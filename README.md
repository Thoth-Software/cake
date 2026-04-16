# Cake

Cake is a Retrieval-Augmented Generation (RAG) framework built in Elixir. The idea is to build a set of broad abstractions based on customer needs that hide the complexity of the document corpora where their data is held. There are three parts:

1. **Generic Data Structures** are the core of CAKE. Our customers' data is locked up in vast, heterogeneous corpora of documentation. Pdfs, epubs, word documents, spreadsheets, html, markdown, and so on. We want to take all that and boil it down to a handful of generic data structures. For example, `Cake.Books.ParsedBook` represents pdfs, epubs, and other documents resembling print books. `Cake.Documents.ParsedDocument` represents programming language documentation. CAKE is fundamentally a research project: given the zoo of different formats, how do we boil it all down into a handful of generics? Every time we implement a CAKE app for a customer, we iterate our GDS and refine them bit more. The governing question is always, *Why is the customer interested in this body of documentation?* That consideration always guides abstraction design.
2. **Ingestion Pipelines** are like Swiss army knives. Each pipeline is an abstract behaviour that ingests data into a given GDS. Each GDS has one pipeline behaviour and each pipeline behaviour has one GDS. So there's a pipeline behaviour for `ParsedBooks` that lives under `Cake.Books.Pipeline`. That behaviour defines the contract that an implementation must satisfy to munge raw documents into a `ParsedBook`. For each pipeline behaviour, there can be any number of concrete implementations. There could be `Cake.Books.Pdf.Pipeline` and `Cake.Books.Epub.Pipeline`. The former munges pdf files into the `ParsedBook` format. The second munges epub files into the `ParsedBook` format. Likewise, for other generics, there will be other implementations. For example, `Cake.Documents.Hexdocs.Pipeline` munges Elixir Hexdocs into `ParsedDocument` format. Whereas, we could also envision a `Cake.Documents.Rustdocs.Pipeline`, which munges the Rust documentation into the same format. The governing question is always, *Given the GDS' nature, how do we build a function to map existing documentation into a form our customer can use?*
3. **Smart Retrieval** when we're designing our search, the governing question is always, *Why does the customer want to see this document in particular?* Notice that this consideration necessarily connects to why the customer is interested in this kind of documentation in the first place; therefore, our GDS, if properly designed, should suggest the right kind of search.

The immediate use case is a document Q&A tool for enterprise customers whose document formats include PDF, Word, Excel, CSV, and JPG. The demo-critical path is PDF ingestion, LiveView chat UI, and citation display. Other document formats are explicitly post-demo.

---

## How the RAG Loop Works End to End

Cake's core loop proceeds through six stages. Understanding this flow is essential context for working on any part of the system, because each module's design is shaped by its position in this sequence. The ingestion half (stages 1–4) happens offline, typically via Oban jobs. The query half (stages 5–6) happens live when a user asks a question.

1. **Ingest**: Raw documents (PDFs, HTML docs) are downloaded and persisted as-is — the "raw data first" principle. Persist before parsing so you can re-process when heuristics improve. We generally use relational databases for this, although object storage is an eventuality. If customer documentation is dynamic or subject to change, we can ingest it automatically whenever it changes and version the output.

2. **Parse**: Raw documents are transformed into GDS records (`ParsedDocument` or `ParsedBook` + `Chunk`). Each time we build a new implementation, we ask ourselves: *Does this require a refinement of our existing generics? Or does it require an entirely new GDS?* Note that some generics subdivide — PDF metadata goes into a `ParsedBook`, with the actual text living inside many `Chunk` records per book.

3. **Embed**: Parsed text is given a vector embedding via `Cake.Embeddings`. Depending on customer needs, this can be done with commercial AI platforms, on a private cloud network using an open-source model, or even air-gapped and on-prem. Whatever generic holds the original text also holds the embedding, in a different field.

4. **Index**: Embedded records are upserted into OpenSearch indices via `Cake.Pipelines.add_to_opensearch/4`. Whichever unit is atomic for this GDS (for `Books` it would be `Chunk`) maps one-to-one to OpenSearch documents. Each document holds both the embedding and the original text.

