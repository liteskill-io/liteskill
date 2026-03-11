defmodule Liteskill.Acp.ProtocolTest do
  use ExUnit.Case, async: true

  alias Liteskill.Acp.Protocol

  describe "encode_request/3" do
    test "produces valid JSON-RPC request with newline" do
      result = Protocol.encode_request("session/prompt", %{"text" => "hi"}, 1)
      assert String.ends_with?(result, "\n")

      {:ok, decoded} = JSON.decode(String.trim(result))
      assert decoded["jsonrpc"] == "2.0"
      assert decoded["method"] == "session/prompt"
      assert decoded["params"] == %{"text" => "hi"}
      assert decoded["id"] == 1
    end
  end

  describe "encode_notification/2" do
    test "produces JSON-RPC notification without id" do
      result = Protocol.encode_notification("session/cancel", %{"sessionId" => "abc"})
      {:ok, decoded} = JSON.decode(String.trim(result))

      assert decoded["jsonrpc"] == "2.0"
      assert decoded["method"] == "session/cancel"
      assert decoded["params"] == %{"sessionId" => "abc"}
      refute Map.has_key?(decoded, "id")
    end
  end

  describe "encode_response/2" do
    test "produces success response" do
      result = Protocol.encode_response(%{"ok" => true}, 5)
      {:ok, decoded} = JSON.decode(String.trim(result))

      assert decoded["result"] == %{"ok" => true}
      assert decoded["id"] == 5
    end
  end

  describe "encode_error/3" do
    test "produces error response" do
      result = Protocol.encode_error(-32_601, "Method not found", 3)
      {:ok, decoded} = JSON.decode(String.trim(result))

      assert decoded["error"]["code"] == -32_601
      assert decoded["error"]["message"] == "Method not found"
      assert decoded["id"] == 3
      refute Map.has_key?(decoded["error"], "data")
    end

    test "includes data when provided" do
      result = Protocol.encode_error(-32_603, "Internal error", 4, %{"detail" => "oops"})
      {:ok, decoded} = JSON.decode(String.trim(result))

      assert decoded["error"]["data"] == %{"detail" => "oops"}
    end
  end

  describe "decode_buffer/1" do
    test "decodes complete messages" do
      line1 = ~s({"jsonrpc":"2.0","method":"test","id":1})
      line2 = ~s({"jsonrpc":"2.0","result":"ok","id":2})
      buffer = line1 <> "\n" <> line2 <> "\n"

      {messages, remaining} = Protocol.decode_buffer(buffer)

      assert length(messages) == 2
      assert Enum.at(messages, 0)["method"] == "test"
      assert Enum.at(messages, 1)["result"] == "ok"
      assert remaining == ""
    end

    test "returns incomplete trailing data as remaining" do
      buffer = ~s({"jsonrpc":"2.0","id":1,"result":"ok"}\n{"incomplete)

      {messages, remaining} = Protocol.decode_buffer(buffer)

      assert length(messages) == 1
      assert remaining == ~s({"incomplete)
    end

    test "skips invalid JSON lines" do
      buffer = "not json\n" <> ~s({"jsonrpc":"2.0","id":1,"result":"ok"}\n)

      {messages, _remaining} = Protocol.decode_buffer(buffer)
      assert length(messages) == 1
    end

    test "handles empty buffer" do
      {messages, remaining} = Protocol.decode_buffer("")
      assert messages == []
      assert remaining == ""
    end
  end

  describe "classify/1" do
    test "classifies response" do
      assert {:response, 1, %{"ok" => true}} =
               Protocol.classify(%{"jsonrpc" => "2.0", "id" => 1, "result" => %{"ok" => true}})
    end

    test "classifies error response" do
      assert {:error_response, 2, %{"code" => -32_601}} =
               Protocol.classify(%{"jsonrpc" => "2.0", "id" => 2, "error" => %{"code" => -32_601}})
    end

    test "classifies incoming request" do
      assert {:request, 3, "fs/read_text_file", %{"path" => "/tmp/x"}} =
               Protocol.classify(%{
                 "jsonrpc" => "2.0",
                 "id" => 3,
                 "method" => "fs/read_text_file",
                 "params" => %{"path" => "/tmp/x"}
               })
    end

    test "classifies notification" do
      assert {:notification, "session/update", %{"data" => "x"}} =
               Protocol.classify(%{
                 "jsonrpc" => "2.0",
                 "method" => "session/update",
                 "params" => %{"data" => "x"}
               })
    end

    test "classifies invalid message" do
      assert {:invalid, %{"foo" => "bar"}} = Protocol.classify(%{"foo" => "bar"})
    end

    test "defaults params to empty map for requests" do
      assert {:request, 1, "test", %{}} =
               Protocol.classify(%{"jsonrpc" => "2.0", "id" => 1, "method" => "test"})
    end
  end

  describe "initialize_params/1" do
    test "builds with default capabilities" do
      params = Protocol.initialize_params()

      assert params["protocolVersion"] == 1
      assert params["clientInfo"]["name"] == "liteskill"
      assert params["clientCapabilities"]["fs"]["readTextFile"] == true
      assert params["clientCapabilities"]["terminal"] == true
    end

    test "merges custom capabilities" do
      params = Protocol.initialize_params(%{"fs" => %{"readTextFile" => false}})

      assert params["clientCapabilities"]["fs"]["readTextFile"] == false
    end
  end

  describe "new_session_params/2" do
    test "builds session params" do
      params = Protocol.new_session_params("/home/user/project")

      assert params["cwd"] == "/home/user/project"
      assert params["mcpServers"] == []
    end

    test "encodes HTTP MCP servers" do
      servers = [%{name: "test", url: "http://localhost:3000", headers: [{"Authorization", "Bearer x"}]}]
      params = Protocol.new_session_params("/tmp", servers)

      [server] = params["mcpServers"]
      assert server["type"] == "http"
      assert server["name"] == "test"
      assert server["url"] == "http://localhost:3000"
      assert [%{"name" => "Authorization", "value" => "Bearer x"}] = server["headers"]
    end

    test "encodes stdio MCP servers" do
      servers = [
        %{type: "stdio", name: "local", command: "node", args: ["server.js"], env: [{"KEY", "val"}]}
      ]

      params = Protocol.new_session_params("/tmp", servers)

      [server] = params["mcpServers"]
      assert server["type"] == "stdio"
      assert server["name"] == "local"
      assert server["command"] == "node"
      assert server["args"] == ["server.js"]
      assert [%{"name" => "KEY", "value" => "val"}] = server["env"]
    end
  end

  describe "prompt_params/2" do
    test "builds prompt with text content block" do
      params = Protocol.prompt_params("session-123", "Hello agent")

      assert params["sessionId"] == "session-123"
      assert [%{"type" => "text", "text" => "Hello agent"}] = params["prompt"]
    end
  end

  describe "cancel_params/1" do
    test "builds cancel notification" do
      params = Protocol.cancel_params("sess-abc")
      assert params["sessionId"] == "sess-abc"
    end
  end

  describe "permission_response/2" do
    test "allow_once response" do
      result = Protocol.permission_response(:allow_once, "opt-1")
      assert result["outcome"]["outcome"] == "selected"
      assert result["outcome"]["optionId"] == "opt-1"
    end

    test "cancel response" do
      result = Protocol.permission_response(:cancel, nil)
      assert result["outcome"]["outcome"] == "cancelled"
    end
  end

  describe "error codes" do
    test "standard JSON-RPC error codes" do
      assert Protocol.error_parse() == -32_700
      assert Protocol.error_invalid_request() == -32_600
      assert Protocol.error_method_not_found() == -32_601
      assert Protocol.error_invalid_params() == -32_602
      assert Protocol.error_internal() == -32_603
    end

    test "ACP-specific error codes" do
      assert Protocol.error_auth_required() == -32_000
      assert Protocol.error_not_found() == -32_002
    end
  end
end
