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
- These are **not** auto-imported by `DataCase`/`ConnCase`/`ObanCase` — `import` the fixture module or `Cake.Factory` in each test that needs them.
- Property tests (StreamData) go in `*_property_test.exs`. When fixing a bug found by a property test, add a corresponding example test in the standard file.
- Mox expectations go in individual tests, not setup blocks.
- `test_helper.exs` sets `Application.put_env(:cake, :skip_search_backend, true)` in every run mode; only `Cake.SearchIntegrationCase` turns it off, in its own setup, for the tests that use it. An integration run (`mix test --only integration`) additionally repoints `Cake.Search.Deployment` at a real cluster. Unit tests that need search behavior mock the backend via Mox (`Cake.Search.Backend.Mock`) or the `Cake.Search.HTTPClientStub` adapter; real-cluster tests `use Cake.SearchIntegrationCase`, and a new `Cake.Search.Backend` implementation instantiates `Cake.Search.BackendConformance`. A pre-existing `:integration`-tagged test that runs a pipeline but is not about search (the Oban job tests) pins the flag on in its own setup.

## Never use `Process.sleep` to wait for async results

It is a race condition — an engraved invitation for flaky tests. Use deterministic synchronization instead:

- **LiveView async work:** use `start_async/3` in the LiveView, then `render_async(lv)` in tests. This waits for the task to complete before rendering — no sleep, no flake.
- **GenServer async work:** `assert_receive` on a message the process sends upon completion, or `:sys.get_state/2` to flush the mailbox.
- **Mox mocks that simulate slow work:** `Process.sleep` inside a mock body is fine — it delays the mock, not the test's assertion. The test still synchronizes on the result via `assert_receive` or similar.

