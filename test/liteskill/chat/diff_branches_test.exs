defmodule Liteskill.Chat.DiffBranchesTest do
  use Liteskill.DataCase, async: false

  alias Liteskill.Chat

  setup do
    {:ok, user} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "diff-test-#{System.unique_integer([:positive])}@example.com",
        name: "Diff Tester",
        oidc_sub: "diff-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    %{user: user}
  end

  describe "diff_branches/3" do
    test "returns shared and divergent messages", %{user: user} do
      # Create parent conversation with messages
      {:ok, parent} = Chat.create_conversation(%{user_id: user.id, title: "Parent"})
      {:ok, _} = Chat.send_message(parent.id, user.id, "Hello")
      Process.sleep(50)
      {:ok, _} = Chat.send_message(parent.id, user.id, "World")
      Process.sleep(50)

      # Fork at position 1 (after "Hello")
      {:ok, fork} = Chat.fork_conversation(parent.id, user.id, 1)
      Process.sleep(50)

      # Add different messages to each branch
      {:ok, _} = Chat.send_message(parent.id, user.id, "Parent branch message")
      Process.sleep(50)
      {:ok, _} = Chat.send_message(fork.id, user.id, "Fork branch message")
      Process.sleep(50)

      assert {:ok, diff} = Chat.diff_branches(parent.id, fork.id, user.id)

      # The shared prefix should include at least the first message
      assert diff.shared != []
      assert diff.branch_a != [] or diff.branch_b != []
    end

    test "returns not_found for inaccessible conversation", %{user: user} do
      {:ok, other_user} =
        Liteskill.Accounts.find_or_create_from_oidc(%{
          email: "diff-other-#{System.unique_integer([:positive])}@example.com",
          name: "Other",
          oidc_sub: "diff-other-#{System.unique_integer([:positive])}",
          oidc_issuer: "https://test.example.com"
        })

      {:ok, conv} = Chat.create_conversation(%{user_id: other_user.id, title: "Private"})

      {:ok, my_conv} = Chat.create_conversation(%{user_id: user.id, title: "Mine"})

      assert {:error, :not_found} = Chat.diff_branches(conv.id, my_conv.id, user.id)
    end
  end
end
