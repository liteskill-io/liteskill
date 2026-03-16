defmodule Liteskill.MemoriesTest do
  use Liteskill.DataCase, async: false

  alias Liteskill.Memories

  setup do
    {:ok, user} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "mem-test-#{System.unique_integer([:positive])}@example.com",
        name: "Memory Tester",
        oidc_sub: "mem-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    {:ok, other_user} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "mem-other-#{System.unique_integer([:positive])}@example.com",
        name: "Other User",
        oidc_sub: "mem-other-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    %{user: user, other_user: other_user}
  end

  describe "Memory.categories/0" do
    test "returns list of valid categories" do
      cats = Liteskill.Memories.Memory.categories()
      assert is_list(cats)
      assert "fact" in cats
      assert "decision" in cats
      assert "insight" in cats
      assert "preference" in cats
    end
  end

  describe "create_memory/2" do
    test "creates a memory with valid attrs", %{user: user} do
      attrs = %{title: "Test Memory", content: "Some important fact", category: "fact"}
      assert {:ok, memory} = Memories.create_memory(attrs, user.id)
      assert memory.title == "Test Memory"
      assert memory.content == "Some important fact"
      assert memory.category == "fact"
      assert memory.user_id == user.id
      assert memory.status == "active"
    end

    test "rejects invalid category", %{user: user} do
      attrs = %{title: "Test", content: "Content", category: "invalid"}
      assert {:error, changeset} = Memories.create_memory(attrs, user.id)
      assert %{category: _} = errors_on(changeset)
    end

    test "requires title and content", %{user: user} do
      assert {:error, changeset} = Memories.create_memory(%{}, user.id)
      errors = errors_on(changeset)
      assert %{title: _, content: _} = errors
    end
  end

  describe "list_memories/2" do
    test "lists only user's active memories", %{user: user, other_user: other_user} do
      {:ok, _} = Memories.create_memory(%{title: "Mine", content: "c", category: "fact"}, user.id)
      {:ok, _} = Memories.create_memory(%{title: "Theirs", content: "c", category: "fact"}, other_user.id)

      memories = Memories.list_memories(user.id)
      assert length(memories) == 1
      assert hd(memories).title == "Mine"
    end

    test "filters by category", %{user: user} do
      {:ok, _} = Memories.create_memory(%{title: "Fact", content: "c", category: "fact"}, user.id)
      {:ok, _} = Memories.create_memory(%{title: "Decision", content: "c", category: "decision"}, user.id)

      memories = Memories.list_memories(user.id, category: "fact")
      assert length(memories) == 1
      assert hd(memories).title == "Fact"
    end

    test "searches by title and content", %{user: user} do
      {:ok, _} = Memories.create_memory(%{title: "Database Migration", content: "c", category: "fact"}, user.id)
      {:ok, _} = Memories.create_memory(%{title: "Other", content: "c", category: "fact"}, user.id)

      memories = Memories.list_memories(user.id, search: "migration")
      assert length(memories) == 1
      assert hd(memories).title == "Database Migration"
    end

    test "excludes archived memories", %{user: user} do
      {:ok, memory} = Memories.create_memory(%{title: "Test", content: "c", category: "fact"}, user.id)
      {:ok, _} = Memories.archive_memory(memory.id, user.id)

      assert Memories.list_memories(user.id) == []
    end
  end

  describe "get_memory/2" do
    test "returns memory owned by user", %{user: user} do
      {:ok, memory} = Memories.create_memory(%{title: "Test", content: "c", category: "fact"}, user.id)
      assert {:ok, found} = Memories.get_memory(memory.id, user.id)
      assert found.id == memory.id
    end

    test "returns not_found for other user's memory", %{user: user, other_user: other_user} do
      {:ok, memory} = Memories.create_memory(%{title: "Test", content: "c", category: "fact"}, user.id)
      assert {:error, :not_found} = Memories.get_memory(memory.id, other_user.id)
    end

    test "returns not_found for nonexistent id", %{user: user} do
      assert {:error, :not_found} = Memories.get_memory(Ecto.UUID.generate(), user.id)
    end
  end

  describe "update_memory/3" do
    test "updates owned memory", %{user: user} do
      {:ok, memory} = Memories.create_memory(%{title: "Old", content: "c", category: "fact"}, user.id)
      assert {:ok, updated} = Memories.update_memory(memory.id, %{title: "New"}, user.id)
      assert updated.title == "New"
    end
  end

  describe "delete_memory/2" do
    test "deletes owned memory", %{user: user} do
      {:ok, memory} = Memories.create_memory(%{title: "Test", content: "c", category: "fact"}, user.id)
      assert {:ok, _} = Memories.delete_memory(memory.id, user.id)
      assert {:error, :not_found} = Memories.get_memory(memory.id, user.id)
    end
  end

  describe "create_memories/3" do
    test "bulk creates memories", %{user: user} do
      items = [
        %{title: "Item 1", content: "Content 1", category: "fact"},
        %{title: "Item 2", content: "Content 2", category: "decision"}
      ]

      assert {:ok, memories} = Memories.create_memories(items, user.id)
      assert length(memories) == 2
    end
  end

  describe "list_memories_for_conversation/2" do
    test "lists memories linked to a conversation", %{user: user} do
      {:ok, conv} = Liteskill.Chat.create_conversation(%{user_id: user.id, title: "Test Conv"})

      {:ok, _} =
        Memories.create_memory(
          %{title: "Linked", content: "c", category: "fact", conversation_id: conv.id},
          user.id
        )

      {:ok, _} = Memories.create_memory(%{title: "Unlinked", content: "c", category: "fact"}, user.id)

      memories = Memories.list_memories_for_conversation(conv.id, user.id)
      assert length(memories) == 1
      assert hd(memories).title == "Linked"
    end
  end

  describe "count_memories/2" do
    test "counts active memories", %{user: user} do
      {:ok, _} = Memories.create_memory(%{title: "A", content: "c", category: "fact"}, user.id)
      {:ok, m} = Memories.create_memory(%{title: "B", content: "c", category: "fact"}, user.id)
      {:ok, _} = Memories.archive_memory(m.id, user.id)

      assert Memories.count_memories(user.id) == 1
    end
  end
end
