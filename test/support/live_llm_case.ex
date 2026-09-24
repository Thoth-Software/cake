defmodule Cake.LiveLLMCase do
  @moduledoc """
  Case template for tests that call a real LLM provider (#247).

  `use Cake.LiveLLMCase` tags the module's tests `:llm`, which
  `test/test_helper.exs` excludes from every default run: only
  `mix test --only llm` runs them, in CI the `llm` job (CLAUDE.md "Live
  LLM tests"). Each test gets `Cake.Embeddings` and
  `Cake.Generation.OpenAI` pointed at OpenAI's real endpoints with the key
  from `OPENAI_KEY` — the variable `config/runtime.exs` reads in prod —
  and no `Req.Test` plug in the way; `on_exit` puts the previous
  configuration back.

  ## Fail loudly, never skip

  A live test that silently passes because no key was present is worse
  than no test: the gate would be green while guarding nothing. So
  `api_key!/0` raises when the variable is unset or blank (an unset GitHub
  secret arrives as an empty string), and the CI job is guarded on the
  PR's head living in this repository rather than soft-failing.

  ## Why `async: false` is mandatory

  The template swaps application config that is global to the VM. ExUnit
  runs every async module before any sync module, so a sync live test can
  never interleave with the `Req.Test`-driven unit tests of the same
  modules; an async one could. `use Cake.LiveLLMCase, async: true`
  therefore raises at compile time.

  ## Provoking the provider's auth error

  `configure_live!/1` is also public so a test can call it again with a
  deliberately wrong key; the template's teardown restores the original
  configuration regardless of how many times a test called it.

  ## Assertion policy

  Pin shapes and invariants — vector length, schema validity, marker
  parseability, loop termination — never generated content or reasoning
  text. Keep prompts tiny and models cheap.
  """

  use ExUnit.CaseTemplate

  @env_var "OPENAI_KEY"
  @embeddings_url "https://api.openai.com/v1/embeddings"
  @responses_url "https://api.openai.com/v1/responses"

  # The test-only transport hooks each module reads from its config block.
  # Live config must carry neither, or the "live" call never leaves the VM.
  @test_hooks %{Cake.Embeddings => :req_options, Cake.Generation.OpenAI => :plug}

  using opts do
    if Keyword.get(opts, :async, false) do
      raise ArgumentError,
            "Cake.LiveLLMCase tests cannot be async: the template swaps the " <>
              "Cake.Embeddings and Cake.Generation.OpenAI application config, " <>
              "which is global to the VM. Drop the async: true."
    end

    quote do
      @moduletag :llm

      import Cake.LiveLLMCase
    end
  end

  setup do
    snapshot = configure_live!(api_key!())
    on_exit(fn -> restore_config!(snapshot) end)
    :ok
  end

  @typedoc "The application config each live block replaced, keyed by module; `nil` when it had none."
  @type config_snapshot :: %{module() => keyword() | nil}

  @doc "The environment variable the key is read from: `#{@env_var}`."
  @spec env_var() :: String.t()
  def env_var, do: @env_var

  @doc "The real embeddings endpoint the template points `Cake.Embeddings` at."
  @spec embeddings_url() :: String.t()
  def embeddings_url, do: @embeddings_url

  @doc "The real Responses endpoint the template points `Cake.Generation.OpenAI` at."
  @spec responses_url() :: String.t()
  def responses_url, do: @responses_url

  @doc """
  The provider key from `#{@env_var}`. Raises when the variable is unset or
  blank: a live test never skips for want of a key, it fails.
  """
  @spec api_key!() :: String.t()
  def api_key! do
    case @env_var |> System.get_env("") |> String.trim() do
      "" ->
        raise """
        #{@env_var} is not set (or blank), but this test calls the real provider. \
        Live LLM tests fail rather than skip without a key: run them with \
        `#{@env_var}=... mix test --only llm`, or leave them out of the run.\
        """

      key ->
        key
    end
  end

  @doc """
  Points `Cake.Embeddings` and `Cake.Generation.OpenAI` at the real
  endpoints with `api_key`, dropping any `Req.Test` hook, and returns the
  configuration each block had before, for `restore_config!/1`.
  """
  @spec configure_live!(String.t()) :: config_snapshot()
  def configure_live!(api_key) when is_binary(api_key) do
    snapshot =
      Map.new(@test_hooks, fn {module, _hook} -> {module, Application.get_env(:cake, module)} end)

    Application.put_env(:cake, Cake.Embeddings, openai_key: api_key, base_url: @embeddings_url)

    Application.put_env(:cake, Cake.Generation.OpenAI,
      openai_key: api_key,
      response_url: @responses_url
    )

    snapshot
  end

  @doc """
  Puts back the configuration `configure_live!/1` replaced: a block that
  had none is deleted again rather than left pointing at the provider.
  """
  @spec restore_config!(config_snapshot()) :: :ok
  def restore_config!(snapshot) when is_map(snapshot) do
    Enum.each(snapshot, fn
      {module, nil} -> Application.delete_env(:cake, module)
      {module, config} -> Application.put_env(:cake, module, config)
    end)
  end

  @doc """
  The response model production conversations send: `Cake.Conversation`'s
  `:response_model` config, the key `CakeWeb.ChatLive` starts every
  conversation from. Read with `fetch!` so a missing key fails the gate
  rather than silently testing some other model. (The `:default_response_model`
  key in `config.exs` is read by nothing in `lib/`, so a gate on it would
  guard nothing.)
  """
  @spec production_response_model() :: String.t()
  def production_response_model do
    :cake
    |> Application.fetch_env!(Cake.Conversation)
    |> Keyword.fetch!(:response_model)
  end

  @doc """
  Whether both LLM modules currently point at the real endpoints with no
  test transport hook — the state a test on this template runs in.
  """
  @spec live_config?() :: boolean()
  def live_config? do
    Enum.all?(@test_hooks, fn {module, hook} ->
      config = Application.get_env(:cake, module, [])

      Keyword.get(config, url_key(module)) == live_url(module) and
        not Keyword.has_key?(config, hook)
    end)
  end

  defp url_key(Cake.Embeddings), do: :base_url
  defp url_key(Cake.Generation.OpenAI), do: :response_url

  defp live_url(Cake.Embeddings), do: @embeddings_url
  defp live_url(Cake.Generation.OpenAI), do: @responses_url
end
