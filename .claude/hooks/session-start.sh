#!/usr/bin/env bash
# SessionStart hook for Cake — installs Erlang/Elixir, Rust, Postgres,
# fetches/compiles deps, and prepares the test database so that Claude
# Code on the web sessions can run `mix compile`, `mix credo`, `mix test`,
# and the full `mix precommit` chain immediately. It also installs the
# LawSpec toolchain (Erlang/OTP 29) beside Cake's own, reached through the
# `otp29` wrapper, so the `laws` job's steps run in lawspec/ (section 6).
#
# Web sessions run as root, so `$SUDO` is empty there. It is safe only as a
# command *prefix* (`$SUDO apt-get ...`); never write `$SUDO -u user cmd`,
# which degrades to `-u user cmd` and is not a command. Steps that must run
# as another OS user branch on `id -u` instead (see the Postgres section).
set -euo pipefail

# Only run in remote (Claude Code on the web) environments. Local
# dev uses docker-compose per the README.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  echo "Not a Claude Code on the web session; skipping setup."
  exit 0
fi

cd "${CLAUDE_PROJECT_DIR:-$(pwd)}"

SUDO=""
if [ "$(id -u)" -ne 0 ]; then SUDO="sudo"; fi

export DEBIAN_FRONTEND=noninteractive

# Elixir wants a UTF-8 locale; the base Ubuntu image is latin1.
export LANG="${LANG:-C.UTF-8}"
export LC_ALL="${LC_ALL:-C.UTF-8}"
export ELIXIR_ERL_OPTIONS="${ELIXIR_ERL_OPTIONS:-+fnu}"
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  {
    echo 'export LANG=C.UTF-8'
    echo 'export LC_ALL=C.UTF-8'
    echo 'export ELIXIR_ERL_OPTIONS=+fnu'
  } >> "$CLAUDE_ENV_FILE"
fi

###############################################################################
# 1. Erlang/OTP + Elixir (precompiled tarballs from builds.hex.pm).
#
# Ubuntu Noble's `erlang` apt package is OTP 25, which has a `:httpc` bug
# that emits an empty `te:` header — the egress proxy in front of Fastly
# rejects every such request with 503, so `mix deps.get` fails even when
# repo.hex.pm is allowlisted. The bug is fixed in OTP 26.2.5 / 27.0+, so
# we install a precompiled OTP tarball from builds.hex.pm (already
# allowlisted) instead of using apt. Ubuntu's `elixir` package is also
# too old for mix.exs (`~> 1.17`), so we drop a precompiled Elixir tarball
# into /opt/elixir.
###############################################################################
OTP_VERSION="${OTP_VERSION:-27.3.4.11}"
OTP_MIN_MAJOR="${OTP_MIN_MAJOR:-27}"
ELIXIR_VERSION="${ELIXIR_VERSION:-1.17.3}"

current_otp_major() {
  command -v erl >/dev/null 2>&1 || { echo 0; return; }
  erl -noshell -eval 'io:format("~s", [erlang:system_info(otp_release)]), halt().' 2>/dev/null \
    || echo 0
}

