---
title: "Cake — RAG Framework for Enterprise Document Q&A"
tags: [cake, rag, elixir, phoenix, opensearch, architecture, domain-model]
date: 2026-11-23
domain: architecture, reference
source: project-maintainer
---

# Cake

Cake is a RAG (Retrieval-Augmented Generation) framework built in Elixir/Phoenix. It ingests enterprise documents, stores embeddings in OpenSearch, and surfaces answers through a Phoenix LiveView chat interface. The immediate use case is a document Q&A tool for enterprise customers whose document formats include PDF, Word, Excel, CSV, and JPG. The demo-critical path is PDF ingestion, LiveView chat UI, and citation display. Other document formats are explicitly post-demo. A second ingestion system ships alongside the PDF one: programming documentation, parsed today from Elixir's own source.

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

**GDS ↔ ingestion pipeline behaviour: 1:1.** Each GDS has exactly one pipeline behaviour that targets it, and each pipeline behaviour produces exactly one GDS. `Cake.Books.Pipeline` targets the `ParsedBook` + `Chunk` GDS; `Cake.Documents.Pipeline` targets the `ParsedDocument` GDS. This is why, deliberately, no framework-level `Cake.Ingestion` master behaviour exists — the GDS *is* the unit of pipeline grouping, and unifying the two behaviours is deferred indefinitely.

**GDS → data structures: 1:many.** A GDS can be composed of multiple related Ecto schemas. The `ParsedBook` + `Chunk` GDS has two data structures (parent and child), where `Chunk` is the retrieval unit. The `ParsedDocument` GDS has one data structure and is its own retrieval unit.

**Data structure → pipeline implementation: 1:1 per source.** Each pipeline implementation produces records of exactly one data structure shape per run. `Cake.Books.Pdf.Pipeline` produces `ParsedBook` + `Chunk` records from a PDF. A future `Cake.Books.Epub.Pipeline` would produce the same shape from an EPUB.

**Pipeline behaviour → implementations: 1:many.** Each pipeline behaviour can have any number of concrete implementations. Adding a new source format is an additive operation against a stable behaviour; it never reshapes the GDS.

---

## Architecture: Application Layers

The system is organized into four layers. Each layer has a clear responsibility boundary, and modules within a layer communicate through defined interfaces (behaviours, function signatures, GenServer protocols). The guiding principle is that **modules are organized by what they're responsible for, not by what infrastructure they share.** Two functions that both call an HTTP API don't belong together unless they operate on the same domain concept and change for the same reasons.

### Layer 1: Ingestion — Two Parallel Pipeline Systems

The ingestion layer has two pipeline behaviours because the two GDSes have fundamentally different parsing requirements, metadata schemas, and chunking strategies. Each GDS owns its own ingestion contract.

**`Cake.Documents.Pipeline`** is the behaviour for ingesting programming documentation. Its GDS is `ParsedDocument`, and its callbacks are listed under "Behaviours and Implementations". The module also contains the `ingest/4` orchestrator that sequences callbacks into a stream pipeline — download → persist raw → parse → persist parsed → embed → index — plus an `ingest_with_sweep/5` variant that follows the run with `sweep`-based retry passes (nothing in `lib/` or `test/` calls the Documents one yet, #266). Current implementation: `Cake.Documents.Hexdocs.Pipeline`. Two dedup checks run inside the stages: the generic persist-parsed stage skips attrs whose `(source, version, package, title)` already exists (`ParsedDocuments.parsed_doc_exists?/4`), and the Hexdocs `persist_raw_docs/2` skips `(module, version)` pairs already stored (`Hexdocs.hexdoc_exists?/2`).

**`Cake.Books.Pipeline`** is the behaviour for ingesting books and book-like documents. Its GDS is `ParsedBook` + `Chunk`, and its callbacks are listed under "Behaviours and Implementations". Like `Documents.Pipeline`, the module also contains its own `ingest/4` orchestrator and an `ingest_with_sweep/5` variant that follows the run with `sweep`-based retry passes. Current implementation: `Cake.Books.Pdf.Pipeline`, which uses a Rustler NIF (`parsebooks` Rust crate wrapping `pdf-extract`). Two helper modules sit beside the behaviour: `Cake.Books.Persistence` owns the write path — `persist_books_and_chunks/2` takes the pair and the requested embedding model, looks the `file_hash` up and returns `{:duplicate, book}` for a `:completed` book whose every chunk was embedded under that model, resumes any other book behind the hash (another status, or `:completed` under another or an unknown model) with its existing chunks after clearing the vectors other models produced, and inserts a new book and its chunks otherwise (`insert_books_and_chunks/3` is that insert without the lookup; a run that loses the check-then-insert race to another is a duplicate only if the winner is already `:completed` under the requested model, and otherwise a `{:concurrent_ingest, winner_id}` persist failure for the sweep to retry) — and `Cake.Books.Retrieval` owns the read path that `ParsedBook` delegates its `load_from_hits/1` and `expand_with_neighbors/2` GDS callbacks to. The expansion returns, for each book, exactly the chunks within `offset` positions of a hit, once each, in ascending `chunk_index` order — a guarantee, so a caller knows which neighbours precede and follow a hit; the order of the books relative to each other is unspecified.

The two orchestrators take their arguments in different orders: Books is `ingest(embedding_service, format_pipeline, embedding_model, paths)`, Documents is `ingest(embedding_service, source_pipeline, version_tuple, embedding_model)`.

**`Cake.Pipelines`** provides shared infrastructure used by both pipeline types: `detuple_with_logging/3` filters `{:ok, _}/{:error, _}` streams and persists errors to `FailedIngest`, `log_and_persist_failure/3` persists one item's failure for a stage that handles outcomes itself, `add_to_search_backend/3` handles index upserts, and `sweep/3` implements a retry loop for item-level failures. A `Context` struct carries pipeline identity (behaviour, implementation, version) plus a per-run `run_id` through a run: the identity fields give error provenance, and `run_id` scopes `count_failures/1`, `finalize_ingest/3`, and `sweep/3` to one run so concurrent ingests of the same source never count or retry each other's failures. `Context` also carries an `opts` keyword, read for `:search_backend_timeout` (the per-record indexing deadline, default 5000 ms); both orchestrators build it with `opts: []` today. A Books run has no source version, so its `Context.version` is the embedding model, and that is what `FailedIngest.version` holds for Books rows.

### Layer 2: Search and Retrieval

**`Cake.Search`** is a vanilla module owning Cake-internal search orchestration. It exposes three search entry points (`search_chunks/4`, `search_chunks_with_context/5`, and `search_docs/4` — the latter an alias of `search_chunks/4` retained for call-site clarity), each supporting three modes (`:keyword`, `:vector`, `:hybrid`). Hybrid is the default. The module reads the target index and the search fields from the GDS module passed via the `:gds` opt. Only `search_chunks_with_context/5` goes further: it hydrates its hits and expands neighbors through that GDS and returns `Search.Result` structs, where `search_chunks/4` and `search_docs/4` return the backend's hits (`{:ok, [Hit.t()]}`). It also owns the pure scoring utilities (`cosine_similarity/2`, `score_results/2`, `normalize_and_combine/1`, `sort_by_relevance/1`) that rank retrieved results. Its tunables are public accessors — `default_size/0` (30), `default_k/0` (30), `default_ef_search/0` (256), `default_keyword_weight/0` (0.8, the boost on the hybrid `should` clause) and `default_expand_offset/0` (2, the neighbor window `search_chunks_with_context/5` expands by) — and each is overridable per call: `:size`, `:k`, `:ef_search`, `:keyword_weight` and `:fields` (replacing the GDS's `search_fields/0`) in opts, and `expand` as the fourth positional argument of `search_chunks_with_context/5`. Each mode reads only the opts it uses: `:keyword` reads `:fields` and `:size`; `:vector` reads `:k`, `:size` and `:ef_search`; `:hybrid` reads all five.

**`Cake.Search.Backend`** is the behaviour for search backends. Each backend translates `%Cake.Search.Query{}` into its native query format, executes it, and maps results back into `[%Cake.Search.Hit{}]`. Injected via config (`Application.get_env(:cake, :search_backend)`), mockable with Mox. Current implementation: `Cake.Search.Backend.OpenSearch`.

