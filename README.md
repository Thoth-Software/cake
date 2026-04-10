# Cake

A RAG (Retrieval-Augmented Generation) framework for Elixir. Cake provides the data structures, ingestion pipelines, and retrieval heuristics needed to build production RAG applications. The framework is designed to be iteratively improved through feedback from real implementations.

## Mission

Cake aims to be a **RAG substrate**, not just a toy app. The core value proposition:

1. **Pluggable Ingestion Pipelines** - Each documentation source is a behaviour with implementations for specific file types
2. **Opinionated Data Structures** - Schemas designed for effective retrieval, with metadata that matters
3. **Hybrid Search** - Vector similarity + keyword search, configurable per use case
4. **Multi-turn Conversations** - Stateful RAG conversations, not just stateless Q&A

## Architecture Overview

```
[Raw Documentation]
       ↓
[Pipeline.download/1]        ← Source-specific fetching
       ↓
[Pipeline.persist_raw_docs/2] ← Store raw data (source of truth)
       ↓
[Pipeline.parse/1]           ← Extract structured content
       ↓
[ParsedDocument]             ← Unified document schema
       ↓
[Embeddings.embed/3]         ← Generate vector embeddings
       ↓
[OpenSearch Index]           ← k-NN + BM25 hybrid search
       ↓
[Conversation]               ← Multi-turn RAG with context
       ↓
[Responses.query_llm/4]      ← Grounded answer generation
```

---

## Ingestion Pipelines

Cake defines pipeline behaviours per document type, with implementations for specific formats and sources. Each behaviour prescribes a processing flow suited to its document type, while implementations handle the details of fetching, parsing, and structuring content from a particular format.

### Documents Pipeline Behaviour (`Cake.Documents.Pipeline`)

For ingesting programming language documentation (e.g., Elixir hexdocs, Java javadocs, Python docs). Implementations download versioned documentation from external sources, persist raw files, and parse them into `ParsedDocument` records.

**Required Callbacks:**

| Callback | Purpose |
|----------|---------|
| `download(version)` | Fetch raw documentation for a specific version |
| `persist_raw_docs(file_paths, version)` | Store raw files as source of truth |
| `parse(raw_docs_stream)` | Transform raw docs into `ParsedDocument` structs |
| `source()` | Return the source identifier (e.g., "hexdocs") |
| `success_message(version)` | Human-readable completion message |

**Pipeline Flow:**

1. Download raw documentation
2. Persist raw files (enables reprocessing with improved heuristics)
3. Parse into `ParsedDocument` records with streaming
4. Batch embed using OpenAI (configurable model)
5. Index in OpenSearch with vector + metadata

#### Hexdocs Implementation (`Cake.Documents.Hexdocs.Pipeline`)

Implements `Cake.Documents.Pipeline` for Elixir core documentation.

**Download Strategy:**
- Clones the Elixir repository at a specific version tag
- Extracts `.ex` source files from `lib/elixir/lib/`

**Parsing Strategy:**
- Uses `Code.string_to_quoted/1` to parse Elixir AST
- Walks the AST to find `@doc` annotations paired with function definitions
- Extracts function signature, arity, and documentation
- Creates `ParsedDocument` with `title: "function_name/arity"` and `text: docstring + code`

This approach captures both the documentation and the actual implementation, giving the LLM more context for answering questions.

### Books Pipeline Behaviour (`Cake.Books.Pipeline`)

For ingesting books and ebooks. Unlike the documents pipeline, this behaviour assumes files are already stored locally. Implementations load binary file data, parse it into `ParsedBook` metadata and `Chunk` records, and persist both before embedding.

**Required Callbacks:**

| Callback | Purpose |
|----------|---------|
| `load_binary(path)` | Load binary file data from storage |
| `parse(binary)` | Parse binary into a `{ParsedBook, [Chunk]}` tuple |
| `format()` | Return the format identifier (e.g., `:pdf`) |
| `success_message()` | Human-readable completion message |

**Pipeline Flow:**

