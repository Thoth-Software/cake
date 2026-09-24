defmodule Cake.S3IntegrationCase do
  @moduledoc """
  Case template for tests that talk to a real S3-compatible object store
  (#251). Stub: compiles the contract tests, implements nothing.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @moduletag :integration

      import Cake.S3IntegrationCase
    end
  end

  setup do
    :ok
  end

  @typedoc "The `:s3` service config `configure_s3!/1` replaced; `nil` when there was none."
  @type config_snapshot :: keyword() | nil

  @spec env_var() :: String.t()
  def env_var, do: not_implemented!()

  @spec endpoint_url() :: String.t()
  def endpoint_url, do: not_implemented!()

  @spec endpoint_config(String.t()) :: keyword()
  def endpoint_config(_url), do: not_implemented!()

  @spec access_key_id() :: String.t()
  def access_key_id, do: not_implemented!()

  @spec secret_access_key() :: String.t()
  def secret_access_key, do: not_implemented!()

  @spec region() :: String.t()
  def region, do: not_implemented!()

  @spec configure_s3!(keyword()) :: config_snapshot()
  def configure_s3!(_overrides \\ []), do: not_implemented!()

  @spec restore_config!(config_snapshot()) :: :ok
  def restore_config!(_snapshot), do: not_implemented!()

  @spec s3_config?() :: boolean()
  def s3_config?, do: not_implemented!()

  @spec await_endpoint!() :: :ok
  def await_endpoint!, do: not_implemented!()

  @spec new_bucket_name() :: String.t()
  def new_bucket_name, do: not_implemented!()

  @spec create_bucket!(String.t()) :: String.t()
  def create_bucket!(_name \\ ""), do: not_implemented!()

  @spec bucket_exists?(String.t()) :: boolean()
  def bucket_exists?(_bucket), do: not_implemented!()

  @spec object_keys!(String.t()) :: [String.t()]
  def object_keys!(_bucket), do: not_implemented!()

  @spec bucket_names!() :: [String.t()]
  def bucket_names!, do: not_implemented!()

  @spec unique_bucket_name(map()) :: String.t()
  def unique_bucket_name(_context), do: not_implemented!()

  @spec drop_bucket!(String.t()) :: :ok
  def drop_bucket!(_bucket), do: not_implemented!()

  @spec drop_buckets!(String.t()) :: :ok
  def drop_buckets!(_prefix), do: not_implemented!()

  defp not_implemented!, do: raise("Cake.S3IntegrationCase is not implemented yet (#251)")
end
