defmodule Cake.Search.BackendTest do
  use ExUnit.Case, async: true

  alias Cake.Search.Backend

  describe "backend/0" do
    test "returns the configured backend module" do
      original = Application.get_env(:cake, :search_backend)
      Application.put_env(:cake, :search_backend, MyFakeBackend)
      on_exit(fn -> Application.put_env(:cake, :search_backend, original) end)

      assert Backend.backend() == MyFakeBackend
    end

    test "defaults to Cake.Search.Backends.OpenSearch" do
      original = Application.get_env(:cake, :search_backend)
      Application.delete_env(:cake, :search_backend)
      on_exit(fn -> Application.put_env(:cake, :search_backend, original) end)

      assert Backend.backend() == Cake.Search.Backends.OpenSearch
    end
  end
end
