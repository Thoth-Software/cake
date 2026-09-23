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
| Refactor function bodies, change pattern matching, modify string/list/map logic, add params, change arity, modify exception handling, introduce boolean/flag params | `code-anti-patterns.md` + `patterns-and-guards.md` |
| Create/rename/move modules, restructure dirs, define new public APIs/behaviours, add/change structs/schemas, introduce deps, change call graphs, add config | `design-anti-patterns.md` |
| Write/modify macros, `use`, `quote`/`unquote`, DSLs, compile-time codegen | `macro-anti-patterns.md` + `macros.md` |
| Create/modify/supervise GenServers/Agents/Tasks, modify supervision tree, use spawn/Task.async, work with Registry/PubSub/message passing | `process-anti-patterns.md` + `genservers.md` + `supervisor-and-application.md` (+ `dynamic-supervisor.md` if dynamic spawning) |
| Write/modify `@type`/`@spec`, address type warnings, design data types | `gradual-set-theoretic-types.md` + `typespecs.md` |
| Write/modify public API for external use, design behaviours for third-party use | `library-guidelines.md` |
| Create a new GDS, ingestion pipeline, behaviour, protocol, Ecto schema, or non-Ecto struct | `priv/reference/creating-things.md` |
| Add/modify a GDS, or implement `Cake.GDS`/`Cake.Promptable`/`Cake.Citable` | README "Cardinality" + "Adding a New GDS"; `lib/cake/gds.ex` + `promptable.ex` + `citable.ex`; one existing GDS impl (`ParsedBook` or `ParsedDocument`) as reference; `design-anti-patterns.md` |
| Add/modify a decomposition strategy, or touch `Cake.Decomposition` | README "Query Decomposition"; `lib/cake/decomposition.ex` + `decomposition/result.ex`; `decomposition/llm.ex` as reference implementation |

Work under `test/` auto-loads `.claude/rules/test-conventions.md` (path-scoped) — no manual trigger needed.

---

## Quality Gates

Run in this order. Every gate must pass before presenting changes.

```bash
mix compile --warnings-as-errors --force  # Zero warnings. Hard gate.
mix credo --strict                         # Zero issues. No inline disables without approval.
mix test                                   # Zero failures, zero warnings.
mix coveralls.json                         # Must not reduce coverage below minimum (coveralls.json is the SSOT for the threshold).
mix docs --warnings-as-errors              # Zero broken @moduledoc/@doc references. Hard gate in CI (runs in the dev env).
```

`mix quality.fast` (compile + credo + `deps.unlock --check-unused`) is the minimum local check; `mix precommit` is the fuller pre-push check (adds format + tests — see Pre-push below). `mix quality` adds dialyzer. Tests run with `MIX_ENV=test`; the test alias runs `ecto.create --quiet` and `ecto.migrate --quiet` first. The test step (`mix test`, and so `mix precommit`) expects the Postgres role `postgres` to have the password `postgres` (config/{dev,test}.exs); `mix quality` and `mix quality.fast` never connect to the database. In Claude Code on the web the session-start hook sets that password and prints `!! postgres:` if it could not.

Dialyzer runs in CI on every push to master and every PR targeting master — the `dialyzer` job in `.github/workflows/quality.yml` carries no event guard (PLT caching makes repeat runs cheap). It has no local pre-push alias, so run `mix quality` before pushing spec-heavy changes rather than waiting for CI.

