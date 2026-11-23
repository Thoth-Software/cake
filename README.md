---
title: "Cake — RAG Framework for Enterprise Document Q&A"
tags: [cake, rag, elixir, phoenix, opensearch, architecture, domain-model]
date: 2026-11-23
domain: architecture, reference
source: project-maintainer
---

# Cake

Cake is a RAG (Retrieval-Augmented Generation) framework built in Elixir/Phoenix. It ingests enterprise documents, stores embeddings in OpenSearch, and surfaces answers through a Phoenix LiveView chat interface. The immediate use case is a document Q&A tool for enterprise customers whose document formats include PDF, Word, Excel, CSV, and JPG. The demo-critical path is PDF ingestion, LiveView chat UI, and citation display. Other document formats are explicitly post-demo. A second ingestion system ships alongside the PDF one: programming documentation, parsed today from Elixir's own source.

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

- **`Cake.Documents.Hexdocs.Hexdoc`** — stores raw Elixir source cloned from the elixir-lang/elixir repository. Intermediate storage between download and parsing into `ParsedDocument`.

### Retrievables (Searchable Units)

A retrievable is the atomic schema that maps one-to-one to an OpenSearch document. It is the unit that search returns and that citations point at. The retrievable may or may not be the same schema as the GDS identity module.

Current retrievables:

- **`Cake.Books.Chunk`** — for the `ParsedBook` GDS. The book-level `ParsedBook` holds metadata; the chunk is what search returns.
- **`Cake.Documents.ParsedDocument`** — for the `ParsedDocument` GDS. The GDS is its own retrievable because a documentation entry is already atomic.

---

## Cardinality: How GDSes, Data Structures, and Pipelines Relate

These four cardinality relationships are stated explicitly because the rest of the architecture assumes them, and the distinctions get subtle once more than one GDS is in play.

**GDS ↔ ingestion pipeline behaviour: 1:1.** Each GDS has exactly one pipeline behaviour that targets it, and each pipeline behaviour produces exactly one GDS. `Cake.Books.Pipeline` targets the `ParsedBook` + `Chunk` GDS; `Cake.Documents.Pipeline` targets the `ParsedDocument` GDS. This is why, deliberately, no framework-level `Cake.Ingestion` master behaviour exists — the GDS *is* the unit of pipeline grouping, and unifying the two behaviours is deferred indefinitely.

**GDS → data structures: 1:many.** A GDS can be composed of multiple related Ecto schemas. The `ParsedBook` + `Chunk` GDS has two data structures (parent and child), where `Chunk` is the retrieval unit. The `ParsedDocument` GDS has one data structure and is its own retrieval unit.

**Data structure → pipeline implementation: 1:1 per source.** Each pipeline implementation produces records of exactly one data structure shape per run. `Cake.Books.Pdf.Pipeline` produces `ParsedBook` + `Chunk` records from a PDF. A future `Cake.Books.Epub.Pipeline` would produce the same shape from an EPUB.

**Pipeline behaviour → implementations: 1:many.** Each pipeline behaviour can have any number of concrete implementations. Adding a new source format is an additive operation against a stable behaviour; it never reshapes the GDS.

---

## Architecture: Application Layers

The system is organized into four layers. Each layer has a clear responsibility boundary, and modules within a layer communicate through defined interfaces (behaviours, function signatures, GenServer protocols). The guiding principle is that **modules are organized by what they're responsible for, not by what infrastructure they share.** Two functions that both call an HTTP API don't belong together unless they operate on the same domain concept and change for the same reasons.

### Supervision Tree Boot Order

The application starts children in this order under Cake.Application:

