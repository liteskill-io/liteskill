defmodule Liteskill.Acp.Client do
  @moduledoc """
  GenServer managing a spawned ACP agent process over stdio.

  Handles bidirectional JSON-RPC 2.0 communication:
  - Outbound: initialize, session/new, session/prompt, session/cancel
  - Inbound: session/update notifications, request_permission, fs/*, terminal/*

  Started lazily via DynamicSupervisor when a user initiates an ACP session.
  """

  use GenServer

  alias Liteskill.Acp.Protocol
  alias Liteskill.Acp.ToolBridge

  require Logger

  @request_timeout 300_000
  @init_timeout 30_000

  # -- Public API --

  def start_link(opts) do
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Starts an ACP client for the given agent config.

  Returns `{:ok, pid}` with a fully initialized client (handshake complete).
  """
  def start_session(agent_config, user_id, opts \\ []) do
    client_opts =
      Keyword.merge(opts,
        agent_config: agent_config,
        user_id: user_id
      )

    case DynamicSupervisor.start_child(
           Liteskill.Acp.ClientSupervisor,
           {__MODULE__, client_opts}
         ) do
      {:ok, pid} ->
        case initialize(pid) do
          {:ok, _capabilities} ->
            {:ok, pid}

          {:error, reason} ->
            stop(pid)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Sends the initialize handshake to the agent.
  """
  def initialize(pid, timeout \\ @init_timeout) do
    GenServer.call(pid, :initialize, timeout)
  end

  @doc """
  Creates a new session with the agent.

  `mcp_servers` is a list of MCP server configs to pass to the agent.
  """
  def new_session(pid, cwd, mcp_servers \\ [], timeout \\ @request_timeout) do
    GenServer.call(pid, {:new_session, cwd, mcp_servers}, timeout)
  end

  @doc """
  Sends a user prompt to the agent within a session.

  Returns `{:ok, stop_reason}` when the agent finishes processing.
  Session update notifications are broadcast via PubSub during processing.
  """
  def prompt(pid, text, timeout \\ @request_timeout) do
    GenServer.call(pid, {:prompt, text}, timeout)
  end

  @doc """
  Cancels the current prompt processing.
  """
  def cancel(pid) do
    GenServer.cast(pid, :cancel)
  end

  @doc """
  Responds to a permission request from the agent.
  """
  def respond_permission(pid, request_id, outcome, option_id \\ nil) do
    GenServer.cast(pid, {:respond_permission, request_id, outcome, option_id})
  end

  @doc """
  Returns the current client status.
  """
  def status(pid) do
    GenServer.call(pid, :status)
  end

  @doc """
  Stops the client and kills the agent process.
  """
  def stop(pid) do
    GenServer.stop(pid, :normal)
  catch
    :exit, _ -> :ok
  end

  # -- GenServer Callbacks --

  @impl true
  def init(opts) do
    agent_config = Keyword.fetch!(opts, :agent_config)
    user_id = Keyword.fetch!(opts, :user_id)

    command = find_executable(agent_config.command)
    args = agent_config.args || []
    env = build_env(agent_config.env || %{})

    # ACP uses newline-delimited JSON over stdio. {:line, 1_048_576} tells the port
    # to deliver complete lines via {:eol, line} and partial data via {:noeol, chunk}.
    # Agent stderr goes to the VM's stderr (not captured) — this is intentional, as
    # agents like Claude Code use stderr for user-facing output.
    port_opts = [
      :binary,
      :exit_status,
      :use_stdio,
      {:args, args},
      {:env, env},
      {:line, 1_048_576}
    ]

    port = Port.open({:spawn_executable, command}, port_opts)

    # next_id starts at 1 for OUR outgoing request IDs. The agent has its own independent
    # ID space (often starting at 0). Both ID spaces coexist on the same stdio channel —
    # requests vs responses are distinguished by the presence of "method" vs "result"/"error".
    state = %{
      port: port,
      agent_config: agent_config,
      user_id: user_id,
      buffer: "",
      pending_requests: %{},
      next_id: 1,
      session_id: nil,
      agent_capabilities: nil,
      status: :starting,
      terminals: %{},
      waiting_permissions: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:initialize, from, %{status: :starting} = state) do
    {id, state} = next_id(state)
    params = Protocol.initialize_params()
    send_to_port(state.port, Protocol.encode_request("initialize", params, id))

    timer = Process.send_after(self(), {:request_timeout, id}, @init_timeout)
    pending = Map.put(state.pending_requests, id, {from, timer, :initialize})

    {:noreply, %{state | pending_requests: pending, status: :initializing}}
  end

  def handle_call(:initialize, _from, state) do
    {:reply, {:error, :already_initialized}, state}
  end

  @impl true
  def handle_call({:new_session, cwd, mcp_servers}, from, %{status: :ready} = state) do
    {id, state} = next_id(state)
    params = Protocol.new_session_params(cwd, mcp_servers)
    send_to_port(state.port, Protocol.encode_request("session/new", params, id))

    timer = Process.send_after(self(), {:request_timeout, id}, @request_timeout)
    pending = Map.put(state.pending_requests, id, {from, timer, :new_session})

    {:noreply, %{state | pending_requests: pending}}
  end

  @impl true
  def handle_call({:prompt, text}, from, %{session_id: session_id} = state) when not is_nil(session_id) do
    {id, state} = next_id(state)
    params = Protocol.prompt_params(session_id, text)
    send_to_port(state.port, Protocol.encode_request("session/prompt", params, id))

    timer = Process.send_after(self(), {:request_timeout, id}, @request_timeout)
    pending = Map.put(state.pending_requests, id, {from, timer, :prompt})

    {:noreply, %{state | status: :prompting, pending_requests: pending}}
  end

  def handle_call({:prompt, _text}, _from, %{session_id: nil} = state) do
    {:reply, {:error, :no_session}, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       status: state.status,
       session_id: state.session_id,
       agent_capabilities: state.agent_capabilities,
       agent_name: state.agent_config.name
     }, state}
  end

  @impl true
  def handle_cast(:cancel, %{session_id: session_id} = state) when not is_nil(session_id) do
    notification = Protocol.encode_notification("session/cancel", Protocol.cancel_params(session_id))
    send_to_port(state.port, notification)
    {:noreply, state}
  end

  def handle_cast(:cancel, state), do: {:noreply, state}

  # Called from AcpHandler after user clicks Allow/Deny in the permission modal.
  # IMPORTANT: option_id MUST be a valid optionId from the agent's original options
  # list — sending nil causes agents (e.g. Claude Code) to treat it as a rejection.
  @impl true
  def handle_cast({:respond_permission, request_id, outcome, option_id}, state) do
    case Map.pop(state.waiting_permissions, request_id) do
      {nil, _} ->
        {:noreply, state}

      {_request, permissions} ->
        response =
          case outcome do
            :allow -> Protocol.permission_response(:allow_once, option_id)
            :cancel -> Protocol.permission_response(:cancel, nil)
          end

        send_to_port(state.port, Protocol.encode_response(response, request_id))
        {:noreply, %{state | waiting_permissions: permissions}}
    end
  end

  # -- Port Messages --

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    process_line(line, state)
  end

  def handle_info({port, {:data, {:noeol, chunk}}}, %{port: port} = state) do
    {:noreply, %{state | buffer: state.buffer <> chunk}}
  end

  def handle_info({port, {:data, data}}, %{port: port} = state) when is_binary(data) do
    buffer = state.buffer <> data
    {messages, remaining} = Protocol.decode_buffer(buffer)
    state = %{state | buffer: remaining}

    state = Enum.reduce(messages, state, &handle_message/2)
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, exit_code}}, %{port: port} = state) do
    Logger.info("ACP agent exited with status #{exit_code}")

    # Reply to any pending requests with error
    state =
      Enum.reduce(state.pending_requests, state, fn {_id, {from, timer, _type}}, acc ->
        Process.cancel_timer(timer)
        GenServer.reply(from, {:error, {:agent_exited, exit_code}})
        acc
      end)

    broadcast_session_event(state, {:acp_agent_exited, exit_code})
    {:stop, :normal, %{state | port: nil, status: :stopped, pending_requests: %{}}}
  end

  def handle_info({:request_timeout, id}, state) do
    case Map.pop(state.pending_requests, id) do
      {nil, _} ->
        {:noreply, state}

      {{from, _timer, type}, pending} ->
        Logger.warning("ACP request timeout: #{type} (id=#{id})")
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | pending_requests: pending}}
    end
  end

  # Terminal port output for spawned terminals
  def handle_info({port, {:data, data}}, state) when is_port(port) do
    state = update_terminal_output(state, port, data)
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, state) when is_port(port) do
    state = update_terminal_exit(state, port, status)
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{port: port} = _state) when is_port(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  def terminate(_reason, _state), do: :ok

  # -- Message Handling --

  defp handle_message(msg, state) do
    classified = Protocol.classify(msg)
    Logger.info("ACP Client: incoming message classified=#{inspect(classified, limit: 300)}")

    case classified do
      {:response, id, result} ->
        handle_response(id, {:ok, result}, state)

      {:error_response, id, error} ->
        handle_response(id, {:error, error}, state)

      {:request, id, method, params} ->
        handle_agent_request(id, method, params, state)

      {:notification, method, params} ->
        handle_notification(method, params, state)

      {:invalid, _} ->
        Logger.warning("ACP: received invalid message")
        state
    end
  end

  defp handle_response(id, result, state) do
    case Map.pop(state.pending_requests, id) do
      {nil, _} ->
        Logger.warning("ACP: response for unknown request id=#{id}")
        state

      {{from, timer, type}, pending} ->
        Process.cancel_timer(timer)
        state = %{state | pending_requests: pending}

        case {type, result} do
          {:initialize, {:ok, caps}} ->
            GenServer.reply(from, {:ok, caps})
            %{state | agent_capabilities: caps, status: :ready}

          {:new_session, {:ok, %{"sessionId" => sid} = result}} ->
            GenServer.reply(from, {:ok, result})
            %{state | session_id: sid}

          {:prompt, {:ok, result}} ->
            Logger.info("ACP Client: prompt response received: #{inspect(result, limit: 500)}")
            GenServer.reply(from, {:ok, result})
            %{state | status: :ready}

          {_type, {:error, _} = error} ->
            GenServer.reply(from, error)
            state
        end
    end
  end

  # Permission requests use the AGENT's request IDs (independent from our outgoing IDs).
  # The response MUST echo the agent's request ID so it can correlate the response.
  # Auto-approved tools skip the UI permission modal and respond immediately.
  defp handle_agent_request(id, "session/request_permission", params, state) do
    Logger.info("ACP Client: received permission request id=#{id} tool=#{get_in(params, ["toolCall", "title"])}")
    context = %{client_pid: self(), terminals: state.terminals, request_id: id}

    case ToolBridge.handle_request("session/request_permission", params, context) do
      {:async, :permission_pending} ->
        Logger.info("ACP Client: permission pending (waiting for UI)")
        permissions = Map.put(state.waiting_permissions, id, params)
        %{state | waiting_permissions: permissions}

      {:ok, result} ->
        response_bytes = Protocol.encode_response(result, id)
        Logger.info("ACP Client: permission auto-approved, sending response: #{String.trim(response_bytes)}")
        send_to_port(state.port, response_bytes)
        state

      {:error, code, message} ->
        send_to_port(state.port, Protocol.encode_error(code, message, id))
        state
    end
  end

  defp handle_agent_request(id, method, params, state) do
    context = %{client_pid: self(), terminals: state.terminals}

    case ToolBridge.handle_request(method, params, context) do
      {:ok, result} ->
        send_to_port(state.port, Protocol.encode_response(result, id))
        state

      {:ok, result, state_updates} ->
        send_to_port(state.port, Protocol.encode_response(result, id))
        Map.merge(state, state_updates)

      {:error, code, message} ->
        send_to_port(state.port, Protocol.encode_error(code, message, id))
        state

      {:async, _} ->
        # Async responses handled via respond_permission or similar
        state
    end
  end

  defp handle_notification("session/update", params, state) do
    broadcast_session_event(state, {:acp_session_update, params})
    state
  end

  defp handle_notification(method, _params, state) do
    Logger.debug("ACP: unhandled notification #{method}")
    state
  end

  # -- Helpers --

  defp next_id(state) do
    {state.next_id, %{state | next_id: state.next_id + 1}}
  end

  defp send_to_port(port, data) when is_port(port) do
    Port.command(port, data)
  end

  defp broadcast_session_event(%{session_id: nil}, _event), do: :ok

  defp broadcast_session_event(%{session_id: session_id}, {event_type, %{} = payload}) do
    Phoenix.PubSub.broadcast(
      Liteskill.PubSub,
      "acp:session:#{session_id}",
      {event_type, Map.put(payload, :session_id, session_id)}
    )
  end

  defp broadcast_session_event(%{session_id: session_id}, event) do
    Phoenix.PubSub.broadcast(
      Liteskill.PubSub,
      "acp:session:#{session_id}",
      event
    )
  end

  defp find_executable(command) do
    System.find_executable(command) || raise "ACP agent executable not found: #{command}"
  end

  defp build_env(env) when is_map(env) do
    Enum.map(env, fn {k, v} -> {String.to_charlist(to_string(k)), String.to_charlist(to_string(v))} end)
  end

  defp update_terminal_output(state, port, data) do
    terminals =
      Enum.reduce(state.terminals, state.terminals, fn {tid, t}, acc ->
        if t.port == port do
          Map.put(acc, tid, %{t | output: t.output <> data})
        else
          acc
        end
      end)

    %{state | terminals: terminals}
  end

  defp update_terminal_exit(state, port, exit_status) do
    terminals =
      Enum.reduce(state.terminals, state.terminals, fn {tid, t}, acc ->
        if t.port == port do
          Map.put(acc, tid, %{t | exit_status: exit_status})
        else
          acc
        end
      end)

    %{state | terminals: terminals}
  end

  defp process_line(line, state) do
    full_line = state.buffer <> line

    case JSON.decode(full_line) do
      {:ok, msg} ->
        state = %{state | buffer: ""}
        state = handle_message(msg, state)
        {:noreply, state}

      {:error, _} ->
        Logger.warning("ACP: failed to decode line: #{String.slice(full_line, 0, 200)}")
        {:noreply, %{state | buffer: ""}}
    end
  end
end
