# A module on the template, so the contract tests below can inspect what
# `use Cake.LiveLLMCase` does to a test module. Its own test is tagged :llm
# by the template and so runs only in `mix test --only llm`, where it is the
# cheapest possible check that the template's setup really ran: no network.
defmodule Cake.LiveLLMCaseTest.Tagged do
  @moduledoc false

  use Cake.LiveLLMCase

  test "the template hands the test live configuration" do
    assert Cake.LiveLLMCase.live_config?()

    refute Keyword.has_key?(Application.get_env(:cake, Cake.Generation.OpenAI), :plug)
    refute Keyword.has_key?(Application.get_env(:cake, Cake.Embeddings), :req_options)
  end
end

defmodule Cake.LiveLLMCaseTest do
  @moduledoc """
  Contract of `Cake.LiveLLMCase`, the case template behind the `:llm` tag
  (#247, item 2). Runs in the unit suite: nothing here calls a provider.

  The template must read the key from the environment and fail loudly —
  not skip — when it is absent; point `Cake.Embeddings` and
  `Cake.Generation.OpenAI` at the real endpoints for the duration of a
  test, with no `Req.Test` plug in the way; restore what it replaced
  afterwards; tag every test `:llm`; and refuse `async: true`, because
  the application config it swaps is global to the VM.
  """

  use ExUnit.Case, async: false

  alias Cake.LiveLLMCase

  @config_keys [Cake.Embeddings, Cake.Generation.OpenAI]

  setup do
    original_key = System.get_env(LiveLLMCase.env_var())
    original_config = Map.new(@config_keys, &{&1, Application.get_env(:cake, &1)})

    on_exit(fn ->
      put_or_delete_env(LiveLLMCase.env_var(), original_key)
      Enum.each(original_config, fn {key, value} -> put_or_delete_config(key, value) end)
    end)

    :ok
  end

  # Where a test module's async flag lives moved in ExUnit 1.20: it is now
  # `__ex_unit__(:config).async?`, and the runner merges `:async` into each
  # test's tags only at run time. Before 1.20 it was stamped onto every
  # test's tags at definition, and `__ex_unit__/1` does not exist.
  defp module_async?(module) do
    if function_exported?(module, :__ex_unit__, 1) do
      module.__ex_unit__(:config).async?
    else
      Enum.any?(module.__ex_unit__().tests, fn %ExUnit.Test{tags: tags} -> tags.async end)
    end
  end

  defp put_or_delete_env(name, nil), do: System.delete_env(name)
  defp put_or_delete_env(name, value), do: System.put_env(name, value)

  defp put_or_delete_config(key, nil), do: Application.delete_env(:cake, key)
  defp put_or_delete_config(key, value), do: Application.put_env(:cake, key, value)

  describe "api_key!/0" do
    test "reads the key from OPENAI_KEY, the variable runtime.exs reads in prod" do
      assert LiveLLMCase.env_var() == "OPENAI_KEY"

      System.put_env("OPENAI_KEY", "sk-test-key")
      assert LiveLLMCase.api_key!() == "sk-test-key"
    end

    test "fails loudly, naming the variable, when it is unset" do
      System.delete_env("OPENAI_KEY")

      assert_raise RuntimeError, ~r/OPENAI_KEY/, fn -> LiveLLMCase.api_key!() end
    end

    test "treats a blank value as absent (an unset GitHub secret arrives as an empty string)" do
      System.put_env("OPENAI_KEY", "")
      assert_raise RuntimeError, ~r/OPENAI_KEY/, fn -> LiveLLMCase.api_key!() end

      System.put_env("OPENAI_KEY", "   ")
      assert_raise RuntimeError, ~r/OPENAI_KEY/, fn -> LiveLLMCase.api_key!() end
    end
  end

  describe "configure_live!/1" do
    test "points Cake.Embeddings at the real endpoint with the key and no Req.Test plug" do
      LiveLLMCase.configure_live!("sk-live")

      config = Application.get_env(:cake, Cake.Embeddings)
      assert Keyword.fetch!(config, :openai_key) == "sk-live"
      assert Keyword.fetch!(config, :base_url) == LiveLLMCase.embeddings_url()
      assert LiveLLMCase.embeddings_url() == "https://api.openai.com/v1/embeddings"
      refute Keyword.has_key?(config, :req_options)
    end

    test "points Cake.Generation.OpenAI at the real Responses endpoint with the key and no plug" do
      LiveLLMCase.configure_live!("sk-live")

      config = Application.get_env(:cake, Cake.Generation.OpenAI)
      assert Keyword.fetch!(config, :openai_key) == "sk-live"
      assert Keyword.fetch!(config, :response_url) == LiveLLMCase.responses_url()
      assert LiveLLMCase.responses_url() == "https://api.openai.com/v1/responses"
      refute Keyword.has_key?(config, :plug)
    end

    test "returns what it replaced, nil for a block that had no config" do
      Application.put_env(:cake, Cake.Embeddings, openai_key: "before", base_url: "http://before")
      Application.delete_env(:cake, Cake.Generation.OpenAI)

      assert LiveLLMCase.configure_live!("sk-live") == %{
               Cake.Embeddings => [openai_key: "before", base_url: "http://before"],
               Cake.Generation.OpenAI => nil
             }
    end

    test "a second call replaces the key — how a test provokes the provider's auth error" do
      LiveLLMCase.configure_live!("sk-live")
      LiveLLMCase.configure_live!("sk-wrong")

      assert Keyword.fetch!(Application.get_env(:cake, Cake.Embeddings), :openai_key) ==
               "sk-wrong"

      assert Keyword.fetch!(Application.get_env(:cake, Cake.Generation.OpenAI), :openai_key) ==
               "sk-wrong"
    end
  end

  describe "live_config?/0" do
    test "is false under the unit-test config, which routes Generation through Req.Test" do
      refute LiveLLMCase.live_config?()
    end

    test "is true once configure_live!/1 has run" do
      LiveLLMCase.configure_live!("sk-live")
      assert LiveLLMCase.live_config?()
    end
  end

  describe "production_response_model/0" do
    test "is the :response_model Cake.Conversation is configured with, not :default_response_model" do
      assert LiveLLMCase.production_response_model() ==
               Keyword.fetch!(Application.fetch_env!(:cake, Cake.Conversation), :response_model)
    end
  end

  describe "restore_config!/1" do
    test "puts back the replaced config, deleting a block that had none" do
      Application.put_env(:cake, Cake.Embeddings, openai_key: "before", base_url: "http://before")
      Application.delete_env(:cake, Cake.Generation.OpenAI)

      snapshot = LiveLLMCase.configure_live!("sk-live")
      assert :ok = LiveLLMCase.restore_config!(snapshot)

      assert Application.get_env(:cake, Cake.Embeddings) == [
               openai_key: "before",
               base_url: "http://before"
             ]

      assert Application.get_env(:cake, Cake.Generation.OpenAI) == nil
    end
  end

  describe "use Cake.LiveLLMCase" do
    test "tags every test :llm and runs the module synchronously" do
      %ExUnit.TestModule{tests: tests} = Cake.LiveLLMCaseTest.Tagged.__ex_unit__()

      assert tests != []
      for %ExUnit.Test{tags: tags} <- tests, do: assert(tags.llm == true)

      refute module_async?(Cake.LiveLLMCaseTest.Tagged)
    end

    test "refuses async: true — the config it swaps is global to the VM" do
      assert_raise ArgumentError, ~r/async/, fn ->
        Code.compile_string("""
        defmodule Cake.LiveLLMCaseTest.RefusedAsync do
          use Cake.LiveLLMCase, async: true
        end
        """)
      end
    end
  end
end
