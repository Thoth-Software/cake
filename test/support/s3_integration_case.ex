defmodule Cake.S3IntegrationCase do
  @moduledoc """
  Case template for tests that talk to a real S3-compatible object store
  (#251).

  `use Cake.S3IntegrationCase` tags the module's tests `:integration`,
  points ExAws's `:s3` service at the store in `S3_ENDPOINT_URL` for the
  duration of each test, creates a bucket unique to the test and sets
  `:book_storage_s3_bucket` to it — the configuration `Cake.Books.Adapters.S3`
  reads at call time — and hands the test the bucket as `:bucket`. Once the
  test is over the bucket is dropped, objects and all, and the config is put
  back however often the test re-pointed or removed it.

  ## How the store is reached

  `config/test.exs` gives ExAws no endpoint, so unit tests cannot reach an
  object store by accident (everything else exercises
  `Cake.Books.Adapters.Mock`). An integration run (`mix test --only
  integration`) needs one, so `test/test_helper.exs` calls
  `await_endpoint!/0`, which waits until the store at `S3_ENDPOINT_URL`
  (default `http://localhost:9000`, the port the `moto` service in
  `docker-compose.yml` and `quality.yml` publishes) answers HTTP, and raises
  with the local start-up command if it never does. Each test's setup then
  writes the endpoint into ExAws's `:s3` service config with
  `configure_s3!/1` and removes it again in `on_exit`.

  ## Credentials: the production posture, made explicit

  The adapter assumes IAM-role credentials in production: nothing in
  application config, ExAws's instance-role provider at run time. There is
  no instance role in a test container, so the template sends a fixed key
  pair (`access_key_id/0`, `secret_access_key/0`) through the same config
  seam; the store accepts any pair. That is the only difference between what
  the tests exercise and what production runs: the same four callbacks, the
  same ExAws request path, the same HTTP client (`config/config.exs`).

  ## Why `async: false` is mandatory

  The template swaps application config that is global to the VM — ExAws's
  `:s3` service config and `:book_storage_s3_bucket` — so two modules on it
  running at once would see each other's buckets. `use Cake.S3IntegrationCase,
  async: true` therefore raises at compile time.

  ## Provoking a request error

  `configure_s3!/1` is public and layers its argument over the endpoint
  config, so a test can re-point ExAws at a closed port (with
  `retries: [max_attempts: 1]` to skip ExAws's back-off) and watch the
  adapter answer an error rather than crash; the template's teardown
  re-points itself before dropping the bucket, so the test need not undo it.

  ## Flake hazards this template absorbs

    * Bucket names are random per test, so a crashed run leaves nothing a
      later run can collide with, and the ledger check in the template's own
      contract test can tell one test's bucket from another's.
    * S3 refuses to delete a bucket with objects in it, so `drop_bucket!/1`
      lists and deletes the objects first.
    * ex_aws_s3 parses listings with SweetXml, which Cake does not depend
      on, so `object_keys!/2` takes the raw XML and reads the keys with
      OTP's xmerl instead, following continuation tokens so a bucket with
      more keys than one page holds is still emptied.
  """

  use ExUnit.CaseTemplate

  require Record

  Record.defrecordp(
    :xml_text,
    :xmlText,
    Record.extract(:xmlText, from_lib: "xmerl/include/xmerl.hrl")
  )

  @env_var "S3_ENDPOINT_URL"
  @default_url "http://localhost:9000"
  @access_key_id "test"
  @secret_access_key "test"
  @region "us-east-1"
  @bucket_prefix "cake-test-"
  @max_page_size 1000
  @readiness_attempts 60
  @readiness_interval_ms 1_000

  using opts do
    if Keyword.get(opts, :async, false) do
      raise ArgumentError,
            "Cake.S3IntegrationCase tests cannot be async: the template swaps " <>
              "ExAws's :s3 config and :book_storage_s3_bucket, which are global " <>
              "to the VM. Drop the async: true."
    end

    quote do
      @moduletag :integration

      import Cake.S3IntegrationCase
    end
  end

  setup do
    snapshot = configure_s3!()
    previous_bucket = Application.fetch_env(:cake, :book_storage_s3_bucket)
    bucket = new_bucket_name()

    # Registered before the bucket exists so a failing `create_bucket!/1`
    # still restores the config; dropping by prefix is a no-op then.
    on_exit(fn ->
      # The test may have re-pointed or removed the config; the teardown
      # needs the endpoint, so it points ExAws there itself first. What that
      # replaces is the test's leftovers, not worth keeping: `snapshot` below
      # is what goes back.
      _leftover = configure_s3!()
      drop_buckets!(bucket)
      restore_config!(snapshot)
      restore_bucket_config(previous_bucket)
    end)

    _bucket = create_bucket!(bucket)
    Application.put_env(:cake, :book_storage_s3_bucket, bucket)

    %{bucket: bucket}
  end

  @typedoc "The `:s3` service config `configure_s3!/1` replaced; `nil` when there was none."
  @type config_snapshot :: keyword() | nil

  @doc "The environment variable the endpoint is read from: `#{@env_var}`."
  @spec env_var() :: String.t()
  def env_var, do: @env_var

  @doc "The store's URL: `#{@env_var}`, or `#{@default_url}`."
  @spec endpoint_url() :: String.t()
  def endpoint_url, do: System.get_env(@env_var, @default_url)

  @doc """
  The `scheme`, `host` and `port` ExAws's `:s3` service config takes,
  from an http(s) URL. The port defaults from the scheme when the URL names
  none. Raises `ArgumentError` for anything else — a URL with no scheme
  would otherwise point ExAws at nothing in particular.
  """
  @spec endpoint_config(String.t()) :: keyword()
  def endpoint_config(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host, port: port}}
      when scheme in ["http", "https"] and is_binary(host) and host != "" and is_integer(port) ->
        [scheme: scheme <> "://", host: host, port: port]

      _other ->
        raise ArgumentError,
              "#{inspect(url)} is not an http(s) URL with a host " <>
                "(the shape #{@env_var} takes, e.g. #{@default_url})"
    end
  end

  @doc "The access key id the template sends; the store accepts any pair."
  @spec access_key_id() :: String.t()
  def access_key_id, do: @access_key_id

  @doc "The secret access key the template sends; the store accepts any pair."
  @spec secret_access_key() :: String.t()
  def secret_access_key, do: @secret_access_key

  @doc "The region the template signs requests for: ExAws's own default."
  @spec region() :: String.t()
  def region, do: @region

  @doc """
  Points ExAws's `:s3` service at the store — `endpoint_config/1` of
  `endpoint_url/0`, the fixed key pair and `region/0` — with `overrides`
  merged on top, and returns the config it replaced, for
  `restore_config!/1`.
  """
  @spec configure_s3!(keyword()) :: config_snapshot()
  def configure_s3!(overrides \\ []) when is_list(overrides) do
    previous = Application.get_env(:ex_aws, :s3)

    config =
      endpoint_url()
      |> endpoint_config()
      |> Keyword.merge(
        access_key_id: @access_key_id,
        secret_access_key: @secret_access_key,
        region: @region
      )
      |> Keyword.merge(overrides)

    Application.put_env(:ex_aws, :s3, config)
    previous
  end

  @doc """
  Puts back the `:s3` config `configure_s3!/1` replaced: a service that
  had none is left with none again rather than pointing at the store.
  """
  @spec restore_config!(config_snapshot()) :: :ok
  def restore_config!(nil), do: Application.delete_env(:ex_aws, :s3)
  def restore_config!(config) when is_list(config), do: Application.put_env(:ex_aws, :s3, config)

  @doc """
  Whether ExAws's `:s3` service currently points at the store with the
  template's key pair — the state a test on this template runs in until it
  calls `configure_s3!/1` with overrides.
  """
  @spec s3_config?() :: boolean()
  def s3_config? do
    config = Application.get_env(:ex_aws, :s3, [])

    expected =
      endpoint_url()
      |> endpoint_config()
      |> Keyword.merge(access_key_id: @access_key_id, secret_access_key: @secret_access_key)

    Enum.all?(expected, fn {key, value} -> Keyword.get(config, key) == value end)
  end

  @doc """
  Waits until the store at `endpoint_url/0` answers HTTP — any response
  counts; a store that is up but unauthenticated still answers — and raises
  with the URL and the local start-up command if it never does. Run once per
  integration run from `test/test_helper.exs`, never from a test: a store
  started moments ago by `docker compose up` takes a while to answer, and
  CI's health check already guarantees it.
  """
  @spec await_endpoint!() :: :ok
  def await_endpoint!, do: await_endpoint!(@readiness_attempts)

  @doc "A bucket name unique to the caller, under the `#{@bucket_prefix}` prefix, valid for S3."
  @spec new_bucket_name() :: String.t()
  def new_bucket_name do
    @bucket_prefix <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  @doc """
  Derives a further bucket name unique to the calling test, under the same
  prefix as its `:bucket`, so the template's teardown drops it too.
  """
  @spec unique_bucket_name(map()) :: String.t()
  def unique_bucket_name(%{bucket: prefix}) when is_binary(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end

  @doc "Creates the bucket `name` in `region/0` and returns the name. Raises if the store refuses."
  @spec create_bucket!(String.t()) :: String.t()
  def create_bucket!(name) when is_binary(name) do
    case name |> ExAws.S3.put_bucket(@region) |> ExAws.request() do
      {:ok, _response} -> name
      {:error, error} -> raise "could not create bucket #{name}: #{inspect(error)}"
    end
  end

  @doc """
  Whether `bucket` exists. A 404 is `false`; any other failure raises, so
  a store that cannot be reached never reads as "already gone".
  """
  @spec bucket_exists?(String.t()) :: boolean()
  def bucket_exists?(bucket) when is_binary(bucket) do
    case bucket |> ExAws.S3.head_bucket() |> ExAws.request() do
      {:ok, _response} -> true
      {:error, {:http_error, 404, _response}} -> false
      {:error, error} -> raise "could not check bucket #{bucket}: #{inspect(error)}"
    end
  end

  @doc """
  Every key in `bucket`, in the order the store lists them (S3 sorts by
  key), across every page of the listing. `page_size` is S3's `max-keys`:
  its default, 1000, is also its maximum, and a smaller value only exists
  so a test can exercise the continuation. Raises if the bucket cannot be
  listed, e.g. does not exist.
  """
  @spec object_keys!(String.t(), pos_integer()) :: [String.t()]
  def object_keys!(bucket, page_size \\ @max_page_size)
      when is_binary(bucket) and is_integer(page_size) and page_size > 0 do
    list_keys(bucket, page_size, nil, [])
  end

  # One page per request; `token` is the previous page's continuation
  # token, `nil` for the first. ex_aws_s3 parses the listing with SweetXml,
  # which is not a dependency here; take the raw XML and read it with
  # xmerl instead.
  defp list_keys(bucket, page_size, token, acc) do
    opts = [max_keys: page_size] ++ if(token, do: [continuation_token: token], else: [])
    operation = %{ExAws.S3.list_objects_v2(bucket, opts) | parser: &Function.identity/1}

    case ExAws.request(operation) do
      {:ok, %{body: xml}} ->
        keys = acc ++ keys_from_listing(xml)

        case next_continuation_token(xml) do
          nil -> keys
          next -> list_keys(bucket, page_size, next, keys)
        end

      {:error, error} ->
        raise "could not list bucket #{bucket}: #{inspect(error)}"
    end
  end

  @doc "Every bucket in the store, as it lists them. Raises if the store cannot be listed."
  @spec bucket_names!() :: [String.t()]
  def bucket_names! do
    operation = %{ExAws.S3.list_buckets() | parser: &Function.identity/1}

    case ExAws.request(operation) do
      {:ok, %{body: xml}} -> names_from_listing(xml)
      {:error, error} -> raise "could not list buckets: #{inspect(error)}"
    end
  end

  @doc """
  Drops every bucket whose name starts with `prefix` (`drop_bucket!/1` on
  each). A prefix with nothing under it is a no-op. Raises on any store
  error.
  """
  @spec drop_buckets!(String.t()) :: :ok
  def drop_buckets!(prefix) when is_binary(prefix) do
    bucket_names!()
    |> Enum.filter(&String.starts_with?(&1, prefix))
    |> Enum.each(&drop_bucket!/1)
  end

  @doc """
  Deletes every object in `bucket`, then the bucket. A bucket that does not
  exist is a no-op. Raises on any other store error.
  """
  @spec drop_bucket!(String.t()) :: :ok
  def drop_bucket!(bucket) when is_binary(bucket) do
    if bucket_exists?(bucket) do
      Enum.each(object_keys!(bucket), &delete_object!(bucket, &1))
      delete_bucket!(bucket)
    else
      :ok
    end
  end

  defp delete_object!(bucket, key) do
    case bucket |> ExAws.S3.delete_object(key) |> ExAws.request() do
      {:ok, _response} -> :ok
      {:error, error} -> raise "could not delete #{key} from #{bucket}: #{inspect(error)}"
    end
  end

  defp delete_bucket!(bucket) do
    case bucket |> ExAws.S3.delete_bucket() |> ExAws.request() do
      {:ok, _response} -> :ok
      {:error, error} -> raise "could not delete bucket #{bucket}: #{inspect(error)}"
    end
  end

  defp keys_from_listing(xml), do: text_nodes(xml, ~c"//Contents/Key/text()")
  defp names_from_listing(xml), do: text_nodes(xml, ~c"//Buckets/Bucket/Name/text()")

  # The token for the page after `xml`, or nil on the last page. S3 sends
  # IsTruncated with every page and the token only on a truncated one.
  defp next_continuation_token(xml) do
    case text_nodes(xml, ~c"//IsTruncated/text()") do
      ["true"] -> xml |> text_nodes(~c"//NextContinuationToken/text()") |> List.first()
      _false -> nil
    end
  end

  defp text_nodes(xml, xpath) when is_binary(xml) do
    {document, _rest} = xml |> String.to_charlist() |> :xmerl_scan.string(quiet: true)

    xpath
    |> :xmerl_xpath.string(document)
    |> Enum.map(fn node -> node |> xml_text(:value) |> List.to_string() end)
  end

  defp restore_bucket_config(:error), do: Application.delete_env(:cake, :book_storage_s3_bucket)

  defp restore_bucket_config({:ok, bucket}),
    do: Application.put_env(:cake, :book_storage_s3_bucket, bucket)

  # Readiness probe: any HTTP response means the store is up.
  defp await_endpoint!(attempts_left) do
    case Req.get(endpoint_url(), retry: false, receive_timeout: 2_000) do
      {:ok, %Req.Response{}} ->
        :ok

      {:error, _error} when attempts_left > 1 ->
        Process.sleep(@readiness_interval_ms)
        await_endpoint!(attempts_left - 1)

      {:error, error} ->
        raise """
        No S3-compatible store at #{endpoint_url()} after #{@readiness_attempts} attempts: \
        #{inspect(error)}

        Start one with `docker compose up -d moto`, or point #{@env_var} at a running \
        store.\
        """
    end
  end
end