1. `CakeWeb.Telemetry` — telemetry metrics
2. `Cake.Repo` — Postgres connection pool
3. Oban — background job processing
4. `DNSCluster` — DNS-based node discovery
5. `Phoenix.PubSub` — pub/sub for LiveView
6. `Finch` (`Cake.Finch`) — the HTTP client pool for Swoosh's API client, which only the prod config names; the OpenAI and S3 clients go through Req's own pool
7. `Cake.Search.Deployment` — OpenSearch connection + index creation
8. `Task.Supervisor` (`Cake.TaskSupervisor`) — shared task supervisor: conversation turn tasks, flat-decomposition sub-search fan-out, and every ingestion fan-out (see "Error Handling in Pipelines")
9. `DynamicSupervisor` (`Cake.ConversationSupervisor`) — supervises the per-session `Conversation` GenServers started via `Conversation.start/1` (`:temporary` children; each stops on its own when its `:owner` LiveView exits)
10. `CakeWeb.Endpoint` — Phoenix HTTP server (last, so all dependencies are ready)

Every `mix test` run starts the application, so this boot order runs in every ExUnit job (`server: false` in test only keeps the endpoint from listening). What the compose smoke test alone adds is the boot of the real stack through `entrypoint.sh` and the assertion that step 7 created both collections (`.claude/rules/compose-smoke.md`).

### Module Boundaries (enforced by `boundary`)

