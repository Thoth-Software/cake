defmodule Cake.SearchIntegrationCase do
  @moduledoc """
  Case template for tests that talk to a real search cluster.

  Stub: compiles so the contract tests in
  `test/cake/search_integration_case_test.exs` can load and fail on the
  missing implementation (#245). Every helper raises until the template is
  implemented.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @moduletag :integration

      import Cake.SearchIntegrationCase
    end
  end

  setup tags do
    Cake.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc "Whether this ExUnit run includes `:integration`-tagged tests."
  @spec integration_run?() :: boolean()
  def integration_run?, do: not_implemented!(:integration_run?)

  @doc "Repoints `Cake.Search.Deployment` at the real cluster for this run."
  @spec start_real_deployment!() :: :ok
  def start_real_deployment!, do: not_implemented!(:start_real_deployment!)

  @doc "Derives a further collection name unique to the calling test."
  @spec unique_collection_name(map()) :: String.t()
  def unique_collection_name(_context), do: not_implemented!(:unique_collection_name)

  @doc "Forces a refresh so documents indexed so far become searchable."
  @spec refresh!(String.t()) :: :ok
  def refresh!(_collection), do: not_implemented!(:refresh!)

  @doc "Drops every collection whose name starts with `prefix`."
  @spec drop_collections!(String.t()) :: :ok
  def drop_collections!(_prefix), do: not_implemented!(:drop_collections!)

  defp not_implemented!(fun) do
    raise "Cake.SearchIntegrationCase.#{fun} is not implemented yet (#245)"
  end
end
