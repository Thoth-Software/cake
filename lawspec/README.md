# Cake laws (LawSpec)

This directory holds [LawSpec](https://github.com/brain-fuel/lawspec)
specifications for Cake modules (#323). LawSpec states the laws a module must
obey, with pinned examples, and compiles them into native property tests. For
Elixir these are StreamData properties inside ExUnit.

| Specification | Covers |
| --- | --- |
| `laws/decomposition.lawspec` | `Cake.Decomposition.Result`: `new/2` and `topological_order/1` |

## Why a separate Mix project

- **OTP 29.** LawSpec's BEAM targets require Erlang/OTP 29: `lawspec doctor`
  and `lawspec generate` refuse any other release. Cake itself runs on OTP 28.
- **Generated runtime.** `lawspec generate` writes about 6,000 lines of
  runtime: Erlang in `src/`, Elixir in `lib/lawspec/` and `test/support/`.
  That code is not written to Cake's `--warnings-as-errors`, credo, boundary,
  dialyzer or coverage gates, and it should not be.

So this project compiles only the Cake source files listed in `@cake_sources`
in `mix.exs`, never the application. It runs in the `laws` job of
`.github/workflows/quality.yml`. A covered module that gains a dependency on
another Cake module needs that module added to `@cake_sources`; until it is,
the compile fails.

## Layout

| Path | Owner | What |
| --- | --- | --- |
| `laws/*.lawspec` | you | the specifications |
| `lawspec.edn` | you | the manifest: sources, verification layers, the Elixir target, and its native failure mappings |
| `lib/cake_laws_*.ex` | you | adapters: each translates LawSpec's generated data to and from the Cake module it covers |
| `mix.exs`, `test/test_helper.exs` | you | the Mix project, set up as LawSpec's Elixir target guide asks |
| `.lawspec/generated.json` | LawSpec | the ownership manifest; commit it |
| everything else in `lib/`, `src/`, `test/` | LawSpec | generated; never edit by hand |

`Result.new/2` raises `ArgumentError` for an invalid graph.
`lawspec.edn` maps that exception to the spec's `InvalidDecomposition`
failure under `:native-bindings :failures`, so the adapter lets it
propagate instead of rescuing it.

## Running locally

You need Erlang/OTP 29, Elixir 1.20 and Node 22 or later. From this
directory:

```bash
npm ci
mix deps.get
MIX_ENV=test mix deps.compile
npx lawspec check
npx lawspec fmt --check
npx lawspec generate --check
mix test
```

- `npx lawspec explain` words every law in plain English. Add
  `--view math` for mathematical notation.
- `npx lawspec evidence` lists each obligation and its status.

## Changing a specification

Laws are tests, and Cake's ordering rule applies (CLAUDE.md "Testing:
Ordering and Failure Handling"). Change the `.lawspec` file first, format it
with `npx lawspec fmt`, regenerate with `npx lawspec generate`, then change
the Cake module. Format before you regenerate: the generated tests cite
source line numbers, so formatting after generating leaves them stale.
Commit the specification, the regenerated files and `.lawspec/generated.json`
together. CI fails on an unformatted specification (`lawspec fmt --check`)
and on stale generated files (`lawspec generate --check`).

A new specification for another module follows the same steps:

1. Write `laws/<name>.lawspec` with a unit named `cake.laws.<name>`.
   - The `cake.laws.` prefix keeps the adapter module (`Cake.Laws.<Name>`)
     out of Cake's own namespace.
2. Add the module's source file to `@cake_sources`.
3. Run `npx lawspec generate` and implement the adapter stub it writes.
4. Add the specification to the table above.
