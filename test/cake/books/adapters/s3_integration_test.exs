defmodule Cake.Books.Adapters.S3IntegrationTest do
  @moduledoc """
  `Cake.Books.Adapters.S3` against a real S3-compatible store (#251): the
  seam between the adapter's four callbacks and ExAws's response shapes,
  which nothing else exercises — every other test runs on
  `Cake.Books.Adapters.Mock`. On `Cake.S3IntegrationCase`, so ExAws points
  at the store and `:book_storage_s3_bucket` is the test's own bucket; the
  adapter is called exactly as production calls it, with no configuration
  of its own.

  Error cases pin the shape ExAws hands back — `{:http_error, status,
  response}` for a store that answered, the transport error for one that
  did not — because that is what `Cake.Books.Adapters.adapter_error/0`
  leaves as `term()` and what `Cake.Books.Pdf.Pipeline.load_binary/1`
  inspects into its message.
  """

  use Cake.S3IntegrationCase

  import Cake.PdfFixtures
  import ExUnit.CaptureLog

  alias Cake.Books.Adapters
  alias Cake.Books.Adapters.S3

  @key Adapters.build_key("default", "books", "s3_integration_fixture")
  @missing Adapters.build_key("default", "books", "never_written")

  # A port on this host with nothing listening: a request to it is refused
  # at once, so the adapter sees a transport error rather than a timeout.
  defp closed_port do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp unreachable_store!, do: configure_s3!(port: closed_port(), retries: [max_attempts: 1])

  # ExAws logs every failed attempt; the unreachable-store tests expect
  # exactly that, so they capture it rather than let it through.
  defp with_unreachable_store(fun) do
    unreachable_store!()
    assert capture_log(fun) =~ "ExAws: HTTP ERROR"
  end

  describe "write/2 then read/1" do
    test "round-trips the exact bytes of a fixture PDF", %{bucket: bucket} do
      binary = fixture_binary(:multi_page)

      assert :ok = S3.write(@key, binary)
      assert {:ok, ^binary} = S3.read(@key)
      assert object_keys!(bucket) == [@key]
    end

    test "carries arbitrary binaries, NUL bytes included" do
      binary = <<0, 1, 2, 255, 0, "not text", 0>>

      assert :ok = S3.write(@key, binary)
      assert {:ok, ^binary} = S3.read(@key)
    end

    test "write/2 overwrites an existing object" do
      assert :ok = S3.write(@key, "first")
      assert :ok = S3.write(@key, "second")
      assert {:ok, "second"} = S3.read(@key)
    end
  end

  describe "exists?/1" do
    test "is true after a write" do
      :ok = S3.write(@key, "%PDF-1.7 sample")
      assert S3.exists?(@key)
    end

    test "is false for a key never written" do
      refute S3.exists?(@missing)
    end

    test "is false, not a crash, when the configured bucket does not exist" do
      Application.put_env(:cake, :book_storage_s3_bucket, new_bucket_name())
      refute S3.exists?(@key)
    end

    test "is false, not a crash, when the store cannot be reached" do
      with_unreachable_store(fn -> refute S3.exists?(@key) end)
    end
  end

  describe "delete/1" do
    test "removes the object", %{bucket: bucket} do
      :ok = S3.write(@key, "%PDF-1.7 sample")

      assert :ok = S3.delete(@key)
      refute S3.exists?(@key)
      assert object_keys!(bucket) == []
    end

    test "is :ok for a key that was never written — S3 DeleteObject is idempotent" do
      assert :ok = S3.delete(@missing)
    end

    test "returns an error tuple, not a crash, when the store cannot be reached" do
      with_unreachable_store(fn ->
        assert {:error, %Req.TransportError{reason: :econnrefused}} = S3.delete(@key)
      end)
    end
  end

  describe "read/1" do
    test "returns ExAws's HTTP error for a key never written, never raises" do
      assert {:error, {:http_error, 404, %{status_code: 404}}} = S3.read(@missing)
    end

    test "returns ExAws's HTTP error when the configured bucket does not exist" do
      Application.put_env(:cake, :book_storage_s3_bucket, new_bucket_name())
      assert {:error, {:http_error, 404, %{status_code: 404}}} = S3.read(@key)
    end

    test "returns the transport error when the store cannot be reached" do
      with_unreachable_store(fn ->
        assert {:error, %Req.TransportError{reason: :econnrefused}} = S3.read(@key)
      end)
    end
  end

  describe "write/2" do
    test "returns an error tuple, not a crash, when the store cannot be reached" do
      with_unreachable_store(fn ->
        assert {:error, %Req.TransportError{reason: :econnrefused}} = S3.write(@key, "x")
      end)
    end
  end

  describe "bucket configuration" do
    test "every callback raises ArgumentError when :book_storage_s3_bucket is unset" do
      Application.delete_env(:cake, :book_storage_s3_bucket)

      assert_raise ArgumentError, fn -> S3.read(@key) end
      assert_raise ArgumentError, fn -> S3.write(@key, "x") end
      assert_raise ArgumentError, fn -> S3.exists?(@key) end
      assert_raise ArgumentError, fn -> S3.delete(@key) end
    end
  end
end
