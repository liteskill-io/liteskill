defmodule Liteskill.Chat.ConversationNotation do
  @moduledoc """
  Export and import conversations as portable JSON notation.

  The JSON captures the full LLM context window (wire-format messages from
  `MessageBuilder.build_llm_messages/1`) so the file is directly reusable
  as LLM context.
  """

  import Ecto.Query

  alias Liteskill.Authorization
  alias Liteskill.Chat
  alias Liteskill.Chat.Conversation
  alias Liteskill.Chat.MessageBuilder
  alias Liteskill.Chat.Projector
  alias Liteskill.EventStore.Postgres, as: Store
  alias Liteskill.Repo

  require Logger

  @version "1.0"

  @doc """
  Exports a conversation as a notation map.

  Returns `{:ok, map}` with the JSON-serializable notation, or an error tuple
  if the conversation is not found or not accessible.
  """
  def export(conversation_id, user_id) do
    with {:ok, conversation} <- Chat.get_conversation(conversation_id, user_id) do
      messages = MessageBuilder.build_llm_messages(conversation.messages)
      messages = attach_model_ids(messages, conversation.messages)

      {:ok,
       %{
         "liteskill_version" => @version,
         "exported_at" => DateTime.to_iso8601(DateTime.utc_now()),
         "conversation" => %{
           "title" => conversation.title,
           "model_id" => conversation.model_id,
           "system_prompt" => conversation.system_prompt
         },
         "messages" => messages
       }}
    end
  end

  @doc """
  Encodes a notation map as pretty-printed JSON.
  """
  def encode(notation) do
    Jason.encode(notation, pretty: true)
  end

  @doc """
  Imports a conversation from a JSON string.

  Parses the JSON, validates structure, creates a new conversation via
  direct event store writes (following the `fork_conversation` pattern),
  and returns `{:ok, conversation}`.
  """
  def import_conversation(json_string, user_id, opts \\ []) do
    with :ok <- Liteskill.Rbac.authorize(user_id, "conversations:create"),
         {:ok, notation} <- parse_and_validate(json_string) do
      do_import(notation, user_id, opts)
    end
  end

  defp parse_and_validate(json_string) do
    case Jason.decode(json_string) do
      {:ok, %{"liteskill_version" => _, "messages" => messages} = notation}
      when is_list(messages) ->
        {:ok, notation}

      {:ok, _} ->
        {:error, :invalid_notation}

      {:error, _} ->
        {:error, :invalid_json}
    end
  end

  defp do_import(notation, user_id, opts) do
    conversation_id = Keyword.get(opts, :conversation_id, Ecto.UUID.generate())
    stream_id = "conversation-#{conversation_id}"
    conv_data = notation["conversation"] || %{}
    now = DateTime.to_iso8601(DateTime.utc_now())

    create_event = %{
      event_type: "ConversationCreated",
      data: %{
        "conversation_id" => conversation_id,
        "user_id" => user_id,
        "title" => conv_data["title"] || "Imported Conversation",
        "model_id" => conv_data["model_id"],
        "system_prompt" => conv_data["system_prompt"],
        "llm_model_id" => nil,
        "timestamp" => now
      }
    }

    message_events = build_message_events(notation["messages"] || [], now)
    all_events = [create_event | message_events]

    case Store.append_events(stream_id, 0, all_events) do
      {:ok, stored_events} ->
        Projector.project_events(stream_id, stored_events)
        Process.sleep(50)
        new_conv = Repo.one!(from(c in Conversation, where: c.stream_id == ^stream_id))
        {:ok, _} = Authorization.create_owner_acl("conversation", new_conv.id, user_id)
        {:ok, new_conv}

      # coveralls-ignore-start — Store.append_events fails only on UUID collision
      {:error, reason} ->
        {:error, reason}
        # coveralls-ignore-stop
    end
  end

  # Enrich wire-format assistant messages with model_id from source records.
  # Source messages are in DB order; wire messages preserve that order for
  # assistant entries (tool_use creates an interleaved user message but the
  # assistant count stays 1:1 with source assistant records).
  defp attach_model_ids(wire_messages, source_messages) do
    model_ids =
      source_messages
      |> Enum.filter(&(&1.role == "assistant" && &1.status == "complete"))
      |> Enum.map(& &1.model_id)

    {enriched, _remaining} =
      Enum.map_reduce(wire_messages, model_ids, fn msg, ids ->
        if msg["role"] == "assistant" do
          case ids do
            [model_id | rest] ->
              {Map.put(msg, "model_id", model_id), rest}

            # coveralls-ignore-start — defensive: more wire messages than source records after merge
            [] ->
              {msg, []}
              # coveralls-ignore-stop
          end
        else
          {msg, ids}
        end
      end)

    enriched
  end

  defp build_message_events(messages, now) do
    # Track the last assistant message_id so tool results can reference it
    {events, _ctx} =
      Enum.flat_map_reduce(messages, %{last_assistant_message_id: nil}, fn msg, ctx ->
        case msg["role"] do
          "user" ->
            build_user_events(msg, ctx, now)

          "assistant" ->
            build_assistant_events(msg, ctx, now)

          # coveralls-ignore-start — defensive: unknown role in imported JSON
          _ ->
            {[], ctx}
            # coveralls-ignore-stop
        end
      end)

    events
  end

  defp build_user_events(msg, ctx, now) do
    content_blocks = msg["content"] || []

    # Check if this is a tool result message
    tool_results = Enum.filter(content_blocks, &match?(%{"toolResult" => _}, &1))
    text_blocks = Enum.filter(content_blocks, &match?(%{"text" => _}, &1))

    cond do
      tool_results != [] ->
        # Tool result message — generate ToolCallCompleted events
        events =
          Enum.map(tool_results, fn %{"toolResult" => tr} ->
            %{
              event_type: "ToolCallCompleted",
              data: %{
                "message_id" => ctx.last_assistant_message_id,
                "tool_use_id" => tr["toolUseId"],
                "tool_name" => "imported_tool",
                "input" => %{},
                "output" => format_tool_result_content(tr["content"]),
                "duration_ms" => 0,
                "timestamp" => now
              }
            }
          end)

        {events, ctx}

      text_blocks != [] ->
        text = Enum.map_join(text_blocks, "\n", & &1["text"])
        message_id = Ecto.UUID.generate()

        event = %{
          event_type: "UserMessageAdded",
          data: %{
            "message_id" => message_id,
            "content" => text,
            "timestamp" => now,
            "tool_config" => nil
          }
        }

        {[event], ctx}

      # coveralls-ignore-start — defensive: user message with only unknown content block types
      true ->
        {[], ctx}
        # coveralls-ignore-stop
    end
  end

  defp build_assistant_events(msg, ctx, now) do
    content_blocks = msg["content"] || []
    message_id = Ecto.UUID.generate()

    tool_use_blocks = Enum.filter(content_blocks, &match?(%{"toolUse" => _}, &1))
    text_blocks = Enum.filter(content_blocks, &match?(%{"text" => _}, &1))
    text = Enum.map_join(text_blocks, "\n", & &1["text"])

    has_tools = tool_use_blocks != []

    stop_reason =
      if has_tools, do: "tool_use", else: "end_turn"

    start_event = %{
      event_type: "AssistantStreamStarted",
      data: %{
        "message_id" => message_id,
        "model_id" => msg["model_id"],
        "request_id" => nil,
        "timestamp" => now,
        "rag_sources" => nil
      }
    }

    tool_start_events =
      Enum.map(tool_use_blocks, fn %{"toolUse" => tu} ->
        %{
          event_type: "ToolCallStarted",
          data: %{
            "message_id" => message_id,
            "tool_use_id" => tu["toolUseId"] || Ecto.UUID.generate(),
            "tool_name" => tu["name"] || "unknown",
            "input" => tu["input"] || %{},
            "timestamp" => now
          }
        }
      end)

    complete_event = %{
      event_type: "AssistantStreamCompleted",
      data: %{
        "message_id" => message_id,
        "full_content" => text,
        "stop_reason" => stop_reason,
        "input_tokens" => 0,
        "output_tokens" => 0,
        "latency_ms" => 0,
        "timestamp" => now
      }
    }

    events = [start_event] ++ tool_start_events ++ [complete_event]
    ctx = %{ctx | last_assistant_message_id: message_id}
    {events, ctx}
  end

  # coveralls-ignore-start — defensive: nil/non-list tool result content from imported JSON
  defp format_tool_result_content(nil), do: %{"content" => [%{"text" => ""}]}

  defp format_tool_result_content(content) when is_list(content) do
    %{"content" => content}
  end

  defp format_tool_result_content(content), do: %{"content" => [%{"text" => inspect(content)}]}
  # coveralls-ignore-stop
end