OTP_MAJOR_NOW="$(current_otp_major)"
if [ "${OTP_MAJOR_NOW}" -lt "${OTP_MIN_MAJOR}" ] 2>/dev/null; then
  # Apt's `erlang` package on Ubuntu Noble is OTP 25, which has the empty
  # `te:` header bug — the egress proxy rejects every request. The plain
  # `command -v erl` check is not enough: it sees apt's /usr/bin/erl and
  # short-circuits, so we must install OTP >= ${OTP_MIN_MAJOR} ourselves
  # whenever the active erl is older.
  echo "==> Active erl is OTP ${OTP_MAJOR_NOW:-none} (< ${OTP_MIN_MAJOR}); installing OTP ${OTP_VERSION}..."

  echo "==> Installing build deps..."
  # Tolerate failing third-party PPAs; we only need the main Ubuntu archive.
  $SUDO apt-get update -y || true
  $SUDO apt-get install -y --no-install-recommends \
    build-essential \
    libssl-dev \
    libncurses6 \
    inotify-tools \
    git \
    curl \
    unzip \
    ca-certificates

  echo "==> Installing Erlang/OTP ${OTP_VERSION} (precompiled from builds.hex.pm)..."
  $SUDO mkdir -p /opt/otp
  curl -fsSL \
    "https://builds.hex.pm/builds/otp/ubuntu-24.04/OTP-${OTP_VERSION}.tar.gz" \
    | $SUDO tar -xz -C /opt/otp --strip-components=1
  ( cd /opt/otp && $SUDO ./Install -minimal /opt/otp )
  for bin in erl erlc escript dialyzer ct_run epmd run_erl to_erl; do
    if [ -x "/opt/otp/bin/${bin}" ]; then
      # Force the symlink so we shadow apt's /usr/bin/erl on $PATH
      # (/usr/local/bin precedes /usr/bin).
      $SUDO ln -sf "/opt/otp/bin/${bin}" "/usr/local/bin/${bin}"
    fi
  done
  hash -r
fi

# Reinstall Elixir whenever it's missing or built against a different OTP
# major than the currently-active erl. Otherwise an OTP upgrade above
# would leave us with an Elixir compiled for the old OTP.
OTP_MAJOR="$(current_otp_major)"
elixir_otp_major() {
  command -v elixir >/dev/null 2>&1 || { echo ""; return; }
  elixir --version 2>/dev/null \
    | sed -n 's/.*compiled with Erlang\/OTP \([0-9]\+\).*/\1/p'
}
ELIXIR_OTP_MAJOR="$(elixir_otp_major)"

if ! command -v elixir >/dev/null 2>&1 \
  || ! command -v mix >/dev/null 2>&1 \
  || [ "${ELIXIR_OTP_MAJOR}" != "${OTP_MAJOR}" ]; then
  echo "==> Installing Elixir ${ELIXIR_VERSION} for OTP ${OTP_MAJOR}..."
  $SUDO mkdir -p /opt/elixir
  curl -fsSL \
    "https://github.com/elixir-lang/elixir/releases/download/v${ELIXIR_VERSION}/elixir-otp-${OTP_MAJOR}.zip" \
    -o /tmp/elixir.zip
  $SUDO unzip -oq /tmp/elixir.zip -d /opt/elixir
  for bin in elixir elixirc iex mix; do
    $SUDO ln -sf "/opt/elixir/bin/${bin}" "/usr/local/bin/${bin}"
  done
  hash -r
fi

echo "==> elixir: $(elixir --version | tail -1)"

###############################################################################
# 2. Rust toolchain (Rustler NIF in deps)
###############################################################################
if ! command -v cargo >/dev/null 2>&1; then
  echo "==> Installing Rust toolchain..."
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --default-toolchain stable --profile minimal --no-modify-path
fi

# Make cargo available for the rest of this script and for the session.
if [ -f "$HOME/.cargo/env" ]; then
  # shellcheck disable=SC1091
  . "$HOME/.cargo/env"
fi
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  echo "export PATH=\"$HOME/.cargo/bin:\$PATH\"" >> "$CLAUDE_ENV_FILE"
fi

echo "==> cargo: $(cargo --version)"

###############################################################################
# 3. PostgreSQL (config/{dev,test}.exs use postgres/postgres @ localhost:5432)
###############################################################################
if ! command -v psql >/dev/null 2>&1; then
  echo "==> Installing PostgreSQL..."
  $SUDO apt-get install -y --no-install-recommends postgresql postgresql-contrib
fi

if ! pg_isready -h localhost -p 5432 >/dev/null 2>&1; then
  echo "==> Starting PostgreSQL..."
  $SUDO service postgresql start || true
  for _ in $(seq 1 30); do
    pg_isready -h localhost -p 5432 >/dev/null 2>&1 && break
    sleep 1
  done
fi

