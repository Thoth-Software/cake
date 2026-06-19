---
title: "Cake — RAG Framework for Enterprise Document Q&A"
tags: [cake, rag, elixir, phoenix, opensearch, architecture, domain-model]
date: 2026-04-23
domain: architecture, reference
source: project-maintainer
---

# Cake

Cake is a RAG (Retrieval-Augmented Generation) framework built in Elixir/Phoenix. It ingests enterprise documents, stores embeddings in OpenSearch, and surfaces answers through a Phoenix LiveView chat interface. The immediate use case is a document Q&A tool for enterprise customers whose document formats include PDF, Word, Excel, CSV, and JPG. The demo-critical path is PDF ingestion, LiveView chat UI, and citation display. Other document formats are explicitly post-demo.

---

## Domain Model: GDS, Raw Data, and Retrievables

Cake's domain model is organized around three categories of data structure, each serving a different role in the ingestion-to-retrieval pipeline. Understanding these categories is a prerequisite for understanding the architecture.

### Generic Data Structure (GDS)

A GDS is a *category of document* that Cake knows how to ingest, search, and cite. It is not a single schema — it is a named grouping that encompasses one or more Ecto schemas, a pipeline behaviour, and a set of protocol implementations. The GDS is the unit of domain identity: when you say "Cake supports books," you mean the `ParsedBook` + `Chunk` GDS exists.

Each GDS answers the question: *Why is the customer interested in this kind of documentation, and what is the atomic unit they'd want returned from a search?* The answer determines the GDS's shape — single-schema or parent/child — and everything downstream follows.

Current GDSes:

- **`ParsedBook` + `Chunk`** — for book-like documents (PDFs, future EPUBs, Word docs). Parent/child pair where `Chunk` is the retrieval unit.
- **`ParsedDocument`** — for programming documentation (hexdocs, future javadocs, Rustdocs). Single schema that is its own retrieval unit.

### Raw Data Structs

Raw data structs hold the original fetched content before it is parsed into a GDS. They exist to support the "raw data first" principle: persist what you fetched so you can re-parse later when heuristics improve, without re-downloading.

Current raw data structs:

- **`Cake.Documents.Hexdocs.Hexdoc`** — stores the raw HTML content fetched from hex.pm tarballs. Intermediate storage between download and parsing into `ParsedDocument`.

### Retrievables (Searchable Units)

A retrievable is the atomic schema that maps one-to-one to an OpenSearch document. It is the unit that search returns and that citations point at. The retrievable may or may not be the same schema as the GDS identity module.

Current retrievables:

- **`Cake.Books.Chunk`** — for the `ParsedBook` GDS. The book-level `ParsedBook` holds metadata; the chunk is what search returns.
- **`Cake.Documents.ParsedDocument`** — for the `ParsedDocument` GDS. The GDS is its own retrievable because a documentation entry is already atomic.

---

## Cardinality: How GDSes, Data Structures, and Pipelines Relate

These four cardinality relationships are stated explicitly because the rest of the architecture assumes them, and the distinctions get subtle once more than one GDS is in play.

**GDS ↔ ingestion pipeline behaviour: 1:1.** Each GDS has exactly one pipeline behaviour that targets it, and each pipeline behaviour produces exactly one GDS. `Cake.Books.Pipeline` targets the `ParsedBook` + `Chunk` GDS; `Cake.Documents.Pipeline` targets the `ParsedDocument` GDS. This is why no framework-level `Cake.Ingestion` master behaviour exists — the GDS *is* the unit of pipeline grouping.

**GDS → data structures: 1:many.** A GDS can be composed of multiple related Ecto schemas. The `ParsedBook` + `Chunk` GDS has two data structures (parent and child), where `Chunk` is the retrieval unit. The `ParsedDocument` GDS has one data structure and is its own retrieval unit.

