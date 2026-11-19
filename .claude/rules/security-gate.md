---
paths:
  - "lib/cake_web/**"
  - "lib/cake_web.ex"
  - ".sobelow-conf"
  - "config/**"
  - "mix.exs"
  - "mix.lock"
---

# Security gate

Auto-loaded when working on the web layer, `.sobelow-conf` or config, where Sobelow findings arise, and on `mix.exs` or `mix.lock`, where the dependency audits do.

The `security` job, every step blocking: `mix deps.unlock --check-unused`, `mix hex.audit` and `mix deps.audit` (the dependency audits, below), and `mix sobelow --config --exit` — static security analysis of the Phoenix app. Its baseline is clean: triaged false-positives are suppressed in `.sobelow-conf` (`:ignore` for deployment-level Config findings, `:ignore_files` for internal file-I/O modules) and via inline `# sobelow_skip` annotations at request-facing call sites, so the gate fails only on **new** findings. When Sobelow flags new code, fix it or — if it's a verified false-positive — add a justified `# sobelow_skip` (never a blanket ignore).

## Dependency audits

`mix hex.audit` fails on any retired package or any package under a security advisory; `mix deps.audit` checks the same lock against the mix_audit database, a second source that overlaps the first. Both have been at zero since #206 cleared the backlog, and nothing is ignored. So a red audit is a new advisory, and it turns every open PR red until it is fixed: the fix is a dependency bump, one commit per package group, with the advisory IDs in the message.

What a bump has to carry with it:

- **Its own dependencies.** `mix deps.update <pkg>` also moves the packages `<pkg>` depends on. Read the lock diff and name everything that moved.
- **Orphans.** A bump can leave an entry nothing requires any more. Run `mix deps.unlock --check-unused` before committing, and `mix deps.unlock --unused` if it fails.
- **`lawspec/`.** It pins the versions in Cake's lock for the packages it shares (`lawspec/README.md`, "Hex dependencies"). When one of them moves, or one of their dependencies does, move it there too and run the `laws` job's steps under OTP 29.
- **Finch and Req together.** Finch 0.22 introduced `Finch.TransportError`, which Req translates into `Req.TransportError` only from 0.5.18. An older Req over a newer Finch changes the error `Cake.Books.Adapters.S3` returns, and only the integration suite notices, because the unit suite stubs the transport.
- **The integration suite**, for anything in the database, HTTP or Phoenix stacks: `mix test --only integration --include network` (`.claude/rules/integration-tests.md`). Tests run the endpoint with `server: false`, so no suite sends a request through Bandit itself until #252's HTTP smoke exists; boot the server and load a LiveView by hand after a Bandit, Plug or Phoenix bump.

`req` is held at `~> 0.6.3` on purpose: 0.7 replaces the Finch and Plug steps with adapter modules and changes retry timing and query-param merging, which needs its own look at the OpenAI retry path before the constraint is widened.