5. **Retrieve**: When a user asks a question, `Cake.Conversation` orchestrates retrieval by calling `Cake.Retrieval`, which in turn embeds the question (via `Cake.Embeddings`) and runs a search (via `Cake.Documents.Cluster.search/3`). The nature of the search (hybrid, keyword, vector), the ranking algorithm, searching multiple times, retrieving extra context, confidence/relevance scoring, and autorating whether context is sufficient to answer are all `Retrieval`'s responsibility and are bespoke to each customer. Eventually, we would like for this step to adapt to customer needs intelligently; by making subtle changes and noting which ones solved the customer's problem best, CAKE can learn what works for their domain. This, in turn, helps us iterate the core product.

6. **Generate**: `Conversation` passes the retrieved chunks to `Cake.Prompt`, which formats them into a numbered context block and assembles the full messages list (system prompt, conversation history, context block, new user question). `Cake.Generation` sends that messages list to the LLM and returns the response text. `Conversation` hands the response to `Cake.Responses`, which uses `Cake.Citations` to parse `[N]` markers back to specific chunks with page numbers, section titles, and previews, and to construct the final structured response the frontend renders. Stretch goals include the autorating mentioned in stage 5, possible intervention by SVMs, and more.

On follow-up turns within the same conversation, stage 5 is skipped — `Conversation` reuses the previously retrieved chunks and only re-invokes stage 6, with the new question appended to message history. This assumes follow-up questions relate to the same topic, which is a reasonable heuristic for document Q&A and saves latency and API cost. Full per-turn pipeline detail, including how query decomposition fits in when `Prompt` determines it's needed, is in the Conversation Layer section of the Architecture below.

---

## Architecture: Module Responsibilities and Data Flow

The system is organized into four layers. Each layer has a clear responsibility boundary, and modules within a layer communicate through defined interfaces (behaviours, function signatures, GenServer protocols). Within a layer, the guiding principle is that **modules are organized by what they're responsible for, not by what infrastructure they share.** Two functions that both happen to call an HTTP API don't belong together unless they operate on the same domain concept and change for the same reasons. Embeddings and LLM completions both call OpenAI, but one feeds retrieval and the other feeds generation — they belong to different stations in the pipeline.

### Ingestion Layer: Two Parallel Pipeline Systems

Cake has two pipeline behaviours because, as of now, we have only two GDS. The split exists because the two generics — `ParsedDocument` and `ParsedBook` + `Chunk` — have fundamentally different parsing requirements, metadata schemas, and chunking strategies. Collapsing them into a single pipeline would require too many conditional branches and obscure the governing question each pipeline answers: *Given this GDS' nature, how do we map existing documentation into a form our customer can use?*

**`Cake.Documents.Pipeline`** is the behaviour for ingesting programming documentation. Its GDS is `ParsedDocument`. The behaviour defines callbacks `download/1`, `persist_raw_docs/2`, `parse/1`, `source/0`, and `success_message/1`. The module also contains the `ingest/4` orchestrator that sequences these callbacks into a stream pipeline: download → persist raw → parse → embed → index. The current implementation is `Cake.Documents.Hexdocs.Pipeline`, which downloads versioned tarballs from hex.pm, extracts HTML files, and parses them into `ParsedDocument` records. Future implementations (javadocs, pydocs, Rustdocs) would implement the same behaviour to produce the same GDS.

**`Cake.Books.Pipeline`** is the behaviour for ingesting books and book-like documents. Its GDS is the `ParsedBook` + `Chunk` pair. The behaviour defines callbacks `load_binary/1`, `parse/1`, `format/0`, and `success_message/0`. The current implementation is `Cake.Books.Pdf.Pipeline`, which uses a Rustler NIF (the `parsebooks` Rust crate wrapping `pdf-extract`) to parse PDFs into `ParsedBook` metadata and `Chunk` records. The NIF boundary is a known complexity point — macOS-compiled Mach-O `.so` files are incompatible with the Linux Docker container, requiring forced recompilation in `entrypoint.sh`. Future implementations (EPUB, Word, etc.) would implement the same behaviour to produce the same GDS pair.

**`Cake.Pipelines`** provides shared infrastructure used by both pipeline types: `detuple_with_logging/3` filters `{:ok, _}/{:error, _}` streams and persists errors to the `FailedIngest` table, `add_to_opensearch/4` handles index upserts, and `sweep/5` implements a retry loop for item-level failures. A `Context` struct carries pipeline identity (behaviour, implementation, version) through a run for error provenance.

### Storage and Search Layer: Postgres and OpenSearch

