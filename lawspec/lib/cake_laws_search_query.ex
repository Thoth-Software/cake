# User-owned LawSpec adapter for laws/search_query.lawspec.
defmodule Cake.Laws.SearchQuery do
  @moduledoc """
  Adapts `Cake.Search.Query` and
  `Cake.Search.Backend.OpenSearch.to_query_map/1` to the
  `cake.laws.search_query` unit.

  A generated start becomes a `Query.new/2` call and each generated builder
  call the `Cake.Search.Query` call it names, in order. An option the
  specification leaves absent is not passed, so the builders' own defaults
  run: `new/1` for a start with no options, `knn/4` for a clause with no
  `ef_search`, `match/3` for a match with no boost.

  Cake holds vectors, boosts and minimum scores as floats and only stores
  them. The specification generates whole hundredths; they are divided by
  100 on the way in and multiplied back on the way out, so equal hundredths
  are equal floats.

  The translation back is strict on purpose, so a shape the specification
  does not name fails the law instead of passing through. A clause, a clause
  body or a query map with a key besides the ones named here has no clause:
  a knn body is `"vector"` and `"k"` alone, or those and a
  `"method_parameters"` that holds `"ef_search"` alone, and a query map has a
  `:min_score` key only when the score is a float.
  """

  alias Cake.Search.Backend.OpenSearch
  alias Cake.Search.Query
  alias LawSpec.Data.BuilderCallClearMinScore
  alias LawSpec.Data.BuilderCallFilterTerm
  alias LawSpec.Data.BuilderCallKnn
  alias LawSpec.Data.BuilderCallMatch
  alias LawSpec.Data.BuilderCallMatchUnboosted
  alias LawSpec.Data.BuilderCallMinScore
  alias LawSpec.Data.BuilderCallSize
  alias LawSpec.Data.BuiltQuery
  alias LawSpec.Data.KnnClause
  alias LawSpec.Data.MatchArgs
  alias LawSpec.Data.MatchClause
  alias LawSpec.Data.QueryMap
  alias LawSpec.Data.Start
  alias LawSpec.Data.TermClause
  alias LawSpec.Data.TermValueBoolValue
  alias LawSpec.Data.TermValueIntegerValue
  alias LawSpec.Data.TermValueTextValue

  @doc """
  `Query.new/2` of `start`, then `calls` in order: the `%Query{}` struct,
  field for field, its clause lists in the order the struct holds them.
  """
  @spec built_query(LawSpec.Data.start(), [LawSpec.Data.builder_call()]) ::
          LawSpec.Data.built_query()
  def built_query(%Start{} = start, calls) when is_list(calls) do
    %Query{} = query = build(start, calls)

    %BuiltQuery{
      index: query.index,
      size: query.size,
      min_score: to_maybe_hundredths(query.min_score),
      musts: Enum.map(query.must, &to_knn_clause/1),
      shoulds: Enum.map(query.should, &to_match_clause/1),
      filters: Enum.map(query.filter, &to_term_clause/1)
    }
  end

  @doc """
  `Backend.OpenSearch.to_query_map/1` of the query `built_query/2` reads: the
  map, with an absent `min_score` for a map that has no `:min_score` key.
  """
  @spec query_map(LawSpec.Data.start(), [LawSpec.Data.builder_call()]) :: LawSpec.Data.query_map()
  def query_map(%Start{} = start, calls) when is_list(calls) do
    start
    |> build(calls)
    |> OpenSearch.to_query_map()
    |> to_query_map()
  end

  defp build(%Start{index: index, size: size, min_score: min_score}, calls) do
    Enum.reduce(calls, new_query(index, new_opts(size, min_score)), &apply_call/2)
  end

  defp new_query(index, []), do: Query.new(index)
  defp new_query(index, opts), do: Query.new(index, opts)

  # An absent option is left out, as in a call that does not pass it.
  defp new_opts(size, min_score) do
    for {key, {:present, value}} <- [size: size, min_score: from_maybe_hundredths(min_score)] do
      {key, value}
    end
  end

  defp apply_call(%BuilderCallKnn{value: %KnnClause{ef_search: :absent} = clause}, query) do
    Query.knn(query, clause.field, from_vector(clause.vector), clause.k)
  end

  defp apply_call(%BuilderCallKnn{value: %KnnClause{ef_search: {:present, ef}} = clause}, query) do
    Query.knn(query, clause.field, from_vector(clause.vector), clause.k, ef_search: ef)
  end

  defp apply_call(%BuilderCallMatch{value: %MatchClause{} = clause}, query) do
    Query.match(query, clause.text, clause.fields, boost: from_hundredths(clause.boost))
  end

  defp apply_call(%BuilderCallMatchUnboosted{value: %MatchArgs{} = args}, query) do
    Query.match(query, args.text, args.fields)
  end

  defp apply_call(%BuilderCallFilterTerm{value: %TermClause{} = clause}, query) do
    Query.filter_term(query, clause.field, from_term_value(clause.value))
  end

  defp apply_call(%BuilderCallMinScore{value: score}, query) do
    Query.min_score(query, from_hundredths(score))
  end

  defp apply_call(%BuilderCallClearMinScore{}, query), do: Query.min_score(query, nil)
  defp apply_call(%BuilderCallSize{value: size}, query), do: Query.size(query, size)

  defp to_knn_clause(%{"knn" => by_field} = clause)
       when map_size(clause) == 1 and map_size(by_field) == 1 do
    [{field, body}] = Map.to_list(by_field)
    {vector, k, ef_search} = knn_body(body)
    %KnnClause{field: field, vector: to_vector(vector), k: k, ef_search: ef_search}
  end

  defp knn_body(%{"vector" => vector, "k" => k} = body) when map_size(body) == 2 do
    {vector, k, :absent}
  end

  defp knn_body(%{"vector" => vector, "k" => k, "method_parameters" => parameters} = body)
       when map_size(body) == 3 do
    %{"ef_search" => ef_search} = parameters
    1 = map_size(parameters)
    {vector, k, {:present, ef_search}}
  end

  defp to_match_clause(%{"multi_match" => body} = clause) when map_size(clause) == 1 do
    %{"query" => text, "fields" => fields, "boost" => boost} = body
    3 = map_size(body)
    %MatchClause{text: text, fields: fields, boost: to_hundredths(boost)}
  end

  defp to_term_clause(%{"term" => by_field} = clause)
       when map_size(clause) == 1 and map_size(by_field) == 1 do
    [{field, value}] = Map.to_list(by_field)
    %TermClause{field: field, value: to_term_value(value)}
  end

  defp to_query_map(%{size: size, query: %{bool: bool} = query} = map)
       when map_size(query) == 1 and map_size(bool) == 3 do
    %{must: must, should: should, filter: filter} = bool

    %QueryMap{
      size: size,
      min_score: map_min_score(map),
      musts: Enum.map(must, &to_knn_clause/1),
      shoulds: Enum.map(should, &to_match_clause/1),
      filters: Enum.map(filter, &to_term_clause/1)
    }
  end

  # A map with a `:min_score` of `nil` has no clause here: `to_hundredths/1`
  # takes a float.
  defp map_min_score(%{min_score: score} = map) when map_size(map) == 3 do
    {:present, to_hundredths(score)}
  end

  defp map_min_score(map) when map_size(map) == 2 and not is_map_key(map, :min_score) do
    :absent
  end

  defp from_term_value(%TermValueTextValue{value: value}) when is_binary(value), do: value
  defp from_term_value(%TermValueIntegerValue{value: value}) when is_integer(value), do: value
  defp from_term_value(%TermValueBoolValue{value: value}) when is_boolean(value), do: value

  defp to_term_value(value) when is_binary(value), do: %TermValueTextValue{value: value}
  defp to_term_value(value) when is_integer(value), do: %TermValueIntegerValue{value: value}
  defp to_term_value(value) when is_boolean(value), do: %TermValueBoolValue{value: value}

  defp from_vector(vector) when is_list(vector), do: Enum.map(vector, &from_hundredths/1)
  defp to_vector(vector) when is_list(vector), do: Enum.map(vector, &to_hundredths/1)

  defp from_hundredths(hundredths) when is_integer(hundredths), do: hundredths / 100
  defp to_hundredths(float) when is_float(float), do: round(float * 100)

  defp from_maybe_hundredths(:absent), do: :absent
  defp from_maybe_hundredths({:present, hundredths}), do: {:present, from_hundredths(hundredths)}

  defp to_maybe_hundredths(nil), do: :absent
  defp to_maybe_hundredths(float), do: {:present, to_hundredths(float)}
end
