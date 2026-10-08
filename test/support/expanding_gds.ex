defmodule Cake.Support.ExpandingGDS do
  @moduledoc """
  In-memory `Cake.GDS` implementation with a real `expand_with_neighbors/2`.

  `Cake.Support.FixtureGDS` inherits the identity expansion, which is right
  for an unordered GDS and leaves the expansion branch of `Cake.Search`'s
  result building unreachable without the Repo. This GDS fills that gap: its
  records carry an `ordinal`, and `expand_with_neighbors/2` adds every record
  of the per-test corpus within `offset` ordinals of a unit, ordered by
  ordinal and deduplicated, the way `Cake.Books.Retrieval` does for chunks.

  The corpus lives in the process dictionary (`put_corpus/1`), so a test
  seeds it in its own process and calls `Cake.Search` from that process.
  `load_from_hits/1` hydrates hits from the corpus in hit order, dropping
  ids the corpus does not know, as a Repo-backed GDS drops stale hits.
  """

  use Cake.GDS

  alias Cake.Search.Hit

  defmodule Record do
    @moduledoc false
    defstruct [:id, :ordinal, :body, :embedding, metadata: %{}]

    @type t :: %__MODULE__{
            id: String.t(),
            ordinal: non_neg_integer(),
            body: String.t(),
            embedding: [float()] | nil,
            metadata: Cake.Citable.metadata()
          }
  end

  @corpus_key {__MODULE__, :corpus}

  @doc "Seeds this process's corpus. Records are kept by id."
  @spec put_corpus([Record.t()]) :: :ok
  def put_corpus(records) when is_list(records) do
    Process.put(@corpus_key, Map.new(records, &{&1.id, &1}))
    :ok
  end

  @doc "Builds a corpus record: `id` is `r<ordinal>`, and the metadata id matches it."
  @spec record(non_neg_integer()) :: Record.t()
  def record(ordinal) when is_integer(ordinal) and ordinal >= 0 do
    id = "r#{ordinal}"

    %Record{
      id: id,
      ordinal: ordinal,
      body: "record #{ordinal}",
      embedding: nil,
      metadata: %{
        id: id,
        label: "R-#{ordinal}",
        preview: "p-#{ordinal}",
        source_ref: nil,
        extras: %{}
      }
    }
  end

  @impl Cake.GDS
  @spec collection_name() :: String.t()
  def collection_name, do: "expanding_collection"

  @impl Cake.GDS
  @spec search_fields() :: [String.t()]
  def search_fields, do: ["body"]

  @impl Cake.GDS
  @spec load_from_hits([Hit.t()]) :: [struct()]
  def load_from_hits(hits) when is_list(hits) do
    corpus = corpus()

    Enum.flat_map(hits, fn %Hit{id: id} ->
      case Map.fetch(corpus, id) do
        {:ok, record} -> [record]
        :error -> []
      end
    end)
  end

  @impl Cake.GDS
  @spec expand_with_neighbors([struct()], non_neg_integer()) :: [struct()]
  def expand_with_neighbors(units, offset) when is_list(units) and is_integer(offset) do
    ordinals = Enum.map(units, & &1.ordinal)

    corpus()
    |> Map.values()
    |> Enum.filter(fn record -> Enum.any?(ordinals, &(abs(&1 - record.ordinal) <= offset)) end)
    |> Enum.sort_by(& &1.ordinal)
  end

  defp corpus, do: Process.get(@corpus_key, %{})
end

defimpl Cake.Promptable, for: Cake.Support.ExpandingGDS.Record do
  @spec prompt_context(Cake.Support.ExpandingGDS.Record.t()) :: String.t()
  def prompt_context(%{body: body}), do: body
end

defimpl Cake.Citable, for: Cake.Support.ExpandingGDS.Record do
  @spec metadata(Cake.Support.ExpandingGDS.Record.t()) :: Cake.Citable.metadata()
  def metadata(%{metadata: m}), do: m
end
