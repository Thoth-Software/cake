# Cake laws (LawSpec)

This directory holds [LawSpec](https://github.com/brain-fuel/lawspec)
specifications for Cake modules (#323). LawSpec states the laws a module must
obey, with pinned examples, and compiles them into native property tests. For
Elixir these are StreamData properties inside ExUnit.

| Specification | Covers |
| --- | --- |
| `laws/decomposition.lawspec` | `Cake.Decomposition.Result`: `new/2` and `topological_order/1` |
| `laws/citations.lawspec` | `Cake.Citations.extract/2`: valid citations and hallucinated indices, each in first-appearance order against a reference model; totality; leading zeros; and `[0]`, which is always hallucinated because `Cake.Prompt` numbers from 1 |
| `laws/responses.lawspec` | `Cake.Responses.process/3` and `build_citation_map/1`: the chunk map; one citation per retrieval unit, numbered `1..K` by first appearance; the final text against a reference model of marker rewriting and whitespace tidying; warnings, download actions, and the untouched `raw_text` and empty `media` |
| `laws/candidates.lawspec` | `Cake.Candidates`: `group_by_document/1` against a reference model (one group per document id, in first-seen order, candidates in input order, text keys) and as a permutation of its input; `all_chunk_ids/1` and `expand_to_chunk_ids/2` against a reference model of a selection, with expansion distributing over appended selections; `document_metadata/1`'s title, 100-character preview and page label, which counts distinct pages; and a group for every candidate whatever its `Cake.Citable` id |
| `laws/prompt_context.lawspec` | `Cake.Prompt`'s context assembly: `prepare_context/2` against a reference model (the first `max_chunks` results at or above the relevance floor, in input order, numbered from 1), its bounds, dense numbering and context quality, its defaults (ten chunks, a floor of 0.30), and a result with no relevance score, which never passes the floor; `format_chunk/1`; `history_messages/1` as the last five complete exchanges; `build/4` as the system message, the recent history, then the question; and the context block that ends `system_message_with_context/1` |
| `laws/prompt_drivers.lawspec` | `Cake.Prompt`'s token budgets and driver protocols: `estimate_tokens/1` as the length over four, rounded up; `fit_answer_pairs/2` against a reference model (the longest run of the newest pairs that fits the budget, and none on a budget of zero); `build_with_prior_answers/5`, which is `build/4` when no pair survives and otherwise folds in the survivors and no others; `self_ask_prompt/3` and `ircot_prompt/3`, which fold in the pairs or steps that survive the same eviction, the IRCoT context without a `[N]` marker; `parse_self_ask_response/1` against a reference model of replies built from lines (the final-answer marker wins, then the last follow-up); and `parse_ircot_response/1`, where a null or blank retrieval query means done |
| `laws/search_query.lawspec` | The `Cake.Search.Query` builders and `Cake.Search.Backend.OpenSearch.to_query_map/1`: clause builders are additive, a clause equal to one the query already holds included; `size` and `min_score` are last-write-wins over `new/2`'s options, and `nil` clears a minimum score; calls in any other order build the same clauses; a knn clause carries `method_parameters.ef_search` only when the call gives one; the query map keeps the query's size, clauses and `min_score`, with a `:min_score` key exactly when it is not `nil`; and the map lists each clause list in call order, against a reference model that folds the calls |
| `laws/fakes.lawspec` | `Cake.Laws.FakeUnit`, the test retrieval unit: it carries generated data through `Cake.Citable` and `Cake.Promptable` unchanged, and meets the five-key `Citable` contract |
| `laws/shared.lawspec` | no laws: types and checked definitions other specifications import (see "Shared types" below) |

## Why a separate Mix project

- **OTP 29.** LawSpec's BEAM targets require Erlang/OTP 29: `lawspec doctor`
  and `lawspec generate` refuse any other release. Cake itself runs on OTP 28.
- **Generated runtime.** `lawspec generate` writes about 6,000 lines of
  runtime: Erlang in `src/`, Elixir in `lib/lawspec/` and `test/support/`.
  That code is not written to Cake's `--warnings-as-errors`, credo, boundary,
  dialyzer or coverage gates, and it should not be.

So this project compiles only the Cake source files listed in `@cake_sources`
in `mix.exs`, never the application (#326 chose this over depending on all of
Cake as a path dependency). It runs in the `laws` job of
`.github/workflows/quality.yml`. A covered module that gains a dependency on
another Cake module needs that module added to `@cake_sources`.

A Cake module that calls modules outside `@cake_sources` in functions no law
exercises still compiles, with undefined-module warnings. This project is not
built with `--warnings-as-errors`, so those warnings are expected; a law that
reaches such a call fails with `UndefinedFunctionError`, which says which
module to add.

## Hex dependencies

Cake's own dependencies that covered modules need are pinned in `mix.exs` to
the exact versions in Cake's `mix.lock`, transitive ones included in this
project's `mix.lock`, so a covered module behaves here as it does in Cake:

- `boundary` (`runtime: false`): for the many Cake modules that `use Boundary`.
  Its compiler is not enabled here; the boundary gate is Cake's.
- `ecto`: for `Cake.Schema`, schemas and changesets, `Ecto.UUID`. No Repo and
  no database.
- `jason`: for structs that derive `Jason.Encoder`.
- `snap` and `finch`: for `Cake.Search.Backend.OpenSearch`, which matches on
  `%Snap.Hit{}`. `snap` matches on `%Finch.Response{}` in turn, so it does
  not compile without `finch`, which it lists as optional. No cluster and no
  HTTP: the laws call only `to_query_map/1`, which is pure.

When Cake's lock moves one of these, move it here too. `stream_data` is the
exception: it is pinned to the version LawSpec's Elixir target requires.
Advisories `mix deps.get` reports for these packages are Cake's own (the
report-only backlog, #206); this project is test-only and never deployed.

**Why `snap` (#332).** The search query unit takes `snap` and `finch` for
one pure function, `to_query_map/1`. The alternative was to leave
`open_search.ex` out and state the clause-order law on `Cake.Search.Query`'s
own struct fields. That law would pin the wrong thing. The struct holds each
clause list newest first, and the order anything outside can observe is the
order in the map OpenSearch is sent, which comes from the builders prepending
and `to_query_map/1` reversing together. A law on the struct still passes
when `to_query_map/1` stops reversing, and fails when both halves change in
step and nothing observable does. With `open_search.ex` compiled, the order
law is about the map, and no law depends on the order the struct holds. The
cost is eight more packages in `mix.lock` (`snap`, `finch`, `castore`,
`mint`, `hpax`, `mime`, `nimble_options`, `nimble_pool`), each at Cake's
locked version, and about three seconds on a cold dependency compile.

## Layout

| Path | Owner | What |
| --- | --- | --- |
| `laws/*.lawspec` | you | the specifications |
| `lawspec.edn` | you | the manifest: sources, verification layers, the Elixir target, and its native failure mappings |
| `lib/cake_laws_<unit>.ex` | you | adapters: each translates LawSpec's generated data to and from the Cake module it covers |
| `lib/cake_laws/*.ex` | you | support modules adapters share: `Cake.Laws.FakeUnit`, and `Cake.Laws.Quiet`, which silences the warnings Cake logs on generated input |
| `mix.exs`, `test/test_helper.exs` | you | the Mix project, set up as LawSpec's Elixir target guide asks |
| `.lawspec/generated.json` | LawSpec | the ownership manifest; commit it |
| everything else in `lib/` (including `lib/cake_laws_<unit>_definitions.ex`), `src/`, `test/` | LawSpec | generated; never edit by hand |

`Result.new/2` raises `ArgumentError` for an invalid graph.
`lawspec.edn` maps that exception to the spec's `InvalidDecomposition`
failure under `:native-bindings :failures`, so the adapter lets it
propagate instead of rescuing it.

## Shared types and fakes

**Shared types.** `laws/shared.lawspec` (`cake.laws.shared`) holds types and
checked definitions more than one specification needs, so they are declared
once:

- `CitableMeta`: a retrieval unit's `Cake.Citable` metadata, less `:extras`.
- `Segment` and `render`: LLM response text as plain text and `[N]` markers,
  rendered to the text Cake parses. `Plain` text never contains `[` or `]`.

Import them by name, as `laws/fakes.lawspec` does:

```lawspec fragment
import cake.laws.shared as shared (CitableMeta, Segment, render)
```

An imported type stays `cake.laws.shared`'s, so its values are the same in
every importer. Generated Elixir names it `LawSpec.Data.<Name>`
(`LawSpec.Data.CitableMeta`), adding the unit as a prefix only when the name
collides with another unit's (the pilot's `Entry` became
`LawSpec.Data.CakeLawsDecompositionTypeEntry`). Imported checked definitions
are copied into the importer. Adapter signatures and laws can't be imported;
each unit states its own.

Add a type here once a second specification needs it. `CitableMeta` and
`Segment` are here already because the citations and responses units (#327,
#328) both build on them.

**Importing another unit.** Any unit's types and checked definitions can be
imported the same way, not only the shared unit's: `laws/responses.lawspec`
imports the citations unit's reference model (`distinctMarkers`,
`citationsOf`, `missingFrom`) instead of restating it. One limit, as of
LawSpec 0.32.0: a definition that tests list membership with `in` cannot be
copied into an importer (`unknown value: lawspecCollections.setMember`).
Write `items contains item` in any definition another unit may import.

**Fake retrieval units.** Cake code that dispatches through `Cake.Citable` or
`Cake.Promptable` (`Citations`, `Responses`, `Candidates`, `Prompt`,
`Conversation`) needs a struct implementing both. Adapters use
`Cake.Laws.FakeUnit` (`lib/cake_laws/fake_unit.ex`): `FakeUnit.new(meta,
prompt_text)` from a generated `CitableMeta`, and
`FakeUnit.to_citable_meta/1` back. `laws/fakes.lawspec` pins that the fake
returns exactly what it was given, so a specification that uses it tests
Cake's code, not the fake. Construct the struct directly when an adapter
needs `:extras`, as `Cake.Laws.Candidates` does.

## Generating text: four caveats

- **Code points, not graphemes.** LawSpec's `prelude.length` and text
  operations count Unicode code points; Elixir's `String.length/1` and
  `String.slice/3` count grapheme clusters. They differ on combining marks,
  emoji sequences and `"\r\n"`. A law about a length or a slice of generated
  text holds only if the text is restricted (to ASCII, say) or the adapter
  binds a native length.
- **No replace, no trim.** LawSpec's text operations join, slice and test
  for a substring; none rewrites text. To pin text that Cake rewrites, build
  the input from pieces and compute the expected text piece by piece, as
  `laws/responses.lawspec` does for `final_text`: a word, a space, a newline
  or a marker, each of which the whitespace rules treat as one item.
- **Generated text is short.** Measured on the candidates unit, 675
  generated values of a regex-refined `Text` had a median length of 0 and a
  longest of 19, and a `{0,160}` bound in the regex did not make them longer.
  A law about a length threshold never reaches it unless the law builds the
  text: repeat a fixed piece a generated number of times and append the
  generated text, as `laws/candidates.lawspec` does for the 100-character
  preview cut (`previewOf`). Check that such a law bites by breaking the Cake
  code and watching it fail.
- **Float64.** LawSpec's `Float64` has no portable order, and exact laws
  over float arithmetic are rarely true. Where Cake only compares or stores a
  float (relevance scores, boosts), generate an exact number such as
  `Integer` hundredths and convert it in the adapter. Where Cake computes with
  floats (cosine similarity), keep the property in StreamData.

## Running LawSpec

Run LawSpec through the npm scripts in `package.json`, never through
`npx lawspec`. The scripts start node with `--no-turbo-fast-api-calls`. On
Node 22, LawSpec's WASM core opens its cache files through WASI, and Node
handles that call on V8's fast-call path, where an allocation can start a
garbage collection that V8 does not allow there. Once `.lawspec/cache` is
warm, `npx lawspec check` and `generate` then die with a bare
`Segmentation fault` (exit 139). The flag turns the fast path off; node
rejects it in `NODE_OPTIONS`, so it goes on the command line.

LawSpec 0.32.0 fixes this in its own compiler host, which now turns those
fast calls off itself. Upstream verified the fix only under x64 emulation.
On native x64 (#349), 0.31.3 without the flag segfaulted in 3 of 5
warm-cache runs, and 0.32.0 without it ran clean in 25 of 25. The scripts
keep the flag until a follow-up drops it from them, from this section, from
the `laws` job's comment in `quality.yml` and from CLAUDE.md together.

| Script | Runs |
| --- | --- |
| `npm run check` | `lawspec check` |
| `npm run fmt` / `npm run fmt:check` | `lawspec fmt` / `lawspec fmt --check` |
| `npm run generate` / `npm run generate:check` | `lawspec generate` / `lawspec generate --check` |
| `npm run lawspec -- <args>` | any other command, such as `explain` or `evidence` |

## The prelude in Claude Code sessions

A Claude Code session that writes a specification from memory guesses at
prelude names, so a hook loads the prelude into the session instead. It is
read from the compiler installed in `node_modules` each time, never from a
copy in the repository, so it matches the LawSpec version `package.json`
pins and needs no upkeep when that version moves.

- **When.** The first tool call of a session that touches LawSpec work: a
  file under `lawspec/` or any `.lawspec` file, a call made from inside
  `lawspec/`, or a shell command or search that names `lawspec`. It loads
  once per session, and once more for each subagent. A session that is
  cleared or compacted loads it again on its next such call, because the
  earlier load is no longer in its context; a resumed session gets its
  transcript back and does not.
- **What.** Every prelude operation name, and every prelude law with its
  parameters, constraints and definition, from `lawspec prelude --json`. The
  compiler reports operation names only, with no signatures. Claude Code
  shows a session at most 10,000 characters from a hook, so descriptions and
  rationales are left out; the hook writes the full source to a temporary
  file and gives its path.
- **Where.** `.claude/hooks/lawspec-prelude.sh` is registered in
  `.claude/settings.json` for `PreToolUse` (Read, Edit, Write, Grep, Glob,
  Bash) and `SessionStart`. It is a cheap gate that runs before every one of
  those calls and starts node only for a call that mentions `lawspec`;
  `.claude/hooks/lawspec-prelude.mjs` decides and renders. Neither can block
  or fail a tool call.
- **Not installed.** Without `node_modules/lawspec` the hook says so once,
  with the `npm ci` to run, and loads the prelude on the next call after
  that.

To read the same inventory by hand: `npm run -s lawspec -- prelude`.

## Running locally

You need Erlang/OTP 29, Elixir 1.20 and Node 22 or later. From this
directory:

```bash
npm ci
mix deps.get
MIX_ENV=test mix deps.compile
npm run check
npm run fmt:check
npm run generate:check
mix test
```

- `npm run lawspec -- explain` words every law in plain English. Add
  `--view math` for mathematical notation.
- `npm run lawspec -- evidence` lists each obligation and its status.

## Changing a specification

Laws are tests, and Cake's ordering rule applies (CLAUDE.md "Testing:
Ordering and Failure Handling"). Change the `.lawspec` file first, format it
with `npm run fmt`, regenerate with `npm run generate`, then change
the Cake module. Format before you regenerate: the generated tests cite
source line numbers, so formatting after generating leaves them stale.
Commit the specification, the regenerated files and `.lawspec/generated.json`
together. CI fails on an unformatted specification (`lawspec fmt --check`)
and on stale generated files (`lawspec generate --check`).

Ten things `npm run check`, `npm run generate` and the generator are
strict or quiet about:

- **Definition names are global.** Two units that each define a function of
  the same name both compile, but the generator renames one (`distinct`
  became `distinct_2`) and rewrites the other unit's generated files. Pick a
  name no other unit uses: `grep -n "^function <name> " laws/*.lawspec`.
- **A function cannot build a record with a refined field from a computed
  value.** `check` fails with `constructor field refinement could not be
  proved`, even when the value is copied from another record of the same
  type. Give the field a literal or `Absent`, or keep the refinement off the
  record and on the law's own variable. The same holds in the other
  direction: a definition whose parameter is refined cannot be passed a
  record's field of that refinement (`definition call precondition could not
  be proved`). Leave the refinement off the parameter.
- **An example's expected value is a literal.** The right-hand side of
  `expect ... = ...` takes a constructor or a literal, not a function call.
- **A function needs an input.** An adapter signature with no argument, for
  a Cake function of arity zero, fails `check` with `functions require one
  or more concrete value inputs and a value result`. Declare it
  `Unit -> Text` and call it with the unit value, `f ()`; the adapter
  receives `:ok`. `laws/prompt_context.lawspec` does this for
  `Cake.Prompt.system_message_no_context/0`.
- **Prelude argument order is not checked for you.** The compiler lists
  prelude names without signatures, and `prelude.endsWith` type-checks with
  its two texts in either order. It takes the text first and the suffix
  second; the other way round is a law that is false, not an error.
- **A bound drawn from every whole number rarely bites.** A refinement's
  bounds narrow what is generated instead of filtering it, so refine a
  ceiling the law must reach. Measured on the prompt context unit: with
  `max_chunks` generated as any `Whole`, the property passed when
  `Cake.Prompt` was broken to apply the ceiling before the floor; with the
  ceiling refined to 0..12 (`SmallCeiling`) it failed, as it should. Check
  that such a law bites by breaking the Cake code and watching it fail.
- **A `Maybe` of regex-refined text is always `Absent`.** Measured on the
  prompt drivers unit, as of LawSpec 0.32.0: a record field
  `text :: Maybe Phrase`, with `Phrase` a regex refinement, was `Absent` in
  every generated value, so a law about the text after a marker only ever
  saw a marker trailed by nothing, and passed with `Cake.Prompt` broken.
  Give the field a refinement that also matches the empty text (`Wording`)
  and treat the empty text as the absent case. A `Maybe` of a record or of
  plain `Text` is generated both ways.
- **A long generated list holds only its type's cheapest values.** A list
  is generated under a size budget its elements share, and a constructor is
  offered only when an element's share covers it. Measured on the search
  query unit, as of LawSpec 0.32.0, over the 222 lists two laws drew as a
  `List BuilderCall`: of their 4,483 calls, 76% were the one constructor
  with no payload, 21% the two that carry a single number, and 2% the four
  that carry a clause record. One list held two different knn clauses, and
  the law that clauses keep their call order passed in one run of two with
  the reversal removed from `to_query_map/1`. Generate the expensive values
  as lists of their own type and build the mixed list from them in a
  checked definition, as `laws/search_query.lawspec` does (`CallMix`,
  `callsOf`): about one list in ten then holds two different knn clauses,
  and the law failed in each of six runs.
- **Two generated records are rarely equal.** A law about a value that
  occurs twice (a clause added again, an id cited again) never sees one
  unless it builds the repeat: make the generated list twice over, as
  `callsTimes` does in the same unit. A `filter_term/3` that dropped a
  clause the query already held passed every law until it did.
- **Regex-refined text is slow to generate.** Each generated value costs a
  few milliseconds, which adds up inside lists. Measured on the same unit:
  two laws over lines that each carried three regex-refined fields took 70
  and 26 seconds; with the two whitespace fields turned into enumerations
  rendered by a checked definition (`Gap`, `gapText`), under three seconds
  each. Refining a list's length made generation slower, not faster.

A new specification for another module follows the same steps:

1. Write `laws/<name>.lawspec` with a unit named `cake.laws.<name>`.
   - The `cake.laws.` prefix keeps the adapter module (`Cake.Laws.<Name>`)
     out of Cake's own namespace.
2. Add the module's source file to `@cake_sources`, and any hex dependency it
   needs (see "Hex dependencies"; pin Cake's locked version).
3. Import shared types from `cake.laws.shared` instead of redeclaring them,
   and use `Cake.Laws.FakeUnit` for retrieval units.
4. Run `npm run fmt`, then `npm run generate`, and implement the
   adapter stub it writes.
5. Add the specification to the table above.
