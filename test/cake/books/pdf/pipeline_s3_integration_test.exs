defmodule Cake.Books.Pdf.PipelineS3IntegrationTest do
  @moduledoc """
  `Cake.Books.Pdf.Pipeline.load_binary/1` — the production read path of the
  Books ingestion — with `Cake.Books.Adapters.S3` as the configured adapter,
  against a real S3-compatible store (#251). The callback resolves the
  adapter from `:book_storage_adapter` at call time, so the tests point that
  key at the S3 adapter for their duration; `Cake.S3IntegrationCase` supplies
  the endpoint and the bucket.

  What is pinned: the `{:ok, {key, binary}}` success shape carrying the exact
  bytes the adapter stored, the `{:error, {key, message}}` wrap of an adapter
  error (the message inspects ExAws's reason, so the HTTP status and the
  transport error both surface), and that what `load_binary/1` hands over
  parses through `parse/1` exactly as the fixture does from disk.
  """

  use Cake.S3IntegrationCase

  import Cake.PdfFixtures
  import ExUnit.CaptureLog

  alias Cake.Books.Adapters
  alias Cake.Books.Adapters.S3
  alias Cake.Books.ParsedBook
  alias Cake.Books.Pdf.Pipeline

  @key Adapters.build_key("default", "books", "multi_page_s3")
  @missing Adapters.build_key("default", "books", "never_written")

  setup do
    previous = Application.fetch_env(:cake, :book_storage_adapter)
    Application.put_env(:cake, :book_storage_adapter, S3)

    on_exit(fn ->
      case previous do
        {:ok, adapter} -> Application.put_env(:cake, :book_storage_adapter, adapter)
        :error -> Application.delete_env(:cake, :book_storage_adapter)
      end
    end)

    :ok
  end

  defp closed_port do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  test "resolves the S3 adapter from config at call time" do
    assert Adapters.adapter() == S3
  end

  describe "load_binary/1" do
    test "returns {:ok, {key, binary}} with the exact bytes the adapter stored" do
      binary = fixture_binary(:multi_page)
      :ok = S3.write(@key, binary)

      assert {:ok, {@key, ^binary}} = Pipeline.load_binary(@key)
    end

    test "wraps a missing object as {:error, {key, message}} naming the HTTP error" do
      assert {:error, {@missing, message}} = Pipeline.load_binary(@missing)
      assert message =~ "Failed to read:"
      assert message =~ ":http_error"
      assert message =~ "404"
    end

    test "wraps an unreachable store the same way, naming the transport error" do
      configure_s3!(port: closed_port(), retries: [max_attempts: 1])

      log =
        capture_log(fn ->
          assert {:error, {@key, message}} = Pipeline.load_binary(@key)
          assert message =~ "Failed to read:"
          assert message =~ "econnrefused"
        end)

      assert log =~ "ExAws: HTTP ERROR"
    end

    test "what it loads parses through parse/1 exactly as the fixture does from disk" do
      :ok = S3.write(@key, fixture_binary(:multi_page))
      {:ok, loaded} = Pipeline.load_binary(@key)

      {%ParsedBook{} = from_store, store_chunks} = Pipeline.parse(loaded)
      {%ParsedBook{} = from_disk, disk_chunks} = parse_fixture(:multi_page)

      assert from_store.source_file_path == @key
      assert from_store.file_hash == from_disk.file_hash
      assert from_store.title == from_disk.title
      assert Enum.map(store_chunks, & &1.text) == Enum.map(disk_chunks, & &1.text)
    end
  end
end
