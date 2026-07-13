defmodule Cake.Search.Query do
  @moduledoc """
  Backend-agnostic composable query builder.

  Each builder function returns a new `%Query{}` with a clause appended or a
  scalar field overwritten. Translation to a backend-specific format (e.g.
  OpenSearch bool queries) is handled by each backend's implementation.

  The outer query envelope uses atom keys for compile-time safety. Clause
  contents use string keys because their schema belongs to the search
  backend, not to this module.

  ## Example

      alias Cake.Search.Query

      Query.new("chunks_of_books", size: 30)
      |> Query.knn("embedding", my_vector, 30)
      |> Query.match("GenServer", ["section_title^2", "text"], boost: 0.8)
      |> Query.filter_term("language", "Elixir")
  """

  @enforce_keys [:index]
  defstruct [:index, :min_score, size: 10, must: [], should: [], filter: []]

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

  @doc "Appends a knn clause to `must`. Accepts an optional `:ef_search` keyword."
  @spec knn(t(), String.t(), [float()], pos_integer(), keyword()) :: t()
  def knn(%__MODULE__{} = query, field, vector, k, opts \\ [])
      when is_binary(field) and is_list(vector) and is_integer(k) and k > 0 do
    base = %{"vector" => vector, "k" => k}

    body =
      case Keyword.get(opts, :ef_search) do
        nil -> base
        ef when is_integer(ef) -> Map.put(base, "ef_search", ef)
      end

    clause = %{"knn" => %{field => body}}
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
end
