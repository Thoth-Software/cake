# Investigation log — `Cake.Conversation`

Phase 0 deliverable for issue #132 (characterization tests). Records the
current behavior of `Cake.Conversation` as of commit `e0a2db3`, so the
tests that follow can pin exactly what exists today.

---

## Public API of `Cake.Conversation`

All signatures taken verbatim from `lib/cake/conversation.ex`.

| Function | Signature | Returns | Mechanism |
|---|---|---|---|
| `child_spec/1` | `(map()) :: Supervisor.child_spec()` | a supervisor child spec with `restart: :temporary` | pure |
| `start_link/1` | `(map()) :: GenServer.on_start()` | `{:ok, pid}` or `{:error, %KeyError{key: :gds, term: opts}}` | validates `:gds` before spawning |
| `start/1` | `(map()) :: GenServer.on_start()` | same as `start_link/1` | non-linked variant |
| `init/1` | `(map()) :: {:ok, state}` | `{:ok, state}` | called inside the GenServer; asserts `{:ok, gds}` via `fetch_gds/1` |
| `ask/2` | `(pid(), String.t()) :: :ok` | `:ok` (always, synchronously) | `GenServer.cast` — fire-and-forget |
| `print_hierarchy/2` | `(map(), list()) :: list()` | the map's entries via for-comprehension | logging-only helper, not part of the turn flow |

### `handle_call` clauses (the poll-style reads)

- `handle_call(:search_results, ...)` — returns the list of scored results. Two clauses:
  - non-empty: logs `"search_results requested by <pid>, returning N chunks"` and returns them.
  - empty: logs `"search_results requested but none available yet"` and returns `[]`.
- `handle_call(:chunk_map, ...)` — returns `state.chunk_map`.
- `handle_call(:citations, ...)` — returns `state.citations`.
- `handle_call(:inspect, ...)` — returns the full state map.

None of these are currently consumed by production code (see
*Polling interface* below).

### `handle_cast` clauses (the turn flow)

Two clauses dispatched on `state.search_results`:

- `[]` — first turn. Runs `run_first_turn/2` (embed + search + LLM + responses).
- non-empty — subsequent turn. Runs `run_subsequent_turn/3` (skips embed + search, reuses prior `search_results`).

Both clauses, on success, `send(state.reply_to, {:convo_response, response, citations})`; on failure, `send(state.reply_to, {:convo_error, error})` and push the error onto `state.errors`.

---

## GenServer state shape

Built by `build_state/2`. Every field is a map key (no struct).

| Field | Type | Default | Source |
|---|---|---|---|
| `search` | module | **required** via `opts.search` | injected collaborator |
| `reply_to` | pid | **required** via `opts.reply_to` | where `{:convo_response, _, _}` and `{:convo_error, _}` are sent |
| `embedder` | String.t() (model name) | **required** via `opts.embedder` | passed to `Cake.Embeddings.embed/3` |
| `response_model` | String.t() (model name) | **required** via `opts.response_model` | passed to `state.generation.complete/2` |
| `provider` | atom | **required** via `opts.provider` | passed to `Cake.Embeddings.embed/3` |
| `responses` | module | `Cake.Responses` | injected collaborator (added by Commit 1) |
| `generation` | module | `Cake.Generation.OpenAI` | injected collaborator |
| `gds` | module | **required** (KeyError otherwise) | validated by `fetch_gds/1` |
| `search_results` | list of `{struct, scores}` tuples | `[]` | populated on first successful turn |
| `message_history` | list of alternating `[question, response, question, response, ...]` strings | `[]` | `Cake.Prompt.history_messages/1` chunks this into pairs |
| `chunk_map` | `%{pos_integer() => Cake.Citable.metadata()}` | `%{}` | populated by `Cake.Responses.process/3` (via `Result`) |
| `citations` | `[Cake.Responses.Result.citation()]` | `[]` | populated by `Cake.Responses.process/3` |
| `errors` | list of error tuples | `[]` | prepended on failed turns |

---

## Message flow for a turn

### First turn (`state.search_results == []`)

1. `ask(pid, question)` → `GenServer.cast(pid, {:question, question})` → returns `:ok` immediately.
2. `handle_cast/2` dispatches to `run_first_turn/2`.
3. `embed_and_search/2`:
   - `Cake.Embeddings.embed(state.provider, %{input: question}, state.embedder)` — **direct module call**, not via an injected module.
   - `state.search.search_chunks_with_context(:hybrid, question, embedding, Cake.Search.OpenSearch.default_expand_offset(), gds: state.gds)` — via the injected `:search` opt.
   - `Cake.Search.score_results/2` → `Cake.Search.normalize_and_combine/1` → `Cake.Search.sort_by_relevance/1`. Pure.
   - Returns `{:ok, scored_results}`.
