# Monthly documentation sweep for Cake

How to use this file: paste everything below the rule as the prompt for a fresh Claude Code session on a clean checkout of `master`, or save it as `.claude/commands/doc-sweep.md` and invoke `/doc-sweep`. It is written for an autonomous run that ends in a report and issues, not in merged changes.

---

Do a documentation sweep of this repository and bring the documentation back into agreement with the code. Work in the phases below, in order. Do not write code or change documentation during the audit phases; the audit ends in a report and a set of issues, and the fixes are executed only after I have made the judgment calls. Read `CLAUDE.md` and `README.md` first and obey them throughout.

## Principles that govern the whole sweep

- **The code is the ground truth for *what is*; the docs are the ground truth for *what should be*.** When they disagree, classify before touching anything: (a) the README is stale and the code is clearly right; (b) the README states an intended contract and the code violates it, which is a code defect to file, not a sentence to soften; (c) two defensible readings exist, which is a judgment call for me. Never silently resolve a (b) or a (c).
- **Verify before you assert.** Every claim you add to a doc must be checked against the source at the line level before you write it, and every claim a reviewer challenges must be re-checked before you reply. The failure mode of the last sweep was not missing facts but overstating them: "only X does Y", "after every stage", "the gate before every call", "is not revealed". Completeness and universality words need a grep behind them.
- **Mechanical versus judgment.** A fix is mechanical when the code already decides the right text and two careful people would write the same thing. It needs judgment when a reasonable alternative exists, when it reverses a recorded decision, when it changes a contract, or when it changes what the product does. Keep the two apart in the report and in the issues, and when you recommend an option on a judgment item, still present it as a choice.
- **Scope discipline.** A doc sweep documents behaviour; it does not change it. Code defects the sweep finds become issues with a tests-first checklist. Dead public API becomes a question for me, because removing it needs approval under CLAUDE.md.

## Phase 0: Orient

1. Record the head commit, the README front-matter `date:`, and the date of the last sweep (search closed issues and PRs for "documentation sweep" / "Documentation pass"). Everything you report is drift since then.
2. List open issues so findings link to existing tracker items instead of duplicating them, and so Known Defects entries can carry issue numbers.
3. Note the repo's label conventions (`.github/workflows/auto-label.yml`) and the epic convention (an epic carries the union of its sub-issues' labels plus `epic-N`).

## Phase 1: README against the code

Fan out read-only auditors, one per section cluster (ingestion and error handling; search and embeddings; conversation, prompt, generation, responses and decomposition; web, supervision tree, boundaries, the three inventories, data schemas). Each auditor extracts every checkable claim in its sections (module and function names with arities, callback lists, struct fields and enforced keys, defaults, config keys, step strings, event shapes, error shapes, file paths, "current implementations" lists) and verifies each against `lib/`, `config/`, `test/support/`, `priv/repo/migrations` and `mix.exs`. Require from each: a count of claims checked, then only disparities with README line, quoted claim, `path:line`, what the code does, and an (a)/(b)/(c) verdict; then an "Omissions" list of things in the code the README should name and does not (the enumeration rule: inventories of structs, behaviours, protocols, implementations, pipelines, boundaries, config keys, events, error unions).

Then spot-check the auditors yourself: re-read the source behind every (b) and every surprising (a) before it goes in the report. Specific traps from the last sweep, all of which a reviewer caught:

- "Only X turns this off / sets this / calls this" — grep the whole tree, including `test/`, before writing "only".
- Events, callbacks and hooks fire on state transitions or conditions, not "after every stage"; name the states.
- Collection operations that filter before they dedupe ("one action per unique `source_ref`" was really "per unique non-`nil` `source_ref`").
- Config inventories: either list every key `lib/` reads (grep `Application.get_env(:cake` and `fetch_env!(:cake`, including `__MODULE__`-keyed blocks and optional keys like `:plug`) or state the scope narrowly and name what is excluded.
- Security-flavoured phrasing ("existence is not revealed") must match the actual response bodies.
- Loops: "waits N seconds then proceeds" versus "polls every N seconds until a condition".
- Validation order: say what runs before what, and what slips through because of it.

## Phase 2: CLAUDE.md

