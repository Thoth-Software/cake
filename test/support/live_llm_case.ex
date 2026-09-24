defmodule Cake.LiveLLMCase do
  @moduledoc """
  Case template for tests that call a real LLM provider (#247).

  Stub: compiles so the suite loads, fails every test that uses it. The
  real template arrives with item 3 of #247.
  """

  use ExUnit.CaseTemplate

  @not_implemented "Cake.LiveLLMCase is not implemented yet (#247, item 3)"

  using _opts do
    quote do
      @moduletag :llm

      import Cake.LiveLLMCase
    end
  end

  setup do
    api_key!()
    :ok
  end

  @typedoc "The application config each live block replaced, keyed by module; `nil` when it had none."
  @type config_snapshot :: %{module() => keyword() | nil}

  @doc "The environment variable the key is read from."
  @spec env_var() :: String.t()
  def env_var, do: raise(@not_implemented)

  @doc "The real embeddings endpoint the template points `Cake.Embeddings` at."
  @spec embeddings_url() :: String.t()
  def embeddings_url, do: raise(@not_implemented)

  @doc "The real Responses endpoint the template points `Cake.Generation.OpenAI` at."
  @spec responses_url() :: String.t()
  def responses_url, do: raise(@not_implemented)

  @doc "The provider key from the environment; raises when it is unset or blank."
  @spec api_key!() :: String.t()
  def api_key!, do: raise(@not_implemented)

  @doc "Points both LLM modules at the real endpoints with `api_key`; returns what it replaced."
  @spec configure_live!(String.t()) :: config_snapshot()
  def configure_live!(_api_key), do: raise(@not_implemented)

  @doc "Puts back the configuration `configure_live!/1` replaced."
  @spec restore_config!(config_snapshot()) :: :ok
  def restore_config!(_snapshot), do: raise(@not_implemented)

  @doc "Whether both LLM modules currently point at the real endpoints with no test plug."
  @spec live_config?() :: boolean()
  def live_config?, do: raise(@not_implemented)
end
