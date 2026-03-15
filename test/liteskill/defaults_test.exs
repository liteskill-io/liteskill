defmodule Liteskill.DefaultsTest do
  use ExUnit.Case, async: true

  alias Liteskill.Defaults

  describe "data_dir/0" do
    test "returns a string containing liteskill" do
      dir = Defaults.data_dir()
      assert is_binary(dir)
      assert String.contains?(String.downcase(dir), "liteskill")
    end

    test "returns platform-appropriate path" do
      dir = Defaults.data_dir()

      case :os.type() do
        {:unix, :darwin} ->
          assert String.contains?(dir, "Library/Application Support/Liteskill")

        {:unix, _} ->
          assert String.contains?(String.downcase(dir), "liteskill")

        {:win32, _} ->
          assert String.contains?(dir, "Liteskill")
      end
    end
  end

  describe "database_path/0" do
    test "returns path ending with liteskill.db" do
      path = Defaults.database_path()
      assert String.ends_with?(path, "liteskill.db")
    end

    test "lives inside data_dir" do
      assert String.starts_with?(Defaults.database_path(), Defaults.data_dir())
    end
  end

  describe "secrets_dir/0" do
    test "equals data_dir" do
      assert Defaults.secrets_dir() == Defaults.data_dir()
    end
  end

  describe "secrets_path/0" do
    test "returns path ending with secrets.json" do
      path = Defaults.secrets_path()
      assert String.ends_with?(path, "secrets.json")
    end

    test "lives inside secrets_dir" do
      assert String.starts_with?(Defaults.secrets_path(), Defaults.secrets_dir())
    end
  end

  describe "home/0" do
    test "returns a string" do
      assert is_binary(Defaults.home())
    end

    test "returns HOME env var when set" do
      # HOME is always set on macOS/Linux test runners
      case System.get_env("HOME") do
        nil -> :ok
        home -> assert Defaults.home() == home
      end
    end
  end

  describe "DATABASE_PATH env var default behavior" do
    test "database_path provides a sane default without any env var" do
      # This is the core fix: the app should boot without DATABASE_PATH set.
      # The default should be a valid path inside the platform data directory.
      path = Defaults.database_path()
      assert is_binary(path)
      assert byte_size(path) > 0
      assert String.ends_with?(path, ".db")

      # Path should be absolute (not relative)
      # Windows paths start with drive letter
      assert String.starts_with?(path, "/") or
               Regex.match?(~r/^[A-Z]:\//i, path)
    end
  end
end
