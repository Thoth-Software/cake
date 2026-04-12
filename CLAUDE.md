---
title: "CLAUDE.md — Operational Contract for AI Sessions on Cake"
tags: [claude-code, ai-instructions, architecture, conventions, quality-gates]
date: 2026-04-12
domain: development, ai-workflow
source: project-maintainer
last_verified: 2026-04-12
---

# CLAUDE.md — Operational Contract for Cake

This file is the primary context document for any AI assistant working on the Cake codebase. Read it in full before making changes. It defines the rules, conventions, architecture, and quality gates that govern all modifications. If something in this file contradicts what you infer from the code, **this file wins** — flag the discrepancy to the user rather than silently following the code.

---

## Dynamic Refdoc Protocol: How This File Stays Current

This file is a living document. After completing any task that changes Cake's architecture, module boundaries, conventions, or tooling, you must do the following:

1. Review this file and README.md for sections that are now stale or incomplete.
2. Propose specific edits to the user. Frame them as: "I changed X, which means section Y in CLAUDE.md should be updated. Here's what I'd change: [diff]."
3. If the user approves, make the edits before closing the task.
4. If unsure whether a change warrants a doc update, ask.

The goal is that any future AI session reading this file gets an accurate picture of the codebase as it exists *now*, not as it existed when this file was last manually edited. Architectural drift without documentation drift is the failure mode this protocol prevents.

---

## Quality Gates: Compile, Lint, Types, Tests, Coverage

Every change must pass all of the following before being considered complete. Run them in this order because earlier gates are faster and catch different classes of issues:

`mix compile --warnings-as-errors --force` must produce zero warnings. This is a hard gate. Warnings are not acceptable even with explanations.

`mix credo --strict` must produce zero issues. Credo is configured in `.credo.exs`. If a new check triggers that you believe should be suppressed, explain why to the user and propose a config change — do not add `# credo:disable-for-this-file` without approval.

`mix dialyzer` must produce zero warnings beyond those listed in `.dialyzer_ignore.exs`. If your change introduces a new Dialyzer warning, either fix the underlying issue or propose adding the suppression with a comment explaining why.

`mix test` must pass with zero failures and zero warnings. Tests run with `MIX_ENV=test`. The test alias runs `ecto.create --quiet` and `ecto.migrate --quiet` before the test suite.

`mix coveralls.json` enforces a minimum coverage threshold (configured in `coveralls.json`). If your change reduces coverage below the threshold, add tests to compensate.

The shortcut aliases: `mix quality.fast` runs compile + credo. `mix quality` runs compile + credo + dialyzer. Always run at least `mix quality.fast` before presenting changes.

---

## Module Architecture: What Exists and What Owns What

Cake is a RAG framework with two parallel ingestion subsystems (documents and books) feeding into a shared conversation layer. The following module map describes the current state. Modules are grouped by responsibility.

### Ingestion Layer: How Raw Data Becomes Searchable Content

`Cake.Documents.Pipeline` is a behaviour module that defines the contract for ingesting programming documentation (hexdocs, javadocs, etc). It also contains the `ingest/4` orchestrator function that sequences download → persist → parse → embed → index. Implementations live under `Cake.Documents.Hexdocs.Pipeline` (and future ones for other sources). The orchestrator uses `Pipelines.detuple_with_logging/3` at every stream transformation step.

`Cake.Books.Pipeline` is a parallel behaviour for ingesting books/ebooks. It follows the same pattern: `load_binary/1` → `parse/1` → persist → embed → index. The PDF implementation uses a Rustler NIF (`parsebooks` crate via `pdf-extract`). Implementations live under `Cake.Books.Pdf.Pipeline` (and future ones for EPUB, etc).

`Cake.Pipelines` contains shared helpers: `detuple_with_logging/3` (filters errors from streams, logs them, persists to FailedIngest), `add_to_opensearch/4`, `sweep/5` (retry loop for failed items), and `Context` struct (carries pipeline identity through a run).

`Cake.FailedIngests` is the context module for the `failed_ingests` table. Every item-level pipeline failure is persisted here with behaviour, implementation, step, version, error text, and input identifier. Pipeline-fatal errors are logged in the `else` branch of each behaviour's `ingest` function.

### Storage and Search Layer: Where Data Lives and How It's Retrieved

`Cake.Documents.Cluster` is a `Snap.Cluster` GenServer managing the OpenSearch connection. It provides `search/3` with three modes: `:keyword` (multi_match on fields), `:vector` (k-NN with cosine similarity via FAISS), and `:hybrid` (vector as `must`, keyword as `should` boost). It also handles index creation at startup via `create_indexes_unless_exist/1`. The index schema uses 1536-dimension knn_vector fields (matching OpenAI ada-002) with HNSW.