**`Cake.Repo`** (Ecto/Postgres) stores all structured data: parsed documents, parsed books, chunks, users, failed ingests, and Oban jobs. All schemas use binary UUIDs via `Cake.Schema` and include `sanitize_text_fields/1` in their changesets.

**`Cake.Documents.Cluster`** (Snap/OpenSearch) manages the search index. It's a GenServer that creates indices at startup and exposes `search/3` with three modes:

- **Keyword search** uses BM25 `multi_match` across configurable fields with optional boost weights.
- **Vector search** uses k-NN with k=30, cosine similarity, and HNSW via the FAISS engine, with `ef_search: 256` for recall quality.
- **Hybrid search** (the default and recommended mode) puts vector similarity in `must` and keyword matching in `should` with a configurable boost weight.

Hybrid exists because pure vector search struggles with exact identifiers, rare terms, and precise patterns that BM25 handles well, while pure keyword search misses semantic similarity. The balance between the two modes — and indeed the entire search design — is intended to be bespoke per customer, guided by the question: *Why does the customer want to see this document in particular?*

Tenant isolation uses multiple OpenSearch indices against a shared backend cluster, with bespoke frontends per client — not multiple clusters. The index schema uses 1536-dimension `knn_vector` fields (matching OpenAI `text-embedding-ada-002`) with HNSW. There is a known TODO to extract a `search_fields/0` callback into a behaviour on the pipeline generics, so that each GDS declares which of its fields are searchable and how they should be weighted, rather than requiring callers to pass a `fields` list.

`Cluster.search/3` is treated as a low-level capability. The conversation layer never calls it directly; it goes through `Cake.Retrieval` (described below), which composes search with scoring, reranking, and other retrieval-strategy concerns.

### Conversation Layer: Stateful Multi-Turn RAG

This layer is organized around a single principle: **`Cake.Conversation` is the sole orchestrator, and every other module in the layer is a peer service that it calls.** The dependency graph is a DAG. Service modules don't know about each other, with one exception (`Prompt` calls `Generation` for query decomposition, which is a genuine downward dependency on a low-level capability, not orchestration leaking sideways). This shape is deliberate: it means each service module can be tested in isolation by mocking only its own direct dependencies, and new capabilities slot in either as new pipeline steps in `Conversation` or as enhancements within an existing service module — without reorganizing.

```
Conversation → Prompt → Generation
Conversation → Retrieval → Cluster
Conversation → Embeddings
Conversation → Generation
Conversation → Responses
```

**`Cake.Conversation`** is a GenServer that manages the state of a single RAG conversation and orchestrates the per-turn pipeline. Its state includes message history, retrieved chunks, chunk map, citations, and accumulated errors. The two-phase lifecycle is the key state-management decision: the first `ask/3` call performs the full retrieve-and-generate loop, while subsequent `ask/2` calls skip retrieval and reuse cached search results, only querying the LLM with the new question appended to message history. This assumes follow-up questions relate to the same topic — a reasonable heuristic for document Q&A that saves latency and API cost.

`Conversation` is deliberately the only module that knows the full shape of a turn. It assembles message history, owns the chunk map, and decides which service to call next. Service modules are agnostic about conversational state — they receive their inputs and return their outputs, and `Conversation` handles everything in between.

The cluster module is passed as the `caller` argument to `start_link/6`. This is dependency injection for testability (Mox), not for supporting multiple clusters at runtime. A known TODO notes that `start_link/6` should eventually accept a `Conversation` struct rather than positional arguments.

**`Cake.Prompt`** owns prompt engineering. It builds the message lists that get sent to the LLM (system prompt, conversation history, retrieved context formatted as a numbered block, the new user question) and handles query decomposition — the optional pre-retrieval step of breaking a complex question into sub-queries. `Prompt` decides whether decomposition is needed for a given question and, when it is, calls `Generation` for the decomposition LLM round-trip. This is the only horizontal dependency in the layer, and it's appropriate: `Generation` is a low-level capability (text-in, text-out), and `Prompt` is one of its clients in exactly the same way `Conversation` is.

**`Cake.Retrieval`** owns retrieval strategy. It accepts a query and returns ranked context chunks with metadata. Internally it calls `Cake.Documents.Cluster.search/3` for the underlying vector/keyword/hybrid search, and it's also where confidence and relevance scoring will live, as well as autorating (deciding whether retrieved context is sufficient to answer the question, possibly via SVM or small neural net). When future capabilities like multi-index search, cross-encoder reranking, or query-classification-driven strategy selection arrive, they slot into this module without `Conversation` having to know about them. From `Conversation`'s perspective, retrieval is always "give me the best context for this query."

