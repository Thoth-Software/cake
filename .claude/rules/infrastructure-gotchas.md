---
paths:
  - "ci/**"
  - "docker-compose*.yml"
  - "Dockerfile"
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
