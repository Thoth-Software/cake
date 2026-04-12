# Cake

Cake is a Retrieval-Augmented Generation (RAG) framework built in Elixir. It provides pluggable ingestion pipelines, hybrid search (vector + keyword), multi-turn conversations with citation tracking, and error recovery for production document Q&A systems. The framework is designed for tenant-isolated deployments where each customer gets a bespoke frontend against shared OpenSearch infrastructure.

The immediate use case is a document Q&A tool for enterprise customers whose document formats include PDF, Word, Excel, CSV, and JPG. The demo-critical path is PDF ingestion, LiveView chat UI, and citation display. Other document formats are explicitly post-demo.

---

## How the RAG Loop Works End to End

Cake's core loop proceeds through five stages. Understanding this flow is essential context for working on any part of the system, because each module's design is shaped by its position in this sequence:

1. **Ingest**: Raw documents (PDFs, HTML docs) are downloaded, persisted as-is (the "raw data first" principle — persist before parsing so you can re-process when heuristics improve), then parsed into structured records (`ParsedDocument` or `ParsedBook` + `Chunk`).

2. **Embed**: Parsed text is sent to OpenAI's `text-embedding-ada-002` to produce 1536-dimensional vectors. Title is prepended to text before embedding because function names and headings carry significant semantic weight.

3. **Index**: Embedded records are upserted into OpenSearch indices configured with HNSW k-NN (FAISS engine, cosine similarity) plus full-text BM25 fields.

4. **Retrieve**: When a user asks a question, the `Conversation` GenServer embeds the question, runs a hybrid search (vector similarity as `must`, keyword BM25 as `should` boost), and collects the top-k chunks with metadata.

5. **Generate**: Retrieved chunks are formatted into a numbered context block, sent to the LLM with the user's question, and the response is parsed for `[N]` citation markers that map back to specific chunks with page numbers, section titles, and previews.

On follow-up turns within the same conversation, stages 2-3 of the retrieve step are skipped — the Conversation reuses previously retrieved chunks and only queries the LLM with the new question appended to message history. This reduces latency and API cost.

---

## Architecture: Module Responsibilities and Data Flow

The system is organized into four layers. Each layer has a clear responsibility boundary, and modules within a layer communicate through defined interfaces (behaviours, function signatures, GenServer protocols).

### Ingestion Layer: Two Parallel Pipeline Systems

Cake has two ingestion subsystems that share the same architectural pattern but handle different source material. The reason for the split is that programming documentation and books have fundamentally different parsing requirements, metadata schemas, and chunking strategies — collapsing them into a single pipeline would require too many conditional branches.

**`Cake.Documents.Pipeline`** handles programming documentation (Elixir hexdocs today, javadocs/pydocs planned). It defines a behaviour with callbacks `download/1`, `persist_raw_docs/2`, `parse/1`, `source/0`, and `success_message/1`. The module also contains the `ingest/4` orchestrator that sequences these callbacks into a stream pipeline: download → persist raw → parse → embed → index. The current implementation is `Cake.Documents.Hexdocs.Pipeline`, which downloads versioned tarballs from hex.pm, extracts HTML files, and parses them into `ParsedDocument` records.

**`Cake.Books.Pipeline`** handles books and ebooks. Its callbacks are `load_binary/1`, `parse/1`, `format/0`, and `success_message/0`. The current implementation is `Cake.Books.Pdf.Pipeline`, which uses a Rustler NIF (the `parsebooks` Rust crate wrapping `pdf-extract`) to parse PDFs into `ParsedBook` + `Chunk` records. The NIF boundary is a known complexity point — macOS-compiled Mach-O `.so` files are incompatible with the Linux Docker container, requiring forced recompilation in `entrypoint.sh`.

**`Cake.Pipelines`** provides shared infrastructure used by both pipeline types: `detuple_with_logging/3` filters `{:ok, _}/{:error, _}` streams and persists errors to the `FailedIngest` table, `add_to_opensearch/4` handles index upserts, and `sweep/5` implements a retry loop for item-level failures. A `Context` struct carries pipeline identity (behaviour, implementation, version) through a run for error provenance.

### Storage and Search Layer: Postgres and OpenSearch

**`Cake.Repo`** (Ecto/Postgres) stores all structured data: parsed documents, parsed books, chunks, users, failed ingests, and Oban jobs. All schemas use binary UUIDs via `Cake.Schema` and include `sanitize_text_fields/1` in their changesets.

