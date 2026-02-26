defmodule Liteskill.Accounts.SessionSweeper do
  @moduledoc """
  Periodic sweeper that deletes expired user sessions.
  Runs every 5 minutes.
  """

  use GenServer

  # coveralls-ignore-start

  @sweep_interval_ms 300_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    Liteskill.Accounts.delete_expired_sessions()
    schedule_sweep()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end

  # coveralls-ignore-stop
end
