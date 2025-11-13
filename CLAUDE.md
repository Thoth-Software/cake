# CLAUDE.md - Context for AI Assistants

## Project Overview

**Caque** (pronounced "cake") is a **Retrieval-Augmented Generation (RAG) system** built with Elixir and Phoenix that:
- Ingests technical documentation (currently HexDocs for Elixir)
- Generates vector embeddings using OpenAI
- Indexes documents in OpenSearch with KNN vector search
- Provides conversational search capabilities using LLM completions

### Tech Stack
- **Language**: Elixir ~> 1.14
- **Framework**: Phoenix 1.7.20 with LiveView
- **Database**: PostgreSQL 14
- **Search Engine**: OpenSearch 2.19.1 with KNN plugins
- **Job Queue**: Oban 2.0
- **External APIs**: OpenAI (embeddings & completions)
- **Container Orchestration**: Docker Compose

---

## Architecture

### Core Pipeline Flow
```
Download → Parse → Embed → Index (OpenSearch)
```

The system uses a **behavior-based pipeline architecture** that allows different documentation sources to be plugged in:
- `Caque.Documents.Pipeline` - Behavior defining the pipeline contract
- `Caque.Documents.Hexdocs.Pipeline` - HexDocs implementation
- Processing uses streams for memory efficiency
- Task-based concurrency for parallel embedding generation

### Key Components

1. **Document Pipeline** (`lib/caque/documents/pipeline.ex`)
   - Behavior module defining ingestion contract
   - Callbacks: `download/1`, `persist_raw_docs/2`, `parse/1`, `source/0`, `success_message/1`
   - Orchestrates the full ingestion flow with error handling

2. **HexDocs Pipeline** (`lib/caque/documents/hexdocs/`)
   - Clones Elixir source from GitHub
   - Parses `.ex` files using AST analysis
   - Extracts function definitions and documentation
   - Stores in `hexdocs` table, then converts to generic `parsed_documents`

3. **OpenSearch Cluster** (`lib/caque/documents/cluster.ex`)
   - Manages OpenSearch connection via Snap library
   - Creates KNN vector index (1536 dimensions, HNSW algorithm)
   - Provides `keyword_search/2` and `vector_search/2` functions
   - Index uses cosinesimil for vector similarity

4. **Embeddings** (`lib/caque/embeddings.ex`)
   - Generates embeddings via OpenAI API (`text-embedding-ada-002`)
   - Combines `title` + `text` from ParsedDocument
   - Returns 1536-dimensional float array
   - Updates ParsedDocument with embedding vector

5. **Completions** (`lib/caque/completions.ex`)
   - LLM completions via OpenAI Chat API
   - RAG implementation: formats search results into system message
   - Currently supports `:openai`, Anthropic marked as TODO

6. **Conversation** (`lib/caque/conversation.ex`)
   - GenServer managing stateful RAG conversations
   - State: search_results, message_history, errors
   - First question triggers vector search, subsequent use cached results
   - Configurable models (default: gpt-5 for completion)

7. **Background Jobs** (`lib/caque/jobs/document_ingestion_job.ex`)
   - Oban worker for async document ingestion
   - Queue: `:default`, max attempts: 3
   - Enqueue via `DocumentIngestionJob.enqueue_for_version/4`

---

## Directory Structure

```
/home/user/caque/
├── lib/
│   ├── caque/                      # Core business logic
│   │   ├── accounts/               # User authentication (Phoenix-generated)
│   │   ├── documents/              # Document processing
│   │   │   ├── cluster.ex          # OpenSearch management
│   │   │   ├── pipeline.ex         # Pipeline behavior
│   │   │   ├── hexdocs/            # HexDocs-specific implementation
│   │   │   ├── parsed_document.ex  # Generic parsed doc schema
│   │   │   └── parsed_documents.ex # Context module
│   │   ├── embeddings.ex           # OpenAI embedding generation
│   │   ├── completions.ex          # LLM completions
│   │   ├── conversation.ex         # RAG conversation GenServer
│   │   ├── jobs/                   # Oban background jobs
│   │   ├── application.ex          # OTP application
│   │   ├── repo.ex                 # Ecto repository
│   │   └── schema.ex               # Custom schema (enforces UUID PKs)
│   ├── caque_web/                  # Phoenix web layer
│   │   ├── controllers/
│   │   ├── live/                   # LiveView modules
│   │   ├── components/
│   │   ├── router.ex
│   │   └── endpoint.ex
├── priv/repo/migrations/           # Database migrations
├── test/
│   ├── caque/                      # Business logic tests
│   ├── caque_web/                  # Web layer tests
│   └── support/                    # Test helpers & fixtures
├── config/                         # Environment configs
└── docker-compose.yml              # Container orchestration
```