**Data structure → pipeline implementation: 1:1 per source.** Each pipeline implementation produces records of exactly one data structure shape per run. `Cake.Books.Pdf.Pipeline` produces `ParsedBook` + `Chunk` records from a PDF. A future `Cake.Books.Epub.Pipeline` would produce the same shape from an EPUB.

**Pipeline behaviour → implementations: 1:many.** Each pipeline behaviour can have any number of concrete implementations. Adding a new source format is an additive operation against a stable behaviour; it never reshapes the GDS.

### Worked Examples

- **`ParsedBook` + `Chunk`:** One GDS, two data structures (parent/child), one pipeline behaviour (`Cake.Books.Pipeline`), currently one implementation (`Cake.Books.Pdf.Pipeline`). Retrieval unit is `Chunk`, not `ParsedBook`.
- **`ParsedDocument`:** One GDS, one data structure, one pipeline behaviour (`Cake.Documents.Pipeline`), currently one implementation (`Cake.Documents.Hexdocs.Pipeline`). The GDS is its own retrieval unit.

---

## Architecture: Application Layers

The system is organized into four layers. Each layer has a clear responsibility boundary, and modules within a layer communicate through defined interfaces (behaviours, function signatures, GenServer protocols). The guiding principle is that **modules are organized by what they're responsible for, not by what infrastructure they share.** Two functions that both call an HTTP API don't belong together unless they operate on the same domain concept and change for the same reasons.

### Layer 1: Ingestion — Two Parallel Pipeline Systems

The ingestion layer has two pipeline behaviours because the two GDSes have fundamentally different parsing requirements, metadata schemas, and chunking strategies. Each GDS owns its own ingestion contract.

**`Cake.Documents.Pipeline`** is the behaviour for ingesting programming documentation. Its GDS is `ParsedDocument`. Callbacks: `download/1`, `persist_raw_docs/2`, `parse/2`, `source/0`, `success_message/1`, and optionally `retry_from_raw/2`. The module also contains the `ingest/4` orchestrator that sequences callbacks into a stream pipeline: download → persist raw → parse → embed → index. Current implementation: `Cake.Documents.Hexdocs.Pipeline`.

**`Cake.Books.Pipeline`** is the behaviour for ingesting books and book-like documents. Its GDS is `ParsedBook` + `Chunk`. Callbacks: `load_binary/1`, `parse/1`, `format/0`, `success_message/0`. Current implementation: `Cake.Books.Pdf.Pipeline`, which uses a Rustler NIF (`parsebooks` Rust crate wrapping `pdf-extract`).

**`Cake.Pipelines`** provides shared infrastructure used by both pipeline types: `detuple_with_logging/3` filters `{:ok, _}/{:error, _}` streams and persists errors to `FailedIngest`, `add_to_opensearch/4` handles index upserts, and `sweep/5` implements a retry loop for item-level failures. A `Context` struct carries pipeline identity (behaviour, implementation, version) through a run for error provenance.

There is deliberately no `Cake.Ingestion` behaviour unifying the two pipeline behaviours. They have different callback shapes because they answer different questions. Each GDS owns its own ingestion contract; unification is deferred indefinitely.

### Layer 2: Search and Retrieval

**`Cake.Search`** defines the search behaviour contract and also owns the pure scoring utilities (`cosine_similarity/2`, `score_results/2`, `normalize_and_combine/1`, `sort_by_relevance/1`) that rank retrieved results. `Cake.Search.OpenSearch` is the real backend implementation.

**`Cake.Search.Query`** is a struct-based composable OpenSearch query builder. Struct fields: `index` (enforced), `size` (default 10), `must`, `should`, `filter` (all default `[]`), `min_score` (default nil). Builder functions: `new/2`, `knn/4`, `match/4`, `filter_term/3`, `min_score/2`, `size/2`. Conversion: `to_query_map/1`.

**`Cake.Search.OpenSearch`** exposes three search entry points (`search_chunks/4`, `search_chunks_with_context/5`, `search_docs/4`), each supporting three modes (`:keyword`, `:vector`, `:hybrid`). Hybrid is the default and recommended mode. The module reads the target index, search fields, hit hydration, and neighbor expansion from the GDS module passed as an argument.

