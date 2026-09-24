---
paths:
  - "test/**/*.ex"
  - "test/**/*.exs"
---

# Test Conventions

Auto-loaded when working with files under `test/`.

Test data follows two tracks; pick by whether the thing is Ecto-backed:

- **Ecto schemas → Phoenix-style fixtures.** Each context has a `test/support/fixtures/<context>_fixtures.ex` module (e.g. `Cake.BooksFixtures`, `Cake.AccountsFixtures`) exposing `*_fixture/1` helpers that insert through the context. Import per test (e.g. `import Cake.BooksFixtures`).
- **Non-Ecto domain structs → `Cake.Factory` (ExMachina).** `test/support/factory.ex` defines factories built with `build/1,2` (currently `build(:convo_chunk)` for `Cake.Test.ConvoChunk`). Import per test (`import Cake.Factory`).
- **Fixture PDFs → `Cake.PdfFixtures`.** `test/support/pdf_fixtures.ex` loads the hand-built PDFs under `test/support/fixtures/pdfs/` by name (`fixture_binary/1`, `fixture_path/1` for staging through a storage adapter, `parse_fixture/1` for the bare `Pdf.Pipeline.parse/1` result). Edit the generator script there, never a PDF, and regenerate. Tests that go through the real NIF are tagged `:integration`.
- **End-to-end ingestion → `Cake.IngestIntegrationHelpers`.** `test/support/ingest_integration_helpers.ex`, imported per module on top of `use Cake.SearchIntegrationCase, async: false`: `stage_book_storage!/1` (setup callback: Disk adapter under a temp root) + `stage_fixture!/1` for a storage key, `ensure_collection!/1` for the GDS's fixed collection on the real node (created with the production mapping, emptied before and after the test), `stub_embeddings/1` for `Cake.Embeddings.Mock` answering from the input text (`deterministic_embedding/1` by default; `once_then_deterministic/1` for a first-call failure), `embed_input/1` for the exact string a pipeline embeds, `indexed_ids!/1` and `chunks_in_order/1` for what landed. Tests that clone a real repository `use Cake.SearchIntegrationCase, async: false, network: true`, which tags them `:network` instead of `:integration` — run with `--only integration --include network` (CLAUDE.md "Integration tests").
- **Live provider calls → `Cake.LiveLLMCase`.** `test/support/live_llm_case.ex` tags the module `:llm` (excluded by default; `OPENAI_KEY=... mix test --only llm` runs it — CLAUDE.md "Live LLM tests"), points `Cake.Embeddings` and `Cake.Generation.OpenAI` at the real endpoints for each test and restores afterwards, and refuses `async: true`. Files are `*_live_test.exs` beside the unit test they extend. Assert shapes and invariants, never generated content; read models and dimensions from config at run time.
- These are **not** auto-imported by `DataCase`/`ConnCase`/`ObanCase` — `import` the fixture module or `Cake.Factory` in each test that needs them.
- Property tests (StreamData) go in `*_property_test.exs`. When fixing a bug found by a property test, add a corresponding example test in the standard file.
- Mox expectations go in individual tests, not setup blocks.
- `test_helper.exs` sets `Application.put_env(:cake, :skip_search_backend, true)` in every run mode; only `Cake.SearchIntegrationCase` turns it off, in its own setup, for the tests that use it. An integration run (`mix test --only integration`) additionally repoints `Cake.Search.Deployment` at a real cluster. Unit tests that need search behavior mock the backend via Mox (`Cake.Search.Backend.Mock`) or the `Cake.Search.HTTPClientStub` adapter; real-cluster tests `use Cake.SearchIntegrationCase`, and a new `Cake.Search.Backend` implementation instantiates `Cake.Search.BackendConformance`. A pre-existing `:integration`-tagged test that runs a pipeline but is not about search (the Oban job tests) pins the flag on in its own setup.

## Never use `Process.sleep` to wait for async results

It is a race condition — an engraved invitation for flaky tests. Use deterministic synchronization instead:

- **LiveView async work:** use `start_async/3` in the LiveView, then `render_async(lv)` in tests. This waits for the task to complete before rendering — no sleep, no flake.
- **GenServer async work:** `assert_receive` on a message the process sends upon completion, or `:sys.get_state/2` to flush the mailbox.
- **Mox mocks that simulate slow work:** `Process.sleep` inside a mock body is fine — it delays the mock, not the test's assertion. The test still synchronizes on the result via `assert_receive` or similar.

