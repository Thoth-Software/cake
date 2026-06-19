---
title: "CLAUDE.md — Operational Contract for AI Sessions on Cake"
tags: [claude-code, ai-instructions, conventions, quality-gates]
date: 2026-04-15
domain: development, ai-workflow
source: project-maintainer
last_verified: 2026-04-15
last_reviewed: 2026-04-23 [jasper]
---

# CLAUDE.md — Operational Contract for Cake

This file governs how you work on Cake. The README describes what things are and why; this file tells you what you must do. Read both before making changes. If this file contradicts what you infer from the code, **this file wins** — flag the discrepancy to the user rather than silently following the code.

For architecture, module responsibilities, data schemas, domain model, cardinality mappings, behaviours, protocols, and the RAG loop, read the README. Do not duplicate that understanding here — reference it.

*Certified accurate by caleb-bb on 2026-04-16*

---

## Context Loading: What to Read and When

### Always load before any task

Read these files in full before making any changes:

- `README.md` — the architecture reference. Understand the domain model and module boundaries before touching code.
- `priv/reference/naming-conventions.md` — at the start of any task involving naming (modules, functions, variables, atoms).
- `priv/reference/enum-cheat.cheatmd` — before writing any collection transformation. If you're about to write explicit recursion over a list, check this first.

### Load by trigger

These reference files in `priv/reference/` should be loaded when the task matches the trigger condition. Load the full file before proceeding.

| When you're about to... | Load these |
|---|---|
| Refactor function bodies, change pattern matching, modify string/list/map logic, add parameters, change arity, modify exception handling, introduce boolean/flag params | `code-anti-patterns.md` + `patterns-and-guards.md` |
| Create/rename/move modules, restructure directories, define new public APIs or behaviours, add/change structs or schemas, introduce dependencies, change module call graphs, add config | `design-anti-patterns.md` |
| Write/modify macros, `use` declarations, `quote`/`unquote`, DSLs, compile-time code generation | `macro-anti-patterns.md` + `macros.md` |
| Create/modify/supervise GenServers/Agents/Tasks, modify supervision tree, use spawn/Task.async, work with Registry/PubSub/message passing | `process-anti-patterns.md` + `genservers.md` + `supervisor-and-application.md` (add `dynamic-supervisor.md` if dynamic spawning) |
| Write/modify `@type`, `@spec`, address type warnings, design data types | `gradual-set-theoretic-types.md` + `typespecs.md` |
| Write/modify public API for external consumption, design behaviours for third-party use | `library-guidelines.md` |
| Add a new GDS, modify an existing GDS's contract, or implement `Cake.GDS` / `Cake.Promptable` / `Cake.Citable` on a schema or struct | README's "Cardinality" + "Adding a New GDS" sections; `lib/cake/gds.ex` + `lib/cake/promptable.ex` + `lib/cake/citable.ex`; one existing GDS impl (`ParsedBook` or `ParsedDocument`) as reference; `design-anti-patterns.md` |

*Certified accurate by caleb-bb on 2026-04-16*

---

## Quality Gates: When to Run and What Must Pass

Run in this order. Every gate must pass before presenting changes.

```bash
mix compile --warnings-as-errors --force  # Zero warnings. Hard gate.
mix credo --strict                         # Zero issues. No inline disables without approval.
mix test                                   # Zero failures, zero warnings.
mix coveralls.json                         # Must not reduce coverage below threshold.
```

`mix quality.fast` (compile + credo) is the minimum local check. `mix quality` adds dialyzer. Tests run with `MIX_ENV=test`; the test alias runs `ecto.create --quiet` and `ecto.migrate --quiet` first.

Dialyzer is not a push gate. In CI it runs only on pull requests — the `dialyzer` job in `.github/workflows/quality.yml` is guarded by `if: github.event_name == 'pull_request'` — which makes it a hard *merge* gate rather than a push gate.

### Pre-push command

Use this single chain locally before pushing — it matches the on-push CI gate:

```bash
mix compile --warnings-as-errors && mix test --exclude integration && mix credo --strict && mix format --check-formatted
```

Tests tagged `:integration` (those requiring OpenSearch, external HTTP, or the Rustler NIF) are excluded from the on-push gate and run separately as a merge gate via `mix test --only integration`.

