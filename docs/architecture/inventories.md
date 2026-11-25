# Inventories

The complete lists: module boundaries, every custom struct, behaviour and protocol with its implementations, the LawSpec specifications, and the configuration keys. When you create another of any of these, add it here. `README.md` has the domain model and the map of the architecture files.

## Module Boundaries (enforced by `boundary`)

The layer responsibilities (README, "Architecture: Application Layers") are enforced at compile time by the [`boundary`](https://hex.pm/packages/boundary) compiler. Each top-level context is a boundary that declares the boundaries it may call (`deps`) and the modules it makes public (`exports`); any cross-boundary call not covered by a declared dep is a compiler warning, which fails the build under `--warnings-as-errors` (how `mix precommit`, `mix quality` and CI compile). Calls made from a protocol implementation are not checked unless it is classified into a boundary, and none of the four `defimpl`s is.

- **`Cake`** — the shared kernel: `Repo`, `Schema`, `Mailer`, the `GDS` behaviour, the `Citable`/`Promptable` protocols, `Citations`, `FailedIngests` and `FailedIngests.FailedIngest`, `ParseBooks`. `Cake.Release`, the release's database tasks, is in the kernel too, and is not exported: it touches only `Cake.Repo`, and nothing in `lib/` calls it: its callers are the release's own scripts and `test/cake/release_test.exs` (see `docs/architecture/deployment.md`). Depends on nothing internal; every context may depend on it.
- **Ingestion** — `Cake.Books` (exports `Adapters`, `ParsedBook`, `Chunk`, `Pipeline`, `Pdf.Pipeline`, `ZipExtractor`) and `Cake.Documents` (exports `Pipeline`, `Hexdocs.Pipeline`, `ParsedDocument`) depend on `Cake.Search`, `Cake.Embeddings`, and `Cake.Pipelines` (exports `Context`; in turn depends on `Cake.Search`).
- **Retrieval** — `Cake.Search` depends only on the kernel and exports `Result`, `Query`, `Hit`, `Backend`, `Provenance` and `Deployment`. The collections created at boot come from `:search_collections` config, which is what keeps the search layer from depending back on the ingestion contexts (an otherwise-cyclic dependency). `Cake.Embeddings` likewise depends only on the kernel and exports `Behaviour`.
- **Conversation** — `Cake.Conversation` is the orchestrator (exports `Events`); it depends on `Cake.Prompt` (exports nothing), `Cake.Search`, `Cake.Embeddings`, `Cake.Generation` (exports `OpenAI` only, so `Cake.Generation.Anthropic` is unreachable from outside its boundary), `Cake.Responses` (exports `Result`), and `Cake.Decomposition` (exports `Result` and `LLM`). Peer-to-peer deps among the service modules are minimal: `Cake.Responses → Cake.Search`, `Cake.Prompt → Cake.Search` (for the `Result` type), and `Cake.Decomposition → Cake.Prompt`/`Cake.Generation`. Nothing depends back on `Cake.Conversation` except the web layer. `Cake.Candidates` is a top-level boundary of its own (deps `Cake` and `Cake.Search`, exports nothing) that the web layer calls alongside `Conversation`.
- **Accounts** — `Cake.Accounts` depends only on the kernel and exports `User`.
- **Web / jobs / app / tasks** — `CakeWeb` depends on `Cake`, `Cake.Accounts`, `Cake.Books`, `Cake.Candidates`, `Cake.Conversation`, `Cake.Embeddings` and `Cake.Search`, and exports `Endpoint` and `Telemetry`; `Cake.Jobs` depends on `Cake.Documents`; Cake.Application (top-level, `@moduledoc false`) on `Cake`, `CakeWeb` and `Cake.Search`. The three Mix tasks are top-level boundaries of their own: `Mix.Tasks.Precommit` and `Mix.Tasks.Hooks.Install` with no deps, `Mix.Tasks.Cake.Nif.Check` depending on `Cake`.

The compiler runs in `:dev`/`:prod` only — test files and support modules deliberately cross boundaries, so `:test` is excluded — and CI enforces it with a dev-env compile. When you add a cross-context call, declare the `dep` (and `export` the target module) rather than working around the boundary.

---

## Custom Structs: Complete Inventory

Every custom struct in Cake, its module, and its purpose. Every one of them defines `@type t`. Both kinds of schema below `use Cake.Schema`.

### Ecto Schemas (database tables)

| Struct | Module | Purpose |
|---|---|---|
| `ParsedBook` | `Cake.Books.ParsedBook` | Book-level metadata for book-like documents. GDS identity module for the Books GDS. |
| `Chunk` | `Cake.Books.Chunk` | Atomic searchable text fragment within a book, with its `embedding` and the `embedding_model` that produced it. Retrieval unit for the Books GDS. |
| `ParsedDocument` | `Cake.Documents.ParsedDocument` | Programming documentation entry, with its `embedding` and the `embedding_model` that produced it. Both GDS identity and retrieval unit for the Documents GDS. |
| `Hexdoc` | `Cake.Documents.Hexdocs.Hexdoc` | Raw Elixir source cloned from the elixir-lang/elixir repository. Intermediate storage (raw data struct). |
| `FailedIngest` | `Cake.FailedIngests.FailedIngest` | Persists pipeline failures, tagged with the recording run's `run_id`: item-level ones, for retry via `Cake.Pipelines.sweep/3`, and pipeline-fatal ones (`pipeline_fatal: true`), which the run-scoped listing and the sweep leave out. |
| `User` | `Cake.Accounts.User` | Phoenix authentication user record: a `username` (what a user logs in with; 3 to 32 characters, compared case-insensitively and stored as typed), a `role` (`:member` or `:admin`), an `email` (required; a user cannot log in until it is confirmed, `confirmed_at`), and a hashed password. |
| `UserToken` | `Cake.Accounts.UserToken` | Session tokens, and the mailed tokens for email confirmation, password reset and email change. |

### Non-Ecto Domain Structs

| Struct | Module | Purpose |
|---|---|---|
| `Pipelines.Context` | `Cake.Pipelines.Context` | A run's identity and options, carried through an ingestion run. Fields: `run_id`, `behaviour`, `implementation`, `version`, `opts`. `docs/architecture/ingestion.md`, under `Cake.Pipelines`, says what each is for. |
| `Search.Query` | `Cake.Search.Query` | Composable query builder. Fields: `index` (enforced), `size` (default 10), `must`, `should`, `filter` (each default `[]`), `min_score` (default `nil`). |
| `Search.Hit` | `Cake.Search.Hit` | Backend-agnostic search hit. Every backend maps its native hit type into this struct at the boundary. Fields: `id`, `score`, `source`. |
| `Search.Result` | `Cake.Search.Result` | Normalized search result. Carries retrieval unit, the `index` (collection name) it came from, backend score, CAKE-computed scores (cosine, relevance), hit provenance (search vs. expansion), search conditions, and prompt index. Single carrier of all retrieval metadata through the pipeline. |
| `Search.Provenance` | `Cake.Search.Provenance` | Search conditions attached to each `Search.Result`: search type, query text, decomposition traceability (`decomposed`, `original_query`, `sub_question_index`), and `embedding_model` — the model the query vector was embedded under, from the `:embedding_model` search opt (the stored vector's model is on the retrieval unit). |
| `Responses.Result` | `Cake.Responses.Result` | Output struct from post-generation processing. Fields: `raw_text`, `final_text`, `chunk_map`, `citations`, `media` (always `[]` — a stub stage), `actions`, `assigns` (always `%{}` — nothing writes it), `warnings`. `Cake.Conversation` broadcasts `final_text`, `citations`, `actions` and `warnings` in `{:response_ready, _}`, and the chat renders all four. `docs/architecture/conversation.md`, under `Cake.Responses`, says how each is built. |
| `Conversation.State` | `Cake.Conversation.State` | Internal state for the `Conversation` GenServer. Enforced keys: `id`, `embedder`, `response_model`, `provider`, `gds`, and the three decomposition budgets `max_context_tokens` (for accumulated answers/steps), `max_self_ask_iterations` and `max_ircot_iterations` (round caps) — the budgets are enforced rather than defaulted, so the struct holds no copy of their defaults. `Conversation.build_state/1` takes each from its opts, then from config, and where the config key is unset falls back to a module attribute in `Cake.Conversation` that repeats the `config/config.exs` value (4096, 5 and 5); `Cake.Prompt` has a 4096 of its own for callers that pass no `:max_context_tokens`. Those copies can drift from `config.exs`. Also carries the collaborator modules (`embeddings`, `generation`, `responses`, `decomposition`), the turn FSM fields (`state`, `pending`, `turn_ref`, `turn_pid`, `queued_question`), the `owner_ref` monitor on the optional `:owner` pid, search results, message history, chunk map, citations, and accumulated errors. |
| `Books.PageContent` | `Cake.Books.PageContent` | Elixir-side struct the Rust PDF NIF decodes into (via NifStruct): one page's extracted text and page number. |
| `Books.PdfExtraction` | `Cake.Books.PdfExtraction` | Elixir-side struct the Rust PDF NIF decodes into: the full extraction result (pages, skipped pages, title). |
| `Books.SkippedPage` | `Cake.Books.SkippedPage` | Elixir-side struct the Rust PDF NIF decodes into: a page that could not be extracted, with its page number and a `reason` string. |
| `Decomposition.Result` | `Cake.Decomposition.Result` | Outcome of decomposing a question. Fields: `original_question` (enforced), `strategy`, `sub_questions` (`%{question, depends_on}` entries), `question_index` (positional index → entry, which `Search.Provenance` refers to). "Query Decomposition" in `docs/architecture/conversation.md` says what each strategy means and what `new/2` validates. |

### Embedded Schemas (LiveView forms)

| Struct | Module | Purpose |
|---|---|---|
| `QuestionForm` | `CakeWeb.ChatLive.QuestionForm` | Embedded schema validating the chat question and mode (`:auto`/`:manual`). |
| `SelectionForm` | `CakeWeb.ChatLive.SelectionForm` | Embedded schema validating document selection as a non-empty subset of the offered candidate IDs. |

---

## Behaviours and Implementations: Complete Inventory

Behaviours in Cake define module-level contracts. The question they answer is "which *module* is responsible for this capability?" Use a behaviour when dispatch is by module identity.

| Behaviour | Module | Purpose | Current Implementations |
|---|---|---|---|
| `Cake.GDS` | `lib/cake/gds.ex` | Module-level contract for a Generic Data Structure. Callbacks: `collection_name/0`, `search_fields/0`, `load_from_hits/1`, and the optional `expand_with_neighbors/2` (`use Cake.GDS` supplies an identity default). | `Cake.Books.ParsedBook`, `Cake.Documents.ParsedDocument` |
| `Cake.Books.Pipeline` | `lib/cake/books/pipeline.ex` | Ingestion behaviour for book-like documents. Callbacks: `load_binary/1`, `parse/1`, `format/0`, `success_message/0` (`format/0` is required, but nothing calls it today). | `Cake.Books.Pdf.Pipeline` |
| `Cake.Documents.Pipeline` | `lib/cake/documents/pipeline.ex` | Ingestion behaviour for programming documentation. Callbacks: `download/1`, `persist_raw_docs/2`, `parse/2`, `success_message/1`, and the optional `retry_from_raw/2`. | `Cake.Documents.Hexdocs.Pipeline` |
| `Cake.Embeddings.Behaviour` | `lib/cake/embeddings/behaviour.ex` | Contract for embedding services: `embed/3`. | `Cake.Embeddings` (OpenAI impl, in `lib/cake/embeddings.ex`) |
| `Cake.Generation` | `lib/cake/generation.ex` | Contract for LLM completion services: `complete/3` and `complete_json/3` (schema-constrained JSON). | `Cake.Generation.OpenAI`, `Cake.Generation.Anthropic` (stub) |
| `Cake.Decomposition` | `lib/cake/decomposition.ex` | Contract for query-decomposition strategies: retrieval-free `decompose/2`, returning `{:ok, Decomposition.Result.t()}` or `{:error, reason}`. | `Cake.Decomposition.LLM` |
| `Cake.Search.Backend` | `lib/cake/search/backend.ex` | Contract for search backends: read, write and collection lifecycle. Callbacks: `search/1` (a `Query` in, `{:ok, [Hit.t()]}` or `{:error, search_error()}` out), `index_document/3`, `delete_document/2`, `create_collection/2`, `list_collections/0`. | `Cake.Search.Backend.OpenSearch` |
| `Cake.Responses.Behaviour` | `lib/cake/responses/behaviour.ex` | Contract for post-generation response processing: `process/3`. | `Cake.Responses` |
| `Cake.Books.Adapters` | `lib/cake/books/adapters.ex` | Contract for raw binary storage of book files. Callbacks: `read/1`, `write/2`, `exists?/1`, `delete/1`, each taking the storage key `build_key/3` produces. | `Cake.Books.Adapters.Disk`, `Cake.Books.Adapters.S3` |

---

## Protocols and Implementations: Complete Inventory

Protocols in Cake define value-level contracts. The question they answer is "what does *this value* know how to do?" Use a protocol when dispatch is by struct type.

| Protocol | Module | Purpose | Current Implementations |
|---|---|---|---|
| `Cake.Promptable` | `lib/cake/promptable.ex` | Renders a struct as prompt context for the LLM. Each implementation defines how its data should appear in the numbered context block. | `Cake.Books.Chunk`, `Cake.Documents.ParsedDocument` |
| `Cake.Citable` | `lib/cake/citable.ex` | Extracts citation metadata from a struct. Returns a map with exactly five keys: `id` (a string, normally the record's UUID), `label`, `source_ref`, `preview`, and `extras`. | `Cake.Books.Chunk`, `Cake.Documents.ParsedDocument` |

---

## Laws Specified in LawSpec

Some modules' laws are stated in [LawSpec](https://github.com/brain-fuel/lawspec) under `lawspec/`, a Mix project of its own that the `laws` CI job runs. `lawspec/README.md` says what each specification covers, law by law, and how to change one.

| Module | Specification |
|---|---|
| `Cake.Decomposition.Result` (`new/2`, `topological_order/1`) | `lawspec/laws/decomposition.lawspec` |
| `Cake.Citations` (`extract/2`) | `lawspec/laws/citations.lawspec` |
| `Cake.Responses` (`process/3`, `build_citation_map/1`) | `lawspec/laws/responses.lawspec` |
| `Cake.Candidates` | `lawspec/laws/candidates.lawspec` |
| `Cake.Prompt`: context assembly | `lawspec/laws/prompt_context.lawspec` |
| `Cake.Prompt`: token budgets and the two driver protocols | `lawspec/laws/prompt_drivers.lawspec` |
| `Cake.Search.Query`'s builders and `Backend.OpenSearch.to_query_map/1` | `lawspec/laws/search_query.lawspec` |
| `Cake.Generation` (the contract, as an ability) | `lawspec/laws/generation.lawspec` |

---

## Configuration Keys

The domain-level `:cake` application-env keys that `lib/` reads, grouped by consumer. A value given is the `config/config.exs` default unless the entry names another file; neither provider-transport block is in `config.exs`: `Cake.Generation.OpenAI` is set in `dev.exs`, `test.exs` and `runtime.exs`, and `Cake.Embeddings` in `dev.exs` and `runtime.exs` (the tests that need it install it with `Application.put_env`). This is not every key. Left out: the framework blocks (`Cake.Repo`, `CakeWeb.Endpoint`, `Cake.Mailer` and `Oban`), `:dns_cluster_query` (read, like `Oban`, in Cake.Application, which is `@moduledoc false`), `:ecto_repos` (read by `Cake.Release`), `:dev_routes` (read by `CakeWeb.Router` at compile time), and the Snap cluster's `username` and `password`.

- **Models and providers.** `:default_embedding_model` (`text-embedding-ada-002`; read by `UploadLive` and `SearchLive`), `:default_embedding_dimension` (1536; read only by `Backend.OpenSearch.build_mapping/1`), `:default_provider` (`:openai`; `UploadLive`, `SearchLive`). `:default_response_model` is set but read by nothing in `lib/`. `config :cake, Cake.Conversation` (`gds`, `embedder`, `response_model`, `provider`) is what `ChatLive` starts conversations from.
- **Provider transports.** `config :cake, Cake.Embeddings` — `:openai_key`, `:base_url`, `:req_options` (a `Req.Test` plug in tests, empty in prod). `config :cake, Cake.Generation.OpenAI` — `:openai_key`, `:response_url` (the Responses API endpoint), and an optional `:plug` (a `Req.Test` plug in tests, unset in prod). `:embeddings_module` swaps the whole module for the pipelines (`Cake.Embeddings.Mock` in `config/test.exs`); the pipelines read it at call time.
- **Search.** `:search_collections` (the boot-time `{name_module, mapping_schema}` pairs), `config :cake, Cake.Search.Deployment` (the Snap cluster: one URL, set in `config/config.exs` and repeated in `dev.exs`, with nothing in `prod.exs` or `runtime.exs`, which `docs/architecture/deployment.md` says is what keeps the release from booting in prod; `http_client_adapter: Cake.Search.HTTPClientStub` in test), and `:search_backend` — set in no config file; `Backend.backend/0` defaults it to `Backend.OpenSearch`, and tests inject the Mox mock with `Application.put_env`. `:skip_search_backend` makes `Pipelines.add_to_search_backend/3` pass records through unindexed, and makes the two retry-path indexers in `Books.Pipeline` and `Documents.Pipeline` return `:ok` without indexing; `test_helper.exs` sets it for every run; `Cake.SearchIntegrationCase` turns it off for the real-cluster suites and does not turn it back on, and the two `pipelines_search_backend` suites (examples and properties) turn it off, and restore it afterwards, to drive indexing through the Mox backend.
- **Book storage.** `:book_storage_adapter` (`Disk` by default, `S3` in prod, `Mock` in test), `:book_storage_tenant` (the tenant segment of storage keys, `"default"`; `BOOK_STORAGE_TENANT` in prod, `config/runtime.exs`), `:book_storage_root` (the Disk adapter's directory, default `priv/book_storage`), `:book_storage_s3_bucket` (`config/runtime.exs`, from the environment).
- **Uploads.** `:max_zip_expanded_bytes` (268 435 456, i.e. 256 MB: the most the PDF entries of one ZIP upload may declare uncompressed in total) and `:max_zip_entries` (10 000 entries per archive, PDF or not), read by `Cake.Books.ZipExtractor` at call time, which also carries a matching compiled-in default for each.
- **Decomposition.** `:decomposition_max_context_tokens` (4096), `:max_self_ask_iterations` (5), `:max_ircot_iterations` (5), `:max_sub_search_concurrency` (4), and `:sub_search_timeout` (30 000 ms), all set in `config/config.exs`; `Cake.Conversation` also carries a matching compiled-in default for each.
