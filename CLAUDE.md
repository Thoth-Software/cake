<!--
CLAUDE.md — Operational Contract for Cake
Maintainer metadata (block HTML comments are stripped before injection; cost zero context):
  created 2026-04-15 · last reviewed 2026-04-23 [jasper] · last verified 2026-06-19
  Certified accurate by Claude 2026-06-19.
Refactored 2026-07-12: task-specific policy moved out of this file to
  priv/reference/creating-things.md (trigger-loaded) and
  .claude/rules/test-conventions.md (path-scoped, auto-loads under test/).
  This file now holds only universal, always-on rules.
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

Work under `test/` auto-loads `.claude/rules/test-conventions.md` (path-scoped) — no manual trigger needed.

---

## Quality Gates

Run in this order. Every gate must pass before presenting changes.

```bash
mix compile --warnings-as-errors --force  # Zero warnings. Hard gate.
mix credo --strict                         # Zero issues. No inline disables without approval.
mix test                                   # Zero failures, zero warnings.
mix coveralls.json                         # Must not reduce coverage below minimum (coveralls.json is the SSOT for the threshold).
```

`mix quality.fast` (compile + credo) is the minimum local check. `mix quality` adds dialyzer. Tests run with `MIX_ENV=test`; the test alias runs `ecto.create --quiet` and `ecto.migrate --quiet` first.

Dialyzer is not a push gate. In CI it runs only on PRs — the `dialyzer` job in `.github/workflows/quality.yml` is guarded by `if: github.event_name == 'pull_request'` — making it a hard *merge* gate, not a push gate.

### Pre-push (matches the on-push CI gate)
```bash
mix compile --force --warnings-as-errors && mix test --exclude integration && mix credo --strict && mix format --check-formatted
```
Tests tagged `:integration` (OpenSearch, external HTTP, or the Rustler NIF) are excluded on-push and run separately as a merge gate via `mix test --only integration`.

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
- **Result tuples:** all pipeline callbacks return `{:ok, _}`/`{:error, _}`. Stream steps use `Pipelines.detuple_with_logging/3` — never a silent filter that discards errors without persisting them. Step names follow `"pipeline.step"`. Pipeline-fatal errors go in the `else` of the `with` chain.

---

## README Update Protocol

After any task that changes architecture, module boundaries, conventions, or tooling:
1. Review this file and README.md for now-stale sections.
2. Propose specific edits: "I changed X → section Y should update; here's the diff."
3. Make approved edits before closing.
4. Unsure whether a change warrants a doc update? Ask.

**Enumeration rule:** if the README lists things (behaviours, protocols, structs, implementations, pipeline implementations) and you create a new instance of that kind, add it to the list.

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