**`Cake.Documents.Cluster`** (Snap/OpenSearch) manages the search index. It's a GenServer that creates indices at startup and exposes `search/3` with three modes. **Keyword search** uses BM25 multi_match across configurable fields with optional boost weights. **Vector search** uses k-NN with k=10, cosine similarity, and HNSW via FAISS engine. **Hybrid search** (the default and recommended mode) puts vector similarity in `must` and keyword matching in `should` with a configurable boost weight. Hybrid exists because pure vector search struggles with exact identifiers, function names, rare terms, and precise code patterns that BM25 handles well.

Tenant isolation uses multiple OpenSearch indices against a shared backend cluster, with bespoke frontends per client — not multiple clusters.

### Conversation Layer: Stateful Multi-Turn RAG

**`Cake.Conversation`** is a GenServer that manages the state of a single RAG conversation. Its state includes search results, message history, chunk map, citations, and accumulated errors. The two-phase lifecycle is the key design decision: the first `ask/3` call performs the full retrieve-and-generate loop, while subsequent `ask/2` calls skip retrieval and reuse cached search results. This assumes follow-up questions relate to the same topic — a reasonable heuristic for document Q&A that saves latency and API cost.

The cluster module is passed as the `caller` argument to `start_link/6`. This is dependency injection for testability (Mox), not for supporting multiple clusters at runtime.

**`Cake.Responses`** formats retrieved chunks into a numbered context block for the LLM, builds the system prompt instructing citation behavior, calls the OpenAI API, extracts the response text, and constructs the `chunk_map` (integer index → chunk metadata). Currently hardcoded to expect `Cake.Books.Chunk` structs — generalizing this is a known TODO.

**`Cake.Citations`** is a pure function module that parses `[N]` markers from LLM response text, resolves them against the chunk_map, filters out hallucinated citations (indices not in the map), deduplicates, and sorts. The chunk_map includes `book_title`, `page_number`, `section_title`, `chunk_index`, and `chunk_preview` — all five are necessary for citations to be distinguishable to end users (earlier versions using only book title were too generic).

**`Cake.Embeddings`** calls the OpenAI embeddings API. It implements `Cake.Embeddings.Behaviour` to allow Mox substitution in tests. Title is prepended to text before embedding.

### Web Layer: Phoenix LiveView Chat Interface

**`CakeWeb.ChatLive`** is the user-facing chat UI. It communicates with `Cake.Conversation` using a polling pattern: `Process.send_after` triggers periodic `handle_info/2` callbacks that call `Conversation.get_messages/1` (a `handle_call(:messages, ...)` on the GenServer). This works but is a known anti-pattern — replacement with Phoenix.PubSub is a planned TODO.

The rest of the web layer is standard Phoenix 1.7 scaffolding: `mix phx.gen.auth`-generated authentication (accounts, sessions, registration, settings), LiveView components, and Bandit HTTP server.

---

## Error Handling: Two-Tier Failure Model in Pipelines

Cake's ingestion pipelines distinguish between two categories of failure, and the distinction matters because the retry strategy and observability requirements differ:

**Item-level failures** occur when a single item in the stream fails while the rest continue. A corrupt PDF that won't parse, an embedding API timeout for one chunk, or a changeset validation error on a single record are all item-level. These are handled inside the stream by `Pipelines.detuple_with_logging/3`, which logs the error with the pipeline step name, persists it to the `failed_ingests` table with full provenance (behaviour, implementation, step, version, input identifier), and filters the failed item out of the stream. Successfully-processed items continue downstream unaffected. Failed items can be retried individually via `Pipelines.sweep/5`.

**Pipeline-fatal failures** occur when the entire pipeline cannot continue. The download step failing, OpenSearch being unreachable, or an invalid embedding model string are pipeline-fatal. These are handled in the `else` branch of the `with` chain in each behaviour module's `ingest` function. Nothing downstream runs.

Step names follow the convention `"pipeline.step"` — e.g., `"books.parse"`, `"docs.embed"`, `"opensearch.index"`.

---

## Data Schemas: Structural Contracts for Domain Objects

### ParsedDocument Schema for Indexed Programming Documentation

`Cake.Documents.ParsedDocument` is the universal output schema for all documentation ingestion pipelines. Every pipeline implementation (hexdocs, future javadocs, etc.) produces these records. Fields: `source` (pipeline identifier), `version`, `package` (module/gem/class name), `language`, `title` (function/method name — used in embeddings), `text`, `url`, `embedding` (1536-float array), `core` (boolean: part of stdlib?). Query helpers: `by_version/2`, `by_language/2`, `by_source/2`.

