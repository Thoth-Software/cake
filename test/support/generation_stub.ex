defmodule Cake.Test.GenerationStub do
  @moduledoc """
  Test stub for `Cake.Generation`. `Cake.Conversation` calls
  `state.generation.complete(messages, model)` (2-arity), but the
  `Cake.Generation` behaviour declares `complete/3`, so the Mox-defined
  `Cake.Generation.Mock` cannot satisfy the call site. This stub exposes
  both arities and reads its configured response from a shared ETS table
  keyed by the *Conversation GenServer pid*, so concurrent conversations
  do not collide.

  ## Usage

      {:ok, pid} = start_supervised({Cake.Conversation, opts})
      Cake.Test.GenerationStub.set_response(pid, {:ok, %{text: "hi", usage: %{}}})

  Or, to inspect arguments and dynamically choose a response:

      Cake.Test.GenerationStub.set_handler(pid, fn messages, _model ->
        send(test_pid, {:captured_messages, messages})
        {:ok, %{text: "hi", usage: %{}}}
      end)

  Tests should `clear/1` after each test (or rely on `start_supervised`'s
  automatic teardown — the entry persists until overwritten or cleared,
  but a new test will start a new GenServer with a fresh pid, so stale
  entries never collide with active ones).
  """

  @behaviour Cake.Generation

  @table :cake_generation_stub_registry

  @doc """
  Idempotently creates the shared ETS table. Call once from `test_helper.exs`.
  """
  @spec setup_table() :: :ok
  def setup_table do
    _ =
      case :ets.whereis(@table) do
        :undefined -> :ets.new(@table, [:public, :named_table, :set])
        _ref -> :ok
      end

    :ok
  end

  @spec set_response(pid(), term()) :: :ok
  def set_response(conversation_pid, response) do
    :ets.insert(@table, {conversation_pid, response})
    :ok
  end

  @spec set_handler(pid(), (list(), String.t() -> term())) :: :ok
  def set_handler(conversation_pid, fun) when is_function(fun, 2) do
    :ets.insert(@table, {conversation_pid, fun})
    :ok
  end

  @spec clear(pid()) :: :ok
  def clear(conversation_pid) do
    :ets.delete(@table, conversation_pid)
    :ok
  end

  @doc "Conversation's call site — 2 args."
  @spec complete(list(), String.t()) :: term()
  def complete(messages, model), do: dispatch(self(), messages, model)

  @impl Cake.Generation
  def complete(messages, model, _opts), do: complete(messages, model)

  defp dispatch(conversation_pid, messages, model) do
    case :ets.lookup(@table, conversation_pid) do
      [{^conversation_pid, fun}] when is_function(fun, 2) -> fun.(messages, model)
      [{^conversation_pid, response}] -> response
      [] -> {:error, {:no_stub_response_for, conversation_pid}}
    end
  end
end
