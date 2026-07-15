defmodule Cake.Search.Backend.OpenSearch do
  @moduledoc """
  OpenSearch implementation of the `Cake.Search.Backend` behaviour.

  Wraps the Snap library for all OpenSearch communication. Snap is an
  implementation detail — no other module should reference Snap types
  directly.

  Owns the translation of `%Cake.Search.Query{}` into the OpenSearch
  bool-query DSL via `to_query_map/1`.
  """

  @behaviour Cake.Search.Backend

  alias Cake.Search.Hit
  alias Cake.Search.Query

  @deployment Cake.Search.Deployment

  @impl Cake.Search.Backend
  @spec search(Query.t()) :: {:ok, [Hit.t()]} | {:error, term()}
  def search(%Query{} = query) do
    case Snap.Search.search(@deployment, query.index, to_query_map(query)) do
      {:ok, %{hits: hits}} -> {:ok, Enum.map(hits, &snap_hit_to_hit/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Cake.Search.Backend
  @spec index_document(String.t(), map(), String.t()) :: :ok | {:error, term()}
  def index_document(collection, document, id) do
    case Snap.Document.update(
           @deployment,
           collection,
           %{doc: document, doc_as_upsert: true},
           id
         ) do
      %{"_id" => _} -> :ok
      error -> {:error, error}
    end
  end

  @impl Cake.Search.Backend
  @spec delete_document(String.t(), String.t()) :: :ok | {:error, term()}
  def delete_document(collection, id) do
    case Snap.Document.delete(@deployment, collection, id) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Cake.Search.Backend
  @spec create_collection(String.t(), map()) :: :ok | {:error, term()}
  def create_collection(collection, mapping) do
    case Snap.Indexes.create(@deployment, collection, mapping) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Cake.Search.Backend
  @spec list_collections() :: {:ok, [String.t()]} | {:error, term()}
  def list_collections do
    Snap.Indexes.list(@deployment)
  end

  @doc """
  Converts a `%Query{}` into the nested map that OpenSearch expects.

  Clause lists are reversed to preserve insertion order (builders prepend).
  `min_score` is omitted when nil.
  """
  @spec to_query_map(Query.t()) :: map()
  def to_query_map(%Query{} = query) do
    base = %{
      size: query.size,
      query: %{
        bool: %{
          must: Enum.reverse(query.must),
          should: Enum.reverse(query.should),
          filter: Enum.reverse(query.filter)
        }
      }
    }

    if is_nil(query.min_score) do
      base
    else
      Map.put(base, :min_score, query.min_score)
    end
  end

  @doc """
  Builds the OpenSearch mapping for a collection based on an Ecto schema.
  """
  @spec build_mapping(module()) :: map()
  def build_mapping(schema) do
    embedding = %{
      type: "knn_vector",
      dimension: Application.get_env(:cake, :default_embedding_dimension, 1536),
      method: %{
        name: "hnsw",
        space_type: "cosinesimil",
        engine: "faiss",
        parameters: %{
          ef_construction: 512,
          m: 16
        }
      }
    }

    text_properties =
      Enum.reduce(schema.__schema__(:fields), %{}, fn field, acc ->
        case field do
          :text -> Map.merge(%{text: %{type: "text"}}, acc)
          :embedding -> Map.merge(%{embedding: embedding}, acc)
          keyword -> Map.merge(%{keyword => %{type: "keyword"}}, acc)
        end
      end)

    %{
      settings: %{
        "index.knn" => true,
        "index.refresh_interval" => "30s",
        "index.merge.policy.max_merge_at_once" => 2
      },
      mappings: %{properties: text_properties}
    }
  end

  @spec snap_hit_to_hit(Snap.Hit.t()) :: Hit.t()
  defp snap_hit_to_hit(%Snap.Hit{} = snap_hit) do
    %Hit{
      id: snap_hit.source["id"],
      score: snap_hit.score,
      source: snap_hit.source
    }
  end
end