# Set the password config/{dev,test}.exs expect. psql must run as the
# `postgres` OS user (peer auth over the local socket): `runuser` when we are
# already root, `sudo -u` otherwise. Don't discard a failure here — without
# the password the first `mix test` dies with FATAL 28P01 (invalid_password),
# far from the cause — but don't abort the hook on it either: the rest of the
# setup (deps, compile) is still worth having.
psql_as_postgres() {
  if [ "$(id -u)" -eq 0 ]; then
    runuser -u postgres -- psql "$@"
  else
    sudo -u postgres psql "$@"
  fi
}

if psql_as_postgres -v ON_ERROR_STOP=1 -q \
     -c "ALTER USER postgres WITH PASSWORD 'postgres';" \
   && PGPASSWORD=postgres psql -h localhost -p 5432 -U postgres -d postgres \
        -qAtc "SELECT 1" >/dev/null; then
  echo "==> postgres: password set; postgres/postgres@localhost:5432 login verified"
else
  cat <<'WARN'
!! postgres: could not set or verify the password for role "postgres".
   config/dev.exs and config/test.exs expect postgres/postgres@localhost:5432,
   so `mix test`, `mix precommit`, and `mix ecto.create` will fail with
   FATAL 28P01 (invalid_password) until it is set. Set it by hand with:
     runuser -u postgres -- psql -c "ALTER USER postgres WITH PASSWORD 'postgres';"
   (as root) or the same command via `sudo -u postgres`.
WARN
fi

echo "==> postgres: $(pg_isready -h localhost -p 5432 || true)"

###############################################################################
# 4. Hex / Rebar / Mix dependencies
###############################################################################
echo "==> Installing Hex and Rebar..."
# builds.hex.pm CDN is blocked in some sandboxes; use the GitHub fallback
# for Hex and a prebuilt rebar3 binary instead.
if ! mix local.hex --force --if-missing 2>/dev/null; then
  echo "    hex.pm CDN unreachable; installing Hex from GitHub..."
  mix archive.install github hexpm/hex branch latest --force
fi

if ! command -v rebar3 >/dev/null 2>&1; then
  echo "    Installing rebar3 from GitHub release..."
  curl -fsSL https://github.com/erlang/rebar3/releases/latest/download/rebar3 \
    -o /tmp/rebar3
  chmod +x /tmp/rebar3
  $SUDO mv /tmp/rebar3 /usr/local/bin/rebar3
fi
# Point mix at the system rebar3 so it doesn't try to download one.
mkdir -p "$HOME/.mix"
ln -sf "$(command -v rebar3)" "$HOME/.mix/rebar3"
mix local.rebar rebar3 "$(command -v rebar3)" --force >/dev/null 2>&1 || true

# Use the system CA bundle for Erlang's TLS stack.
export HEX_CACERTS_PATH="${HEX_CACERTS_PATH:-/etc/ssl/certs/ca-certificates.crt}"
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  echo "export HEX_CACERTS_PATH=${HEX_CACERTS_PATH}" >> "$CLAUDE_ENV_FILE"
fi

echo "==> Fetching Mix deps..."
if ! mix deps.get; then
  cat <<'WARN'
!! mix deps.get failed.
   Cake's deps are fetched from repo.hex.pm. If you are running in Claude Code
   on the web with the default network allowlist, that host is blocked
   (`x-deny-reason: host_not_allowed`) — Erlang, Elixir, Postgres, and Rust
   will be installed, but Mix cannot resolve packages until repo.hex.pm is
   reachable. Add repo.hex.pm and builds.hex.pm to the environment's egress
   allowlist, or commit deps/ into the repo, then re-run this hook.
WARN
  exit 0
fi

