defmodule Cake.S3IntegrationCaseTest do
  @moduledoc """
  Contract for `Cake.S3IntegrationCase`, the case template every
  real-object-store test builds on (#251).

  The template must:

    * tag its tests `:integration` and refuse `async: true` (the pure half of
      that contract is in `Cake.S3IntegrationCaseUnitTest`);
    * point ExAws's `:s3` service at the endpoint in `S3_ENDPOINT_URL` with a
      fixed key pair for the duration of the test — a configuration the
      `Cake.Books.Adapters.S3` callbacks read at call time — and put back
      whatever was there before;
    * hand each test a bucket that exists, is empty, and is unique to it, and
      set `:book_storage_s3_bucket` to it, so the adapter under test needs no
      configuration of its own — plus a way to derive further bucket names
      under the same prefix;
    * expose the bucket helpers a test needs to observe the adapter from the
      outside (`bucket_exists?/1`, `object_keys!/2` across every page of a
      listing, `bucket_names!/0`,
      `create_bucket!/1`, `drop_bucket!/1`, `drop_buckets!/1`);
    * drop every bucket under the test's prefix, objects and all, once the
      test is over, and restore the config however often the test re-pointed
      it.

  Teardown cannot be observed from inside the test that triggers it
  (`on_exit` callbacks run newest-first, so a test-body callback runs before
  the template's), so the tests record what they created in a ledger and the
  `setup_all` `on_exit` — which runs after every test in the module and all
  their callbacks — asserts none of it survived and the config is back to
  what it was before the module.
  """

  use Cake.S3IntegrationCase

  alias Cake.S3IntegrationCase

  setup_all do
    {:ok, ledger} = Agent.start(fn -> [] end)
    original_s3_config = Application.get_env(:ex_aws, :s3)
    original_bucket_config = Application.get_env(:cake, :book_storage_s3_bucket)

    on_exit(fn ->
      created = Agent.get(ledger, & &1)
      Agent.stop(ledger)

      assert created != [], "no test recorded a bucket in the ledger"
      assert Enum.uniq(created) == created, "two tests were handed the same bucket name"

      assert Application.get_env(:ex_aws, :s3) == original_s3_config,
             "the template left ExAws's :s3 config changed after the module"

      assert Application.get_env(:cake, :book_storage_s3_bucket) == original_bucket_config,
             "the template left :book_storage_s3_bucket changed after the module"

      # Reaching the store again needs the endpoint config the template has
      # just (correctly) removed; put it back for the check, then undo that.
      snapshot = configure_s3!()
      leftovers = Enum.filter(created, &bucket_exists?/1)
      restore_config!(snapshot)
      assert leftovers == [], "buckets survived their test's teardown: #{inspect(leftovers)}"
    end)

    %{ledger: ledger}
  end

  defp record(ledger, name), do: Agent.update(ledger, &[name | &1])

  defp put_object!(bucket, key, body) do
    {:ok, _} = bucket |> ExAws.S3.put_object(key, body) |> ExAws.request()
    :ok
  end

  describe "endpoint configuration" do
    test "tags every test :integration", context do
      assert context[:integration] == true
    end

    test "points ExAws's :s3 service at the endpoint with the fixed key pair" do
      assert s3_config?()

      config = ExAws.Config.new(:s3)
      expected = endpoint_config(endpoint_url())

      assert config.scheme == Keyword.fetch!(expected, :scheme)
      assert config.host == Keyword.fetch!(expected, :host)
      assert config.port == Keyword.fetch!(expected, :port)
      assert config.region == region()
      assert config.access_key_id == access_key_id()
      assert config.secret_access_key == secret_access_key()
    end

    test "a round trip the config cannot fake: a bucket created is a bucket found", context do
      refute bucket_exists?(new_bucket_name())

      extra = create_bucket!(unique_bucket_name(context))
      record(context.ledger, extra)

      assert bucket_exists?(extra)
      assert extra in bucket_names!()
    end

    test "configure_s3!/1 layers overrides on the endpoint config — how a test provokes a request error" do
      before = Application.get_env(:ex_aws, :s3)

      assert configure_s3!(port: 1, retries: [max_attempts: 1]) == before

      config = ExAws.Config.new(:s3)
      assert config.port == 1
      assert config.retries == [max_attempts: 1]
      assert config.host == Keyword.fetch!(endpoint_config(endpoint_url()), :host)
      refute s3_config?()
    end

    test "restore_config!/1 puts back what configure_s3!/1 replaced, deleting when there was none" do
      before = Application.get_env(:ex_aws, :s3)

      snapshot = configure_s3!(port: 1)
      assert :ok = restore_config!(snapshot)
      assert Application.get_env(:ex_aws, :s3) == before

      Application.delete_env(:ex_aws, :s3)
      assert configure_s3!() == nil
      assert :ok = restore_config!(nil)
      assert Application.get_env(:ex_aws, :s3) == nil
    end
  end

  describe "per-test bucket" do
    test "hands each test a :bucket that exists and is empty", %{bucket: bucket} do
      assert bucket =~ ~r/^cake-test-[0-9a-f]{16}$/
      assert bucket_exists?(bucket)
      assert object_keys!(bucket) == []
    end

    test "sets :book_storage_s3_bucket to it, the key the adapter reads", %{bucket: bucket} do
      assert Application.fetch_env!(:cake, :book_storage_s3_bucket) == bucket
    end

    test "unique_bucket_name/1 derives distinct names under the test's bucket", context do
      first = unique_bucket_name(context)
      second = unique_bucket_name(context)

      assert first != second
      assert String.starts_with?(first, context.bucket <> "-")
      assert String.starts_with?(second, context.bucket <> "-")
    end

    test "names differ between tests (checked in the setup_all teardown)", context do
      record(context.ledger, context.bucket)
    end

    test "names differ between tests, second sample", context do
      record(context.ledger, context.bucket)
    end
  end

  describe "bucket helpers" do
    test "object_keys!/1 lists every key in the bucket, in key order", %{bucket: bucket} do
      put_object!(bucket, "cake-documents/default/books/b", "second")
      put_object!(bucket, "cake-documents/default/books/a", "first")

      assert object_keys!(bucket) == [
               "cake-documents/default/books/a",
               "cake-documents/default/books/b"
             ]
    end

    test "object_keys!/2 follows continuation tokens across pages", %{bucket: bucket} do
      keys = for n <- 1..3, do: "cake-documents/default/books/page_#{n}"
      Enum.each(keys, &put_object!(bucket, &1, "x"))

      # A page size below the key count forces a second page; the default
      # page size (S3's maximum) lists the same keys in one.
      assert object_keys!(bucket, 2) == keys
      assert object_keys!(bucket) == keys
    end

    test "object_keys!/1 raises for a bucket that does not exist" do
      missing = new_bucket_name()

      assert_raise RuntimeError, ~r/#{missing}/, fn -> object_keys!(missing) end
    end

    test "bucket_names!/0 lists the buckets in the store", context do
      assert context.bucket in bucket_names!()
      refute new_bucket_name() in bucket_names!()
    end

    test "create_bucket!/1 creates the named bucket and returns its name", context do
      name = unique_bucket_name(context)
      record(context.ledger, name)

      assert create_bucket!(name) == name
      assert bucket_exists?(name)
    end

    test "drop_bucket!/1 removes the objects and the bucket, and is a no-op once it is gone",
         context do
      name = create_bucket!(unique_bucket_name(context))
      record(context.ledger, name)
      put_object!(name, "cake-documents/default/books/x", "x")

      assert :ok = drop_bucket!(name)
      refute bucket_exists?(name)
      assert :ok = drop_bucket!(name)
    end

    test "drop_buckets!/1 drops every bucket under a prefix, and is idempotent for an empty one",
         context do
      prefix = unique_bucket_name(context)
      first = create_bucket!(prefix <> "-a")
      second = create_bucket!(prefix <> "-b")
      record(context.ledger, first)
      record(context.ledger, second)
      put_object!(second, "cake-documents/default/books/x", "x")

      assert :ok = drop_buckets!(prefix)
      refute bucket_exists?(first)
      refute bucket_exists?(second)
      assert :ok = drop_buckets!(prefix)
    end
  end

  describe "automatic teardown" do
    test "drops the test's bucket even with objects in it", context do
      put_object!(context.bucket, "cake-documents/default/books/kept", "until teardown")
      record(context.ledger, context.bucket)
    end

    test "drops derived buckets too", context do
      derived = create_bucket!(unique_bucket_name(context))
      put_object!(derived, "cake-documents/default/books/kept", "until teardown")
      record(context.ledger, derived)
    end

    test "drops the bucket even if the test re-pointed ExAws elsewhere", context do
      record(context.ledger, context.bucket)
      configure_s3!(port: 1, retries: [max_attempts: 1])
    end

    test "drops the bucket even if the test removed the ExAws config", context do
      record(context.ledger, context.bucket)
      Application.delete_env(:ex_aws, :s3)
    end
  end

  test "await_endpoint!/0 returns :ok while the store answers" do
    assert :ok = S3IntegrationCase.await_endpoint!()
  end
end