1. Load all binaries from disk
2. Parse into `ParsedBook` + `Chunk` records (format-aware)
3. Persist books and chunks to PostgreSQL
4. Batch embed chunks
5. Index chunks in OpenSearch

#### PDF Implementation (`Cake.Books.Pdf.Pipeline`)

Implements `Cake.Books.Pipeline` for PDF files.

- Loads PDF binary from filesystem paths
- Uses Rust NIF (`Cake.ParseBooks`) to extract page text
- Creates `ParsedBook` metadata (title, file hash, word count, page count)
- Creates a `Chunk` per non-empty page
- Computes SHA256 hash for deduplication

### Shared Design Philosophy

- Raw/binary data is persisted first, enabling re-processing when heuristics improve
- Streaming throughout to handle large datasets
- Concurrent processing via `Task.async_stream` (5 max concurrency)
- Skippable OpenSearch indexing for testing

### Error Handling in Pipelines

Pipelines process streams of items (files, documents, chunks), and failures fall into two categories that are handled differently.

**Item-level failures** occur when a single item in the stream fails while the rest continue normally. A corrupt PDF that won't parse, an embedding API timeout for one chunk, or a changeset validation error on a single record are all item-level failures. These are handled inside the stream itself via `Pipelines.detuple_with_logging/2`, which logs the error with the pipeline step name and filters the failed item out of the stream. Successfully-processed items continue downstream unaffected.

**Pipeline-fatal failures** occur when the entire pipeline cannot continue. The download step failing, OpenSearch being unreachable, or an invalid embedding model string are pipeline-fatal. These are handled in the `ingest` function on each behaviour module, where the `with` chain short-circuits and returns an error tuple. Nothing downstream runs.

The distinction matters for two reasons. First, item-level failures should not abort a batch — if 148 out of 150 PDFs parse successfully, those 148 should be persisted, embedded, and indexed. Second, the retry strategy differs: item-level failures can be retried individually, while pipeline-fatal failures require retrying the entire batch.

**Where logging lives:**

The behaviour module's `ingest` function is responsible for logging (and eventually persisting) pipeline-fatal errors. Each stream transformation step uses `Pipelines.detuple_with_logging/2` with a descriptive step name (e.g., `"books.parse"`, `"docs.embed"`) to log item-level failures. Callback implementations (e.g., `Pdf.Pipeline.parse/1`) return `{:ok, _}` or `{:error, _}` tuples — they do not log directly, because the behaviour module is the single point of observability for the pipeline as a whole.

Step names follow the convention `"pipeline.step"` where `pipeline` is a short identifier for the behaviour (`books`, `docs`) and `step` identifies the transformation (`load_binary`, `parse`, `persist`, `embed`, `opensearch.index`).

**Future: error persistence.** Item-level errors will be persisted to a `FailedIngest` table (via `Cake.FailedIngests`) at the point of failure, inside `detuple_with_logging`. Pipeline-fatal errors will be persisted in the `else` branch of the `ingest` function's `with` chain. Each record stores the behaviour, implementation, step, version, error text, and an input identifier sufficient to locate and retry the failed item. See the `FailedIngest` schema for details.

---

## Data Structures

### ParsedDocument (`Cake.Documents.ParsedDocument`)

The universal schema for all indexed documentation. Every ingestion pipeline outputs `ParsedDocument` records.

| Field | Type | Purpose |
|-------|------|---------|
| `source` | string | Pipeline identifier ("hexdocs", "javadocs", etc.) |
| `version` | string | Documentation version |
| `package` | string | Module/gem/class name |
| `language` | string | Programming language |
| `title` | string | Function/class/method name - used in embeddings |
| `text` | string | Documentation content |
| `url` | string | Original documentation URL |
| `core` | boolean | Part of stdlib/core? |
| `embedding` | float array | 1536-dimensional vector (OpenAI ada-002) |

**Query Helpers:**
- `by_version/2`, `by_language/2`, `by_source/2` for filtering

### Hexdoc (`Cake.Documents.Hexdocs.Hexdoc`)

Intermediate storage for raw Elixir source code before parsing:

