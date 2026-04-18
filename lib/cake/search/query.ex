defmodule Cake.Search.Query do
  @moduledoc """
  Composable query builder for OpenSearch queries.

  Builders operate on a `%Query{}` struct. Each builder either appends a clause
  to one of the bool lists or sets a scalar field. `to_query_map/1` converts the
  struct to the nested map OpenSearch expects.

  The outer query envelope uses atom keys for compile-time safety. Clause
  contents are plain maps whose schema belongs to OpenSearch, not to this module.

  ## Example

      alias Cake.Search.Query

      Query.new("docs", size: 20)
      |> Query.knn("embedding", my_vector, 10)
      |> Query.match("GenServer", ["title", "text"], boost: 2.0)
      |> Query.filter_term("language", "Elixir")
      |> Query.min_score(0.5)
      |> Query.to_query_map()
  """

  @enforce_keys [:index]
  defstruct [:index, size: 10, must: [], should: [], filter: [], min_score: nil]

  @type t :: %__MODULE__{
          index: String.t(),
          size: pos_integer(),
          must: [map()],
          should: [map()],
          filter: [map()],
          min_score: number() | nil
        }

  @doc "Creates a new query for the given index. Accepts `:size` and `:min_score` options."
  @spec new(String.t(), keyword()) :: t()
  def new(index, opts \\ []) when is_binary(index) do
    %__MODULE__{
      index: index,
      size: Keyword.get(opts, :size, 10),
      min_score: Keyword.get(opts, :min_score, nil)
    }
  end

  @doc "Appends a knn clause to `must`."
  @spec knn(t(), String.t(), [float()], pos_integer()) :: t()
  def knn(%__MODULE__{} = query, field, vector, k)
      when is_binary(field) and is_list(vector) and is_integer(k) and k > 0 do
    clause = %{"knn" => %{field => %{"vector" => vector, "k" => k}}}
    %{query | must: [clause | query.must]}
  end

  @doc "Appends a multi_match clause to `should`. Accepts a `:boost` option (default 1.0)."
  @spec match(t(), String.t(), [String.t()], keyword()) :: t()
  def match(%__MODULE__{} = query, text, fields, opts \\ [])
      when is_binary(text) and is_list(fields) do
    boost = Keyword.get(opts, :boost, 1.0)
    clause = %{"multi_match" => %{"query" => text, "fields" => fields, "boost" => boost}}
    %{query | should: [clause | query.should]}
  end

  @doc "Appends a term clause to `filter`."
  @spec filter_term(t(), String.t(), term()) :: t()
  def filter_term(%__MODULE__{} = query, field, value) when is_binary(field) do
    clause = %{"term" => %{field => value}}
    %{query | filter: [clause | query.filter]}
  end

  @doc "Sets the minimum score threshold. Pass `nil` to clear."
  @spec min_score(t(), number() | nil) :: t()
  def min_score(%__MODULE__{} = query, score) do
    %{query | min_score: score}
  end

  @doc "Sets the maximum number of results to return."
  @spec size(t(), pos_integer()) :: t()
  def size(%__MODULE__{} = query, size) when is_integer(size) and size > 0 do
    %{query | size: size}
  end

  @doc """
  Converts the query struct to the nested map OpenSearch expects.

  Clause lists are reversed to preserve insertion order (builders prepend).
  `min_score` is omitted when nil.
  """
  @spec to_query_map(t()) :: map()
  def to_query_map(%__MODULE__{} = query) do
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
end
