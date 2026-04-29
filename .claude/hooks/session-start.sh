#!/usr/bin/env bash
# SessionStart hook for Cake — installs Erlang/Elixir, Rust, Postgres,
# fetches/compiles deps, and prepares the test database so that Claude
# Code on the web sessions can run `mix compile`, `mix credo`, and
# `mix test` immediately.
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
ELIXIR_VERSION="${ELIXIR_VERSION:-1.17.3}"

if ! command -v erl >/dev/null 2>&1; then
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
      $SUDO ln -sf "/opt/otp/bin/${bin}" "/usr/local/bin/${bin}"
    fi
  done
fi

if ! command -v elixir >/dev/null 2>&1 || ! command -v mix >/dev/null 2>&1; then
  OTP_MAJOR=$(erl -noshell -eval 'io:format("~s", [erlang:system_info(otp_release)]), halt().')
  echo "==> Detected OTP ${OTP_MAJOR}; installing Elixir ${ELIXIR_VERSION}..."
  $SUDO mkdir -p /opt/elixir
  curl -fsSL \
    "https://github.com/elixir-lang/elixir/releases/download/v${ELIXIR_VERSION}/elixir-otp-${OTP_MAJOR}.zip" \
    -o /tmp/elixir.zip
  $SUDO unzip -oq /tmp/elixir.zip -d /opt/elixir
  for bin in elixir elixirc iex mix; do
    $SUDO ln -sf "/opt/elixir/bin/${bin}" "/usr/local/bin/${bin}"
  done
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

# Set the password the app expects.
$SUDO -u postgres psql -v ON_ERROR_STOP=1 \
  -c "ALTER USER postgres WITH PASSWORD 'postgres';" >/dev/null 2>&1 || true

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

echo "==> Cake remote setup complete."
