defmodule Cake.QueryGenerators do
  @moduledoc """
  StreamData generators for `Cake.Search.Query` property tests.

  Generators return `StreamData.t(value)` and can be composed with standard
  StreamData combinators. `apply_step/2` and `apply_sequence/2` interpret the
  tagged-tuple format produced by `builder_step/0` and `builder_sequence/0`.
  """

  alias Cake.Search.Query

  @type step ::
          {:knn, String.t(), [float()], pos_integer()}
          | {:match, String.t(), [String.t()], keyword()}
          | {:filter_term, String.t(), String.t()}
          | {:min_score, number()}
          | {:size, pos_integer()}

  @doc "Generates small maps with string keys and string/integer values."
  @spec clause_map() :: StreamData.t(map())
  def clause_map do
    StreamData.map_of(
      StreamData.string(:alphanumeric, min_length: 1, max_length: 8),
      StreamData.one_of([
        StreamData.string(:alphanumeric),
        StreamData.integer()
      ]),
      max_length: 3
    )
  end

  @doc "Generates short alphanumeric index names."
  @spec index_name() :: StreamData.t(String.t())
  def index_name do
    StreamData.string(:alphanumeric, min_length: 1, max_length: 16)
  end

  @doc "Generates a float list of the given dimension (default 4)."
  @spec vector(pos_integer()) :: StreamData.t([float()])
  def vector(dimension \\ 4) do
    StreamData.list_of(
      StreamData.float(min: -1.0e6, max: 1.0e6),
      length: dimension
    )
  end

  @doc "Generates complete `%Query{}` structs with random field values."
  @spec query() :: StreamData.t(Query.t())
  def query do
    StreamData.map(
      StreamData.tuple({
        index_name(),
        StreamData.positive_integer(),
        StreamData.list_of(clause_map(), max_length: 5),
        StreamData.list_of(clause_map(), max_length: 5),
        StreamData.list_of(clause_map(), max_length: 5),
        StreamData.one_of([
          StreamData.constant(nil),
          StreamData.float(min: 0.0, max: 1.0)
        ])
      }),
      fn {index, size, must, should, filter, min_score} ->
        %Query{
          index: index,
          size: size,
          must: must,
          should: should,
          filter: filter,
          min_score: min_score
        }
      end
    )
  end

  @doc "Generates a tagged tuple representing a single builder call."
  @spec builder_step() :: StreamData.t(step())
  def builder_step do
    StreamData.one_of([knn_step(), match_step(), filter_term_step(), min_score_step(), size_step()])
  end

  @doc "Generates a list of builder steps."
  @spec builder_sequence() :: StreamData.t([step()])
  def builder_sequence do
    StreamData.list_of(builder_step(), max_length: 10)
  end

  @doc "Applies a single builder step to a query."
  @spec apply_step(Query.t(), step()) :: Query.t()
  def apply_step(query, {:knn, field, vec, k}), do: Query.knn(query, field, vec, k)
  def apply_step(query, {:match, text, fields, opts}), do: Query.match(query, text, fields, opts)
  def apply_step(query, {:filter_term, field, value}), do: Query.filter_term(query, field, value)
  def apply_step(query, {:min_score, score}), do: Query.min_score(query, score)
  def apply_step(query, {:size, size}), do: Query.size(query, size)

  @doc "Applies a sequence of builder steps to a query in order."
  @spec apply_sequence(Query.t(), [step()]) :: Query.t()
  def apply_sequence(query, steps) do
    Enum.reduce(steps, query, fn step, acc -> apply_step(acc, step) end)
  end

  defp knn_step do
    StreamData.map(
      StreamData.tuple({
        StreamData.string(:alphanumeric, min_length: 1),
        vector(),
        StreamData.positive_integer()
      }),
      fn {field, vec, k} -> {:knn, field, vec, k} end
    )
  end

  defp match_step do
    StreamData.map(
      StreamData.tuple({
        StreamData.string(:alphanumeric, min_length: 1),
        StreamData.list_of(
          StreamData.string(:alphanumeric, min_length: 1),
          min_length: 1,
          max_length: 3
        ),
        StreamData.float(min: 0.1, max: 5.0)
      }),
      fn {text, fields, boost} -> {:match, text, fields, [boost: boost]} end
    )
  end

  defp filter_term_step do
    StreamData.map(
      StreamData.tuple({
        StreamData.string(:alphanumeric, min_length: 1),
        StreamData.string(:alphanumeric)
      }),
      fn {field, value} -> {:filter_term, field, value} end
    )
  end

  defp min_score_step do
    StreamData.map(
      StreamData.float(min: 0.0, max: 1.0),
      fn score -> {:min_score, score} end
    )
  end

  defp size_step do
    StreamData.map(
      StreamData.positive_integer(),
      fn size -> {:size, size} end
    )
  end
end
