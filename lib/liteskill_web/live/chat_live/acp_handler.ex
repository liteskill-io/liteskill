defmodule LiteskillWeb.ChatLive.AcpHandler do
  @moduledoc false

  use Phoenix.Component

  import LiteskillWeb.ErrorHelpers, only: [action_error: 2]
  import Phoenix.LiveView, only: [push_patch: 2, put_flash: 3]

  alias Liteskill.Acp
  alias Liteskill.Acp.McpPassthrough
  alias Liteskill.Acp.SessionBridge
  alias Liteskill.Chat

  require Logger

  # -- Components --

  attr :request, :map, required: true

  def permission_modal(assigns) do
    ~H"""
    <div class="modal modal-open">
      <div class="modal-box">
        <h3 class="font-bold text-lg">Agent Permission Request</h3>
        <p class="py-4 text-sm">
          The ACP agent is requesting permission:
        </p>
        <div class="bg-base-200 rounded-lg p-3 text-sm font-mono mb-4">
          {@request["description"] || @request["method"] || "Unknown action"}
        </div>
        <div class="modal-action">
          <button phx-click="reject_acp_permission" class="btn btn-ghost btn-sm">
            Deny
          </button>
          <button phx-click="approve_acp_permission" class="btn btn-primary btn-sm">
            Allow
          </button>
        </div>
      </div>
      <div class="modal-backdrop" phx-click="reject_acp_permission"></div>
    </div>
    """
  end

  @events ~w(send_acp_message approve_acp_permission reject_acp_permission)

  def events, do: @events

  def assigns do
    [
      acp_mode: false,
      acp_agent_configs: [],
      acp_agent_config_id: nil,
      acp_client_pid: nil,
      acp_session_id: nil,
      acp_message_id: nil,
      acp_permission_request: nil
    ]
  end

  @doc false
  def cleanup_acp_session_public(socket), do: cleanup_acp_session(socket)

  def handle_event("send_acp_message", %{"message" => %{"content" => content}}, socket) do
    content = String.trim(content)

    cond do
      content == "" ->
        {:noreply, socket}

      socket.assigns.acp_agent_config_id == nil ->
        {:noreply, put_flash(socket, :error, "No ACP agent selected.")}

      true ->
        send_to_acp_agent(content, socket)
    end
  end

  def handle_event("approve_acp_permission", _params, socket) do
    respond_permission(socket, true)
  end

  def handle_event("reject_acp_permission", _params, socket) do
    respond_permission(socket, false)
  end

  def handle_info({:acp_session_update, update}, socket) do
    if socket.assigns.acp_message_id do
      stream_id = socket.assigns.conversation.stream_id
      SessionBridge.handle_update(stream_id, socket.assigns.acp_message_id, update)
    end

    # Update stream_content for live UI rendering
    socket = maybe_append_stream_content(socket, update)
    {:noreply, socket}
  end

  def handle_info({:acp_session_complete, result}, socket) do
    if socket.assigns.acp_message_id do
      stream_id = socket.assigns.conversation.stream_id
      full_content = result["content"] || socket.assigns[:stream_content] || ""
      stop_reason = result["stopReason"] || "end_turn"

      SessionBridge.complete_stream(stream_id, socket.assigns.acp_message_id, full_content, stop_reason: stop_reason)
    end

    {:noreply, reload_after_acp_complete(socket)}
  end

  def handle_info({:acp_session_error, error}, socket) do
    error_message = if is_binary(error), do: error, else: inspect(error)

    if socket.assigns.acp_message_id do
      stream_id = socket.assigns.conversation.stream_id
      SessionBridge.fail_stream(stream_id, socket.assigns.acp_message_id, error_message)
    end

    {:noreply,
     assign(socket,
       streaming: false,
       stream_error: %{title: "ACP agent error", detail: error_message},
       acp_message_id: nil
     )}
  end

  def handle_info({:acp_session_ready, {:ok, pid, session_id}}, socket) do
    # Subscribe to PubSub BEFORE sending the prompt so we receive all updates.
    # On session reuse (second+ message), session_id is nil because ensure_session/3
    # returns {:ok, existing_pid, nil}. In that case we skip re-subscribing (already
    # subscribed from the first message) and MUST preserve the existing acp_session_id
    # — overwriting with nil would break cleanup_acp_session/1.
    if session_id do
      Phoenix.PubSub.subscribe(Liteskill.PubSub, "acp:session:#{session_id}")
      Phoenix.PubSub.subscribe(Liteskill.PubSub, "acp:permission:#{session_id}")
      Process.monitor(pid)
    end

    socket =
      assign(socket,
        acp_client_pid: pid,
        acp_session_id: session_id || socket.assigns[:acp_session_id]
      )

    # Now send the prompt — we're subscribed and will receive updates in real-time
    lv_pid = self()
    content = socket.assigns[:acp_pending_content]

    Task.Supervisor.start_child(Liteskill.TaskSupervisor, fn ->
      case Acp.Client.prompt(pid, content) do
        {:ok, result} -> send(lv_pid, {:acp_prompt_complete, result})
        {:error, reason} -> send(lv_pid, {:acp_session_error, inspect(reason)})
      end
    end)

    {:noreply, assign(socket, acp_pending_content: nil)}
  end

  def handle_info({:acp_session_ready, {:error, reason}}, socket) do
    # Delegate to the existing error handler
    handle_info({:acp_client_started, {:error, reason}}, socket)
  end

  def handle_info({:acp_prompt_complete, result}, socket) do
    if socket.assigns.acp_message_id do
      stream_id = socket.assigns.conversation.stream_id
      stop_reason = result["stopReason"] || "end_turn"
      full_content = socket.assigns[:stream_content] || ""

      SessionBridge.complete_stream(stream_id, socket.assigns.acp_message_id, full_content, stop_reason: stop_reason)
    end

    {:noreply, reload_after_acp_complete(socket)}
  end

  def handle_info({:acp_client_started, {:error, reason}}, socket) do
    error_message = inspect(reason)
    Logger.error("ACP client startup failed: #{error_message}")

    # Fail the stream if one is active
    if socket.assigns.acp_message_id && socket.assigns[:conversation] do
      stream_id = socket.assigns.conversation.stream_id
      SessionBridge.fail_stream(stream_id, socket.assigns.acp_message_id, error_message)
    end

    {:noreply,
     assign(socket,
       streaming: false,
       stream_error: %{title: "ACP agent failed to start", detail: error_message},
       acp_message_id: nil
     )}
  end

  def handle_info({:acp_permission_request, request}, socket) do
    # Auto-approve MCP tool calls for our builtin shim tools
    if auto_approve_tool?(request) do
      respond_permission(socket, true, request)
    else
      {:noreply, assign(socket, acp_permission_request: request)}
    end
  end

  # -- Private --

  defp send_to_acp_agent(content, socket) do
    case ensure_conversation(content, socket) do
      {:ok, socket} ->
        do_send_acp_prompt(content, socket)

      {:error, reason, socket} ->
        {:noreply, put_flash(socket, :error, action_error("create conversation", reason))}
    end
  rescue
    e ->
      Logger.error("ACP send failed: #{Exception.message(e)}")
      {:noreply, put_flash(socket, :error, "Failed to send to ACP agent.")}
  end

  defp ensure_conversation(content, socket) do
    case socket.assigns.conversation do
      nil ->
        user_id = socket.assigns.current_user.id

        create_params = %{
          user_id: user_id,
          title: LiteskillWeb.ChatLive.Helpers.truncate_title(content),
          llm_model_id: socket.assigns[:selected_llm_model_id]
        }

        case Chat.create_conversation(create_params) do
          {:ok, conversation} ->
            # Subscribe for real-time tool call updates via event store + projector
            Phoenix.PubSub.subscribe(Liteskill.PubSub, "event_store:#{conversation.stream_id}")
            Phoenix.PubSub.subscribe(Liteskill.PubSub, "projector:#{conversation.stream_id}")

            # Update sidebar conversations list
            conversations = Chat.list_conversations(user_id)

            {:ok, assign(socket, conversation: conversation, conversations: conversations)}

          {:error, reason} ->
            {:error, reason, socket}
        end

      _conversation ->
        {:ok, socket}
    end
  end

  @doc """
  Starts an ACP prompt for an already-sent user message (e.g. after edit).
  Skips Chat.send_message since the message already exists.
  """
  def prompt_after_edit(content, socket) do
    start_acp_stream_and_prompt(content, socket)
  end

  defp do_send_acp_prompt(content, socket) do
    user_id = socket.assigns.current_user.id
    conversation = socket.assigns.conversation

    case Chat.send_message(conversation.id, user_id, content) do
      {:ok, _message} ->
        start_acp_stream_and_prompt(content, socket)

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, action_error("send message", reason))}
    end
  end

  defp start_acp_stream_and_prompt(content, socket) do
    user_id = socket.assigns.current_user.id
    conversation = socket.assigns.conversation
    stream_id = conversation.stream_id

    case SessionBridge.start_stream(stream_id, model_id: "acp-agent") do
      {:ok, message_id} ->
        {:ok, messages} = Chat.list_messages(conversation.id, user_id)

        # Phase 1: Setup session async (prompt sent in Phase 2 after PubSub subscribe)
        lv_pid = self()
        agent_config_id = socket.assigns.acp_agent_config_id
        acp_client_pid = socket.assigns.acp_client_pid

        Task.Supervisor.start_child(Liteskill.TaskSupervisor, fn ->
          result = ensure_session(acp_client_pid, agent_config_id, user_id)
          send(lv_pid, {:acp_session_ready, result})
        end)

        # Update URL if we were on the index page (new conversation)
        socket =
          if socket.assigns.live_action == :index do
            push_patch(socket, to: "/c/#{conversation.id}")
          else
            socket
          end

        {:noreply,
         assign(socket,
           messages: messages,
           form: Phoenix.Component.to_form(%{"content" => ""}, as: :message),
           streaming: true,
           stream_content: "",
           stream_error: nil,
           pending_tool_calls: [],
           acp_message_id: message_id,
           acp_pending_content: content
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, action_error("start ACP stream", reason))}
    end
  end

  # Phase 1: Setup session only (runs in a Task).
  # On reuse, returns {:ok, pid, nil} — the nil session_id signals to the caller
  # (handle_info :acp_session_ready) that it should preserve the existing session_id
  # in socket assigns rather than overwriting it.
  defp ensure_session(existing_pid, agent_config_id, user_id) do
    if existing_pid && Process.alive?(existing_pid) do
      {:ok, existing_pid, nil}
    else
      mcp_servers = build_acp_mcp_servers(user_id)

      with {:ok, config} <- Acp.get_agent_config(agent_config_id, user_id),
           {:ok, pid} <- Acp.Client.start_session(config, user_id),
           {:ok, session_result} <- Acp.Client.new_session(pid, File.cwd!(), mcp_servers) do
        session_id = session_result["sessionId"]
        {:ok, pid, session_id}
      else
        {:error, reason} ->
          Logger.error("ACP client failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  defp build_acp_mcp_servers(user_id) do
    external = McpPassthrough.build_mcp_servers(user_id)
    builtin_shim = build_builtin_shim_server(user_id)
    [builtin_shim | external]
  end

  defp build_builtin_shim_server(user_id) do
    token = LiteskillWeb.McpShimController.generate_token(user_id)
    base_url = LiteskillWeb.Endpoint.url()

    %{
      type: "http",
      name: "Liteskill Tools",
      url: "#{base_url}/api/mcp/shim",
      headers: [{"Authorization", "Bearer #{token}"}]
    }
  end

  # Auto-approve tool calls for builtin Liteskill tools (wiki, reports, etc.)
  defp auto_approve_tool?(%{"tool_call" => tool_call}) when is_map(tool_call) do
    name =
      tool_call["toolName"] || tool_call["tool_name"] || tool_call["name"] ||
        tool_call["title"] || ""

    String.starts_with?(name, "mcp__Liteskill_Tools__")
  end

  defp auto_approve_tool?(_), do: false

  defp respond_permission(socket, approved, request \\ nil) do
    outcome = if approved, do: :allow, else: :cancel
    request = request || socket.assigns.acp_permission_request

    case {socket.assigns.acp_client_pid, request} do
      {pid, %{"id" => request_id} = req} when is_pid(pid) ->
        # IMPORTANT: option_id MUST be a valid optionId from the request's options list.
        # Sending nil causes the agent to treat the response as a rejection.
        option_id = if approved, do: find_allow_option_id(req["options"]), else: find_reject_option_id(req["options"])
        Acp.Client.respond_permission(pid, request_id, outcome, option_id)
        {:noreply, assign(socket, acp_permission_request: nil)}

      _ ->
        {:noreply, socket}
    end
  end

  # Extracts the best "allow" optionId from the agent's permission options.
  # Agents provide options with "kind" indicating the semantics. Prefer allow_once
  # over allow_always to avoid blanket approvals.
  defp find_allow_option_id(options) when is_list(options) do
    case Enum.find(options, fn opt -> opt["kind"] == "allow_once" end) do
      %{"optionId" => id} ->
        id

      nil ->
        case Enum.find(options, fn opt -> opt["kind"] == "allow_always" end) do
          %{"optionId" => id} -> id
          nil -> nil
        end
    end
  end

  defp find_allow_option_id(_), do: nil

  defp find_reject_option_id(options) when is_list(options) do
    case Enum.find(options, fn opt -> opt["kind"] == "reject_once" end) do
      %{"optionId" => id} -> id
      nil -> nil
    end
  end

  defp find_reject_option_id(_), do: nil

  defp reload_after_acp_complete(socket) do
    conversation = socket.assigns.conversation
    user_id = socket.assigns.current_user.id

    # Small delay to let the projector finish writing
    Process.sleep(50)

    {:ok, messages} = Chat.list_messages(conversation.id, user_id)

    assign(socket,
      streaming: false,
      stream_content: "",
      acp_message_id: nil,
      messages: messages,
      pending_tool_calls: []
    )
  end

  defp maybe_append_stream_content(socket, %{
         "update" => %{"sessionUpdate" => "agent_message_chunk", "content" => content}
       }) do
    text =
      case content do
        %{"text" => t} when is_binary(t) -> t
        t when is_binary(t) -> t
        _ -> ""
      end

    if text == "" do
      socket
    else
      assign(socket, stream_content: (socket.assigns[:stream_content] || "") <> text)
    end
  end

  # Insert tool call position marker into stream_content when a tool call starts
  defp maybe_append_stream_content(socket, %{
         "update" => %{"sessionUpdate" => type, "toolCallId" => id, "status" => "pending"}
       })
       when type in ["tool_use", "tool_call"] do
    marker = "\n<!-- tc:#{id} -->\n"
    assign(socket, stream_content: (socket.assigns[:stream_content] || "") <> marker)
  end

  defp maybe_append_stream_content(socket, _update), do: socket

  # Called on LiveView unmount / navigation away. Requires acp_session_id to be
  # non-nil for PubSub cleanup — this is why ensure_session reuse must NOT overwrite
  # acp_session_id with nil (see handle_info :acp_session_ready).
  defp cleanup_acp_session(socket) do
    if socket.assigns[:acp_session_id] do
      Phoenix.PubSub.unsubscribe(Liteskill.PubSub, "acp:session:#{socket.assigns.acp_session_id}")
      Phoenix.PubSub.unsubscribe(Liteskill.PubSub, "acp:permission:#{socket.assigns.acp_session_id}")
    end

    if socket.assigns[:acp_client_pid] && Process.alive?(socket.assigns.acp_client_pid) do
      Acp.Client.stop(socket.assigns.acp_client_pid)
    end
  end
end
