---
paths:
  - "ci/**"
  - "docker-compose*.yml"
  - "Dockerfile"
  - "entrypoint.sh"
  - ".env.ci"
---

# Compose smoke test (merge gate)

Auto-loaded when working on the smoke script, the compose files, the `Dockerfile`, `entrypoint.sh` or `.env.ci`.

The `compose-smoke` job in `quality.yml` runs `ci/compose_smoke.sh` on every PR. Where the ExUnit jobs gate the code inside service containers, this gates the containers themselves (#250): Phoenix runs `server: false` in test, so `Cake.Application`'s supervision order and `Cake.Search.Deployment`'s boot-time collection creation run nowhere else in CI, and the NIF-clobbering recompile sequence lives in `entrypoint.sh` (CLAUDE.md "Infrastructure Gotchas"), where only a broken dev container ever surfaced a regression. The script builds the image from the `Dockerfile`, starts `db` and `opensearch`, waits on their health checks with a bounded timeout, starts the app through `entrypoint.sh` only then (the entrypoint waits for OpenSearch itself but not for Postgres), and asserts, in order: HTTP 200 from the app through the published port; both collections (`chunks_of_books`, `docs`) exist in OpenSearch, proving `Deployment` boot ran; every migration under `priv/repo/migrations` is in `schema_migrations`; and a one-shot `mix cake.nif.check test/support/fixtures/pdfs/multi_page.pdf` inside the app container extracts the fixture through `Cake.ParseBooks.extract_pdf/1`, proving the recompile produced a loadable Linux `.so`. That last check is only meaningful because the script first overwrites `priv/native/parsebooks.so` with a stale file in the created, not yet started, app container: the image's own build already carries a valid NIF, which would pass the check even with the recompile sequence deleted from `entrypoint.sh`, so the planted file reproduces the dev bind mount's unloadable host `.so` and only a rebuild at boot can replace it. It tears the stack down with `docker compose down -v` on every exit path, printing the container logs first on failure. The stack under test is the checked-in topology: `docker-compose.yml` unchanged, layered with `docker-compose.ci.yml` (no dev bind mount, so the image runs as built; no `db`/`opensearch` host ports, both are queried through `docker compose exec`; OpenSearch pinned to the release the `integration` job pins; smoke-specific container names) and interpolated from `.env.ci` (checked in and secret-free: `UID`/`GID` for the Dockerfile's `useradd`, the trust-authenticated `CAKE_PG*` role, an `OPENSEARCH_INITIAL_ADMIN_PASSWORD` that only has to pass the image's strength check because the security plugin is disabled, and a placeholder `OPENAI_KEY` — the app boots without a real one, and this is the proof). As it grows, the script is the executable record of the deployment topology, the seed for the staging environment #244 anticipates. Locally, with Docker running and no dev stack up (both publish the app on 4000):

```bash
ci/compose_smoke.sh               # a few minutes on a runner (the image build dominates; entrypoint.sh's recompile reuses the image's _build), longer on a laptop
SMOKE_KEEP=1 ci/compose_smoke.sh  # leave the stack up afterwards; every SMOKE_* knob is documented in the script
```

It runs under its own compose project (`cake-smoke`), so its `down -v` never touches the dev stack's volumes. A failure here is a finding about the containers, not the code: fix `Dockerfile`, `entrypoint.sh` or the compose files, never loosen an assertion, and stop and ask when what broke is the boot path itself.
