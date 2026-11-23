<!--
CLAUDE.md — Operational Contract for Cake
Maintainer metadata (block HTML comments are stripped before injection; cost zero context):
  created 2026-04-15 · last reviewed 2026-04-23 [jasper] · last verified 2026-11-23
  Certified accurate by Claude 2026-06-19; re-audited against code 2026-09-15 (#256)
  and 2026-11-23 (the documentation sweep, #417).
Refactored 2026-07-12: task-specific policy moved out of this file to
  priv/reference/creating-things.md (trigger-loaded) and
  .claude/rules/test-conventions.md (path-scoped, auto-loads under test/).
  This file now holds only universal, always-on rules.
2026-09-15 (#256): creating-things.md had gone missing from priv/reference/;
  restored same day (content re-reviewed against code — result-tuple bullet
  aligned with the corrected rule below) and the trigger row points at it again.
Trimmed 2026-11-23 (#422): statements made more than once now have one home;
  the CI gates are a table; the toolchain and Postgres detail moved to
  .claude/rules/infrastructure-gotchas.md; trigger rows that duplicated a rule's
  paths: were retired; the README was split, and each file under
  docs/architecture/ has a trigger row.
-->

# CLAUDE.md — Operational Contract for Cake

This file says what you must do when you work on Cake; the README says what things are and why (reference it, don't restate it here). If this file contradicts what you infer from the code, **this file wins**: flag the discrepancy rather than silently following the code.

---

## Context Loading

**Always load:** `README.md` (the domain model, the layers and which way they depend), `priv/reference/naming-conventions.md`, and `priv/reference/enum-cheat.cheatmd` (before any collection transformation or explicit recursion over a list).

**Load by trigger.** Files are in `priv/reference/` unless a path is given.

| When you're about to... | Load |
|---|---|
| Work on a GDS, a pipeline, `FailedIngest`, the sweep, a storage adapter or an ingestion job | `docs/architecture/ingestion.md` |
| Work on `Cake.Search`, a backend, the deployment or embeddings | `docs/architecture/search.md` |
| Work on `Conversation`, `Prompt`, `Generation`, `Responses`, `Citations` or `Decomposition` | `docs/architecture/conversation.md` |
| Work on `CakeWeb`, `Cake.Accounts`, `Cake.Candidates` or `assets/` | `docs/architecture/web.md` |
| Create, rename or remove a module, struct, behaviour, protocol, boundary dep or config key | `docs/architecture/inventories.md` |
| Work on a Dockerfile, `rel/`, `entrypoint.sh` or `Cake.Release` | `docs/architecture/deployment.md` |
| Give someone a login, or create the first admin | `docs/runbooks/first-admin.md` |
| Refactor function bodies; change pattern matching, string/list/map logic, params, arity or exception handling; add a boolean/flag param | `code-anti-patterns.md` + `patterns-and-guards.md` + `docs-tests-and-with.md` |
| Create/rename/move modules or directories; define public APIs or behaviours; add/change structs or schemas; add deps or config; change call graphs | `design-anti-patterns.md` + `config-and-distribution.md` |
| Add or restyle a screen, component or layout; move daisyUI, heroicons, Tailwind or esbuild | `.claude/rules/front-end.md`; then build the assets and look at the page in both themes and at phone width, because the suite cannot see a style; `docs/demo-script.md` when the change alters a step of the demo |
| Write/modify macros, `use`, `quote`/`unquote`, DSLs, compile-time codegen | `macro-anti-patterns.md` + `macros.md` |
| Work on GenServers/Agents/Tasks or `spawn`, the supervision tree, Registry/PubSub or message passing | `process-anti-patterns.md` + `genservers.md` + `supervisor-and-application.md` + `task-and-gen-tcp.md` (+ `dynamic-supervisor.md` for dynamic spawning) |
| Write/modify `@type`/`@spec`, address type warnings, design data types | `gradual-set-theoretic-types.md` + `typespecs.md` |
| Write/modify an API or behaviour for third-party use | `library-guidelines.md` |
| Create or modify a GDS (or implement `Cake.GDS`, `Cake.Promptable` or `Cake.Citable`), an ingestion pipeline, a decomposition strategy (or `Cake.Decomposition`), a behaviour, protocol, Ecto schema or struct | `creating-things.md` |
| Change a module listed in `@cake_sources` in `lawspec/mix.exs`, or add a LawSpec specification | `lawspec/README.md`; update the module's `.lawspec` file first, as with any test, regenerate, and run the `laws` job's steps |

The rules in `.claude/rules/` load themselves when you open a file their `paths:` frontmatter matches: `test-conventions.md`, `integration-tests.md`, `live-llm-tests.md`, `compose-smoke.md`, `infrastructure-gotchas.md`, `security-gate.md`, `front-end.md`. When one names a suite for the files you changed, run it.

---

## Quality Gates

Run `mix precommit` before every push. It runs compile `--force --warnings-as-errors`, `format --check-formatted` and `credo --strict` in the dev env (where the `boundary` compiler runs), then `test --exclude integration` in the test env, and stops at the first failure. Every gate must pass before you present changes: zero warnings, zero credo issues, zero test failures. `mix quality.fast` (compile, credo, unused-deps check; no database) and `mix quality` (the same plus dialyzer) are lighter loops for iteration.

If the session-start hook printed a line beginning `!!` (`toolchain`, `postgres`, `lawspec`), fix what it names before trusting a gate.

CI (`.github/workflows/quality.yml`) also runs gates `mix precommit` does not. Run the ones your change can trip:

| Gate | Trips when you change |
|---|---|
| `mix docs --warnings-as-errors` (dev env) | a `@moduledoc`, `@doc` or `@typedoc`, the README, or a file under `docs/architecture/` or `docs/runbooks/` |
| `mix xref graph --label compile-connected --fail-above 3` | compile-time dependencies between modules |
| `mix dialyzer` (in `mix quality`) | specs or types |
| `mix coveralls.json --exclude integration` | code without tests: the minimum is in `coveralls.json` |
| the `laws` job | a module a `.lawspec` file covers (`lawspec/README.md`) |
| the `security` job | dependencies, config, the web layer, or a file, shell or raw-SQL call anywhere (`.claude/rules/security-gate.md`) |
| `compose-smoke` and `release-image` (pull requests only) | a Dockerfile, `entrypoint.sh`, a compose file or `rel/` (`.claude/rules/compose-smoke.md`, `docs/architecture/deployment.md`) |

The last two gate the images, not the code. A failure there is a finding about the image: fix the image, never loosen an assertion.

### Test tags and run modes

A plain `mix test` excludes three tags, split by what a test needs. Each is a merge gate, run on its own:

- `:integration` — real OpenSearch, object store, NIF and Oban. `docker compose up -d opensearch moto`, then `mix test --only integration`.
- `:network` — the integration tests that also clone from the public internet. `mix test --only integration --include network` is the gate's command. Never `--only network` or `--include network` without `--only integration`.
- `:llm` — real provider calls. `OPENAI_KEY=... mix test --only llm` (its conversation suite needs the OpenSearch node too).

Unit and integration tests cannot share a run; `test_helper.exs` refuses `--include integration`. A live test asserts shapes and invariants, never generated content, and one that stays red means provider drift or a parsing defect: stop and ask, never loosen the assertion. The detail is in `.claude/rules/integration-tests.md` and `.claude/rules/live-llm-tests.md`.

---

## When to Stop and Ask

Stop and ask before proceeding when:
- **Ambiguous scope** — a task reads more than one way and the difference changes which modules are touched.
- **Architecture boundary change** — moving a responsibility between modules, adding a module, or changing a module's public API. Describe the change and why first.
- **Behaviour/protocol modification** — adding, removing or changing a callback.
- **Known-defect adjacency** — the task touches an item under "Known Defects and Deferred Work": flag it, don't silently resolve or ignore it.
- **Uncertain doc update** — unsure whether a change warrants a README, architecture-file or CLAUDE.md edit.
- **Credo disable** — no inline `# credo:disable-*` without explicit approval.
- **Branch management** — each issue gets its own branch, cut from `master`; within an issue, stay on its branch.

---

## Pull Requests

Every PR description names the issue it closes with `closes #nnn`. Merges are squash-and-merge.

---

## Testing: Ordering and Failure Handling

Tests are the contract; code satisfies it. Tests written after the implementation encode what the code did, not what it should do.

**For any behaviour change:**

1. The user describes the change.
2. **Tests first.** Encode the new contract in tests before touching the implementation. If the change is non-trivial, push the test diff and STOP for approval: the tests are the spec.
3. Implement against the reviewed tests.
4. Run the gates. Iterate on the *implementation*, not the tests, until green.
5. Stop and ask if the gates keep failing in ways that suggest the test itself is wrong.

**When `mix test` is red, classify before reacting:**

1. The test asserts behaviour the spec says is **correct** → fix the implementation; do not edit the test.
2. The test asserts behaviour the spec says **should change** → update the test to the new contract, then the implementation; note the contract change in the PR.
3. **Neither** → stop and ask. Do not delete assertions, broaden matchers, add `try/rescue` or `@tag :skip`. If you are loosening an assertion to make a test pass, you are almost certainly here.

---

## Typespecs, DI, Result Tuples

- **Every public function you write has a `@spec`**, `@impl` callback implementations included, and every `@callback` and protocol function is fully typed. Two things are exempt: the lower-arity heads the compiler generates for default arguments (spec the full arity), and `__using__/1` macros.
- **An `@impl` spec's return type is a subset of the callback's.** Its argument types narrow the callback's only for values the module itself produces (its state, a `start_async` result, a name it chose); what the framework or another process sends keeps the callback's type, usually `term()`. Dialyzer does not check this; review does.
- **`term()` is for a value whose shape the module cannot know**, never a stand-in for a type another spec already names.
- **Every custom struct defines `@type t :: %__MODULE__{}`** with every field typed; specs say `MyStruct.t()`, never `%MyStruct{}`.
- **Every `@type` has a `@typedoc`**, struct `t/0` included; `@typep` is exempt.
- Retrieval callbacks return `[struct()]`, not a specific struct, on purpose (the `Cake.GDS` moduledoc, "Return types", says why).
- **List-of-struct arguments are guarded with `when is_list(arg)`**, not matched on their elements: the `@spec` says what the list holds, the guard checks the container.
- **DI is for Mox, not runtime polymorphism.** A module that depends on an external service takes its collaborator as an argument or from config, behind a behaviour with a mock. An orchestration-layer module validates its required opts before it spawns, as `Cake.Conversation.start_link/1` and `start/1` do for `:gds`.
- **Result tuples:** every fallible pipeline operation reports `{:ok, _}`/`{:error, _}`; the exceptions are in `priv/reference/creating-things.md`.

---

## README Update Protocol

After a task that changes architecture, module boundaries, conventions or tooling:
1. Review this file, the README and the files under `docs/architecture/` for stale sections.
2. Propose the specific edits: "I changed X → section Y should say Z."
3. Make the approved edits before closing.

**Enumeration rule:** when those files list things of a kind (behaviours, protocols, structs, implementations, pipelines, boundaries, config keys) and you create another, add it. The inventories are in `docs/architecture/inventories.md`. Every issue cut ends with a **final checkbox** for a documentation update that applies this rule, naming any custom struct the work introduces.

---

## Known Defects and Deferred Work

An entry belongs here when you would otherwise fix the defect in passing, or trust code that is known to be wrong. One line each; the detail is in the issue.

- **xref coupling ratchet (#208):** the `--fail-above 3` baseline comes from `Conversation.State`'s defstruct DI defaults; it ratchets to 0 once those are decoupled.
- **Book status after a sweep (#305):** `Books.Pipeline.ingest_with_sweep/5` leaves `embedding_status` at `:failed` after `retry_from_chunk` resolves a book's last failing chunk.
- **Hexdocs sources with several top-level forms (#291):** `Hexdoc.to_parsed_docs/1` accepts only a bare `defmodule` AST, so `enum.ex`, `kernel.ex`, `string.ex` and the like yield no `ParsedDocument` and no `FailedIngest`.
- **Post-demo formats (#418):** Word, Excel, CSV and JPG pipelines are deferred.