---

## Database Schema

### Tables

1. **hexdocs** (Raw HexDocs storage)
   - `id` (uuid) - Primary key
   - `module` (text) - Module name
   - `version` (text) - Elixir version
   - `core` (boolean) - Core Elixir module flag
   - `url` (text) - Documentation URL
   - `content` (text) - Raw Elixir source code
   - `source` (text) - Always "hexdocs"
   - `language` (text) - Always "elixir"

2. **parsed_documents** (Generic processed docs)
   - `id` (uuid) - Primary key
   - `source` (text) - e.g., "hexdocs"
   - `version` (text) - e.g., "1.18.3"
   - `package` (text) - Module/package name
   - `language` (text) - e.g., "elixir"
   - `title` (text) - Function name or doc title
   - `url` (text) - Documentation URL
   - `text` (text) - Documentation + code
   - `core` (boolean) - Core module flag
   - `embedding` (float[]) - 1536-dimensional vector
   - `embedded_at` (timestamp) - When embedding was generated

3. **users**, **users_tokens** (Authentication)
   - Standard Phoenix authentication tables

4. **oban_jobs** (Background job queue)
   - Standard Oban schema

### Important: UUID Primary Keys
All schemas inherit from `Caque.Schema` which enforces UUIDs as primary keys:
```elixir
use Caque.Schema  # instead of use Ecto.Schema
```

---

## Development Workflows

### Initial Setup
```bash
# Start all services
docker-compose up -d

# Install dependencies and setup database
mix setup  # Runs deps.get, ecto.setup, assets.setup, assets.build
```

### Accessing IEx

**Option 1: Docker Desktop**
1. Open Docker Desktop → Containers
2. Click `caque_app`
3. Click CLI (on topbar)
4. Type `iex --remsh dev`

**Option 2: Command Line**
```bash
docker exec -it caque_app iex --remsh dev
```

### Code Quality Requirements ⚠️

**CRITICAL: These must pass before completing any task**

1. **No Compilation Warnings**
   ```bash
   mix compile --force
   # Must output: Compiled without warnings
   ```

2. **All Tests Pass with No Warnings**
   ```bash
   mix test
   # Must show: All tests passing, 0 warnings
   ```

3. **Always run tests at the end of any task**

### Mix Aliases
```bash
mix setup          # Full project setup
mix ecto.setup     # Create DB, migrate, seed
mix ecto.reset     # Drop and recreate DB
mix test           # Create test DB, migrate, run tests
mix assets.build   # Build Tailwind and ESBuild
mix assets.deploy  # Minified production assets
```

---

## Testing

### Test Configuration
- **Framework**: ExUnit
- **DB Isolation**: Ecto sandbox mode
- **Mocking**: Mox library for external APIs
- **OpenSearch**: Skipped in tests via `:skip_opensearch` flag

### Test Support Files
- `test/support/data_case.ex` - Database test case
- `test/support/conn_case.ex` - Controller test case
- `test/support/oban_case.ex` - Oban job testing
- `test/support/test_pipeline.ex` - Mock pipeline for tests
- `test/support/fixtures/` - Test data fixtures

### Running Tests
```bash
# All tests
mix test

# Specific file
mix test test/caque/documents/pipeline_test.exs

# Specific test
mix test test/caque/documents/pipeline_test.exs:42

# With coverage
mix test --cover
```

---

## Environment Variables

