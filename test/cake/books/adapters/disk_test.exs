defmodule Cake.Books.Adapters.DiskTest do
  @moduledoc """
  The disk adapter resolves every key under `:book_storage_root`, so a key
  that could escape the root must be refused before any filesystem access.
  `:book_storage_root` is process-global, so this module is `async: false`.
  """

  use ExUnit.Case, async: false

  alias Cake.Books.Adapters.Disk

  setup do
    root = Path.join(System.tmp_dir!(), "cake-disk-adapter-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    original = Application.get_env(:cake, :book_storage_root)
    Application.put_env(:cake, :book_storage_root, root)

    on_exit(fn ->
      Application.put_env(:cake, :book_storage_root, original)
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "round-trips a binary under the root", %{root: root} do
    key = "cake-documents/default/books/sample_abc123"

    assert :ok = Disk.write(key, "%PDF-1.7 sample")
    assert File.exists?(Path.join(root, key))
    assert Disk.exists?(key)
    assert {:ok, "%PDF-1.7 sample"} = Disk.read(key)
    assert :ok = Disk.delete(key)
    refute Disk.exists?(key)
  end

  test "refuses to read, write, probe, or delete a key with a .. segment", %{root: root} do
    outside = Path.join(root, "..") |> Path.join("cake-disk-adapter-outside")
    File.write!(outside, "secret")
    on_exit(fn -> File.rm(outside) end)

    key = "../cake-disk-adapter-outside"

    assert {:error, :einval} = Disk.read(key)
    assert {:error, :einval} = Disk.write(key, "overwritten")
    refute Disk.exists?(key)
    assert {:error, :einval} = Disk.delete(key)

    assert File.read!(outside) == "secret"
  end
end
