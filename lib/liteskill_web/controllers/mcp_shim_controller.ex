defmodule LiteskillWeb.McpShimController do
  @moduledoc """
  MCP Streamable HTTP endpoint exposing Liteskill builtin tools to ACP agents.

  Implements the minimal MCP protocol (initialize, tools/list, tools/call) so that
  ACP agents can discover and call builtin tools (wiki, reports, deep research)
  via standard MCP HTTP transport.

  Authentication is via short-lived Phoenix.Token passed as a Bearer header.
  """

  use LiteskillWeb, :controller

  alias Liteskill.BuiltinTools

  require Logger

  @salt "acp_mcp_token"
  @max_age 3600

  @acp_exposed_suites [
    BuiltinTools.Wiki,
    BuiltinTools.Reports,
    BuiltinTools.DeepResearch
  ]

  @doc """
  Generates a short-lived bearer token encoding the user_id.
  """
  def generate_token(user_id) do
    Phoenix.Token.sign(LiteskillWeb.Endpoint, @salt, user_id)
  end

  def handle(conn, _params) do
    with {:ok, user_id} <- verify_token(conn),
         {:ok, body} <- read_body_json(conn) do
      dispatch(conn, body, user_id)
    else
      {:error, :unauthorized} ->
        conn |> put_status(401) |> json(%{"error" => "unauthorized"})

      # coveralls-ignore-start — Plug.Parsers always populates body_params in :api pipeline
      {:error, :bad_request} ->
        conn |> put_status(400) |> json(%{"error" => "invalid JSON body"})
        # coveralls-ignore-stop
    end
  end

  # -- MCP Method Dispatch --

  defp dispatch(conn, %{"method" => "initialize", "id" => id}, _user_id) do
    session_id = Ecto.UUID.generate()

    result = %{
      "protocolVersion" => "2025-03-26",
      "capabilities" => %{"tools" => %{}},
      "serverInfo" => %{"name" => "Liteskill Tools", "version" => app_version()}
    }

    conn
    |> put_resp_header("mcp-session-id", session_id)
    |> json(jsonrpc_result(id, result))
  end

  defp dispatch(conn, %{"method" => "notifications/initialized"}, _user_id) do
    send_resp(conn, 200, "")
  end

  defp dispatch(conn, %{"method" => "tools/list", "id" => id}, _user_id) do
    tools =
      Enum.flat_map(@acp_exposed_suites, fn mod ->
        Enum.map(mod.list_tools(), fn tool ->
          %{
            "name" => tool["name"],
            "description" => tool["description"],
            "inputSchema" => tool["inputSchema"]
          }
        end)
      end)

    json(conn, jsonrpc_result(id, %{"tools" => tools}))
  end

  defp dispatch(conn, %{"method" => "tools/call", "id" => id, "params" => params}, user_id) do
    tool_name = params["name"]
    arguments = params["arguments"] || %{}

    case BuiltinTools.find_handler(tool_name) do
      nil ->
        json(conn, jsonrpc_error(id, -32_602, "Unknown tool: #{tool_name}"))

      module ->
        case module.call_tool(tool_name, arguments, user_id: user_id) do
          {:ok, result} ->
            json(conn, jsonrpc_result(id, result))

          # coveralls-ignore-start — builtin tools wrap errors in {:ok, ...} via wrap_result
          {:error, reason} ->
            error_msg = if is_binary(reason), do: reason, else: inspect(reason)
            json(conn, jsonrpc_error(id, -32_603, error_msg))
            # coveralls-ignore-stop
        end
    end
  end

  defp dispatch(conn, %{"method" => method, "id" => id}, _user_id) do
    json(conn, jsonrpc_error(id, -32_601, "Method not found: #{method}"))
  end

  # coveralls-ignore-start — requires sending body without "method" key, which dispatch/3 above catches
  defp dispatch(conn, _body, _user_id) do
    conn |> put_status(400) |> json(%{"error" => "invalid request"})
  end

  # coveralls-ignore-stop

  # -- Auth --

  defp verify_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        case Phoenix.Token.verify(LiteskillWeb.Endpoint, @salt, token, max_age: @max_age) do
          {:ok, user_id} -> {:ok, user_id}
          {:error, _reason} -> {:error, :unauthorized}
        end

      _ ->
        {:error, :unauthorized}
    end
  end

  defp read_body_json(conn) do
    case conn.body_params do
      # coveralls-ignore-start — Plug.Parsers always fetches body_params in :api pipeline
      %Plug.Conn.Unfetched{} ->
        {:error, :bad_request}

      # coveralls-ignore-stop
      %{} = params when map_size(params) > 0 ->
        {:ok, params}

      # coveralls-ignore-start — Plug.Parsers always produces a non-empty map for valid JSON
      _ ->
        {:error, :bad_request}
        # coveralls-ignore-stop
    end
  end

  # -- JSON-RPC Helpers --

  defp jsonrpc_result(id, result) do
    %{"jsonrpc" => "2.0", "id" => id, "result" => result}
  end

  defp jsonrpc_error(id, code, message) do
    %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}
  end

  defp app_version do
    :liteskill |> Application.spec(:vsn) |> to_string()
  end
end
