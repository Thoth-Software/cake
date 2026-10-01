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
| Add a `Cake.Search.Backend` implementation, or change `Backend.OpenSearch` / `Search.Deployment` | README "Search Design"; `test/support/backend_conformance.ex` (instantiate it for the new backend) + `test/support/search_integration_case.ex`; run `mix test --only integration` (see "Integration tests") |
| Change what `Books.Pipeline.ingest/4` / `Documents.Pipeline.ingest/4` / `ingest_with_sweep/5` persist, embed, index or report, or add an end-to-end ingestion test | "Integration tests" below; `test/support/ingest_integration_helpers.ex`; the existing `*_integration_test.exs` for the pipeline as reference; run `mix test --only integration --include network` against a real node (the `:network` group clones elixir-lang/elixir) |
| Change `Cake.Books.Adapters.S3`, ExAws config, or `Cake.S3IntegrationCase`; add a `Cake.Books.Adapters` implementation | `lib/cake/books/adapters.ex` + `adapters/s3.ex` (the "Authentication" and "Errors" sections); `test/support/s3_integration_case.ex`; `test/cake/books/adapters/s3_integration_test.exs` as reference; run `mix test --only integration` (see "Integration tests") |
| Add/modify a live-provider test (`:llm`), touch `Cake.LiveLLMCase`, or change what `Cake.Embeddings` / `Cake.Generation.OpenAI` / `Cake.Decomposition.LLM` send over the wire | "Live LLM tests" below; `test/support/live_llm_case.ex`; the existing `*_live_test.exs` for the module as reference; run `OPENAI_KEY=... mix test --only llm` |
| Add/modify an end-to-end `Cake.Conversation` test (tier 1 `:integration` or tier 2 `:llm`), or touch `Cake.ConversationIntegrationHelpers` | "Integration tests" + "Live LLM tests" below; `test/support/conversation_integration_helpers.ex`; README "The Per-Turn Pipeline"; `test/cake/conversation_integration_test.exs` as reference; run `mix test --only integration` (and `OPENAI_KEY=... mix test --only llm` for the live tier) |

