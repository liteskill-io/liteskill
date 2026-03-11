defmodule Liteskill.Acp.Protocol do
  @moduledoc """
  JSON-RPC 2.0 encoding/decoding for the Agent Client Protocol.

  Handles framing (newline-delimited JSON) and message construction
  for bidirectional stdio communication with ACP agents.
  """

  @jsonrpc_version "2.0"

  # -- Encoding (outgoing messages) --

  @doc """
  Encodes a JSON-RPC request (expects a response).
  """
  def encode_request(method, params, id) do
    %{"jsonrpc" => @jsonrpc_version, "method" => method, "params" => params, "id" => id}
    |> JSON.encode!()
    |> frame()
  end

  @doc """
  Encodes a JSON-RPC notification (no response expected).
  """
  def encode_notification(method, params) do
    %{"jsonrpc" => @jsonrpc_version, "method" => method, "params" => params}
    |> JSON.encode!()
    |> frame()
  end

  @doc """
  Encodes a JSON-RPC success response.
  """
  def encode_response(result, id) do
    %{"jsonrpc" => @jsonrpc_version, "result" => result, "id" => id}
    |> JSON.encode!()
    |> frame()
  end

  @doc """
  Encodes a JSON-RPC error response.
  """
  def encode_error(code, message, id, data \\ nil) do
    error = %{"code" => code, "message" => message}
    error = if data, do: Map.put(error, "data", data), else: error

    %{"jsonrpc" => @jsonrpc_version, "error" => error, "id" => id}
    |> JSON.encode!()
    |> frame()
  end

  # -- Decoding (incoming messages) --

  @doc """
  Extracts complete JSON-RPC messages from a buffer.

  Returns `{messages, remaining_buffer}` where messages is a list of
  decoded maps and remaining_buffer is any incomplete trailing data.
  """
  def decode_buffer(buffer) do
    lines = String.split(buffer, "\n")
    {complete, [remaining]} = Enum.split(lines, -1)

    messages =
      complete
      |> Enum.reject(&(&1 == ""))
      |> Enum.flat_map(fn line ->
        case JSON.decode(line) do
          {:ok, msg} -> [msg]
          {:error, _} -> []
        end
      end)

    {messages, remaining}
  end

  @doc """
  Classifies a decoded JSON-RPC message.

  Returns one of:
  - `{:response, id, result}` — response to our request
  - `{:error_response, id, error}` — error response to our request
  - `{:request, id, method, params}` — incoming request from agent
  - `{:notification, method, params}` — incoming notification from agent
  - `{:invalid, message}` — unrecognized message
  """
  def classify(%{"id" => id, "result" => result}), do: {:response, id, result}

  def classify(%{"id" => id, "error" => error}) when is_map(error), do: {:error_response, id, error}

  def classify(%{"id" => id, "method" => method} = msg), do: {:request, id, method, msg["params"] || %{}}

  def classify(%{"method" => method} = msg), do: {:notification, method, msg["params"] || %{}}

  def classify(msg), do: {:invalid, msg}

  # -- ACP Request Builders --

  @doc """
  Builds initialize request params.
  """
  def initialize_params(client_capabilities \\ %{}) do
    %{
      "protocolVersion" => 1,
      "clientInfo" => %{"name" => "liteskill", "version" => app_version()},
      "clientCapabilities" => Map.merge(default_client_capabilities(), client_capabilities)
    }
  end

  @doc """
  Builds session/new request params.
  """
  def new_session_params(cwd, mcp_servers \\ []) do
    %{
      "cwd" => cwd,
      "mcpServers" => Enum.map(mcp_servers, &encode_mcp_server/1)
    }
  end

  @doc """
  Builds session/prompt request params.
  """
  def prompt_params(session_id, text) do
    %{
      "sessionId" => session_id,
      "prompt" => [%{"type" => "text", "text" => text}]
    }
  end

  @doc """
  Builds session/cancel notification params.
  """
  def cancel_params(session_id) do
    %{"sessionId" => session_id}
  end

  @doc """
  Builds a permission response for request_permission.

  CRITICAL: `option_id` must be one of the optionIds from the agent's original
  permission request options list. Passing nil or an unrecognized value causes
  agents to treat the response as a rejection.
  """
  def permission_response(:allow_once, option_id) do
    %{"outcome" => %{"outcome" => "selected", "optionId" => option_id}}
  end

  def permission_response(:cancel, _option_id) do
    %{"outcome" => %{"outcome" => "cancelled"}}
  end

  # -- ACP Error Codes --

  def error_parse, do: -32_700
  def error_invalid_request, do: -32_600
  def error_method_not_found, do: -32_601
  def error_invalid_params, do: -32_602
  def error_internal, do: -32_603
  def error_auth_required, do: -32_000
  def error_not_found, do: -32_002

  # -- Private --

  defp app_version do
    :liteskill |> Application.spec(:vsn) |> to_string()
  end

  defp frame(json), do: json <> "\n"

  defp default_client_capabilities do
    %{
      "fs" => %{"readTextFile" => true, "writeTextFile" => true},
      "terminal" => true
    }
  end

  defp encode_mcp_server(%{type: "http", name: name, url: url, headers: headers}) do
    %{
      "type" => "http",
      "name" => name,
      "url" => url,
      "headers" => Enum.map(headers || [], fn {k, v} -> %{"name" => k, "value" => v} end)
    }
  end

  defp encode_mcp_server(%{type: "stdio", name: name, command: command, args: args, env: env}) do
    %{
      "type" => "stdio",
      "name" => name,
      "command" => command,
      "args" => args || [],
      "env" => Enum.map(env || [], fn {k, v} -> %{"name" => k, "value" => v} end)
    }
  end

  defp encode_mcp_server(%{name: name, url: url} = server) do
    encode_mcp_server(%{type: "http", name: name, url: url, headers: server[:headers]})
  end
end
