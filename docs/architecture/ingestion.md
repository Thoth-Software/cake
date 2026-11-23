# Ingestion

How content gets into Cake: the two pipeline systems, the fields each schema carries, how to add a GDS or a pipeline, and how failures are recorded and retried. `README.md` has the domain model and the map of the architecture files.

## Layer 1: Ingestion — Two Parallel Pipeline Systems

The ingestion layer has two pipeline behaviours because the two GDSes have fundamentally different parsing requirements, metadata schemas, and chunking strategies. Each GDS owns its own ingestion contract.

**`Cake.Documents.Pipeline`** is the behaviour for ingesting programming documentation. Its GDS is `ParsedDocument`, and its callbacks are listed under "Behaviours and Implementations". The module also contains the `ingest/4` orchestrator that sequences callbacks into a stream pipeline — download → persist raw → parse → persist parsed → embed → index — plus an `ingest_with_sweep/5` variant that follows the run with `sweep`-based retry passes (nothing in `lib/` or `test/` calls the Documents one yet, #266). Current implementation: `Cake.Documents.Hexdocs.Pipeline`. Two dedup checks run inside the stages: the generic persist-parsed stage skips attrs whose `(source, version, package, title)` already exists (`ParsedDocuments.parsed_doc_exists?/4`), and the Hexdocs `persist_raw_docs/2` skips `(module, version)` pairs already stored (`Hexdocs.hexdoc_exists?/2`).

**`Cake.Books.Pipeline`** is the behaviour for ingesting books and book-like documents. Its GDS is `ParsedBook` + `Chunk`, and its callbacks are listed under "Behaviours and Implementations". Like `Documents.Pipeline`, the module also contains its own `ingest/4` orchestrator and an `ingest_with_sweep/5` variant that follows the run with `sweep`-based retry passes. Current implementation: `Cake.Books.Pdf.Pipeline`, which uses a Rustler NIF (`parsebooks` Rust crate wrapping `pdf-extract`). Two helper modules sit beside the behaviour: `Cake.Books.Persistence` owns the write path — `persist_books_and_chunks/2` takes the pair and the requested embedding model, looks the `file_hash` up and returns `{:duplicate, book}` for a `:completed` book whose every chunk was embedded under that model, resumes any other book behind the hash (another status, or `:completed` under another or an unknown model) with its existing chunks after clearing the vectors other models produced, and inserts a new book and its chunks otherwise (`insert_books_and_chunks/3` is that insert without the lookup; a run that loses the check-then-insert race to another is a duplicate only if the winner is already `:completed` under the requested model, and otherwise a `{:concurrent_ingest, winner_id}` persist failure for the sweep to retry) — and `Cake.Books.Retrieval` owns the read path that `ParsedBook` delegates its `load_from_hits/1` and `expand_with_neighbors/2` GDS callbacks to. The expansion returns, for each book, exactly the chunks within `offset` positions of a hit, once each, in ascending `chunk_index` order — a guarantee, so a caller knows which neighbours precede and follow a hit; the order of the books relative to each other is unspecified.

The two orchestrators take their arguments in different orders: Books is `ingest(embedding_service, format_pipeline, embedding_model, paths)`, Documents is `ingest(embedding_service, source_pipeline, version_tuple, embedding_model)`.

**`Cake.Pipelines`** provides shared infrastructure used by both pipeline types: `detuple_with_logging/3` filters `{:ok, _}/{:error, _}` streams and persists errors to `FailedIngest`, `log_and_persist_failure/3` persists one item's failure for a stage that handles outcomes itself, `add_to_search_backend/3` handles index upserts, and `sweep/3` implements a retry loop for item-level failures. A `Context` struct carries pipeline identity (behaviour, implementation, version) plus a per-run `run_id` through a run: the identity fields give error provenance, and `run_id` scopes `count_failures/1`, `finalize_ingest/3`, and `sweep/3` to one run so concurrent ingests of the same source never count or retry each other's failures. `Context` also carries an `opts` keyword, read for `:search_backend_timeout` (the per-record indexing deadline, default 5000 ms); both orchestrators build it with `opts: []` today. A Books run has no source version, so its `Context.version` is the embedding model, and that is what `FailedIngest.version` holds for Books rows.

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
