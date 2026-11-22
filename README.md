---
title: "Cake — RAG Framework for Enterprise Document Q&A"
tags: [cake, rag, elixir, phoenix, opensearch, architecture, domain-model]
date: 2026-10-01
domain: architecture, reference
source: project-maintainer
---

# Cake

Cake is a RAG (Retrieval-Augmented Generation) framework built in Elixir/Phoenix. It ingests enterprise documents, stores embeddings in OpenSearch, and surfaces answers through a Phoenix LiveView chat interface. The immediate use case is a document Q&A tool for enterprise customers whose document formats include PDF, Word, Excel, CSV, and JPG. The demo-critical path is PDF ingestion, LiveView chat UI, and citation display. Other document formats are explicitly post-demo.

---

## Domain Model: GDS, Raw Data, and Retrievables

Cake's domain model is organized around three categories of data structure, each serving a different role in the ingestion-to-retrieval pipeline. Understanding these categories is a prerequisite for understanding the architecture.

### Generic Data Structure (GDS)

A GDS is a *category of document* that Cake knows how to ingest, search, and cite. It is not a single schema — it is a named grouping that encompasses one or more Ecto schemas, a pipeline behaviour, and a set of protocol implementations. The GDS is the unit of domain identity: when you say "Cake supports books," you mean the `ParsedBook` + `Chunk` GDS exists.

Each GDS answers the question: *Why is the customer interested in this kind of documentation, and what is the atomic unit they'd want returned from a search?* The answer determines the GDS's shape — single-schema or parent/child — and everything downstream follows.

Current GDSes:

- **`ParsedBook` + `Chunk`** — for book-like documents (PDFs, future EPUBs, Word docs). Parent/child pair where `Chunk` is the retrieval unit.
- **`ParsedDocument`** — for programming documentation (hexdocs, future javadocs, Rustdocs). Single schema that is its own retrieval unit.

### Raw Data Structs

Raw data structs hold the original fetched content before it is parsed into a GDS. They exist to support the "raw data first" principle: persist what you fetched so you can re-parse later when heuristics improve, without re-downloading.

Current raw data structs:

- **`Cake.Documents.Hexdocs.Hexdoc`** — stores raw Elixir source cloned from the elixir-lang/elixir repository. Intermediate storage between download and parsing into `ParsedDocument`.

### Retrievables (Searchable Units)

A retrievable is the atomic schema that maps one-to-one to an OpenSearch document. It is the unit that search returns and that citations point at. The retrievable may or may not be the same schema as the GDS identity module.

Current retrievables:

- **`Cake.Books.Chunk`** — for the `ParsedBook` GDS. The book-level `ParsedBook` holds metadata; the chunk is what search returns.
- **`Cake.Documents.ParsedDocument`** — for the `ParsedDocument` GDS. The GDS is its own retrievable because a documentation entry is already atomic.

---

## Cardinality: How GDSes, Data Structures, and Pipelines Relate

These four cardinality relationships are stated explicitly because the rest of the architecture assumes them, and the distinctions get subtle once more than one GDS is in play.

**GDS ↔ ingestion pipeline behaviour: 1:1.** Each GDS has exactly one pipeline behaviour that targets it, and each pipeline behaviour produces exactly one GDS. `Cake.Books.Pipeline` targets the `ParsedBook` + `Chunk` GDS; `Cake.Documents.Pipeline` targets the `ParsedDocument` GDS. This is why no framework-level `Cake.Ingestion` master behaviour exists — the GDS *is* the unit of pipeline grouping.

**GDS → data structures: 1:many.** A GDS can be composed of multiple related Ecto schemas. The `ParsedBook` + `Chunk` GDS has two data structures (parent and child), where `Chunk` is the retrieval unit. The `ParsedDocument` GDS has one data structure and is its own retrieval unit.

**Data structure → pipeline implementation: 1:1 per source.** Each pipeline implementation produces records of exactly one data structure shape per run. `Cake.Books.Pdf.Pipeline` produces `ParsedBook` + `Chunk` records from a PDF. A future `Cake.Books.Epub.Pipeline` would produce the same shape from an EPUB.

**Pipeline behaviour → implementations: 1:many.** Each pipeline behaviour can have any number of concrete implementations. Adding a new source format is an additive operation against a stable behaviour; it never reshapes the GDS.

### Worked Examples

- **`ParsedBook` + `Chunk`:** One GDS, two data structures (parent/child), one pipeline behaviour (`Cake.Books.Pipeline`), currently one implementation (`Cake.Books.Pdf.Pipeline`). Retrieval unit is `Chunk`, not `ParsedBook`.
- **`ParsedDocument`:** One GDS, one data structure, one pipeline behaviour (`Cake.Documents.Pipeline`), currently one implementation (`Cake.Documents.Hexdocs.Pipeline`). The GDS is its own retrieval unit.

---

## Architecture: Application Layers

The system is organized into four layers. Each layer has a clear responsibility boundary, and modules within a layer communicate through defined interfaces (behaviours, function signatures, GenServer protocols). The guiding principle is that **modules are organized by what they're responsible for, not by what infrastructure they share.** Two functions that both call an HTTP API don't belong together unless they operate on the same domain concept and change for the same reasons.

### Layer 1: Ingestion — Two Parallel Pipeline Systems

The ingestion layer has two pipeline behaviours because the two GDSes have fundamentally different parsing requirements, metadata schemas, and chunking strategies. Each GDS owns its own ingestion contract.

**`Cake.Documents.Pipeline`** is the behaviour for ingesting programming documentation. Its GDS is `ParsedDocument`. Callbacks: `download/1`, `persist_raw_docs/2`, `parse/2`, `success_message/1`, and optionally `retry_from_raw/2`. The module also contains the `ingest/4` orchestrator that sequences callbacks into a stream pipeline — download → persist raw → parse → persist parsed → embed → index — plus an `ingest_with_sweep/5` variant that follows the run with `sweep`-based retry passes. Current implementation: `Cake.Documents.Hexdocs.Pipeline`. Two dedup checks run inside the stages: the generic persist-parsed stage skips attrs whose `(source, version, package, title)` already exists (`ParsedDocuments.parsed_doc_exists?/4`), and the Hexdocs `persist_raw_docs/2` skips `(module, version)` pairs already stored (`Hexdocs.hexdoc_exists?/2`).

**`Cake.Books.Pipeline`** is the behaviour for ingesting books and book-like documents. Its GDS is `ParsedBook` + `Chunk`. Callbacks: `load_binary/1`, `parse/1`, `format/0`, `success_message/0`. Like `Documents.Pipeline`, the module also contains its own `ingest/4` orchestrator and an `ingest_with_sweep/5` variant that follows the run with `sweep`-based retry passes. Current implementation: `Cake.Books.Pdf.Pipeline`, which uses a Rustler NIF (`parsebooks` Rust crate wrapping `pdf-extract`). The NIF's contract and `parse/1` are pinned against fixture PDFs in the `integration` CI job, and `load_binary/1` against a real S3-compatible store with the S3 adapter configured (`.claude/rules/integration-tests.md`). Two helper modules sit beside the behaviour: `Cake.Books.Persistence` owns the write path — `persist_books_and_chunks/2` takes the pair and the requested embedding model, looks the `file_hash` up and returns `{:duplicate, book}` for a `:completed` book whose every chunk was embedded under that model, resumes any other book behind the hash (another status, or `:completed` under another or an unknown model) with its existing chunks after clearing the vectors other models produced, and inserts a new book and its chunks otherwise (`insert_books_and_chunks/3` is that insert without the lookup; a run that loses the check-then-insert race to another is a duplicate only if the winner is already `:completed` under the requested model, and otherwise a `{:concurrent_ingest, winner_id}` persist failure for the sweep to retry) — and `Cake.Books.Retrieval` owns the read path that `ParsedBook` delegates its `load_from_hits/1` and `expand_with_neighbors/2` GDS callbacks to. The expansion returns, for each book, exactly the chunks within `offset` positions of a hit, once each, in ascending `chunk_index` order — a guarantee, so a caller knows which neighbours precede and follow a hit; the order of the books relative to each other is unspecified.

Both orchestrators are also pinned end to end in that job — a fixture PDF, or a real clone of one tagged Elixir release, through `ingest/4` into real Postgres rows and a real OpenSearch collection and back out through `Cake.Search` — with only the embedding provider substituted, plus `ingest_with_sweep/5`'s run-scoped retries and the Oban job driving the real Hexdocs pipeline (`Cake.IngestIntegrationHelpers` under `test/support/`; `.claude/rules/integration-tests.md`). The two take their arguments in different orders: Books is `ingest(embedding_service, format_pipeline, embedding_model, paths)`, Documents is `ingest(embedding_service, source_pipeline, version_tuple, embedding_model)`.

**`Cake.Pipelines`** provides shared infrastructure used by both pipeline types: `detuple_with_logging/3` filters `{:ok, _}/{:error, _}` streams and persists errors to `FailedIngest`, `log_and_persist_failure/3` persists one item's failure for a stage that handles outcomes itself, `add_to_search_backend/3` handles index upserts, and `sweep/3` implements a retry loop for item-level failures. A `Context` struct carries pipeline identity (behaviour, implementation, version) plus a per-run `run_id` through a run: the identity fields give error provenance, and `run_id` scopes `count_failures/1`, `finalize_ingest/3`, and `sweep/3` to one run so concurrent ingests of the same source never count or retry each other's failures. `Context` also carries an `opts` keyword, read for `:search_backend_timeout` (the per-record indexing deadline, default 5000 ms); both orchestrators build it with `opts: []` today.

There is deliberately no `Cake.Ingestion` behaviour unifying the two pipeline behaviours. They have different callback shapes because they answer different questions. Each GDS owns its own ingestion contract; unification is deferred indefinitely.

### Layer 2: Search and Retrieval