---

## When to Stop and Ask the User

Stop work and ask before proceeding in any of these situations:

- **Ambiguous scope.** If a task could be interpreted multiple ways and the difference affects which modules are touched, ask which interpretation is intended.
- **Architecture boundary change.** If you need to move a responsibility from one module to another, add a new module, or change the public API of an existing module, describe what you'd change and why before doing it.
- **Behaviour or protocol modification.** If you need to add, remove, or change a callback on an existing behaviour or protocol, flag it. Existing implementations will need updating.
- **CLAUDE.md or README contradicts code.** This file wins. Flag the discrepancy rather than silently following the code.
- **Known defect adjacency.** If your task touches a known defect or deferred work item (listed below), flag it rather than silently resolving or ignoring it.
- **Uncertain doc update.** If you're unsure whether a change warrants a README or CLAUDE.md update, ask.
- **Credo disable request.** No inline `# credo:disable-for-this-file` or `# credo:disable-for-next-line` without explicit user approval.

---

## Policies for Creating New Things

### New ingestion pipeline (for an existing GDS)

Consult the README sections "Adding a New Ingestion Pipeline" and "Requirements for All Pipeline Implementations" before starting. The short version:

- Implement the behaviour for the target GDS (`Cake.Books.Pipeline` or `Cake.Documents.Pipeline`).
- All callbacks return `{:ok, _}` or `{:error, _}`.
- Use `Pipelines.detuple_with_logging/3` with a descriptive step name — never the silent `detuple/1`.
- Step names follow `"pipeline.step"` convention (e.g., `"books.parse"`, `"docs.embed"`).
- Pipeline-fatal errors go in the `else` branch of the `with` chain in the behaviour's `ingest` function.
- Schemas must `use Cake.Schema` (not `Ecto.Schema`) and call `sanitize_text_fields/1` in changesets with string fields.
- UUIDs are binary, not string.

### New GDS

Consult the README section "Adding a New GDS" before starting. The checklist includes designing schemas, declaring `use Cake.GDS`, implementing `Cake.Promptable` and `Cake.Citable`, designing a pipeline behaviour, creating an OpenSearch index mapping, and threading the GDS through `Cake.Conversation`.

### New behaviour

- Define callbacks with `@callback` and full typespecs.
- Every callback must have `@doc`.
- Add the behaviour to the README's "Behaviours and Implementations" section.
- Create at least one implementation. If the behaviour replaces a hardcoded module, the existing code becomes the first implementation.

### New protocol

- Define with `@doc` on each function.
- Implement for at least one struct.
- Add the protocol and its implementations to the README's "Protocols and Implementations" section.

### New Ecto schema

- `use Cake.Schema` (not `Ecto.Schema`).
- Call `sanitize_text_fields/1` in every changeset with string fields.
- UUIDs are binary.
- Define a `@type t :: %__MODULE__{}` with all fields spelled out.
- Add a factory in `test/support/factory.ex` (Ecto-backed: `insert/1`; non-Ecto: `build/1`).
- Add the schema to the README's "Custom Structs" section.

### New custom struct (non-Ecto)

- Define a `@type t :: %__MODULE__{}` with all fields spelled out.
- Add a factory via `build/1` in `test/support/factory.ex`.
- Add the struct to the README's "Custom Structs" section.

*Certified accurate by caleb-bb on 2026-04-16*

---

## Typespec Policies

- **Every public function must have a `@spec`.** No exceptions.
- **Every custom struct must define `@type t :: %__MODULE__{}`** with all fields and their types explicitly listed. This type must be used wherever the struct appears in any typespec — never use `%MyStruct{}` in a spec, always `MyStruct.t()`.
- **Behaviour callbacks must have full typespecs** via `@callback`.
- **Protocol functions must have full typespecs** via `@spec` in the protocol definition.
- **Retrieval callbacks return `[struct()]`**, not a specific struct type. This is deliberate — see the GDS behaviour documentation in the README.

---

## Dependency Injection Conventions