### Required Configuration
```bash
# PostgreSQL
CAQUE_PGUSER=postgres
CAQUE_PGPASSWORD=postgres
CAQUE_PGDATABASE=caque_dev
CAQUE_PGHOST=db
CAQUE_PGPORT=5432

# OpenSearch
OPENSEARCH_INITIAL_ADMIN_PASSWORD=<strong_password>
OPENSEARCH_URL=http://opensearch:9200

# OpenAI
OPENAI_KEY=sk-...
```

### Docker Services
- **phoenix** (port 4000) - Phoenix application
- **db** (port 5432) - PostgreSQL 14
- **opensearch** (ports 9200, 9600) - OpenSearch with ML plugins

---

## Coding Conventions

### Elixir Style
1. **Use explicit module names** - No aliases in function definitions
2. **Pattern matching over conditionals** - Leverage Elixir's pattern matching
3. **Pipe operator** - Use `|>` for data transformations
4. **Streams for large data** - Use `Stream` module for memory efficiency
5. **Error tuples** - Return `{:ok, result}` or `{:error, reason}`

### Phoenix Patterns
1. **Context modules** - Business logic in contexts (e.g., `Caque.Documents`)
2. **Changesets for validation** - Always use Ecto changesets
3. **LiveView for real-time** - Prefer LiveView over traditional controllers
4. **Component organization** - Reusable components in `caque_web/components/`

### Schema Patterns
```elixir
# Always use the custom schema
use Caque.Schema  # Enforces UUID primary keys

# Standard imports
import Ecto.Changeset
import Ecto.Query, warn: false

# Schema fields
schema "table_name" do
  field :name, :string
  # UUID primary key is automatic
  timestamps(type: :utc_datetime)
end
```

### Pipeline Pattern
To add a new documentation source:

1. Create module implementing `Caque.Documents.Pipeline` behavior
2. Implement required callbacks:
   - `download/1` - Download raw docs
   - `persist_raw_docs/2` - Save to source-specific table
   - `parse/1` - Convert to `ParsedDocument` structs
   - `source/0` - Return source identifier
   - `success_message/1` - Success notification
3. Use `Caque.Documents.Pipeline.ingest/4` to run the full pipeline

Example:
```elixir
defmodule Caque.Documents.MySource.Pipeline do
  @behaviour Caque.Documents.Pipeline

  @impl true
  def download(version), do: # implementation

  @impl true
  def persist_raw_docs(docs, version), do: # implementation

  @impl true
  def parse(version), do: # implementation

  @impl true
  def source(), do: "my_source"

  @impl true
  def success_message(version), do: "Loaded my_source #{version}"
end
```

---

## Common Tasks

### Ingest New Documentation
```elixir
# In IEx
alias Caque.Documents.Hexdocs.Pipeline
alias Caque.Documents.Pipeline, as: BasePipeline

# Synchronous ingestion
BasePipeline.ingest(:openai, Pipeline, {1, 18, 3}, "text-embedding-ada-002")

# Background job
alias Caque.Jobs.DocumentIngestionJob
DocumentIngestionJob.enqueue_for_version(
  Pipeline,
  :openai,
  {1, 18, 3},
  "text-embedding-ada-002"
)
```

### Search Documents
```elixir
# Keyword search
alias Caque.Documents.Cluster
Cluster.keyword_search("Enum.map", limit: 5)

# Vector search (requires embedding)
alias Caque.Embeddings
{:ok, %{embedding: embedding}} = Embeddings.embed_query(:openai, "list functions", "text-embedding-ada-002")
Cluster.vector_search(embedding, limit: 5)
```

### Start a Conversation
```elixir
alias Caque.Conversation

# Start GenServer
{:ok, pid} = Conversation.start_link(%{automatic: true})

# Ask question
GenServer.cast(pid, {:question, "How do I use Enum.map?"})

# Get state
state = :sys.get_state(pid)
```

### Database Operations
```elixir
# Query parsed documents
alias Caque.Documents.ParsedDocuments
ParsedDocuments.list_parsed_documents()

# Get by source
import Ecto.Query
Caque.Repo.all(from p in Caque.Documents.ParsedDocument, where: p.source == "hexdocs")
```

---

