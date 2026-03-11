defmodule Liteskill.Acp.McpPassthrough do
  @moduledoc """
  Converts Liteskill MCP server configurations to ACP-compatible format
  for passing to external agents during session creation.
  """

  alias Liteskill.McpServers
  alias Liteskill.McpServers.McpServer

  @doc """
  Builds a list of ACP-format MCP server configs from the user's active servers.

  Filters to the given `selected_server_ids` if provided, otherwise uses all active servers.
  Returns maps suitable for `Protocol.new_session_params/2`.
  """
  def build_mcp_servers(user_id, selected_server_ids \\ nil) do
    servers = McpServers.list_servers(user_id)

    servers
    |> Enum.filter(&is_struct(&1, McpServer))
    |> maybe_filter_selected(selected_server_ids)
    |> Enum.filter(&(&1.status == "active"))
    |> Enum.map(&to_acp_format/1)
  end

  @doc """
  Converts a single McpServer to ACP HTTP format.
  """
  def to_acp_format(%McpServer{} = server) do
    headers = build_headers(server)

    %{
      type: "http",
      name: server.name,
      url: server.url,
      headers: headers
    }
  end

  defp maybe_filter_selected(servers, nil), do: servers

  defp maybe_filter_selected(servers, selected_ids) when is_struct(selected_ids, MapSet) do
    Enum.filter(servers, &MapSet.member?(selected_ids, &1.id))
  end

  defp maybe_filter_selected(servers, selected_ids) when is_list(selected_ids) do
    id_set = MapSet.new(selected_ids)
    Enum.filter(servers, &MapSet.member?(id_set, &1.id))
  end

  defp build_headers(%McpServer{api_key: api_key, headers: custom_headers}) do
    auth_headers =
      if api_key && api_key != "" do
        [{"Authorization", "Bearer #{api_key}"}]
      else
        []
      end

    custom =
      Enum.map(custom_headers || %{}, fn {k, v} -> {to_string(k), to_string(v)} end)

    auth_headers ++ custom
  end
end
