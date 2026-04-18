defmodule Cake.Search.Query do
  @moduledoc """
  Composable query builder for OpenSearch queries.

  Built by `Cake.Search.OpenSearch` via `build/3`, then converted to the OpenSearch
  wire format by `to_opensearch/1` before being passed to `Snap.Search.search/3`.
  """

  @enforce_keys [:search_type, :index]
  defstruct [
    :search_type,
    :index,
    :keywords,
    :embedding,
    :cluster,
    fields: [],
    size: 30,
    k: 30,
    ef_search: 256,
    keyword_weight: 0.8
  ]

  @type t :: %__MODULE__{
          search_type: :keyword | :vector | :hybrid,
          index: String.t(),
          keywords: String.t() | nil,
          embedding: [float()] | nil,
          fields: [String.t()],
          size: pos_integer(),
          k: pos_integer(),
          ef_search: pos_integer(),
          keyword_weight: float(),
          cluster: module() | nil
        }

  @spec build(:keyword | :vector | :hybrid, String.t(), map()) :: t()
  def build(search_type, index, params) when is_map(params) do
    %__MODULE__{
      search_type: search_type,
      index: index,
      keywords: Map.get(params, :keywords),
      embedding: Map.get(params, :embedding),
      fields: Map.get(params, :fields, []),
      size: Map.get(params, :size, 30),
      k: Map.get(params, :k, 30),
      ef_search: Map.get(params, :ef_search, 256),
      keyword_weight: Map.get(params, :keyword_weight, 0.8),
      cluster: Map.get(params, :cluster)
    }
  end

  @spec to_opensearch(t()) :: map()
  def to_opensearch(%__MODULE__{search_type: :keyword} = q) do
    %{
      size: q.size,
      query: %{
        multi_match: %{
          query: q.keywords,
          fields: q.fields
        }
      }
    }
  end

  def to_opensearch(%__MODULE__{search_type: :vector} = q) do
    %{
      size: q.size,
      query: %{
        knn: %{
          embedding: %{
            vector: q.embedding,
            k: q.k
          }
        }
      }
    }
  end

  def to_opensearch(%__MODULE__{search_type: :hybrid} = q) do
    %{
      size: q.size,
      query: %{
        bool: %{
          must: [
            %{
              knn: %{
                embedding: %{
                  vector: q.embedding,
                  k: q.k,
                  method_parameters: %{
                    ef_search: q.ef_search
                  }
                }
              }
            }
          ],
          should: [
            %{
              multi_match: %{
                query: q.keywords,
                fields: q.fields,
                boost: q.keyword_weight
              }
            }
          ]
        }
      }
    }
  end
end
