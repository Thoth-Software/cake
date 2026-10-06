<!--
CLAUDE.md — Operational Contract for Cake
Maintainer metadata (block HTML comments are stripped before injection; cost zero context):
  created 2026-04-15 · last reviewed 2026-04-23 [jasper] · last verified 2026-09-15
  Certified accurate by Claude 2026-06-19; re-audited against code 2026-09-15 (#256).
Refactored 2026-07-12: task-specific policy moved out of this file to
  priv/reference/creating-things.md (trigger-loaded) and
  .claude/rules/test-conventions.md (path-scoped, auto-loads under test/).
  This file now holds only universal, always-on rules.
2026-09-15 (#256): creating-things.md had gone missing from priv/reference/;
  restored same day (content re-reviewed against code — result-tuple bullet
  aligned with the corrected rule below) and the trigger row points at it again.
-->

# CLAUDE.md — Operational Contract for Cake

This file governs how you work on Cake. The README describes what things are and why; this file tells you what you must do. Read both before making changes. If this file contradicts what you infer from the code, **this file wins** — flag the discrepancy rather than silently following the code.

For architecture, module responsibilities, schemas, domain model, cardinality, behaviours, protocols, and the RAG loop, read the README. Don't duplicate that here — reference it.

---

## Context Loading

### Always load before any task
- `README.md` — architecture reference. Understand the domain model and module boundaries before touching code.
- `priv/reference/naming-conventions.md` — for any task involving naming (modules, functions, variables, atoms).
- `priv/reference/enum-cheat.cheatmd` — before writing any collection transformation. If about to write explicit recursion over a list, check this first.

### Load by trigger
Load the full file when the task matches the trigger. Reference files live in `priv/reference/`.

| When you're about to... | Load |
|---|---|
| Refactor function bodies, change pattern matching, modify string/list/map logic, add params, change arity, modify exception handling, introduce boolean/flag params | `code-anti-patterns.md` + `patterns-and-guards.md` + `docs-tests-and-with.md` |
| Create/rename/move modules, restructure dirs, define new public APIs/behaviours, add/change structs/schemas, introduce deps, change call graphs, add config | `design-anti-patterns.md` + `config-and-distribution.md` |
| Write/modify macros, `use`, `quote`/`unquote`, DSLs, compile-time codegen | `macro-anti-patterns.md` + `macros.md` |
| Create/modify/supervise GenServers/Agents/Tasks, modify supervision tree, use spawn/Task.async, work with Registry/PubSub/message passing | `process-anti-patterns.md` + `genservers.md` + `supervisor-and-application.md` + `task-and-gen-tcp.md` (+ `dynamic-supervisor.md` if dynamic spawning) |
| Write/modify `@type`/`@spec`, address type warnings, design data types | `gradual-set-theoretic-types.md` + `typespecs.md` |
| Write/modify public API for external use, design behaviours for third-party use | `library-guidelines.md` |
| Create or modify a GDS, ingestion pipeline, behaviour, protocol, Ecto schema, or non-Ecto struct | `priv/reference/creating-things.md` |
| Add/modify a GDS, or implement `Cake.GDS`/`Cake.Promptable`/`Cake.Citable` | README "Cardinality" + "Adding a New GDS"; `lib/cake/gds.ex` + `promptable.ex` + `citable.ex`; one existing GDS impl (`ParsedBook` or `ParsedDocument`) as reference; `design-anti-patterns.md` |
| Add/modify a decomposition strategy, or touch `Cake.Decomposition` | README "Query Decomposition"; `lib/cake/decomposition.ex` + `decomposition/result.ex`; `decomposition/llm.ex` as reference implementation |
| Add a `Cake.Search.Backend` implementation, or change `Backend.OpenSearch` / `Search.Deployment` | README "Search Design"; `test/support/backend_conformance.ex` (instantiate it for the new backend) + `test/support/search_integration_case.ex`; run `mix test --only integration` (see `.claude/rules/integration-tests.md`) |
| Change what `Books.Pipeline.ingest/4` / `Documents.Pipeline.ingest/4` / `ingest_with_sweep/5` persist, embed, index or report, or add an end-to-end ingestion test | `.claude/rules/integration-tests.md`; `test/support/ingest_integration_helpers.ex`; the existing `*_integration_test.exs` for the pipeline as reference; run `mix test --only integration --include network` against a real node (the `:network` group clones elixir-lang/elixir) |
| Change `Cake.Books.Adapters.S3`, ExAws config, or `Cake.S3IntegrationCase`; add a `Cake.Books.Adapters` implementation | `lib/cake/books/adapters.ex` + `adapters/s3.ex` (the "Authentication" and "Errors" sections); `test/support/s3_integration_case.ex`; `test/cake/books/adapters/s3_integration_test.exs` as reference; run `mix test --only integration` (see `.claude/rules/integration-tests.md`) |
| Add/modify a live-provider test (`:llm`), touch `Cake.LiveLLMCase`, or change what `Cake.Embeddings` / `Cake.Generation.OpenAI` / `Cake.Decomposition.LLM` send over the wire | `.claude/rules/live-llm-tests.md`; `test/support/live_llm_case.ex`; the existing `*_live_test.exs` for the module as reference; run `OPENAI_KEY=... mix test --only llm` |
| Add/modify an end-to-end `Cake.Conversation` test (tier 1 `:integration` or tier 2 `:llm`), or touch `Cake.ConversationIntegrationHelpers` | `.claude/rules/integration-tests.md` + `.claude/rules/live-llm-tests.md`; `test/support/conversation_integration_helpers.ex`; README "The Per-Turn Pipeline"; `test/cake/conversation_integration_test.exs` as reference; run `mix test --only integration` (and `OPENAI_KEY=... mix test --only llm` for the live tier) |

Path-scoped rules in `.claude/rules/` auto-load when you work on a file their `paths:` frontmatter matches — no manual trigger needed: `test-conventions.md` (anything under `test/`), `integration-tests.md`, `live-llm-tests.md`, `compose-smoke.md`, `infrastructure-gotchas.md` and `security-gate.md`. The rows above that name one of them are for loading it before you have opened a matching file.

---

## Quality Gates

Run `mix precommit` before every push. It is a Mix task (`lib/mix/tasks/precommit.ex`, not an alias) that runs the pre-push chain one child `mix` process per step with `MIX_ENV` set explicitly, stops at the first failing step, and exits non-zero — so it works the same whatever `MIX_ENV` you invoke it under:

```bash
mix precommit  # MIX_ENV=dev: compile --force --warnings-as-errors → format --check-formatted → credo --strict; then MIX_ENV=test: test --exclude integration
```

The compile, format and credo steps run in the dev env (so `--warnings-as-errors` enforces `boundary`); the test step runs in the test env. Every gate must pass before presenting changes: zero warnings, zero credo issues (no inline disables without approval), zero test failures. Two lighter aliases exist for iteration: `mix quality.fast` (compile + credo + `deps.unlock --check-unused`, never touches the database) and `mix quality` (the same plus dialyzer). The test step expects the Postgres role `postgres` to have the password `postgres` (config/{dev,test}.exs); the test alias runs `ecto.create --quiet` and `ecto.migrate --quiet` first, and in Claude Code on the web the session-start hook sets that password and prints `!! postgres:` if it could not.

On-push CI (`.github/workflows/quality.yml`) runs the same checks **plus** gates with no local alias, so run them yourself when a change is likely to trip one:

- `mix docs --warnings-as-errors` — the documentation gate (#204): zero broken `@moduledoc`/`@doc` references; runs in the dev env.
- `mix xref graph --label compile-connected --fail-above 3` — the compile-coupling ratchet (baseline 3; see #208).
- `mix dialyzer` — the `dialyzer` job runs on every push to master and every PR targeting master, with no event guard (PLT caching makes repeat runs cheap); run `mix quality` before pushing spec-heavy changes rather than waiting for it.
- `mix coveralls.json --exclude integration` — coverage must not drop below the minimum in `coveralls.json` (the SSOT for the threshold).
- The `security` job: `mix deps.unlock --check-unused`, `mix hex.audit` + `mix deps.audit` (report-only until #206 clears) and `mix sobelow --config --exit` (`.claude/rules/security-gate.md`).

Tests tagged `:integration`, `:network` and `:llm` are excluded on-push and run separately as merge gates (see "Test tags and run modes" below). PRs additionally run the compose smoke test, `ci/compose_smoke.sh`, which gates the containers rather than the code (`.claude/rules/compose-smoke.md`). A failure there is a finding about the containers: fix `Dockerfile`, `entrypoint.sh` or the compose files, never loosen an assertion.

### Test tags and run modes

Test tags split by what a test *needs*, not by how slow it is:

- `:integration` — hermetic infrastructure (OpenSearch, the Rustler NIF, Oban): free and deterministic, so a required merge gate on every PR (the `integration` job; `.claude/rules/integration-tests.md`).
- `:network` — the integration tests that also reach the public internet (the hexdocs clone): the same required merge gate, run by the same job via `--include network`; tagged separately only so a plain local `--only integration` can leave them out.
- `:llm` — real provider calls: secret-bearing (`OPENAI_KEY`), cost-bearing, and rate-limit-flaky. `test_helper.exs` excludes it from every default run alongside `:integration`; only `mix test --only llm` runs it.

```bash
docker compose up -d opensearch moto               # the real node and object store an integration run needs (OPENSEARCH_URL / S3_ENDPOINT_URL override the localhost defaults)
mix test --only integration --include network      # the integration merge gate's command
mix test --only integration                        # the same minus the :network group (no clone) — a local shortcut, not the gate
OPENAI_KEY=... mix test --only llm                 # the live merge gate (its conversation suite needs the OpenSearch node up too)
```

Unit and integration tests cannot share one run (the skip flag and the Deployment config are global): `test_helper.exs` refuses a mixed `--include integration` run with an error pointing at `--only integration`. Never `--only network` or `--include network` alone: without `--only integration` it is a unit-mode run, and the tests refuse it.

A live test asserts shapes and invariants, never generated content; one that stays red after the wiring is in means provider drift or a parsing defect: stop and ask, never loosen the assertion.

The detail behind each gate lives in a path-scoped rule that auto-loads when you touch the files it covers: `.claude/rules/integration-tests.md` (what the `integration` job runs, the case templates, local setup) and `.claude/rules/live-llm-tests.md` (the `llm` job, its fork-PR guard, `Cake.LiveLLMCase`, what each live suite pins).

---

## When to Stop and Ask

Stop and ask before proceeding when:
- **Ambiguous scope** — a task reads multiple ways and the difference changes which modules are touched.
- **Architecture boundary change** — moving a responsibility between modules, adding a module, or changing an existing module's public API. Describe the change and why before doing it.
- **Behaviour/protocol modification** — adding/removing/changing a callback. Existing implementations will need updating.
- **CLAUDE.md/README contradicts code** — this file wins; flag it.
- **Known-defect adjacency** — task touches a known defect or deferred item (see bottom); flag, don't silently resolve.
- **Uncertain doc update** — unsure whether a change warrants a README/CLAUDE.md edit.
- **Credo disable** — no inline `# credo:disable-for-this-file` / `# credo:disable-for-next-line` without explicit approval.
- **Branch management** — do not create new branches or check out other branches. All work happens on the current branch unless the user explicitly directs otherwise.

---

## Testing: Ordering and Failure Handling

Tests are the contract; code satisfies it. (Mechanical conventions — fixtures/factory tracks, the no-`Process.sleep` rule — auto-load via `.claude/rules/test-conventions.md` when you touch `test/`.)

**Ordering — for any behavior change:**
1. **Spec.** User describes the change.
2. **Tests first.** Encode the new contract in tests before touching implementation. If the change is non-trivial, push the test diff for review and STOP for approval.
3. **Human reviews tests** — the tests are the spec.
4. **Implement** against the reviewed tests.
5. **Run gates** (Quality Gates above). Iterate on the *implementation*, not the tests, until green.
6. **Stop and ask** if step 5 keeps failing in ways that suggest the test itself is wrong.

Tests written after implementation encode what the code did, not what it should do. Write them first.

**When `mix test` is red, classify before reacting:**
1. Test asserts behavior the spec says is **correct** → fix the implementation; do not edit the test.
2. Test asserts behavior the spec says **should change** → update the test to the new contract, then the implementation; note the contract change in the PR.
3. **Neither** (test/spec ambiguous, or the failure surfaces a question neither answers) → **stop, ask.** Do NOT paper over it by deleting assertions, broadening matchers, adding `try/rescue`, or `@tag :skip`.

If you're loosening an assertion to make a test pass, you're almost certainly in case 3.

---

## Typespecs, DI, Result Tuples

- **Every public function has a `@spec`.** No exceptions — including `@impl` callback implementations, which must redundantly spec the callback signature. This ensures specs appear in LLM context and that dialyzer catches impl/callback mismatches.
- **Every custom struct defines `@type t :: %__MODULE__{}`** with all fields typed. Use `MyStruct.t()` in specs, never `%MyStruct{}`.
- **Every `@type` has a `@typedoc`**, struct `t/0` included. `@typep` is exempt.
- Behaviour callbacks (`@callback`) and protocol functions (`@spec`) get full typespecs.
- Retrieval callbacks return `[struct()]`, not a specific struct type — deliberate (see GDS behaviour docs in README).
- **List-of-struct args use `when is_list(arg)` guards**, not head-matching on list elements. The `@spec` controls what the list contains; the guard validates the container type at runtime.
- **DI is for Mox, not runtime polymorphism:** modules depending on external services accept collaborator modules as args (or read them from config); define a behaviour, implement it, provide a mock in test. `Cake.Conversation` requires a `:gds` opt validated in `start_link/1`/`start/1` before the GenServer spawns (`init/1` only builds state). Follow the same required-opt pattern for future orchestration-layer modules.
- **Result tuples:** every fallible pipeline operation reports through `{:ok, _}`/`{:error, _}`, with the exceptions, the stream-callback detuple rule and the pipeline-fatal `with` chain spelled out in `priv/reference/creating-things.md` (loaded by the trigger row for creating or modifying a pipeline).

---

## README Update Protocol

After any task that changes architecture, module boundaries, conventions, or tooling:
1. Review this file and README.md for now-stale sections.
2. Propose specific edits: "I changed X → section Y should update; here's the diff."
3. Make approved edits before closing.
4. Unsure whether a change warrants a doc update? Ask.

**Enumeration rule:** if the README lists things (behaviours, protocols, structs, implementations, pipeline implementations) and you create a new instance of that kind, add it to the list. Every new issue cut must include, as its **final checkbox**, a documentation update that applies this rule — in particular, adding any custom structs the work introduces to the README's struct inventory.

---

## Known Defects and Deferred Work

If your task touches these, flag rather than silently resolving or ignoring. One line each; the detail lives in the linked issue.
- **Post-demo formats** (README "Roadmap"): Word, Excel, CSV, JPG pipelines are explicitly deferred.
- **Advisory backlog (#206):** `mix hex.audit` / `mix deps.audit` are report-only in CI until the backlog clears, then flip to blocking.
- **xref coupling ratchet (#208):** `--fail-above 3` baseline comes from `Conversation.State`'s defstruct DI defaults; ratchets to 0 once those are decoupled.
- **Book status after a sweep (#305, found by #248):** `Books.Pipeline.ingest_with_sweep/5` leaves `embedding_status` at `:failed` after `retry_from_chunk` resolves a book's last failing chunk.
- **Hexdocs sources with several top-level forms (#291, found by #248):** `Hexdoc.to_parsed_docs/1` accepts only a bare `defmodule` AST, so `enum.ex`, `kernel.ex`, `string.ex` and the like yield no `ParsedDocument` and no `FailedIngest`.
