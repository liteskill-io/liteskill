defmodule Liteskill.Acp.SessionBridge do
  @moduledoc """
  Bridges ACP session updates to the conversation event store.

  Translates ACP session/update notifications into conversation aggregate
  commands so that ACP agent activity is recorded in the same event-sourced
  model as native LLM streams.
  """

  alias Liteskill.Aggregate.Loader
  alias Liteskill.Chat.ConversationAggregate
  alias Liteskill.Chat.Projector

  require Logger

  @doc """
  Starts an assistant stream in the conversation for ACP mode.

  Called when the user sends a prompt to the ACP agent.
  Returns `{:ok, message_id}` or `{:error, reason}`.
  """
  def start_stream(stream_id, opts \\ []) do
    model_id = Keyword.get(opts, :model_id, "acp-agent")
    message_id = Keyword.get(opts, :message_id, Ecto.UUID.generate())

    command = {:start_assistant_stream, %{message_id: message_id, model_id: model_id}}

    case Loader.execute(ConversationAggregate, stream_id, command) do
      {:ok, _state, events} ->
        Projector.project_events(stream_id, events)
        {:ok, message_id}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Processes an ACP session/update notification and records it in the event store.

  Returns `:ok` on success.
  """
  def handle_update(stream_id, message_id, update) do
    inner = unwrap_update(update)

    case classify_update(inner) do
      {:content_chunk, text} ->
        handle_content_chunk(stream_id, message_id, text)

      {:tool_call, tool_call_id, tool_call} ->
        handle_tool_call(stream_id, message_id, tool_call_id, tool_call)

      {:tool_result, tool_call_id, result, tool_name} ->
        handle_tool_result(stream_id, message_id, tool_call_id, result, tool_name)

      {:plan, _plan} ->
        :ok

      :ignored ->
        :ok

      :unknown ->
        :ok
    end
  end

  @doc """
  Completes the ACP stream in the conversation.

  Called when `session/prompt` returns with a stopReason.
  """
  def complete_stream(stream_id, message_id, full_content, opts \\ []) do
    stop_reason = Keyword.get(opts, :stop_reason, "end_turn")

    command =
      {:complete_stream,
       %{
         message_id: message_id,
         full_content: full_content,
         stop_reason: stop_reason,
         latency_ms: 0,
         input_tokens: 0,
         output_tokens: 0
       }}

    case Loader.execute(ConversationAggregate, stream_id, command) do
      {:ok, _state, events} ->
        Projector.project_events(stream_id, events)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Fails the ACP stream in the conversation.

  Called when the ACP agent exits unexpectedly or returns an error.
  """
  def fail_stream(stream_id, message_id, error_message) do
    command =
      {:fail_stream,
       %{
         message_id: message_id,
         error_type: "acp_error",
         error_message: error_message,
         retry_count: 0
       }}

    case Loader.execute(ConversationAggregate, stream_id, command) do
      {:ok, _state, events} ->
        Projector.project_events(stream_id, events)
        {:error, {"acp_error", error_message}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # -- Update Unwrapping --

  # ACP session/update notifications wrap the actual update under an "update" key:
  # %{"sessionId" => "...", "update" => %{"sessionUpdate" => "agent_message_chunk", ...}}
  defp unwrap_update(%{"update" => inner}) when is_map(inner), do: inner
  defp unwrap_update(update), do: update

  # -- Update Classification --
  #
  # Different ACP agents use different sessionUpdate values for the same concepts:
  #   - ACP spec: "tool_use" / "tool_result"
  #   - Claude Code: "tool_call" (status "pending") / "tool_call_update" (status "completed")
  #   - Legacy: flat format with "type" key instead of "sessionUpdate"
  #
  # All :tool_result tuples carry {id, result, tool_name} so the tool name propagates
  # to handle_tool_result and into the event store. Without this, tool results were
  # always recorded as tool_name="unknown".

  # ACP spec: sessionUpdate field identifies the update type
  defp classify_update(%{"sessionUpdate" => "agent_message_chunk", "content" => content}) do
    text = extract_text(content)
    {:content_chunk, text}
  end

  defp classify_update(%{"sessionUpdate" => "tool_use", "toolCallId" => id} = tc) do
    {:tool_call, id, tc}
  end

  # Claude Code sends "tool_call" (not "tool_use") with status "pending"
  defp classify_update(%{"sessionUpdate" => "tool_call", "toolCallId" => id, "status" => "pending"} = tc) do
    {:tool_call, id, tc}
  end

  # ACP spec: standard tool_result notification
  defp classify_update(%{"sessionUpdate" => "tool_result", "toolCallId" => id, "result" => result} = tc) do
    tool_name = tc["toolName"] || tc["title"]
    {:tool_result, id, result, tool_name}
  end

  # Claude Code sends "tool_call_update" with status "completed" for tool results.
  # Tool name lives in _meta.claudeCode.toolName or top-level title/toolName.
  defp classify_update(%{"sessionUpdate" => "tool_call_update", "toolCallId" => id, "status" => "completed"} = tc) do
    result = get_in(tc, ["_meta", "claudeCode", "toolResponse"]) || tc["rawOutput"] || tc["content"]
    tool_name = get_in(tc, ["_meta", "claudeCode", "toolName"]) || tc["toolName"] || tc["title"]
    {:tool_result, id, result, tool_name}
  end

  # Claude Code sends "tool_call_update" with status "failed" when a tool call is
  # rejected or errors. Record as a tool result so the tool call doesn't stay "started".
  defp classify_update(%{"sessionUpdate" => "tool_call_update", "toolCallId" => id, "status" => "failed"} = tc) do
    result = get_in(tc, ["_meta", "claudeCode", "toolResponse"]) || tc["rawOutput"] || tc["content"]
    tool_name = get_in(tc, ["_meta", "claudeCode", "toolName"]) || tc["toolName"] || tc["title"]
    {:tool_result, id, result, tool_name}
  end

  # Progressive tool_call_update (input streaming) — ignore
  defp classify_update(%{"sessionUpdate" => "tool_call_update"}) do
    :ignored
  end

  # Agent thinking — ignore silently
  defp classify_update(%{"sessionUpdate" => "agent_thought_chunk"}) do
    :ignored
  end

  defp classify_update(%{"sessionUpdate" => "plan_update", "plan" => plan}) do
    {:plan, plan}
  end

  # Informational updates we can safely ignore
  defp classify_update(%{"sessionUpdate" => type})
       when type in ["available_commands_update", "usage_update", "status_update"] do
    :ignored
  end

  # Legacy/compat: flat format with "type" key
  defp classify_update(%{"type" => "agent_message_chunk", "content" => content}) do
    text = extract_text(content)
    {:content_chunk, text}
  end

  defp classify_update(%{"type" => "content_chunk", "content" => content}) do
    text = extract_text(content)
    {:content_chunk, text}
  end

  defp classify_update(update) do
    Logger.debug("ACP SessionBridge: unhandled update: #{inspect(update, limit: 200)}")
    :unknown
  end

  # -- Handlers --

  defp handle_content_chunk(stream_id, message_id, text) when is_binary(text) and text != "" do
    command =
      {:receive_chunk,
       %{
         message_id: message_id,
         chunk_index: 0,
         content_block_index: 0,
         delta_type: "text_delta",
         delta_text: text
       }}

    case Loader.execute(ConversationAggregate, stream_id, command) do
      {:ok, _state, events} -> Projector.project_events_async(stream_id, events)
      {:error, reason} -> Logger.error("ACP SessionBridge: failed to record chunk: #{inspect(reason)}")
    end

    :ok
  end

  defp handle_content_chunk(_stream_id, _message_id, _text), do: :ok

  defp handle_tool_call(stream_id, message_id, tool_call_id, tool_call) do
    tool_name =
      get_in(tool_call, ["_meta", "claudeCode", "toolName"]) ||
        tool_call["toolName"] || tool_call["title"] || tool_call["tool_name"] || "unknown"

    input = tool_call["rawInput"] || tool_call["input"] || %{}

    command =
      {:start_tool_call,
       %{
         message_id: message_id,
         tool_use_id: tool_call_id,
         tool_name: tool_name,
         input: input
       }}

    case Loader.execute(ConversationAggregate, stream_id, command) do
      {:ok, _state, events} -> Projector.project_events(stream_id, events)
      {:error, reason} -> Logger.error("ACP SessionBridge: failed to record tool call: #{inspect(reason)}")
    end

    :ok
  end

  # tool_name is extracted from the update in classify_update/1 and threaded through
  # handle_update/3 → here. Falls back to "unknown" only if no agent provided a name.
  defp handle_tool_result(stream_id, message_id, tool_call_id, result, tool_name) do
    output = normalize_output(result)

    command =
      {:complete_tool_call,
       %{
         message_id: message_id,
         tool_use_id: tool_call_id,
         tool_name: tool_name || "unknown",
         input: %{},
         output: output,
         duration_ms: 0
       }}

    case Loader.execute(ConversationAggregate, stream_id, command) do
      {:ok, _state, events} -> Projector.project_events(stream_id, events)
      {:error, reason} -> Logger.error("ACP SessionBridge: failed to record tool result: #{inspect(reason)}")
    end

    :ok
  end

  # -- Helpers --

  defp extract_text(%{"type" => "text", "text" => text}), do: text
  defp extract_text(%{"text" => text}), do: text
  defp extract_text(content) when is_binary(content), do: content
  defp extract_text(_), do: ""

  # ToolCall.output is typed as :map in the schema. ACP tool results arrive in
  # various shapes (list of content blocks, raw strings, maps). We must always
  # produce a map so the Ecto changeset cast succeeds.
  defp normalize_output(result) when is_map(result), do: result

  defp normalize_output(result) when is_list(result) do
    %{"text" => Enum.map_join(result, "\n", &extract_text/1)}
  end

  defp normalize_output(result) when is_binary(result), do: %{"text" => result}
  defp normalize_output(_), do: %{}
end