**`Cake.Documents.Cluster`** is the OpenSearch `Snap.Cluster` — connection management and index lifecycle only, not query logic. Query construction lives in `Cake.Search.Query`.

**`Cake.Embeddings`** calls the configured embedding service (OpenAI by default). Implements `Cake.Embeddings.Behaviour` for Mox substitution. Title is prepended to text before embedding. Used at both ingestion time (by pipelines) and query time (by the conversation layer).

Tenant isolation uses multiple OpenSearch indices against a shared backend cluster, with bespoke frontends per client.

### Layer 3: Conversation — Stateful Multi-Turn RAG

This layer is organized around a single principle: **`Cake.Conversation` is the sole orchestrator, and every other module in the layer is a peer service that it calls.** The dependency graph is a DAG. Service modules don't know about each other, with one exception (`Prompt` calls `Generation` for query decomposition).

```
Conversation → Prompt → Generation
Conversation → Search (Cake.Search behaviour → Cake.Search.OpenSearch → Cluster)
Conversation → Embeddings
Conversation → Generation
Conversation → Responses
```

**`Cake.Conversation`** is a GenServer managing single-conversation state: message history, retrieved chunks, chunk map, citations, accumulated errors. A turn starts one of two ways: `autoask/2` runs the full retrieve-and-generate loop automatically, while `manualask/2` retrieves and returns candidate documents (`[Search.Result.t()]`) for the user to pick from — `select_docs/2` then supplies the chosen document ids and generation proceeds. Follow-up turns reuse cached search results rather than re-retrieving.

**`Cake.Prompt`** owns prompt engineering. Builds the messages list for the LLM (system prompt, conversation history, retrieved context as a numbered block, user question). Handles query decomposition by calling `Generation` when needed. Filters chunks by relevance floor and chunk ceiling, assigns dense 1..N indices.

**`Cake.Retrieval`** (planned) will own retrieval strategy: search, scoring, autorating. Currently these responsibilities are split between `Conversation` and `Search.OpenSearch`.

**`Cake.Generation`** owns LLM completions. Accepts a messages list, calls the LLM API, returns response content. Both `Conversation` (main answer) and `Prompt` (query decomposition) call it. Defines `Cake.Generation` as a behaviour; `Cake.Generation.OpenAI` is the real implementation. `Cake.Generation.Anthropic` is a placeholder stub.

**`Cake.Responses`** handles post-generation processing. Builds the chunk map (integer index → chunk metadata), parses citation markers, deduplicates, and assembles the final structured response. Uses `Cake.Citations` for citation parsing. `Cake.Responses.Behaviour` defines the contract; `Cake.Responses.Result` is the output struct.

**`Cake.Citations`** is a pure function module. Parses `[N]` markers from response text, resolves against the chunk map, filters hallucinated citations, deduplicates, sorts.

#### The Per-Turn Pipeline

Every arrow originates from `Conversation`:

1. User message arrives at `Conversation`.
2. `Conversation` → `Prompt.prepare_context` (filter/rank/index chunks).
3. `Conversation` → `Prompt.build` (assemble messages list).
4. `Conversation` → `Generation.complete` (LLM call).
5. `Conversation` → `Responses.process` (chunk map, citations, structuring).
6. `Conversation` updates state and notifies the frontend.

On follow-up turns, retrieval is skipped — cached chunks are reused with the new question appended to message history.

### Layer 4: Web — Phoenix LiveView Chat Interface

**`CakeWeb.ChatLive`** is the user-facing chat UI. It starts a `Conversation` GenServer and subscribes to its PubSub topic for state-change, candidates-ready, response-ready, and error broadcasts. Domain-level candidate grouping and chunk-ID extraction are delegated to **`Cake.Candidates`**. Two embedded-schema form modules live under `chat_live/`: **`QuestionForm`** (question + mode validation) and **`SelectionForm`** (document-selection validation with subset checking against available IDs).