Work under `test/` auto-loads `.claude/rules/test-conventions.md` (path-scoped) — no manual trigger needed.

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
- The `security` job: `mix deps.unlock --check-unused` (blocking) plus `mix hex.audit` and `mix deps.audit` (**report-only** while the advisory backlog in #206 is outstanding; they flip to blocking once it clears), and `mix sobelow --config --exit` (blocking) — static security analysis of the Phoenix app. Its baseline is clean: triaged false-positives are suppressed in `.sobelow-conf` (`:ignore` for deployment-level Config findings, `:ignore_files` for internal file-I/O modules) and via inline `# sobelow_skip` annotations at request-facing call sites, so the gate fails only on **new** findings. When Sobelow flags new code, fix it or — if it's a verified false-positive — add a justified `# sobelow_skip` (never a blanket ignore).

Tests tagged `:integration` are excluded on-push and run separately as a merge gate via `mix test --only integration` against a real OpenSearch node (see below). PRs additionally run the compose smoke test, `ci/compose_smoke.sh`, which gates the containers rather than the code (see "Compose smoke test" below).

### Integration tests (merge gate)
The `integration` job in `quality.yml` runs `mix test --only integration --include network` against a real single-node OpenSearch service container (`opensearchproject/opensearch`, security plugin disabled, mirroring the `opensearch` service in `docker-compose.yml`), an S3-compatible object store (`motoserver/moto`, mirroring the `moto` service there; see the workflow comment for why moto rather than MinIO or LocalStack), plus Postgres. What runs there: the backend conformance suite (`Cake.Search.BackendConformance`, instantiated for `Backend.OpenSearch` — collection lifecycle and search modes), the mapping + boot tests (`build_mapping/1` accepted by the server for both GDS schemas, `Deployment.create_collections_unless_exist/2`), the GDS round-trip tests (`Pipelines.add_to_search_backend/3` → search → `load_from_hits/1` → `expand_with_neighbors/2`), and the Rustler NIF suite — `Cake.ParseBooksTest` + `Cake.ParseBooksPropertyTest` (the `Cake.ParseBooks.extract_pdf/1` contract: page text and order, struct decoding, skipped pages, `{:error, _}` never a crash) and `Cake.Books.Pdf.PipelineIntegrationTest` (`Pdf.Pipeline.parse/1`: dense `chunk_index` after blank-page rejection, the title fallback chain, book metadata) — over the fixture PDFs under `test/support/fixtures/pdfs/`, loaded through `Cake.PdfFixtures`, and the end-to-end conversation suites (#249, tier 1) on `Cake.ConversationIntegrationHelpers` (`test/support/conversation_integration_helpers.ex`): `Cake.ConversationIntegrationTest` (`autoask/2` over real hits — dense prompt indices, citation resolution and renumbering against the real chunk map, the PubSub events; the manual `manualask/2` → `select_docs/2` flow; cache reuse across turns pinned by the collection's search request count; the empty-retrieval cache of #255/#264; hallucinated-marker filtering), `Cake.ConversationDecompositionIntegrationTest` (a Mox decomposition collaborator against the real index for all four strategies — flat fan-out, sequential least-to-most, self-ask and IRCoT — with generation scripted, never asserted as prose), and `CakeWeb.ChatLiveIntegrationTest` (mount → submit → real retrieval → PubSub round trip → citations rendered). The helpers seed a `Cake.Books.Chunk` corpus with unit-vector embeddings into the test's own collection, bind a `Cake.GDS` to that collection (`CollectionGDS`, configured per test — the reason those suites are `async: false`, together with the shared Ecto sandbox the turn task needs), script generation through `Req.Test` and the real `Cake.Generation.OpenAI` transport, and allow the conversation pid on every collaborator so the turn tasks under `Cake.TaskSupervisor` inherit access. And the end-to-end ingestion suites (#248), on `Cake.IngestIntegrationHelpers` (`test/support/ingest_integration_helpers.ex`), where only the embedding provider is substituted — `Cake.Embeddings.Mock` answers with `deterministic_embedding/1`, the unit vector on the axis the input text hashes to, so a query embedded the same way is an exact vector match — and everything else is real: `Cake.Books.PipelineIntegrationTest` (a fixture PDF staged through the Disk adapter → `Books.Pipeline.ingest/4` → NIF → `ParsedBook` + `Chunk` rows → the real `chunks_of_books` collection → `Cake.Search.search_chunks/4`; then the contracts: `file_hash` dedup, honest partial and all-fail summaries, `embedding_status` transitions, the pipeline-fatal `FailedIngest` row from #258; then `ingest_with_sweep/5`, run-scoped: `retry_from_chunk` re-embedding and re-indexing into the real index, unresolvable failures remaining with their counts, another run's rows untouched), `Cake.Documents.Hexdocs.PipelineIntegrationTest` (a real `git clone` of one small tagged Elixir release → `Documents.Pipeline.ingest/4` → `Hexdoc` + `ParsedDocument` rows → the real `docs` collection; `retry_from_raw/2` from the persisted raw row alone) and `Cake.Jobs.DocumentIngestionJobIntegrationTest` (`DocumentIngestionJob` drained with the real Hexdocs pipeline — the five older `:integration` Oban tests only ever drive `Cake.TestPipeline`). These three are `async: false` — the pipelines index into the GDS's fixed collection name and the storage adapter is application config — and the helpers create that collection in the namespace with the production mapping and empty it before and after each test. And the S3 adapter suite (#251) against the object store — `Cake.Books.Adapters.S3IntegrationTest` (the four callbacks and the ExAws error shapes: `{:http_error, status, response}`, the transport error, `false` from `exists?/1`, `ArgumentError` without `:book_storage_s3_bucket`), `Cake.Books.Pdf.PipelineS3IntegrationTest` (`load_binary/1` with the S3 adapter configured: the `{:ok, {key, binary}}` shape and the `{:error, {key, message}}` wrap), and the template's own contract (`Cake.S3IntegrationCaseTest`). The search tests `use Cake.SearchIntegrationCase`, which gives each test a collection of its own inside the `cake_test` Snap index namespace and drops it afterwards, so a developer's real `docs`/`chunks_of_books` indices are never touched. The S3 tests `use Cake.S3IntegrationCase`, which points ExAws's `:s3` service at `S3_ENDPOINT_URL` with a fixed key pair for each test (the test-time stand-in for the IAM role production assumes; `config/config.exs` sets ExAws's HTTP client to Req for every env), gives the test a bucket of its own in `:book_storage_s3_bucket`, and drops every bucket under that prefix afterwards; it refuses `async: true` because both keys are global to the VM. The NIF suite needs only the compiled `parsebooks` crate (every CI job installs the Rust toolchain), but it is tagged `:integration` all the same so the pre-push hot path never runs it; the `--only integration` run mode is global, so locally it still needs the OpenSearch node and the object store below to start. A new `Cake.Search.Backend` implementation instantiates the suite with `use Cake.Search.BackendConformance, backend: ..., mapping: ...` and must pass it unchanged. Unit and integration tests cannot share one run (the skip flag and the Deployment config are global), which is why this is a separate invocation: `test_helper.exs` refuses a mixed `--include integration` run with an error pointing at `--only integration`. Locally, start the same node and run the same command:
```bash
docker compose up -d opensearch moto               # publishes http://localhost:9200 and http://localhost:9000 (see docker-compose.yml)
mix test --only integration --include network      # the merge gate's command; MIX_ENV=test; OPENSEARCH_URL and S3_ENDPOINT_URL override those defaults
mix test --only integration                        # the same minus the :network group (no clone) — a local shortcut, not the gate
```

`OPENSEARCH_URL` and `S3_ENDPOINT_URL` are read by the integration test setup only; leave them unset on the host, or set them to `http://opensearch:9200` and `http://moto:9000` when running inside the `cake_app` container (the compose file already does). The `moto` service is the S3-compatible object store for the `Cake.Books.Adapters.S3` suite (#251): moto's standalone server rather than MinIO or LocalStack, because MinIO has withdrawn its community images and LocalStack's current images need a paid token (the compose file and `quality.yml` carry the details). Only the integration run needs it; dev uses the Disk adapter.

**`:network` tag.** The end-to-end hexdocs tests (`Cake.Documents.Hexdocs.PipelineIntegrationTest`, `Cake.Jobs.DocumentIngestionJobIntegrationTest`) are tagged `:network` *instead of* `:integration` (`use Cake.SearchIntegrationCase, async: false, network: true`): `Hexdocs.Pipeline.download/1` really clones elixir-lang/elixir (v1.0.0, the smallest tag, ~27 MB). They are part of the same required merge gate as the `:integration` tests — the `integration` job runs both, and a `:network` failure turns it red — so the separate tag exists only for local runs: an ExUnit include always wins over an exclude, so a test carrying both tags could never be left out of a plain `mix test --only integration`, and a developer without network would have no way to run the rest. Never `--only network` or `--include network` alone: without `--only integration` it is a unit-mode run (no real cluster), and the tests refuse it.

### Live LLM tests (merge gate, internal PRs only)

Test tags split by what a test *needs*, not by how slow it is:

- `:integration` — hermetic infrastructure (OpenSearch, the Rustler NIF, Oban): free and deterministic, so a required merge gate on every PR (the `integration` job, above).
- `:network` — the integration tests that also reach the public internet (the hexdocs clone): the same required merge gate, run by the same job via `--include network`; tagged separately only so a plain local `--only integration` can leave them out.
- `:llm` — real provider calls: secret-bearing (`OPENAI_KEY`), cost-bearing, and rate-limit-flaky. `test_helper.exs` excludes it from every default run alongside `:integration`; only `mix test --only llm` runs it.

The `llm` job in `quality.yml` runs `mix test --only llm` with `OPENAI_KEY` from repository secrets — plus the same pinned OpenSearch service as the `integration` job and Postgres, for the staging-shaped conversation suite below — guarded by `github.event.pull_request.head.repo.full_name == github.repository`: fork PRs never receive secrets, and the guard *skips* the job rather than soft-failing it, so on an internal PR a missing or broken key turns the gate red while on a fork PR the skipped job satisfies the required check. Locally: `OPENAI_KEY=... mix test --only llm`. Assertions pin shapes and invariants (vector length, schema validity, marker parseability, loop termination) — never generated content or reasoning text — and corpora stay tiny and models cheap.

Live tests `use Cake.LiveLLMCase` (`test/support/live_llm_case.ex`) and sit next to the unit test they extend as `*_live_test.exs`. The template tags the module `:llm`, reads the key with `api_key!/0` (unset or blank raises — a live test never skips), points `Cake.Embeddings` and `Cake.Generation.OpenAI` at the real endpoints with no `Req.Test` hook for the duration of each test (`configure_live!/1`; call it again with a wrong key to provoke the provider's auth error), and restores the previous config in `on_exit`. It refuses `async: true` at compile time: the config it swaps is global to the VM, and only sync modules are guaranteed never to interleave with the `Req.Test`-driven unit tests of the same modules. Models and dimensions are read from config at run time, so the gate follows production rather than a copy of it: every generation-driven suite takes its model from `production_response_model/0`, which is `Cake.Conversation`'s `:response_model` (the key `ChatLive` starts conversations from — `:default_response_model` in `config.exs` is read by nothing in `lib/`), and the embeddings suite reads `:default_embedding_model`/`:default_embedding_dimension`, the keys the ingestion and search LiveViews and the OpenSearch mapping use.

What runs there: the template's own network-free smoke test (`Cake.LiveLLMCaseTest.Tagged`); `Cake.EmbeddingsLiveTest` (`embed/3`: configured vector dimension, usage shape, struct passthrough, 401 as an error tuple); `Cake.Generation.OpenAILiveTest` (`complete/3` against the Responses API: success parse, `finish_reason` mapping, usage normalization, `{:auth, _}`); `Cake.Generation.OpenAIJSONLiveTest` (`complete_json/3` round-tripped through ExJsonSchema with the two schemas production sends — `Cake.Decomposition.LLM.schema/0` and `Cake.Prompt.ircot_schema/0`); and `Cake.Decomposition.LLMLiveTest` (`decompose/2` with its production defaults: atomic → `:none`, compound → dependency-free `:flat` entries that survive `Result.new/2`). Two more suites gate the interleaved driver protocols, directly through `Cake.Prompt` + `Cake.Generation` with no strategy module and no `Conversation` — protocol conformance here, full interleaved live turns in #271 once a production emitter marks a `Result` `:self_ask`/`:ircot`. `Cake.Prompt.SelfAskLiveTest` drives `self_ask_prompt/3` through `complete/3`, answering each follow-up with a plain completion and folding the pair back in: every driver reply must carry "Follow up:" or "So the final answer is:" (the parser is total, so parseability alone proves nothing), and a trivial question must reach the final marker within `:max_self_ask_iterations`. `Cake.Prompt.IRCoTLiveTest` drives `ircot_prompt/3` through `complete_json/3` with `ircot_schema/0`, folding each continuing step in with an empty context: every step must validate and classify via `parse_ircot_response/1`, and a trivial question must terminate with a null `retrieval_query` within `:max_ircot_iterations`. Both mirror the `Conversation` loops' at-most-cap accounting and read the model from `Cake.Conversation`'s config. A live test that stays red after the wiring is in means provider drift or a parsing defect: stop and ask, never loosen the assertion. **The staging-shaped suite (#249, tier 2).** `Cake.ConversationLiveTest` runs the whole loop with every production collaborator live: a tiny corpus embedded by the real `Cake.Embeddings`, indexed into a real OpenSearch collection, answered by the real `Cake.Generation.OpenAI` on `production_response_model/0`, cited by the real `Cake.Responses`. It pins that the turn's citations are non-empty, that each resolves to a chunk the turn retrieved from the corpus, and that every `[N]` left in the text is one of them — one plain turn (`decomposition: nil`) and one `:sequential` turn through a test strategy (no production strategy emits dependency edges yet), the single decomposed live case budgeted; self-ask and IRCoT live turns are #271's. It is the staging smoke test #244 describes and the seed of the future staging-branch merge gate. It is tagged `:llm` only, so it needs what an integration run has without being one: it takes its per-test collection from `Cake.SearchIntegrationCase.integration_collection/1` (the case template's setup as a named setup) and repoints `Cake.Search.Deployment` at `OPENSEARCH_URL` itself in `setup_all` (`Cake.ConversationIntegrationHelpers.start_live_deployment!/0`, which refuses any run shape but an exclusive `--only llm`). Locally that means the node from "Integration tests" must be up: `docker compose up -d opensearch && OPENAI_KEY=... mix test --only llm`.

`Cake.Generation.Anthropic` is a stub today; when it is implemented it gets the same generation and structured-output suites, parameterized on the module, and the template grows the matching config swap.

### Compose smoke test (merge gate)

The `compose-smoke` job in `quality.yml` runs `ci/compose_smoke.sh` on every PR. Where the ExUnit jobs gate the code inside service containers, this gates the containers themselves (#250): Phoenix runs `server: false` in test, so `Cake.Application`'s supervision order and `Cake.Search.Deployment`'s boot-time collection creation run nowhere else in CI, and the NIF-clobbering recompile sequence lives in `entrypoint.sh` ("Infrastructure Gotchas" below), where only a broken dev container ever surfaced a regression. The script builds the image from the `Dockerfile`, starts `db` and `opensearch`, waits on their health checks with a bounded timeout, starts the app through `entrypoint.sh` only then (the entrypoint waits for OpenSearch itself but not for Postgres), and asserts, in order: HTTP 200 from the app through the published port; both collections (`chunks_of_books`, `docs`) exist in OpenSearch, proving `Deployment` boot ran; every migration under `priv/repo/migrations` is in `schema_migrations`; and a one-shot `mix cake.nif.check test/support/fixtures/pdfs/multi_page.pdf` inside the app container extracts the fixture through `Cake.ParseBooks.extract_pdf/1`, proving the recompile produced a loadable Linux `.so`. That last check is only meaningful because the script first overwrites `priv/native/parsebooks.so` with a stale file in the created, not yet started, app container: the image's own build already carries a valid NIF, which would pass the check even with the recompile sequence deleted from `entrypoint.sh`, so the planted file reproduces the dev bind mount's unloadable host `.so` and only a rebuild at boot can replace it. It tears the stack down with `docker compose down -v` on every exit path, printing the container logs first on failure. The stack under test is the checked-in topology: `docker-compose.yml` unchanged, layered with `docker-compose.ci.yml` (no dev bind mount, so the image runs as built; no `db`/`opensearch` host ports, both are queried through `docker compose exec`; OpenSearch pinned to the release the `integration` job pins; smoke-specific container names) and interpolated from `.env.ci` (checked in and secret-free: `UID`/`GID` for the Dockerfile's `useradd`, the trust-authenticated `CAKE_PG*` role, an `OPENSEARCH_INITIAL_ADMIN_PASSWORD` that only has to pass the image's strength check because the security plugin is disabled, and a placeholder `OPENAI_KEY` — the app boots without a real one, and this is the proof). As it grows, the script is the executable record of the deployment topology, the seed for the staging environment #244 anticipates. Locally, with Docker running and no dev stack up (both publish the app on 4000):

```bash
ci/compose_smoke.sh               # a few minutes on a runner (the image build dominates; entrypoint.sh's recompile reuses the image's _build), longer on a laptop
SMOKE_KEEP=1 ci/compose_smoke.sh  # leave the stack up afterwards; every SMOKE_* knob is documented in the script
```

It runs under its own compose project (`cake-smoke`), so its `down -v` never touches the dev stack's volumes. A failure here is a finding about the containers, not the code: fix `Dockerfile`, `entrypoint.sh` or the compose files, never loosen an assertion, and stop and ask when what broke is the boot path itself.

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
- Behaviour callbacks (`@callback`) and protocol functions (`@spec`) get full typespecs.
- Retrieval callbacks return `[struct()]`, not a specific struct type — deliberate (see GDS behaviour docs in README).
- **List-of-struct args use `when is_list(arg)` guards**, not head-matching on list elements. The `@spec` controls what the list contains; the guard validates the container type at runtime.
- **DI is for Mox, not runtime polymorphism:** modules depending on external services accept collaborator modules as args (or read them from config); define a behaviour, implement it, provide a mock in test. `Cake.Conversation` requires a `:gds` opt validated in `start_link/1`/`start/1` before the GenServer spawns (`init/1` only builds state). Follow the same required-opt pattern for future orchestration-layer modules.
- **Result tuples:** every fallible pipeline operation reports through `{:ok, _}`/`{:error, _}`. Direct callbacks return them as-is (`retry_from_raw/2`, `Books.Pipeline.load_binary/1`), with one tagged exception: `Documents.Pipeline.download/1` returns `{:error, :download, reason}` (three elements) so the orchestrator can attribute the failure to the download step. Inside a stream callback (`persist_raw_docs/2`, `parse/2`), fallible per-item work produces result tuples that the callback itself must pass through `Pipelines.detuple_with_logging/3` — persisting failures to `FailedIngest`, never a silent filter — *before* returning: the `Enumerable.t()` a stream callback returns carries bare successful values, ready for the next stage. `Books.Pipeline.parse/1` is a second exception: it returns a bare `{ParsedBook.t(), [Chunk.t()]}` on success and **raises** on failure — `parse_all_binaries/3` rescues the exception into the per-item error tuple, and every returned value (an `{:error, _}` included) is wrapped `{:ok, _}` as success, so never signal failure by return value there. Declarative callbacks return bare values by design (`format/0`, `success_message/*`). Step names follow `"pipeline.step"`. Pipeline-fatal errors go in the `else` of the `with` chain, routed through `Pipelines.handle_ingest_error/2`. That chain must include an eager, run-level fallible step (`Documents.Pipeline`: `download/1`; `Books.Pipeline`: `validate_paths/1`), because stream stages always return `{:ok, stream}` and can't reach `else` (README "Pipeline-Fatal Steps and the `with` Chain").

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

- **NIF clobbering.** The `.:/app` bind mount overlays macOS binaries onto the Linux container. `entrypoint.sh` forces recompilation in sequence: `rm -f priv/native/*.so` → `mix deps.compile --force bcrypt_elixir` → `mix compile --force`. Diagnostic for this failure: "module not available" — not `:nif_not_loaded`. `mix cake.nif.check PATH` reproduces it on demand (it extracts a PDF through the NIF without starting the app), and the compose smoke gate runs it inside the app container on every PR.
- **Colima FD limits.** Default 1024 is too low for concurrent `Task.async_stream` fan-out. Raise via provision script.
- **Colima port forwarder leak.** `limactl` accumulates CLOSED socket FDs. Fix: `colima start --network-address`.
- **Colima port forwarder saturation.** `portForwarder: ssh` saturates under burst traffic. Use `grpc`.
- **Bind mount hot paths.** Heavy virtiofs I/O through the mount is slow. Copy to `/tmp` inside the container on hot paths.

---

## Known Defects and Deferred Work

If your task touches these, flag rather than silently resolving or ignoring. One line each; the detail lives in the linked issue.
- **Post-demo formats** (README "Roadmap"): Word, Excel, CSV, JPG pipelines are explicitly deferred.
- **Advisory backlog (#206):** `mix hex.audit` / `mix deps.audit` are report-only in CI until the backlog clears, then flip to blocking.
- **xref coupling ratchet (#208):** `--fail-above 3` baseline comes from `Conversation.State`'s defstruct DI defaults; ratchets to 0 once those are decoupled.
- **Book status after a sweep (#305, found by #248):** `Books.Pipeline.ingest_with_sweep/5` leaves `embedding_status` at `:failed` after `retry_from_chunk` resolves a book's last failing chunk.
- **Hexdocs sources with several top-level forms (#291, found by #248):** `Hexdoc.to_parsed_docs/1` accepts only a bare `defmodule` AST, so `enum.ex`, `kernel.ex`, `string.ex` and the like yield no `ParsedDocument` and no `FailedIngest`.
