defmodule Cake.ConversationTest do
  use ExUnit.Case, async: false

  alias Cake.Conversation
  alias Cake.Support.FixtureGDS

  defp valid_opts do
    %{
      search: Cake.Search.OpenSearch,
      reply_to: self(),
      embedder: "text-embedding-ada-002",
      response_model: "gpt-4o-mini",
      provider: :openai,
      gds: FixtureGDS
    }
  end

  describe ":gds option" do
    test "start_link/1 rejects opts missing :gds" do
      opts = Map.delete(valid_opts(), :gds)

      case Conversation.start_link(opts) do
        {:error, {%KeyError{key: :gds}, _stack}} ->
          :ok

        {:error, %KeyError{key: :gds}} ->
          :ok

        other ->
          flunk("""
          expected start_link to reject opts missing :gds with a KeyError,
          got: #{inspect(other)}
          """)
      end
    end

    test "start_link/1 rejects opts with gds: nil" do
      opts = Map.put(valid_opts(), :gds, nil)

      case Conversation.start_link(opts) do
        {:error, {%KeyError{}, _stack}} ->
          :ok

        {:error, %KeyError{}} ->
          :ok

        {:error, {reason, _stack}} when is_atom(reason) or is_tuple(reason) ->
          :ok

        {:error, reason} when is_atom(reason) or is_tuple(reason) ->
          :ok

        other ->
          flunk("""
          expected start_link to reject gds: nil,
          got: #{inspect(other)}
          """)
      end
    end

    test "start_link/1 accepts opts with :gds and returns a pid" do
      {:ok, pid} = Conversation.start_link(valid_opts())
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert is_pid(pid)
      state = :sys.get_state(pid)
      assert state.gds == FixtureGDS
    end
  end
end
