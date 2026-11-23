---
paths:
  - "ci/**"
  - "docker-compose*.yml"
  - "Dockerfile"
  - "Dockerfile.release"
  - "Dockerfile.release.dockerignore"
  - "rel/**"
  - "lib/cake/release.ex"
  - "entrypoint.sh"
  - ".env.ci"
  - "native/**"
  - "priv/native/**"
  - "lib/cake/parse_books.ex"
  - "lib/cake/books/pdf/**"
  - "lib/mix/tasks/cake.nif.check.ex"
---

# Infrastructure Gotchas

Auto-loaded when working on the Docker stack (the dev image and the release image), the release's overlays and `Cake.Release`, or the `parsebooks` NIF and its Elixir wrappers, so the NIF-clobbering warning reaches NIF work too.

Dev runs three containers via `docker-compose.yml`: `cake_app`, `cake_db` (Postgres 14), `cake_opensearch`.

- **NIF clobbering.** The `.:/app` bind mount overlays macOS binaries onto the Linux container. `entrypoint.sh` forces recompilation in sequence: `rm -f priv/native/*.so` → `mix deps.compile --force bcrypt_elixir` → `mix compile --force`. Diagnostic for this failure: "module not available" — not `:nif_not_loaded`. `mix cake.nif.check PATH` reproduces it on demand (it extracts a PDF through the NIF without starting the app), and the compose smoke gate runs it inside the app container on every PR.
- **Two images.** `Dockerfile` is the dev image (the compose stack above; gated by `ci/compose_smoke.sh`). `Dockerfile.release` is the release image, the one that is deployed (README "Deployment"; gated by `ci/release_smoke.sh`, the `release-image` job). They share nothing but the base image tags, which move together with `.tool-versions` and `quality.yml`. An edit to one is not an edit to the other.
- **The release image's build context.** `Dockerfile.release.dockerignore`, not `.dockerignore`: BuildKit prefers `<Dockerfile>.dockerignore`. A builder that does not (flyctl's non-BuildKit path reads `.dockerignore` unless `ignorefile` names another) would send `test/` and `priv/repo/seeds.exs` (`.dockerignore` happens to exclude `priv/native` too, but that is the dev image's file and can change). The Dockerfile removes `priv/native` and the seeds itself before compiling, so neither a host-built NIF nor the seeds reach the image either way. Keep that `rm` when editing: `ci/release_smoke.sh` plants a marker file in `priv/native` before building and fails if it reaches the release.
- **The release image has no Rust, no Mix and no `test/`.** The NIF is compiled in the builder stage (`native/` is copied in; Rust is installed there) and travels inside the release at `lib/cake-<vsn>/priv/native/parsebooks.so`. `mix cake.nif.check` does not exist in a release; `ci/release_smoke.sh` does the same through `bin/cake eval` with the fixture mounted.
- **`bin/cake eval` evaluates `config/runtime.exs`.** Every one-shot command in the release (`bin/migrate` included) raises unless the variables the prod block demands are set (`DATABASE_URL`, `SECRET_KEY_BASE`, `OPENAI_KEY`, `BOOK_STORAGE_S3_BUCKET`), whether or not the command uses them. `ci/release_smoke.sh` passes placeholders.
- **Colima FD limits.** Default 1024 is too low for concurrent `Task.async_stream` fan-out. Raise via provision script.
- **Colima port forwarder leak.** `limactl` accumulates CLOSED socket FDs. Fix: `colima start --network-address`.
- **Colima port forwarder saturation.** `portForwarder: ssh` saturates under burst traffic. Use `grpc`.
- **Bind mount hot paths.** Heavy virtiofs I/O through the mount is slow. Copy to `/tmp` inside the container on hot paths.
