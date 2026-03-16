defmodule Liteskill.Memories do
  @moduledoc """
  Context for user-scoped knowledge extraction and management.

  Memories are facts, decisions, insights, and preferences extracted
  from conversations. They build a persistent knowledge base that
  enriches future interactions.
  """

  use Boundary,
    top_level?: true,
    deps: [Liteskill.Rbac],
    exports: [Memory]

  import Ecto.Query

  alias Liteskill.Memories.Memory
  alias Liteskill.Repo

  # --- Write API ---

  def create_memory(attrs, user_id) do
    with :ok <- Liteskill.Rbac.authorize(user_id, "memories:create") do
      %Memory{}
      |> Memory.changeset(Map.put(attrs, :user_id, user_id))
      |> Repo.insert()
    end
  end

  def update_memory(id, attrs, user_id) do
    with {:ok, memory} <- get_memory(id, user_id) do
      memory
      |> Memory.changeset(attrs)
      |> Repo.update()
    end
  end

  def archive_memory(id, user_id) do
    update_memory(id, %{status: "archived"}, user_id)
  end

  def delete_memory(id, user_id) do
    with {:ok, memory} <- get_memory(id, user_id) do
      Repo.delete(memory)
    end
  end

  # --- Read API ---

  def get_memory(id, user_id) do
    case Repo.get(Memory, id) do
      nil -> {:error, :not_found}
      %{user_id: ^user_id} = memory -> {:ok, memory}
      _ -> {:error, :not_found}
    end
  end

  def list_memories(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)

    Memory
    |> where([m], m.user_id == ^user_id and m.status == "active")
    |> apply_category_filter(opts)
    |> apply_search_filter(opts)
    |> order_by([m], desc: m.updated_at)
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  def count_memories(user_id, opts \\ []) do
    Memory
    |> where([m], m.user_id == ^user_id and m.status == "active")
    |> apply_category_filter(opts)
    |> apply_search_filter(opts)
    |> Repo.aggregate(:count)
  end

  def list_memories_for_conversation(conversation_id, user_id) do
    Repo.all(
      from m in Memory,
        where: m.user_id == ^user_id and m.conversation_id == ^conversation_id and m.status == "active",
        order_by: [asc: m.inserted_at]
    )
  end

  # --- Bulk Create (for LLM suggestions) ---

  def create_memories(items, user_id, conversation_id \\ nil) do
    with :ok <- Liteskill.Rbac.authorize(user_id, "memories:create") do
      results =
        Enum.map(items, fn item ->
          attrs =
            item
            |> Map.put(:user_id, user_id)
            |> Map.put(:conversation_id, conversation_id)

          %Memory{}
          |> Memory.changeset(attrs)
          |> Repo.insert()
        end)

      saved = Enum.filter(results, &match?({:ok, _}, &1))
      {:ok, Enum.map(saved, fn {:ok, m} -> m end)}
    end
  end

  # --- Private ---

  defp apply_category_filter(query, opts) do
    case Keyword.get(opts, :category) do
      nil -> query
      cat -> where(query, [m], m.category == ^cat)
    end
  end

  defp apply_search_filter(query, opts) do
    case Keyword.get(opts, :search) do
      search when is_binary(search) and search != "" ->
        escaped =
          search
          |> String.replace("\\", "\\\\")
          |> String.replace("%", "\\%")
          |> String.replace("_", "\\_")

        pattern = "%#{escaped}%"

        where(
          query,
          [m],
          fragment("? LIKE ? ESCAPE '\\'", m.title, ^pattern) or
            fragment("? LIKE ? ESCAPE '\\'", m.content, ^pattern)
        )

      _ ->
        query
    end
  end
end