**`CakeWeb.UserAuth`** provides authentication plugs.

### Supervision Tree Boot Order

The application starts children in this order under `Cake.Application`:

1. `CakeWeb.Telemetry` — telemetry metrics
2. `Cake.Repo` — Postgres connection pool
3. Oban — background job processing
4. `DNSCluster` — DNS-based node discovery
5. `Phoenix.PubSub` — pub/sub for LiveView
6. `Finch` — HTTP client pool
7. `Cake.Documents.Cluster` — OpenSearch connection + index creation
8. `CakeWeb.Endpoint` — Phoenix HTTP server (last, so all dependencies are ready)

---

## The RAG Loop: End-to-End Data Flow

This section traces how content flows from raw document to user-facing answer, connecting the layers described above.

1. **Acquire**: A pipeline implementation fetches source content (PDF binary, hex.pm tarball, etc.).
2. **Persist raw**: Raw content is saved to Postgres as the source of truth, enabling re-parsing without re-downloading.
3. **Parse**: The pipeline transforms raw content into GDS schema records (e.g., `ParsedBook` + `Chunk`).
4. **Index**: Embedded records are upserted into OpenSearch indices via `Cake.Pipelines.add_to_opensearch/4`. The retrieval unit maps one-to-one to OpenSearch documents.
5. **Retrieve**: `Cake.Conversation` orchestrates retrieval — embed the question, search OpenSearch, score and rank results.
6. **Generate**: `Prompt` formats retrieved chunks into a numbered context block. `Generation` sends the messages list to the LLM. `Responses` parses `[N]` citation markers and builds the structured response the frontend renders.

---

## Custom Structs: Complete Inventory

Every custom struct in Cake, its module, its purpose, and whether it defines a `t()` type.

### Ecto Schemas (use Cake.Schema)

| Struct | Module | Purpose |
|---|---|---|
| `ParsedBook` | `Cake.Books.ParsedBook` | Book-level metadata for book-like documents. GDS identity module for the Books GDS. |
| `Chunk` | `Cake.Books.Chunk` | Atomic searchable text fragment within a book. Retrieval unit for the Books GDS. |
| `ParsedDocument` | `Cake.Documents.ParsedDocument` | Programming documentation entry. Both GDS identity and retrieval unit for the Documents GDS. |
| `Hexdoc` | `Cake.Documents.Hexdocs.Hexdoc` | Raw HTML content fetched from hex.pm. Intermediate storage (raw data struct). |
| `FailedIngest` | `Cake.FailedIngests.FailedIngest` | Persists item-level pipeline failures for retry via `sweep/5`. |
| `User` | `Cake.Accounts.User` | Phoenix authentication user record. |
| `UserToken` | `Cake.Accounts.UserToken` | Session and email confirmation tokens. |

### Non-Ecto Domain Structs

| Struct | Module | Purpose |
|---|---|---|
| `Pipelines.Context` | `Cake.Pipelines.Context` | Carries pipeline identity (behaviour, implementation, version) through an ingestion run for error provenance. |
| `Search.Query` | `Cake.Search.Query` | Composable OpenSearch query builder. Fields: `index`, `size`, `must`, `should`, `filter`, `min_score`. |
| `Search.Result` | `Cake.Search.Result` | Normalized search result. Carries retrieval unit, backend score, CAKE-computed scores (cosine, relevance), hit provenance (search vs. expansion), search conditions, and prompt index. Single carrier of all retrieval metadata through the pipeline. |
| `Search.Provenance` | `Cake.Search.Provenance` | Search conditions (type, query text, decomposition flag, embedding model) attached to each `Search.Result`. |
| `Responses.Result` | `Cake.Responses.Result` | Output struct from post-generation processing. Contains the formatted response, citations, and chunk map. |

---

## Behaviours and Implementations: Complete Inventory

Behaviours in Cake define module-level contracts. The question they answer is "which *module* is responsible for this capability?" Use a behaviour when dispatch is by module identity.

