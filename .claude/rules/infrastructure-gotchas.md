---
paths:
  - "ci/**"
  - "docker-compose*.yml"
  - "Dockerfile"
  - "fly/**"
  - "entrypoint.sh"
  - ".env.ci"
  - "native/**"
  - "priv/native/**"
  - "lib/cake/parse_books.ex"
  - "lib/cake/books/pdf/**"
  - "lib/mix/tasks/cake.nif.check.ex"
---

# Infrastructure Gotchas

Auto-loaded when working on the Docker stack or the `parsebooks` NIF and its Elixir wrappers, so the NIF-clobbering warning reaches NIF work too.

Dev runs three containers via `docker-compose.yml`: `cake_app`, `cake_db` (Postgres 14), `cake_opensearch`.

- **NIF clobbering.** The `.:/app` bind mount overlays macOS binaries onto the Linux container. `entrypoint.sh` forces recompilation in sequence: `rm -f priv/native/*.so` → `mix deps.compile --force bcrypt_elixir` → `mix compile --force`. Diagnostic for this failure: "module not available" — not `:nif_not_loaded`. `mix cake.nif.check PATH` reproduces it on demand (it extracts a PDF through the NIF without starting the app), and the compose smoke gate runs it inside the app container on every PR.
- **Colima FD limits.** Default 1024 is too low for concurrent `Task.async_stream` fan-out. Raise via provision script.
- **Colima port forwarder leak.** `limactl` accumulates CLOSED socket FDs. Fix: `colima start --network-address`.
- **Colima port forwarder saturation.** `portForwarder: ssh` saturates under burst traffic. Use `grpc`.
- **Bind mount hot paths.** Heavy virtiofs I/O through the mount is slow. Copy to `/tmp` inside the container on hot paths.

Staging runs on Fly (#360); each app's directory under `fly/` holds its `fly.toml` and a README that is its runbook. For the search node (`fly/search/`, #364), all seen in a local container unless marked:

- **A volume mounts root-owned; the OpenSearch image runs as uid 1000 and refuses root.** `fly/search/entrypoint.sh` starts as root, chowns the mount root and drops to uid 1000 with `chroot --userspec` (the image has no `su`, `setpriv` or `gosu`). Deploying the stock image against a volume fails with `AccessDeniedException: .../data/nodes`.
- **A failed OpenSearch start does not exit.** The exception is logged and the process stays alive, so the machine reads "started". Read `fly checks list`, not the machine state.
- **Heap is 1 GB unless `OPENSEARCH_JAVA_OPTS` says otherwise**, whatever the machine's memory. Keep it at half of `[[vm]] memory`; k-NN graphs are off-heap (about 6 KB per 1536-dimension chunk).
- **No service section is what keeps the node private and always on.** Never add `[http_service]` or `[[services]]` to `fly/search/fly.toml` or `fly/db/fly.toml` (Fly docs, not yet verified on the live app).
- **The image tag is pinned in three places:** `fly/search/Dockerfile`, `quality.yml` and `docker-compose.ci.yml`.
