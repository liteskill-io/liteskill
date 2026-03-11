defmodule Liteskill.Acp do
  @moduledoc """
  The ACP (Agent Client Protocol) context.

  Manages configurations for external AI agents that communicate via ACP
  over stdio, and provides lifecycle management for ACP client sessions.
  """

  use Boundary,
    top_level?: true,
    deps: [
      Liteskill.Aggregate,
      Liteskill.Authorization,
      Liteskill.Chat,
      Liteskill.McpServers,
      Liteskill.Rbac
    ],
    exports: [AgentConfig, Client, McpPassthrough, Protocol, SessionBridge]

  import Ecto.Query

  alias Liteskill.Acp.AgentConfig
  alias Liteskill.Authorization
  alias Liteskill.Repo

  # -- CRUD --

  def create_agent_config(attrs) do
    user_id = attrs[:user_id] || attrs["user_id"]

    with :ok <- Liteskill.Rbac.authorize(user_id, "acp:create") do
      Repo.transaction(fn ->
        case %AgentConfig{} |> AgentConfig.changeset(attrs) |> Repo.insert() do
          {:ok, config} ->
            {:ok, _} = Authorization.create_owner_acl("acp_agent_config", config.id, config.user_id)
            config

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)
    end
  end

  def update_agent_config(id, attrs, user_id) do
    with {:ok, config} <- authorize_admin_or_owner(id, user_id) do
      config |> AgentConfig.changeset(attrs) |> Repo.update()
    end
  end

  def delete_agent_config(id, user_id) do
    with {:ok, config} <- authorize_admin_or_owner(id, user_id) do
      Repo.delete(config)
    end
  end

  def get_agent_config(id, user_id) do
    case Repo.get(AgentConfig, id) do
      nil ->
        {:error, :not_found}

      %AgentConfig{user_id: ^user_id} = config ->
        {:ok, config}

      %AgentConfig{instance_wide: true} = config ->
        {:ok, config}

      %AgentConfig{} = config ->
        if Authorization.has_access?("acp_agent_config", config.id, user_id) do
          {:ok, config}
        else
          {:error, :not_found}
        end
    end
  end

  def list_agent_configs(user_id) do
    accessible_ids = Authorization.accessible_entity_ids("acp_agent_config", user_id)

    AgentConfig
    |> where([c], c.user_id == ^user_id or c.instance_wide == true or c.id in subquery(accessible_ids))
    |> order_by([c], asc: c.name)
    |> Repo.all()
  end

  def list_active_agent_configs(user_id) do
    user_id
    |> list_agent_configs()
    |> Enum.filter(&(&1.status == "active"))
  end

  def list_all_active_agent_configs do
    Enum.filter(list_all_agent_configs(), &(&1.status == "active"))
  end

  # -- Admin --

  def list_all_agent_configs do
    Repo.all(from(c in AgentConfig, order_by: [asc: :name]))
  end

  # -- ACL --

  def grant_usage(id, grantee_id, user_id) do
    with :ok <- Liteskill.Rbac.authorize(user_id, "acp:manage") do
      %Authorization.EntityAcl{}
      |> Authorization.EntityAcl.changeset(%{
        entity_type: "acp_agent_config",
        entity_id: id,
        user_id: grantee_id,
        role: "viewer"
      })
      |> Repo.insert()
    end
  end

  def revoke_usage(id, grantee_id, user_id) do
    with :ok <- Liteskill.Rbac.authorize(user_id, "acp:manage") do
      case Repo.one(
             from(a in Authorization.EntityAcl,
               where:
                 a.entity_type == "acp_agent_config" and
                   a.entity_id == ^id and
                   a.user_id == ^grantee_id
             )
           ) do
        nil -> {:error, :not_found}
        acl -> Repo.delete(acl)
      end
    end
  end

  # -- Private --

  defp authorize_admin_or_owner(id, user_id) do
    case Repo.get(AgentConfig, id) do
      nil ->
        {:error, :not_found}

      %AgentConfig{user_id: ^user_id} = config ->
        {:ok, config}

      %AgentConfig{} = config ->
        if Liteskill.Rbac.has_any_admin_permission?(user_id) do
          {:ok, config}
        else
          {:error, :forbidden}
        end
    end
  end
end
