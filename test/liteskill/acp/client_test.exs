defmodule Liteskill.Acp.ClientTest do
  use ExUnit.Case, async: true

  alias Liteskill.Acp.Client

  @moduletag :tmp_dir

  describe "init and lifecycle" do
    test "spawns agent process", %{tmp_dir: tmp_dir} do
      script = write_echo_agent(tmp_dir)

      {:ok, pid} =
        Client.start_link(
          agent_config: %{name: "test", command: script, args: [], env: %{}},
          user_id: Ecto.UUID.generate()
        )

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "initialize/1" do
    test "completes handshake with agent", %{tmp_dir: tmp_dir} do
      script = write_acp_agent(tmp_dir)

      {:ok, pid} =
        Client.start_link(
          agent_config: %{name: "test", command: script, args: [], env: %{}},
          user_id: Ecto.UUID.generate()
        )

      assert {:ok, caps} = Client.initialize(pid)
      assert caps["protocolVersion"] == 1
      assert caps["agentCapabilities"]

      status = Client.status(pid)
      assert status.status == :ready

      GenServer.stop(pid)
    end
  end

  describe "new_session/3" do
    test "creates session after initialization", %{tmp_dir: tmp_dir} do
      script = write_acp_agent(tmp_dir)

      {:ok, pid} =
        Client.start_link(
          agent_config: %{name: "test", command: script, args: [], env: %{}},
          user_id: Ecto.UUID.generate()
        )

      {:ok, _caps} = Client.initialize(pid)
      assert {:ok, %{"sessionId" => session_id}} = Client.new_session(pid, tmp_dir)
      assert is_binary(session_id)

      status = Client.status(pid)
      assert status.session_id == session_id

      GenServer.stop(pid)
    end
  end

  describe "prompt/2" do
    test "sends prompt and receives response", %{tmp_dir: tmp_dir} do
      script = write_acp_agent(tmp_dir)

      {:ok, pid} =
        Client.start_link(
          agent_config: %{name: "test", command: script, args: [], env: %{}},
          user_id: Ecto.UUID.generate()
        )

      {:ok, _} = Client.initialize(pid)
      {:ok, _} = Client.new_session(pid, tmp_dir)

      assert {:ok, %{"stopReason" => "end_turn"}} = Client.prompt(pid, "Hello")

      GenServer.stop(pid)
    end
  end

  describe "cancel/1" do
    test "sends cancel notification without error", %{tmp_dir: tmp_dir} do
      script = write_acp_agent(tmp_dir)

      {:ok, pid} =
        Client.start_link(
          agent_config: %{name: "test", command: script, args: [], env: %{}},
          user_id: Ecto.UUID.generate()
        )

      {:ok, _} = Client.initialize(pid)
      {:ok, _} = Client.new_session(pid, tmp_dir)

      # cancel is a cast, should not raise
      assert :ok = Client.cancel(pid)

      GenServer.stop(pid)
    end
  end

  describe "agent exit" do
    test "client stops when agent exits", %{tmp_dir: tmp_dir} do
      script = write_exit_agent(tmp_dir)

      {:ok, pid} =
        Client.start_link(
          agent_config: %{name: "test", command: script, args: [], env: %{}},
          user_id: Ecto.UUID.generate()
        )

      ref = Process.monitor(pid)
      state = :sys.get_state(pid)
      Port.command(state.port, "quit\n")

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
    end
  end

  # -- Helper: Mock ACP Agent Scripts --

  defp write_echo_agent(tmp_dir) do
    path = Path.join(tmp_dir, "echo_agent.sh")

    File.write!(path, """
    #!/bin/bash
    while IFS= read -r line; do
      echo "$line"
    done
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp write_acp_agent(tmp_dir) do
    path = Path.join(tmp_dir, "acp_agent.sh")

    # A minimal ACP-compatible agent that handles initialize, session/new, and session/prompt
    File.write!(path, ~S"""
    #!/bin/bash
    SESSION_ID=""

    while IFS= read -r line; do
      METHOD=$(echo "$line" | grep -o '"method":"[^"]*"' | head -1 | cut -d'"' -f4)
      ID=$(echo "$line" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)

      if [ "$METHOD" = "initialize" ]; then
        echo "{\"jsonrpc\":\"2.0\",\"id\":$ID,\"result\":{\"protocolVersion\":1,\"agentInfo\":{\"name\":\"test-agent\",\"version\":\"0.1.0\"},\"authMethods\":[],\"agentCapabilities\":{\"loadSession\":false,\"mcpCapabilities\":{\"http\":true},\"promptCapabilities\":{\"image\":false},\"sessionCapabilities\":{}}}}"
      elif [ "$METHOD" = "session/new" ]; then
        SESSION_ID="sess-$(date +%s)"
        echo "{\"jsonrpc\":\"2.0\",\"id\":$ID,\"result\":{\"sessionId\":\"$SESSION_ID\"}}"
      elif [ "$METHOD" = "session/prompt" ]; then
        echo "{\"jsonrpc\":\"2.0\",\"id\":$ID,\"result\":{\"stopReason\":\"end_turn\"}}"
      elif [ "$METHOD" = "session/cancel" ]; then
        true  # notification, no response
      fi
    done
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp write_exit_agent(tmp_dir) do
    path = Path.join(tmp_dir, "exit_agent.sh")

    File.write!(path, """
    #!/bin/bash
    read -r line
    exit 0
    """)

    File.chmod!(path, 0o755)
    path
  end
end
