# Creating New Things — Policies

Load when creating or modifying a GDS, ingestion pipeline, decomposition strategy, behaviour, protocol, Ecto schema, or non-Ecto struct. The headings below say "new", but the rules hold for changes to an existing one too.

When asked to create new functionality, first reason about whether it is testable. If so, write the tests first, ensure they fail, then STOP. If the user approves, write the code that makes them pass. Do unit tests this way as a matter of course. If the functionality requires integration testing, stop and ask the user what to do. Always favor property tests where possible: while reasoning about testability, consider what properties each function ought to have and whether a property test can cover them; if so, prefer property tests over ordinary tests.

## New ingestion pipeline (for an existing GDS)

Consult "Adding a New Ingestion Pipeline" and "Requirements for All Pipeline Implementations" in `docs/architecture/ingestion.md` first. Short version:

- Implement the behaviour for the target GDS (`Cake.Books.Pipeline` or `Cake.Documents.Pipeline`).
- Every fallible operation reports through `{:ok, _}`/`{:error, _}`. Direct callbacks return them as-is (`retry_from_raw/2`, `load_binary/1`); the one tagged exception is `Documents.Pipeline.download/1`, which returns `{:error, :download, reason}` so the orchestrator can attribute the failure to the download step. Inside a stream callback (`persist_raw_docs/2`, `parse/2`), fallible per-item work produces result tuples that the callback itself passes through `Pipelines.detuple_with_logging/3` *before* returning — the returned stream carries bare successful values, ready for the next stage (this is what keeps a new implementation consumable by `ingest/4`). `Books.Pipeline.parse/1` is a second exception: bare `{ParsedBook.t(), [Chunk.t()]}` on success, raise on failure — `parse_all_binaries/3` rescues the exception into the per-item error tuple, and any returned value (an `{:error, _}` included) is wrapped `{:ok, _}` as success, so never signal failure from it by return value. Declarative callbacks return bare values by design (`format/0`, `success_message/*`).
- Every stream step records its per-item failures to `FailedIngest` under a descriptive step name, through `Pipelines.detuple_with_logging/3` (the default, for a stream of result tuples) or `Pipelines.log_and_persist_failure/3` (for a step that handles each item's outcome itself, as the Books embed stage does under `"books.embed"`) — never a silent stream filter that drops `{:error, _}` without persisting it.
- Step names follow `"pipeline.step"` (e.g. `"books.parse"`, `"docs.embed"`).
- Pipeline-fatal errors go in the `else` branch of the `with` chain in the behaviour's `ingest` function, routed through `Pipelines.handle_ingest_error/2`. The chain must include at least one eager, run-level fallible step returning `{:ok, _}` or `{:error, step, reason}` (`Documents.Pipeline`: `download/1`; `Books.Pipeline`: `validate_paths/1`). Stream stages always return `{:ok, stream}`, so a chain made only of them never reaches `else`. See "Pipeline-Fatal Steps and the `with` Chain" in `docs/architecture/ingestion.md`.
- Schemas `use Cake.Schema` (not `Ecto.Schema`) and call `sanitize_text_fields/1` in changesets with string fields.
- UUIDs are binary, not string.

## New GDS

Consult "Cardinality" in the README and "Adding a New GDS" in `docs/architecture/ingestion.md` first. Then read `lib/cake/gds.ex`, `lib/cake/promptable.ex` and `lib/cake/citable.ex`, one existing GDS as the reference (`lib/cake/books/parsed_book.ex` or `lib/cake/documents/parsed_document.ex`), and `design-anti-patterns.md`. The same reading applies when you implement `Cake.GDS`, `Cake.Promptable` or `Cake.Citable` for an existing module. Checklist: design schemas, declare `use Cake.GDS`, implement `Cake.Promptable` and `Cake.Citable`, design a pipeline behaviour, register the collection in `config :cake, :search_collections` (the mapping is derived from the retrieval-unit schema; nobody writes one), thread the GDS through `Cake.Conversation`.

## New decomposition strategy

Consult "Query Decomposition" in `docs/architecture/conversation.md` first. Then read `lib/cake/decomposition.ex` (the behaviour) and `lib/cake/decomposition/result.ex` (what a strategy returns); `lib/cake/decomposition/llm.ex` is the reference implementation. The same reading applies to any change to `Cake.Decomposition`. All three files are listed in `@cake_sources` in `lawspec/mix.exs`, so the LawSpec row of CLAUDE.md's trigger table applies too.

## New behaviour

- Define callbacks with `@callback` and full typespecs.
- Every callback has `@doc`.
- Add the behaviour to "Behaviours and Implementations" in `docs/architecture/inventories.md`.
- Create at least one implementation. If the behaviour replaces a hardcoded module, the existing code becomes the first implementation.

## New protocol

- Define with `@doc` on each function.
- Implement for at least one struct.
- Add the protocol and its implementations to "Protocols and Implementations" in `docs/architecture/inventories.md`.

## New Ecto schema

- `use Cake.Schema` (not `Ecto.Schema`).
- Call `sanitize_text_fields/1` in every changeset with string fields.
- UUIDs are binary.
- Define `@type t :: %__MODULE__{}` with all fields spelled out.
- Add a `*_fixture/1` helper to the matching `test/support/fixtures/<context>_fixtures.ex` (Phoenix-style; inserts through the context).
- Add the schema to "Custom Structs" in `docs/architecture/inventories.md`.

## New custom struct (non-Ecto)

- Define `@type t :: %__MODULE__{}` with all fields spelled out.
- Add a factory to `Cake.Factory` (`test/support/factory.ex`); build it with `build/1`.
- Add the struct to "Custom Structs" in `docs/architecture/inventories.md`.