# Force NIF rebuild on first install (host artifacts may be stale).
rm -f priv/native/*.so 2>/dev/null || true

echo "==> Compiling deps..."
mix deps.compile

###############################################################################
# 5. Test database
###############################################################################
echo "==> Preparing test database..."
MIX_ENV=test mix ecto.create --quiet || true
MIX_ENV=test mix ecto.migrate --quiet || true

###############################################################################
# 6. LawSpec toolchain (lawspec/README.md, "Running locally")
#
# lawspec/ is its own Mix project and needs Erlang/OTP 29, which Cake does
# not run on. Its toolchain goes in /opt/lawspec, beside Cake's and never on
# PATH, with a Mix home of its own: `mix local.hex --force` under OTP 29
# would otherwise replace the Hex archive Cake's toolchain loads. The `otp29`
# wrapper runs one command with that toolchain:
#
#   cd lawspec && otp29 npm run check && otp29 mix test
#
# Each install is skipped when it is already done, and each check is of
# something written only after its install succeeded, inside the directory
# the install fills, so an interrupted install or a deleted directory runs
# again. The toolchain is checked by a version marker; node_modules, deps and
# the compiled deps in _build/test by a hash of the files that decide what
# goes into them. A failure here is reported and does not fail the hook:
# everything Cake itself needs is ready by now.
###############################################################################
LAWSPEC_OTP_VERSION="${LAWSPEC_OTP_VERSION:-29.1.2}"
LAWSPEC_ELIXIR_VERSION="${LAWSPEC_ELIXIR_VERSION:-1.20.2}"
LAWSPEC_HOME=/opt/lawspec
LAWSPEC_WRAPPER=/usr/local/bin/otp29

# Called as an `if` condition, where `set -e` is off, so each step returns
# its own failure.
lawspec_toolchain() {
  local otp_major="${LAWSPEC_OTP_VERSION%%.*}"

  if [ ! -w "$LAWSPEC_HOME" ]; then
    $SUDO mkdir -p "$LAWSPEC_HOME" || return 1
    $SUDO chown "$(id -u):$(id -g)" "$LAWSPEC_HOME" || return 1
  fi

  # Not the tarball's own releases/*/OTP_VERSION: that file is unpacked
  # before ./Install has run, so it would pass for a half-installed runtime.
  if [ "$(cat "$LAWSPEC_HOME/otp/.session-start-version" 2>/dev/null)" \
       != "$LAWSPEC_OTP_VERSION" ]; then
    echo "==> lawspec: installing Erlang/OTP ${LAWSPEC_OTP_VERSION}..."
    rm -rf "$LAWSPEC_HOME/otp" && mkdir -p "$LAWSPEC_HOME/otp" || return 1
    curl -fsSL \
      "https://builds.hex.pm/builds/otp/ubuntu-24.04/OTP-${LAWSPEC_OTP_VERSION}.tar.gz" \
      | tar -xz -C "$LAWSPEC_HOME/otp" --strip-components=1 || return 1
    ( cd "$LAWSPEC_HOME/otp" && ./Install -minimal "$LAWSPEC_HOME/otp" >/dev/null ) || return 1
    echo "$LAWSPEC_OTP_VERSION" > "$LAWSPEC_HOME/otp/.session-start-version" || return 1
  fi

  if [ "$(cat "$LAWSPEC_HOME/elixir/VERSION" 2>/dev/null)" != "$LAWSPEC_ELIXIR_VERSION" ] \
     || [ "$(cat "$LAWSPEC_HOME/elixir/.otp-major" 2>/dev/null)" != "$otp_major" ]; then
    echo "==> lawspec: installing Elixir ${LAWSPEC_ELIXIR_VERSION} for OTP ${otp_major}..."
    rm -rf "$LAWSPEC_HOME/elixir" && mkdir -p "$LAWSPEC_HOME/elixir" || return 1
    curl -fsSL \
      "https://builds.hex.pm/builds/elixir/v${LAWSPEC_ELIXIR_VERSION}-otp-${otp_major}.zip" \
      -o "$LAWSPEC_HOME/elixir.zip" || return 1
    unzip -oq "$LAWSPEC_HOME/elixir.zip" -d "$LAWSPEC_HOME/elixir" || return 1
    rm -f "$LAWSPEC_HOME/elixir.zip"
    echo "$otp_major" > "$LAWSPEC_HOME/elixir/.otp-major" || return 1
  fi

  if ! grep -qsF "$LAWSPEC_HOME/otp/bin" "$LAWSPEC_WRAPPER"; then
    $SUDO tee "$LAWSPEC_WRAPPER" >/dev/null <<WRAPPER || return 1
