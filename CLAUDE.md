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

This file says what you must do when you work on Cake; the README says what things are and why (reference it, don't restate it here). If this file contradicts what you infer from the code, **this file wins**: flag the discrepancy rather than silently following the code.

---

## Context Loading

**Always load:** `README.md` (the domain model, the layers and which way they depend), `priv/reference/naming-conventions.md`, and `priv/reference/enum-cheat.cheatmd` (before any collection transformation or explicit recursion over a list).

### Load by trigger
Load the full file when the task matches the trigger. Reference files live in `priv/reference/`.

| When you're about to... | Load |
|---|---|
| Refactor function bodies, change pattern matching, modify string/list/map logic, add params, change arity, modify exception handling, introduce boolean/flag params | `code-anti-patterns.md` + `patterns-and-guards.md` + `docs-tests-and-with.md` |
| Create/rename/move modules, restructure dirs, define new public APIs/behaviours, add/change structs/schemas, introduce deps, change call graphs, add config | `design-anti-patterns.md` + `config-and-distribution.md` |
| Add or restyle a screen, component or layout; touch `assets/`, `core_components.ex`, `layouts.ex` or a LiveView template; move daisyUI, heroicons, Tailwind or esbuild | `.claude/rules/front-end.md` (start a new screen from `mix phx.gen.live` and commit its raw output first; daisyUI classes over ad-hoc utilities; no Node; select by `id` in LiveView tests; where the kit's files come from and how to update them); README "Components, Layouts and Assets"; then build the assets and look at the page in both themes and at phone width, because the suite cannot see a style; `docs/demo-script.md` when the change alters a step of the demo |
| Write/modify macros, `use`, `quote`/`unquote`, DSLs, compile-time codegen | `macro-anti-patterns.md` + `macros.md` |
| Create/modify/supervise GenServers/Agents/Tasks, modify supervision tree, use spawn/Task.async, work with Registry/PubSub/message passing | `process-anti-patterns.md` + `genservers.md` + `supervisor-and-application.md` + `task-and-gen-tcp.md` (+ `dynamic-supervisor.md` if dynamic spawning) |
| Write/modify `@type`/`@spec`, address type warnings, design data types | `gradual-set-theoretic-types.md` + `typespecs.md` |
| Write/modify public API for external use, design behaviours for third-party use | `library-guidelines.md` |
| Create or modify a GDS, ingestion pipeline, behaviour, protocol, Ecto schema, or non-Ecto struct | `priv/reference/creating-things.md` |
| Add/modify a GDS, or implement `Cake.GDS`/`Cake.Promptable`/`Cake.Citable` | README "Cardinality" + "Adding a New GDS"; `lib/cake/gds.ex` + `promptable.ex` + `citable.ex`; one existing GDS impl (`ParsedBook` or `ParsedDocument`) as reference; `design-anti-patterns.md` |
| Add/modify a decomposition strategy, or touch `Cake.Decomposition` | README "Query Decomposition"; `lib/cake/decomposition.ex` + `decomposition/result.ex`; `decomposition/llm.ex` as reference implementation |
| Change a module listed in `@cake_sources` in `lawspec/mix.exs`, or add a LawSpec specification | `lawspec/README.md`; update the module's `.lawspec` file first, as with any test, regenerate, and run the `laws` job's steps |
| Add a `Cake.Search.Backend` implementation, or change `Backend.OpenSearch` / `Search.Deployment` | README "Search Design"; `test/support/backend_conformance.ex` (instantiate it for the new backend) + `test/support/search_integration_case.ex`; run `mix test --only integration` (see `.claude/rules/integration-tests.md`) |
| Change what `Books.Pipeline.ingest/4` / `Documents.Pipeline.ingest/4` / `ingest_with_sweep/5` persist, embed, index or report, or add an end-to-end ingestion test | `.claude/rules/integration-tests.md`; `test/support/ingest_integration_helpers.ex`; the existing `*_integration_test.exs` for the pipeline as reference; run `mix test --only integration --include network` against a real node (the `:network` group clones elixir-lang/elixir) |
| Change `Cake.Books.Adapters.S3`, ExAws config, or `Cake.S3IntegrationCase`; add a `Cake.Books.Adapters` implementation | `lib/cake/books/adapters.ex` + `adapters/s3.ex` (the "Authentication" and "Errors" sections); `test/support/s3_integration_case.ex`; `test/cake/books/adapters/s3_integration_test.exs` as reference; run `mix test --only integration` (see `.claude/rules/integration-tests.md`) |
| Add/modify a live-provider test (`:llm`), touch `Cake.LiveLLMCase`, or change what `Cake.Embeddings` / `Cake.Generation.OpenAI` / `Cake.Decomposition.LLM` send over the wire | `.claude/rules/live-llm-tests.md`; `test/support/live_llm_case.ex`; the existing `*_live_test.exs` for the module as reference; run `OPENAI_KEY=... mix test --only llm` |
| Add/modify an end-to-end `Cake.Conversation` test (tier 1 `:integration` or tier 2 `:llm`), or touch `Cake.ConversationIntegrationHelpers` | `.claude/rules/integration-tests.md` + `.claude/rules/live-llm-tests.md`; `test/support/conversation_integration_helpers.ex`; README "The Per-Turn Pipeline"; `test/cake/conversation_integration_test.exs` as reference; run `mix test --only integration` (and `OPENAI_KEY=... mix test --only llm` for the live tier) |

Path-scoped rules in `.claude/rules/` auto-load when you work on a file their `paths:` frontmatter matches — no manual trigger needed: `test-conventions.md` (anything under `test/`), `integration-tests.md`, `live-llm-tests.md`, `compose-smoke.md`, `infrastructure-gotchas.md`, `security-gate.md` and `front-end.md`. The rows above that name one of them are for loading it before you have opened a matching file. LawSpec work also loads the compiler's prelude through a hook (`.claude/hooks/lawspec-prelude.sh`; `lawspec/README.md`, "The prelude in Claude Code sessions"), so never write a `prelude.` name from memory.

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
- **Ambiguous scope** — a task reads more than one way and the difference changes which modules are touched.
- **Architecture boundary change** — moving a responsibility between modules, adding a module, or changing a module's public API. Describe the change and why first.
- **Behaviour/protocol modification** — adding, removing or changing a callback.
- **Known-defect adjacency** — the task touches an item under "Known Defects and Deferred Work": flag it, don't silently resolve or ignore it.
- **Uncertain doc update** — unsure whether a change warrants a README or CLAUDE.md edit.
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

- **Every public function has a `@spec`.** No exceptions — including `@impl` callback implementations, so specs appear in LLM context. An `@impl` spec's return type is a subset of the callback's. Its argument types narrow the callback's only for values the implementing module itself produces (its state, a `start_async` result, a name it chose); arguments the framework or other processes produce (messages, requests, exit reasons, `from`) keep the callback's type, usually `term()`. Dialyzer flags only an argument or return with *nothing in common* with the callback's, so this rule is enforced in review, not by the gate.
- **`term()` is for values whose shape the module genuinely cannot know**, never a stand-in for a type another spec already names. If the value comes from one call with a typed result, the spec names that type.
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

**Enumeration rule:** if the README lists things (behaviours, protocols, structs, implementations, pipeline implementations) and you create a new instance of that kind, add it to the list. Every new issue cut must include, as its **final checkbox**, a documentation update that applies this rule — in particular, adding any custom structs the work introduces to the README's struct inventory.

---

## Known Defects and Deferred Work

One line each; the detail lives in the linked issue.
- **Post-demo formats** (README "Roadmap"): Word, Excel, CSV, JPG pipelines are explicitly deferred.
- **xref coupling ratchet (#208):** `--fail-above 3` baseline comes from `Conversation.State`'s defstruct DI defaults; ratchets to 0 once those are decoupled.
- **Book status after a sweep (#305, found by #248):** `Books.Pipeline.ingest_with_sweep/5` leaves `embedding_status` at `:failed` after `retry_from_chunk` resolves a book's last failing chunk.
- **Hexdocs sources with several top-level forms (#291, found by #248):** `Hexdoc.to_parsed_docs/1` accepts only a bare `defmodule` AST, so `enum.ex`, `kernel.ex`, `string.ex` and the like yield no `ParsedDocument` and no `FailedIngest`.