| Field | Type | Purpose |
|-------|------|---------|
| `module` | string | Elixir module name |
| `version` | string | Elixir version |
| `content` | string | Raw source code |
| `url` | string | hexdocs.pm URL |

This two-stage approach (raw → parsed) allows re-parsing when AST extraction heuristics improve.

### ParsedBook (`Cake.Books.ParsedBook`)

For book/ebook ingestion (parallel RAG subsystem):

| Field | Type | Purpose |
|-------|------|---------|
| `title` | string | Book title |
| `authors` | string array | Author list |
| `source_format` | string | PDF, EPUB, etc. (determines chunking strategy) |
| `file_hash` | string | For deduplication |
| `table_of_contents` | map | Structure for section-aware retrieval |
| `embedding_status` | enum | :pending, :processing, :completed, :failed |

### Chunk (`Cake.Books.Chunk`)

Searchable chunks of a book:

| Field | Type | Purpose |
|-------|------|---------|
| `text` | string | Content |
| `page_number` | integer | For citation |
| `chunk_index` | integer | Ordering |
| `section_title` | string | Section context |
| `word_count` | integer | Token estimation |
| `embedding` | float array | Vector representation |

---

## Embeddings Module

### Embeddings Behaviour (`Cake.Embeddings.Behaviour`)

Defines the contract for embedding services:

```elixir
@callback embed(atom(), ParsedDocument.t(), String.t()) ::
  {:ok, embedding_result()} | {:error, String.t()}
```

### OpenAI Implementation (`Cake.Embeddings`)

Currently the only implementation. Embeds documents by:

1. Combining `title` and `text`: `"#{title}\n\n#{text}"`
2. Calling OpenAI embeddings API
3. Returning the embedding vector + usage stats

**Configuration:**
```elixir
config :cake, Cake.Embeddings,
  openai_key: "sk-...",
  base_url: "https://api.openai.com/v1/embeddings"
```

**Design Note:** Title is prepended to text for embedding because function names and signatures carry significant semantic weight for code documentation.

---

## Search & Retrieval

### OpenSearch Cluster (`Cake.Documents.Cluster`)

Manages the OpenSearch connection and provides three search modes:

#### Keyword Search
```elixir
Cluster.search(:keyword, index, %{keywords: "pattern matching"})
```
Multi-match query across `title` (boosted 2x) and `text` fields.

#### Vector Search
```elixir
Cluster.search(:vector, index, %{embedding: embedding})
```
k-NN search with k=10, cosine similarity, HNSW algorithm via FAISS engine.

#### Hybrid Search (Default)
```elixir
Cluster.search(:hybrid, index, %{
  keywords: "pattern matching",
  embedding: embedding,
  keyword_weight: 0.3
})
```
Combines vector similarity as the core query with keyword matching as a boost signal. Configurable keyword weighting.

**Index Schema:**
- Embedding field: `knn_vector`, 1536 dimensions, HNSW + FAISS
- Text field: Full-text searchable
- Metadata fields: Keyword type for filtering

**Why Hybrid?** Pure vector search struggles with:
- Exact identifiers and function names
- Rare terms and acronyms
- Precise code patterns

BM25 handles these well, while vector search handles semantic similarity. Hybrid gives you both.

---

## Conversation Module

### Conversation GenServer (`Cake.Conversation`)

Manages multi-turn RAG conversations as stateful processes.

**Initialization:**
```elixir
Conversation.start_link(
  caller,           # Cluster module
  embedder,         # Embedding model string
  index,            # OpenSearch index name
  response_model,   # LLM model name
  provider,         # :openai
  search_type       # :hybrid
)
```

**Two-Turn Workflow:**

1. **First Turn** (no prior context):
   - Embed the question
   - Perform hybrid search
   - Query LLM with retrieved context
   - Store search results and message history

2. **Subsequent Turns** (with prior context):
   - Reuse previous search results
   - Query LLM with same context + new question
   - Append to message history

**API:**
```elixir
Conversation.ask(pid, "How do I use pattern matching?")
```