### ParsedBook and Chunk Schemas for Book Content

`Cake.Books.ParsedBook` stores book-level metadata. Fields: `title`, `authors` (string array), `source_format` (determines chunking strategy), `file_hash` (deduplication), `file_size`, `word_count`, `total_pages`, `parsed_at`, `embedding_status` (enum: pending/processing/completed/failed), `metadata` (map for format-specific extras), `table_of_contents` (map), `language` (ISO code), `isbn`, `publisher`, `publication_date`. Has many `Chunk` records.

`Cake.Books.Chunk` stores searchable text fragments belonging to a book. Fields: `text`, `page_number` (nullable — some formats lack pages), `chunk_index` (ordering for unpaginated formats), `section_title`, `word_count`, `char_count`, `embedding` (1536-float array). Belongs to `ParsedBook`. Query helpers: `by_book/2`, `on_page/2`, `within_pages/3`, `by_section/2`.

### FailedIngest Schema for Error Tracking and Retry

`Cake.FailedIngests.FailedIngest` persists every item-level pipeline failure. Fields: `pipeline_behaviour`, `pipeline_implementation`, `step`, `version`, `error_text`, `input_identifier` (sufficient to locate and retry the failed item), `pipeline_fatal` (boolean), `retry_count`, `last_retried_at`. The `sweep/5` function in `Cake.Pipelines` queries these records and retries them via a caller-provided retry function.

---

## Adding a New Ingestion Pipeline

There are two extension points depending on what you're ingesting. Both follow the same pattern: implement a behaviour, return result tuples from callbacks, and let the orchestrator handle stream composition and error tracking.

### Adding a New Documentation Source (Implement Cake.Documents.Pipeline)

To ingest a new source of programming documentation, implement the `Cake.Documents.Pipeline` behaviour:

1. Create a raw document schema (like `Hexdoc`) for intermediate storage of fetched content.
2. Implement callbacks: `download/1` (fetch raw docs for a version), `persist_raw_docs/2` (save raw files as source of truth), `parse/1` (transform raw docs into `ParsedDocument` attrs), `source/0` (return identifier string), `success_message/1` (human-readable completion message).
3. Register with Oban via `DocumentIngestionJob.enqueue_for_version/4` for async ingestion.
4. Ensure all callbacks return `{:ok, _}` / `{:error, _}` tuples so `detuple_with_logging` can observe failures.
5. Optionally implement `retry_from_raw/2` to enable item-level retry from persisted raw docs.

### Adding a New Book/Ebook Format (Implement Cake.Books.Pipeline)

To ingest a new ebook format, implement the `Cake.Books.Pipeline` behaviour:

1. Implement callbacks: `load_binary/1` (read file into memory), `parse/1` (transform binary into `{ParsedBook, [Chunk]}` tuple), `format/0` (return format string like "pdf"), `success_message/0`.
2. Add format-specific parsing logic. If `parse/1` calls code that can raise (e.g., a NIF), the behaviour's orchestrator wraps it in `try/rescue`.
3. The schema for any new data structures must `use Cake.Schema` and include `sanitize_text_fields/1` if it has string fields.

### Requirements for All Pipeline Implementations

Every stream transformation step must use `Pipelines.detuple_with_logging/3` with a descriptive step name — not the silent `detuple/1`. Callbacks return `{:ok, _}` / `{:error, _}` tuples. Pipeline-fatal errors are logged in the `else` branch of the `ingest` function. The key principle: **persist raw data first**. When your parsing heuristics improve, you can re-process without re-downloading.

---

## Development Environment Setup and Operation

### Prerequisites and Initial Setup

Docker, Docker Compose, Colima (macOS), Elixir 1.15+, Rust toolchain (for Rustler NIFs).

```bash
# Pull container images
docker pull opensearchproject/opensearch
docker pull postgres:14

# Clone and enter
git clone git@github.com:caleb-bb/cake.git && cd cake

# Start the containerized environment
docker-compose up -d

# Or, if running locally without Docker for the Elixir app:
mix deps.get
mix ecto.setup
mix phx.server
```

### Running the Development Environment via Docker Compose

`docker-compose up` starts three containers: `cake_app` (Phoenix on port 4000), `cake_db` (Postgres on port 5432), `cake_opensearch` (OpenSearch on port 9200). The `entrypoint.sh` script handles waiting for OpenSearch health, recompiling NIFs for the Linux container, running migrations, seeding, and starting Phoenix.

