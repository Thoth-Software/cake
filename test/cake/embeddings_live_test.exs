defmodule Cake.EmbeddingsLiveTest do
  @moduledoc """
  `Cake.Embeddings.embed/3` against the real OpenAI embeddings endpoint
  (#247, item 4) — the live coverage `Cake.EmbeddingsTest` deferred in
  #109/#110.

  Shapes and invariants only: the vector has the configured dimension (the
  one the OpenSearch mappings are built for) and holds floats, usage is
  integer token counts, the struct passthrough is untouched, and a wrong
  key comes back as the error tuple rather than a raise. Never the
  vector's values.
  """

  use Cake.LiveLLMCase

  alias Cake.Embeddings

  @input "The quick brown fox jumps over the lazy dog."
  @wrong_key "sk-not-a-real-key"

  # The production model and the dimension the index mappings assume. Read
  # at run time so the gate follows config, not a copy of it.
  defp model, do: Application.get_env(:cake, :default_embedding_model, "text-embedding-ada-002")
  defp dimension, do: Application.get_env(:cake, :default_embedding_dimension, 1536)

  describe "embed/3 with the configured embedding model" do
    test "returns a vector of the configured dimension, every element a float" do
      assert {:ok, %{attrs: %{embedding: vector}}} =
               Embeddings.embed(:openai, %{input: @input}, model())

      assert length(vector) == dimension()
      assert Enum.all?(vector, &is_float/1)
    end

    test "reports the provider's token usage as integer counts, and nothing else in the result" do
      assert {:ok, result} = Embeddings.embed(:openai, %{input: @input}, model())

      assert result |> Map.keys() |> Enum.sort() == [:attrs, :struct, :usage]
      assert %{"prompt_tokens" => prompt_tokens, "total_tokens" => total_tokens} = result.usage
      assert is_integer(prompt_tokens) and prompt_tokens > 0
      assert is_integer(total_tokens) and total_tokens >= prompt_tokens
    end

    test "passes the caller's struct through untouched, nil when none was given" do
      marker = %Cake.Search.Hit{id: "caller-owned", score: 1.0, source: %{}}

      assert {:ok, %{struct: ^marker}} =
               Embeddings.embed(:openai, %{input: @input, struct: marker}, model())

      assert {:ok, %{struct: nil}} = Embeddings.embed(:openai, %{input: @input}, model())
    end
  end

  describe "embed/3 with a wrong key" do
    test "returns the error tuple naming the 401 rather than raising" do
      configure_live!(@wrong_key)

      assert {:error, message} = Embeddings.embed(:openai, %{input: @input}, model())
      assert message =~ "401"
    end
  end
end