**`Cake.Embeddings`** calls the configured embedding service (OpenAI by default, but the architecture supports commercial platforms, private cloud deployments with open-source models, and air-gapped on-prem installations). It implements `Cake.Embeddings.Behaviour` for Mox substitution in tests. Title is prepended to text before embedding because function names and headings carry significant semantic weight. Embeddings is a thin module by design — text in, vector out — and it's used at both ingestion time (by the pipelines) and at query time (by `Retrieval`, when it needs to embed the user's question for vector search).

**`Cake.Generation`** owns LLM completions. It accepts a fully-assembled messages list, calls the LLM API, and returns the response content. It doesn't know about conversational state, chunk maps, or citations — it's purely a transport for prompt-in, response-out. Both `Conversation` (for the main answer) and `Prompt` (for query decomposition) call it. A `Cake.Generation.Behaviour` will be extracted to enable Mox substitution in tests, mirroring the pattern already in place for `Embeddings` and `Cluster`.

**`Cake.Responses`** handles post-generation processing. After `Generation` returns the LLM's response text, `Conversation` hands it to `Responses` along with the chunk context to build the chunk map (integer index → chunk metadata), parse citation markers, deduplicate, and assemble the final structured response that the frontend will render. The chunk map includes `book_title`, `page_number`, `section_title`, `chunk_index`, and `chunk_preview` — all five are necessary for citations to be distinguishable to end users (earlier versions using only book title were too generic). Currently this module is hardcoded to expect `Cake.Books.Chunk` structs; generalizing it to work with any GDS' atomic unit is a known TODO, likely mirroring the `search_fields/0` callback pattern.

**`Cake.Citations`** is a pure function module used by `Responses`. It parses `[N]` markers from response text, resolves them against the chunk_map, filters out hallucinated citations (indices not in the map), deduplicates, and sorts. It's separated from `Responses` because citation parsing is a self-contained, side-effect-free operation that benefits from being directly testable.

#### The Per-Turn Pipeline

A single user question moves through the layer as follows. Every arrow originates from `Conversation`:

1. User message arrives at `Conversation`.
2. `Conversation` → `Prompt.decompose` (which internally calls `Generation` if decomposition is needed; returns one or more queries).
3. `Conversation` → `Retrieval.retrieve` for each query (search + scoring + autorating gate; returns ranked chunks).
4. `Conversation` → `Prompt.build` (assembles the final messages list from system prompt, conversation history, retrieved chunks formatted as a numbered context block, and the user question).
5. `Conversation` → `Generation.complete` (LLM call; returns response text).
6. `Conversation` → `Responses.process` (chunk map construction, citation parsing via `Citations`, deduplication, final structuring).
7. `Conversation` updates state and notifies the frontend.

On follow-up turns within the same conversation, steps 2–3 are skipped — `Conversation` reuses the cached chunks and goes straight to building the prompt with the new question appended to message history.

### Web Layer: Phoenix LiveView Chat Interface

**`CakeWeb.ChatLive`** is the user-facing chat UI. It communicates with `Cake.Conversation` using a polling pattern: `Process.send_after` triggers periodic `handle_info/2` callbacks that call `Conversation.get_messages/1` (a `handle_call(:messages, ...)` on the GenServer). This works but is a known anti-pattern — replacement with Phoenix.PubSub is a planned TODO, with markers in both `Conversation` and `ChatLive`.

The rest of the web layer is standard Phoenix 1.7 scaffolding: `mix phx.gen.auth`-generated authentication (accounts, sessions, registration, settings), LiveView components, and Bandit HTTP server.

---

## Error Handling: Two-Tier Failure Model in Pipelines

Cake's ingestion pipelines distinguish between two categories of failure. The distinction matters because the retry strategy and observability requirements differ.

**Item-level failures** occur when a single item in the stream fails while the rest continue. A corrupt PDF that won't parse, an embedding API timeout for one chunk, or a changeset validation error on a single record are all item-level. These are handled inside the stream by `Pipelines.detuple_with_logging/3`, which logs the error with the pipeline step name, persists it to the `failed_ingests` table with full provenance (behaviour, implementation, step, version, input identifier), and filters the failed item out of the stream. Successfully-processed items continue downstream unaffected. Failed items can be retried individually via `Pipelines.sweep/5`.