**`Cake.Search`** is a vanilla module owning Cake-internal search orchestration. It exposes three search entry points (`search_chunks/4`, `search_chunks_with_context/5`, and `search_docs/4` — the latter an alias of `search_chunks/4` retained for call-site clarity), each supporting three modes (`:keyword`, `:vector`, `:hybrid`). Hybrid is the default. The module reads the target index, search fields, hit hydration, and neighbor expansion from the GDS module passed via the `:gds` opt. It also owns the pure scoring utilities (`cosine_similarity/2`, `score_results/2`, `normalize_and_combine/1`, `sort_by_relevance/1`) that rank retrieved results. Its tunables are public accessors — `default_size/0` (30), `default_k/0` (30), `default_ef_search/0` (256), `default_keyword_weight/0` (0.8, the boost on the hybrid `should` clause) and `default_expand_offset/0` (2, the neighbor window `search_chunks_with_context/5` expands by) — and each is overridable per call: `:size`, `:k`, `:ef_search`, `:keyword_weight` and `:fields` (replacing the GDS's `search_fields/0`) in opts, and `expand` as the fourth positional argument of `search_chunks_with_context/5`.

**`Cake.Search.Backend`** is the behaviour for search backends. Each backend translates `%Cake.Search.Query{}` into its native query format, executes it, and maps results back into `[%Cake.Search.Hit{}]`. Injected via config (`Application.get_env(:cake, :search_backend)`), mockable with Mox. Current implementation: `Cake.Search.Backend.OpenSearch`.

**`Cake.Search.Query`** is a struct-based composable query builder. Struct fields: `index` (enforced), `size` (default 10), `must`, `should`, `filter` (all default `[]`), `min_score` (default nil). Builder functions: `new/2` (accepts `:size` and `:min_score`), `knn/5` (an optional `:ef_search`, emitted as the clause's `method_parameters.ef_search`; `Cake.Search` always passes it), `match/4`, `filter_term/3`, `min_score/2`, `size/2`. `Backend.OpenSearch.to_query_map/1` converts a Query into the nested map OpenSearch expects.

**`Cake.Search.Hit`** is the backend-agnostic search hit struct. Every backend maps its native hit type into `%Hit{}` at the boundary; downstream code (`load_from_hits/1`, result builders) works exclusively with hits. `Hit.id` is taken from the document's own `id` field in `_source`, not from the OpenSearch `_id`, so every indexer must store an `id` field — `Pipelines.add_to_search_backend/3` indexes each record under `record.id`.

**`Cake.Search.Deployment`** is the OpenSearch `Snap.Cluster` — connection management and index lifecycle only, not query logic. Query construction lives in `Cake.Search.Query`. At boot it reads `collections/0` (the `{name_module, mapping_schema}` pairs in `:search_collections`) and calls `create_collections_unless_exist/2`, which lists the cluster's collections and creates the missing ones with `Backend.OpenSearch.build_mapping/1`: the schema-derived mapping (`:text` → `text`; `:embedding` → an HNSW `knn_vector` on the `faiss` engine with cosine similarity, `ef_construction: 512`, `m: 16`; everything else `keyword`) plus `index.knn` and a 30 s `index.refresh_interval`. `init/1` starts a linked task that polls `Process.whereis/1` every 10 s until the cluster process is registered and only then creates the collections, and that path calls `Backend.OpenSearch` directly rather than through `Backend.backend/0`, so a second backend would get no boot-time collection creation.

**`Cake.Embeddings`** calls the configured embedding service (OpenAI by default). Implements `Cake.Embeddings.Behaviour` for Mox substitution. It embeds the text it is given verbatim — it does no title prepending itself. At ingestion time the pipelines prepend a title to the text before calling it (the chunk's `section_title` for books, the document `title` for docs); query-time callers embed the question as-is. Used at both ingestion time (by the pipelines) and query time (by `Cake.Conversation`, and directly by `CakeWeb.SearchLive`, which is why `CakeWeb` declares `Cake.Embeddings` as a boundary dep). Its live contract — a vector of the configured dimension, the usage shape, a 401 as an error tuple — is pinned against the real endpoint in the `llm` CI job (`Cake.EmbeddingsLiveTest` on `Cake.LiveLLMCase`; `.claude/rules/live-llm-tests.md`).

Indices are one-per-GDS on a shared OpenSearch cluster: `collection_name/0` returns a fixed name per GDS (currently `"chunks_of_books"` and `"docs"`), created at boot by `Cake.Search.Deployment`.

### Layer 3: Conversation — Stateful Multi-Turn RAG

This layer is organized around a single principle: **`Cake.Conversation` is the sole orchestrator, and every other module in the layer is a peer service that it calls.** The dependency graph is a DAG. Peer-to-peer knowledge is minimal and deliberate: `Prompt` and `Responses` consume `Cake.Search` result types, and `Cake.Decomposition.LLM` calls `Prompt.decomposition_prompt/1` and `Generation.complete_json/3`.

```
Conversation → Prompt
Conversation → Decomposition (opt-in; Decomposition.LLM → Prompt, Generation)
Conversation → Search (Cake.Search → Cake.Search.Backend → OpenSearch)
Conversation → Embeddings
Conversation → Generation
Conversation → Responses
```

**`Cake.Conversation`** is a GenServer managing single-conversation state: message history, retrieved chunks, chunk map, citations, accumulated errors. `start/1` spawns it under the `Cake.ConversationSupervisor` DynamicSupervisor; an optional `:owner` pid (ChatLive passes itself) is monitored so the conversation stops when its owner exits. A turn starts one of two ways, and neither blocks the caller: every slow stage runs in a task under `Cake.TaskSupervisor` and reports back by PubSub broadcast (`Cake.Conversation.Events`). `autoask/2` casts the full retrieve-and-generate loop; `manualask/2` replies `:ok` and retrieves candidate results (`[Search.Result.t()]`) in a `:retrieving` state, broadcasting them as `{:candidates_ready, _}` for the user to pick from — `select_docs/2` then supplies the Citable ids of the chosen candidates (chunk ids, for books; the web layer groups candidates by document and expands a document selection back into candidate ids via `Cake.Candidates`), rejects unknown ids synchronously, and otherwise replies `:ok` while generation proceeds in a task. When the `:decomposition` opt is set (a `Cake.Decomposition` implementation; default `nil`), an `autoask/2` turn that begins before any retrieval has completed (`search_results` still `nil`, its uninitialized sentinel) decomposes the question before searching — the first auto-mode turn. Manual mode never decomposes, and a manual turn's cached candidates suppress decomposition on later auto turns (see "Query Decomposition" below). Follow-up turns reuse cached search results rather than re-retrieving; a completed retrieval that found nothing (`[]`) is cached and reused like any other, distinguishable from the never-retrieved `nil`. The whole loop is pinned end to end against a real cluster in the `integration` CI job — `Cake.ConversationIntegrationTest` (plain, manual and cached turns), `Cake.ConversationDecompositionIntegrationTest` (all four decomposition strategies over a Mox collaborator) and `CakeWeb.ChatLiveIntegrationTest` (the LiveView round trip), on `Cake.ConversationIntegrationHelpers` — and with every collaborator live in the `llm` job (`Cake.ConversationLiveTest`, the staging-gate seed of #244); `.claude/rules/integration-tests.md` and `.claude/rules/live-llm-tests.md`.

**Events, queued turns, and error shapes.** `Cake.Conversation.Events` defines the four broadcast shapes on the `"conversation:#{id}"` topic (`Events.topic/1`): `{:state_change, state_name}` whenever the turn FSM moves (`:retrieving`, `:awaiting_selection`, `:generating`, `:idle` — an auto turn broadcasts `:generating` once before its combined retrieve-and-generate task and `:idle` when it finishes), `{:candidates_ready, candidates}`, `{:response_ready, %{response: text, citations: list}}`, and `{:error, reason}`. An `autoask/2` that arrives while a turn is `:generating` is stored in `queued_question` (a later one overwrites an earlier one) and replayed as a fresh turn when the current one completes; every other invalid transition has no clause and crashes the GenServer by design — the UI is expected to prevent it. `select_docs/2` rejects unknown ids with `{:error, {:unknown_candidate_ids, ids}}` and returns the conversation to `:idle`. A `:flat` fan-out fails the whole turn with `{:error, :sub_search_timeout}` or `{:error, {:sub_search_crashed, reason}}`. Collaborator failures are typed: `t:Cake.Decomposition.error_reason/0` is `{:invalid_response, _}` or `{:generation, _}`, and `t:Cake.Generation.error_reason/0` enumerates transport, timeout, rate-limit, auth, HTTP-status, malformed-response, malformed-JSON, empty-response, content-filter and provider errors. Four read-only calls — `GenServer.call(pid, :search_results | :chunk_map | :citations | :inspect)` — expose state for tests and tooling with no public wrapper; `:search_results` replies `[]` for the never-retrieved `nil`. The child spec is `restart: :temporary`, which is what makes the owner-exit stop final under `Cake.ConversationSupervisor`.

**`Cake.Prompt`** owns prompt engineering. Builds the messages list for the LLM (system prompt, conversation history, retrieved context as a numbered block, user question). Filters chunks by relevance floor and chunk ceiling, assigns dense 1..N indices. Also owns the decomposition-side prompts and budgeting: `decomposition_prompt/1` (the JSON-answering prompt `Decomposition.LLM` sends), `build_with_prior_answers/5` (folds accumulated sub-question/answer pairs into the system message for sequential resolution), `fit_answer_pairs/2` (evicts oldest pairs to fit the token budget), `estimate_tokens/1` (~4 chars/token estimate), the self-ask driver protocol — `self_ask_prompt/3` (the marker-teaching driver prompt with accumulated pairs folded in) and `parse_self_ask_response/1` (classifies the model's reply as a follow-up question or the final answer) — and the IRCoT driver protocol: `ircot_prompt/3` (the CoT driver prompt with accumulated reasoning steps and their retrieved context folded in), `ircot_schema/0` (the `reasoning`/`retrieval_query` JSON schema its structured replies must satisfy), and `parse_ircot_response/1` (classifies a validated step as continue-with-query or done). Both driver protocols are pinned against the production model in the `llm` CI job — `Cake.Prompt.SelfAskLiveTest` (marker usage and termination) and `Cake.Prompt.IRCoTLiveTest` (schema validity and the null terminator) — driven through `Prompt` and `Generation` alone; full interleaved turns through `Conversation` are #271's (`.claude/rules/live-llm-tests.md`). What needs no model is specified in LawSpec, in `lawspec/laws/prompt_drivers.lawspec` (#331): `estimate_tokens/1` as the length over four, rounded up, `fit_answer_pairs/2` against a reference model (the longest run of the newest pairs that fits the budget, and none on a budget of zero), which pairs and steps `build_with_prior_answers/5`, `self_ask_prompt/3` and `ircot_prompt/3` fold in, the IRCoT context carrying no `[N]` marker, and the two reply classifiers (`lawspec/README.md`). The rest of its public surface is the prompt text itself — `system_message_with_context/1`, `system_message_no_context/0`, `self_ask_system_message/0`, `ircot_system_message/0`, `decomposition_system_message/0` — plus `format_chunk/1` (one numbered context entry) and `history_messages/1`, which keeps only the last five exchanges. `prepare_context/2` returns `{indexed_chunks, context_quality}`, the quality being `:good` or `:none`; `Conversation` discards it today. A result with no relevance score never passes the floor, whatever the floor: `nil` is not a score of zero. Its context assembly is specified in LawSpec, in `lawspec/laws/prompt_context.lawspec` (#330): `prepare_context/2` against a reference model (the first `max_chunks` results at or above the floor, in input order, numbered from 1) with its bounds, defaults and the unscored-result rule, `format_chunk/1`, `history_messages/1` as the last five complete exchanges, and `build/4` as the system message, the recent history, then the question (`lawspec/README.md`). `parse_ircot_response/1` treats a blank `retrieval_query` as the terminator too, not only `null`.

**`Cake.Retrieval`** (planned) will own retrieval strategy: search, scoring, autorating. Currently these responsibilities are split between `Conversation` and `Cake.Search`.

**`Cake.Generation`** owns LLM completions. Two callbacks: `complete/3` (plain completion for the main answer) and `complete_json/3` (schema-constrained JSON completion, used by `Decomposition.LLM` and by `Conversation`'s IRCoT loop). Callers: `Conversation` and `Cake.Decomposition.LLM`. Defines `Cake.Generation` as a behaviour; `Cake.Generation.OpenAI` is the real implementation. `Cake.Generation.Anthropic` is a placeholder stub. `OpenAI`'s parsing of the Responses API wire format is pinned against the live endpoint in the `llm` CI job (`Cake.Generation.OpenAILiveTest`, and `Cake.Generation.OpenAIJSONLiveTest` for `complete_json/3` with the two schemas production sends); `Anthropic` gets the same suites when implemented. The contract itself is specified in LawSpec as an ability, in `lawspec/laws/generation.lawspec` (#333): whatever the provider replies, a successful completion never has empty text, its token counts are never negative, its finish reason is one of the four documented ones, and the parsed JSON of a successful `complete_json/3` fits the schema asked for. Those laws run against `Cake.Generation.OpenAI` over a stubbed provider and against the scripted fake that other specifications use in its place (`lawspec/README.md`, "Abilities and handlers").

**`Cake.Responses`** handles post-generation processing. Builds the chunk map (integer index → chunk metadata), parses citation markers through `Cake.Citations`, keeps one citation per retrieval unit (by `Cake.Citable` `:id`, so a unit at two prompt indices is cited once, under the index whose marker appears first), renumbers the survivors 1..N by first appearance with no gaps, and rewrites the `[N]` markers in the text to match: two markers for one unit show the same number, and hallucinated markers take no number, are removed and are reported as warnings. It derives one `:download` action per unique non-`nil` citation `source_ref` (citations without one yield no action), and assembles the final structured response. `Cake.Responses.Behaviour` defines the contract; `Cake.Responses.Result` is the output struct. `process/3`'s and `build_citation_map/1`'s laws are specified in LawSpec, in `lawspec/laws/responses.lawspec` (#328): the chunk map, the citation list and its numbering, the final text against a reference model of marker rewriting and whitespace tidying, warnings, download actions, and the untouched `raw_text` and empty `media` (`lawspec/README.md`).

**`Cake.Citations`** is a pure function module. Parses `[N]` markers from response text, resolves them against the chunk map, separates hallucinated indices out (they come back alongside the valid list, and `Responses` turns them into warnings), and deduplicates, preserving first-appearance order. The numeric renumbering and sorting happens inside `Cake.Responses`, which renumbers the survivors by first appearance. A `[0]` marker is always hallucinated, since `Cake.Prompt` numbers the chunk map from 1, so it comes back as index `0` and `Responses` reports it as `{:hallucinated_citation, 0}`. `extract/2`'s laws are specified in LawSpec, in `lawspec/laws/citations.lawspec` (#327): valid citations and hallucinated indices, each in first-appearance order against a reference model built from the text's segments, totality, leading zeros, and the `[0]` rule (`lawspec/README.md`).

#### Query Decomposition

**`Cake.Decomposition`** is the behaviour for query-decomposition strategies. Its single callback `decompose/2` is retrieval-free — question in, `{:ok, Decomposition.Result.t()}` or `{:error, reason}` out. Strategies never touch `Search` or `Embeddings`; `Conversation` performs all retrieval and feeds results back in as data.

**The Result.** `Decomposition.Result` carries the outcome: `strategy` is `:none` (atomic), `:flat` (independent sub-questions), `:sequential` (at least one `%{question, depends_on}` entry carries a dependency; `new/2` validates the DAG acyclic, and `topological_order/1` yields the resolution order), `:self_ask` (the model discovers its own follow-up questions at resolution time, so `sub_questions` is empty; `new/2` never derives it — a strategy module marks it explicitly), or `:ircot` (the model interleaves retrieval with chain-of-thought reasoning, emitting a retrieval query per reasoning step; like `:self_ask`, `sub_questions` is empty and a strategy module marks it explicitly).

**Its laws.** `new/2` and `topological_order/1` are also specified in [LawSpec](https://github.com/brain-fuel/lawspec), in `lawspec/laws/decomposition.lawspec` (#323): string normalization, the dense positional `question_index`, the strategy derivation, rejection of cycles and of out-of-range or self dependencies, and the resolution order — every index once, dependencies first, and the smallest ready index next, checked against a reference model written in the spec. LawSpec compiles them into StreamData properties. `lawspec/` is its own Mix project because LawSpec's BEAM targets require Erlang/OTP 29; it compiles only the Cake files its specifications cover (`@cake_sources` in `lawspec/mix.exs`) and runs in the `laws` CI job (`lawspec/README.md`).

**Strategies and tiers.** `Cake.Decomposition.LLM` is the shipped strategy: prompt from `Prompt.decomposition_prompt/1`, schema-constrained output via `Generation.complete_json/3`; a Mox mock stands in for tests, and `Cake.Decomposition.LLMLiveTest` pins the atomic and flat branches against the real provider in the `llm` CI job. Its JSON schema (`LLM.schema/0`) emits atomic-or-flat only — a `:sequential` result currently requires a strategy that emits dependency edges, and a `:self_ask` or `:ircot` result a strategy that marks it. The `Conversation`-side machinery for all five tiers (atomic, flat, sequential, self-ask, IRCoT) is in place. `Conversation` calls `decompose(question, [])`, so the shipped strategy runs on its own compile-time defaults — `Cake.Generation.OpenAI` and `"gpt-4o-mini"` — not the conversation's `:generation` collaborator or `response_model`.

**Integration.** Opt-in via `Conversation`'s `:decomposition` opt — and the web app does not opt in today: `config :cake, Cake.Conversation`, which `ChatLive` builds its start opts from, sets no `:decomposition`, so production conversations run with `decomposition: nil`. The implemented trigger is cache state, not turn count: decomposition runs when an `autoask/2` turn begins before any retrieval has completed (`search_results == nil`) — the first auto-mode turn. Manual mode never decomposes, and any completed retrieval suppresses it: a prior manual turn's cached candidates and an empty completed retrieval (`[]`) alike. An atomic result searches the original question once. A `:flat` decomposition fans one embed+search per sub-question out concurrently under `Cake.TaskSupervisor` (capped by `config :cake, :max_sub_search_concurrency`, default 4; per-search timeout from `config :cake, :sub_search_timeout`, default 30s; failure is all-or-nothing) and merges the deduplicated results into a single context. A `:sequential` decomposition resolves least-to-most in topological order, each prompt carrying the accumulated prior question/answer pairs within the `:max_context_tokens` budget (default from `config :cake, :decomposition_max_context_tokens`, 4096; oldest pairs evicted first); the final answer is generated over the merged context plus the surviving answers. A `:self_ask` decomposition interleaves instead of planning upfront: the self-ask driver prompt puts the original question to the model, each "Follow up:" it emits is embedded, searched, and answered over the retrieved context (the pair folding into the next driver prompt, same `:max_context_tokens` budget), and the turn ends when the model emits "So the final answer is:" — or, after `:max_self_ask_iterations` follow-up rounds (default from `config :cake, :max_self_ask_iterations`, 5), by synthesizing the answer over the merged context plus the accumulated pairs. An `:ircot` decomposition interleaves retrieval with chain-of-thought reasoning: each round the model produces one reasoning step as schema-constrained JSON (`Generation.complete_json/3` against `Prompt.ircot_schema/0`, separating `reasoning` from `retrieval_query`), the retrieval query is embedded and searched, and the results are injected as context for the next step's driver prompt (accumulated steps budgeted by the same `:max_context_tokens`); the turn ends when the model sets `"retrieval_query"` to null — the terminating step's reasoning is the final answer — or, after `:max_ircot_iterations` rounds (default from `config :cake, :max_ircot_iterations`, 5), by synthesizing the answer over the merged context.

**Traceability.** Each merged result's `Search.Provenance` is stamped `decomposed: true` with the `original_query` and a `sub_question_index` into `Decomposition.Result`'s `question_index`, so citations trace back to the specific sub-question that surfaced them. Self-ask follow-ups and IRCoT reasoning steps have no `question_index` entries, so there the index counts rounds in discovery order, zero-based — follow-up rounds for self-ask, reasoning/retrieval rounds for IRCoT. Intermediate answers have their `[N]` markers stripped before being folded into the next prompt, and so do the self-ask final answer on the marker path and the IRCoT terminating reasoning: a `:self_ask` turn that ends by marker or an `:ircot` turn that ends by `null` reaches `Responses.process` with no markers and yields empty `citations`. Only the cap-exhaustion synthesis paths cite the merged context.

#### The Per-Turn Pipeline

Every arrow originates from `Conversation`:

1. User message arrives at `Conversation`.
2. `Conversation` resolves search results: cached results are reused; otherwise it embeds the question and searches via `Cake.Search.search_chunks_with_context/5`. With `:decomposition` set on such a no-cache `autoask` turn, `Decomposition.decompose` runs first — an atomic result searches the original question once; otherwise one embed+search per sub-question (concurrent for `:flat`, topologically ordered with accumulated prior answers for `:sequential`, model-driven one follow-up at a time for `:self_ask`, one retrieval query per JSON reasoning step for `:ircot`), merged into one context. Manual mode retrieves through `manualask/2` and never decomposes.
3. `Conversation` → `Prompt.prepare_context` (filter/rank/index chunks).
4. `Conversation` → `Prompt.build` (assemble messages list).
5. `Conversation` → `Generation.complete` (LLM call).
6. `Conversation` → `Responses.process` (chunk map, citations, structuring).
7. `Conversation` updates state and notifies the frontend.

On follow-up turns, retrieval is skipped — cached chunks are reused with the new question appended to message history.

### Layer 4: Web — Phoenix LiveView Chat Interface

**`CakeWeb.ChatLive`** is the user-facing chat UI. It starts a `Conversation` GenServer and subscribes to its PubSub topic for state-change, candidates-ready, response-ready, and error broadcasts. The conversation's lifetime is the page's: ChatLive starts it as `:owner`, so it stops when the LiveView exits, and monitors it the other way round. If the conversation dies first, the page survives: the `:DOWN` handler apologises, drops the pid (`convo_pid: nil`), keeps the message history on the page, disables the question form (a question submitted in the race, before the `:DOWN` is handled, is dropped from the history rather than sent to the dead pid; the one residual window is a conversation that dies after an auto-mode question passed ChatLive's liveness check but before `autoask/2`'s cast is delivered, which keeps the question and is reported by the `:DOWN` like a crash mid-turn, until `autoask/2` acknowledges acceptance — #311), and offers a "Start a new conversation" action that starts a fresh `Conversation` with no memory of the earlier turns (restoring that state is #39). Domain-level candidate grouping and chunk-ID extraction are delegated to **`Cake.Candidates`** (a top-level boundary of its own, see "Module Boundaries"): it groups candidates by document id (the `Cake.Citable` `source_ref`, or the `id` of a unit with none), summarises a group for display — a title, a 100-character preview and a page label that counts distinct pages, so several chunks on page 5 read "PDF page 5" — and expands a selection of documents back into candidate ids. Its laws are specified in LawSpec, in `lawspec/laws/candidates.lawspec` (#329): grouping against a reference model and as a permutation of its input, expansion against a reference model of a selection and distributing over appended selections, the summary's title, preview and page label, and a group for every candidate whatever its id (`lawspec/README.md`). Two embedded-schema form modules live under `chat_live/`: **`QuestionForm`** (question + mode validation) and **`SelectionForm`** (document-selection validation with subset checking against available IDs).

**What the chat shows.** The screen takes the wide column and has three parts: the heading, the messages, and a bar that stays at the bottom of the screen while the messages scroll above it. A question and its answer are daisyUI chat bubbles on opposite sides, each under its label ("You", "Cake"); the answer is plain text with its line breaks kept (Markdown is not rendered). The sources an answer cites are chips under it, numbered as the `[N]` markers in its text are: a chip's label opens the source's preview on hover, from the keyboard and by tap, and its arrow links to the download. The previews are placed against the row of chips, not centred on their own chip, so one for a narrow chip cannot run off the edge of a phone. The two replies ChatLive adds itself (a failed turn, a conversation that ended) are `notice/1` errors, not bubbles. The messages are a log (`role="log"`), so a screen reader announces each one as it arrives. Before the first question the messages are an `empty_state/1` with a link to Upload. The bar holds whichever of four things the conversation's state calls for: the composer (the question box, Send, and the "Manual selection" toggle with a line saying what it does; Enter sends, and Send is disabled until there is a question and while there is no conversation); a `working/1` line while the conversation works, "Searching the documents..." for `:retrieving` and "Working on an answer..." for `:generating` (an auto turn reports `:generating` for the whole of it, the search included); "Use selected" and "Use all" while documents are being chosen, the candidates themselves being cards above it, one per document, with a checkbox, the title, the chunk count, the page label and the preview ("Use selected" is disabled while none is ticked); and, once the conversation has ended, a warning `notice/1` and "Start a new conversation" above the disabled composer. One JavaScript hook, `FollowNewest` (`assets/js/follow_newest.js`), keeps the newest message in view as the page grows, and stops while the reader has scrolled up; a list of candidates taller than half the screen opens at its heading instead of its end. Where there is a mouse, it also puts the cursor back in the question box when the box returns after an answer.

**`CakeWeb.UploadLive`** is the book-upload UI: accepts PDF and ZIP uploads (ZIP archives are unpacked to PDFs via `Cake.Books.ZipExtractor`), writes the files through the configured `Cake.Books.Adapters` storage adapter, then runs `Cake.Books.Pipeline.ingest/4` with `Cake.Books.Pdf.Pipeline` as an async task. The upload limits (20 archives of up to 100 MB each) bound compressed bytes only; `ZipExtractor` bounds expansion. Before inflating anything it parses the archive's central directory itself, rejecting an archive whose end record declares more than `:max_zip_entries` entries before reading any of them, and one whose PDF entries declare more than `:max_zip_expanded_bytes` uncompressed in total (it does not use `:zip.list_dir/1`, which turns every entry name into a charlist). It then inflates only the PDF entries itself, with `:zlib.safeInflate/2`, and abandons any entry whose output passes the size it declared, so an archive that understates its sizes is rejected too. `UploadLive` reports a rejected archive with the limit it broke: as the page's error when nothing else in the batch can be ingested, otherwise in a warning listing each rejected archive while the rest of the batch is ingested. What the user sees: a drop zone that is also the file picker (a plain button at phone width) stating what is accepted and the limits, and a separate folder option; a queue where each file has its name, size, upload progress, a remove button and its own error, with the submit button disabled while any queued file is refused; while ingesting, a `working/1` line that says there is no progress to show and to keep the tab open on the page, because ingestion runs in a task the LiveView owns and stops when the page is left; and when it finishes, a `notice/1` with the figures (indexed, failed, non-PDF files skipped: a success, a warning when something failed, an error when nothing was ingested, and plain information when nothing was indexed and nothing failed, as when every file was already in the library), "Upload more", a link to the documents list unless nothing was ingested (a file that fails before it is stored is not listed there) and, when something was indexed, a link to the chat. The figures are the pipeline's: sections indexed, not files. The rejected-archives warning and the page's error are `notice/1`s too.

**`CakeWeb.SearchLive`** is a direct search UI at `/search`: it embeds the query itself (`Cake.Embeddings` with `:default_provider` and `:default_embedding_model`), runs `Cake.Search.search_chunks_with_context/5` against the `Cake.Books.ParsedBook` GDS, which it hardcodes, and renders the grouped results without starting a conversation. Each book is a card: its title links to the download, and its matching pages are chips, each showing the first 200 characters of its chunk on hover. Its states are the shared state components: a search in flight is a `working/1` line, a failed one a `notice/1` with a generic message (the reason is only logged), and one that finished and found nothing an `empty_state/1` naming the query.

**`CakeWeb.ParsedBookLive.Index`** is the documents list at `/documents`: a read-only table of what has been uploaded, newest first (`Cake.Books.list_parsed_books_newest_first/0`, which returns a map of the six fields the list shows for each book, not a `ParsedBook`), with each document's title (a link to its page), page count, ingestion status as a `status_badge/1`, upload time in UTC and a download link to `/books/download/…`, named after its document for a screen reader. The module keeps the name `mix phx.gen.live` gave it; to a user the screen is "Documents". The list is read when the page opens and again when the Refresh button is pressed, and the page says when it was last read: nothing announces that an ingest finished, since the ingestion layer broadcasts nothing. An empty corpus is an `empty_state/1` with a link to Upload. Below the `sm` breakpoint the Pages and Uploaded columns are hidden and the download link is an icon. Every row shows what the database says, so the known defects show through: a book can read "failed" after a retry fixed it (#305), a scanned PDF "completed" with nothing searchable (#293), and a title the parser got wrong is shown wrong (#86).

**`CakeWeb.ParsedBookLive.Show`** is one document at `/documents/:id`: the same fields, plus its authors, its word count and the number of chunks it was split into (`Cake.Books.count_chunks/1`), as a `list/1`, with the download as the page's primary button. A well-formed id that matches no document is a 404; one that is not a UUID is a 400. There is no create, edit or delete on either page.

**`CakeWeb.Titles`** is how a document's title is displayed in the chat and on the documents pages (the search screen shows the stored title as it is): `display/1` removes control and replacement characters and Word's "Microsoft Word - " prefix, and trims; a missing title, or one with nothing left that can be seen, is "Untitled". It corrects nothing else (#86). `display_citation_label/1` is the chat's variant for a citation's label ("title, p. N"): the same cleanup, with the page spelled out as ", PDF page N". The documents pages do not use it, so a stored title that mentions a page keeps its wording there; the chat runs candidate titles through it as well as citation labels, so such a title reads differently in the chat.

**`CakeWeb.BooksController`** serves authenticated book downloads at `/books/download/*file_path`: only keys recorded as a `ParsedBook`'s `source_file_path` that also pass `Cake.Books.Adapters.valid_key?/1` are read back through the configured adapter — the same store `UploadLive` writes to; anything else is reported as not found.

**`CakeWeb.AdminLive`** is the landing page of the admin area at `/admin`, where the top bar's Admin link leads: it names what an admin can manage, which today is the logins, and links to them.

**The admin panel for logins** is three LiveViews under `/admin/users`, generated with `mix phx.gen.live` and inside the admin `live_session`, so every one of them is behind the admin guard. From them an admin creates a login, changes it, sets a new password for it, confirms its email by hand or takes the confirmation back, and removes it:

- **`CakeWeb.Admin.UserLive.Index`**, at `/admin/users`, lists every login in username order: username, email, role, whether the email is confirmed, and created date. "New login" is its primary action, and each row but the admin's own has a Delete button behind a confirmation. On a phone the table keeps the username, the role and Delete.
- **`CakeWeb.Admin.UserLive.Show`**, at `/admin/users/:id`, is one login's page: its fields, and the way to its form and to setting its password. It confirms an unconfirmed login by hand, or takes a confirmation back behind a confirmation dialog (`Cake.Accounts.set_user_confirmed/3`); the admin's own page has neither button, since nobody confirms their own email or takes their own confirmation back. Taking a confirmation back stops the next log-in but ends no session the login already has (#401).
- **`CakeWeb.Admin.UserLive.Form`** is the forms, one per live action: `:new` at `/admin/users/new` (username, email, password, role; `Cake.Accounts.create_user/1`, which makes the login confirmed), `:edit` at `/admin/users/:id/edit` (username, email and role, never the password; `Cake.Accounts.update_user/2`, which leaves the confirmation as it was: the admin vouches for the address they type) and `:password` at `/admin/users/:id/password` (a new password and nothing else; `Cake.Accounts.reset_user_password/2`).

What the panel refuses, it refuses on the page: a username that is taken is an error on the username, an email that is taken or missing an error on the email, the demotion of the last admin an error on the role, and an admin's request to delete their own login or take back their own confirmation a `notice/1` (the last-admin rule is `Cake.Accounts`'s; who is asking is known only to the LiveView). Setting a password or deleting a login ends that user everywhere at once: the context deletes their sessions and tokens, and the LiveView then calls `CakeWeb.UserAuth.end_live_sessions/1`, which sends their open pages to the log-in page. A password is typed in and never comes back: a password field is always rendered empty, nothing typed goes into a URL (every form says `method="post"`, so one submitted before LiveView has loaded is not a GET), and the parameter is named `password`, which Phoenix filters out of the log. That filter does not reach a crash report, which prints the message a page was handling and everything it held. The panel closes what a page can close: the form it holds never carries the password, a field that is not text never reaches the template, a save that raises is reported on the page and logged by its exception's name alone, and the admin check on each event turns the admin away rather than crash when it cannot read the session. A crash elsewhere while a password-bearing event is being handled would still print the event; redacting crash reports for every page is #399.

Two admins can work at once. The edit form writes only the fields changed on it, measured against the login as the form last showed it, so a form opened a while ago does not put back what someone else changed since. A login that someone else deleted is reported wherever it is next touched ("That login no longer exists."): deleting it takes the row off the list, and opening its page or a form for it, or saving a form already open, sends the admin back to the list (`Cake.Accounts.get_user/1` is the lookup that answers `nil`). The list is read afresh after every deletion.

**`CakeWeb.UserAuth`** provides the authentication plugs and the four `on_mount/4` LiveView hooks (`:mount_current_user`, `:ensure_authenticated`, `:redirect_if_user_is_authenticated`, `:ensure_admin`) that the router's `live_session`s use. The `/admin` scope is behind the plug `require_admin/2` and the hook `:ensure_admin`: an admin goes through, a logged-in user who is not one is sent to the home page with a "not authorized" flash, and a visitor who is not logged in is sent to the log-in page. Neither needs the authentication plug or hook before it. Both read the user, and so the role, from the database on each request and each mount, so a demotion takes effect on the user's next navigation. Two more checks cover a page that is already open, which a guard that runs on mount cannot reach. Every hook subscribes a connected page to its user's topic, and `end_live_sessions/1` broadcasts on it, so a user whose sessions were ended (their password set by an admin, or their login deleted) is sent to the log-in page from every page they have open, told that their session has ended; a mount looks its session up once more after subscribing, so one that ended in between is not missed. And `:ensure_admin` looks the session up again on every event of a connected admin page, so an admin who is demoted, deleted or logged out while a screen is open can do nothing more from it. These `live_session` hooks are the only access check on a LiveView mount (no LiveView declares its own `on_mount`), so they must run on every connected mount: `CakeWeb.LiveJoinAuthorizationTest` joins the LiveView channel directly, as a hand-written client would, and pins that a join without a URL cannot skip them after access is revoked (phoenix_live_view 1.0.20 refuses it; EEF-CVE-2026-126334, #389).

#### The Account Pages

Seven LiveViews, generated by `mix phx.gen.auth` and since reworked (#372, #377). A user logs in with a username. Every user also has an email, and cannot log in until it is confirmed. Each page is a `header/1` and a form in a card, at the shell's default width. Tokens, sessions and hashing are as generated.

| Page | Module | Route | What it needs |
|---|---|---|---|
| Log in | `CakeWeb.UserLoginLive` | `/users/log_in` | A username and a password. The form posts to `CakeWeb.UserSessionController`, which answers a wrong username and a wrong password alike, and refuses a user whose email is not confirmed, saying so only when the password is right. The page links to the confirmation instructions page. |
| Register | `CakeWeb.UserRegistrationLive` | `/users/register` | A username, an email and a password. It sends the confirmation instructions and sends the visitor to the log-in page; it logs nobody in. |
| Settings | `CakeWeb.UserSettingsLive` | `/users/settings` | A logged-in user. Shows the username, which this page does not change (an admin's action, #376). Offers changing the email, confirmed by a link mailed to the new address, and changing the password. |
| Forgot password | `CakeWeb.UserForgotPasswordLive` | `/users/reset_password` | An email. The answer is the same whether or not it matches a user. |
| Reset password | `CakeWeb.UserResetPasswordLive` | `/users/reset_password/:token` | The token from the reset mail. Resetting a password does not confirm the email (#402). |
| Confirmation instructions | `CakeWeb.UserConfirmationInstructionsLive` | `/users/confirm` | An email, answered the same whether or not it matches. |
| Confirm account | `CakeWeb.UserConfirmationLive` | `/users/confirm/:token` | The token from the confirmation mail. |

**Confirmation.** A user who registers is unconfirmed until they follow the mailed link. A user made with `Cake.Accounts.create_user/1` (the first admin, a login an admin hands out, the dev seed's) is confirmed from the start and is sent nothing. Where mail has nowhere to go, as in a release today (#367), an admin confirms a user by hand: `Cake.Accounts.set_user_confirmed/3` confirms a user or takes the confirmation back, for an admin or for `:operator` (the command line), and refuses to take a user's own confirmation back from them (`{:error, :own_account}`). The gate is at log-in: taking a confirmation back does not end the sessions the user already has (#401). The screen for it is the admin panel's (#376).

The switch that closes the self-service pages on a public deployment is #367's and is not in yet, so all seven are open.

#### The App Shell

Every page is rendered inside one shell, `CakeWeb.Layouts.app/1`: a top bar, the page, and the flash messages. The top bar shows the product name (a link home for a visitor, to the chat for a signed-in user), the pages the user may open, the theme toggle, and an account area. What it links to depends on who is looking:

| Viewer | Page links | Account area |
|---|---|---|
| A visitor | none | Register, Log in |
| A member | Chat, Documents, Upload, Search | a menu under the username: Change password (the settings page), Log out |
| An admin | Chat, Documents, Upload, Search, Admin | the same menu |

The links come from the user's role as it was when the page was loaded, and they are only links: the routes are guarded by `CakeWeb.UserAuth` whatever the bar shows. A page the bar links to tells the shell which one it is (`current_page`), and its own entry is shown as the current page and is not a link: a link to the page being shown would remount it and discard what it holds, on the chat the whole conversation. For the same reason the product name is not a link on the chat. Below the `lg` breakpoint the page links collapse into a menu button and the username into an icon, so the bar fits a phone; the links are rendered twice, in `#main-nav` and `#mobile-nav`.

**`CakeWeb.PageController`** serves the home page at `/`. A visitor gets the product name, one sentence about it and a log-in button, inside the shell. A signed-in user is redirected to `/chat`, with any flash carried along; log-in itself still lands on `/`, so this is where a user arrives after logging in.

**`CakeWeb.ErrorHTML`** renders the error pages for HTML requests: one page for every status, with the status code, its standard message and a link home. The endpoint renders it inside the root layout (`render_errors` in `config/config.exs`), so it is styled and themed, and outside the shell, because an error can happen before the request has a user or a flash. In development Phoenix's debug page is shown instead. JSON errors are `CakeWeb.ErrorJSON`'s.

#### Components, Layouts and Assets

The web layer's kit is the one `mix phx.new` generates on Phoenix 1.8: Tailwind v4 with daisyUI 5, built without Node. `.claude/rules/front-end.md` has the working rules (generator first, daisyUI classes over ad-hoc utilities, where each file comes from and how to update it) and, under "Look and feel", the conventions that keep screens alike. `docs/ui-reference/` holds reference screenshots of the shell and the search screen in each state, in both themes and at two widths, to put a new screen beside.

**`CakeWeb.CoreComponents`** is the generated component library, styled with daisyUI classes: `flash/1`, `button/1`, `input/1`, `header/1`, `table/1`, `list/1` and `icon/1`, the `show/2` and `hide/2` JS commands, and `translate_error/1` and `translate_errors/2`. `use CakeWeb, :html` and `:live_view` import it. Cake adds three state components to it, for the same three situations on every screen, so that screens built apart look alike (#392). The search screen, the chat, the documents list and the upload screen use them, and the account pages and the admin panel use `notice/1`: `empty_state/1` (nothing to show yet: an icon, one sentence, an optional action), `working/1` (work under way, announced as a status) and `notice/1` (a message that is part of the page, of kind `:info`, `:success`, `:warning` or `:error`; `flash/1` stays the dismissible message after an action). `status_badge/1` (#380) shows an ingestion status (pending, processing, completed, failed) as a badge in the status's own colour, the same wherever a status is shown. The generated `table/1` has one addition: a `:col` may carry a `class`, put on its heading and each of its cells, for a column a phone has no room for.

**`CakeWeb.Layouts`** holds the layouts. `root.html.heex` is the HTML skeleton every page is rendered into: the head, the stylesheet and script tags, an inline script that sets the theme before first paint, and the page title, which is "<page> · Cake" for a page that assigns `page_title` (every LiveView does) and "Cake" for one that assigns none. `app/1` is the app shell, a function component that takes the page as its slot and the user as `current_user` (see "The App Shell" above). It renders the page into one column, `#page`, narrow by default and wide with `width={:wide}`, for a table of records or the chat. A page takes its width from there, and the chat, the documents list and the admin panel's list of logins are the pages that ask for the wide column so far. Each LiveView and the home page call it from their own template (`<Layouts.app flash={@flash} current_user={@current_user}>`); `use CakeWeb, :live_view` names no layout. `flash_group/1` renders the flash messages and the two connection-lost notices as daisyUI toasts, and `theme_toggle/1` the top bar's system / light / dark switch.

**Assets.** `assets/css/app.css` is the stylesheet's entry point and the whole Tailwind configuration (there is no `tailwind.config.js`): the sources Tailwind scans, the heroicons and daisyUI plugins, and the two themes, `light` (the default) and `dark` (followed when the system prefers it, or chosen with the toggle). `light` carries the values of daisyUI's Fantasy theme and `dark` those of its Dracula theme. `assets/js/app.js` connects the LiveSocket and the topbar, and hands the LiveSocket the hooks, each a file beside it (`follow_newest.js`, the chat's, is the only one). daisyUI and heroicons are Git dependencies in `mix.exs`, fetched by `mix deps.get` and never compiled; Tailwind and esbuild are standalone binaries. `mix assets.build` writes `priv/static/assets/css/app.css` and `priv/static/assets/js/app.js`, and `mix assets.deploy` minifies and digests them. Neither needs Node. The kit is written for LiveView 1.2 and Cake is on 1.0, so colocated hooks and colocated CSS are left out.

#### Roles and the First Admin

A user is a `:member` or an `:admin` (`Cake.Accounts.User`'s `role`). Registration always makes a member, whatever the request carries. There is always at least one admin: `Cake.Accounts.update_user_role/2`, `Cake.Accounts.update_user/2` (the admin panel's, which changes the username, the email and the role together) and `Cake.Accounts.delete_user/1` refuse to demote or delete the last one with `{:error, :last_admin}`. They go by the role in the database, and they are decided one at a time: each takes the same transaction-level advisory lock before it reads anything, so two requests cannot each remove one of the last two admins, and a demotion cannot slip past a promotion that is still uncommitted.

**To give someone a login**, an admin opens Admin, then Logins, then "New login" (`/admin/users/new`), types a username, the person's email and a password, picks a role, and tells the person the password. The login is confirmed from the start, so it works at once. To change it later, open the login from the list and use "Set password", which also logs that person out everywhere.

No screen can create the first admin, because every admin screen needs an admin. It is created by calling `Cake.Accounts.create_user/1` with a username, an email, a password and a role. All four are required, and the user is confirmed from the start, so they can log in at once. The password must never be an argument on the command line, where it is left in the shell history and shown in the process list.

In dev the call runs in the process you start, so the password can come from the environment. `IFS= read -rs` takes it without echoing it, recording it, or trimming spaces from its ends:

```bash
IFS= read -rs ADMIN_PASSWORD && export ADMIN_PASSWORD
mix run -e 'case Cake.Accounts.create_user(%{username: "caleb", email: "caleb@example.com", password: System.fetch_env!("ADMIN_PASSWORD"), role: :admin}) do {:ok, user} -> IO.puts("created #{user.username} (#{user.role})"); {:error, changeset} -> IO.inspect(changeset.errors); System.halt(1) end'
```

In a release (#361) the call goes through `bin/cake rpc`, which evaluates the expression on the running node. That node does not have the environment of the shell that ran `rpc`, so the password comes from standard input, which `rpc` does pass through:

```bash
IFS= read -rs ADMIN_PASSWORD
printf '%s\n' "$ADMIN_PASSWORD" | bin/cake rpc 'case Cake.Accounts.create_user(%{username: "caleb", email: "caleb@example.com", password: String.trim_trailing(IO.read(:stdio, :line), "\n"), role: :admin}) do {:ok, user} -> IO.puts("created #{user.username} (#{user.role})"); {:error, changeset} -> raise "not created: #{inspect(changeset.errors)}" end'
```

Three details of that command matter to a script that runs it:

- `printf` is a shell builtin, so the password is not in the process list either.
- Only the line's newline is removed (`String.trim_trailing/2`), so a password that begins or ends with a space is the one stored.
- On failure it raises. The `rpc` command then exits non-zero, so a script stops there, and the running node is unaffected. It must not call `System.halt/1`, which would stop the node it runs on.

The dev seed (`priv/repo/seeds.exs`) creates a dev login, `admin`, as a confirmed admin, and makes it one on a database that was seeded before roles or confirmation existed. Its password is in the repository, and the dev image's `entrypoint.sh` runs the seed on every boot, so that image must never serve anyone but a developer: a release must not run the seed (#361, #367).

### Supervision Tree Boot Order

The application starts children in this order under Cake.Application:

1. `CakeWeb.Telemetry` — telemetry metrics
2. `Cake.Repo` — Postgres connection pool
3. Oban — background job processing
4. `DNSCluster` — DNS-based node discovery
5. `Phoenix.PubSub` — pub/sub for LiveView
6. `Finch` — HTTP client pool
7. `Cake.Search.Deployment` — OpenSearch connection + index creation
8. `Task.Supervisor` (`Cake.TaskSupervisor`) — shared task supervisor: conversation turn tasks, flat-decomposition sub-search fan-out, and every ingestion fan-out (the per-item task stages of both pipelines and of the source pipelines, `Pipelines.add_to_search_backend/3` included), run unlinked so a crashed item is reported to the consuming stream instead of taking it down (see "Error Handling in Pipelines")
9. `DynamicSupervisor` (`Cake.ConversationSupervisor`) — supervises the per-session `Conversation` GenServers started via `Conversation.start/1` (`:temporary` children; each stops on its own when its `:owner` LiveView exits)
10. `CakeWeb.Endpoint` — Phoenix HTTP server (last, so all dependencies are ready)

Phoenix runs `server: false` in test, so this boot order is exercised in CI only by the compose smoke test, which boots the real stack through `entrypoint.sh` and asserts that step 7 created both collections (`.claude/rules/compose-smoke.md`).

### Module Boundaries (enforced by `boundary`)

The layer responsibilities above are enforced at compile time by the [`boundary`](https://hex.pm/packages/boundary) compiler. Each top-level context is a boundary that declares the boundaries it may call (`deps`) and the modules it makes public (`exports`); any cross-boundary call not covered by a declared dep fails the build.

- **`Cake`** — the shared kernel: `Repo`, `Schema`, `Mailer`, the `GDS` behaviour, the `Citable`/`Promptable` protocols, `Citations`, `FailedIngests` and `FailedIngests.FailedIngest`, `ParseBooks`. Depends on nothing internal; every context may depend on it.
- **Ingestion** — `Cake.Books` (exports `Adapters`, `ParsedBook`, `Chunk`, `Pipeline`, `Pdf.Pipeline`, `ZipExtractor`) and `Cake.Documents` (exports `Pipeline`, `Hexdocs.Pipeline`, `ParsedDocument`) depend on `Cake.Search`, `Cake.Embeddings`, and `Cake.Pipelines` (exports `Context`; in turn depends on `Cake.Search`).
- **Retrieval** — `Cake.Search` depends only on the kernel and exports `Result`, `Query`, `Hit`, `Backend`, `Provenance` and `Deployment`. It no longer names the GDS modules: the collections created at boot come from `:search_collections` config, which is what keeps the search layer from depending back on the ingestion contexts (an otherwise-cyclic dependency). `Cake.Embeddings` likewise depends only on the kernel and exports `Behaviour`.
- **Conversation** — `Cake.Conversation` is the orchestrator (exports `Events`); it depends on `Cake.Prompt` (exports nothing), `Cake.Search`, `Cake.Embeddings`, `Cake.Generation` (exports `OpenAI` only, so `Cake.Generation.Anthropic` is unreachable from outside its boundary), `Cake.Responses` (exports `Result`), and `Cake.Decomposition` (exports `Result` and `LLM`). Peer-to-peer deps among the service modules are minimal: `Cake.Responses → Cake.Search`, `Cake.Prompt → Cake.Search` (for the `Result` type), and `Cake.Decomposition → Cake.Prompt`/`Cake.Generation`. Nothing depends back on `Cake.Conversation` except the web layer. `Cake.Candidates` is a top-level boundary of its own (deps `Cake` and `Cake.Search`, exports nothing) that the web layer calls alongside `Conversation`.
- **Accounts** — `Cake.Accounts` depends only on the kernel and exports `User`.
- **Web / jobs / app / tasks** — `CakeWeb` depends on `Cake`, `Cake.Accounts`, `Cake.Books`, `Cake.Candidates`, `Cake.Conversation`, `Cake.Embeddings` and `Cake.Search`, and exports `Endpoint` and `Telemetry`; `Cake.Jobs` depends on `Cake.Documents`; Cake.Application (top-level, `@moduledoc false`) on `Cake`, `CakeWeb` and `Cake.Search`. The three Mix tasks are top-level boundaries of their own: `Mix.Tasks.Precommit` and `Mix.Tasks.Hooks.Install` with no deps, `Mix.Tasks.Cake.Nif.Check` depending on `Cake`.

The compiler runs in `:dev`/`:prod` only — test files and support modules deliberately cross boundaries, so `:test` is excluded — and CI enforces it with a dev-env compile. When you add a cross-context call, declare the `dep` (and `export` the target module) rather than working around the boundary.

---

## The RAG Loop: End-to-End Data Flow

This section traces how content flows from raw document to user-facing answer, connecting the layers described above.

1. **Acquire**: A pipeline implementation fetches source content (a PDF binary from the storage adapter, a `git clone` of elixir-lang/elixir for hexdocs, etc.).
2. **Persist raw**: Raw content is persisted before parsing, as the source of truth that enables re-parsing without re-acquiring it. Where it lives depends on the pipeline: Hexdocs source goes to Postgres as `Hexdoc.content`; book binaries go to the `Cake.Books.Adapters` store, with Postgres holding the book's `source_file_path` (the storage key) and `file_hash`.
3. **Parse**: The pipeline transforms raw content into GDS schema records (e.g., `ParsedBook` + `Chunk`).
4. **Index**: Embedded records are upserted into OpenSearch indices via `Cake.Pipelines.add_to_search_backend/3`. The retrieval unit maps one-to-one to OpenSearch documents.
5. **Retrieve**: `Cake.Conversation` orchestrates retrieval — embed the question, search OpenSearch, score and rank results.
6. **Generate**: `Prompt` formats retrieved chunks into a numbered context block. `Generation` sends the messages list to the LLM. `Responses` parses `[N]` citation markers and builds the structured response the frontend renders.

---

## Custom Structs: Complete Inventory

Every custom struct in Cake, its module, and its purpose. Every one of them defines `@type t`.

### Ecto Schemas (use Cake.Schema)

| Struct | Module | Purpose |
|---|---|---|
| `ParsedBook` | `Cake.Books.ParsedBook` | Book-level metadata for book-like documents. GDS identity module for the Books GDS. |
| `Chunk` | `Cake.Books.Chunk` | Atomic searchable text fragment within a book, with its `embedding` and the `embedding_model` that produced it. Retrieval unit for the Books GDS. |
| `ParsedDocument` | `Cake.Documents.ParsedDocument` | Programming documentation entry, with its `embedding` and the `embedding_model` that produced it. Both GDS identity and retrieval unit for the Documents GDS. |
| `Hexdoc` | `Cake.Documents.Hexdocs.Hexdoc` | Raw Elixir source cloned from the elixir-lang/elixir repository. Intermediate storage (raw data struct). |
| `FailedIngest` | `Cake.FailedIngests.FailedIngest` | Persists item-level pipeline failures for retry via `Cake.Pipelines.sweep/3`, tagged with the recording run's `run_id`. |
| `User` | `Cake.Accounts.User` | Phoenix authentication user record: a `username` (what a user logs in with; 3 to 32 characters, compared case-insensitively and stored as typed), a `role` (`:member` or `:admin`), an `email` (required; a user cannot log in until it is confirmed, `confirmed_at`), and a hashed password. |
| `UserToken` | `Cake.Accounts.UserToken` | Session and email confirmation tokens. |

### Non-Ecto Domain Structs

| Struct | Module | Purpose |
|---|---|---|
| `Pipelines.Context` | `Cake.Pipelines.Context` | Carries pipeline identity (behaviour, implementation, version) plus a per-run `run_id` through an ingestion run: identity for error provenance, `run_id` to scope `count_failures/1`, `finalize_ingest/3`, and `sweep/3` to that run. |
| `Search.Query` | `Cake.Search.Query` | Composable query builder. Fields: `index`, `size`, `must`, `should`, `filter`, `min_score`. |
| `Search.Hit` | `Cake.Search.Hit` | Backend-agnostic search hit. Every backend maps its native hit type into this struct at the boundary. Fields: `id`, `score`, `source`. |
| `Search.Result` | `Cake.Search.Result` | Normalized search result. Carries retrieval unit, backend score, CAKE-computed scores (cosine, relevance), hit provenance (search vs. expansion), search conditions, and prompt index. Single carrier of all retrieval metadata through the pipeline. |
| `Search.Provenance` | `Cake.Search.Provenance` | Search conditions attached to each `Search.Result`: search type, query text, decomposition traceability (`decomposed`, `original_query`, `sub_question_index`), and `embedding_model` — the model the query vector was embedded under, from the `:embedding_model` search opt (the stored vector's model is on the retrieval unit). |
| `Responses.Result` | `Cake.Responses.Result` | Output struct from post-generation processing. Fields: `raw_text`, `final_text` (markers renumbered), `chunk_map`, `citations` (one per cited retrieval unit, `new_index` 1..K), `media` (always `[]` — a stub stage), `actions` (one `:download` per unique non-`nil` citation `source_ref`), `assigns` (passthrough map for the view), `warnings` (`{:hallucinated_citation, idx}`). |
| `Conversation.State` | `Cake.Conversation.State` | Internal state for the `Conversation` GenServer. Enforced keys: `id`, `embedder`, `response_model`, `provider`, `gds`, and the three decomposition budgets `max_context_tokens` (for accumulated answers/steps), `max_self_ask_iterations` and `max_ircot_iterations` (round caps) — the budgets are enforced rather than defaulted so their config.exs defaults, read by `Conversation.build_state/1`, cannot drift from a struct-level copy. Also carries the collaborator modules (`embeddings`, `generation`, `responses`, `decomposition`), the turn FSM fields (`state`, `pending`, `turn_ref`, `turn_pid`, `queued_question`), the `owner_ref` monitor on the optional `:owner` pid, search results, message history, chunk map, citations, and accumulated errors. |
| `Books.PageContent` | `Cake.Books.PageContent` | Elixir-side struct the Rust PDF NIF decodes into (via NifStruct): one page's extracted text and page number. |
| `Books.PdfExtraction` | `Cake.Books.PdfExtraction` | Elixir-side struct the Rust PDF NIF decodes into: the full extraction result (pages, skipped pages, title). |
| `Books.SkippedPage` | `Cake.Books.SkippedPage` | Elixir-side struct the Rust PDF NIF decodes into: a page that could not be extracted, with its page number and a `reason` string. |
| `Decomposition.Result` | `Cake.Decomposition.Result` | Outcome of decomposing a question: `original_question`, `strategy` (`:none` \| `:flat` \| `:sequential` \| `:self_ask` \| `:ircot`), `sub_questions` (a dependency DAG of `%{question, depends_on}` entries — `new/2` validates indices and acyclicity), and `question_index` mapping positional index → entry so `Search.Provenance` can reference sub-questions by index. `topological_order/1` yields the sequential resolution order. |

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
| `Cake.GDS` | `lib/cake/gds.ex` | Module-level contract for a Generic Data Structure. Declares index name, search fields, hit hydration, neighbor expansion. | `Cake.Books.ParsedBook`, `Cake.Documents.ParsedDocument` |
| `Cake.Books.Pipeline` | `lib/cake/books/pipeline.ex` | Ingestion behaviour for book-like documents. Callbacks: `load_binary/1`, `parse/1`, `format/0`, `success_message/0`. | `Cake.Books.Pdf.Pipeline` |
| `Cake.Documents.Pipeline` | `lib/cake/documents/pipeline.ex` | Ingestion behaviour for programming documentation. Callbacks: `download/1`, `persist_raw_docs/2`, `parse/2`, `success_message/1`, and the optional `retry_from_raw/2`. | `Cake.Documents.Hexdocs.Pipeline` |
| `Cake.Embeddings.Behaviour` | `lib/cake/embeddings/behaviour.ex` | Contract for embedding services. | `Cake.Embeddings` (OpenAI impl, in `lib/cake/embeddings.ex`) |
| `Cake.Generation` | `lib/cake/generation.ex` | Contract for LLM completion services: `complete/3` and `complete_json/3` (schema-constrained JSON). | `Cake.Generation.OpenAI`, `Cake.Generation.Anthropic` (stub) |
| `Cake.Decomposition` | `lib/cake/decomposition.ex` | Contract for query-decomposition strategies: retrieval-free `decompose/2`, returning `{:ok, Decomposition.Result.t()}` or `{:error, reason}`. | `Cake.Decomposition.LLM` |
| `Cake.Search.Backend` | `lib/cake/search/backend.ex` | Contract for search backends: read, write and collection lifecycle. Callbacks: `search/1` (a `Query` in, `{:ok, [Hit.t()]}` or `{:error, search_error()}` out), `index_document/3`, `delete_document/2`, `create_collection/2`, `list_collections/0`. | `Cake.Search.Backend.OpenSearch` |
| `Cake.Responses.Behaviour` | `lib/cake/responses/behaviour.ex` | Contract for post-generation response processing. | `Cake.Responses` |
| `Cake.Books.Adapters` | `lib/cake/books/adapters.ex` | Contract for raw binary storage of book files. Callbacks: `read/1`, `write/2`, `exists?/1`, `delete/1`, each taking the storage key `build_key/3` produces. | `Cake.Books.Adapters.Disk`, `Cake.Books.Adapters.S3` |

---

## Protocols and Implementations: Complete Inventory

Protocols in Cake define value-level contracts. The question they answer is "what does *this value* know how to do?" Use a protocol when dispatch is by struct type.

| Protocol | Module | Purpose | Current Implementations |
|---|---|---|---|
| `Cake.Promptable` | `lib/cake/promptable.ex` | Renders a struct as prompt context for the LLM. Each implementation defines how its data should appear in the numbered context block. | `Cake.Books.Chunk`, `Cake.Documents.ParsedDocument` |
| `Cake.Citable` | `lib/cake/citable.ex` | Extracts citation metadata from a struct. Returns a map with exactly five keys: `id` (a string), `label`, `source_ref`, `preview`, and `extras`. | `Cake.Books.Chunk`, `Cake.Documents.ParsedDocument` |

---

## Data Schemas: Field-Level Detail

### ParsedDocument Fields

`source` (pipeline identifier), `version`, `package` (module/gem/class name), `language`, `title` (function/method name — used in embeddings), `text`, `url`, `embedding` (an array of floats whose length is the embedding model's output dimension (1536 for the default, `text-embedding-ada-002`)), `embedding_model` (nullable string: the model that produced `embedding`, written in the same update; `nil` until embedded, and on rows embedded before the column existed; a retry refuses to embed a document under a model other than its corpus's — same `source` and `version`), `core` (boolean: part of stdlib?). Query helpers: `base_query/0`, `by_version/2`, `by_language/2`, `by_source/2`.

### Hexdoc Fields

`module`, `version`, `core` (boolean, default `true`), `url`, `content` (the raw Elixir source), `source` (default `"hexdocs"`), `language` (default `"elixir"`). Query helpers: `base_query/0`, `by_module/2`, `by_version/2`; `to_parsed_docs/1` turns one row into the `ParsedDocument` attrs the parse stage emits: one per `def` or `defp` clause (private functions are retrieval context too), titled `name/arity`, with the preceding `@doc` carried whether written as a string, a `~S`/`~s` sigil or a keyword list; `defmacro`, `defguard`, `defdelegate` and the other forms are skipped.

### ParsedBook Fields

`title`, `source_file_path` (required; the `Cake.Books.Adapters` storage key the binary was written under — `CakeWeb.BooksController` reads it back through the configured adapter for downloads — and the `Citable` `source_ref`), `authors` (string array), `source_format`, `file_hash` (deduplication), `file_size`, `word_count`, `total_pages`, `parsed_at`, `embedding_status` (enum: pending/processing/completed/failed — written after the index stage, so `completed` means every chunk embedded *and* indexed; it is the one state that makes a re-upload of the same bytes a duplicate — and only under the model every chunk carries — any other is resumed), `metadata` (map), `table_of_contents` (map), `language` (ISO code), `isbn`, `publisher`, `publication_date`. Has many `Chunk` records. Query helpers: `base_query/0`, `by_title/2`, `by_language/2`, `by_file_path/2`, `by_author/2`, `by_format/2`, `by_isbn/2`, `by_publisher/2`, `published_on/2`, `published_before/2`, `published_after/2`, `parsed_on/2`, `parsed_before/2`, `parsed_after/2`.

### Chunk Fields

`text`, `page_number` (nullable), `chunk_index` (ordering for unpaginated formats), `section_title`, `word_count`, `char_count`, `embedding` (an array of floats whose length is the embedding model's output dimension (1536 for the default, `text-embedding-ada-002`)), `embedding_model` (nullable string: the model that produced `embedding`, written in the same update; `nil` until embedded, and on rows embedded before the column existed. A `:completed` book is a duplicate only when every chunk carries the requested model; a retry refuses to embed a chunk under a model other than its book's). Belongs to `ParsedBook`. Query helpers: `base_query/0`, `by_book/2`, `on_page/2`, `within_pages/3`, `by_section/2`.

### FailedIngest Fields

`run_id` (UUID of the `Pipelines.Context` run that recorded it; required on new rows, nullable in the table for rows predating it, which stay listable as historical records but sit outside the run-scoped `count_failures/1` and `sweep/3`), `pipeline_behaviour`, `pipeline_implementation`, `step`, `version`, `error_text`, `input_identifier`, `pipeline_fatal` (boolean), `retry_count`, `last_retried_at` (both declared, but nothing in `lib/` writes them: a sweep deletes resolved rows and leaves unresolved rows untouched).

---

## Adding a New GDS

The question to ask when designing a new GDS is *Why is the customer interested in this kind of documentation, and what is the atomic unit they'd want returned from a search?* The answer determines whether your GDS is a single schema or a parent/child pair. Existing GDSes (`ParsedBook` + `Chunk` and `ParsedDocument`) are the reference implementations.

1. **Design the schema(s).** Decide single-schema vs. parent/child. Use `Cake.Schema`. Every changeset with string fields must call `sanitize_text_fields/1`. UUIDs are binary.
2. **Declare `use Cake.GDS` on the identity module.** Implement `collection_name/0`, `search_fields/0`, `load_from_hits/1`. Override `expand_with_neighbors/2` if the GDS has ordering; otherwise inherit the identity default.
3. **Implement `Cake.Promptable`** on the retrieval-unit schema. Define how a search result renders in the numbered context block.
4. **Implement `Cake.Citable`** on the retrieval-unit schema. Define citation metadata — the map must carry exactly five keys: `id` (a string, normally the record's UUID), `label`, `source_ref`, `preview`, `extras`.
5. **Design a pipeline behaviour** targeting this GDS, or implement an existing one if the GDS already has a behaviour.
6. **Register the collection in `config :cake, :search_collections`** as a `{IdentityModule, RetrievalUnitSchema}` pair. `Cake.Search.Deployment` creates every registered collection at boot, and `Backend.OpenSearch.build_mapping/1` derives the mapping from the retrieval-unit schema's fields (`:text` → `text`, `:embedding` → `knn_vector` sized by `:default_embedding_dimension`, everything else → `keyword`), so that schema must carry `:text` and `:embedding` fields. Nobody hand-writes a mapping, and an unregistered GDS gets no collection.
7. **Thread the GDS through `Cake.Conversation`.** Pass `gds: YourGDS` in opts. `Cake.Search` will use the GDS's callbacks for collection name, field selection, hit hydration, and neighbor expansion.

---

## Adding a New Ingestion Pipeline

### For an Existing GDS

Implement the behaviour for the target GDS. Consult `Cake.Books.Pdf.Pipeline` or `Cake.Documents.Hexdocs.Pipeline` as reference implementations.

### Adding a New Documentation Source (Cake.Documents.Pipeline)

1. Create a raw document schema for intermediate storage.
2. Implement callbacks: `download/1`, `persist_raw_docs/2`, `parse/2`, `success_message/1`. The source identifier (e.g. `"hexdocs"`) is a property of the data, not of the module: `parse/2` emits it as the `:source` attr of every `ParsedDocument` (for hexdocs, `Hexdoc.doc_attrs/0` is the single source of truth: `Hexdoc.to_parsed_docs/1` merges it into every attrs map it emits).
3. Register with Oban via `DocumentIngestionJob.enqueue_for_version/4`.
4. Follow the result-tuple contract: `download/1` returns `{:ok, paths}` or the tagged `{:error, :download, reason}`; stream callbacks (`persist_raw_docs/2`, `parse/2`) detuple their per-item result tuples via `Pipelines.detuple_with_logging/3` before returning, so the streams they return carry bare successful values; `success_message/1` returns a bare value.
5. Optionally implement `retry_from_raw/2`.

### Adding a New Book Format (Cake.Books.Pipeline)

1. Implement callbacks: `load_binary/1`, `parse/1`, `format/0`, `success_message/0`.
2. Add format-specific parsing logic.
3. New schemas must `use Cake.Schema` and include `sanitize_text_fields/1`.

### Requirements for All Pipeline Implementations

Every stream step must record its per-item failures to `FailedIngest`, under a descriptive step name, through one of two `Cake.Pipelines` functions — never a silent filter that drops a failure without persisting it. `Pipelines.detuple_with_logging/3` is the default: fallible per-item work produces result tuples that the callback detuples (persisting failures) before returning, so the stream a callback returns carries bare successful values. `Pipelines.log_and_persist_failure/3` is for a step that handles each item's outcome itself and has no result-tuple stream to detuple — the Books embed stage uses it, recording every failed chunk under `"books.embed"` as it maps embedding results back onto chunks. Direct fallible callbacks return `{:ok, _}` / `{:error, _}` (plus `download/1`'s tagged `{:error, :download, reason}`); declarative callbacks return bare values; and `Books.Pipeline.parse/1` returns a bare pair on success and raises on failure — the orchestrator rescues the exception into the per-item error tuple, and any returned value (an `{:error, _}` included) is wrapped as success, so never signal failure from it by return value. Pipeline-fatal errors go in the `else` branch of the behaviour's `ingest` `with` chain, which must open with at least one eager, run-level fallible step (see "Pipeline-Fatal Steps and the `with` Chain" below). A stage that fans its items out to tasks does so with `Task.Supervisor.async_stream_nolink(Cake.TaskSupervisor, ...)` and `zip_input_on_exit: true`, never a plain `Task.async_stream/3`, and its result handler has an `{:exit, {input, reason}}` clause that records the item (see "Error Handling in Pipelines" below). Persist raw data first.

---

## Error Handling in Pipelines

Cake distinguishes between item-level failures (one document fails to parse) and pipeline-fatal failures (the download step itself fails). Item-level failures are persisted to `FailedIngest` via `detuple_with_logging/3`, tagged with the run's `run_id`, and can be retried via `sweep/3`, which only ever touches that run's rows. The sweep calls each pipeline's `retry/4` with no rescue, so `retry/4` answers every row with a result tuple: a row recorded under a step it has no strategy for (`Documents.Pipeline`: a source pipeline's own `"docs.persist_raw"` and `"docs.parse"`) gets `{:error, {:unsupported_step, step}}`, and a row with no `input_identifier` to resume from gets `{:error, {:no_input_identifier, failure_id}}`; both are logged and counted as remaining, never retried. A retry asked to embed under a model other than the one its book (Books) or corpus (Documents: same `source` and `version`) already carries (or where a vector's model was never recorded, reported as `nil`) is refused the same way, with `{:error, {:embedding_model_mismatch, id, stored_models, requested}}`; a `"docs.persist"` retry is checked before its re-parsed documents are inserted: a retry repairs one item, and moving a book or corpus to a new model is a re-ingest (#284). Pipeline-fatal failures short-circuit the `with` chain and are logged in the `else` branch.

**A crash inside one item's task is an item-level failure.** Every ingestion fan-out — the persist, embed and index stages of both pipelines, and the stages a source pipeline runs inside its own callbacks — starts its per-item tasks unlinked under `Cake.TaskSupervisor`, via `Task.Supervisor.async_stream_nolink/4` with `zip_input_on_exit: true` and the stage's timeout, never through a plain `Task.async_stream/3`. A plain `async_stream` links each task to the process consuming the stream, so a crash inside the task (a malformed provider body tripping a bad match, a bang call in persistence) would kill the consumer and abort the whole run with no per-item record. Unlinked, the crash reaches the stream as `{:exit, {input, reason}}`, the same shape a task killed on timeout produces, and the stage's result handler records a `FailedIngest` row for that item under its step name — with the item's identifier (the chunk or document id, the storage key, the hexdoc module) as `input_identifier` and the exception, as inspected, in `error_text` — then the run continues with the next item. The guarantee is pinned per stage in the unit suites (`Cake.PipelinesSearchBackendTest` and its property test, `Cake.Books.PipelineTest`, `Cake.Documents.PipelineTest`, `Cake.Documents.Hexdocs.PipelineTest`; #273). A stage whose task body rescues its own exceptions into a result tuple (`"docs.persist"`, the Hexdocs `safe_*` helpers) records the exception message that way instead, so only a non-exception exit reaches its `{:exit, _}` clause.

### Pipeline-Fatal Steps and the `with` Chain

A `with` clause short-circuits to `else` only when its result fails to match its pattern. Every stream stage in a pipeline returns `{:ok, stream}` unconditionally, since its per-item failures are lazy and are persisted by `detuple_with_logging/3` as the stream is consumed. So a `with` chain made only of stream stages can never reach its `else` branch. Its `else` would be dead code, and pipeline-fatal errors would have nowhere to go.

**Rule:** every pipeline behaviour's `ingest` `with` chain must include at least one **eager, run-level fallible step**. This is a clause that runs before any stream is built, decides whether the run as a whole can proceed, and returns either `{:ok, value}` or the tagged `{:error, step, reason}` (`step` an atom naming the step). The chain's `else` routes every such error through `Pipelines.handle_ingest_error/2`. That call logs it with the run's `Context`, persists a `FailedIngest` row with `pipeline_fatal: true` and `step: Atom.to_string(step)`, and returns `{:error, {step, reason}}` to the caller. Don't add an `else` to a chain with no fallible step. Add the step first, and test that its failure reaches `handle_ingest_error/2`.

| Pipeline | Run-level fallible step | Fatal errors |
|---|---|---|
| `Cake.Documents.Pipeline.ingest/4` | `source_pipeline.download/1` | `{:error, {:download, reason}}` |
| `Cake.Books.Pipeline.ingest/4` | `Cake.Books.Pipeline.validate_paths/1` | `{:error, {:validate_paths, :no_paths}}` for an empty key list; `{:error, {:validate_paths, {:invalid_paths, keys}}}` when any key is not a non-blank, NUL-free, valid UTF-8 string (`keys` lists every invalid one unchanged; keys are identifiers, so they are never sanitized) |

`Cake.Schema.sanitize_text_fields/2` (the `sanitize_text_fields/1` helper `use Cake.Schema` injects into each schema) strips NUL bytes from `:string` fields because Postgres cannot store them. That is right for free text and wrong for identifiers: an identifier field such as `ParsedBook.source_file_path` or `FailedIngest.input_identifier` must never rely on it, because a stripped key no longer names the object it was loaded from. Reject unstorable identifiers at the pipeline's run-level fallible step instead, as `validate_paths/1` does.

Pipeline-fatal and item-level failures are separate. A fatal error means nothing was attempted, and the caller gets `{:error, {step, reason}}`. A run where every item failed still completes, and the caller gets `{:error, {:no_items_ingested, summary}}` from `finalize_ingest/3` in the `do` body, never from `else`.

Step names follow `"pipeline.step"` convention (e.g., `"books.parse"`, `"docs.embed"`). The `Context` struct carries pipeline identity so error records are traceable to their source.

### Error Type Unions

Behaviours that return `{:error, reason}` define a named union type enumerating the concrete error shapes their implementations produce. The behaviour owns the union; adding a new implementation means adding its error types to the union. Three modules use this pattern today:

- **`Cake.Search.Backend.search_error()`** — union of `Snap.ResponseError.t()`, `Snap.HTTPClient.Error.t()`, and `Jason.DecodeError.t()`. Fully enforceable by dialyzer: a new backend whose errors aren't in the union will fail the callback type check.

- **`Cake.Books.Adapters.adapter_error()`** — union of `File.posix()` (Disk adapter) and `term()` (S3 adapter, because `ExAws.request/1` specs `{:error, term()}`). The `term()` contribution collapses the union for dialyzer today, but enumerating `File.posix()` explicitly documents the Disk contract and will become enforceable once ExAws publishes a concrete error type. The Disk implementation narrows its own specs to `File.posix()` independently. What the S3 side actually returns — `{:http_error, status, response}` when the store answered, the transport error when it could not be reached — is pinned against a real store in the `integration` CI job (`Cake.Books.Adapters.S3IntegrationTest` on `Cake.S3IntegrationCase`; `.claude/rules/integration-tests.md`).

- **`Cake.Books.Persistence.persist_error()`** — union of `{:invalid_input, map()}` and `{String.t(), Ecto.Changeset.t() | chunk_error()}`, with `chunk_error()` itself a union of `{:invalid_chunk, keyword(), map()}` and `{:chunk_insert_count_mismatch, non_neg_integer(), non_neg_integer()}`. Fully concrete — every error path is accounted for.

The pattern is: define the union in the behaviour (or module that owns the contract), use it in callback specs, and let each implementation narrow to its subset. When a dependency doesn't expose concrete error types (as with ExAws), include `term()` and document why — the union still serves as a registry of intent even when dialyzer can't enforce it.

---

## Search Design

OpenSearch queries support three modes via `search_type`: `:keyword` (BM25 multi_match), `:vector` (k-NN with cosine similarity over an HNSW/FAISS index; the knn clause defaults to `k=30` at query time, overridable via `opts[:k]` — `Cake.Search` likewise defaults the query `size` to 30, overriding the `Query` struct's own default of 10), and `:hybrid` (vector in `must`, keyword in `should` with configurable boost). Hybrid is the default because pure vector search struggles with exact identifiers and rare terms, while pure keyword search misses semantic similarity.

`Cake.Search` builds queries via `Cake.Search.Query`, delegates execution to the configured `Cake.Search.Backend` (default: `Backend.OpenSearch`), and hydrates hits into `Cake.Search.Result` structs via the GDS's `load_from_hits/1`. The backend is injected via `Application.get_env(:cake, :search_backend)` and mocked with Mox in tests.

The builders' laws, and `Backend.OpenSearch.to_query_map/1`'s, are specified in LawSpec, in `lawspec/laws/search_query.lawspec` (#332): clause builders are additive, a clause equal to one the query already holds included; `size` and `min_score` are last-write-wins over `new/2`'s options; calls in any other order build the same clauses; a knn clause carries `method_parameters.ef_search` only when the call gives one; and the query map keeps the query's size, clauses and `min_score` (a `:min_score` key exactly when it is not `nil`) and lists each clause list in call order, checked against a reference model that folds the calls. The clause order is a law about the map, not about the struct, which holds each list newest first (`lawspec/README.md`).

`Backend` defines `@type search_error` as the explicit union of all error types that any backend implementation can return. When a new backend is added, its error types must be added to this union — dialyzer enforces this by checking each implementation's return types against the callback specs. This makes the set of possible search errors a conscious, enumerated registry rather than an opaque `term()`; `index_document/3` returns the same union, passing Snap's `{:error, reason}` through unchanged. In the test env `Cake.Search.Deployment` is configured with `Cake.Search.HTTPClientStub` (a `Snap.HTTPClient` adapter under `test/support/`) so backend tests can drive Snap's real request/response path against canned replies. Against a real node, `Cake.Search.BackendConformance` (`test/support/`) is the backend-parameterized conformance suite — collection lifecycle and the `:keyword`/`:vector`/`:hybrid` search modes with `min_score` and `size` — that every backend implementation instantiates (`use Cake.Search.BackendConformance, backend: ..., mapping: ...`) and must pass unchanged; it runs in the `integration` CI job on `Cake.SearchIntegrationCase`, which repoints the Deployment at `OPENSEARCH_URL` inside the `cake_test` Snap index namespace and gives each test a collection of its own (`.claude/rules/integration-tests.md`).

`search_chunks_with_context/5` returns `{:ok, [Cake.Search.Result.t()]}` (or the backend's error tuple). Direct hits carry `hit_source: :search` and the backend `_score`; expanded neighbors carry `hit_source: :expansion` and `backend_score: nil`. The Result struct is the single carrier of retrieval metadata through the rest of the pipeline (scoring, prompt assembly, response post-processing) — everything above the Search.Result boundary speaks CAKE; everything below speaks vendor. CAKE-computed scores (`cosine_score`, `relevance_score`) are populated by `Search.score_results/2` and `Search.normalize_and_combine/1`; `prompt_index` is populated by `Prompt.prepare_context/2`. Each Result also carries a `Search.Provenance` describing the search conditions (type, query text, and the query's embedding model when the caller passes `:embedding_model`, as `Conversation` and `SearchLive` do) under which it was discovered.

---

## Configuration Keys

The domain-level `:cake` application-env keys that `lib/` reads, grouped by consumer. Values are `config/config.exs` defaults unless noted. Framework configuration is as Phoenix generated it and is not listed here: `Cake.Repo`, `CakeWeb.Endpoint`, `Cake.Mailer`, `Oban` and `:dns_cluster_query` (both read in Cake.Application, which is `@moduledoc false`).

- **Models and providers.** `:default_embedding_model` (`text-embedding-ada-002`; read by `UploadLive` and `SearchLive`), `:default_embedding_dimension` (1536; read only by `Backend.OpenSearch.build_mapping/1`), `:default_provider` (`:openai`; `UploadLive`, `SearchLive`). `:default_response_model` is set but read by nothing in `lib/`. `config :cake, Cake.Conversation` (`gds`, `embedder`, `response_model`, `provider`) is what `ChatLive` starts conversations from.
- **Provider transports.** `config :cake, Cake.Embeddings` — `:openai_key`, `:base_url`, `:req_options` (a `Req.Test` plug in tests, empty in prod). `config :cake, Cake.Generation.OpenAI` — `:openai_key`, `:response_url` (the Responses API endpoint), and an optional `:plug` (a `Req.Test` plug in tests, unset in prod). `:embeddings_module` swaps the whole module for the pipelines (`Cake.Embeddings.Mock` in `config/test.exs`); the pipelines read it at call time.
- **Search.** `:search_collections` (the boot-time `{name_module, mapping_schema}` pairs), `config :cake, Cake.Search.Deployment` (the Snap cluster: URL per env, `http_client_adapter: Cake.Search.HTTPClientStub` in test), and `:search_backend` — set in no config file; `Backend.backend/0` defaults it to `Backend.OpenSearch`, and tests inject the Mox mock with `Application.put_env`. `:skip_search_backend` makes `Pipelines.add_to_search_backend/3` pass records through unindexed; `test_helper.exs` sets it for every run; `Cake.SearchIntegrationCase` turns it off per test for the real-cluster suites, and `test/cake/pipelines_search_backend_test.exs` does the same to drive indexing through the Mox backend.
- **Book storage.** `:book_storage_adapter` (`Disk` by default, `S3` in prod, `Mock` in test), `:book_storage_tenant` (the tenant segment of storage keys, `"default"`), `:book_storage_root` (the Disk adapter's directory, default `priv/book_storage`), `:book_storage_s3_bucket` (`config/runtime.exs`, from the environment).
- **Uploads.** `:max_zip_expanded_bytes` (268 435 456, i.e. 256 MB: the most the PDF entries of one ZIP upload may declare uncompressed in total) and `:max_zip_entries` (10 000 entries per archive, PDF or not), read by `Cake.Books.ZipExtractor` at call time, which also carries a matching compiled-in default for each.
- **Decomposition.** `:decomposition_max_context_tokens` (4096), `:max_self_ask_iterations` (5), `:max_ircot_iterations` (5), `:max_sub_search_concurrency` (4), and `:sub_search_timeout` (30 000 ms), all set in `config/config.exs`; `Cake.Conversation` also carries a matching compiled-in default for each.

---

## Roadmap: Planned and Deferred

**Shipped since first draft:** query decomposition in its own `Cake.Decomposition` boundary (not inside `Prompt` as originally sketched): flat concurrent fan-out end-to-end, plus the `Conversation`-side machinery for the other three tiers — sequential least-to-most, the self-ask loop and the IRCoT loop. The shipped LLM strategy emits atomic-or-flat decompositions only, so `:sequential` awaits a strategy that emits dependency edges, and `:self_ask`/`:ircot` await one that marks them (`Result.new/2` never derives either). See "Query Decomposition" under Layer 3. Conversation layer decomposition: `Prompt` and `Generation` are their own boundaries, and `Responses` is collapsed to post-processing only (it makes no HTTP calls).

**Needed before the demo:** an icon for Cake. The Phoenix favicon and logo were removed with the rest of the Phoenix branding (#375) and nothing replaces them yet: the root layout declares an empty icon (`<link rel="icon" href="data:,">`), so a browser tab shows none. When there is one, put it in `priv/static/`, add it to `CakeWeb.static_paths/0`, and point that `<link>` at it.

**Post-demo planned:** test coverage expansion, Word/Excel/CSV/JPG pipelines.

**Longer-term:** autorating (`Search` or dedicated module), cross-encoder reranking (`Search`), HyDE-style query expansion (`Prompt` + `Retrieval`), multi-index search and result merging (`Retrieval`).
