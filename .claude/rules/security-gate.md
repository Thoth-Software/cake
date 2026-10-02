---
paths:
  - "lib/cake_web/**"
  - "lib/cake_web.ex"
  - ".sobelow-conf"
  - "config/**"
---

# Security gate

Auto-loaded when working on the web layer, `.sobelow-conf` or config, where Sobelow findings arise.

The `security` job: `mix deps.unlock --check-unused` (blocking) plus `mix hex.audit` and `mix deps.audit` (**report-only** while the advisory backlog in #206 is outstanding; they flip to blocking once it clears), and `mix sobelow --config --exit` (blocking) — static security analysis of the Phoenix app. Its baseline is clean: triaged false-positives are suppressed in `.sobelow-conf` (`:ignore` for deployment-level Config findings, `:ignore_files` for internal file-I/O modules) and via inline `# sobelow_skip` annotations at request-facing call sites, so the gate fails only on **new** findings. When Sobelow flags new code, fix it or — if it's a verified false-positive — add a justified `# sobelow_skip` (never a blanket ignore).