**Pipeline-fatal failures** occur when the entire pipeline cannot continue. The download step failing, OpenSearch being unreachable, or an invalid embedding model string are pipeline-fatal. These are handled in the `else` branch of the `with` chain in each behaviour module's `ingest` function. Nothing downstream runs.

Step names follow the convention `"pipeline.step"` — e.g., `"books.parse"`, `"docs.embed"`, `"opensearch.index"`.

---

## Data Schemas: Structural Contracts for Domain Objects

Each GDS defines the structural contract that all pipeline implementations targeting that GDS must produce. The schemas are designed to answer the question: *Why is the customer interested in this kind of documentation?* — the metadata fields, relationships, and query helpers all flow from that consideration.

### ParsedDocument: The GDS for Programming Documentation

`Cake.Documents.ParsedDocument` is the output schema for all documentation pipelines. Every implementation (hexdocs, future javadocs, Rustdocs, etc.) produces these records. Fields: `source` (pipeline identifier), `version`, `package` (module/gem/class name), `language`, `title` (function/method name — used in embeddings), `text`, `url`, `embedding` (1536-float array), `core` (boolean: part of stdlib?). Query helpers: `by_version/2`, `by_language/2`, `by_source/2`.

### ParsedBook + Chunk: The GDS for Book-like Documents

`Cake.Books.ParsedBook` stores book-level metadata. This generic subdivides: pdf metadata goes into a `ParsedBook`, with the actual text living inside many `Chunk` records. Fields: `title`, `authors` (string array), `source_format` (determines chunking strategy), `file_hash` (deduplication), `file_size`, `word_count`, `total_pages`, `parsed_at`, `embedding_status` (enum: pending/processing/completed/failed), `metadata` (map for format-specific extras), `table_of_contents` (map), `language` (ISO code), `isbn`, `publisher`, `publication_date`. Has many `Chunk` records.

`Cake.Books.Chunk` stores the atomic searchable unit for this GDS — the text fragment that maps one-to-one to an OpenSearch document. Fields: `text`, `page_number` (nullable — some formats lack pages), `chunk_index` (ordering for unpaginated formats), `section_title`, `word_count`, `char_count`, `embedding` (1536-float array). Belongs to `ParsedBook`. Query helpers: `by_book/2`, `on_page/2`, `within_pages/3`, `by_section/2`.

### FailedIngest: Error Tracking and Retry

`Cake.FailedIngests.FailedIngest` persists every item-level pipeline failure. Fields: `pipeline_behaviour`, `pipeline_implementation`, `step`, `version`, `error_text`, `input_identifier` (sufficient to locate and retry the failed item), `pipeline_fatal` (boolean), `retry_count`, `last_retried_at`. The `sweep/5` function in `Cake.Pipelines` queries these records and retries them via a caller-provided retry function.

---

## Adding a New Ingestion Pipeline

There are two extension points depending on which GDS you're targeting. Both follow the same pattern: implement the behaviour for that GDS, return result tuples from callbacks, and let the orchestrator handle stream composition and error tracking.

### Adding a New Documentation Source (Implement Cake.Documents.Pipeline)

To ingest a new source of programming documentation into the `ParsedDocument` GDS:

1. Create a raw document schema (like `Hexdoc`) for intermediate storage of fetched content — this supports the "raw data first" principle so you can re-process when parsing heuristics improve.
2. Implement callbacks: `download/1` (fetch raw docs for a version), `persist_raw_docs/2` (save raw files as source of truth), `parse/1` (transform raw docs into `ParsedDocument` attrs), `source/0` (return identifier string), `success_message/1` (human-readable completion message).
3. Register with Oban via `DocumentIngestionJob.enqueue_for_version/4` for async ingestion.
4. Ensure all callbacks return `{:ok, _}` / `{:error, _}` tuples so `detuple_with_logging` can observe failures.
5. Optionally implement `retry_from_raw/2` to enable item-level retry from persisted raw docs.

### Adding a New Book/Ebook Format (Implement Cake.Books.Pipeline)

To ingest a new book-like format into the `ParsedBook` + `Chunk` GDS:

1. Implement callbacks: `load_binary/1` (read file into memory), `parse/1` (transform binary into `{ParsedBook, [Chunk]}` tuple), `format/0` (return format string like "pdf"), `success_message/0`.
2. Add format-specific parsing logic. If `parse/1` calls code that can raise (e.g., a NIF), the behaviour's orchestrator wraps it in `try/rescue`.
3. The schema for any new data structures must `use Cake.Schema` and include `sanitize_text_fields/1` if it has string fields.

