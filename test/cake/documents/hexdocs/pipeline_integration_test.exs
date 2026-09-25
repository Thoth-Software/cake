defmodule Cake.Documents.Hexdocs.PipelineIntegrationTest do
  @moduledoc """
  The Hexdocs ingestion pipeline end to end (#248): a real `git clone` of
  one small tagged Elixir release, `Cake.Documents.Pipeline.ingest/4` over
  it, real `Hexdoc` and `ParsedDocument` rows in Postgres, real documents
  in the `docs` collection of a real OpenSearch node, and
  `retry_from_raw/2` re-parsing from the persisted raw rows alone.

  Tagged `:network` instead of `:integration` (`network: true` on the case
  template): `download/1` is a genuine network dependency (elixir-lang/elixir
  on GitHub), so `mix test --only integration` alone leaves it out and the
  merge-gate job adds `--include network`. The version is v1.0.0, the
  smallest tagged release, and every clone goes to the pipeline's own temp
  directory.

  Only the embedding provider is substituted (`Cake.IngestIntegrationHelpers`).
  `async: false`: the pipeline indexes into the GDS's fixed collection.
  """

  use Cake.SearchIntegrationCase, async: false, network: true

  import Cake.IngestIntegrationHelpers
  import ExUnit.CaptureIO, only: [with_io: 2]
  import Mox

  alias Cake.Documents.Hexdocs
  alias Cake.Documents.Hexdocs.Hexdoc
  alias Cake.Documents.ParsedDocument
  alias Cake.Documents.ParsedDocuments
  alias Cake.Documents.Pipeline
  alias Cake.FailedIngests.FailedIngest
  alias Cake.Pipelines
  alias Cake.Repo
  alias Cake.Search
  alias Cake.Search.Hit

  # v1.0.0 (September 2014) is the smallest tagged release of the language:
  # 71 .ex files under lib/elixir/lib, a 27 MB clone.
  @version {1, 0, 0}
  @version_string "1.0.0"

  setup :verify_on_exit!

  setup do
    ensure_collection!(ParsedDocument)
    :ok
  end

  defp ids(structs), do: Enum.map(structs, & &1.id)

  defp ingest, do: Pipeline.ingest(:openai, Hexdocs.Pipeline, @version, embedding_model())

  describe "download/1" do
    test "clones the tagged release and lists the .ex sources under lib/elixir/lib" do
      ctx = Pipelines.build_context(Pipeline, Hexdocs.Pipeline, @version)

      assert {:ok, paths} = Hexdocs.Pipeline.download(ctx)

      assert paths != []
      assert Enum.all?(paths, &String.ends_with?(&1, ".ex"))
      assert Enum.all?(paths, &File.regular?/1)
      assert Enum.all?(paths, &String.contains?(&1, "/lib/elixir/lib/"))
      assert Enum.any?(paths, &(Path.basename(&1) == "enum.ex"))
    end
  end

  describe "ingest/4" do
    test "persists raw hexdocs, parses them into ParsedDocuments, embeds and indexes them; retry_from_raw/2 needs no clone" do
      stub_embeddings()

      # The 2014 sources trip the current parser's deprecation warnings
      # (charlists, `not in`); they are the sources' business, not the test's.
      {result, _parser_warnings} = with_io(:stderr, &ingest/0)
      assert {:ok, %{indexed: indexed, failed: 0, message: message}} = result
      assert message == "Successfully ingested Elixir docs from Hexdocs for version 1.0.0"
      assert indexed > 0

      # Raw rows: one Hexdoc per source file, keyed by filename and version,
      # holding the file verbatim as the re-parseable source of truth.
      raw = Hexdocs.hexdocs_by_version(@version_string)
      assert raw != []

      assert Enum.all?(
               raw,
               &match?(%Hexdoc{source: "hexdocs", language: "elixir", core: true}, &1)
             )

      assert %Hexdoc{url: "https://hexdocs.pm/elixir/enum.ex", content: enum_source} =
               Enum.find(raw, &(&1.module == "enum.ex"))

      assert enum_source =~ "defmodule Enum do"

      # Parsed rows: one ParsedDocument per def clause the parser accepts,
      # embedded with the stub's vector for the exact input the pipeline
      # embeds, every one counted in the summary and present in the real
      # index. Pinned on path.ex, a file that is a single `defmodule`.
      #
      # Flagged, not pinned (#248): a file with more than one top-level form
      # — enum.ex (defprotocol Enumerable + defmodule Enum + defimpls),
      # kernel.ex, string.ex, stream.ex — currently yields no ParsedDocument
      # at all, silently: Hexdoc.to_parsed_docs/1 accepts only a bare
      # `defmodule` AST. Likewise a def with several clauses yields one
      # document per clause under the same title, and how many survive the
      # (source, version, package, title) dedup depends on insert timing.
      docs = ParsedDocuments.by_source_and_version("hexdocs", @version_string)
      assert length(docs) == indexed
      assert Enum.all?(docs, &(&1.embedding == deterministic_embedding(embed_input(&1))))

      assert %ParsedDocument{
               language: "elixir",
               core: true,
               url: "https://hexdocs.pm/elixir/path.ex"
             } =
               absname = Enum.find(docs, &(&1.package == "path.ex" and &1.title == "absname/1"))

      assert Repo.all(FailedIngest) == []
      assert Enum.sort(indexed_ids!(ParsedDocument)) == Enum.sort(ids(docs))

      # Retrievable by its own embedding at an exact score of 1.0. Not
      # necessarily alone at the top: deterministic_embedding/1 maps each
      # text onto one of the configured dimension's axes, and with this many
      # documents some pairs share an axis (which pairs depends on the exact
      # source text, and Macro.to_string/1 formats it differently across
      # Elixir versions), so a collided neighbour scores 1.0 too.
      absname_id = absname.id

      assert {:ok, hits} =
               Search.search_chunks(:vector, "", deterministic_embedding(embed_input(absname)),
                 gds: ParsedDocument
               )

      assert %Hit{score: 1.0} = Enum.find(hits, &(&1.id == absname_id))
      assert Enum.any?(ParsedDocument.load_from_hits(hits), &(&1.id == absname_id))

      # retry_from_raw/2 works from the persisted raw row: with the clone
      # gone from disk it re-parses the same documents the run produced.
      File.rm_rf!(Path.join(System.tmp_dir!(), "hexdocs"))

      {reparse, _parser_warnings} =
        with_io(:stderr, fn ->
          Hexdocs.Pipeline.retry_from_raw("path.ex@1.0.0", @version_string)
        end)

      assert {:ok, reparsed} = reparse
      assert reparsed != []
      assert Enum.all?(reparsed, &(&1.package == "path.ex" and &1.version == @version_string))

      assert MapSet.new(reparsed, & &1.title) ==
               docs |> Enum.filter(&(&1.package == "path.ex")) |> MapSet.new(& &1.title)

      assert {:error, {:raw_doc_not_found, "nope.ex@1.0.0"}} =
               Hexdocs.Pipeline.retry_from_raw("nope.ex@1.0.0", @version_string)
    end
  end
end