`Cake.Repo` is the Ecto repo for Postgres. All Ecto schemas use `Cake.Schema` (not `Ecto.Schema` directly) which provides `sanitize_text_fields/1` in changesets and uses binary UUIDs as primary keys.

### Conversation Layer: The RAG Loop

`Cake.Conversation` is a GenServer managing multi-turn RAG conversations. State includes `search_results`, `message_history`, `chunk_map`, `citations`, and `errors`. It has a two-phase lifecycle: the first `ask/3` call embeds the question, searches, queries the LLM, and stores results. Subsequent `ask/2` calls reuse the stored search results and only query the LLM. The cluster module is passed as the `caller` argument (dependency injection for testability, not multi-cluster support).

`Cake.Responses` calls the LLM API with retrieved context. Currently implements OpenAI only (`:openai` clause); Anthropic clause is a TODO stub. It builds a numbered context format with chunk metadata, constructs the `chunk_map` (index → metadata), and returns `{:ok, %{response, chunk_map, usage}}`.

`Cake.Citations` parses `[N]` markers from LLM response text, resolves them against the chunk_map, drops hallucinated citations (indices not in the map), deduplicates, and sorts. Pure function, no side effects.

`Cake.Embeddings` calls the OpenAI embeddings API. Implements `Cake.Embeddings.Behaviour` for Mox testability. Prepends title to text before embedding.

### Web Layer: How Users Interact

`CakeWeb.ChatLive` is the LiveView chat interface. It uses a polling pattern: `handle_info/2` + `Process.send_after` to periodically check the Conversation GenServer for new messages (via `Conversation.get_messages/1` → `handle_call(:messages, ...)`). PubSub replacement for polling is a planned TODO.

Phoenix auth scaffolding (`Accounts`, `UserAuth`, settings/registration/login LiveViews) is standard `mix phx.gen.auth` output with minimal customization.

### Data Schemas: The Shape of Things

`Cake.Documents.ParsedDocument` — universal schema for indexed documentation. Fields: source, version, package, language, title, text, url, embedding, core.

`Cake.Books.ParsedBook` — book metadata. Fields: title, authors, source_format, file_hash, file_size, word_count, total_pages, parsed_at, embedding_status, metadata (map for format-specific extras), table_of_contents.

`Cake.Books.Chunk` — searchable chunk of a book. Fields: text, page_number, chunk_index, section_title, word_count, char_count, embedding. Belongs to ParsedBook.

`Cake.Documents.Hexdocs.Hexdoc` — intermediate storage for raw Elixir source code before parsing. Fields: module, version, content, url.

`Cake.FailedIngests.FailedIngest` — error tracking. Fields: pipeline_behaviour, pipeline_implementation, step, version, error_text, input_identifier, pipeline_fatal, retry_count, last_retried_at.

---

## Conventions: Patterns You Must Follow

### Dependency Injection via Module Arguments

Several modules accept collaborator modules as arguments rather than hardcoding them. This is for Mox testability, not for runtime polymorphism. `Conversation` takes `caller` (the cluster module). `Pipeline.ingest/4` reads the embeddings module from application config. When adding new modules that depend on external services, follow this pattern: define a behaviour, implement it, and pass the module as an argument or read it from config.

### Result Tuples and Error Handling in Pipelines

All pipeline callbacks return `{:ok, _}` or `{:error, _}` tuples. Stream transformation steps use `Pipelines.detuple_with_logging/3` (not the silent `detuple/1`) to filter errors, log them, and persist them to FailedIngest. Step names follow the convention `"pipeline.step"` (e.g., `"books.parse"`, `"docs.embed"`). Pipeline-fatal errors are handled in the `else` branch of the `with` chain in each behaviour's `ingest` function.

### Schema Conventions

Every new Ecto schema must `use Cake.Schema` (not `Ecto.Schema`). Every changeset for a schema with string fields must call `sanitize_text_fields/1`. UUIDs are binary, not string.

### Test Conventions

Use `Cake.Factory` (ExMachina) for test data. Import it via the case templates (`DataCase`, `ConnCase`, `ObanCase`). Ecto-backed factories use `insert/1`; non-Ecto domain objects (chunk_maps, embedding responses, LLM responses) use `build/1`. When adding new domain structs, add a corresponding factory.

Property tests (StreamData) go in files named `*_property_test.exs`. When fixing a bug found by a property test, add a corresponding example test in the standard test file.

Mox expectations are set up in individual tests, not in setup blocks, to keep each test self-describing.

### OpenSearch Test Isolation