**Design Philosophy:** Conversations reuse search results across turns because follow-up questions typically relate to the same topic. This reduces latency and API costs.

---

## Response Generation

### Responses Module (`Cake.Responses`)

Generates LLM responses with retrieved context.

**Process:**
1. Format context docs as system message (package, title, text for each)
2. Build messages array with context + user question
3. Call LLM API
4. Parse and return response

**Context Format:**
```
You are a helpful assistant...
Context:
---
Package: Enum
Title: map/2
Text: Maps the given function over...
---
```

**Configuration:**
```elixir
config :cake, Cake.Responses,
  openai_key: "sk-...",
  response_url: "https://api.openai.com/v1/chat/completions"
```

---

## Job Scheduling

### Document Ingestion Job (`Cake.Jobs.DocumentIngestionJob`)

Oban worker for async document ingestion:

```elixir
DocumentIngestionJob.enqueue_for_version(
  Cake.Documents.Hexdocs.Pipeline,
  :openai,
  {1, 18, 3},
  "text-embedding-ada-002"
)
```

- Retries up to 3 times on failure
- Logs success/error messages
- Runs ingestion in background

---

---

## Application Startup

Supervised processes (`Cake.Application`):

1. Telemetry
2. PostgreSQL Repo (Ecto)
3. Oban job queue
4. DNS cluster
5. Phoenix PubSub
6. Finch HTTP client
7. **Cake.Documents.Cluster** (OpenSearch connection — documents)
8. **Cake.Books.Cluster** (OpenSearch connection — book chunks)
9. Phoenix Endpoint

---

## Configuration

### OpenSearch
```elixir
config :cake, Cake.Documents.Cluster,
  url: "https://...",
  username: "...",
  password: "..."
```

### Embeddings
```elixir
config :cake, Cake.Embeddings,
  openai_key: "sk-...",
  base_url: "https://api.openai.com/v1/embeddings"
```

### Responses
```elixir
config :cake, Cake.Responses,
  openai_key: "sk-...",
  response_url: "https://api.openai.com/v1/chat/completions"
```

---

## Adding a New Pipeline

Choose the behaviour that matches your document type, then implement it for your specific format or source.

**To ingest a new documentation source** (implement `Cake.Documents.Pipeline`):

1. Create a raw document schema (like `Hexdoc`) for intermediate storage
2. Implement the callbacks: `download/1`, `persist_raw_docs/2`, `parse/1`, `source/0`, `success_message/1`
3. Register with Oban for async ingestion
4. Ensure all callback return values use `{:ok, _}` / `{:error, _}` tuples so `detuple_with_logging` can observe failures

**To ingest a new book/ebook format** (implement `Cake.Books.Pipeline`):

1. Implement the callbacks: `load_binary/1`, `parse/1`, `format/0`, `success_message/0`
2. Add format-specific parsing logic (NIF, library, etc.)
3. If `parse/1` calls code that can raise (e.g., a NIF), the behaviour's `parse_all_binaries` wraps it in `try/rescue` — your callback does not need to catch its own exceptions

**Requirements for all new pipelines and implementations:**

- Every stream transformation step must use `Pipelines.detuple_with_logging/2` with a descriptive step name, not the silent `detuple/1`.
- Callbacks should return `{:ok, _}` / `{:error, _}` tuples. If a callback calls a function that raises, the behaviour module wraps the call in `try/rescue` so errors enter the logging path rather than silently dying as task exits.
- Pipeline-fatal errors must be logged in the `else` branch of the `ingest` function.

**Key Principle:** Persist raw data first. When your parsing heuristics improve, you can re-process without re-downloading or re-loading.

---

## Development

```bash
# Compile without warnings
mix compile --force

# Run tests without warnings
mix test
```

---

## Roadmap

See `feature_roadmap.md` for planned enhancements including:

- Re-ranking pipelines
- Query expansion (HyDE-style)
- Semantic chunking with overlap
- Context assembly strategies
- Faithfulness checks
- Conversational memory improvements
- Evaluation harnesses