#!/usr/bin/env bash
# Runs one command with the LawSpec toolchain (Erlang/OTP 29), installed by
# .claude/hooks/session-start.sh: otp29 mix test, otp29 npm run check.
export PATH="$LAWSPEC_HOME/elixir/bin:$LAWSPEC_HOME/otp/bin:\$PATH"
export MIX_HOME="$LAWSPEC_HOME/mix"
exec "\$@"
WRAPPER
    $SUDO chmod +x "$LAWSPEC_WRAPPER" || return 1
  fi

  # Hex and rebar3 for this Mix home; rebar3 itself was installed in section 4.
  if ! ls "$LAWSPEC_HOME"/mix/archives/hex-* >/dev/null 2>&1; then
    otp29 mix local.hex --force >/dev/null 2>&1 \
      || otp29 mix archive.install github hexpm/hex branch latest --force >/dev/null \
      || return 1
  fi
  if ! ls "$LAWSPEC_HOME"/mix/elixir/*/rebar3 >/dev/null 2>&1; then
    otp29 mix local.rebar rebar3 "$(command -v rebar3)" --force >/dev/null || return 1
  fi
}

# LawSpec itself (npm) and the Mix deps, compiled for the test env, which is
# where LawSpec's doctor looks for them. Fetching fills deps/ and compiling
# fills _build/test, so each has a hash of its own: `rm -rf _build` must
# bring the compile back without a fetch.
lawspec_deps() {
  local hook="$PWD/.claude/hooks/session-start.sh" hashes

  cd lawspec || return 1

  hashes=node_modules/.session-start.sha256
  if ! sha256sum --check --status "$hashes" 2>/dev/null; then
    rm -f "$hashes"
    echo "==> lawspec: installing LawSpec (npm ci)..."
    npm ci --no-audit --no-fund >/dev/null || return 1
    sha256sum "$hook" package.json package-lock.json > "$hashes" || { rm -f "$hashes"; return 1; }
  fi

  # The logs are shown on failure only: dependency warnings are not ours to
  # fix.
  hashes=deps/.session-start.sha256
  if ! sha256sum --check --status "$hashes" 2>/dev/null; then
    # What is fetched anew is compiled anew.
    rm -f "$hashes" _build/test/.session-start.sha256
    echo "==> lawspec: fetching Mix deps..."
    otp29 mix deps.get > "$LAWSPEC_HOME/deps.log" 2>&1 \
      || { tail -n 20 "$LAWSPEC_HOME/deps.log"; return 1; }
    sha256sum "$hook" mix.exs mix.lock > "$hashes" || { rm -f "$hashes"; return 1; }
  fi

  hashes=_build/test/.session-start.sha256
  if ! sha256sum --check --status "$hashes" 2>/dev/null; then
    rm -f "$hashes"
    echo "==> lawspec: compiling Mix deps..."
    MIX_ENV=test otp29 mix deps.compile > "$LAWSPEC_HOME/compile.log" 2>&1 \
      || { tail -n 20 "$LAWSPEC_HOME/compile.log"; return 1; }
    sha256sum "$hook" mix.exs mix.lock > "$hashes" || { rm -f "$hashes"; return 1; }
  fi
}

if [ -d lawspec ]; then
  # The last condition runs the toolchain, so one that is installed but does
  # not start is reported too.
  if lawspec_toolchain && ( lawspec_deps ) \
     && lawspec_elixir="$(ERL_CRASH_DUMP=/dev/null otp29 elixir --version 2>/dev/null | tail -n 1)" \
     && [ -n "$lawspec_elixir" ]; then
    echo "==> lawspec: ${lawspec_elixir}; run its commands as \`otp29 <command>\` in lawspec/"
  else
    cat <<'WARN'
!! lawspec: could not install the LawSpec toolchain (Erlang/OTP 29) or the
   dependencies of lawspec/. Cake's own setup is unaffected. The `laws` job's
   steps will not run until it is installed: see section 6 of
   .claude/hooks/session-start.sh, and lawspec/README.md, "Running locally".
WARN
  fi
fi

echo "==> Cake remote setup complete."
