defmodule Liteskill.Chat.Search do
  @moduledoc """
  Full-text search across conversation messages.

  Uses SQLite FTS5 when available, with graceful fallback to LIKE queries.
  Authorization-aware: only searches conversations the user can access.
  """

  import Ecto.Query

  alias Liteskill.Authorization
  alias Liteskill.Chat.Conversation
  alias Liteskill.Repo

  require Logger

  @default_limit 20

  @doc """
  Search messages across all accessible conversations.

  Returns a list of maps with :message_id, :conversation_id, :conversation_title,
  :content, :snippet, :role, and :updated_at.
  """
  def search(user_id, query, opts \\ []) do
    query = String.trim(query)

    if query == "" do
      []
    else
      case fts_search(user_id, query, opts) do
        {:ok, results} ->
          results

        {:error, _reason} ->
          like_search(user_id, query, opts)
      end
    end
  end

  @doc """
  Returns true if FTS5 is available in the current SQLite build.
  """
  def fts_available? do
    case Repo.query("SELECT 1 FROM messages_fts LIMIT 0") do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  # --- FTS5 Search ---

  defp fts_search(user_id, query, opts) do
    limit = Keyword.get(opts, :limit, @default_limit)
    offset = Keyword.get(opts, :offset, 0)
    accessible_ids = accessible_conversation_ids(user_id)

    # Sanitize query for FTS5: escape special chars, wrap terms in quotes
    fts_query = sanitize_fts_query(query)

    sql = """
    SELECT
      f.message_id,
      f.conversation_id,
      c.title as conversation_title,
      snippet(messages_fts, 2, '<<', '>>', '...', 40) as snippet,
      m.role,
      m.updated_at,
      rank
    FROM messages_fts f
    JOIN messages m ON m.id = f.message_id
    JOIN conversations c ON c.id = f.conversation_id
    WHERE messages_fts MATCH ?
      AND f.conversation_id IN (#{placeholders(accessible_ids)})
    ORDER BY rank
    LIMIT ? OFFSET ?
    """

    params = [fts_query] ++ accessible_ids ++ [limit, offset]

    case Repo.query(sql, params) do
      {:ok, %{rows: rows, columns: columns}} ->
        {:ok, Enum.map(rows, fn row -> row_to_result(columns, row) end)}

      {:error, reason} ->
        Logger.debug("FTS5 search failed, falling back to LIKE: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # --- LIKE Fallback ---

  defp like_search(user_id, query, opts) do
    limit = Keyword.get(opts, :limit, @default_limit)
    offset = Keyword.get(opts, :offset, 0)

    escaped =
      query
      |> String.replace("\\", "\\\\")
      |> String.replace("%", "\\%")
      |> String.replace("_", "\\_")

    pattern = "%#{escaped}%"

    accessible_ids_query = Authorization.accessible_entity_ids("conversation", user_id)

    results =
      Repo.all(
        from(m in "messages",
          join: c in Conversation,
          on: c.id == m.conversation_id,
          where:
            (c.user_id == ^user_id or c.id in subquery(accessible_ids_query)) and
              fragment("? LIKE ? ESCAPE '\\'", m.content, ^pattern),
          select: %{
            message_id: m.id,
            conversation_id: m.conversation_id,
            conversation_title: c.title,
            snippet: fragment("substr(?, max(1, instr(lower(?), lower(?)) - 40), 120)", m.content, m.content, ^query),
            role: m.role,
            updated_at: m.updated_at
          },
          order_by: [desc: m.updated_at],
          limit: ^limit,
          offset: ^offset
        )
      )

    results
  end

  # --- Helpers ---

  defp accessible_conversation_ids(user_id) do
    accessible_ids_query = Authorization.accessible_entity_ids("conversation", user_id)

    owned = Repo.all(from(c in Conversation, where: c.user_id == ^user_id and c.status != "archived", select: c.id))

    shared = Repo.all(accessible_ids_query)

    Enum.uniq(owned ++ shared)
  end

  defp placeholders([]), do: "SELECT NULL WHERE 0"

  defp placeholders(list) do
    Enum.map_join(list, ", ", fn _ -> "?" end)
  end

  defp sanitize_fts_query(query) do
    # Escape FTS5 special characters and wrap each term in quotes
    query
    |> String.replace(~r/["\(\)\*\:]/, "")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.map_join(" ", fn term -> "\"#{term}\"" end)
  end

  @result_keys %{
    "message_id" => :message_id,
    "conversation_id" => :conversation_id,
    "conversation_title" => :conversation_title,
    "snippet" => :snippet,
    "role" => :role,
    "updated_at" => :updated_at,
    "rank" => :rank
  }

  defp row_to_result(columns, row) do
    columns
    |> Enum.zip(row)
    |> Map.new(fn {col, val} -> {Map.get(@result_keys, col, col), val} end)
  end
end
