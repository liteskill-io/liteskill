defmodule Liteskill.Acp.ToolBridgeTest do
  use ExUnit.Case, async: true

  alias Liteskill.Acp.ToolBridge

  @moduletag :tmp_dir

  describe "handle_request fs/read_text_file" do
    test "reads a file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.txt")
      File.write!(path, "line1\nline2\nline3")

      assert {:ok, %{"content" => "line1\nline2\nline3"}} =
               ToolBridge.handle_request("fs/read_text_file", %{"path" => path}, %{})
    end

    test "reads with line offset and limit", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "lines.txt")
      File.write!(path, "a\nb\nc\nd\ne")

      assert {:ok, %{"content" => "b\nc"}} =
               ToolBridge.handle_request(
                 "fs/read_text_file",
                 %{"path" => path, "line" => 2, "limit" => 2},
                 %{}
               )
    end

    test "returns error for missing file" do
      assert {:error, -32_002, _msg} =
               ToolBridge.handle_request("fs/read_text_file", %{"path" => "/nonexistent/file"}, %{})
    end

    test "returns error for relative path" do
      assert {:error, -32_602, _msg} =
               ToolBridge.handle_request("fs/read_text_file", %{"path" => "relative/path"}, %{})
    end

    test "returns error for missing path param" do
      assert {:error, -32_602, _msg} =
               ToolBridge.handle_request("fs/read_text_file", %{}, %{})
    end
  end

  describe "handle_request fs/write_text_file" do
    test "writes a file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "output.txt")

      assert {:ok, %{}} =
               ToolBridge.handle_request(
                 "fs/write_text_file",
                 %{"path" => path, "content" => "hello"},
                 %{}
               )

      assert File.read!(path) == "hello"
    end

    test "creates parent directories", %{tmp_dir: tmp_dir} do
      path = Path.join([tmp_dir, "sub", "dir", "file.txt"])

      assert {:ok, %{}} =
               ToolBridge.handle_request(
                 "fs/write_text_file",
                 %{"path" => path, "content" => "nested"},
                 %{}
               )

      assert File.read!(path) == "nested"
    end

    test "returns error for relative path" do
      assert {:error, -32_602, _msg} =
               ToolBridge.handle_request(
                 "fs/write_text_file",
                 %{"path" => "relative", "content" => "x"},
                 %{}
               )
    end

    test "returns error for missing params" do
      assert {:error, -32_602, _msg} =
               ToolBridge.handle_request("fs/write_text_file", %{"path" => "/tmp/x"}, %{})
    end
  end

  describe "handle_request session/request_permission" do
    test "broadcasts permission request and returns async" do
      Phoenix.PubSub.subscribe(Liteskill.PubSub, "acp:permission:sess-1")

      params = %{
        "sessionId" => "sess-1",
        "toolCall" => %{"toolCallId" => "tc-1", "toolCall" => %{"toolName" => "bash"}},
        "options" => [%{"optionId" => "allow", "name" => "Allow", "kind" => "allow_once"}]
      }

      assert {:async, :permission_pending} =
               ToolBridge.handle_request("session/request_permission", params, %{client_pid: self()})

      assert_receive {:acp_permission_request, payload}
      assert payload["session_id"] == "sess-1"
      assert payload["tool_call"]["toolCallId"] == "tc-1"
      assert payload["id"] == nil
    end
  end

  describe "handle_request unknown method" do
    test "returns method not found error" do
      assert {:error, -32_601, _msg} =
               ToolBridge.handle_request("unknown/method", %{}, %{})
    end
  end
end
