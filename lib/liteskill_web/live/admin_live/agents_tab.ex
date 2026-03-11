defmodule LiteskillWeb.AdminLive.AgentsTab do
  @moduledoc false

  use LiteskillWeb, :html

  import LiteskillWeb.AdminLive.Helpers, only: [require_admin: 2]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Liteskill.Acp

  def assigns do
    [
      acp_agents: [],
      editing_acp_agent: nil,
      acp_agent_form: %{}
    ]
  end

  def load_data(socket) do
    agents = Acp.list_all_agent_configs()

    assign(socket,
      page_title: "ACP Agents",
      acp_agents: agents,
      editing_acp_agent: nil,
      acp_agent_form: %{}
    )
  end

  @events ~w(new_acp_agent cancel_acp_agent create_acp_agent edit_acp_agent update_acp_agent delete_acp_agent toggle_acp_agent_instance_wide)

  def events, do: @events

  def handle_event("new_acp_agent", _params, socket) do
    {:noreply,
     assign(socket,
       editing_acp_agent: :new,
       acp_agent_form: %{"name" => "", "command" => "", "args" => "", "description" => ""}
     )}
  end

  def handle_event("cancel_acp_agent", _params, socket) do
    {:noreply, assign(socket, editing_acp_agent: nil, acp_agent_form: %{})}
  end

  def handle_event("create_acp_agent", %{"agent" => params}, socket) do
    require_admin(socket, fn ->
      user_id = socket.assigns.current_user.id

      attrs = %{
        name: params["name"],
        command: params["command"],
        args: parse_args(params["args"]),
        description: params["description"],
        user_id: user_id
      }

      case Acp.create_agent_config(attrs) do
        {:ok, _config} ->
          {:noreply,
           socket
           |> assign(acp_agents: Acp.list_all_agent_configs(), editing_acp_agent: nil, acp_agent_form: %{})
           |> put_flash(:info, "Agent created.")}

        {:error, %Ecto.Changeset{} = cs} ->
          {:noreply, put_flash(socket, :error, changeset_error(cs))}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed: #{inspect(reason)}")}
      end
    end)
  end

  def handle_event("edit_acp_agent", %{"id" => id}, socket) do
    agent = Enum.find(socket.assigns.acp_agents, &(&1.id == id))

    if agent do
      {:noreply,
       assign(socket,
         editing_acp_agent: agent,
         acp_agent_form: %{
           "name" => agent.name,
           "command" => agent.command,
           "args" => Enum.join(agent.args || [], " "),
           "description" => agent.description || ""
         }
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("update_acp_agent", %{"agent" => params}, socket) do
    require_admin(socket, fn ->
      agent = socket.assigns.editing_acp_agent
      user_id = socket.assigns.current_user.id

      attrs = %{
        name: params["name"],
        command: params["command"],
        args: parse_args(params["args"]),
        description: params["description"]
      }

      case Acp.update_agent_config(agent.id, attrs, user_id) do
        {:ok, _} ->
          {:noreply,
           socket
           |> assign(acp_agents: Acp.list_all_agent_configs(), editing_acp_agent: nil, acp_agent_form: %{})
           |> put_flash(:info, "Agent updated.")}

        {:error, %Ecto.Changeset{} = cs} ->
          {:noreply, put_flash(socket, :error, changeset_error(cs))}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed: #{inspect(reason)}")}
      end
    end)
  end

  def handle_event("delete_acp_agent", %{"id" => id}, socket) do
    require_admin(socket, fn ->
      user_id = socket.assigns.current_user.id

      case Acp.delete_agent_config(id, user_id) do
        {:ok, _} ->
          {:noreply,
           socket
           |> assign(acp_agents: Acp.list_all_agent_configs())
           |> put_flash(:info, "Agent deleted.")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed: #{inspect(reason)}")}
      end
    end)
  end

  def handle_event("toggle_acp_agent_instance_wide", %{"id" => id}, socket) do
    require_admin(socket, fn ->
      agent = Enum.find(socket.assigns.acp_agents, &(&1.id == id))
      user_id = socket.assigns.current_user.id

      if agent do
        case Acp.update_agent_config(agent.id, %{instance_wide: !agent.instance_wide}, user_id) do
          {:ok, _} ->
            {:noreply, assign(socket, acp_agents: Acp.list_all_agent_configs())}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Failed: #{inspect(reason)}")}
        end
      else
        {:noreply, socket}
      end
    end)
  end

  def render_tab(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between">
        <div>
          <h2 class="text-xl font-semibold">ACP Agents</h2>
          <p class="text-sm text-base-content/60 mt-1">
            External AI agents that communicate via the Agent Client Protocol (ACP) over stdio.
          </p>
        </div>
        <button
          :if={@editing_acp_agent == nil}
          phx-click="new_acp_agent"
          class="btn btn-primary btn-sm gap-1"
        >
          <.icon name="hero-plus-micro" class="size-4" /> Add Agent
        </button>
      </div>

      <%= if @editing_acp_agent do %>
        <div class="card bg-base-100 shadow">
          <div class="card-body">
            <h3 class="card-title text-base">
              {if @editing_acp_agent == :new, do: "New Agent", else: "Edit Agent"}
            </h3>
            <form
              phx-submit={
                if @editing_acp_agent == :new, do: "create_acp_agent", else: "update_acp_agent"
              }
              class="space-y-4"
            >
              <div class="form-control">
                <label class="label"><span class="label-text">Name</span></label>
                <input
                  type="text"
                  name="agent[name]"
                  value={@acp_agent_form["name"]}
                  class="input input-bordered"
                  required
                  placeholder="e.g. Claude Code"
                />
              </div>
              <div class="form-control">
                <label class="label"><span class="label-text">Command</span></label>
                <input
                  type="text"
                  name="agent[command]"
                  value={@acp_agent_form["command"]}
                  class="input input-bordered"
                  required
                  placeholder="e.g. claude"
                />
              </div>
              <div class="form-control">
                <label class="label">
                  <span class="label-text">Arguments (space-separated)</span>
                </label>
                <input
                  type="text"
                  name="agent[args]"
                  value={@acp_agent_form["args"]}
                  class="input input-bordered"
                  placeholder="e.g. --acp --model opus"
                />
              </div>
              <div class="form-control">
                <label class="label"><span class="label-text">Description</span></label>
                <input
                  type="text"
                  name="agent[description]"
                  value={@acp_agent_form["description"]}
                  class="input input-bordered"
                  placeholder="Optional description"
                />
              </div>
              <div class="flex gap-2 justify-end">
                <button type="button" phx-click="cancel_acp_agent" class="btn btn-ghost btn-sm">
                  Cancel
                </button>
                <button type="submit" class="btn btn-primary btn-sm">
                  {if @editing_acp_agent == :new, do: "Create", else: "Save"}
                </button>
              </div>
            </form>
          </div>
        </div>
      <% end %>

      <div
        :if={@acp_agents == [] && @editing_acp_agent == nil}
        class="text-center py-12 text-base-content/60"
      >
        <.icon name="hero-cpu-chip" class="size-12 mx-auto mb-3 opacity-40" />
        <p>No ACP agents configured yet.</p>
        <p class="text-sm mt-1">Add an agent like Claude Code, Codex, or Gemini CLI.</p>
      </div>

      <div :if={@acp_agents != []} class="space-y-3">
        <div :for={agent <- @acp_agents} class="card bg-base-100 shadow">
          <div class="card-body py-4">
            <div class="flex items-center justify-between">
              <div>
                <div class="flex items-center gap-2">
                  <h3 class="font-semibold">{agent.name}</h3>
                  <span class={[
                    "badge badge-sm",
                    if(agent.status == "active", do: "badge-success", else: "badge-ghost")
                  ]}>
                    {agent.status}
                  </span>
                  <span :if={agent.instance_wide} class="badge badge-sm badge-info">
                    instance-wide
                  </span>
                </div>
                <p class="text-sm text-base-content/60 mt-1 font-mono">
                  {agent.command} {Enum.join(agent.args || [], " ")}
                </p>
                <p :if={agent.description} class="text-sm text-base-content/60 mt-0.5">
                  {agent.description}
                </p>
              </div>
              <div class="flex items-center gap-2">
                <label
                  class="flex items-center gap-1 cursor-pointer"
                  title="Make available to all users"
                >
                  <span class="text-xs text-base-content/60">Shared</span>
                  <input
                    type="checkbox"
                    class="toggle toggle-sm toggle-primary"
                    checked={agent.instance_wide}
                    phx-click="toggle_acp_agent_instance_wide"
                    phx-value-id={agent.id}
                  />
                </label>
                <button
                  phx-click="edit_acp_agent"
                  phx-value-id={agent.id}
                  class="btn btn-ghost btn-sm btn-square"
                  title="Edit"
                >
                  <.icon name="hero-pencil-micro" class="size-4" />
                </button>
                <button
                  phx-click="delete_acp_agent"
                  phx-value-id={agent.id}
                  class="btn btn-ghost btn-sm btn-square text-error"
                  title="Delete"
                  data-confirm="Delete this agent?"
                >
                  <.icon name="hero-trash-micro" class="size-4" />
                </button>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp parse_args(nil), do: []
  defp parse_args(""), do: []
  defp parse_args(str), do: String.split(str)

  defp changeset_error(%Ecto.Changeset{} = cs) do
    cs
    |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
    |> Enum.map_join(", ", fn {field, msgs} -> "#{field}: #{Enum.join(msgs, ", ")}" end)
  end
end
