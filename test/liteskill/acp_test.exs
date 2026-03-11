defmodule Liteskill.AcpTest do
  use Liteskill.DataCase, async: false

  alias Liteskill.Acp
  alias Liteskill.Acp.AgentConfig

  setup do
    user = insert_user()
    %{user: user}
  end

  describe "create_agent_config/1" do
    test "creates with valid attrs", %{user: user} do
      attrs = %{
        name: "Claude Code",
        command: "claude",
        args: ["--acp"],
        user_id: user.id
      }

      assert {:ok, %AgentConfig{} = config} = Acp.create_agent_config(attrs)
      assert config.name == "Claude Code"
      assert config.command == "claude"
      assert config.args == ["--acp"]
      assert config.status == "active"
      assert config.instance_wide == false
    end

    test "fails without required fields", %{user: user} do
      assert {:error, %Ecto.Changeset{}} = Acp.create_agent_config(%{user_id: user.id})
    end

    test "enforces unique name per user", %{user: user} do
      attrs = %{name: "agent", command: "cmd", user_id: user.id}

      assert {:ok, _} = Acp.create_agent_config(attrs)
      assert {:error, %Ecto.Changeset{}} = Acp.create_agent_config(attrs)
    end

    test "rejects nil user_id" do
      assert {:error, :forbidden} = Acp.create_agent_config(%{name: "x", command: "x", user_id: nil})
    end
  end

  describe "get_agent_config/2" do
    test "owner can access", %{user: user} do
      {:ok, config} = Acp.create_agent_config(%{name: "a", command: "c", user_id: user.id})
      assert {:ok, ^config} = Acp.get_agent_config(config.id, user.id)
    end

    test "instance_wide accessible to any user", %{user: user} do
      admin = insert_user(email: "admin2@test.com")
      {:ok, config} = Acp.create_agent_config(%{name: "global", command: "c", user_id: admin.id})
      Liteskill.Repo.update!(Ecto.Changeset.change(config, instance_wide: true))

      assert {:ok, _} = Acp.get_agent_config(config.id, user.id)
    end

    test "returns not_found for unauthorized user", %{user: user} do
      other = insert_user(email: "other@test.com")
      {:ok, config} = Acp.create_agent_config(%{name: "private", command: "c", user_id: other.id})

      assert {:error, :not_found} = Acp.get_agent_config(config.id, user.id)
    end
  end

  describe "list_agent_configs/1" do
    test "lists owned and instance_wide configs", %{user: user} do
      {:ok, _owned} = Acp.create_agent_config(%{name: "mine", command: "c", user_id: user.id})

      admin = insert_user(email: "admin3@test.com")
      {:ok, global} = Acp.create_agent_config(%{name: "global", command: "c", user_id: admin.id})
      Liteskill.Repo.update!(Ecto.Changeset.change(global, instance_wide: true))

      configs = Acp.list_agent_configs(user.id)
      assert length(configs) == 2
    end
  end

  describe "update_agent_config/3" do
    test "owner can update", %{user: user} do
      {:ok, config} = Acp.create_agent_config(%{name: "a", command: "c", user_id: user.id})

      assert {:ok, updated} = Acp.update_agent_config(config.id, %{name: "b"}, user.id)
      assert updated.name == "b"
    end
  end

  describe "delete_agent_config/2" do
    test "owner can delete", %{user: user} do
      {:ok, config} = Acp.create_agent_config(%{name: "a", command: "c", user_id: user.id})

      assert {:ok, _} = Acp.delete_agent_config(config.id, user.id)
      assert {:error, :not_found} = Acp.get_agent_config(config.id, user.id)
    end
  end

  describe "list_active_agent_configs/1" do
    test "filters inactive configs", %{user: user} do
      {:ok, _active} = Acp.create_agent_config(%{name: "active", command: "c", user_id: user.id})

      {:ok, inactive} =
        Acp.create_agent_config(%{name: "inactive", command: "c", user_id: user.id, status: "inactive"})

      configs = Acp.list_active_agent_configs(user.id)
      assert length(configs) == 1
      refute Enum.any?(configs, &(&1.id == inactive.id))
    end
  end

  describe "list_all_agent_configs/0" do
    test "lists all configs regardless of owner", %{user: user} do
      {:ok, _} = Acp.create_agent_config(%{name: "one", command: "c", user_id: user.id})

      other = insert_user(email: "other-admin@test.com")
      {:ok, _} = Acp.create_agent_config(%{name: "two", command: "c", user_id: other.id})

      configs = Acp.list_all_agent_configs()
      assert length(configs) >= 2
    end
  end

  describe "get_agent_config/2 with ACL" do
    test "returns config when user has ACL access", %{user: user} do
      admin = insert_user(email: "acl-admin@test.com")
      Liteskill.Rbac.ensure_system_roles()
      admin_role = Liteskill.Rbac.get_role_by_name!("Instance Admin")
      {:ok, _} = Liteskill.Rbac.assign_role_to_user(admin.id, admin_role.id)

      {:ok, config} = Acp.create_agent_config(%{name: "shared", command: "c", user_id: admin.id})

      # Without ACL, user can't access
      assert {:error, :not_found} = Acp.get_agent_config(config.id, user.id)

      # Grant ACL access via context function
      assert {:ok, _} = Acp.grant_usage(config.id, user.id, admin.id)

      assert {:ok, _} = Acp.get_agent_config(config.id, user.id)
    end

    test "returns not_found for nonexistent config", %{user: user} do
      assert {:error, :not_found} = Acp.get_agent_config(Ecto.UUID.generate(), user.id)
    end
  end

  describe "update_agent_config/3 authorization" do
    test "non-owner non-admin gets forbidden", %{user: user} do
      other = insert_user(email: "update-owner@test.com")
      {:ok, config} = Acp.create_agent_config(%{name: "theirs", command: "c", user_id: other.id})

      assert {:error, :forbidden} = Acp.update_agent_config(config.id, %{name: "nope"}, user.id)
    end

    test "returns not_found for missing config", %{user: user} do
      assert {:error, :not_found} = Acp.update_agent_config(Ecto.UUID.generate(), %{}, user.id)
    end
  end

  describe "delete_agent_config/2 authorization" do
    test "non-owner non-admin gets forbidden", %{user: user} do
      other = insert_user(email: "delete-owner@test.com")
      {:ok, config} = Acp.create_agent_config(%{name: "theirs", command: "c", user_id: other.id})

      assert {:error, :forbidden} = Acp.delete_agent_config(config.id, user.id)
    end
  end

  describe "grant_usage/3 and revoke_usage/3" do
    test "grants and revokes usage with admin permission", %{user: _user} do
      admin = insert_user(email: "grant-admin@test.com")
      Liteskill.Rbac.ensure_system_roles()
      admin_role = Liteskill.Rbac.get_role_by_name!("Instance Admin")
      {:ok, _} = Liteskill.Rbac.assign_role_to_user(admin.id, admin_role.id)

      {:ok, config} = Acp.create_agent_config(%{name: "shared-acl", command: "c", user_id: admin.id})
      grantee = insert_user(email: "grantee@test.com")

      assert {:ok, _} = Acp.grant_usage(config.id, grantee.id, admin.id)
      assert {:ok, _} = Acp.get_agent_config(config.id, grantee.id)

      assert {:ok, _} = Acp.revoke_usage(config.id, grantee.id, admin.id)
      assert {:error, :not_found} = Acp.get_agent_config(config.id, grantee.id)
    end
  end

  # -- Helpers --

  defp insert_user(opts \\ []) do
    email = Keyword.get(opts, :email, "acp-test-#{System.unique_integer([:positive])}@test.com")

    {:ok, user} =
      Liteskill.Accounts.register_user(%{
        email: email,
        password: "TestPassword123!",
        name: "Test User"
      })

    user
  end
end