| Behaviour | Module | Purpose | Current Implementations |
|---|---|---|---|
| `Cake.GDS` | `lib/cake/gds.ex` | Module-level contract for a Generic Data Structure. Declares index name, search fields, hit hydration, neighbor expansion. | `Cake.Books.ParsedBook`, `Cake.Documents.ParsedDocument` |
| `Cake.Books.Pipeline` | `lib/cake/books/pipeline.ex` | Ingestion behaviour for book-like documents. Callbacks: `load_binary/1`, `parse/1`, `format/0`, `success_message/0`. | `Cake.Books.Pdf.Pipeline` |
| `Cake.Documents.Pipeline` | `lib/cake/documents/pipeline.ex` | Ingestion behaviour for programming documentation. Callbacks: `download/1`, `persist_raw_docs/2`, `parse/2`, `source/0`, `success_message/1`. | `Cake.Documents.Hexdocs.Pipeline` |
| `Cake.Embeddings.Behaviour` | `lib/cake/embeddings.ex` | Contract for embedding services. | `Cake.Embeddings` (OpenAI impl) |
| `Cake.Generation` | `lib/cake/generation.ex` | Contract for LLM completion services. | `Cake.Generation.OpenAI`, `Cake.Generation.Anthropic` (stub) |
| `Cake.Search` | `lib/cake/search.ex` | Contract for search backends. | `Cake.Search.OpenSearch` |
| `Cake.Responses.Behaviour` | `lib/cake/responses/behaviour.ex` | Contract for post-generation response processing. | `Cake.Responses` |

---

## Protocols and Implementations: Complete Inventory

Protocols in Cake define value-level contracts. The question they answer is "what does *this value* know how to do?" Use a protocol when dispatch is by struct type.

| Protocol | Module | Purpose | Current Implementations |
|---|---|---|---|
| `Cake.Promptable` | `lib/cake/promptable.ex` | Renders a struct as prompt context for the LLM. Each implementation defines how its data should appear in the numbered context block. | `Cake.Books.Chunk`, `Cake.Documents.ParsedDocument` |
| `Cake.Citable` | `lib/cake/citable.ex` | Extracts citation metadata from a struct. Returns a map with `label`, `source_ref`, `preview`, and `extras`. | `Cake.Books.Chunk`, `Cake.Documents.ParsedDocument` |

---

## Data Schemas: Field-Level Detail

### ParsedDocument Fields

`source` (pipeline identifier), `version`, `package` (module/gem/class name), `language`, `title` (function/method name — used in embeddings), `text`, `url`, `embedding` (1536-float array), `core` (boolean: part of stdlib?). Query helpers: `by_version/2`, `by_language/2`, `by_source/2`.

### ParsedBook Fields

`title`, `authors` (string array), `source_format`, `file_hash` (deduplication), `file_size`, `word_count`, `total_pages`, `parsed_at`, `embedding_status` (enum: pending/processing/completed/failed), `metadata` (map), `table_of_contents` (map), `language` (ISO code), `isbn`, `publisher`, `publication_date`. Has many `Chunk` records.

### Chunk Fields

`text`, `page_number` (nullable), `chunk_index` (ordering for unpaginated formats), `section_title`, `word_count`, `char_count`, `embedding` (1536-float array). Belongs to `ParsedBook`. Query helpers: `by_book/2`, `on_page/2`, `within_pages/3`, `by_section/2`.

### FailedIngest Fields

`pipeline_behaviour`, `pipeline_implementation`, `step`, `version`, `error_text`, `input_identifier`, `pipeline_fatal` (boolean), `retry_count`, `last_retried_at`.

---

## Adding a New GDS

The question to ask when designing a new GDS is *Why is the customer interested in this kind of documentation, and what is the atomic unit they'd want returned from a search?* The answer determines whether your GDS is a single schema or a parent/child pair. Existing GDSes (`ParsedBook` + `Chunk` and `ParsedDocument`) are the reference implementations.