4. `Cake.Prompt.prepare_context(scored_results)` → `{indexed_chunks, _context_quality}`. Pure.
5. `Cake.Prompt.build(indexed_chunks, question, [])` → messages list. Pure. History is the empty list on turn 1.
6. `state.generation.complete(messages, state.response_model)` — **2-arg call**; see gotcha below.
   - On `{:ok, %{text: response, usage: _}}`: `state.responses.process(response, indexed_chunks, [])` produces a `Cake.Responses.Result`.
   - Updates state: `search_results: scored_results`, `message_history: [question, response]`, `chunk_map: result.chunk_map`, `citations: result.citations`.
   - Sends `{:convo_response, result.final_text, result.citations}` to `state.reply_to`.
   - `{:noreply, new_state}`.

### Subsequent turn (`state.search_results != []`)

1. `ask(pid, question)` as above.
2. `handle_cast/2` dispatches to `run_subsequent_turn/3`.
3. **No embedding, no search.** Reuses `state.search_results` as-is.
4. `Cake.Prompt.prepare_context(state.search_results)` → `{indexed_chunks, _}`.
5. `Cake.Prompt.build(indexed_chunks, question, state.message_history)` — history now threaded in.
6. `state.generation.complete(messages, state.response_model)`.
   - On success: state update is `message_history: state.message_history ++ [question, response]` (append, not prepend), and `chunk_map`/`citations` are overwritten with the new turn's values.
   - Sends `{:convo_response, result.final_text, result.citations}`.

### Error branches

- `embed_and_search/2` returning `{:error, _}`: falls out of the `with` chain in `run_first_turn/2`, returns the error tuple. `handle_cast/2` then sends `{:convo_error, error}` and pushes onto `state.errors`.
  - **Known bug** (flagged in CLAUDE.md): the first-turn error path double-wraps the error tuple. Not fixing here; pin the current behavior.
- `generation.complete/2` returning `{:error, _}`: returned from the `case` in `run_first_turn/2` / `run_subsequent_turn/3`. Same downstream handling.
- If `Cake.Responses.process/3` raises, it will crash the GenServer (no catch). No current test exercises this.

---

## Citation shape exposed to the caller

The `{:convo_response, response, citations}` message carries:

- `response` — the `Result.final_text` string (post-renumbering, post-formatting).
- `citations` — a list of citation maps per `Cake.Responses.Result.citation/0`:
  ```elixir
  %{
    old_index: pos_integer(),          # what the LLM wrote, e.g., [7]
    new_index: pos_integer(),          # first-appearance-renumbered, 1-based
    id: term(),                         # stable unique id from Citable
    label: String.t(),                  # display label, e.g., "Alpha, p. 1"
    preview: String.t(),                # first ~200 chars of text (Chunk impl)
    source_ref: String.t() | nil,      # download path or nil
    extras: map()                       # GDS-specific: for Chunk it's %{book_title, page_number, section_title, chunk_index}
  }
  ```

The `chunk_preview` / preview length is **200 characters** per `Cake.Citable` impl for `Cake.Books.Chunk` (`@preview_length 200`). This is a pin-worthy quirk.

Citation list is sorted by `new_index` ascending (per `Cake.Responses.renumber_citations/1`).

Fields that the issue spec calls out ("book_title, page_number, section_title, chunk_index, chunk_preview") are all present, but:

- `book_title`, `page_number`, `section_title`, `chunk_index` live under `extras`.
- `chunk_preview` is **not** a separate field — it is the top-level `preview` field. The issue spec's naming is slightly wrong; the actual field is `preview`.

---

## Polling interface

**The issue spec is wrong about this.** There is no polling.

- `CakeWeb.ChatLive` calls `Cake.Conversation.start(opts)` with `reply_to: self()`, then `handle_info({:convo_response, response, citations}, socket)` / `handle_info({:convo_error, error}, socket)` / `handle_info({:DOWN, ...}, socket)`.
- No `Process.send_after`, no timer, no periodic poll. It's a push model via `send/2`.