Modules that depend on external services accept collaborator modules as arguments — for Mox testability, not runtime polymorphism. When adding new external-service dependencies, follow this pattern: define a behaviour, implement it, pass the module as an argument or read it from config. In the testing environment, a mock should be available.

`Cake.Conversation` requires a `:gds` opt (a `Cake.GDS` module) that threads through to `Cake.Search.OpenSearch`. Required, not defaulted — `init/1` validates before spawn. Follow the same required-opt pattern for any future orchestration-layer module that dispatches across GDSes.

---

## Result Tuples and Pipeline Error Handling

All pipeline callbacks return `{:ok, _}` or `{:error, _}`. Stream steps use `Pipelines.detuple_with_logging/3` — never the silent `detuple/1`. Step names follow `"pipeline.step"` convention. Pipeline-fatal errors go in the `else` branch of the `with` chain in each behaviour's `ingest` function.

*Certified accurate by caleb-bb on 2026-04-16*

---

## Test Conventions

- Use `Cake.Factory` (ExMachina) for test data, imported via `DataCase`, `ConnCase`, or `ObanCase`.
- Ecto-backed factories use `insert/1`; non-Ecto domain objects use `build/1`.
- New domain structs need a corresponding factory.
- Property tests (StreamData) go in `*_property_test.exs`. When fixing a bug found by a property test, add a corresponding example test in the standard file.
- Mox expectations go in individual tests, not setup blocks.
- `test_helper.exs` sets `Application.put_env(:cake, :skip_opensearch, true)`. Tests that need search behavior mock the cluster via Mox or a test module.

---

## Test-Code Ordering

Tests are the contract; code satisfies it. For any task that changes behavior:

1. **Spec.** The user describes what the change should do.
2. **Tests first.** Write or update tests to encode the new contract before touching implementation. Push the test diff for human review at this point if the change is non-trivial.
3. **Human reviews tests.** The tests are the spec; the human confirms they encode the intended behavior.
4. **Implement.** Write the implementation against the reviewed tests.
5. **Run gates.** Run the pre-push command above. Iterate on the implementation — not the tests — until the suite is green.
6. **Stop and ask** if step 5 keeps failing in ways that suggest the test itself is wrong; see the next section.

Tests written *after* the implementation tend to encode whatever the code happened to do, not what it should do. Write them first.

---

## When Tests Fail After Your Changes

When `mix test` is red, classify the failure before reacting:

1. **The test asserts on behavior the spec says is correct.** Fix the implementation. Do not edit the test.
2. **The test asserts on behavior the spec says should change.** Update the test to match the new contract, then update the implementation. Mention the test change in the PR description so a reviewer can sign off on the contract change.
3. **Neither — the test or spec is ambiguous, or the failure surfaces a question neither answers.** Stop. Ask the user. Do not paper over the failure by deleting assertions, broadening matchers, adding `try/rescue`, or marking tests `@tag :skip`.

If you find yourself loosening an assertion to make a test pass, you are almost certainly in case 3.

---

## README Update Protocol

After completing any task that changes architecture, module boundaries, conventions, or tooling:

1. Review both this file and README.md for sections that are now stale.
2. Propose specific edits: "I changed X, which means section Y should be updated. Here's what I'd change: [diff]."
3. Make approved edits before closing the task.
4. If unsure whether a change warrants a doc update, ask.

**The enumeration rule:** If the README contains a list of things (behaviours, protocols, structs, implementations, pipeline implementations, etc.) and you create a new instance of that kind of thing, add it to the list. For example: if you create a new behaviour, add it to the "Behaviours and Implementations" section. If you implement a protocol for a new struct, add the implementation to the "Protocols and Implementations" section. If you create a new schema, add it to the "Custom Structs" section.

*Certified accurate by caleb-bb on 2026-04-16*

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

- **`Conversation.start_link/6` positional args**: Should eventually accept a struct.
- **Post-demo formats**: Word, Excel, CSV, JPG pipelines are explicitly deferred.
- **`Responses` hardcoded to `Chunk`**: Generalizing post-processing beyond `Cake.Books.Chunk` to work with any GDS's atomic unit is a known TODO.
- **`search_fields/0` behaviour extraction**: TODO to extract into a behaviour on the pipeline generics so each GDS declares its searchable fields.