1. **Design the schema(s).** Decide single-schema vs. parent/child. Use `Cake.Schema`. Every changeset with string fields must call `sanitize_text_fields/1`. UUIDs are binary.
2. **Declare `use Cake.GDS` on the identity module.** Implement `index_name/0`, `search_fields/0`, `load_from_hits/1`. Override `expand_with_neighbors/2` if the GDS has ordering; otherwise inherit the identity default.
3. **Implement `Cake.Promptable`** on the retrieval-unit schema. Define how a search result renders in the numbered context block.
4. **Implement `Cake.Citable`** on the retrieval-unit schema. Define citation metadata: `label`, `source_ref`, `preview`, `extras`.
5. **Design a pipeline behaviour** targeting this GDS, or implement an existing one if the GDS already has a behaviour.
6. **Create an OpenSearch index mapping.** Embedding dimension must match the configured model (currently 1536 for `text-embedding-ada-002`).
7. **Thread the GDS through `Cake.Conversation`.** Pass `gds: YourGDS` in opts. `Cake.Search.OpenSearch` will use the GDS's callbacks for index name, field selection, hit hydration, and neighbor expansion.

---

## Adding a New Ingestion Pipeline

### For an Existing GDS

Implement the behaviour for the target GDS. Consult `Cake.Books.Pdf.Pipeline` or `Cake.Documents.Hexdocs.Pipeline` as reference implementations.

### Adding a New Documentation Source (Cake.Documents.Pipeline)

1. Create a raw document schema for intermediate storage.
2. Implement callbacks: `download/1`, `persist_raw_docs/2`, `parse/2`, `source/0`, `success_message/1`.
3. Register with Oban via `DocumentIngestionJob.enqueue_for_version/4`.
4. Ensure all callbacks return `{:ok, _}` / `{:error, _}`.
5. Optionally implement `retry_from_raw/2`.

### Adding a New Book Format (Cake.Books.Pipeline)

1. Implement callbacks: `load_binary/1`, `parse/1`, `format/0`, `success_message/0`.
2. Add format-specific parsing logic.
3. New schemas must `use Cake.Schema` and include `sanitize_text_fields/1`.

### Requirements for All Pipeline Implementations

Every stream step must use `Pipelines.detuple_with_logging/3` with a descriptive step name. Callbacks return `{:ok, _}` / `{:error, _}`. Pipeline-fatal errors go in the `else` branch. Persist raw data first.

---

## Error Handling in Pipelines

Cake distinguishes between item-level failures (one document fails to parse) and pipeline-fatal failures (the download step itself fails). Item-level failures are persisted to `FailedIngest` via `detuple_with_logging/3` and can be retried via `sweep/5`. Pipeline-fatal failures short-circuit the `with` chain and are logged in the `else` branch.

Step names follow `"pipeline.step"` convention (e.g., `"books.parse"`, `"docs.embed"`). The `Context` struct carries pipeline identity so error records are traceable to their source.

---

## Search Design

OpenSearch queries support three modes via `search_type`: `:keyword` (BM25 multi_match), `:vector` (k-NN with cosine similarity, HNSW/FAISS, k=30, ef_search=256), and `:hybrid` (vector in `must`, keyword in `should` with configurable boost). Hybrid is the default because pure vector search struggles with exact identifiers and rare terms, while pure keyword search misses semantic similarity.

`search_chunks_with_context/5` returns a list of `Cake.Search.Result.t()` structs. Direct hits carry `hit_source: :search` and the backend `_score`; expanded neighbors carry `hit_source: :expansion` and `backend_score: nil`. The Result struct is the single carrier of retrieval metadata through the rest of the pipeline (scoring, prompt assembly, response post-processing) — everything above the Search.Result boundary speaks CAKE; everything below speaks vendor. CAKE-computed scores (`cosine_score`, `relevance_score`) are populated by `Search.score_results/2` and `Search.normalize_and_combine/1`; `prompt_index` is populated by `Prompt.prepare_context/2`. Each Result also carries a `Search.Provenance` describing the search conditions (type, query text) under which it was discovered.

