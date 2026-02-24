defmodule Liteskill.Chat.StreamRegistryTest do
  use ExUnit.Case, async: true

  alias Liteskill.Chat.StreamRegistry

  # Polls a condition function until it returns true, with bounded retries.
  # Replaces arbitrary Process.sleep calls with deterministic polling.
  defp assert_eventually(fun, retries \\ 20, interval \\ 10) do
    if fun.() do
      :ok
    else
      if retries > 0 do
        Process.sleep(interval)
        assert_eventually(fun, retries - 1, interval)
      else
        flunk("condition not met after polling")
      end
    end
  end

  describe "register/2 and lookup/1" do
    test "registers and looks up a stream task" do
      conv_id = Ecto.UUID.generate()

      task =
        Task.async(fn ->
          Process.sleep(:infinity)
        end)

      :ok = StreamRegistry.register(conv_id, task.pid)

      assert {:ok, pid} = StreamRegistry.lookup(conv_id)
      assert pid == task.pid

      Task.shutdown(task)
    end

    test "returns :error for unknown conversation" do
      assert :error = StreamRegistry.lookup(Ecto.UUID.generate())
    end

    test "returns :error after process exits" do
      conv_id = Ecto.UUID.generate()
      task = Task.async(fn -> :ok end)
      :ok = StreamRegistry.register(conv_id, task.pid)

      # Wait for the task to finish
      Task.await(task)

      # Poll until the monitor's spawned cleanup process runs.
      # The monitor removes the ETS entry asynchronously after the DOWN signal.
      assert_eventually(fn -> :error == StreamRegistry.lookup(conv_id) end)
    end
  end

  describe "streaming?/1" do
    test "returns true for active stream" do
      conv_id = Ecto.UUID.generate()

      task =
        Task.async(fn ->
          Process.sleep(:infinity)
        end)

      :ok = StreamRegistry.register(conv_id, task.pid)

      assert StreamRegistry.streaming?(conv_id)

      Task.shutdown(task)
    end

    test "returns false for no stream" do
      refute StreamRegistry.streaming?(Ecto.UUID.generate())
    end
  end

  describe "unregister/1" do
    test "removes entry from registry" do
      conv_id = Ecto.UUID.generate()

      task =
        Task.async(fn ->
          Process.sleep(:infinity)
        end)

      :ok = StreamRegistry.register(conv_id, task.pid)
      assert StreamRegistry.streaming?(conv_id)

      :ok = StreamRegistry.unregister(conv_id)
      refute StreamRegistry.streaming?(conv_id)

      Task.shutdown(task)
    end
  end

  describe "auto-cleanup on process exit" do
    test "cleans up when monitored process crashes" do
      conv_id = Ecto.UUID.generate()

      pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      :ok = StreamRegistry.register(conv_id, pid)
      assert StreamRegistry.streaming?(conv_id)

      # Kill the process and wait for monitor cleanup
      Process.exit(pid, :kill)
      assert_eventually(fn -> not StreamRegistry.streaming?(conv_id) end)
    end

    test "cleans up when process exits normally" do
      conv_id = Ecto.UUID.generate()

      pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      :ok = StreamRegistry.register(conv_id, pid)
      assert StreamRegistry.streaming?(conv_id)

      send(pid, :stop)
      assert_eventually(fn -> not StreamRegistry.streaming?(conv_id) end)
    end
  end

  describe "double-registration safety" do
    test "second registration survives first process exit" do
      conv_id = Ecto.UUID.generate()

      pid1 =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      pid2 =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      :ok = StreamRegistry.register(conv_id, pid1)
      assert {:ok, ^pid1} = StreamRegistry.lookup(conv_id)

      # Re-register with a new pid (simulates double-launch)
      :ok = StreamRegistry.register(conv_id, pid2)
      assert {:ok, ^pid2} = StreamRegistry.lookup(conv_id)

      # Kill the first process — should NOT remove the second's registration
      Process.exit(pid1, :kill)
      # Wait for monitor cleanup of pid1 to complete
      ref = Process.monitor(pid1)
      assert_receive {:DOWN, ^ref, :process, ^pid1, _}, 500

      # pid2 should still be registered
      assert {:ok, ^pid2} = StreamRegistry.lookup(conv_id)

      send(pid2, :stop)
    end
  end
end
