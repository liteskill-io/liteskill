# Mock ACP agent for E2E testing.
#
# Speaks ACP JSON-RPC 2.0 over stdio. Configurable via environment variables:
#
#   MOCK_ACP_BEHAVIOR  - "simple" (default) | "tool_call"
#   MOCK_ACP_RESPONSE  - text the agent returns (default: "Hello from the mock ACP agent!")
#   MOCK_ACP_TOOL_NAME - tool name for tool_call behavior (default: "mcp__Liteskill_Tools__wiki__list_spaces")

defmodule MockAcpAgent do
  @moduledoc false
  def run do
    loop()
  end

  defp loop do
    case IO.gets("") do
      :eof ->
        :ok

      {:error, _} ->
        :ok

      line when is_binary(line) ->
        line = String.trim(line)

        if line != "" do
          case JSON.decode(line) do
            {:ok, msg} -> handle(msg)
            {:error, _} -> :ok
          end
        end

        loop()
    end
  end

  # -- Message Handlers --

  defp handle(%{"method" => "initialize", "id" => id}) do
    respond(id, %{
      "protocolVersion" => 1,
      "agentInfo" => %{"name" => "Mock ACP Agent", "version" => "1.0.0"},
      "agentCapabilities" => %{}
    })
  end

  defp handle(%{"method" => "session/new", "id" => id}) do
    session_id = "mock-session-#{System.unique_integer([:positive])}"
    respond(id, %{"sessionId" => session_id})
  end

  defp handle(%{"method" => "session/prompt", "id" => id, "params" => params}) do
    session_id = params["sessionId"]
    behavior = System.get_env("MOCK_ACP_BEHAVIOR", "simple")
    response = System.get_env("MOCK_ACP_RESPONSE", "Hello from the mock ACP agent!")

    case behavior do
      "tool_call" -> handle_tool_call(session_id, id, response)
      _ -> handle_simple(session_id, id, response)
    end
  end

  defp handle(%{"method" => "session/cancel"}), do: :ok
  defp handle(%{"method" => "notifications/" <> _}), do: :ok
  defp handle(_), do: :ok

  # -- Behaviors --

  defp handle_simple(session_id, request_id, response_text) do
    send_content(session_id, response_text)
    respond(request_id, %{"stopReason" => "end_turn"})
  end

  defp handle_tool_call(session_id, request_id, response_text) do
    tool_call_id = "mock-tc-#{System.unique_integer([:positive])}"
    tool_name = System.get_env("MOCK_ACP_TOOL_NAME", "mcp__Liteskill_Tools__wiki__list_spaces")

    # 1. Notify: tool call started (pending)
    notify("session/update", %{
      "sessionId" => session_id,
      "update" => %{
        "sessionUpdate" => "tool_call",
        "toolCallId" => tool_call_id,
        "status" => "pending",
        "_meta" => %{"claudeCode" => %{"toolName" => tool_name}},
        "rawInput" => %{},
        "content" => [],
        "title" => tool_name
      }
    })

    # 2. Request permission
    send_line(
      JSON.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 0,
        "method" => "session/request_permission",
        "params" => %{
          "sessionId" => session_id,
          "toolCall" => %{
            "title" => tool_name,
            "toolCallId" => tool_call_id,
            "rawInput" => %{},
            "content" => [],
            "kind" => "other"
          },
          "options" => [
            %{"kind" => "allow_always", "name" => "Always Allow", "optionId" => "allow_always"},
            %{"kind" => "allow_once", "name" => "Allow", "optionId" => "allow"},
            %{"kind" => "reject_once", "name" => "Reject", "optionId" => "reject"}
          ]
        }
      })
    )

    # 3. Wait for permission response
    wait_for_response(0)

    # 4. Notify: tool call completed
    notify("session/update", %{
      "sessionId" => session_id,
      "update" => %{
        "sessionUpdate" => "tool_call_update",
        "toolCallId" => tool_call_id,
        "status" => "completed",
        "_meta" => %{
          "claudeCode" => %{
            "toolName" => tool_name,
            "toolResponse" => "Tool executed successfully"
          }
        },
        "rawOutput" => "Tool executed successfully",
        "content" => [
          %{"type" => "content", "content" => %{"type" => "text", "text" => "Tool executed successfully"}}
        ]
      }
    })

    # 5. Send final content
    send_content(session_id, response_text)

    # 6. Respond to the prompt
    respond(request_id, %{"stopReason" => "end_turn"})
  end

  # -- Helpers --

  defp wait_for_response(expected_id) do
    case IO.gets("") do
      :eof ->
        :ok

      {:error, _} ->
        :ok

      line when is_binary(line) ->
        line = String.trim(line)

        case JSON.decode(line) do
          {:ok, %{"id" => ^expected_id, "result" => _}} -> :ok
          {:ok, %{"id" => ^expected_id, "error" => _}} -> :ok
          _ -> wait_for_response(expected_id)
        end
    end
  end

  defp send_content(session_id, text) do
    notify("session/update", %{
      "sessionId" => session_id,
      "update" => %{
        "sessionUpdate" => "agent_message_chunk",
        "content" => %{"type" => "text", "text" => text}
      }
    })
  end

  defp respond(id, result) do
    send_line(JSON.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result}))
  end

  defp notify(method, params) do
    send_line(JSON.encode!(%{"jsonrpc" => "2.0", "method" => method, "params" => params}))
  end

  defp send_line(json) do
    IO.write(:stdio, json <> "\n")
  end
end

MockAcpAgent.run()
