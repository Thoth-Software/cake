---
title: "CLAUDE.md — Operational Contract for AI Sessions on Cake"
tags: [claude-code, ai-instructions, conventions, quality-gates]
date: 2026-04-15
domain: development, ai-workflow
source: project-maintainer
last_verified: 2026-04-15
---

# CLAUDE.md — Operational Contract for Cake

This file governs how you work on Cake. The README describes what things are and why; this file tells you what you must do. Read both before making changes. If this file contradicts what you infer from the code, **this file wins** — flag the discrepancy to the user rather than silently following the code.

For architecture, module responsibilities, data schemas, and the RAG loop, read the README. Do not duplicate that understanding here — reference it.

---

## Dynamic Refdoc Protocol

After completing any task that changes architecture, module boundaries, conventions, or tooling:

1. Review both this file and README.md for sections that are now stale.
2. Propose specific edits: "I changed X, which means section Y should be updated. Here's what I'd change: [diff]."
3. Make approved edits before closing the task.
4. If unsure whether a change warrants a doc update, ask.

---

## Quality Gates

Run in this order. Every gate must pass before presenting changes.

```bash
mix compile --warnings-as-errors --force  # Zero warnings. Hard gate.
mix credo --strict                         # Zero issues. No inline disables without approval.
mix test                                   # Zero failures, zero warnings.
mix coveralls.json                         # Must not reduce coverage below threshold.
```

`mix quality.fast` (compile + credo) is the minimum local check. `mix quality` adds dialyzer. Tests run with `MIX_ENV=test`; the test alias runs `ecto.create --quiet` and `ecto.migrate --quiet` first.

Dialyzer is not yet a hard gate (the config line is commented out) but do not introduce new warnings.

---

## Conventions

### Dependency Injection

Modules that depend on external services accept collaborator modules as arguments — for Mox testability, not runtime polymorphism. `Conversation` takes `caller` (the cluster module). Pipelines read the embeddings module from application config. When adding new external-service dependencies, follow this pattern: define a behaviour, implement it, pass the module as an argument or read it from config.

### Result Tuples and Pipeline Error Handling

All pipeline callbacks return `{:ok, _}` or `{:error, _}`. Stream steps use `Pipelines.detuple_with_logging/3` — never the silent `detuple/1`. Step names follow `"pipeline.step"` convention (e.g., `"books.parse"`, `"docs.embed"`). Pipeline-fatal errors go in the `else` branch of the `with` chain in each behaviour's `ingest` function.

### Schemas

Every Ecto schema must `use Cake.Schema` (not `Ecto.Schema`). Every changeset for a schema with string fields must call `sanitize_text_fields/1`. UUIDs are binary, not string.

### Tests

Use `Cake.Factory` (ExMachina) for test data, imported via `DataCase`, `ConnCase`, or `ObanCase`. Ecto-backed factories use `insert/1`; non-Ecto domain objects use `build/1`. New domain structs need a corresponding factory.

Property tests (StreamData) go in `*_property_test.exs`. When fixing a bug found by a property test, add a corresponding example test in the standard file.

Mox expectations go in individual tests, not setup blocks.

### OpenSearch Test Isolation

`test_helper.exs` sets `Application.put_env(:cake, :skip_opensearch, true)`. Pipeline code checks this flag. Tests that need search behavior mock the cluster via Mox or a test module with the same function signature.

---

## Infrastructure Gotchas

The dev environment runs three containers via `docker-compose.yml`: `cake_app`, `cake_db` (Postgres 14), `cake_opensearch`.

**NIF clobbering.** The `.:/app` bind mount overlays macOS binaries onto the Linux container. `entrypoint.sh` forces recompilation (`rm -f priv/native/*.so && mix deps.compile --force bcrypt_elixir && mix compile --force`). The diagnostic for this failure is "module not available" — not `:nif_not_loaded`.

**Colima FD limits.** Default 1024 is too low for concurrent `Task.async_stream` fan-out. Raise via provision script.

**Colima port forwarder leak.** `limactl` accumulates CLOSED socket FDs. Fix: `colima start --network-address`.

**Colima port forwarder saturation.** `portForwarder: ssh` saturates under burst traffic. Use `grpc`.

**Bind mount hot paths.** Heavy virtiofs I/O through the mount is slow. Copy to `/tmp` inside the container on hot paths.

---

## Known Defects and Deferred Work

If your task touches any of these, flag it to the user rather than silently resolving or ignoring it.

- **Polling → PubSub**: `ChatLive` and `Conversation` both have TODO markers for replacing `Process.send_after` polling with Phoenix.PubSub.
- **`Responses.Behaviour`**: Not yet extracted. Preferred approach: pass the responses module as an argument, consistent with how `caller` works.
- **`search_fields/0` callback**: Each GDS should declare its own searchable fields rather than callers passing a `fields` list. TODO comment in `Cluster.search/3`.
- **`Responses.query_llm/4` hardcoded to Chunk**: Needs to become GDS-agnostic.
- **`Conversation.start_link/6` positional args**: Should eventually accept a struct.
- **First-turn error wrapping bug**: The `else` branch in the first-turn `handle_cast` double-wraps the error tuple. Comment in code: "Fix ya shit." Do not silently fix this — discuss with user first.
- **Post-demo formats**: Word, Excel, CSV, JPG pipelines are explicitly deferred.

---

## Reference Loading Rules

All reference files live in `priv/reference/`. Load them **before** making changes. Read the full file, then proceed.

### Always load

- `priv/reference/naming-conventions.md` — at the start of any task involving naming (modules, functions, variables, atoms).
- `priv/reference/enum-cheat.md` — before writing any collection transformation. If you're about to write explicit recursion over a list, check this first.

### Load by trigger

| When you're about to... | Load these |
|---|---|
| Refactor function bodies, change pattern matching, modify string/list/map logic, add parameters, change arity, modify exception handling, introduce boolean/flag params | `code-anti-patterns.md` + `patterns-and-guards.md` |
| Create/rename/move modules, restructure directories, define new public APIs or behaviours, add/change structs or schemas, introduce dependencies, change module call graphs, add config | `design-anti-patterns.md` |
| Write/modify macros, `use` declarations, `quote`/`unquote`, DSLs, compile-time code generation | `macro-anti-patterns.md` + `macros.md` + `quote-and-unquote.md` |
| Create/modify/supervise GenServers/Agents/Tasks, modify supervision tree, use spawn/Task.async, work with Registry/PubSub/message passing | `process-anti-patterns.md` + `genservers.md` + `supervisor-and-application.md` (add `dynamic-supervisor.md` if dynamic spawning) |
| Write/modify `@type`, `@spec`, address type warnings, design data types | `gradual-set-theoretic-types.md` + `typespecs.md` |
| Write/modify public API for external consumption, design behaviours for third-party use | `library-guidelines.md` |

---

## File Map

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

test/
  support/
    factory.ex             # ExMachina test data factories
    data_case.ex           # Ecto sandbox setup
    conn_case.ex           # Phoenix conn setup
    oban_case.ex           # Oban testing helpers
    test_pipeline.ex       # Mock pipeline implementations
  cake/
    citations_test.exs
    citations_property_test.exs

config/
  dev.exs      # Dev config (live reload, logging)
  test.exs     # Test config (sandbox, Oban manual mode)
  runtime.exs  # Runtime config (reads env vars)

native/parsebooks/   # Rust crate for PDF parsing via Rustler
```
