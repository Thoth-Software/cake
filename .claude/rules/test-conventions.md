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
- These are **not** auto-imported by `DataCase`/`ConnCase`/`ObanCase` — `import` the fixture module or `Cake.Factory` in each test that needs them.
- Property tests (StreamData) go in `*_property_test.exs`. When fixing a bug found by a property test, add a corresponding example test in the standard file.
- Mox expectations go in individual tests, not setup blocks.
- `test_helper.exs` sets `Application.put_env(:cake, :skip_opensearch, true)`. Tests that need search behavior mock the cluster via Mox or a test module.

## Never use `Process.sleep` to wait for async results

It is a race condition — an engraved invitation for flaky tests. Use deterministic synchronization instead:

- **LiveView async work:** use `start_async/3` in the LiveView, then `render_async(lv)` in tests. This waits for the task to complete before rendering — no sleep, no flake.
- **GenServer async work:** `assert_receive` on a message the process sends upon completion, or `:sys.get_state/2` to flush the mailbox.
- **Mox mocks that simulate slow work:** `Process.sleep` inside a mock body is fine — it delays the mock, not the test's assertion. The test still synchronizes on the result via `assert_receive` or similar.