---

## Roadmap: Planned and Deferred

**Post-demo planned:** conversation layer decomposition (extract `Prompt` and `Generation` fully; collapse `Responses` to post-processing only), test coverage expansion, generalize `Responses` beyond `Chunk`, `search_fields/0` behaviour extraction, `Conversation.start_link` struct migration, Word/Excel/CSV/JPG pipelines.

**Longer-term:** query decomposition (`Prompt`), autorating (`Search` or dedicated module), cross-encoder reranking (`Search`), HyDE-style query expansion (`Prompt` + `Retrieval`), multi-index search and result merging (`Retrieval`).

---

## Directory Structure

```
lib/
  cake/
    accounts/                # Phoenix auth (User, UserToken, UserNotifier)
    books/                   # Book ingestion subsystem
      chunk.ex               #   Chunk schema (retrieval unit)
      parsed_book.ex         #   ParsedBook schema (GDS identity)
      pipeline.ex            #   Books.Pipeline behaviour + orchestrator
      pdf/pipeline.ex        #   PDF implementation (Rustler NIF)
    documents/               # Documentation ingestion subsystem
      cluster.ex             #   OpenSearch Snap.Cluster (connection + index lifecycle)
      parsed_document.ex     #   ParsedDocument schema (GDS identity + retrieval unit)
      parsed_documents.ex    #   ParsedDocuments context (CRUD)
      pipeline.ex            #   Documents.Pipeline behaviour + orchestrator
      hexdocs/               #   Hexdocs implementation
        hexdoc.ex            #     Raw hexdoc schema
        pipeline.ex          #     Hexdocs.Pipeline implementation
    failed_ingests/          # FailedIngest schema + context
    search.ex                # Cake.Search behaviour contract + pure scoring utilities
    search/
      query.ex               #   Composable query builder (new/2, knn/4, match/4, to_query_map/1)
      open_search.ex         #   Cake.Search.OpenSearch — real implementation
    candidates.ex            # Pure-function candidate grouping and chunk-ID extraction
    conversation.ex          # Conversation GenServer (orchestrator)
    gds.ex                   # Cake.GDS behaviour
    promptable.ex            # Cake.Promptable protocol
    citable.ex               # Cake.Citable protocol
    citations.ex             # Pure-function citation parser
    embeddings.ex            # OpenAI embeddings client + Behaviour
    generation.ex            # Cake.Generation behaviour (contract only)
    generation/
      open_ai.ex             #   Cake.Generation.OpenAI — real implementation
      anthropic.ex           #   Cake.Generation.Anthropic — placeholder stub
    pipelines.ex             # Shared pipeline helpers + Context struct
    prompt.ex                # Cake.Prompt — prompt engineering
    responses.ex             # Post-processing pipeline
    responses/
      behaviour.ex           #   Cake.Responses.Behaviour (contract)
      result.ex              #   Cake.Responses.Result struct
    schema.ex                # Base schema (use Cake.Schema)
  cake_web/
    live/
      chat_live.ex           # LiveView chat UI
      chat_live/
        question_form.ex     #   Embedded schema for question + mode validation
        selection_form.ex    #   Embedded schema for document selection validation
    user_auth.ex             # Auth plugs

test/
  support/
    factory.ex               # ExMachina test data factories
    data_case.ex             # Ecto sandbox setup
    conn_case.ex             # Phoenix conn setup
    oban_case.ex             # Oban testing helpers
    test_pipeline.ex         # Mock pipeline implementations
  cake/
    citations_test.exs
    citations_property_test.exs

config/
  dev.exs                    # Dev config (live reload, logging)
  test.exs                   # Test config (sandbox, Oban manual mode)
  runtime.exs                # Runtime config (reads env vars)

native/parsebooks/           # Rust crate for PDF parsing via Rustler
```
