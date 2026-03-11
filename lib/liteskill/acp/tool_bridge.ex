defmodule Liteskill.Acp.ToolBridge do
  @moduledoc """
  Handles incoming ACP requests from an external agent.

  Maps standard ACP client methods (fs/read_text_file, fs/write_text_file,
  terminal/*) to local operations, and routes session/request_permission
  to PubSub for UI approval.
  """

  require Logger

  # -- Dispatch --

  @doc """
  Dispatches an incoming ACP request from the agent to the appropriate handler.

  Returns `{:ok, result}` or `{:error, code, message}`.
  """
  def handle_request("session/request_permission", params, context) do
    if auto_approve_tool?(params) do
      Logger.debug("ACP ToolBridge: auto-approving tool: #{inspect(params, limit: 300)}")
      {:ok, Liteskill.Acp.Protocol.permission_response(:allow_once, allow_option_id(params))}
    else
      handle_permission_request(params, context)
    end
  end

  def handle_request("fs/read_text_file", params, _context) do
    handle_read_file(params)
  end

  def handle_request("fs/write_text_file", params, _context) do
    handle_write_file(params)
  end

  def handle_request("terminal/create", params, context) do
    handle_terminal_create(params, context)
  end

  def handle_request("terminal/output", params, context) do
    handle_terminal_output(params, context)
  end

  def handle_request("terminal/wait_for_exit", params, context) do
    handle_terminal_wait(params, context)
  end

  def handle_request("terminal/kill", params, context) do
    handle_terminal_kill(params, context)
  end

  def handle_request("terminal/release", params, context) do
    handle_terminal_release(params, context)
  end

  def handle_request(method, _params, _context) do
    {:error, -32_601, "Method not found: #{method}"}
  end

  # -- File System --

  defp handle_read_file(%{"path" => path} = params) do
    with :ok <- validate_absolute_path(path) do
      case File.read(path) do
        {:ok, content} ->
          content = maybe_slice_lines(content, params["line"], params["limit"])
          {:ok, %{"content" => content}}

        {:error, reason} ->
          {:error, -32_002, "File not found: #{reason}"}
      end
    end
  end

  defp handle_read_file(_), do: {:error, -32_602, "Missing required param: path"}

  defp handle_write_file(%{"path" => path, "content" => content}) do
    with :ok <- validate_absolute_path(path) do
      dir = Path.dirname(path)

      case File.mkdir_p(dir) do
        :ok ->
          case File.write(path, content) do
            :ok -> {:ok, %{}}
            {:error, reason} -> {:error, -32_603, "Write failed: #{reason}"}
          end

        {:error, reason} ->
          {:error, -32_603, "Cannot create directory: #{reason}"}
      end
    end
  end

  defp handle_write_file(_), do: {:error, -32_602, "Missing required params: path, content"}

  # -- Permissions --

  # Auto-approve MCP tool calls for our own builtin shim tools (wiki, reports, etc.).
  # The tool name prefix "mcp__Liteskill_Tools__" matches the MCP server name
  # "Liteskill Tools" as formatted by agents (spaces → underscores). If the agent
  # uses a different naming convention, auto-approve won't match and the tool call
  # will go through the UI permission modal instead — safe fallback.
  defp auto_approve_tool?(%{"toolCall" => %{"title" => name}}) when is_binary(name) do
    String.starts_with?(name, "mcp__Liteskill_Tools__")
  end

  defp auto_approve_tool?(_), do: false

  # Select the best "allow" option from the agent's permission options.
  # IMPORTANT: The returned optionId MUST be one of the optionIds sent by the agent.
  # Returning nil or an unrecognized ID causes agents to treat the response as a
  # rejection (e.g. Claude Code shows "tool use was rejected").
  # Strategy: prefer allow_once (kind) → allow_always (kind) → first option as fallback.
  defp allow_option_id(%{"options" => options}) when is_list(options) do
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

  defp allow_option_id(_), do: nil

  defp handle_permission_request(params, context) do
    session_id = params["sessionId"]
    tool_call = params["toolCall"]

    Phoenix.PubSub.broadcast(
      Liteskill.PubSub,
      "acp:permission:#{session_id}",
      {:acp_permission_request,
       %{
         "id" => context[:request_id],
         "session_id" => session_id,
         "tool_call" => tool_call,
         "options" => params["options"] || [],
         "client_pid" => context[:client_pid]
       }}
    )

    # Response is sent asynchronously after user interaction
    {:async, :permission_pending}
  end

  # -- Terminal --

  defp handle_terminal_create(%{"command" => command} = params, context) do
    args = params["args"] || []
    cwd = params["cwd"]
    env = parse_env_vars(params["env"])

    port_opts = [:binary, :exit_status, :use_stdio, :stderr_to_stdout, args: args]
    port_opts = if cwd, do: [{:cd, cwd} | port_opts], else: port_opts
    port_opts = if env == [], do: port_opts, else: [{:env, env} | port_opts]

    port = Port.open({:spawn_executable, find_executable(command)}, port_opts)
    terminal_id = Ecto.UUID.generate()

    terminals = Map.get(context, :terminals, %{})
    terminals = Map.put(terminals, terminal_id, %{port: port, output: "", exit_status: nil})

    {:ok, %{"terminalId" => terminal_id}, %{terminals: terminals}}
  end

  defp handle_terminal_create(_, _), do: {:error, -32_602, "Missing required param: command"}

  defp handle_terminal_output(%{"terminalId" => terminal_id}, context) do
    case get_in(context, [:terminals, terminal_id]) do
      nil ->
        {:error, -32_002, "Terminal not found: #{terminal_id}"}

      terminal ->
        result = %{"output" => terminal.output}
        result = if terminal.exit_status, do: Map.put(result, "exitStatus", terminal.exit_status), else: result
        {:ok, result}
    end
  end

  defp handle_terminal_output(_, _), do: {:error, -32_602, "Missing required param: terminalId"}

  defp handle_terminal_wait(%{"terminalId" => terminal_id}, context) do
    case get_in(context, [:terminals, terminal_id]) do
      nil ->
        {:error, -32_002, "Terminal not found: #{terminal_id}"}

      %{exit_status: status} when not is_nil(status) ->
        {:ok, %{"exitStatus" => status}}

      _terminal ->
        # Will be resolved when the port sends exit_status
        {:async, {:terminal_wait, terminal_id}}
    end
  end

  defp handle_terminal_wait(_, _), do: {:error, -32_602, "Missing required param: terminalId"}

  defp handle_terminal_kill(%{"terminalId" => terminal_id}, context) do
    case get_in(context, [:terminals, terminal_id]) do
      nil ->
        {:error, -32_002, "Terminal not found: #{terminal_id}"}

      %{port: port} ->
        Port.close(port)
        {:ok, %{}}
    end
  end

  defp handle_terminal_kill(_, _), do: {:error, -32_602, "Missing required param: terminalId"}

  defp handle_terminal_release(%{"terminalId" => terminal_id}, context) do
    case get_in(context, [:terminals, terminal_id]) do
      nil ->
        {:error, -32_002, "Terminal not found: #{terminal_id}"}

      %{port: port, exit_status: nil} ->
        Port.close(port)
        terminals = Map.delete(context[:terminals] || %{}, terminal_id)
        {:ok, %{}, %{terminals: terminals}}

      _terminal ->
        terminals = Map.delete(context[:terminals] || %{}, terminal_id)
        {:ok, %{}, %{terminals: terminals}}
    end
  end

  defp handle_terminal_release(_, _), do: {:error, -32_602, "Missing required param: terminalId"}

  # -- Helpers --

  defp validate_absolute_path(path) do
    if String.starts_with?(path, "/") do
      :ok
    else
      {:error, -32_602, "Path must be absolute: #{path}"}
    end
  end

  defp maybe_slice_lines(content, nil, nil), do: content

  defp maybe_slice_lines(content, line, limit) do
    lines = String.split(content, "\n")
    start = max((line || 1) - 1, 0)

    lines
    |> Enum.drop(start)
    |> then(fn l -> if limit, do: Enum.take(l, limit), else: l end)
    |> Enum.join("\n")
  end

  defp parse_env_vars(nil), do: []

  defp parse_env_vars(env_list) when is_list(env_list) do
    Enum.map(env_list, fn %{"name" => name, "value" => value} ->
      {String.to_charlist(name), String.to_charlist(value)}
    end)
  end

  defp parse_env_vars(_), do: []

  defp find_executable(command) do
    System.find_executable(command) || command
  end
end
