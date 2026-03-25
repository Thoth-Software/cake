# Caque

A RAG (Retrieval-Augmented Generation) framework for Elixir. Caque provides the data structures, ingestion pipelines, and retrieval heuristics needed to build production RAG applications. The framework is designed to be iteratively improved through feedback from real implementations.

## Mission

Caque aims to be a **RAG substrate**, not just a toy app. The core value proposition:

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

### Pipeline Behaviour (`Caque.Documents.Pipeline`)

The core abstraction for all document ingestion. Each pipeline implementation handles a class of documentation (e.g., Elixir hexdocs, Java javadocs, Python docs).

**Required Callbacks:**

| Callback | Purpose |
|----------|---------|
| `download(version)` | Fetch raw documentation for a specific version |
| `persist_raw_docs(file_paths, version)` | Store raw files as source of truth |
| `parse(raw_docs_stream)` | Transform raw docs into `ParsedDocument` structs |
| `source()` | Return the source identifier (e.g., "hexdocs") |
| `success_message(version)` | Human-readable completion message |

**Pipeline Flow:**

The `Pipeline.ingest/4` function orchestrates the full ingestion:

1. Download raw documentation
2. Persist raw files (enables reprocessing with improved heuristics)
3. Parse into `ParsedDocument` records with streaming
4. Batch embed using OpenAI (configurable model)
5. Index in OpenSearch with vector + metadata

**Design Philosophy:**

- Raw documents are persisted first, enabling re-parsing when heuristics improve
- Streaming throughout to handle large documentation sets
- Concurrent processing via `Task.async_stream` (5 max concurrency)
- Skippable OpenSearch indexing for testing

### Hexdocs Pipeline (`Caque.Documents.Hexdocs.Pipeline`)

Implementation for Elixir core documentation.

**Download Strategy:**
- Clones the Elixir repository at a specific version tag
- Extracts `.ex` source files from `lib/elixir/lib/`

**Parsing Strategy:**
- Uses `Code.string_to_quoted/1` to parse Elixir AST
- Walks the AST to find `@doc` annotations paired with function definitions
- Extracts function signature, arity, and documentation
- Creates `ParsedDocument` with `title: "function_name/arity"` and `text: docstring + code`

This approach captures both the documentation and the actual implementation, giving the LLM more context for answering questions.

---

## Data Structures

### ParsedDocument (`Caque.Documents.ParsedDocument`)

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

### Hexdoc (`Caque.Documents.Hexdocs.Hexdoc`)

Intermediate storage for raw Elixir source code before parsing:

| Field | Type | Purpose |
|-------|------|---------|
| `module` | string | Elixir module name |
| `version` | string | Elixir version |
| `content` | string | Raw source code |
| `url` | string | hexdocs.pm URL |

This two-stage approach (raw → parsed) allows re-parsing when AST extraction heuristics improve.

### ParsedBook (`Caque.Books.ParsedBook`)

For book/ebook ingestion (parallel RAG subsystem):

| Field | Type | Purpose |
|-------|------|---------|
| `title` | string | Book title |
| `authors` | string array | Author list |
| `source_format` | string | PDF, EPUB, etc. (determines chunking strategy) |
| `file_hash` | string | For deduplication |
| `table_of_contents` | map | Structure for section-aware retrieval |
| `embedding_status` | enum | :pending, :processing, :completed, :failed |

### Chunk (`Caque.Books.Chunk`)

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

### Embeddings Behaviour (`Caque.Embeddings.Behaviour`)

Defines the contract for embedding services:

```elixir
@callback embed(atom(), ParsedDocument.t(), String.t()) ::
  {:ok, embedding_result()} | {:error, String.t()}
```

### OpenAI Implementation (`Caque.Embeddings`)

Currently the only implementation. Embeds documents by:

1. Combining `title` and `text`: `"#{title}\n\n#{text}"`
2. Calling OpenAI embeddings API
3. Returning the embedding vector + usage stats

**Configuration:**
```elixir
config :caque, Caque.Embeddings,
  openai_key: "sk-...",
  base_url: "https://api.openai.com/v1/embeddings"
```

**Design Note:** Title is prepended to text for embedding because function names and signatures carry significant semantic weight for code documentation.

---

## Search & Retrieval

### OpenSearch Cluster (`Caque.Documents.Cluster`)

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

### Conversation GenServer (`Caque.Conversation`)

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

### Responses Module (`Caque.Responses`)

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
config :caque, Caque.Responses,
  openai_key: "sk-...",
  response_url: "https://api.openai.com/v1/chat/completions"
```

---

## Job Scheduling

### Document Ingestion Job (`Caque.Jobs.DocumentIngestionJob`)

Oban worker for async document ingestion:

```elixir
DocumentIngestionJob.enqueue_for_version(
  Caque.Documents.Hexdocs.Pipeline,
  :openai,
  {1, 18, 3},
  "text-embedding-ada-002"
)
```

- Retries up to 3 times on failure
- Logs success/error messages
- Runs ingestion in background

---

## Books Pipeline (Experimental)

The books subsystem (`Caque.Books`, `Caque.ParseBooks`) provides infrastructure for ingesting ebooks:

- **ParsedBook** schema with rich metadata (ISBN, publisher, TOC)
- **Chunk** schema for section-aware retrieval
- **Rustler NIF** binding to Rust parsing library (crate: "parsebooks")

The source format field determines chunking strategy - PDFs chunk differently than EPUBs.

---

## Application Startup

Supervised processes (`Caque.Application`):

1. Telemetry
2. PostgreSQL Repo (Ecto)
3. Oban job queue
4. DNS cluster
5. Phoenix PubSub
6. Finch HTTP client
7. **Caque.Documents.Cluster** (OpenSearch connection)
8. Phoenix Endpoint

---

## Configuration

### OpenSearch
```elixir
config :caque, Caque.Documents.Cluster,
  url: "https://...",
  username: "...",
  password: "..."
```

### Embeddings
```elixir
config :caque, Caque.Embeddings,
  openai_key: "sk-...",
  base_url: "https://api.openai.com/v1/embeddings"
```

### Responses
```elixir
config :caque, Caque.Responses,
  openai_key: "sk-...",
  response_url: "https://api.openai.com/v1/chat/completions"
```

---

## Adding a New Pipeline

To ingest a new documentation source:

1. Create a raw document schema (like `Hexdoc`) for intermediate storage
2. Implement the `Pipeline` behaviour:
   - `download/1` - Fetch docs for a version
   - `persist_raw_docs/2` - Store raw files
   - `parse/1` - Transform to `ParsedDocument` stream
   - `source/0` - Return source identifier
   - `success_message/1` - Completion message
3. Register with Oban for async ingestion

**Key Principle:** Persist raw documents first. When your parsing heuristics improve, you can re-process without re-downloading.

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