`Cake.Conversation` does expose `handle_call(:search_results | :chunk_map | :citations | :inspect, ...)` — these read state fields synchronously — but **no production consumer calls them**. They look like they were added in anticipation of a poller that never arrived, or as debug hooks.

**Implication for Commit 12 (polling interface):** the spec's instruction to "pin the polling interface used by ChatLive" has no analogue in the current code. Options:

1. Pin the `handle_call(:search_results / :chunk_map / :citations / :inspect)` contract instead, on the theory that these are the "polling-adjacent" reads.
2. Pin the push-message contract (`{:convo_response, _, _}` / `{:convo_error, _}`) as the ChatLive→Conversation notification seam.
3. Skip Commit 12 entirely (note it in the commit log, no test added).

**This needs a decision from Jasper before Phase 5.**

---

## Error handling, current behavior

### Cluster/search failure

`search.search_chunks_with_context/5` returns `{:error, reason}`:
- falls out of the `with` in `embed_and_search/2` and bubbles up through `run_first_turn/2`.
- `handle_cast/2` first-turn error branch: `send(reply_to, {:convo_error, error})`, push onto `state.errors`.
- **Known double-wrap bug** on first turn: look at lines 76–79 of `conversation.ex`; the `error` variable here already is `{:error, reason}`. No production change; pin as-is.

### Embeddings failure

`Cake.Embeddings.embed/3` returns `{:error, String.t()}`. Same flow as cluster failure — falls out of `with` in `embed_and_search/2`.

**But this flow is currently impossible to exercise in tests without a production change** (see gotchas below).

### LLM/generation failure

`state.generation.complete/2` returning `{:error, reason}`:
- Returned from `case` → bubbles out of `run_first_turn/2` / `run_subsequent_turn/3` as `{:error, reason}`.
- Same `handle_cast` error branch.

### Zero chunks returned

`scored_results == []` is a valid success. `Cake.Prompt.prepare_context([])` returns `{[], :none}`. `Cake.Prompt.build([], question, history)` dispatches to a different clause that uses `system_message_no_context()` (a no-context prompt). LLM is still called. Result is still processed. No short-circuit.

### Uncited LLM output

If the LLM returns text with no `[N]` markers, `Cake.Responses.process/3` returns a `Result` with `citations: []`. The frontend receives `{:convo_response, final_text, []}`.

### `Cake.Responses.process/3` raising

No current test exercises this. It would crash the GenServer. Given `restart: :temporary`, the supervisor does **not** restart.

---

## History handling

- `state.message_history` is a flat list of alternating `[question_1, response_1, question_2, response_2, ...]` strings (not structs).
- On first turn, history initialized to `[question, response]`.
- On subsequent turns, history is **appended**: `state.message_history ++ [question, response]`.
- `Cake.Prompt.build/4` receives `history` and passes it to `Cake.Prompt.history_messages/1`, which chunks it pairwise (`Enum.chunk_every(2, 2, :discard)`) and keeps the most recent 5 exchanges (`Enum.take(-5)`).
- History is threaded **only to the prompt**. It is not passed to the cluster / search.

---

## Concurrency behavior

- `ask/2` is `GenServer.cast` — **returns `:ok` immediately**, fire-and-forget.
- The heavy work (embed, search, LLM) runs inside `handle_cast/2`, which is synchronous with respect to the mailbox: a second `ask/2` arriving while the first is in progress queues in the GenServer's mailbox and does not start until the first `handle_cast/2` returns.
- No tasks are spawned. No async pattern. `handle_call` reads are blocked for the duration of an in-flight `handle_cast`.
- Callers see: `ask/2` returns `:ok` regardless; the eventual result arrives as a message to `reply_to`.

---

## Gotchas blocking the test plan

These are contradictions between the issue spec's assumptions and current code. **Need Jasper's decision before writing tests.**

### 1. Generation arity mismatch

`Cake.Generation.Behaviour` declares the callback as 3-arity: `complete(messages, model, opts)`. `Cake.Generation.OpenAI.complete/3` has `opts \\ []`, so both `complete/2` and `complete/3` exist on the impl. But `Cake.Generation.Mock` (defined via `Mox.defmock(..., for: Cake.Generation)`) only exposes the arity the behaviour declares — `complete/3`.

`Cake.Conversation` calls `state.generation.complete(messages, state.response_model)` — **2 args, not 3**. Against the real OpenAI impl this works via the default arg. Against `Cake.Generation.Mock` it will raise `UndefinedFunctionError` for `Cake.Generation.Mock.complete/2`.