`Application.put_env(:cake, :skip_opensearch, true)` is set in `test_helper.exs`. Pipeline code checks this flag before making OpenSearch calls. Tests that need search behavior mock the cluster module via Mox or pass a test module implementing the same function signature.

---

## Infrastructure: Docker Compose Development Environment

The dev environment runs three containers via `docker-compose.yml`: `cake_app` (Elixir/Phoenix), `cake_db` (Postgres 14), `cake_opensearch` (OpenSearch, single-node, security disabled).

The `entrypoint.sh` script waits for OpenSearch health (yellow/green), runs `mix deps.get`, forces recompilation of Rust NIFs (`rm -f priv/native/*.so && mix deps.compile --force bcrypt_elixir && mix compile --force`), runs migrations, seeds, and starts Phoenix with `--sname dev`.

The `.:/app` bind mount means macOS-compiled binaries overlay onto the Linux container. This is why `entrypoint.sh` forces NIF recompilation — without it, macOS Mach-O `.so` files would be loaded instead of Linux ELF, causing "module not available" errors (not `:nif_not_loaded`, which is the non-obvious diagnostic).

The dev environment runs inside a Colima VM on macOS. Known instability vectors: default 1024 FD limit (raise via provision script), `portForwarder: ssh` saturates under burst traffic (use `grpc`), heavy virtiofs I/O through the bind mount (copy to `/tmp` inside container on hot paths), and leaked CLOSED socket FDs in `limactl` port forwarder (fix: `colima start --network-address`).

---

## Current TODOs and Deferred Work

These items are acknowledged technical debt or planned work. If your task touches any of these areas, flag it to the user rather than silently resolving or ignoring the TODO.

Replace polling with Phoenix.PubSub in ChatLive and Conversation. TODOs are placed in both files.

Extract `Cake.Responses.Behaviour` for Mox testability. Preferred approach: pass the responses module as an argument (consistent with how the cluster is already passed via `caller`).

Extract `search_fields/0` callback into a behaviour on the pipeline generics, so schemas declare their own searchable fields rather than callers passing a fields list.

`Responses.query_llm/4` is currently hardcoded to `Cake.Books.Chunk` struct shape. It needs to be made agnostic about what struct is passed in, likely mirroring the search callback pattern.

Post-demo document formats: Word, Excel, CSV, JPG pipelines are explicitly deferred.

`Conversation.start_link/6` should eventually expect a `Conversation` struct. For now, it takes positional arguments.

The Conversation error handling in the first-turn `handle_cast` has a known issue: the error variable in the `else` branch contains a full error tuple that's being wrapped in another tuple. Comment in code: "Fix ya shit."

---

## File Map: Where to Find Things

```
lib/
  cake/
    accounts/              # Phoenix auth (User, UserToken, UserNotifier)
    books/                 # Book ingestion subsystem
      chunk.ex             # Chunk schema
      parsed_book.ex       # ParsedBook schema
      pipeline.ex          # Books.Pipeline behaviour + orchestrator
      pdf/pipeline.ex      # PDF implementation (Rustler NIF)
    documents/             # Documentation ingestion subsystem
      cluster.ex           # OpenSearch Snap.Cluster + search/3
      parsed_document.ex   # ParsedDocument schema
      parsed_documents.ex  # ParsedDocuments context (CRUD)
      pipeline.ex          # Documents.Pipeline behaviour + orchestrator
      hexdocs/             # Hexdocs implementation
        downloads.ex       # Tarball fetching
        hexdoc.ex          # Raw hexdoc schema
        pipeline.ex        # Hexdocs.Pipeline implementation
    failed_ingests/        # FailedIngest schema + context
    conversation.ex        # Conversation GenServer
    citations.ex           # Citation parser (pure function)
    embeddings.ex          # OpenAI embeddings client + Behaviour
    pipelines.ex           # Shared pipeline helpers + Context
    responses.ex           # LLM response generation
    schema.ex              # Base schema (use Cake.Schema)
  cake_web/
    live/
      chat_live.ex         # LiveView chat UI
    user_auth.ex           # Auth plugs
    # ... standard Phoenix web scaffolding

test/
  support/
    factory.ex             # ExMachina test data factories
    data_case.ex           # Ecto sandbox setup
    conn_case.ex           # Phoenix conn setup
    oban_case.ex           # Oban testing helpers
    test_pipeline.ex       # Mock pipeline implementations
  cake/
    citations_test.exs           # Example-based citation tests
    citations_property_test.exs  # StreamData property tests

config/
  dev.exs      # Dev config (live reload, logging)
  test.exs     # Test config (sandbox, Oban manual mode)
  runtime.exs  # Runtime config (reads env vars)

native/parsebooks/   # Rust crate for PDF parsing via Rustler
```
