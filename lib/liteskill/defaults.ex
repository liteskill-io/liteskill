defmodule Liteskill.Defaults do
  @moduledoc """
  Platform-specific default paths and configuration values.

  Provides sane defaults for every environment variable the app reads,
  so the application boots without mandatory env vars on any OS.
  These functions are pure (no Application config reads) and can be
  called from runtime.exs, Desktop, or tests.
  """

  use Boundary, top_level?: true, deps: [], exports: []

  @doc """
  Returns the platform-specific application data directory.

  - macOS: `~/Library/Application Support/Liteskill`
  - Linux: `$XDG_DATA_HOME/liteskill` (defaults to `~/.local/share/liteskill`)
  - Windows: `%APPDATA%\\Liteskill` (defaults to `C:/Users/Default/AppData/Roaming/Liteskill`)
  """
  @spec data_dir() :: String.t()
  def data_dir do
    # coveralls-ignore-start — each branch only reachable on its own OS
    case :os.type() do
      {:unix, :darwin} ->
        Path.join(home(), "Library/Application Support/Liteskill")

      {:unix, _} ->
        xdg = System.get_env("XDG_DATA_HOME", Path.join(home(), ".local/share"))
        Path.join(xdg, "liteskill")

      {:win32, _} ->
        Path.join(
          System.get_env("APPDATA", "C:/Users/Default/AppData/Roaming"),
          "Liteskill"
        )
    end

    # coveralls-ignore-stop
  end

  @doc """
  Returns the default database path: `<data_dir>/liteskill.db`.
  """
  @spec database_path() :: String.t()
  def database_path, do: Path.join(data_dir(), "liteskill.db")

  @doc """
  Returns the default secrets directory (same as `data_dir/0`).
  """
  @spec secrets_dir() :: String.t()
  def secrets_dir, do: data_dir()

  @doc """
  Returns the default secrets file path: `<data_dir>/secrets.json`.
  """
  @spec secrets_path() :: String.t()
  def secrets_path, do: Path.join(data_dir(), "secrets.json")

  @doc """
  Returns the user's home directory, falling back to `~`.
  """
  @spec home() :: String.t()
  def home, do: System.get_env("HOME", "~")
end
