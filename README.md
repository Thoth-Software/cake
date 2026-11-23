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

Each layer has a file of its own under `docs/architecture/`; this README says only what the layer is, which modules it is made of, and which way its dependencies run. The [`boundary`](https://hex.pm/packages/boundary) compiler enforces those dependencies at compile time (`docs/architecture/inventories.md`, "Module Boundaries"). Beneath all four sits the shared kernel, `Cake`, which holds among other things the repo, the base schema, the `Cake.GDS` behaviour, and the `Cake.Citable` and `Cake.Promptable` protocols. It declares no internal dependency, and every layer may depend on it.

**Layer 1: Ingestion.** Two parallel pipeline systems, one per GDS: `Cake.Books.Pipeline` (implemented by `Cake.Books.Pdf.Pipeline`, over a Rust NIF) and `Cake.Documents.Pipeline` (implemented by `Cake.Documents.Hexdocs.Pipeline`). Each behaviour module also holds its `ingest/4` orchestrator. `Cake.Pipelines` is what they share: recording failures to `FailedIngest`, indexing, and the retry sweep. `Cake.Jobs` runs the Documents pipeline as an Oban job. Ingestion depends on search and embeddings, never the reverse.

**Layer 2: Search and Retrieval.** `Cake.Search` orchestrates keyword, vector and hybrid search over a GDS's collection through the `Cake.Search.Backend` behaviour (implemented by `Cake.Search.Backend.OpenSearch`), with `Cake.Search.Query` to build a query and `Cake.Search.Result` to carry what comes back. `Cake.Search.Deployment` owns the cluster connection and creates the collections at boot. `Cake.Embeddings` turns text into vectors. Both depend only on the kernel.

**Layer 3: Conversation.** `Cake.Conversation`, a GenServer per chat, is the sole orchestrator of a turn, and every other module in the layer is a peer service it calls: `Cake.Prompt`, `Cake.Generation`, `Cake.Responses` (which calls `Cake.Citations`) and, when opted into, `Cake.Decomposition`. It also calls `Cake.Search` and `Cake.Embeddings`. Nothing depends back on it but the web layer.

**Layer 4: Web.** `CakeWeb`: the chat, upload, search and documents LiveViews, the admin panel and the account pages, behind `CakeWeb.Router` and the guards in `CakeWeb.UserAuth`, over `Cake.Accounts`. It depends on the layers below it, and only the application's supervisor depends on it.

| File | Read it when you work on |
|---|---|
| `docs/architecture/ingestion.md` | a GDS, a pipeline, `FailedIngest`, the sweep, a storage adapter or an ingestion job; it also has the field-level schemas |
| `docs/architecture/search.md` | `Cake.Search`, a backend, the deployment or embeddings |
| `docs/architecture/conversation.md` | `Conversation`, `Prompt`, `Generation`, `Responses`, `Citations` or `Decomposition` |
| `docs/architecture/web.md` | `CakeWeb`, `Cake.Accounts`, `Cake.Candidates` or `assets/` |
| `docs/architecture/inventories.md` | creating, renaming or removing a module, struct, behaviour, protocol, boundary dep or config key |
| `docs/architecture/deployment.md` | a Dockerfile, `rel/`, `entrypoint.sh` or `Cake.Release` |
| `docs/runbooks/first-admin.md` | giving someone a login, or creating the first admin |

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

## The RAG Loop: End-to-End Data Flow

This section traces how content flows from raw document to user-facing answer, connecting the layers described above.

1. **Acquire**: A pipeline implementation fetches source content (a PDF binary from the storage adapter, a `git clone` of elixir-lang/elixir for hexdocs, etc.).
2. **Persist raw**: Raw content is persisted before parsing (the "raw data first" principle, under "Raw Data Structs"). Where it lives depends on the pipeline: Hexdocs source goes to Postgres as `Hexdoc.content`; book binaries go to the `Cake.Books.Adapters` store, with Postgres holding the book's `source_file_path` (the storage key) and `file_hash`.
3. **Parse**: The pipeline transforms raw content into GDS schema records (e.g., `ParsedBook` + `Chunk`).
4. **Index**: Embedded records are upserted into OpenSearch indices via `Cake.Pipelines.add_to_search_backend/3`. The retrieval unit maps one-to-one to OpenSearch documents.
5. **Retrieve**: `Cake.Conversation` orchestrates retrieval — embed the question, search OpenSearch, score and rank results.
6. **Generate**: `Prompt` formats retrieved chunks into a numbered context block. `Generation` sends the messages list to the LLM. `Responses` parses `[N]` citation markers and builds the structured response the frontend renders.

---

## Roadmap: Planned and Deferred

**Needed before the demo:** an icon for Cake. The Phoenix favicon and logo were removed with the rest of the Phoenix branding (#375) and nothing replaces them yet: the root layout declares an empty icon (`<link rel="icon" href="data:,">`), so a browser tab shows none. When there is one, put it in `priv/static/`, add it to `CakeWeb.static_paths/0`, and point that `<link>` at it.

**Post-demo planned:** test coverage expansion, Word/Excel/CSV/JPG pipelines.

**Longer-term:** autorating (`Search` or dedicated module), cross-encoder reranking (`Search`), HyDE-style query expansion (`Prompt` + `Retrieval`), multi-index search and result merging (`Retrieval`).
