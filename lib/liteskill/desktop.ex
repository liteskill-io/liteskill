defmodule Liteskill.Desktop do
  @moduledoc """
  Boundary module for desktop-mode functionality.

  Provides platform-specific path helpers and configuration persistence
  for the Tauri desktop app with SQLite database.
  """

  use Boundary, top_level?: true, deps: [Liteskill.Defaults], exports: []

  @doc "Returns true when running in desktop mode."
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:liteskill, :desktop_mode, false)
  end

  @doc "Returns the platform-specific application data directory."
  @spec data_dir() :: String.t()
  def data_dir do
    Application.get_env(:liteskill, :desktop_data_dir) || Liteskill.Defaults.data_dir()
  end

  @doc "Returns true when running on Windows."
  @spec windows?() :: boolean()
  def windows?, do: match?({:win32, _}, :os.type())

  @doc "Returns the architecture triple string for the current platform."
  @spec arch_triple() :: String.t()
  def arch_triple do
    {os_family, os_name} = :os.type()
    arch = :system_architecture |> :erlang.system_info() |> to_string()

    cpu =
      cond do
        String.contains?(arch, "aarch64") or String.contains?(arch, "arm64") ->
          "aarch64"

        # coveralls-ignore-start
        String.contains?(arch, "x86_64") or String.contains?(arch, "amd64") ->
          "x86_64"

        # coveralls-ignore-stop

        # coveralls-ignore-start
        true ->
          arch |> String.split("-") |> hd()
          # coveralls-ignore-stop
      end

    # coveralls-ignore-start
    os =
      case {os_family, os_name} do
        {:unix, :darwin} -> "apple-darwin"
        {:unix, :linux} -> "unknown-linux-gnu"
        {:win32, _} -> "pc-windows-msvc"
        {:unix, name} -> "unknown-#{name}"
      end

    # coveralls-ignore-stop

    "#{cpu}-#{os}"
  end

  @doc "Returns the path to the desktop configuration JSON file."
  @spec config_path() :: String.t()
  def config_path, do: Path.join(data_dir(), "desktop_config.json")

  @doc """
  Loads or creates the desktop configuration file at the given path.

  On first run, generates a cryptographically secure `secret_key_base`
  value, persists it as JSON, and returns the map.
  On subsequent runs, reads the existing file.
  """
  @spec load_or_create_config!(String.t()) :: map()
  def load_or_create_config!(path) do
    if File.exists?(path) do
      path |> File.read!() |> Jason.decode!()
    else
      config = %{
        "secret_key_base" => Base.url_encode64(:crypto.strong_rand_bytes(48), padding: false)
      }

      File.mkdir_p!(Path.dirname(path))
      File.write!(path, Jason.encode!(config, pretty: true))
      config
    end
  end
end