The layer responsibilities above are enforced at compile time by the [`boundary`](https://hex.pm/packages/boundary) compiler. Each top-level context is a boundary that declares the boundaries it may call (`deps`) and the modules it makes public (`exports`); any cross-boundary call not covered by a declared dep is a compiler warning, which fails the build under `--warnings-as-errors` (how `mix precommit`, `mix quality` and CI compile). Calls made from a protocol implementation are not checked unless it is classified into a boundary, and none of the four `defimpl`s is.

- **`Cake`** — the shared kernel: `Repo`, `Schema`, `Mailer`, the `GDS` behaviour, the `Citable`/`Promptable` protocols, `Citations`, `FailedIngests` and `FailedIngests.FailedIngest`, `ParseBooks`. `Cake.Release`, the release's database tasks, is in the kernel too, and is not exported: it touches only `Cake.Repo`, and nothing calls it but the release's own scripts (see "Deployment"). Depends on nothing internal; every context may depend on it.
- **Ingestion** — `Cake.Books` (exports `Adapters`, `ParsedBook`, `Chunk`, `Pipeline`, `Pdf.Pipeline`, `ZipExtractor`) and `Cake.Documents` (exports `Pipeline`, `Hexdocs.Pipeline`, `ParsedDocument`) depend on `Cake.Search`, `Cake.Embeddings`, and `Cake.Pipelines` (exports `Context`; in turn depends on `Cake.Search`).
- **Retrieval** — `Cake.Search` depends only on the kernel and exports `Result`, `Query`, `Hit`, `Backend`, `Provenance` and `Deployment`. The collections created at boot come from `:search_collections` config, which is what keeps the search layer from depending back on the ingestion contexts (an otherwise-cyclic dependency). `Cake.Embeddings` likewise depends only on the kernel and exports `Behaviour`.
- **Conversation** — `Cake.Conversation` is the orchestrator (exports `Events`); it depends on `Cake.Prompt` (exports nothing), `Cake.Search`, `Cake.Embeddings`, `Cake.Generation` (exports `OpenAI` only, so `Cake.Generation.Anthropic` is unreachable from outside its boundary), `Cake.Responses` (exports `Result`), and `Cake.Decomposition` (exports `Result` and `LLM`). Peer-to-peer deps among the service modules are minimal: `Cake.Responses → Cake.Search`, `Cake.Prompt → Cake.Search` (for the `Result` type), and `Cake.Decomposition → Cake.Prompt`/`Cake.Generation`. Nothing depends back on `Cake.Conversation` except the web layer. `Cake.Candidates` is a top-level boundary of its own (deps `Cake` and `Cake.Search`, exports nothing) that the web layer calls alongside `Conversation`.
- **Accounts** — `Cake.Accounts` depends only on the kernel and exports `User`.
- **Web / jobs / app / tasks** — `CakeWeb` depends on `Cake`, `Cake.Accounts`, `Cake.Books`, `Cake.Candidates`, `Cake.Conversation`, `Cake.Embeddings` and `Cake.Search`, and exports `Endpoint` and `Telemetry`; `Cake.Jobs` depends on `Cake.Documents`; Cake.Application (top-level, `@moduledoc false`) on `Cake`, `CakeWeb` and `Cake.Search`. The three Mix tasks are top-level boundaries of their own: `Mix.Tasks.Precommit` and `Mix.Tasks.Hooks.Install` with no deps, `Mix.Tasks.Cake.Nif.Check` depending on `Cake`.

The compiler runs in `:dev`/`:prod` only — test files and support modules deliberately cross boundaries, so `:test` is excluded — and CI enforces it with a dev-env compile. When you add a cross-context call, declare the `dep` (and `export` the target module) rather than working around the boundary.

---

## The RAG Loop: End-to-End Data Flow

This section traces how content flows from raw document to user-facing answer, connecting the layers described above.

1. **Acquire**: A pipeline implementation fetches source content (a PDF binary from the storage adapter, a `git clone` of elixir-lang/elixir for hexdocs, etc.).
2. **Persist raw**: Raw content is persisted before parsing (the "raw data first" principle, under "Raw Data Structs"). Where it lives depends on the pipeline: Hexdocs source goes to Postgres as `Hexdoc.content`; book binaries go to the `Cake.Books.Adapters` store, with Postgres holding the book's `source_file_path` (the storage key) and `file_hash`.
3. **Parse**: The pipeline transforms raw content into GDS schema records (e.g., `ParsedBook` + `Chunk`).
4. **Index**: Embedded records are upserted into OpenSearch indices via `Cake.Pipelines.add_to_search_backend/3`. The retrieval unit maps one-to-one to OpenSearch documents.
5. **Retrieve**: `Cake.Conversation` orchestrates retrieval — embed the question, search OpenSearch, score and rank results.
6. **Generate**: `Prompt` formats retrieved chunks into a numbered context block. `Generation` sends the messages list to the LLM. `Responses` parses `[N]` citation markers and builds the structured response the frontend renders.

---

## Custom Structs: Complete Inventory

Every custom struct in Cake, its module, and its purpose. Every one of them defines `@type t`.

### Ecto Schemas (use Cake.Schema)

| Struct | Module | Purpose |
|---|---|---|
| `ParsedBook` | `Cake.Books.ParsedBook` | Book-level metadata for book-like documents. GDS identity module for the Books GDS. |
| `Chunk` | `Cake.Books.Chunk` | Atomic searchable text fragment within a book, with its `embedding` and the `embedding_model` that produced it. Retrieval unit for the Books GDS. |
| `ParsedDocument` | `Cake.Documents.ParsedDocument` | Programming documentation entry, with its `embedding` and the `embedding_model` that produced it. Both GDS identity and retrieval unit for the Documents GDS. |
| `Hexdoc` | `Cake.Documents.Hexdocs.Hexdoc` | Raw Elixir source cloned from the elixir-lang/elixir repository. Intermediate storage (raw data struct). |
| `FailedIngest` | `Cake.FailedIngests.FailedIngest` | Persists pipeline failures, tagged with the recording run's `run_id`: item-level ones, for retry via `Cake.Pipelines.sweep/3`, and pipeline-fatal ones (`pipeline_fatal: true`), which the run-scoped listing and the sweep leave out. |
| `User` | `Cake.Accounts.User` | Phoenix authentication user record: a `username` (what a user logs in with; 3 to 32 characters, compared case-insensitively and stored as typed), a `role` (`:member` or `:admin`), an `email` (required; a user cannot log in until it is confirmed, `confirmed_at`), and a hashed password. |
| `UserToken` | `Cake.Accounts.UserToken` | Session tokens, and the mailed tokens for email confirmation, password reset and email change. |

### Non-Ecto Domain Structs

| Struct | Module | Purpose |
|---|---|---|
| `Pipelines.Context` | `Cake.Pipelines.Context` | A run's identity and options, carried through an ingestion run. Fields: `run_id`, `behaviour`, `implementation`, `version`, `opts`. Layer 1, `Cake.Pipelines`, says what each is for. |
| `Search.Query` | `Cake.Search.Query` | Composable query builder. Fields: `index` (enforced), `size` (default 10), `must`, `should`, `filter` (each default `[]`), `min_score` (default `nil`). |
| `Search.Hit` | `Cake.Search.Hit` | Backend-agnostic search hit. Every backend maps its native hit type into this struct at the boundary. Fields: `id`, `score`, `source`. |
| `Search.Result` | `Cake.Search.Result` | Normalized search result. Carries retrieval unit, the `index` (collection name) it came from, backend score, CAKE-computed scores (cosine, relevance), hit provenance (search vs. expansion), search conditions, and prompt index. Single carrier of all retrieval metadata through the pipeline. |
| `Search.Provenance` | `Cake.Search.Provenance` | Search conditions attached to each `Search.Result`: search type, query text, decomposition traceability (`decomposed`, `original_query`, `sub_question_index`), and `embedding_model` — the model the query vector was embedded under, from the `:embedding_model` search opt (the stored vector's model is on the retrieval unit). |
| `Responses.Result` | `Cake.Responses.Result` | Output struct from post-generation processing. Fields: `raw_text`, `final_text`, `chunk_map`, `citations`, `media` (always `[]` — a stub stage), `actions`, `assigns` (always `%{}` — nothing writes it), `warnings`. Layer 3, `Cake.Responses`, says how each is built. |
| `Conversation.State` | `Cake.Conversation.State` | Internal state for the `Conversation` GenServer. Enforced keys: `id`, `embedder`, `response_model`, `provider`, `gds`, and the three decomposition budgets `max_context_tokens` (for accumulated answers/steps), `max_self_ask_iterations` and `max_ircot_iterations` (round caps) — the budgets are enforced rather than defaulted so their config.exs defaults, read by `Conversation.build_state/1`, cannot drift from a struct-level copy. Also carries the collaborator modules (`embeddings`, `generation`, `responses`, `decomposition`), the turn FSM fields (`state`, `pending`, `turn_ref`, `turn_pid`, `queued_question`), the `owner_ref` monitor on the optional `:owner` pid, search results, message history, chunk map, citations, and accumulated errors. |
| `Books.PageContent` | `Cake.Books.PageContent` | Elixir-side struct the Rust PDF NIF decodes into (via NifStruct): one page's extracted text and page number. |
| `Books.PdfExtraction` | `Cake.Books.PdfExtraction` | Elixir-side struct the Rust PDF NIF decodes into: the full extraction result (pages, skipped pages, title). |
| `Books.SkippedPage` | `Cake.Books.SkippedPage` | Elixir-side struct the Rust PDF NIF decodes into: a page that could not be extracted, with its page number and a `reason` string. |
| `Decomposition.Result` | `Cake.Decomposition.Result` | Outcome of decomposing a question. Fields: `original_question` (enforced), `strategy`, `sub_questions` (`%{question, depends_on}` entries), `question_index` (positional index → entry, which `Search.Provenance` refers to). "Query Decomposition" says what each strategy means and what `new/2` validates. |

### Embedded Schemas (LiveView forms)

| Struct | Module | Purpose |
|---|---|---|
| `QuestionForm` | `CakeWeb.ChatLive.QuestionForm` | Embedded schema validating the chat question and mode (`:auto`/`:manual`). |
| `SelectionForm` | `CakeWeb.ChatLive.SelectionForm` | Embedded schema validating document selection as a non-empty subset of the offered candidate IDs. |

---

## Behaviours and Implementations: Complete Inventory

Behaviours in Cake define module-level contracts. The question they answer is "which *module* is responsible for this capability?" Use a behaviour when dispatch is by module identity.

| Behaviour | Module | Purpose | Current Implementations |
|---|---|---|---|
| `Cake.GDS` | `lib/cake/gds.ex` | Module-level contract for a Generic Data Structure. Callbacks: `collection_name/0`, `search_fields/0`, `load_from_hits/1`, and the optional `expand_with_neighbors/2` (`use Cake.GDS` supplies an identity default). | `Cake.Books.ParsedBook`, `Cake.Documents.ParsedDocument` |
| `Cake.Books.Pipeline` | `lib/cake/books/pipeline.ex` | Ingestion behaviour for book-like documents. Callbacks: `load_binary/1`, `parse/1`, `format/0`, `success_message/0` (`format/0` is required, but nothing calls it today). | `Cake.Books.Pdf.Pipeline` |
| `Cake.Documents.Pipeline` | `lib/cake/documents/pipeline.ex` | Ingestion behaviour for programming documentation. Callbacks: `download/1`, `persist_raw_docs/2`, `parse/2`, `success_message/1`, and the optional `retry_from_raw/2`. | `Cake.Documents.Hexdocs.Pipeline` |
| `Cake.Embeddings.Behaviour` | `lib/cake/embeddings/behaviour.ex` | Contract for embedding services: `embed/3`. | `Cake.Embeddings` (OpenAI impl, in `lib/cake/embeddings.ex`) |
| `Cake.Generation` | `lib/cake/generation.ex` | Contract for LLM completion services: `complete/3` and `complete_json/3` (schema-constrained JSON). | `Cake.Generation.OpenAI`, `Cake.Generation.Anthropic` (stub) |
| `Cake.Decomposition` | `lib/cake/decomposition.ex` | Contract for query-decomposition strategies: retrieval-free `decompose/2`, returning `{:ok, Decomposition.Result.t()}` or `{:error, reason}`. | `Cake.Decomposition.LLM` |
| `Cake.Search.Backend` | `lib/cake/search/backend.ex` | Contract for search backends: read, write and collection lifecycle. Callbacks: `search/1` (a `Query` in, `{:ok, [Hit.t()]}` or `{:error, search_error()}` out), `index_document/3`, `delete_document/2`, `create_collection/2`, `list_collections/0`. | `Cake.Search.Backend.OpenSearch` |
| `Cake.Responses.Behaviour` | `lib/cake/responses/behaviour.ex` | Contract for post-generation response processing: `process/3`. | `Cake.Responses` |
| `Cake.Books.Adapters` | `lib/cake/books/adapters.ex` | Contract for raw binary storage of book files. Callbacks: `read/1`, `write/2`, `exists?/1`, `delete/1`, each taking the storage key `build_key/3` produces. | `Cake.Books.Adapters.Disk`, `Cake.Books.Adapters.S3` |

---

## Protocols and Implementations: Complete Inventory

Protocols in Cake define value-level contracts. The question they answer is "what does *this value* know how to do?" Use a protocol when dispatch is by struct type.

| Protocol | Module | Purpose | Current Implementations |
|---|---|---|---|
| `Cake.Promptable` | `lib/cake/promptable.ex` | Renders a struct as prompt context for the LLM. Each implementation defines how its data should appear in the numbered context block. | `Cake.Books.Chunk`, `Cake.Documents.ParsedDocument` |
| `Cake.Citable` | `lib/cake/citable.ex` | Extracts citation metadata from a struct. Returns a map with exactly five keys: `id` (a string, normally the record's UUID), `label`, `source_ref`, `preview`, and `extras`. | `Cake.Books.Chunk`, `Cake.Documents.ParsedDocument` |

---

## Laws Specified in LawSpec

Some modules' laws are stated in [LawSpec](https://github.com/brain-fuel/lawspec) under `lawspec/`, a Mix project of its own that the `laws` CI job runs. `lawspec/README.md` says what each specification covers, law by law, and how to change one.

| Module | Specification |
|---|---|
| `Cake.Decomposition.Result` (`new/2`, `topological_order/1`) | `lawspec/laws/decomposition.lawspec` |
| `Cake.Citations` (`extract/2`) | `lawspec/laws/citations.lawspec` |
| `Cake.Responses` (`process/3`, `build_citation_map/1`) | `lawspec/laws/responses.lawspec` |
| `Cake.Candidates` | `lawspec/laws/candidates.lawspec` |
| `Cake.Prompt`: context assembly | `lawspec/laws/prompt_context.lawspec` |
| `Cake.Prompt`: token budgets and the two driver protocols | `lawspec/laws/prompt_drivers.lawspec` |
| `Cake.Search.Query`'s builders and `Backend.OpenSearch.to_query_map/1` | `lawspec/laws/search_query.lawspec` |
| `Cake.Generation` (the contract, as an ability) | `lawspec/laws/generation.lawspec` |

---

## Configuration Keys

The domain-level `:cake` application-env keys that `lib/` reads, grouped by consumer. Values are `config/config.exs` defaults unless noted. Framework configuration is as Phoenix generated it and is not listed here: `Cake.Repo`, `CakeWeb.Endpoint`, `Cake.Mailer`, `Oban` and `:dns_cluster_query` (both read in Cake.Application, which is `@moduledoc false`).

- **Models and providers.** `:default_embedding_model` (`text-embedding-ada-002`; read by `UploadLive` and `SearchLive`), `:default_embedding_dimension` (1536; read only by `Backend.OpenSearch.build_mapping/1`), `:default_provider` (`:openai`; `UploadLive`, `SearchLive`). `:default_response_model` is set but read by nothing in `lib/`. `config :cake, Cake.Conversation` (`gds`, `embedder`, `response_model`, `provider`) is what `ChatLive` starts conversations from.
- **Provider transports.** `config :cake, Cake.Embeddings` — `:openai_key`, `:base_url`, `:req_options` (a `Req.Test` plug in tests, empty in prod). `config :cake, Cake.Generation.OpenAI` — `:openai_key`, `:response_url` (the Responses API endpoint), and an optional `:plug` (a `Req.Test` plug in tests, unset in prod). `:embeddings_module` swaps the whole module for the pipelines (`Cake.Embeddings.Mock` in `config/test.exs`); the pipelines read it at call time.
- **Search.** `:search_collections` (the boot-time `{name_module, mapping_schema}` pairs), `config :cake, Cake.Search.Deployment` (the Snap cluster: one URL, set in `config/config.exs` and repeated in `dev.exs`, with nothing in `prod.exs` or `runtime.exs` yet, #362; `http_client_adapter: Cake.Search.HTTPClientStub` in test), and `:search_backend` — set in no config file; `Backend.backend/0` defaults it to `Backend.OpenSearch`, and tests inject the Mox mock with `Application.put_env`. `:skip_search_backend` makes `Pipelines.add_to_search_backend/3` pass records through unindexed, and makes the two retry-path indexers in `Books.Pipeline` and `Documents.Pipeline` return `:ok` without indexing; `test_helper.exs` sets it for every run; `Cake.SearchIntegrationCase` turns it off for the real-cluster suites and does not turn it back on, and the two `pipelines_search_backend` suites (examples and properties) turn it off, and restore it afterwards, to drive indexing through the Mox backend.
- **Book storage.** `:book_storage_adapter` (`Disk` by default, `S3` in prod, `Mock` in test), `:book_storage_tenant` (the tenant segment of storage keys, `"default"`; `BOOK_STORAGE_TENANT` in prod, `config/runtime.exs`), `:book_storage_root` (the Disk adapter's directory, default `priv/book_storage`), `:book_storage_s3_bucket` (`config/runtime.exs`, from the environment).
- **Uploads.** `:max_zip_expanded_bytes` (268 435 456, i.e. 256 MB: the most the PDF entries of one ZIP upload may declare uncompressed in total) and `:max_zip_entries` (10 000 entries per archive, PDF or not), read by `Cake.Books.ZipExtractor` at call time, which also carries a matching compiled-in default for each.
- **Decomposition.** `:decomposition_max_context_tokens` (4096), `:max_self_ask_iterations` (5), `:max_ircot_iterations` (5), `:max_sub_search_concurrency` (4), and `:sub_search_timeout` (30 000 ms), all set in `config/config.exs`; `Cake.Conversation` also carries a matching compiled-in default for each.

---

## Deployment

There are two images, and they are not variants of each other. **`Dockerfile` is the dev image**: `MIX_ENV=dev`, started through `entrypoint.sh`, which waits for OpenSearch to report yellow or green (polling every 5 s, with no timeout), runs `mix deps.get`, recompiles the app and the NIF, creates the database if it is missing and migrates it, runs the seed and starts `mix phx.server`. It is what `docker-compose.yml` builds, and the `compose-smoke` gate covers it (`ci/compose_smoke.sh`, `.claude/rules/compose-smoke.md`). **`Dockerfile.release` is the release image**, the one that is deployed (#361, the first step of staging, #360): a `mix release` built in a builder stage that has Rust for the `parsebooks` crate and builds the assets with `mix assets.deploy`, copied into a runner stage with no Mix, no compiler and no Rust, running as `nobody`. Its build context is filtered by `Dockerfile.release.dockerignore`, which BuildKit prefers over `.dockerignore` when building that file (`.dockerignore` stays the dev image's, which needs `test/` in its context). Both files came from `mix phx.gen.release --docker` and were then edited by hand.

The release has three entry points under `bin/` (each of the first two with a `.bat` twin the generator writes for Windows): `server` (starts the app with `PHX_SERVER=true`), `migrate` (runs `Cake.Release.migrate/0`, which applies every pending migration without starting the app) and `cake` itself (`cake eval`, `cake rpc`, `cake remote`); `Cake.Release.rollback/2` is reached through `cake eval`. `server`, `migrate` and `cake eval` evaluate `config/runtime.exs` first, whose prod block raises unless `DATABASE_URL`, `SECRET_KEY_BASE`, `OPENAI_KEY` and `BOOK_STORAGE_S3_BUCKET` are set, so `bin/migrate` needs the server's environment even though it uses only the database. `cake rpc` and `cake remote` attach to the node that is already running and evaluate no configuration of their own. The release never runs `priv/repo/seeds.exs`: there is no entry point for it, and the image does not contain the file. Nor can a NIF built on a host reach the image: `priv/native` is kept out of the build context and removed in the builder stage before `mix compile` builds the only `parsebooks.so` the release carries.

The `release-image` gate covers this image (`ci/release_smoke.sh`, on every pull request). It builds `Dockerfile.release` and asserts, with one-shot commands in the built image: `bin/cake eval` extracts a fixture PDF through `Cake.ParseBooks.extract_pdf/1` (the fixture is mounted, since the image carries no `test/`), so the NIF compiled in the builder stage loads in the runner stage; `bin/migrate` applies every migration under `priv/repo/migrations` to an empty Postgres; a marker file the script plants in the host's `priv/native` before building does not reach the release, whose `priv/native` holds `parsebooks.so` and nothing else; and no `seeds.exs` is in the release. It does not boot the app. The release cannot boot in prod yet: `config/runtime.exs` does not configure the search node, the object store or the endpoint for a deployed app, which is #362.

---

## Roadmap: Planned and Deferred

**Needed before the demo:** an icon for Cake. The Phoenix favicon and logo were removed with the rest of the Phoenix branding (#375) and nothing replaces them yet: the root layout declares an empty icon (`<link rel="icon" href="data:,">`), so a browser tab shows none. When there is one, put it in `priv/static/`, add it to `CakeWeb.static_paths/0`, and point that `<link>` at it.

**Post-demo planned:** test coverage expansion, Word/Excel/CSV/JPG pipelines.

**Longer-term:** autorating (`Search` or dedicated module), cross-encoder reranking (`Search`), HyDE-style query expansion (`Prompt` + `Retrieval`), multi-index search and result merging (`Retrieval`).