CLAUDE.md is paid for on every turn, so the test for each paragraph is whether a task unrelated to its subject still needs it in context. Measure it (words per section), then build a redundancy map against: `.claude/rules/*.md`, the comments in `test/test_helper.exs`, the job comments in `.github/workflows/quality.yml`, the moduledocs of the Mix tasks, `mix.exs` alias comments, and the README. Report what is stated more than once and where the single home should be, what can move behind the "Load by trigger" table or a path-scoped rule (name the globs and the always-on remainder), and which trigger rows point at files that do not exist or which `priv/reference/` files no trigger reaches. Check CLAUDE.md's tooling claims against `mix.exs`, the workflow job list, `coveralls.json`, `.sobelow-conf` and `priv/hooks/`, and check Known Defects entries against open issues (each should be one line plus an issue number; anything without an issue needs one cut before it can be shortened).

## Phase 3: Docstrings

Measure from compiled docs chunks, not by grepping for `@doc`: lower-arity heads produced by default arguments count as documented when the full arity is, `@impl` functions are hidden rather than missing, protocol implementation modules are skipped, and `use`-generated functions are separated from the module's own. Run `mix docs --warnings-as-errors` first (if `Cake.ParseBooks` fails to load, `MIX_ENV=dev mix compile --force` rebuilds the NIF; that is environmental, not a doc problem). Then run this script with `MIX_ENV=dev mix run --no-start doc_coverage.exs` and report: modules without `@moduledoc` (expect Phoenix scaffolding only), callbacks without `@doc`, public own functions without `@doc` grouped by kind (README-cited API first, then pipeline stages, prompt text, query helpers, web), explicit `@doc false` worth a second look, and `@typedoc` coverage.

```elixir
# doc_coverage.exs — docstring coverage from the compiled docs chunks of the :cake app
Application.load(:cake)
mods = :cake |> Application.spec(:modules) |> Enum.sort()

generated =
  ~w(__info__ __struct__ __changeset__ __schema__ __impl__ __protocol__ __deriving__ module_info
     behaviour_info __live__ __components__ __phoenix_verify_routes__ __phoenix_component_verify__
     __mix_recompile__? __routes__ __helpers__ __checks__ __gettext__ __live_view__ __live_component__
     __boundary__ __mix_task__ __sobelow__ __ex_unit__ __adapter__ __log__ __struct_fields__)a
  |> MapSet.new()

src_defines? = fn source, name ->
  n = Regex.escape(Atom.to_string(name))
  Regex.match?(~r/^\s*(def|defmacro|defdelegate|defguard)\s+#{n}(\s*\(|\s|$)/m, source)
end

for mod <- mods, Code.ensure_loaded?(mod) do
  attrs = mod.module_info(:attributes)
  protocol_impl? = Keyword.has_key?(attrs, :protocol_impl)
  source = mod.module_info(:compile)[:source] |> to_string() |> File.read!()
  behaviours = attrs |> Keyword.get_values(:behaviour) |> List.flatten()

  callbacks_of_behaviours =
    behaviours
    |> Enum.flat_map(fn b ->
      Code.ensure_loaded(b)
      if function_exported?(b, :behaviour_info, 1), do: b.behaviour_info(:callbacks), else: []
    end)
    |> MapSet.new()

  {moduledoc, docs} =
    case Code.fetch_docs(mod) do
      {:docs_v1, _, :elixir, _, md, _, ds} -> {md, ds}
      _ -> {:no_chunk, []}
    end

  md_state = case moduledoc do %{} -> :present; other -> other end
  doc_index = for {{k, n, a}, _, _, d, m} <- docs, into: %{}, do: {{k, n, a}, {d, m}}

  covered_by_defaults = fn kind, n, a ->
    Enum.find_value(doc_index, fn
      {{^kind, ^n, a2}, {d, %{defaults: nd}}} when a2 > a and a2 - a <= nd ->
        case d do %{} -> :present; :hidden -> :hidden; _ -> nil end
      _ -> nil
    end)
  end

  doc_state = fn kind, n, a ->
    case Map.get(doc_index, {kind, n, a}) do
      {%{}, _} -> :present
      {:hidden, _} -> :hidden
      {:none, _} -> :none
      nil -> covered_by_defaults.(kind, n, a) || :none
    end
  end

