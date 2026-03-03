defmodule Liteskill.DesktopTest do
  use ExUnit.Case, async: true

  alias Liteskill.Desktop

  describe "enabled?/0" do
    test "returns false by default" do
      refute Desktop.enabled?()
    end
  end

  describe "data_dir/0" do
    test "returns a string containing liteskill" do
      dir = Desktop.data_dir()
      assert is_binary(dir)
      assert String.contains?(String.downcase(dir), "liteskill")
    end
  end

  describe "arch_triple/0" do
    test "returns a valid triple with at least 3 segments" do
      triple = Desktop.arch_triple()
      assert is_binary(triple)
      segments = String.split(triple, "-")
      assert length(segments) >= 3
    end
  end

  describe "config_path/0" do
    test "ends with desktop_config.json" do
      assert String.ends_with?(Desktop.config_path(), "desktop_config.json")
    end
  end

  describe "windows?/0" do
    test "returns a boolean" do
      result = Desktop.windows?()
      assert is_boolean(result)
    end
  end

  describe "load_or_create_config!/1" do
    @tag :tmp_dir
    test "creates config file on first call and loads on second", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "desktop_config.json")

      # First call: creates file
      config = Desktop.load_or_create_config!(path)
      assert is_map(config)
      assert Map.has_key?(config, "secret_key_base")
      assert byte_size(config["secret_key_base"]) > 0
      assert File.exists?(path)

      # Second call: loads existing file (same values)
      config2 = Desktop.load_or_create_config!(path)
      assert config2 == config
    end

    @tag :tmp_dir
    test "creates parent directories if needed", %{tmp_dir: tmp_dir} do
      path = Path.join([tmp_dir, "nested", "dir", "desktop_config.json"])

      config = Desktop.load_or_create_config!(path)
      assert is_map(config)
      assert File.exists?(path)
    end
  end
end