The `security` job in `.github/workflows/quality.yml` runs the dependency-audit gates: `mix deps.unlock --check-unused` (blocking — no unused lockfile entries) plus `mix hex.audit` and `mix deps.audit` (currently **report-only** while the advisory backlog in #206 is outstanding; they flip to blocking once it's cleared). It also runs `mix sobelow --config --exit` (blocking) — static security analysis of the Phoenix app. Its baseline is clean: triaged false-positives are suppressed in `.sobelow-conf` (`:ignore` for deployment-level Config findings, `:ignore_files` for internal file-I/O modules) and via inline `# sobelow_skip` annotations at request-facing call sites, so the gate fails only on **new** findings. When Sobelow flags new code, fix it or — if it's a verified false-positive — add a justified `# sobelow_skip` (never a blanket ignore).

### Pre-push
```bash
mix precommit  # MIX_ENV=dev: compile --force --warnings-as-errors → format --check-formatted → credo --strict; then MIX_ENV=test: test --exclude integration
```
`mix precommit` is a Mix task (`lib/mix/tasks/precommit.ex`, not an alias) that runs that chain in that order, one child `mix` process per step with `MIX_ENV` set explicitly: the compile, format, and credo steps run in the dev env (so `--warnings-as-errors` enforces `boundary`) and the test step runs in the test env. It stops at the first failing step and exits non-zero. Run it before pushing; it works the same whatever `MIX_ENV` you invoke it under. On-push CI (`quality.yml`) runs the same checks **plus** gates with no local alias: a dev-env compile with `--warnings-as-errors` (enforces `boundary`), the compile-coupling ratchet `mix xref graph --label compile-connected --fail-above 3` (baseline 3; see #208), `mix docs --warnings-as-errors` (the documentation gate, #204), dialyzer, and coverage via `mix coveralls.json --exclude integration` against the `coveralls.json` minimum. Tests tagged `:integration` (OpenSearch, external HTTP, or the Rustler NIF) are excluded on-push and run separately as a merge gate via `mix test --only integration`.

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
5. **Run gates** (pre-push above). Iterate on the *implementation*, not the tests, until green.
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
- Behaviour callbacks (`@callback`) and protocol functions (`@spec`) get full typespecs.
- Retrieval callbacks return `[struct()]`, not a specific struct type — deliberate (see GDS behaviour docs in README).
- **List-of-struct args use `when is_list(arg)` guards**, not head-matching on list elements. The `@spec` controls what the list contains; the guard validates the container type at runtime.
- **DI is for Mox, not runtime polymorphism:** modules depending on external services accept collaborator modules as args (or read them from config); define a behaviour, implement it, provide a mock in test. `Cake.Conversation` requires a `:gds` opt validated in `start_link/1`/`start/1` before the GenServer spawns (`init/1` only builds state). Follow the same required-opt pattern for future orchestration-layer modules.
- **Result tuples:** every fallible pipeline operation reports through `{:ok, _}`/`{:error, _}`. Direct callbacks return them as-is (`retry_from_raw/2`, `Books.Pipeline.load_binary/1`), with one tagged exception: `Documents.Pipeline.download/1` returns `{:error, :download, reason}` (three elements) so the orchestrator can attribute the failure to the download step. Inside a stream callback (`persist_raw_docs/2`, `parse/2`), fallible per-item work produces result tuples that the callback itself must pass through `Pipelines.detuple_with_logging/3` — persisting failures to `FailedIngest`, never a silent filter — *before* returning: the `Enumerable.t()` a stream callback returns carries bare successful values, ready for the next stage. `Books.Pipeline.parse/1` is a second exception: it returns a bare `{ParsedBook.t(), [Chunk.t()]}` on success and **raises** on failure — `parse_all_binaries/3` rescues the exception into the per-item error tuple, and every returned value (an `{:error, _}` included) is wrapped `{:ok, _}` as success, so never signal failure by return value there. Declarative callbacks return bare values by design (`format/0`, `source/0`, `success_message/*`). Step names follow `"pipeline.step"`. Pipeline-fatal errors go in the `else` of the `with` chain, routed through `Pipelines.handle_ingest_error/2`. That chain must include an eager, run-level fallible step (`Documents.Pipeline`: `download/1`; `Books.Pipeline`: `validate_paths/1`), because stream stages always return `{:ok, stream}` and can't reach `else` (README "Pipeline-Fatal Steps and the `with` Chain").

---

## README Update Protocol

After any task that changes architecture, module boundaries, conventions, or tooling:
1. Review this file and README.md for now-stale sections.
2. Propose specific edits: "I changed X → section Y should update; here's the diff."
3. Make approved edits before closing.
4. Unsure whether a change warrants a doc update? Ask.

**Enumeration rule:** if the README lists things (behaviours, protocols, structs, implementations, pipeline implementations) and you create a new instance of that kind, add it to the list. Every new issue cut must include, as its **final checkbox**, a documentation update that applies this rule — in particular, adding any custom structs the work introduces to the README's struct inventory.

---

## Infrastructure Gotchas

Dev runs three containers via `docker-compose.yml`: `cake_app`, `cake_db` (Postgres 14), `cake_opensearch`.

- **NIF clobbering.** The `.:/app` bind mount overlays macOS binaries onto the Linux container. `entrypoint.sh` forces recompilation in sequence: `rm -f priv/native/*.so` → `mix deps.compile --force bcrypt_elixir` → `mix compile --force`. Diagnostic for this failure: "module not available" — not `:nif_not_loaded`.
- **Colima FD limits.** Default 1024 is too low for concurrent `Task.async_stream` fan-out. Raise via provision script.
- **Colima port forwarder leak.** `limactl` accumulates CLOSED socket FDs. Fix: `colima start --network-address`.
- **Colima port forwarder saturation.** `portForwarder: ssh` saturates under burst traffic. Use `grpc`.
- **Bind mount hot paths.** Heavy virtiofs I/O through the mount is slow. Copy to `/tmp` inside the container on hot paths.

---

## Known Defects and Deferred Work

If your task touches these, flag rather than silently resolving or ignoring.
- **Post-demo formats:** Word, Excel, CSV, JPG pipelines are explicitly deferred.
- **Vestigial contracts (#259):** `Documents.Pipeline.source/0` has no call sites; `Cake.Responses` declares an unused Boundary dep on `Cake.Generation`.
- **Advisory backlog (#206):** `mix hex.audit` / `mix deps.audit` are report-only in CI until the backlog clears, then flip to blocking.
- **xref coupling ratchet (#208):** `--fail-above 3` baseline comes from `Conversation.State`'s defstruct DI defaults; ratchets to 0 once those are decoupled.
