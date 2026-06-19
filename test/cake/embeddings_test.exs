defmodule Cake.EmbeddingsTest do
  @moduledoc """
  Audit + minimal coverage for `Cake.Embeddings`.

  ## Audit findings (#110)

  `lib/cake/embeddings.ex` is a 3-line function that:

    1. reads `:openai_key` and `:base_url` from `Application.get_env/2`,
    2. calls `Req.post/1` against the configured URL, and
    3. pattern-matches the response into `{:ok, %{usage, input, attrs}}`
       or one of two `{:error, ...}` shapes.

  There is **no batching, no title prepending, and no token-counting logic**
  in this repo (despite earlier issue text). The function is an integration
  boundary; the only meaningfully testable surface here is the
  transport-error branch, which we exercise below by pointing
  `:base_url` at an unreachable host.

  Live OpenAI calls are out of scope for unit tests and will be tagged
  `:integration` per #109.

  ## HTTP stubbing

  Successful responses are now exercised via `Req.Test`: `embed/3` reads an
  optional `:plug` from its config block (set to `{Req.Test, Cake.Embeddings}`
  in `config/test.exs`), mirroring `Cake.Generation.OpenAI`. The success test
  below stubs the OpenAI embeddings response shape and asserts the result
  threads the caller's struct through.

  ## What this file does NOT test

  - The OpenAI response-shape unhappy paths beyond transport failure —
    would require additional stubbed responses; deferred.
  """

  use ExUnit.Case, async: false

  alias Cake.Embeddings

  setup do
    original = Application.get_env(:cake, Cake.Embeddings)

    on_exit(fn ->
      if original do
        Application.put_env(:cake, Cake.Embeddings, original)
      else
        Application.delete_env(:cake, Cake.Embeddings)
      end
    end)

    :ok
  end

  describe "embed/3 transport error" do
    test "returns {:error, message} when the configured base_url is unreachable" do
      # Port 1 is reserved/unused; connections refuse immediately.
      Application.put_env(:cake, Cake.Embeddings,
        openai_key: "test-key",
        base_url: "http://127.0.0.1:1"
      )

      result = Embeddings.embed(:openai, %{input: "hello"}, "text-embedding-ada-002")

      assert {:error, message} = result
      assert is_binary(message)
      assert message =~ "Cake.Embeddings"
      assert message =~ "Application layer error"
    end
  end

  describe "embed/3 success" do
    test "threads the caller's struct through and returns the embedding attrs" do
      Req.Test.stub(Cake.Embeddings, fn conn ->
        Req.Test.json(conn, %{
          "data" => [%{"embedding" => [0.1, 0.2, 0.3], "index" => 0}],
          "usage" => %{"prompt_tokens" => 5, "total_tokens" => 5}
        })
      end)

      passed = ~D[2025-01-01]

      assert {:ok, result} =
               Embeddings.embed(
                 :openai,
                 %{input: "hello", struct: passed},
                 "text-embedding-ada-002"
               )

      assert result.struct == passed
      assert result.attrs == %{embedding: [0.1, 0.2, 0.3]}
    end
  end

  describe "Cake.Embeddings.Behaviour contract" do
    test "the @callback embed/3 is declared with the documented arity" do
      callbacks = Cake.Embeddings.Behaviour.behaviour_info(:callbacks)
      assert {:embed, 3} in callbacks
    end

    test "Cake.Embeddings implements Cake.Embeddings.Behaviour" do
      behaviours = Cake.Embeddings.module_info(:attributes)[:behaviour] || []
      assert Cake.Embeddings.Behaviour in behaviours
    end
  end
end
