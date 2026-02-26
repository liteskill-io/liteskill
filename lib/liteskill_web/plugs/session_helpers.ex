defmodule LiteskillWeb.Plugs.SessionHelpers do
  @moduledoc """
  Shared helpers for extracting client metadata from connections.
  """

  @max_user_agent_length 512

  @doc """
  Extracts the client IP address from x-forwarded-for header or remote_ip.
  """
  def client_ip(conn) do
    case Plug.Conn.get_req_header(conn, "x-forwarded-for") do
      [forwarded | _] ->
        forwarded
        |> String.split(",")
        |> List.first()
        |> String.trim()

      [] ->
        conn.remote_ip
        |> :inet.ntoa()
        |> to_string()
    end
  end

  @doc """
  Extracts the user-agent header, truncated to #{@max_user_agent_length} characters.
  """
  def client_user_agent(conn) do
    case Plug.Conn.get_req_header(conn, "user-agent") do
      [ua | _] -> String.slice(ua, 0, @max_user_agent_length)
      [] -> nil
    end
  end
end