### Iterating the Generics Themselves

Each time a new pipeline implementation is built, the question to ask is: *Does this require a refinement of our existing generics, or does it require an entirely new GDS?* For example, if Word documents share enough structural similarity with PDFs (metadata + searchable text chunks), they should produce `ParsedBook` + `Chunk` records via a new `Cake.Books.Docx.Pipeline`. If a fundamentally different kind of source material arises — say, structured spreadsheet data or image-based documents — that may warrant designing a new GDS with its own pipeline behaviour.

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

The cluster creates indices at startup if they don't exist. Index names: `"docs"` (programming documentation), `"chunks_of_books"` (book content). Both use 1536-dimension `knn_vector` fields with HNSW + FAISS and cosine similarity.

### OpenAI Embeddings and LLM Responses

```elixir
config :cake, Cake.Embeddings,
  openai_key: "sk-...",
  base_url: "https://api.openai.com/v1/embeddings"

config :cake, Cake.Generation,
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

**Post-demo planned:**

- Refactor the conversation layer into the six-module decomposition described in the Architecture section (`Conversation`, `Prompt`, `Retrieval`, `Embeddings`, `Generation`, `Responses`). The current codebase has `Conversation` plus `Responses` plus `Embeddings`; the structural work is extracting `Prompt`, `Retrieval`, and `Generation` into their own modules and collapsing the existing `Cake.Responses` into its post-processing role (`query_llm` moves out to `Generation`, prompt assembly moves out to `Prompt`).
- Replace the polling pattern between `CakeWeb.ChatLive` and `Cake.Conversation` with Phoenix.PubSub. TODO markers already exist in both modules.
- Expand test coverage per the four-tier plan.
- Extract `Cake.Generation.Behaviour` for Mox substitution in tests, mirroring `Cake.Embeddings.Behaviour` and the injection pattern already used for `Cake.Documents.Cluster`.
- Generalize `Cake.Responses` post-processing (chunk map construction, citation resolution) beyond `Cake.Books.Chunk` to work with any GDS' atomic unit, likely mirroring the `search_fields/0` callback pattern.
- Extract a `search_fields/0` callback into a behaviour on the GDS pipeline generics, so each GDS declares which of its fields are searchable and how they should be weighted, rather than requiring callers to pass a `fields` list to `Cluster.search/3`.
- Change `Cake.Conversation.start_link/6` to accept a `Conversation` struct rather than positional arguments.
- Word, Excel, CSV, and JPG ingestion pipelines.

**Longer-term:**

- Query decomposition (lives in `Cake.Prompt`; calls `Cake.Generation` for the decomposition round-trip when a question is complex enough to need sub-queries).
- Confidence/relevance scoring and autorating (live in `Cake.Retrieval`; autorating may graduate to its own module if it develops enough configuration and strategy complexity to warrant it).
- Cross-encoder re-ranking pipelines (`Cake.Retrieval`).
- Query expansion, HyDE-style (spans `Cake.Prompt` for hypothetical-answer generation and `Cake.Retrieval` for searching over the expanded query).
- Multi-index search and result merging (`Cake.Retrieval`).
- Semantic chunking with overlap (ingestion pipelines — specifically each `Cake.Books.Pipeline` implementation).
- Context assembly strategies (`Cake.Prompt`): how to order, truncate, and interleave retrieved chunks when the context window is tight.
- Faithfulness evaluation harness for measuring citation accuracy and answer groundedness against a ground-truth QA set.
- Conversational memory improvements beyond the current reuse-chunks-on-follow-up heuristic.
- Adaptive search that learns what works for each customer's domain, feeding signals back into `Cake.Retrieval`'s strategy selection.

---

## Dynamic Refdoc Protocol: Keeping This File Current

This README is a living document that should accurately reflect the codebase at all times. Any AI assistant making changes to Cake should review this file after completing a task and propose updates to any sections that are now stale. Human contributors should do the same. The rule: **if you changed it in code, check whether you need to change it here.**

The companion file `CLAUDE.md` contains operational rules and conventions for AI assistants. It is more prescriptive (what you *must* do) while this README is more descriptive (what things *are* and *why*). Both files should be kept in sync with the codebase and with each other.