Environment variables (set in `.env` or shell): `CAKE_PGUSER`, `CAKE_PGPASSWORD`, `CAKE_PGDATABASE`, `CAKE_PGHOST`, `CAKE_PGPORT`, `OPENSEARCH_INITIAL_ADMIN_PASSWORD`, `OPENAI_KEY`.

### Known Colima/Docker Gotchas on macOS

The `.:/app` bind mount overlays macOS-compiled binaries onto the Linux container, breaking NIFs. Fix: `entrypoint.sh` runs `rm -f priv/native/*.so && mix deps.compile --force bcrypt_elixir && mix compile --force`. The diagnostic signal for this failure is "module not available" (not `:nif_not_loaded`).

The Colima VM's default FD limit of 1024 is too low for concurrent `Task.async_stream` fan-out across Postgres, OpenSearch, and OpenAI. Fix: raise kernel + systemd FD limits via provision script.

The `limactl` port forwarder accumulates leaked CLOSED socket FDs over long sessions. Fix: `colima start --network-address` gives the VM a routable IP and eliminates the forwarder entirely.

### Quality Checks and Testing

```bash
mix compile --warnings-as-errors --force  # Zero warnings required
mix credo --strict                         # Zero issues required
mix dialyzer                               # Zero new warnings required
mix test                                   # Zero failures required
mix coveralls.html                         # Coverage report in cover/

mix quality.fast    # compile + credo (quick local check)
mix quality         # compile + credo + dialyzer (full suite)
```

Test data factories are in `test/support/factory.ex` (ExMachina). Property tests (StreamData) are in files named `*_property_test.exs`. Coverage threshold is enforced in CI via `coveralls.json`.

---

## Configuration Reference for External Services

### OpenSearch Cluster Connection

```elixir
config :cake, Cake.Documents.Cluster,
  url: "http://opensearch:9200",
  username: "...",
  password: "..."
```

The cluster creates indices at startup if they don't exist. Index names: `"docs"` (programming documentation), `"chunks_of_books"` (book content). Both use 1536-dimension knn_vector fields with HNSW + FAISS and cosine similarity.

### OpenAI Embeddings and LLM Responses

```elixir
config :cake, Cake.Embeddings,
  openai_key: "sk-...",
  base_url: "https://api.openai.com/v1/embeddings"

config :cake, Cake.Responses,
  openai_key: "sk-...",
  response_url: "https://api.openai.com/v1/chat/completions"
```

Embedding model: `text-embedding-ada-002` (1536 dimensions). Response model: configurable per conversation via `Conversation.start_link/6`.

---

## Supervision Tree and Application Startup Order

`Cake.Application` starts processes in this order. The order matters because later processes depend on earlier ones being available:

1. `CakeWeb.Telemetry` — telemetry metrics
2. `Cake.Repo` — Postgres connection pool
3. Oban — background job processing
4. `DNSCluster` — DNS-based node discovery
5. `Phoenix.PubSub` — pub/sub for LiveView
6. `Finch` — HTTP client pool (for Swoosh emails)
7. `Cake.Documents.Cluster` — OpenSearch connection + index creation
8. `CakeWeb.Endpoint` — Phoenix HTTP server (last, so all dependencies are ready)

---

## Roadmap: What's Planned and What's Deferred

See `feature_roadmap.md` for the full research-backed roadmap. The short version:

**Demo-critical (in progress):** PDF ingestion via Rustler NIF, LiveView chat UI with polling, citation display with chunk-level metadata.

**Post-demo planned:** Replace polling with PubSub, expand test coverage (four-tier plan), Word/Excel/CSV/JPG ingestion pipelines, extract `Responses.Behaviour` for testability, extract `search_fields/0` callback, generalize `Responses.query_llm/4` beyond Chunk structs.

**Longer-term:** Re-ranking pipelines, query expansion (HyDE-style), semantic chunking with overlap, context assembly strategies, faithfulness evaluation harness, conversational memory improvements.

---

## Dynamic Refdoc Protocol: Keeping This File Current

This README is a living document that should accurately reflect the codebase at all times. Any AI assistant making changes to Cake should review this file after completing a task and propose updates to any sections that are now stale. Human contributors should do the same. The rule: **if you changed it in code, check whether you need to change it here.**

The companion file `CLAUDE.md` contains operational rules and conventions for AI assistants. It is more prescriptive (what you *must* do) while this README is more descriptive (what things *are* and *why*). Both files should be kept in sync with the codebase and with each other.
