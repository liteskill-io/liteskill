defmodule Liteskill.SingleUserTest do
  use Liteskill.DataCase, async: false

  alias Liteskill.Accounts
  alias Liteskill.Accounts.User
  alias Liteskill.LlmProviders
  alias Liteskill.Settings
  alias Liteskill.SingleUser

  describe "enabled?/0" do
    test "returns false by default" do
      refute SingleUser.enabled?()
    end

    test "returns true when configured" do
      original = Application.get_env(:liteskill, :single_user_mode, false)
      Application.put_env(:liteskill, :single_user_mode, true)

      on_exit(fn ->
        Application.put_env(:liteskill, :single_user_mode, original)
      end)

      assert SingleUser.enabled?()
    end
  end

  describe "auto_user/0" do
    test "returns admin user when it exists" do
      Accounts.ensure_admin_user()
      user = SingleUser.auto_user()
      assert %User{} = user
      assert user.email == User.admin_email()
    end
  end

  describe "auto_provision_admin/0" do
    test "sets password on admin when setup is required" do
      admin = Accounts.ensure_admin_user()
      assert User.setup_required?(admin)

      assert {:ok, updated} = SingleUser.auto_provision_admin()
      refute User.setup_required?(updated)
      assert updated.password_hash
    end

    test "returns :noop when admin user does not exist" do
      # Delete the admin user so auto_user() returns nil
      admin_email = User.admin_email()

      case Liteskill.Repo.get_by(User, email: admin_email) do
        nil -> :ok
        user -> Liteskill.Repo.delete!(user)
      end

      assert :noop = SingleUser.auto_provision_admin()
    end

    test "is a no-op when admin already has a password" do
      admin = Accounts.ensure_admin_user()
      {:ok, admin} = Accounts.setup_admin_password(admin, "a_secure_password1")
      refute User.setup_required?(admin)

      assert {:ok, same} = SingleUser.auto_provision_admin()
      assert same.id == admin.id
    end
  end

  describe "setup_needed?/0" do
    setup do
      original = Application.get_env(:liteskill, :single_user_mode, false)

      on_exit(fn ->
        Application.put_env(:liteskill, :single_user_mode, original)
      end)

      admin = Accounts.ensure_admin_user()
      {:ok, admin: admin}
    end

    test "returns false when single_user_mode is disabled", %{admin: _admin} do
      Application.put_env(:liteskill, :single_user_mode, false)
      refute SingleUser.setup_needed?()
    end

    test "returns true when enabled and no providers exist", %{admin: _admin} do
      Application.put_env(:liteskill, :single_user_mode, true)
      assert SingleUser.setup_needed?()
    end

    test "returns false when enabled and a provider exists", %{admin: admin} do
      Application.put_env(:liteskill, :single_user_mode, true)

      {:ok, _provider} =
        LlmProviders.create_provider(%{
          name: "Test Provider",
          provider_type: "anthropic",
          provider_config: %{},
          user_id: admin.id
        })

      refute SingleUser.setup_needed?()
    end

    test "returns false when enabled and an ACP agent exists", %{admin: admin} do
      Application.put_env(:liteskill, :single_user_mode, true)

      {:ok, _agent} =
        Liteskill.Acp.create_agent_config(%{
          name: "Test Agent",
          command: "test-agent",
          user_id: admin.id
        })

      refute SingleUser.setup_needed?()
    end

    test "returns false when setup has been dismissed", %{admin: _admin} do
      Application.put_env(:liteskill, :single_user_mode, true)

      # No providers/models/embedding, but setup was dismissed
      assert LlmProviders.list_all_providers() == []
      {:ok, _} = Settings.dismiss_setup()

      refute SingleUser.setup_needed?()
    end
  end
end