**Impact:** Mox cannot stand in for `Cake.Generation` as-is. Possible resolutions:

- a. Add `@callback complete(messages, model)` to `Cake.Generation` (production change, minor, one line).
- b. Change `Cake.Conversation` to call `state.generation.complete(messages, state.response_model, [])` (production change to conversation.ex — **forbidden by the issue**).
- c. Write a hand-rolled stub `Cake.Generation.Stub` in `test/support/` that implements `Cake.Generation` and reads its response from `Process`-dict / Agent / ETS. No production changes.

I recommend (c). It keeps this issue scoped to test-only changes and sidesteps the arity question.

### 2. Embeddings not injected

`Cake.Conversation` calls `Cake.Embeddings.embed(provider, %{input: question}, embedder)` **directly** — not via an injected module. `Cake.Embeddings` in turn calls `Req.post/1` directly (no `:plug` option).

**Impact:** There is no seam to mock embeddings. Tests would need one of:

- a. Add `:embeddings` to Conversation's injected opts (production change to conversation.ex — forbidden).
- b. Modify `Cake.Embeddings` to read a module or plug from Application config (production change to embeddings.ex).
- c. Use `Req.Test` — but `Cake.Embeddings` doesn't thread a `:plug` option through, so this requires a production change to `Cake.Embeddings`.

None of (a)/(b)/(c) is purely test-side. **This is a real blocker for first-turn tests** (embed+search+LLM+respond). Options:

- Ask Jasper if Commit 1 scope can expand to include injecting `:embeddings` (mirrors the `:responses` injection in the existing Commit 1).
- Design tests around second-turn flow (where `search_results` is already populated, so embedding is skipped). Requires priming state via `:sys.replace_state/2` before `ask/2` — ugly but test-side only.
- Accept the tests cover subsequent-turn flow only and note the gap.

### 3. "Polling interface" doesn't exist

See *Polling interface* section. ChatLive uses `handle_info` + `send/2`, not polling. Commit 12 as written has nothing to pin.

### 4. Preview field name

Spec calls it `chunk_preview`; actual field is `preview` at the top of the citation map. `chunk_index` does exist (inside `extras`). Minor — call it out when writing Commit 5.

### 5. `chunk_index` on Chunk

`Cake.Books.Chunk` has a `chunk_index` integer field and `Cake.Citable` surfaces it under `extras`. So Commit 5's list of fields is mostly right; just `chunk_preview` → `preview`.

---

## Test infrastructure available

- `mix.exs` has `mox ~> 1.2.0` and `ex_machina ~> 2.8`. Confirmed.
- `test/support/mocks.ex` already defines `Cake.Embeddings.Mock`, `Cake.Search.Mock`, `Cake.Generation.Mock`, `Cake.Responses.Mock`.
- `test/support/fixture_gds.ex` — in-memory `Cake.GDS` impl with call recording. `FixtureGDS.Record` does NOT implement `Cake.Promptable`. A second-turn test that reuses `search_results` would need `Promptable` on whatever struct is in there, or would need to prime state with structs that already have `Promptable` (e.g., `Cake.Books.Chunk` via factory — requires DataCase for the DB).
- `test/support/stub_chunk.ex` — `Cake.Test.StubChunk` has `Citable` only, not `Promptable`.
- `test/test_helper.exs` sets `skip_opensearch: true` and runs `ExUnit.start()`.
- `Cake.DataCase` sets up SQL sandbox; use with `async: true` is supported.
- Existing `test/cake/conversation_test.exs` exercises `start_link/1` validation only — `:gds` opt. No turn-flow tests yet.

---

## Recommended way forward

Given the gotchas above, the minimum viable plan:

1. Either (a) extend Commit 1 to inject `:embeddings` into Conversation, **or** (b) write tests that prime `search_results` via `:sys.replace_state/2` and only exercise the subsequent-turn path. Jasper to decide.
2. Use a hand-rolled `Cake.Generation.Stub` test-support module to sidestep Mox arity mismatch. Or add `complete/2` to the behaviour.
3. For Commit 12, pin the push-message contract (`{:convo_response, _, _}` / `{:convo_error, _}`) rather than a nonexistent polling interface, or drop the commit.
4. For Promptable on test structs: either use real `Cake.Books.Chunk` via factory (requires DataCase), or add a `Cake.Promptable` impl for `StubChunk` (test-only, straightforward).

I'll pause here and wait for your call on items 1–4 before writing any tests.
