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

When Cake's lock moves one of these, move it here too. `stream_data` is the
exception: it is pinned to the version LawSpec's Elixir target requires.
Advisories `mix deps.get` reports for these packages are Cake's own (the
report-only backlog, #206); this project is test-only and never deployed.

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
needs `:extras` or a non-text `:id`.

## Generating text: three caveats

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
