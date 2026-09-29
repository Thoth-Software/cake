defmodule Cake.S3IntegrationCaseUnitTest do
  @moduledoc """
  The pure parts of `Cake.S3IntegrationCase` (#251), as plain unit tests that
  never touch an object store: where the endpoint comes from and how a URL
  becomes ExAws's `scheme`/`host`/`port` triple, the fixed test credentials,
  bucket names that satisfy S3's naming rules and never collide, `s3_config?/0`
  under the unit-test config, and `use Cake.S3IntegrationCase` refusing
  `async: true`.

  `async: false`: the endpoint tests set and unset `S3_ENDPOINT_URL`, which is
  global to the VM.
  """

  use ExUnit.Case, async: false

  alias Cake.S3IntegrationCase

  setup do
    original = System.get_env(S3IntegrationCase.env_var())

    on_exit(fn ->
      case original do
        nil -> System.delete_env(S3IntegrationCase.env_var())
        value -> System.put_env(S3IntegrationCase.env_var(), value)
      end
    end)

    :ok
  end

  describe "endpoint_url/0" do
    test "reads S3_ENDPOINT_URL, the variable CI and docker-compose set" do
      assert S3IntegrationCase.env_var() == "S3_ENDPOINT_URL"

      System.put_env("S3_ENDPOINT_URL", "http://moto:9000")
      assert S3IntegrationCase.endpoint_url() == "http://moto:9000"
    end

    test "defaults to the moto service's published port on localhost" do
      System.delete_env("S3_ENDPOINT_URL")
      assert S3IntegrationCase.endpoint_url() == "http://localhost:9000"
    end
  end

  describe "endpoint_config/1" do
    test "splits a URL into the scheme, host and port ExAws's :s3 config takes" do
      assert S3IntegrationCase.endpoint_config("http://localhost:9000") == [
               scheme: "http://",
               host: "localhost",
               port: 9000
             ]

      assert S3IntegrationCase.endpoint_config("http://moto:9000/") == [
               scheme: "http://",
               host: "moto",
               port: 9000
             ]
    end

    test "takes the scheme's default port when the URL names none" do
      assert S3IntegrationCase.endpoint_config("https://s3.example.com") == [
               scheme: "https://",
               host: "s3.example.com",
               port: 443
             ]
    end

    test "rejects a URL with no scheme or no host rather than pointing ExAws nowhere" do
      assert_raise ArgumentError, ~r/localhost:9000/, fn ->
        S3IntegrationCase.endpoint_config("localhost:9000")
      end

      assert_raise ArgumentError, fn -> S3IntegrationCase.endpoint_config("http://") end
    end
  end

  describe "fixed credentials" do
    test "are the key pair the store accepts and the region ExAws defaults to" do
      assert S3IntegrationCase.access_key_id() == "test"
      assert S3IntegrationCase.secret_access_key() == "test"
      assert S3IntegrationCase.region() == "us-east-1"
    end
  end

  describe "new_bucket_name/0" do
    test "is a valid S3 bucket name under a recognisable test prefix" do
      name = S3IntegrationCase.new_bucket_name()

      assert name =~ ~r/^cake-test-[0-9a-f]{16}$/
      assert String.length(name) in 3..63
      assert name == String.downcase(name)
    end

    test "never hands out the same name twice" do
      names = Enum.map(1..50, fn _ -> S3IntegrationCase.new_bucket_name() end)
      assert Enum.uniq(names) == names
    end
  end

  describe "unique_bucket_name/1" do
    test "derives a valid, distinct S3 bucket name under the test's bucket" do
      context = %{bucket: "cake-test-0123456789abcdef"}
      first = S3IntegrationCase.unique_bucket_name(context)
      second = S3IntegrationCase.unique_bucket_name(context)

      assert first != second
      assert first =~ ~r/^cake-test-0123456789abcdef-[0-9]+$/
      assert String.length(first) in 3..63
    end
  end

  describe "s3_config?/0" do
    test "is false under the unit-test config, which points ExAws at nothing" do
      refute S3IntegrationCase.s3_config?()
    end
  end

  describe "use Cake.S3IntegrationCase" do
    test "refuses async: true — the config it swaps is global to the VM" do
      assert_raise ArgumentError, ~r/async/, fn ->
        Code.compile_string("""
        defmodule Cake.S3IntegrationCaseUnitTest.RefusedAsync do
          use Cake.S3IntegrationCase, async: true
        end
        """)
      end
    end
  end
end
