defmodule Cake.Documents.ClusterTest do
  use ExUnit.Case, async: false

  alias Cake.Documents.Cluster

  describe "build_mapping/1" do
    test "uses :default_embedding_dimension from config for the knn_vector field" do
      original = Application.get_env(:cake, :default_embedding_dimension)
      Application.put_env(:cake, :default_embedding_dimension, 3072)

      on_exit(fn ->
        if is_nil(original) do
          Application.delete_env(:cake, :default_embedding_dimension)
        else
          Application.put_env(:cake, :default_embedding_dimension, original)
        end
      end)

      mapping = Cluster.build_mapping(Cake.Books.Chunk)

      assert get_in(mapping, [:mappings, :properties, :embedding, :dimension]) == 3072
    end

    test "defaults to 1536 (matches text-embedding-ada-002 / 3-small) when config is set" do
      Application.put_env(:cake, :default_embedding_dimension, 1536)

      mapping = Cluster.build_mapping(Cake.Books.Chunk)

      assert get_in(mapping, [:mappings, :properties, :embedding, :dimension]) == 1536
    end
  end
end