**`Cake.Search.Query`** is a struct-based composable query builder (its fields are in the struct inventory). Builder functions: `new/2` (accepts `:size` and `:min_score`), `knn/5` (an optional `:ef_search`, emitted as the clause's `method_parameters.ef_search`; `Cake.Search` always passes it), `match/4` (an optional `:boost`, default 1.0; `Cake.Search` passes the keyword weight as the boost on hybrid queries), `filter_term/3`, `min_score/2`, `size/2`. `Backend.OpenSearch.to_query_map/1` converts a Query into the nested map OpenSearch expects.

**`Cake.Search.Hit`** is the backend-agnostic search hit struct. Every backend maps its native hit type into `%Hit{}` at the boundary; downstream code (`load_from_hits/1`, result builders) works exclusively with hits. `Hit.id` is taken from the document's own `id` field in `_source`, not from the OpenSearch `_id`, so every indexer must store an `id` field — `Pipelines.add_to_search_backend/3` indexes each record under `record.id`, and so do the two retry-path indexers in `Books.Pipeline` and `Documents.Pipeline`, which call `Backend.backend().index_document/3` directly.

**`Cake.Search.Deployment`** is the OpenSearch `Snap.Cluster` — connection management and index lifecycle only, not query logic. Query construction lives in `Cake.Search.Query`. At boot it reads `collections/0` (the `{name_module, mapping_schema}` pairs in `:search_collections`) and calls `create_collections_unless_exist/2`, which lists the cluster's collections and creates the missing ones with `Backend.OpenSearch.build_mapping/1`: the schema-derived mapping (`:text` → `text`; `:embedding` → an HNSW `knn_vector`, sized by `:default_embedding_dimension`, on the `faiss` engine with cosine similarity, `ef_construction: 512`, `m: 16`; everything else `keyword`) plus three index settings: `index.knn`, a 30 s `index.refresh_interval` and `index.merge.policy.max_merge_at_once: 2`. `init/1` starts a linked task that polls `Process.whereis/1` every 10 s until the cluster process is registered and only then creates the collections, and that path calls `Backend.OpenSearch` directly rather than through `Backend.backend/0`, so a second backend would get no boot-time collection creation.

**`Cake.Embeddings`** calls the embedding service its provider argument names. OpenAI is the only one: `embed/3` has a single clause, `embed(:openai, …)`, and any other provider raises `FunctionClauseError`. Implements `Cake.Embeddings.Behaviour` for Mox substitution. It embeds the text it is given verbatim — it does no title prepending itself. At ingestion time the pipelines prepend a title to the text before calling it (the chunk's `section_title` for books, the document `title` for docs); query-time callers embed the question as-is. Used at both ingestion time (by the pipelines) and query time (by `Cake.Conversation`, and directly by `CakeWeb.SearchLive`, which is why `CakeWeb` declares `Cake.Embeddings` as a boundary dep).
Indices are one-per-GDS on a shared OpenSearch cluster: `collection_name/0` returns a fixed name per GDS (currently `"chunks_of_books"` and `"docs"`), created at boot by `Cake.Search.Deployment`.

### Layer 3: Conversation — Stateful Multi-Turn RAG

This layer is organized around a single principle: **`Cake.Conversation` is the sole orchestrator, and every other module in the layer is a peer service that it calls.** The dependency graph is a DAG. Peer-to-peer knowledge is minimal and deliberate: `Prompt` and `Responses` consume `Cake.Search` result types, `Responses` calls `Cake.Citations` (a kernel module that nothing else calls, `Conversation` included), and `Cake.Decomposition.LLM` calls `Prompt.decomposition_prompt/1` and `Generation.complete_json/3`.

```
Conversation → Prompt
Conversation → Decomposition (opt-in; Decomposition.LLM → Prompt, Generation)
Conversation → Search (Cake.Search → Cake.Search.Backend → OpenSearch)
Conversation → Embeddings
Conversation → Generation
Conversation → Responses (Responses → Citations)
```

**`Cake.Conversation`** is a GenServer managing single-conversation state: message history, retrieved chunks, chunk map, citations, accumulated errors. `start/1` spawns it under the `Cake.ConversationSupervisor` DynamicSupervisor. Its opts are a map: `:id` and `:gds` are validated before the process spawns (a missing one returns `{:error, %KeyError{}}`), `:embedder`, `:response_model` and `:provider` are required when the state is built, and the collaborator modules (`:embeddings`, `:generation`, `:responses`, `:decomposition`) and the three decomposition budgets are optional; an optional `:owner` pid (ChatLive passes itself) is monitored so the conversation stops when its owner exits. A turn starts one of two ways, and neither blocks the caller: every slow stage runs in a task under `Cake.TaskSupervisor` and reports back by PubSub broadcast (`Cake.Conversation.Events`). `autoask/2` casts the full retrieve-and-generate loop; `manualask/2` replies `:ok` and retrieves candidate results (`[Search.Result.t()]`) in a `:retrieving` state, broadcasting them as `{:candidates_ready, _}` for the user to pick from — `select_docs/2` then supplies the Citable ids of the chosen candidates (chunk ids, for books; the web layer groups candidates by document and expands a document selection back into candidate ids via `Cake.Candidates`), rejects unknown ids synchronously, and otherwise replies `:ok` while generation proceeds in a task. When the `:decomposition` opt is set (a `Cake.Decomposition` implementation; default `nil`), the first auto-mode turn decomposes the question before searching; when exactly, and what suppresses it, is under "Query Decomposition" below. Follow-up auto turns reuse cached search results rather than re-retrieving (`manualask/2` always searches again); a completed retrieval that found nothing (`[]`) is cached and reused like any other, distinguishable from the never-retrieved `nil`. A completed manual turn caches every candidate it retrieved, not only the ones the user selected, so the next auto turn answers over all of them.
**Events, queued turns, and error shapes.** `Cake.Conversation.Events` defines the four broadcast shapes on the `"conversation:#{id}"` topic (`Events.topic/1`): `{:state_change, state_name}` whenever the turn FSM moves (`:retrieving`, `:awaiting_selection`, `:generating`, `:idle` — an auto turn broadcasts `:generating` once before its combined retrieve-and-generate task and `:idle` when it finishes), `{:candidates_ready, candidates}`, `{:response_ready, %{response: text, citations: list}}`, and `{:error, reason}`. An `autoask/2` that arrives while a turn is `:generating` is stored in `queued_question` (a later one overwrites an earlier one) and replayed as a fresh turn when the current one ends, whether it completed, failed or crashed; every other invalid transition has no clause and crashes the GenServer by design — the UI is expected to prevent it. `select_docs/2` rejects unknown ids with `{:error, {:unknown_candidate_ids, ids}}` and returns the conversation to `:idle`. A `:flat` fan-out fails the whole turn with `{:error, :sub_search_timeout}` or `{:error, {:sub_search_crashed, reason}}`. Two collaborators' failures are typed: `t:Cake.Decomposition.error_reason/0` is `{:invalid_response, _}` or `{:generation, _}`, and `t:Cake.Generation.error_reason/0` enumerates transport, timeout, rate-limit, auth, HTTP-status, malformed-response, malformed-JSON, empty-response, content-filter and provider errors. The other two are not: an embedding failure is a `String.t()` and a search failure one of the backend's error structs (`t:Cake.Search.Backend.search_error/0`), and both are broadcast unchanged as `{:error, reason}`. Four read-only calls — `GenServer.call(pid, :search_results | :chunk_map | :citations | :inspect)` — expose state for tests and tooling with no public wrapper; `:search_results` replies `[]` for the never-retrieved `nil`. The child spec is `restart: :temporary`, which is what makes the owner-exit stop final under `Cake.ConversationSupervisor`.

**`Cake.Prompt`** owns prompt engineering. Builds the messages list for the LLM (system prompt, conversation history, retrieved context as a numbered block, user question). On auto turns `prepare_context/2` filters chunks by relevance floor and chunk ceiling and assigns dense 1..N indices; a manual turn does not go through it: `Conversation` numbers the candidates the user picked from 1 itself, with no relevance floor and no chunk ceiling. Also owns the decomposition-side prompts and budgeting: `decomposition_prompt/1` (the JSON-answering prompt `Decomposition.LLM` sends), `build_with_prior_answers/5` (folds accumulated sub-question/answer pairs into the system message for sequential resolution), `fit_answer_pairs/2` (evicts oldest pairs to fit the token budget), `estimate_tokens/1` (~4 chars/token estimate), the self-ask driver protocol — `self_ask_prompt/3` (the marker-teaching driver prompt with accumulated pairs folded in) and `parse_self_ask_response/1` (classifies the model's reply as a follow-up question or the final answer) — and the IRCoT driver protocol: `ircot_prompt/3` (the CoT driver prompt with accumulated reasoning steps and their retrieved context folded in), `ircot_schema/0` (the `reasoning`/`retrieval_query` JSON schema its structured replies must satisfy), and `parse_ircot_response/1` (classifies a validated step as continue-with-query or done). The rest of its public surface is the prompt text itself — `system_message_with_context/1`, `system_message_no_context/0`, `self_ask_system_message/0`, `ircot_system_message/0`, `decomposition_system_message/0` — plus `format_chunk/1` (one numbered context entry) and `history_messages/1`, which keeps only the last five exchanges. `prepare_context/2` returns `{indexed_chunks, context_quality}`, the quality being `:good` or `:none`; `Conversation` discards it today. Its ceiling and floor default to 10 chunks and a relevance of 0.3 (`:max_chunks`, `:min_relevance`), and `Conversation` passes neither opt, so nothing configures them. A result with no relevance score never passes the floor, whatever the floor: `nil` is not a score of zero. `parse_ircot_response/1` treats a blank `retrieval_query` as the terminator too, not only `null`.

**`Cake.Retrieval`** (planned) will own retrieval strategy: search, scoring, autorating. Today search and scoring are split between `Conversation` and `Cake.Search`, and autorating is not implemented anywhere.

**`Cake.Generation`** owns LLM completions. Two callbacks: `complete/3` (plain completion for the main answer) and `complete_json/3` (schema-constrained JSON completion, used by `Decomposition.LLM` and by `Conversation`'s IRCoT loop). Callers: `Conversation` and `Cake.Decomposition.LLM`. Defines `Cake.Generation` as a behaviour; `Cake.Generation.OpenAI` is the real implementation. `Cake.Generation.Anthropic` is a placeholder stub.

**`Cake.Responses`** handles post-generation processing. Builds the chunk map (integer index → chunk metadata), parses citation markers through `Cake.Citations`, keeps one citation per retrieval unit (by `Cake.Citable` `:id`, so a unit at two prompt indices is cited once, under the index whose marker appears first), renumbers the survivors 1..N by first appearance with no gaps, and rewrites the `[N]` markers in the text to match: two markers for one unit show the same number, and hallucinated markers take no number, are removed and are reported as warnings. It derives one `:download` action per unique non-`nil` citation `source_ref` (citations without one yield no action), and assembles the final structured response. `Cake.Responses.Behaviour` defines the contract; `Cake.Responses.Result` is the output struct. `Conversation` keeps the result's `chunk_map` and `citations` and broadcasts its `final_text` and `citations`; nothing reads `actions`, `warnings`, `media`, `assigns` or `raw_text` today (#419 is to carry the first two through to the chat).

**`Cake.Citations`** is a pure function module. Parses `[N]` markers from response text, resolves them against the chunk map, separates hallucinated indices out (they come back alongside the valid list, and `Responses` turns them into warnings), and deduplicates, preserving first-appearance order. The numeric renumbering happens inside `Cake.Responses`, which renumbers the survivors by first appearance; nothing sorts them. A `[0]` marker is always hallucinated, since prompt indices start at 1 on auto and manual turns alike, so it comes back as index `0` and `Responses` reports it as `{:hallucinated_citation, 0}`.

#### Query Decomposition

**`Cake.Decomposition`** is the behaviour for query-decomposition strategies. Its single callback `decompose/2` is retrieval-free — question in, `{:ok, Decomposition.Result.t()}` or `{:error, reason}` out. Strategies never touch `Search` or `Embeddings`; `Conversation` performs all retrieval and feeds results back in as data.

**The Result.** `Decomposition.Result` carries the outcome: `strategy` is `:none` (atomic), `:flat` (independent sub-questions), `:sequential` (at least one `%{question, depends_on}` entry carries a dependency; `new/2` validates the DAG acyclic, and `topological_order/1` yields the resolution order), `:self_ask` (the model discovers its own follow-up questions at resolution time, so `sub_questions` is empty; `new/2` never derives it — a strategy module marks it explicitly), or `:ircot` (the model interleaves retrieval with chain-of-thought reasoning, emitting a retrieval query per reasoning step; like `:self_ask`, `sub_questions` is empty and a strategy module marks it explicitly).

**Strategies and tiers.** `Cake.Decomposition.LLM` is the shipped strategy: prompt from `Prompt.decomposition_prompt/1`, schema-constrained output via `Generation.complete_json/3`; a Mox mock stands in for tests. Its JSON schema (`LLM.schema/0`) emits atomic-or-flat only — a `:sequential` result currently requires a strategy that emits dependency edges, and a `:self_ask` or `:ircot` result a strategy that marks it. The `Conversation`-side machinery for all five tiers (atomic, flat, sequential, self-ask, IRCoT) is in place. `Conversation` calls `decompose(question, [])`, so the shipped strategy runs on its own compile-time defaults — `Cake.Generation.OpenAI` and `"gpt-4o-mini"` — not the conversation's `:generation` collaborator or `response_model`.

**Integration.** Opt-in via `Conversation`'s `:decomposition` opt — and the web app does not opt in today: `config :cake, Cake.Conversation`, which `ChatLive` builds its start opts from, sets no `:decomposition`, so production conversations run with `decomposition: nil`. The implemented trigger is cache state, not turn count: decomposition runs when an `autoask/2` turn begins before any retrieval has completed (`search_results == nil`) — the first auto-mode turn. Manual mode never decomposes, and any completed retrieval suppresses it: a prior manual turn's cached candidates and an empty completed retrieval (`[]`) alike. What each tier then does (atomic, `:flat`, `:sequential`, `:self_ask`, `:ircot`), with its caps, its token budget and its failure rule, is in `Cake.Conversation`'s moduledoc under "Query decomposition"; the config keys behind the caps are under "Configuration Keys".

**Traceability.** Each merged result's `Search.Provenance` is stamped `decomposed: true`, with the `original_query` and a `sub_question_index` (its moduledoc says what the index counts under each strategy). Intermediate answers have their `[N]` markers stripped before being folded into the next prompt, and so do the self-ask final answer on the marker path and the IRCoT terminating reasoning: a `:self_ask` turn that ends by marker or an `:ircot` turn that ends by `null` reaches `Responses.process` with no markers and yields empty `citations`. Among the self-ask and IRCoT endings, only the cap-exhaustion synthesis paths cite the merged context; `:flat` and `:sequential` answers are always generated over it and cite it.

#### The Per-Turn Pipeline

Every arrow originates from `Conversation`:

1. User message arrives at `Conversation`.
2. `Conversation` resolves search results: cached results are reused; otherwise it embeds the question and searches via `Cake.Search.search_chunks_with_context/5`. With `:decomposition` set on such a no-cache `autoask` turn, `Decomposition.decompose` runs first and the turn searches once per sub-question, merging the results into one context (see "Query Decomposition" above). Manual mode retrieves through `manualask/2`.
3. `Conversation` → `Prompt.prepare_context` (filter and index chunks; they were ranked at retrieval, by `Search.sort_by_relevance/1`). Auto turns only: a manual turn indexes the user's selection instead.
4. `Conversation` → `Prompt.build` (assemble messages list).
5. `Conversation` → `Generation.complete` (LLM call).
6. `Conversation` → `Responses.process` (chunk map, citations, structuring).
7. `Conversation` updates state and notifies the frontend.

### Layer 4: Web — Phoenix LiveView Chat Interface

**`CakeWeb.ChatLive`** is the user-facing chat UI. It starts a `Conversation` GenServer and subscribes to its PubSub topic for state-change, candidates-ready, response-ready, and error broadcasts. The conversation's lifetime is the page's: ChatLive starts it as `:owner`, so it stops when the LiveView exits, and monitors it the other way round. If the conversation dies first, the page survives: it apologises, keeps the message history, disables the question form, and offers a "Start a new conversation" action that starts a fresh `Conversation` with no memory of the earlier turns (restoring that state is #39). One window remains in which an auto-mode question can be lost to a conversation that dies between ChatLive's liveness check and the cast, until `autoask/2` acknowledges acceptance (#311); the comments on `dispatch_question/3` have the detail. Domain-level candidate grouping and chunk-ID extraction are delegated to **`Cake.Candidates`** (a top-level boundary of its own, see "Module Boundaries"): it groups candidates by document id (the `Cake.Citable` `source_ref`, or the `id` of a unit with none), summarises a group for display — a title, a 100-character preview and a page label that counts distinct pages, so several chunks on page 5 read "PDF page 5" — and expands a selection of documents back into candidate ids (`all_chunk_ids/1`, behind "Use all", is every candidate's id). Two embedded-schema form modules live under `chat_live/`: **`QuestionForm`** (question + mode validation) and **`SelectionForm`** (document-selection validation with subset checking against available IDs).

**`CakeWeb.UploadLive`** is the book-upload UI: accepts PDF and ZIP uploads (ZIP archives are unpacked to PDFs via `Cake.Books.ZipExtractor`), writes the files through the configured `Cake.Books.Adapters` storage adapter, then runs `Cake.Books.Pipeline.ingest/4` with `Cake.Books.Pdf.Pipeline` as an async task. The upload limits (20 files, PDF or ZIP, through the drop zone and 200 PDFs through the folder option, each file up to 100 MB) bound compressed bytes only; `Cake.Books.ZipExtractor` bounds expansion, before and during inflation, by `:max_zip_entries` and `:max_zip_expanded_bytes` (its moduledoc says how, and why it reads the archive's directory itself). `UploadLive` reports a rejected archive with the limit it broke: as the page's error when nothing else in the batch can be ingested (that error names only the first rejected archive), otherwise in a warning listing each rejected archive while the rest of the batch is ingested. Indexed is not yet searchable: the collection takes in new documents every 30 seconds (`index.refresh_interval`, see `Cake.Search.Deployment` above), so a question asked or a search run sooner than that after the notice can find nothing, and nothing on this screen or in the chat says so (#410). A storage write that fails crashes the LiveView instead of being reported (#292).

**`CakeWeb.SearchLive`** is a direct search UI at `/search`: it embeds the query itself (`Cake.Embeddings` with `:default_provider` and `:default_embedding_model`), runs `Cake.Search.search_chunks_with_context/5` against the `Cake.Books.ParsedBook` GDS, which it hardcodes, and renders the grouped results without starting a conversation.

**`CakeWeb.ParsedBookLive.Index`** is the documents list at `/documents`: a read-only table of what has been uploaded, newest first (`Cake.Books.list_parsed_books_newest_first/0`, which returns a map of the six fields the list shows for each book, not a `ParsedBook`). The module keeps the name `mix phx.gen.live` gave it; to a user the screen is "Documents". The list is read when the page opens and again when the Refresh button is pressed, and the page says when it was last read: nothing announces that an ingest finished, since the ingestion layer broadcasts nothing. Every row shows what the database says, so the known defects show through: a book can read "failed" after a retry fixed it (#305), a scanned PDF "completed" with nothing searchable (#293), and a title the parser got wrong is shown wrong (#86).

**`CakeWeb.ParsedBookLive.Show`** is one document at `/documents/:id`: the same fields, plus its authors, its word count and the number of chunks it was split into (`Cake.Books.count_chunks/1`), as a `list/1`, with the download as the page's primary button. A well-formed id that matches no document is a 404; one that is not a UUID is a 400. There is no create, edit or delete on either page.

**`CakeWeb.Titles`** is how a document's title is displayed in the chat and on the documents pages (the search screen shows the stored title as it is): `display/1` for a stored title, and `display_citation_label/1`, the chat's variant, for a citation's label. Its moduledoc says what each removes and where the two differ. Neither corrects a title the parser got wrong (#86).

**`CakeWeb.BooksController`** serves authenticated book downloads at `/books/download/*file_path`: only keys recorded as a `ParsedBook`'s `source_file_path` that also pass `Cake.Books.Adapters.valid_key?/1` are read back through the configured adapter — the same store `UploadLive` writes to; anything else is reported as not found.

**`CakeWeb.AdminLive`** is the landing page of the admin area at `/admin`, where the top bar's Admin link leads: it names what an admin can manage, which today is the logins, and links to them.

**The admin panel for logins** is three LiveViews under `/admin/users`, inside the admin `live_session`, so every one of them is behind the admin guard. From them an admin creates a login, changes it, sets a new password for it, confirms its email by hand or takes the confirmation back, and removes it:

- **`CakeWeb.Admin.UserLive.Index`**, at `/admin/users`, lists every login in username order: username, email, role, whether the email is confirmed, and created date. "New login" is its primary action, and each row but the admin's own has a Delete button behind a confirmation. On a phone the table keeps the username, the role and Delete.
- **`CakeWeb.Admin.UserLive.Show`**, at `/admin/users/:id`, is one login's page: its fields, and the way to its form and to setting its password. It confirms an unconfirmed login by hand, or takes a confirmation back behind a confirmation dialog (`Cake.Accounts.set_user_confirmed/3`); the admin's own page has neither button, since nobody confirms their own email or takes their own confirmation back.- **`CakeWeb.Admin.UserLive.Form`** is the forms, one per live action: `:new` at `/admin/users/new` (username, email, password, role; `Cake.Accounts.create_user/1`), `:edit` at `/admin/users/:id/edit` (username, email and role, never the password; `Cake.Accounts.update_user/2`, which leaves the confirmation as it was: the admin vouches for the address they type) and `:password` at `/admin/users/:id/password` (a new password and nothing else; `Cake.Accounts.reset_user_password/2`).

What the panel refuses, it refuses on the page, and setting a password or deleting a login ends that user everywhere at once: the context deletes their sessions and tokens, and the LiveView then calls `CakeWeb.UserAuth.end_live_sessions/1`, which sends their open pages to the log-in page. The three modules' moduledocs carry the rest: which refusal lands on which field, why a typed password never comes back and what a crash report can still print (#399), and how two admins working at once are kept from overwriting each other or acting on a login that is gone.

**`CakeWeb.Router`** is the map of who may open what. The home page is open to everyone. The chat, the documents pages, the search and the upload are one `live_session` (`:authenticated_app`) behind a log-in, so moving between them is a live navigation and not a page load; the download route sits behind the same plug. The admin area is a `live_session` of its own (`:admin`). The account pages are in three more: the ones a logged-in user is turned away from (register, log in, the two password-reset pages), the settings page, which needs a log-in, and the two confirmation pages, open to both. `CakeWeb.UserSessionController` takes the log-in form's POST and the log-out; the settings page's password form posts to the same action with `_action=password_updated`, which logs the user in again after the change and returns them to the settings page. The settings `live_session` also routes `/users/settings/confirm_email/:token`, the link mailed for an email change. In development only, `/dev/dashboard` and `/dev/mailbox` are Phoenix's LiveDashboard and the Swoosh mailbox, where the mails the account pages send can be read.

**`CakeWeb.UserAuth`** provides the authentication plugs (`fetch_current_user/2`, which the `:browser` pipeline runs on every request, `require_authenticated_user/2`, `redirect_if_user_is_authenticated/2` and `require_admin/2`) and the four `on_mount/4` LiveView hooks (`:mount_current_user`, `:ensure_authenticated`, `:redirect_if_user_is_authenticated`, `:ensure_admin`) that the router's `live_session`s use. The `/admin` scope is behind the plug `require_admin/2` and the hook `:ensure_admin`: an admin goes through, a logged-in user who is not one is sent to the home page with a "not authorized" flash, and a visitor who is not logged in is sent to the log-in page. Neither needs the authentication plug or hook before it. Both read the user, and so the role, from the database on each request and each mount, so a demotion takes effect on the user's next navigation. Two more checks cover a page that is already open, which a guard that runs on mount cannot reach: `end_live_sessions/1` sends a user's open pages to the log-in page when their sessions are ended, and `:ensure_admin` looks the session up again on every event of a connected admin page (their `@doc`s say how). These `live_session` hooks are the only access check on a LiveView mount (no LiveView declares its own `on_mount`), so they must run on every connected mount; `CakeWeb.LiveJoinAuthorizationTest` pins that a join without a URL cannot skip them.

#### The Account Pages

Seven LiveViews. A user logs in with a username. Every user also has an email, and cannot log in until it is confirmed. Each page is a `header/1` and a form in a card, at the shell's default width. Tokens, sessions and hashing are as `mix phx.gen.auth` generates them.

| Page | Module | Route | What it needs |
|---|---|---|---|
| Log in | `CakeWeb.UserLoginLive` | `/users/log_in` | A username and a password. The form posts to `CakeWeb.UserSessionController`, which answers a wrong username and a wrong password alike, and refuses a user whose email is not confirmed, saying so only when the password is right. The page links to the confirmation instructions page. |
| Register | `CakeWeb.UserRegistrationLive` | `/users/register` | A username, an email and a password. It sends the confirmation instructions and sends the visitor to the log-in page; it logs nobody in. |
| Settings | `CakeWeb.UserSettingsLive` | `/users/settings` | A logged-in user. Shows the username, which this page does not change (an admin's action, #376). Offers changing the email, confirmed by a link mailed to the new address (the link opens this same LiveView at `/users/settings/confirm_email/:token`), and changing the password. |
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

The links come from the user's role as it was when the page was loaded, and they are only links: the routes are guarded by `CakeWeb.UserAuth` whatever the bar shows. `CakeWeb.Layouts.app/1`'s `@doc` says how a page marks itself as the current one, why its own entry is then not a link, and how the bar collapses on a narrow screen.

**`CakeWeb.PageController`** serves the home page at `/`. A visitor gets the product name, one sentence about it and a log-in button, inside the shell. A signed-in user is redirected to `/chat`, with any flash carried along; log-in itself still lands on `/`, so this is where a user arrives after logging in.

**`CakeWeb.ErrorHTML`** renders the error pages for HTML requests: one page for every status, with the status code, its standard message and a link home. The endpoint renders it inside the root layout (`render_errors` in `config/config.exs`), so it is styled and themed, and outside the shell, because an error can happen before the request has a user or a flash. In development Phoenix's debug page is shown instead. JSON errors are `CakeWeb.ErrorJSON`'s.

#### Components, Layouts and Assets

The web layer's kit is the one `mix phx.new` generates on Phoenix 1.8: Tailwind v4 with daisyUI 5, built without Node. `.claude/rules/front-end.md` has the working rules (generator first, daisyUI classes over ad-hoc utilities, where each file comes from and how to update it) and, under "Look and feel", the conventions that keep screens alike. `docs/ui-reference/` holds reference screenshots of the home page, the shell and the search screen in each state, in both themes and at two widths (the member's open menu at phone width only), to put a new screen beside. `docs/demo-script.md` is the path through all of these screens that a presenter or a tester follows, with the limits they will meet on the way.

**`CakeWeb.CoreComponents`** is the generated component library, styled with daisyUI classes: `flash/1`, `button/1`, `input/1`, `header/1`, `table/1`, `list/1` and `icon/1`, the `show/2` and `hide/2` JS commands, and `translate_error/1` and `translate_errors/2`. `use CakeWeb, :html` and `:live_view` import it. Cake adds four components to it: the three state components that every screen uses for the same three situations (`empty_state/1`, `working/1` and `notice/1`), and `status_badge/1` for an ingestion status. Their `@doc`s, and "States" and "Chips and badges" in `.claude/rules/front-end.md`, say when each is used. Two generated components carry an edit: a `table/1` `:col` may carry a `class`, and `header/1` takes one.

**`CakeWeb.Layouts`** holds the layouts: `root.html.heex`, the HTML skeleton every page is rendered into, which sets the theme before first paint and the page title ("<page> · Cake" for a page that assigns `page_title`, "Cake" for one that assigns none); `app/1`, the app shell (see "The App Shell" above); `flash_group/1`, which renders the flash messages and the two connection-lost notices as daisyUI toasts; and `theme_toggle/1`, the top bar's system / light / dark switch. Each LiveView and the home page call `app/1` from their own template (`<Layouts.app flash={@flash} current_user={@current_user}>`); `use CakeWeb, :live_view` names no layout.

**Assets.** `assets/css/app.css` is the stylesheet's entry point and the whole Tailwind configuration, the two themes (`light` and `dark`) included. `assets/js/app.js` connects the LiveSocket and the topbar, and hands the LiveSocket the hooks, each a file beside it (`follow_newest.js`, the chat's, is the only one). `mix assets.build` writes `priv/static/assets/css/app.css` and `priv/static/assets/js/app.js`, and `mix assets.deploy` minifies and digests them. Neither needs Node. Where each file comes from, how to update it, and what the kit leaves out while Cake is on LiveView 1.0 are in `.claude/rules/front-end.md`.

#### Roles and the First Admin

A user is a `:member` or an `:admin` (`Cake.Accounts.User`'s `role`). Registration always makes a member, whatever the request carries. There is always at least one admin: `Cake.Accounts.update_user_role/2`, `Cake.Accounts.update_user/2` (the admin panel's, which changes the username, the email and the role together) and `Cake.Accounts.delete_user/1` refuse to demote or delete the last one with `{:error, :last_admin}`. They go by the role in the database and are decided one at a time, under one advisory lock (`delete_user/1`'s `@doc` says why, under "Concurrency").

**To give someone a login**, an admin opens Admin, then Logins, then "New login" (`/admin/users/new`), types a username, the person's email and a password, picks a role, and tells the person the password. The login works at once (see "Confirmation"). To change it later, open the login from the list and use "Set password", which also logs that person out everywhere.

No screen can create the first admin, because every admin screen needs an admin. It is created by calling `Cake.Accounts.create_user/1` with a username, an email, a password and a role. All four are required. The password must never be an argument on the command line, where it is left in the shell history and shown in the process list.

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

The dev seed (`priv/repo/seeds.exs`) creates a dev login, `admin`, as a confirmed admin, and makes it one on a database that was seeded before roles or confirmation existed. Its password is in the repository, and the dev image's `entrypoint.sh` runs the seed on every boot, so that image must never serve anyone but a developer. What keeps the seed out of a release is under "Deployment".

### Supervision Tree Boot Order

The application starts children in this order under Cake.Application:

1. `CakeWeb.Telemetry` — telemetry metrics
2. `Cake.Repo` — Postgres connection pool
3. Oban — background job processing
4. `DNSCluster` — DNS-based node discovery
5. `Phoenix.PubSub` — pub/sub for LiveView
6. `Finch` (`Cake.Finch`) — the HTTP client pool for Swoosh's API client, which only the prod config names; the OpenAI and S3 clients go through Req's own pool
7. `Cake.Search.Deployment` — OpenSearch connection + index creation
8. `Task.Supervisor` (`Cake.TaskSupervisor`) — shared task supervisor: conversation turn tasks, flat-decomposition sub-search fan-out, and every ingestion fan-out (see "Error Handling in Pipelines")
9. `DynamicSupervisor` (`Cake.ConversationSupervisor`) — supervises the per-session `Conversation` GenServers started via `Conversation.start/1` (`:temporary` children; each stops on its own when its `:owner` LiveView exits)
10. `CakeWeb.Endpoint` — Phoenix HTTP server (last, so all dependencies are ready)

Every `mix test` run starts the application, so this boot order runs in every ExUnit job (`server: false` in test only keeps the endpoint from listening). What the compose smoke test alone adds is the boot of the real stack through `entrypoint.sh` and the assertion that step 7 created both collections (`.claude/rules/compose-smoke.md`).

### Module Boundaries (enforced by `boundary`)

The layer responsibilities above are enforced at compile time by the [`boundary`](https://hex.pm/packages/boundary) compiler. Each top-level context is a boundary that declares the boundaries it may call (`deps`) and the modules it makes public (`exports`); any cross-boundary call not covered by a declared dep is a compiler warning, which fails the build under `--warnings-as-errors` (how `mix precommit`, `mix quality` and CI compile). Calls made from a protocol implementation are not checked unless it is classified into a boundary, and none of the four `defimpl`s is.

- **`Cake`** — the shared kernel: `Repo`, `Schema`, `Mailer`, the `GDS` behaviour, the `Citable`/`Promptable` protocols, `Citations`, `FailedIngests` and `FailedIngests.FailedIngest`, `ParseBooks`. `Cake.Release`, the release's database tasks, is in the kernel too, and is not exported: it touches only `Cake.Repo`, and nothing calls it but the release's own scripts (see "Deployment"). Depends on nothing internal; every context may depend on it.
- **Ingestion** — `Cake.Books` (exports `Adapters`, `ParsedBook`, `Chunk`, `Pipeline`, `Pdf.Pipeline`, `ZipExtractor`) and `Cake.Documents` (exports `Pipeline`, `Hexdocs.Pipeline`, `ParsedDocument`) depend on `Cake.Search`, `Cake.Embeddings`, and `Cake.Pipelines` (exports `Context`; in turn depends on `Cake.Search`).
- **Retrieval** — `Cake.Search` depends only on the kernel and exports `Result`, `Query`, `Hit`, `Backend`, `Provenance` and `Deployment`. The collections created at boot come from `:search_collections` config, which is what keeps the search layer from depending back on the ingestion contexts (an otherwise-cyclic dependency). `Cake.Embeddings` likewise depends only on the kernel and exports `Behaviour`.
- **Conversation** — `Cake.Conversation` is the orchestrator (exports `Events`); it depends on `Cake.Prompt` (exports nothing), `Cake.Search`, `Cake.Embeddings`, `Cake.Generation` (exports `OpenAI` only, so `Cake.Generation.Anthropic` is unreachable from outside its boundary), `Cake.Responses` (exports `Result`), and `Cake.Decomposition` (exports `Result` and `LLM`). Peer-to-peer deps among the service modules are minimal: `Cake.Responses → Cake.Search`, `Cake.Prompt → Cake.Search` (for the `Result` type), and `Cake.Decomposition → Cake.Prompt`/`Cake.Generation`. Nothing depends back on `Cake.Conversation` except the web layer. `Cake.Candidates` is a top-level boundary of its own (deps `Cake` and `Cake.Search`, exports nothing) that the web layer calls alongside `Conversation`.
- **Accounts** — `Cake.Accounts` depends only on the kernel and exports `User`.
- **Web / jobs / app / tasks** — `CakeWeb` depends on `Cake`, `Cake.Accounts`, `Cake.Books`, `Cake.Candidates`, `Cake.Conversation`, `Cake.Embeddings` and `Cake.Search`, and exports `Endpoint` and `Telemetry`; `Cake.Jobs` depends on `Cake.Documents`; Cake.Application (top-level, `@moduledoc false`) on `Cake`, `CakeWeb` and `Cake.Search`. The three Mix tasks are top-level boundaries of their own: `Mix.Tasks.Precommit` and `Mix.Tasks.Hooks.Install` with no deps, `Mix.Tasks.Cake.Nif.Check` depending on `Cake`.

The compiler runs in `:dev`/`:prod` only — test files and support modules deliberately cross boundaries, so `:test` is excluded — and CI enforces it with a dev-env compile. When you add a cross-context call, declare the `dep` (and `export` the target module) rather than working around the boundary.

---

## The RAG Loop: End-to-End Data Flow

This section traces how content flows from raw document to user-facing answer, connecting the layers described above.

1. **Acquire**: A pipeline implementation fetches source content (a PDF binary from the storage adapter, a `git clone` of elixir-lang/elixir for hexdocs, etc.).
2. **Persist raw**: Raw content is persisted before parsing (the "raw data first" principle, under "Raw Data Structs"). Where it lives depends on the pipeline: Hexdocs source goes to Postgres as `Hexdoc.content`; book binaries go to the `Cake.Books.Adapters` store, with Postgres holding the book's `source_file_path` (the storage key) and `file_hash`.
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
| `FailedIngest` | `Cake.FailedIngests.FailedIngest` | Persists pipeline failures, tagged with the recording run's `run_id`: item-level ones, for retry via `Cake.Pipelines.sweep/3`, and pipeline-fatal ones (`pipeline_fatal: true`), which the run-scoped listing and the sweep leave out. |
| `User` | `Cake.Accounts.User` | Phoenix authentication user record: a `username` (what a user logs in with; 3 to 32 characters, compared case-insensitively and stored as typed), a `role` (`:member` or `:admin`), an `email` (required; a user cannot log in until it is confirmed, `confirmed_at`), and a hashed password. |
| `UserToken` | `Cake.Accounts.UserToken` | Session tokens, and the mailed tokens for email confirmation, password reset and email change. |

### Non-Ecto Domain Structs

| Struct | Module | Purpose |
|---|---|---|
| `Pipelines.Context` | `Cake.Pipelines.Context` | A run's identity and options, carried through an ingestion run. Fields: `run_id`, `behaviour`, `implementation`, `version`, `opts`. Layer 1, `Cake.Pipelines`, says what each is for. |
| `Search.Query` | `Cake.Search.Query` | Composable query builder. Fields: `index` (enforced), `size` (default 10), `must`, `should`, `filter` (each default `[]`), `min_score` (default `nil`). |
| `Search.Hit` | `Cake.Search.Hit` | Backend-agnostic search hit. Every backend maps its native hit type into this struct at the boundary. Fields: `id`, `score`, `source`. |
| `Search.Result` | `Cake.Search.Result` | Normalized search result. Carries retrieval unit, the `index` (collection name) it came from, backend score, CAKE-computed scores (cosine, relevance), hit provenance (search vs. expansion), search conditions, and prompt index. Single carrier of all retrieval metadata through the pipeline. |
| `Search.Provenance` | `Cake.Search.Provenance` | Search conditions attached to each `Search.Result`: search type, query text, decomposition traceability (`decomposed`, `original_query`, `sub_question_index`), and `embedding_model` — the model the query vector was embedded under, from the `:embedding_model` search opt (the stored vector's model is on the retrieval unit). |
| `Responses.Result` | `Cake.Responses.Result` | Output struct from post-generation processing. Fields: `raw_text`, `final_text`, `chunk_map`, `citations`, `media` (always `[]` — a stub stage), `actions`, `assigns` (always `%{}` — nothing writes it), `warnings`. Layer 3, `Cake.Responses`, says how each is built. |
| `Conversation.State` | `Cake.Conversation.State` | Internal state for the `Conversation` GenServer. Enforced keys: `id`, `embedder`, `response_model`, `provider`, `gds`, and the three decomposition budgets `max_context_tokens` (for accumulated answers/steps), `max_self_ask_iterations` and `max_ircot_iterations` (round caps) — the budgets are enforced rather than defaulted so their config.exs defaults, read by `Conversation.build_state/1`, cannot drift from a struct-level copy. Also carries the collaborator modules (`embeddings`, `generation`, `responses`, `decomposition`), the turn FSM fields (`state`, `pending`, `turn_ref`, `turn_pid`, `queued_question`), the `owner_ref` monitor on the optional `:owner` pid, search results, message history, chunk map, citations, and accumulated errors. |
| `Books.PageContent` | `Cake.Books.PageContent` | Elixir-side struct the Rust PDF NIF decodes into (via NifStruct): one page's extracted text and page number. |
| `Books.PdfExtraction` | `Cake.Books.PdfExtraction` | Elixir-side struct the Rust PDF NIF decodes into: the full extraction result (pages, skipped pages, title). |
| `Books.SkippedPage` | `Cake.Books.SkippedPage` | Elixir-side struct the Rust PDF NIF decodes into: a page that could not be extracted, with its page number and a `reason` string. |
| `Decomposition.Result` | `Cake.Decomposition.Result` | Outcome of decomposing a question. Fields: `original_question` (enforced), `strategy`, `sub_questions` (`%{question, depends_on}` entries), `question_index` (positional index → entry, which `Search.Provenance` refers to). "Query Decomposition" says what each strategy means and what `new/2` validates. |

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

## Data Schemas: Field-Level Detail

### ParsedDocument Fields

`source` (pipeline identifier), `version`, `package` (module/gem/class name), `language`, `title` (function/method name — used in embeddings), `text`, `url`, `embedding` (an array of floats whose length is the embedding model's output dimension (1536 for the default, `text-embedding-ada-002`)), `embedding_model` (nullable string: the model that produced `embedding`, written in the same update; `nil` until embedded, and on rows embedded before the column existed), `core` (boolean: part of stdlib?). Query helpers: `base_query/0`, `by_version/2`, `by_language/2`, `by_source/2`.

### Hexdoc Fields

`module`, `version`, `core` (boolean, default `true`), `url`, `content` (the raw Elixir source), `source` (default `"hexdocs"`), `language` (default `"elixir"`). Query helpers: `base_query/0`, `by_module/2`, `by_version/2`; `to_parsed_docs/1` turns one row into the `ParsedDocument` attrs the parse stage emits: one per `def` or `defp` clause (private functions are retrieval context too), titled `name/arity`, with the preceding `@doc` carried whether written as a string, a `~S`/`~s` sigil or a keyword list; `defmacro`, `defguard`, `defdelegate` and the other forms are skipped.

### ParsedBook Fields

`title`, `source_file_path` (required; the `Cake.Books.Adapters` storage key the binary was written under — `CakeWeb.BooksController` reads it back through the configured adapter for downloads — and the `Citable` `source_ref`), `authors` (string array), `source_format`, `file_hash` (deduplication), `file_size`, `word_count`, `total_pages`, `parsed_at`, `embedding_status` (enum: pending/processing/completed/failed — `pending` from parsing, `processing` once the book's chunks begin to embed, and the final value written after the index stage, so `completed` means every chunk embedded *and* indexed; how it decides whether a re-upload is a duplicate or a book to resume is under `Cake.Books.Persistence`, Layer 1), `metadata` (map), `table_of_contents` (map), `language` (ISO code), `isbn`, `publisher`, `publication_date`. Eight fields are required: `source_file_path`, `source_format`, `file_hash`, `file_size`, `title`, `word_count`, `parsed_at` and `embedding_status`. Seven are declared but written by nothing in `lib/` (the PDF pipeline sets none of them): `authors`, `isbn`, `publisher`, `publication_date`, `language`, `metadata` and `table_of_contents`. Has many `Chunk` records. Query helpers: `base_query/0`, `by_title/2`, `by_language/2`, `by_file_path/2`, `by_author/2`, `by_format/2`, `by_isbn/2`, `by_publisher/2`, `published_on/2`, `published_before/2`, `published_after/2`, `parsed_on/2`, `parsed_before/2`, `parsed_after/2`.

### Chunk Fields

`text`, `page_number` (nullable), `chunk_index` (ordering for unpaginated formats), `section_title` (read as the prefix of the text that is embedded and as the boosted keyword-search field, but written by nothing in `lib/`: the PDF pipeline builds its chunks without one), `word_count`, `char_count`, `embedding` and `embedding_model` (both as on `ParsedDocument` above). Belongs to `ParsedBook`. Query helpers: `base_query/0`, `by_book/2`, `on_page/2`, `within_pages/3`, `by_section/2`.

### FailedIngest Fields

`run_id` (UUID of the `Pipelines.Context` run that recorded it; required on new rows, nullable in the table for rows predating it, which stay listable as historical records but sit outside the run-scoped `count_failures/1` and `sweep/3`), `pipeline_behaviour`, `pipeline_implementation`, `step`, `version`, `error_text`, `input_identifier`, `pipeline_fatal` (boolean), `retry_count`, `last_retried_at` (both declared, but nothing in `lib/` writes them: a sweep deletes resolved rows and leaves unresolved rows untouched).

---

## Adding a New GDS

Start from the question under "Generic Data Structure (GDS)" (why the customer wants this kind of documentation, and what atomic unit a search should return). The answer determines whether your GDS is a single schema or a parent/child pair. Existing GDSes (`ParsedBook` + `Chunk` and `ParsedDocument`) are the reference implementations.

1. **Design the schema(s).** Decide single-schema vs. parent/child. Use `Cake.Schema`. Every changeset with string fields must call `sanitize_text_fields/1`. UUIDs are binary.
2. **Declare `use Cake.GDS` on the identity module.** Implement `collection_name/0`, `search_fields/0`, `load_from_hits/1`. Override `expand_with_neighbors/2` if the GDS has ordering; otherwise inherit the identity default.
3. **Implement `Cake.Promptable`** on the retrieval-unit schema. Define how a search result renders in the numbered context block.
4. **Implement `Cake.Citable`** on the retrieval-unit schema. Define citation metadata: the five-key map described under "Protocols and Implementations".
5. **Design a pipeline behaviour** targeting this GDS, or implement an existing one if the GDS already has a behaviour.
6. **Register the collection in `config :cake, :search_collections`** as a `{IdentityModule, RetrievalUnitSchema}` pair. `Cake.Search.Deployment` creates every registered collection at boot, with a mapping derived from the retrieval-unit schema's fields (the rule is under `Cake.Search.Deployment` in Layer 2), so that schema must carry `:text` and `:embedding` fields. Nobody hand-writes a mapping, and an unregistered GDS gets no collection.
7. **Thread the GDS through `Cake.Conversation`.** Pass `gds: YourGDS` in opts. `Cake.Search` will use the GDS's callbacks for collection name, field selection, hit hydration, and neighbor expansion.

---

## Adding a New Ingestion Pipeline

### For an Existing GDS

Implement the behaviour for the target GDS. Consult `Cake.Books.Pdf.Pipeline` or `Cake.Documents.Hexdocs.Pipeline` as reference implementations.

### Adding a New Documentation Source (Cake.Documents.Pipeline)

1. Create a raw document schema for intermediate storage.
2. Implement the behaviour's callbacks (listed under "Behaviours and Implementations"). The source identifier (e.g. `"hexdocs"`) is a property of the data, not of the module: `parse/2` emits it as the `:source` attr of every `ParsedDocument` (for hexdocs, `Hexdoc.doc_attrs/0` is the single source of truth: `Hexdoc.to_parsed_docs/1` merges it into every attrs map it emits).
3. Register with Oban via `DocumentIngestionJob.enqueue_for_version/4`.
4. Follow the result-tuple contract under "Requirements for All Pipeline Implementations". For this behaviour, `download/1` is the direct fallible callback (`{:ok, paths}` or the tagged `{:error, :download, reason}`), `persist_raw_docs/2` and `parse/2` are the stream callbacks, and `success_message/1` is declarative.
5. Optionally implement `retry_from_raw/2`.

### Adding a New Book Format (Cake.Books.Pipeline)

1. Implement the behaviour's callbacks (listed under "Behaviours and Implementations").
2. Add format-specific parsing logic.
3. New schemas must `use Cake.Schema` and include `sanitize_text_fields/1`.

### Requirements for All Pipeline Implementations

Every stream step must record its per-item failures to `FailedIngest`, under a descriptive step name, through one of two `Cake.Pipelines` functions — never a silent filter that drops a failure without persisting it. `Pipelines.detuple_with_logging/3` is the default: fallible per-item work produces result tuples that the callback detuples (persisting failures) before returning, so the stream a callback returns carries bare successful values. `Pipelines.log_and_persist_failure/3` is for a step that handles each item's outcome itself and has no result-tuple stream to detuple — the Books embed stage uses it, recording every failed chunk under `"books.embed"` as it maps embedding results back onto chunks. Direct fallible callbacks return `{:ok, _}` / `{:error, _}` (plus `download/1`'s tagged `{:error, :download, reason}`); declarative callbacks return bare values; and `Books.Pipeline.parse/1` returns a bare pair on success and raises on failure — the orchestrator rescues the exception into the per-item error tuple, and any returned value (an `{:error, _}` included) is wrapped as success, so never signal failure from it by return value. Pipeline-fatal errors go in the `else` branch of the behaviour's `ingest` `with` chain, which must open with at least one eager, run-level fallible step (see "Pipeline-Fatal Steps and the `with` Chain" below). A stage that fans its items out to tasks follows the fan-out rule under "Error Handling in Pipelines" below. Persist raw data first.

---

## Error Handling in Pipelines

Cake distinguishes between item-level failures (one document fails to parse) and pipeline-fatal failures (the download step itself fails). Item-level failures are persisted to `FailedIngest` via `detuple_with_logging/3`, tagged with the run's `run_id`, and can be retried via `sweep/3`, which only ever touches that run's rows. `sweep/3` makes at most `:max_sweeps` passes (default 2) and stops early when a pass resolves nothing; `ingest_with_sweep/5` returns the ingest's own result and only logs what the sweep resolved. The sweep calls each pipeline's `retry/4` with no rescue, so `retry/4` answers every row with a result tuple: a row recorded under a step it has no strategy for (`Documents.Pipeline`: a source pipeline's own `"docs.persist_raw"` and `"docs.parse"`) gets `{:error, {:unsupported_step, step}}`, and a row with no `input_identifier` to resume from gets `{:error, {:no_input_identifier, failure_id}}`; both are logged and counted as remaining, never retried. For the steps it does handle, `retry/4` dispatches on the row's step: Books re-runs `"books.load_binary"`, `"books.parse"` and `"books.persist"` from the file and resumes `"books.embed"` and `"search_backend.index"` from the persisted chunk; Documents sends `"docs.persist"` back through the source pipeline's `retry_from_raw/2` and resumes `"docs.embed"`, `"docs.embed_persist"` and `"search_backend.index"` from the persisted document. When what a retry resumes from is gone it answers `{:error, {:chunk_not_found, id}}`, `{:error, {:document_not_found, id}}` or `{:error, {:raw_doc_not_found, id}}`, and `{:error, {:retry_not_implemented, module}}` when the source pipeline has no `retry_from_raw/2`. A retry asked to embed under a model other than the one its book (Books) or corpus (Documents: same `source` and `version`) already carries (or where a vector's model was never recorded, reported as `nil`) is refused the same way, with `{:error, {:embedding_model_mismatch, id, stored_models, requested}}`; a `"docs.persist"` retry is checked before its re-parsed documents are inserted: a retry repairs one item, and moving a book or corpus to a new model is a re-ingest (#284). Pipeline-fatal failures short-circuit the `with` chain and are logged in the `else` branch.

**A crash inside one item's task is an item-level failure.** Every ingestion fan-out — the persist, embed and index stages of both pipelines, and the stages a source pipeline runs inside its own callbacks — starts its per-item tasks unlinked under `Cake.TaskSupervisor`, via `Task.Supervisor.async_stream_nolink/4` with `zip_input_on_exit: true` and the stage's timeout, never through a plain `Task.async_stream/3`. (A plain `async_stream` links each task to the process consuming the stream, so one crash would abort the whole run with no per-item record.) Unlinked, the crash reaches the stream as `{:exit, {input, reason}}`, the same shape a task killed on timeout produces, and the stage's result handler records a `FailedIngest` row for that item under its step name — with the item's identifier as `input_identifier` (the chunk or document id, the storage key, the hexdoc module, the source file's path in the first Hexdocs raw-document stage, or `package@version` for a `"docs.persist"` item; a Books persist exit whose input is not a book-and-chunks pair has none) and the exception, as inspected, in `error_text` — then the run continues with the next item. A stage whose task body rescues its own exceptions into a result tuple (`"docs.persist"`, the Hexdocs `safe_*` helpers) records the exception message that way instead, so only a non-exception exit reaches its `{:exit, _}` clause.

### Pipeline-Fatal Steps and the `with` Chain

A `with` clause short-circuits to `else` only when its result fails to match its pattern. No stream stage in a pipeline can fail the chain, since its per-item failures are lazy and are persisted by `detuple_with_logging/3` as the stream is consumed: the Books stage functions return `{:ok, stream}` unconditionally, and the Documents stages and `Pipelines.add_to_search_backend/3` return a bare stream, bound by a clause that always matches. So a `with` chain made only of stream stages can never reach its `else` branch. Its `else` would be dead code, and pipeline-fatal errors would have nowhere to go.

**Rule:** every pipeline behaviour's `ingest` `with` chain must include at least one **eager, run-level fallible step**. This is a clause that runs before any stream is built, decides whether the run as a whole can proceed, and returns either `{:ok, value}` or the tagged `{:error, step, reason}` (`step` an atom naming the step). The chain's `else` routes every such error through `Pipelines.handle_ingest_error/2`. That call logs it with the run's `Context`, persists a `FailedIngest` row with `pipeline_fatal: true` and `step: Atom.to_string(step)`, and returns `{:error, {step, reason}}` to the caller. An untagged `{:error, reason}` that reaches the `else` is persisted the same way under `step: "ingest"` and returned unchanged. Don't add an `else` to a chain with no fallible step. Add the step first, and test that its failure reaches `handle_ingest_error/2`.

| Pipeline | Run-level fallible step | Fatal errors |
|---|---|---|
| `Cake.Documents.Pipeline.ingest/4` | `source_pipeline.download/1` | `{:error, {:download, reason}}` |
| `Cake.Books.Pipeline.ingest/4` | `Cake.Books.Pipeline.validate_paths/1` | `{:error, {:validate_paths, :no_paths}}` for an empty key list; `{:error, {:validate_paths, {:invalid_paths, keys}}}` when any key is not a non-blank, NUL-free, valid UTF-8 string (`keys` lists every invalid one unchanged; keys are identifiers, so they are never sanitized) |

`Cake.Schema.sanitize_text_fields/2` (the `sanitize_text_fields/1` helper `use Cake.Schema` injects into each schema) strips NUL bytes from `:string` fields because Postgres cannot store them. That is right for free text and wrong for identifiers: an identifier field such as `ParsedBook.source_file_path` or `FailedIngest.input_identifier` must never rely on it, because a stripped key no longer names the object it was loaded from. Reject unstorable identifiers at the pipeline's run-level fallible step instead, as `validate_paths/1` does.

Pipeline-fatal and item-level failures are separate. A fatal error means nothing was attempted, and the caller gets `{:error, {step, reason}}`. A run where every item failed still completes, and the caller gets `{:error, {:no_items_ingested, summary}}` from `finalize_ingest/3` in the `do` body, never from `else`.

Item-level step names follow `"pipeline.step"` convention (e.g., `"books.parse"`, `"docs.embed"`), with one exception: the index stage both pipelines share records `"search_backend.index"`. A pipeline-fatal row carries its step's bare name: `"download"`, `"validate_paths"`, or `"ingest"` for an untagged error. The item-level steps are `"books.load_binary"`, `"books.parse"`, `"books.persist"` and `"books.embed"` for Books, and `"docs.persist_raw"`, `"docs.parse"`, `"docs.persist"`, `"docs.embed"` and `"docs.embed_persist"` for Documents.
### Error Type Unions

Behaviours that return `{:error, reason}` define a named union type enumerating the concrete error shapes their implementations produce. The behaviour owns the union; adding a new implementation means adding its error types to the union. Six unions follow this pattern today: `t:Cake.Documents.Pipeline.retry_from_raw_error/0`, `t:Cake.Generation.error_reason/0`, `t:Cake.Decomposition.error_reason/0`, and the three worked through here:

- **`Cake.Search.Backend.search_error()`** — union of `Snap.ResponseError.t()`, `Snap.HTTPClient.Error.t()`, and `Jason.DecodeError.t()`. Dialyzer checks it only loosely: it flags a callback's return when that return has nothing in common with the callback's type, so a backend that returns `{:ok, hits}` alongside an error outside the union still passes. Keeping the union complete is a review rule (CLAUDE.md "Typespecs"). `index_document/3` returns the same union, passing Snap's `{:error, reason}` through unchanged.

- **`Cake.Books.Adapters.adapter_error()`** — union of `File.posix()` (Disk adapter) and `term()` (S3 adapter, because `ExAws.request/1` specs `{:error, term()}`). The `term()` contribution collapses the union for dialyzer today, but enumerating `File.posix()` explicitly documents the Disk contract and will become enforceable once ExAws publishes a concrete error type. The Disk implementation narrows its own specs to `File.posix()` independently. What the S3 side actually returns is `{:http_error, status, response}` when the store answered, and the transport error when it could not be reached.

- **`Cake.Books.Persistence.persist_error()`** — union of `{:invalid_input, map()}` and `{String.t(), Ecto.Changeset.t() | chunk_error() | {:concurrent_ingest, Ecto.UUID.t()}}` (the last is a run that lost the check-then-insert race), with `chunk_error()` itself a union of `{:invalid_chunk, keyword(), map()}` and `{:chunk_insert_count_mismatch, non_neg_integer(), non_neg_integer()}`. Fully concrete — every error path is accounted for.

The pattern is: define the union in the behaviour (or module that owns the contract), use it in callback specs, and let each implementation narrow to its subset. When a dependency doesn't expose concrete error types (as with ExAws), include `term()` and document why — the union still serves as a registry of intent even when dialyzer can't enforce it.

---

## Search Design

OpenSearch queries support three modes via `search_type`: `:keyword` (BM25 multi_match), `:vector` (k-NN with cosine similarity over an HNSW/FAISS index), and `:hybrid` (vector in `must`, keyword in `should` with configurable boost). The defaults for `k`, `size` and the boost, and how a call overrides them, are under `Cake.Search` in Layer 2. Hybrid is the default because pure vector search struggles with exact identifiers and rare terms, while pure keyword search misses semantic similarity.

A new backend implementation instantiates the conformance suite, `Cake.Search.BackendConformance`, and must pass it unchanged (`.claude/rules/integration-tests.md`).

`search_chunks_with_context/5` returns `{:ok, [Cake.Search.Result.t()]}` (or the backend's error tuple). Direct hits carry `hit_source: :search` and the backend `_score`; expanded neighbors carry `hit_source: :expansion` and `backend_score: nil`. The Result struct is the single carrier of retrieval metadata through the rest of the pipeline (scoring, prompt assembly, response post-processing) — everything above the Search.Result boundary speaks CAKE; everything below speaks vendor. CAKE-computed scores (`cosine_score`, `relevance_score`) are populated by `Search.score_results/2` and `Search.normalize_and_combine/1`; `prompt_index` is populated by `Prompt.prepare_context/2` on auto turns and read by nothing: `Responses` takes each index from the `{index, result}` pair it is handed. Each Result also carries a `Search.Provenance` describing the search conditions (type, query text, and the query's embedding model when the caller passes `:embedding_model`, as `Conversation` and `SearchLive` do) under which it was discovered.

---

## Configuration Keys

The domain-level `:cake` application-env keys that `lib/` reads, grouped by consumer. Values are `config/config.exs` defaults unless noted. Framework configuration is as Phoenix generated it and is not listed here: `Cake.Repo`, `CakeWeb.Endpoint`, `Cake.Mailer`, `Oban` and `:dns_cluster_query` (both read in Cake.Application, which is `@moduledoc false`).

- **Models and providers.** `:default_embedding_model` (`text-embedding-ada-002`; read by `UploadLive` and `SearchLive`), `:default_embedding_dimension` (1536; read only by `Backend.OpenSearch.build_mapping/1`), `:default_provider` (`:openai`; `UploadLive`, `SearchLive`). `:default_response_model` is set but read by nothing in `lib/`. `config :cake, Cake.Conversation` (`gds`, `embedder`, `response_model`, `provider`) is what `ChatLive` starts conversations from.
- **Provider transports.** `config :cake, Cake.Embeddings` — `:openai_key`, `:base_url`, `:req_options` (a `Req.Test` plug in tests, empty in prod). `config :cake, Cake.Generation.OpenAI` — `:openai_key`, `:response_url` (the Responses API endpoint), and an optional `:plug` (a `Req.Test` plug in tests, unset in prod). `:embeddings_module` swaps the whole module for the pipelines (`Cake.Embeddings.Mock` in `config/test.exs`); the pipelines read it at call time.
- **Search.** `:search_collections` (the boot-time `{name_module, mapping_schema}` pairs), `config :cake, Cake.Search.Deployment` (the Snap cluster: one URL, set in `config/config.exs` and repeated in `dev.exs`, with nothing in `prod.exs` or `runtime.exs` yet, #362; `http_client_adapter: Cake.Search.HTTPClientStub` in test), and `:search_backend` — set in no config file; `Backend.backend/0` defaults it to `Backend.OpenSearch`, and tests inject the Mox mock with `Application.put_env`. `:skip_search_backend` makes `Pipelines.add_to_search_backend/3` pass records through unindexed, and makes the two retry-path indexers in `Books.Pipeline` and `Documents.Pipeline` return `:ok` without indexing; `test_helper.exs` sets it for every run; `Cake.SearchIntegrationCase` turns it off for the real-cluster suites and does not turn it back on, and the two `pipelines_search_backend` suites (examples and properties) turn it off, and restore it afterwards, to drive indexing through the Mox backend.
- **Book storage.** `:book_storage_adapter` (`Disk` by default, `S3` in prod, `Mock` in test), `:book_storage_tenant` (the tenant segment of storage keys, `"default"`; `BOOK_STORAGE_TENANT` in prod, `config/runtime.exs`), `:book_storage_root` (the Disk adapter's directory, default `priv/book_storage`), `:book_storage_s3_bucket` (`config/runtime.exs`, from the environment).
- **Uploads.** `:max_zip_expanded_bytes` (268 435 456, i.e. 256 MB: the most the PDF entries of one ZIP upload may declare uncompressed in total) and `:max_zip_entries` (10 000 entries per archive, PDF or not), read by `Cake.Books.ZipExtractor` at call time, which also carries a matching compiled-in default for each.
- **Decomposition.** `:decomposition_max_context_tokens` (4096), `:max_self_ask_iterations` (5), `:max_ircot_iterations` (5), `:max_sub_search_concurrency` (4), and `:sub_search_timeout` (30 000 ms), all set in `config/config.exs`; `Cake.Conversation` also carries a matching compiled-in default for each.

---

## Deployment

There are two images, and they are not variants of each other. **`Dockerfile` is the dev image**: `MIX_ENV=dev`, started through `entrypoint.sh`, which waits for OpenSearch to report yellow or green (polling every 5 s, with no timeout), runs `mix deps.get`, recompiles the app and the NIF, creates the database if it is missing and migrates it, runs the seed and starts `mix phx.server`. It is what `docker-compose.yml` builds, and the `compose-smoke` gate covers it (`ci/compose_smoke.sh`, `.claude/rules/compose-smoke.md`). **`Dockerfile.release` is the release image**, the one that is deployed (#361, the first step of staging, #360): a `mix release` built in a builder stage that has Rust for the `parsebooks` crate and builds the assets with `mix assets.deploy`, copied into a runner stage with no Mix, no compiler and no Rust, running as `nobody`. Its build context is filtered by `Dockerfile.release.dockerignore`, which BuildKit prefers over `.dockerignore` when building that file (`.dockerignore` stays the dev image's, which needs `test/` in its context). Both files came from `mix phx.gen.release --docker` and were then edited by hand.

The release has three entry points under `bin/` (each of the first two with a `.bat` twin the generator writes for Windows): `server` (starts the app with `PHX_SERVER=true`), `migrate` (runs `Cake.Release.migrate/0`, which applies every pending migration without starting the app) and `cake` itself (`cake eval`, `cake rpc`, `cake remote`); `Cake.Release.rollback/2` is reached through `cake eval`. `server`, `migrate` and `cake eval` evaluate `config/runtime.exs` first, whose prod block raises unless `DATABASE_URL`, `SECRET_KEY_BASE`, `OPENAI_KEY` and `BOOK_STORAGE_S3_BUCKET` are set, so `bin/migrate` needs the server's environment even though it uses only the database. `cake rpc` and `cake remote` attach to the node that is already running and evaluate no configuration of their own. The release never runs `priv/repo/seeds.exs`: there is no entry point for it, and the image does not contain the file. Nor can a NIF built on a host reach the image: `priv/native` is kept out of the build context and removed in the builder stage before `mix compile` builds the only `parsebooks.so` the release carries.

The `release-image` gate covers this image (`ci/release_smoke.sh`, on every pull request). It builds `Dockerfile.release` and asserts, with one-shot commands in the built image: `bin/cake eval` extracts a fixture PDF through `Cake.ParseBooks.extract_pdf/1` (the fixture is mounted, since the image carries no `test/`), so the NIF compiled in the builder stage loads in the runner stage; `bin/migrate` applies every migration under `priv/repo/migrations` to an empty Postgres; a marker file the script plants in the host's `priv/native` before building does not reach the release, whose `priv/native` holds `parsebooks.so` and nothing else; and no `seeds.exs` is in the release. It does not boot the app. The release cannot boot in prod yet: `config/runtime.exs` does not configure the search node, the object store or the endpoint for a deployed app, which is #362.

---

## Roadmap: Planned and Deferred

**Needed before the demo:** an icon for Cake. The Phoenix favicon and logo were removed with the rest of the Phoenix branding (#375) and nothing replaces them yet: the root layout declares an empty icon (`<link rel="icon" href="data:,">`), so a browser tab shows none. When there is one, put it in `priv/static/`, add it to `CakeWeb.static_paths/0`, and point that `<link>` at it.

**Post-demo planned:** test coverage expansion, Word/Excel/CSV/JPG pipelines.

**Longer-term:** autorating (`Search` or dedicated module), cross-encoder reranking (`Search`), HyDE-style query expansion (`Prompt` + `Retrieval`), multi-index search and result merging (`Retrieval`).