## Important Patterns

### Concurrency with Task.async_stream
Used for parallel embedding generation:
```elixir
Task.async_stream(
  docs,
  fn doc -> Embeddings.embed_parsed_document(service, doc, model) end,
  max_concurrency: 5,
  timeout: 60_000
)
|> Stream.map(fn {:ok, result} -> result end)
```

### Error Handling
```elixir
# Use Logger for tracking
require Logger
Logger.info("Processing #{source} version #{version}")
Logger.error("Failed to process: #{inspect(error)}")

# Return error tuples
{:ok, result} | {:error, reason}

# Pattern match in pipelines
case result do
  {:ok, data} -> process(data)
  {:error, reason} -> handle_error(reason)
end
```

### Test Mode with OpenSearch
```elixir
# Pipeline automatically skips OpenSearch in test env
# Check via Application.get_env(:caque, :skip_opensearch, false)

# In tests, mock external APIs
defmock(Caque.MockEmbeddings, for: Caque.Embeddings)
```

---

## Known TODOs

1. **Anthropic Completions** - `Caque.Completions.complete/3` returns `:not_implemented` for `:anthropic`
2. **Embedding Usage Tracking** - Consider separate table for tracking token usage
3. **Error Recovery** - Improve error handling in Conversation GenServer
4. **Additional Sources** - Support for Clojure, Java, Python documentation
5. **Conversation History** - Persist conversations to database

---

## Debugging Tips

### Check OpenSearch Connectivity
```bash
# From within phoenix container
curl -X GET http://opensearch:9200
# Should return cluster info with version 2.19.1
```

### View Oban Jobs
```elixir
# In IEx
import Ecto.Query
Caque.Repo.all(from j in Oban.Job, order_by: [desc: j.inserted_at], limit: 10)
```

### Inspect Embeddings
```elixir
# Check if document has embedding
alias Caque.Documents.ParsedDocument
doc = Caque.Repo.get(ParsedDocument, "some-uuid")
length(doc.embedding) # Should be 1536
```

### Test Pipeline Without OpenSearch
```elixir
# Set env var before running
Application.put_env(:caque, :skip_opensearch, true)
```

---

## Git Workflow

### Branch Naming
- Feature branches should start with `claude/` prefix
- Include session ID in branch name for Claude Code sessions

### Commit Requirements
1. Clear, descriptive commit messages
2. All tests must pass before committing
3. No compilation warnings
4. Follow conventional commits format when possible

### Push Requirements
- Always use `git push -u origin <branch-name>`
- Retry on network errors with exponential backoff (2s, 4s, 8s, 16s)
- Verify branch name starts with `claude/` for Claude Code sessions

---

## External Resources

### Documentation
- [Phoenix Framework](https://hexdocs.pm/phoenix)
- [Ecto](https://hexdocs.pm/ecto)
- [OpenSearch](https://opensearch.org/docs/latest/)
- [Oban](https://hexdocs.pm/oban)

### APIs
- [OpenAI Embeddings](https://platform.openai.com/docs/api-reference/embeddings)
- [OpenAI Chat Completions](https://platform.openai.com/docs/api-reference/chat)

---

## Quick Reference

### Start Development
```bash
docker-compose up -d
docker exec -it caque_app iex --remsh dev
```

### Before Completing Tasks
```bash
mix compile --force  # Must have no warnings
mix test            # Must pass with no warnings
```

### Ingest Documentation
```elixir
alias Caque.Jobs.DocumentIngestionJob
alias Caque.Documents.Hexdocs.Pipeline
DocumentIngestionJob.enqueue_for_version(Pipeline, :openai, {1, 18, 3}, "text-embedding-ada-002")
```

### Search
```elixir
# Keyword
Caque.Documents.Cluster.keyword_search("Enum", limit: 5)

# Semantic (requires embedding first)
{:ok, %{embedding: emb}} = Caque.Embeddings.embed_query(:openai, "list operations", "text-embedding-ada-002")
Caque.Documents.Cluster.vector_search(emb, limit: 5)
```

---

**Remember**: Always run `mix compile --force` and `mix test` before considering any task complete!
