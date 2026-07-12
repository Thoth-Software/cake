# Creating New Things — Policies

Load when creating a new GDS, ingestion pipeline, behaviour, protocol, Ecto schema, or non-Ecto struct.

When asked to create new functionality, first reason about whether it is testable. If so, write the tests first, ensure they fail, then STOP. If the user approves, write the code that makes them pass. Do unit tests this way as a matter of course. If the functionality requires integration testing, stop and ask the user what to do. Always favor property tests where possible: while reasoning about testability, consider what properties each function ought to have and whether a property test can cover them; if so, prefer property tests over ordinary tests.

## New ingestion pipeline (for an existing GDS)

Consult README "Adding a New Ingestion Pipeline" and "Requirements for All Pipeline Implementations" first. Short version:

- Implement the behaviour for the target GDS (`Cake.Books.Pipeline` or `Cake.Documents.Pipeline`).
- All callbacks return `{:ok, _}` or `{:error, _}`.
- Use `Pipelines.detuple_with_logging/3` with a descriptive step name — never a silent stream filter that drops `{:error, _}` without persisting it.
- Step names follow `"pipeline.step"` (e.g. `"books.parse"`, `"docs.embed"`).
- Pipeline-fatal errors go in the `else` branch of the `with` chain in the behaviour's `ingest` function.
- Schemas `use Cake.Schema` (not `Ecto.Schema`) and call `sanitize_text_fields/1` in changesets with string fields.
- UUIDs are binary, not string.

## New GDS

Consult README "Adding a New GDS" first. Checklist: design schemas, declare `use Cake.GDS`, implement `Cake.Promptable` and `Cake.Citable`, design a pipeline behaviour, create an OpenSearch index mapping, thread the GDS through `Cake.Conversation`.

## New behaviour

- Define callbacks with `@callback` and full typespecs.
- Every callback has `@doc`.
- Add the behaviour to README "Behaviours and Implementations".
- Create at least one implementation. If the behaviour replaces a hardcoded module, the existing code becomes the first implementation.

## New protocol

- Define with `@doc` on each function.
- Implement for at least one struct.
- Add the protocol and its implementations to README "Protocols and Implementations".

## New Ecto schema

- `use Cake.Schema` (not `Ecto.Schema`).
- Call `sanitize_text_fields/1` in every changeset with string fields.
- UUIDs are binary.
- Define `@type t :: %__MODULE__{}` with all fields spelled out.
- Add a `*_fixture/1` helper to the matching `test/support/fixtures/<context>_fixtures.ex` (Phoenix-style; inserts through the context).
- Add the schema to README "Custom Structs".

## New custom struct (non-Ecto)

- Define `@type t :: %__MODULE__{}` with all fields spelled out.
- Add a factory to `Cake.Factory` (`test/support/factory.ex`); build it with `build/1`.
- Add the struct to README "Custom Structs".

