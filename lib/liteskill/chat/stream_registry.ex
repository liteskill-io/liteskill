defmodule Liteskill.Chat.StreamRegistry do
  @moduledoc """
  ETS-based registry tracking active LLM stream tasks per conversation.

  Each entry maps `conversation_id → task_pid`. A monitor is spawned on
  registration so the entry is automatically cleaned up when the task exits.

  When a stream task dies, the monitor also triggers automatic recovery
  via `Chat.recover_stream_by_id/1` to consolidate partial content and
  transition the conversation back to `:active` state. This makes stream
  lifecycle fully backend-managed — the frontend is a pure observer.
  """

  require Logger

  @table __MODULE__

  @doc """
  Creates the ETS table. Call once from `Application.start/2`.
  """
  def create_table do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
  rescue
    # coveralls-ignore-next-line
    ArgumentError -> @table
  end

  @doc """
  Registers a stream task for the given conversation.

  Spawns a monitor process that removes the entry when the task exits.
  """
  def register(conversation_id, pid) when is_pid(pid) do
    ensure_table()
    :ets.insert(@table, {conversation_id, pid})

    table = @table

    conv_id = conversation_id

    # Use Task.start so $callers is propagated — Ecto sandbox needs
    # the caller chain to route DB operations through the shared connection.
    Task.start(fn ->
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} ->
          try do
            :ets.delete_object(table, {conv_id, pid})
          rescue
            # coveralls-ignore-next-line
            ArgumentError -> :ok
          end

          # Auto-recover: spawn async so monitor cleanup isn't blocked.
          # The sleep lets the normal completion path (complete_stream →
          # projector) finish first; recover_stream_by_id is idempotent
          # and checks conversation status before acting.
          Task.start(fn ->
            Process.sleep(250)

            try do
              Liteskill.Chat.recover_stream_by_id(conv_id)
            rescue
              # coveralls-ignore-start
              e ->
                Logger.warning(
                  "StreamRegistry auto-recovery failed for #{conv_id}: #{Exception.message(e)}"
                )

                # coveralls-ignore-stop
            end
          end)
      end
    end)

    :ok
  end

  @doc """
  Looks up the active stream task for a conversation.

  Returns `{:ok, pid}` if found and the process is alive, `:error` otherwise.
  """
  def lookup(conversation_id) do
    case :ets.lookup(@table, conversation_id) do
      [{^conversation_id, pid}] ->
        if Process.alive?(pid), do: {:ok, pid}, else: :error

      [] ->
        :error
    end
  rescue
    # coveralls-ignore-next-line
    ArgumentError -> :error
  end

  @doc """
  Returns `true` if a stream task is registered and alive for the conversation.
  """
  def streaming?(conversation_id) do
    match?({:ok, _}, lookup(conversation_id))
  end

  @doc """
  Manually removes a conversation from the registry.
  """
  def unregister(conversation_id) do
    :ets.delete(@table, conversation_id)
    :ok
  rescue
    # coveralls-ignore-next-line
    ArgumentError -> :ok
  end

  # coveralls-ignore-start
  defp ensure_table do
    :ets.info(@table) != :undefined || create_table()
    :ok
  end

  # coveralls-ignore-stop
end
