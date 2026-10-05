#!/usr/bin/env bash
# recv.fund installer.
#
# Writes a compose project (.env, docker-compose.yml, Caddyfile) under
# /opt/recvfund and starts it with the published images. Run with no flags
# for the operations menu, or pass --help for the flag list.
#
# Published as a GitHub release asset; the latest release is always at
#   https://github.com/recv-fund/recvfund-scripts/releases/latest/download/install.sh
# Works under
#   bash <(curl -fsSL https://github.com/recv-fund/recvfund-scripts/releases/latest/download/install.sh) [flags]
#   curl -fsSL https://github.com/recv-fund/recvfund-scripts/releases/latest/download/install.sh | sudo bash -s -- [flags]
# Prompts read from /dev/tty, never from stdin, so the pipe form is safe.

if [ -z "${BASH_VERSION:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "install.sh needs bash 4 or newer (found ${BASH_VERSION:-not bash})." >&2
  echo "On macOS: brew install bash, then run /opt/homebrew/bin/bash <(curl -fsSL https://github.com/recv-fund/recvfund-scripts/releases/latest/download/install.sh)" >&2
  exit 1
fi

set -euo pipefail

# The release workflow replaces "dev" with the installer's version in the
# published asset. Image versions are separate: every release of
# recvfund-server publishes a new X.Y.Z, and fresh installs and updates look up
# the newest one (latest_release) and write it to .env as IMAGE_TAG.
SCRIPT_VERSION="dev"
REGISTRY_REPO="recv-fund/recvfund"
INSTALL_URL="https://github.com/recv-fund/recvfund-scripts/releases/latest/download/install.sh"
PROJECT="recvfund"
DEFAULT_DIR="/opt/recvfund"
HEALTH_TIMEOUT=90
MIN_DISK_GB=5
RECOMMENDED_DISK_GB=10

# ---------------------------------------------------------------------------
# State (set by flags and prompts)
# ---------------------------------------------------------------------------
ACTION=""            # install | update | restart | reset | status
NETWORK=""           # mainnet | testnet
ASSUME_YES=0
DOMAIN=""
ACME_EMAIL=""
DB_MODE=""           # external | bundled
PG_HOST=""
PG_PORT=""
PG_DB=""
PG_USER=""
PG_PASSWORD=""
PG_SSL=""
SSL_MODE=""          # letsencrypt | http
HTTP_PORT=""
HTTP_PORT_SET=0
# Host address the plain-HTTP port is published on; empty means every interface.
HTTP_BIND=""
# --site-url: the public address in plain-HTTP mode, skipping the prompt.
SITE_URL_FLAG=""
IMAGE_TAG=""
DIR="$DEFAULT_DIR"
SOURCE=""
DRY_RUN="${RECV_DRY_RUN:-0}"

SITE_DOMAIN=""
SITE_URL=""
AES_KEY=""
ADMIN_KEY=""
REDIS_PASSWORD=""

OS_ID=""
OS_NAME=""
ARCH=""
LOG_FILE=""
DOCKER=(docker)
SUDO=""
TTY_OK=0
UPDATE_PHASE=""
CADDY_UPDATE_FILE=""

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_BLUE=$'\e[34m'
else
  C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""
fi

log_line() {
  [ -n "$LOG_FILE" ] || return 0
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE" 2>/dev/null || true
}
say()  { printf '%s\n' "$*"; log_line "$*"; }
info() { printf '%s==>%s %s\n' "$C_BLUE" "$C_RESET" "$*"; log_line "==> $*"; }
ok()   { printf '%s  ok%s  %s\n' "$C_GREEN" "$C_RESET" "$*"; log_line "ok: $*"; }
warn() { printf '%sWARNING:%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; log_line "WARNING: $*"; }
die()  { printf '%sERROR:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; log_line "ERROR: $*"; exit 1; }

on_exit() {
  local rc=$?
  if [ -n "$CADDY_UPDATE_FILE" ]; then rm -f -- "$CADDY_UPDATE_FILE"; fi
  if [ "$rc" -ne 0 ] && [ "$UPDATE_PHASE" = migration ]; then
    printf 'Update stopped during migration. Application services remain stopped. The installed image tag is unchanged, but completed migrations may have changed the database. Restore the paired pre-update database/configuration backup or resolve the migration before starting services.\n' >&2
  fi
  if [ "$rc" -ne 0 ] && [ -n "$LOG_FILE" ]; then
    printf 'The log is in %s\n' "$LOG_FILE" >&2
  fi
}
trap on_exit EXIT

usage() {
  cat <<EOF
recv.fund installer v${SCRIPT_VERSION}

Usage: install.sh [operation] [options]

Operations (no operation shows a menu):
  --mainnet             Fresh install on mainnet
  --testnet             Fresh install on testnet (recommended for a first install)
  --update              Move to the newest released version, run migrations, restart
  --restart             Restart the services without touching data
  --reset               Remove containers, images, volumes and the install directory
  --status              Show container status and the health endpoint

Options:
  --yes                 Accept every default; no prompts
  --domain <host>       Domain for Let's Encrypt (implies HTTPS)
  --email <address>     Email for the Let's Encrypt account
  --external-db         Use an external Postgres (prompts unless --pg-* are given)
  --pg-host <host>      External Postgres host
  --pg-port <port>      External Postgres port (default 5432)
  --pg-db <name>        External Postgres database (default recv)
  --pg-user <user>      External Postgres user (default recv)
  --pg-password <pw>    External Postgres password (visible in the process list; prefer the prompt)
  --pg-ssl              Connect to the external Postgres with SSL
  --http-port <n>       Serve plain HTTP on this host port (behind your own proxy)
  --http-bind <ip>      Publish that port on this address only, for example 127.0.0.1
                        when the proxy runs on the same server (default: every address)
  --site-url <url>      Public address in plain-HTTP mode, for example https://pay.example.com
                        (default: prompt, suggesting http://<public ip>[:port])
  --image-tag <tag>     Image version to run (default: the newest released X.Y.Z)
  --dir <path>          Install directory (default ${DEFAULT_DIR})
  --source <path>       Build the images from a local recvfund-server checkout instead of pulling
  -h, --help            Show this help
  --version             Print the script version

Environment:
  RECV_DRY_RUN=1        Print docker commands instead of running them
  NO_COLOR=1            Disable coloured output
EOF
}

# ---------------------------------------------------------------------------
# Prompts. All reads come from /dev/tty so the script works when stdin is
# the script itself (curl | bash).
# ---------------------------------------------------------------------------
if { : < /dev/tty; } 2>/dev/null; then
  TTY_OK=1
fi

require_tty() {
  [ "$TTY_OK" = 1 ] || die "No terminal is available for prompts. Re-run with --yes and the flags for the values you need."
}

# ask VAR "Prompt" "default"
ask() {
  local var="$1" prompt="$2" default="${3:-}" reply=""
  if [ "$ASSUME_YES" = 1 ]; then
    say "${prompt} [${default}]: ${default}"
    printf -v "$var" '%s' "$default"
    return 0
  fi
  require_tty
  printf '%s [%s]: ' "$prompt" "$default" > /dev/tty
  IFS= read -r reply < /dev/tty || true
  [ -n "$reply" ] || reply="$default"
  printf -v "$var" '%s' "$reply"
  log_line "${prompt}: ${reply}"
}

# ask_secret VAR "Prompt" — no echo, no default, never logged.
ask_secret() {
  local var="$1" prompt="$2" reply=""
  if [ "$ASSUME_YES" = 1 ]; then
    die "${prompt}: a value is required; pass it with the matching flag when using --yes."
  fi
  require_tty
  while [ -z "$reply" ]; do
    printf '%s: ' "$prompt" > /dev/tty
    IFS= read -rs reply < /dev/tty || true
    printf '\n' > /dev/tty
  done
  printf -v "$var" '%s' "$reply"
}

# confirm "Question" y|n  -> exit status 0 for yes
confirm() {
  local prompt="$1" default="${2:-n}" reply=""
  local shown="y/N"
  [ "$default" = y ] && shown="Y/n"
  if [ "$ASSUME_YES" = 1 ]; then
    say "${prompt} [${shown}]: ${default}"
    [ "$default" = y ]
    return
  fi
  require_tty
  printf '%s [%s]: ' "$prompt" "$shown" > /dev/tty
  IFS= read -r reply < /dev/tty || true
  [ -n "$reply" ] || reply="$default"
  log_line "${prompt}: ${reply}"
  case "$reply" in y|Y|yes|YES|Yes) return 0 ;; *) return 1 ;; esac
}

# ---------------------------------------------------------------------------
# Privilege and command wrappers
# ---------------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
fi

as_root() {
  if [ -n "$SUDO" ]; then
    "$SUDO" "$@"
  else
    "$@"
  fi
}

docker_cmd() {
  if [ "$DRY_RUN" = 1 ]; then
    say "[dry-run] ${DOCKER[*]} $*"
    return 0
  fi
  log_line "+ ${DOCKER[*]} $*"
  if [ -n "$LOG_FILE" ]; then
    "${DOCKER[@]}" "$@" 2>&1 | tee -a "$LOG_FILE"
  else
    "${DOCKER[@]}" "$@"
  fi
}

# Like docker_cmd but discards output; used for checks.
docker_quiet() {
  if [ "$DRY_RUN" = 1 ]; then
    say "[dry-run] ${DOCKER[*]} $*"
    return 0
  fi
  log_line "+ ${DOCKER[*]} $*"
  "${DOCKER[@]}" "$@" >/dev/null 2>&1
}

compose() {
  local args=(compose -p "$PROJECT" --env-file "$DIR/.env" -f "$DIR/docker-compose.yml")
  if [ -f "$DIR/docker-compose.build.yml" ]; then
    args+=(-f "$DIR/docker-compose.build.yml")
  fi
  if [ "$DB_MODE" = bundled ]; then
    args+=(--profile db)
  fi
  docker_cmd "${args[@]}" "$@"
}

# ---------------------------------------------------------------------------
# Flag parsing
# ---------------------------------------------------------------------------
need_arg() {
  if [ $# -lt 2 ] || [ -z "$2" ]; then die "$1 needs a value (see --help)"; fi
}

set_action() {
  [ -z "$ACTION" ] || [ "$ACTION" = "$1" ] || die "Only one of --mainnet, --testnet, --update, --restart, --reset, --status can be given."
  ACTION="$1"
}

parse_args() {
while [ $# -gt 0 ]; do
  arg="$1"
  val=""
  case "$arg" in
    --*=*) val="${arg#*=}"; arg="${arg%%=*}" ;;
  esac
  case "$arg" in
    --mainnet) set_action install; NETWORK=mainnet ;;
    --testnet) set_action install; NETWORK=testnet ;;
    --update)  set_action update ;;
    --restart) set_action restart ;;
    --reset)   set_action reset ;;
    --status)  set_action status ;;
    --yes|-y)  ASSUME_YES=1 ;;
    --external-db) DB_MODE=external ;;
    --pg-ssl)  PG_SSL=true ;;
    --domain|--email|--pg-host|--pg-port|--pg-db|--pg-user|--pg-password|--http-port|--http-bind|--site-url|--image-tag|--dir|--source)
      if [ -z "$val" ]; then
        need_arg "$arg" "${2:-}"
        val="$2"
        shift
      fi
      case "$arg" in
        --domain)      DOMAIN="$val" ;;
        --email)       ACME_EMAIL="$val" ;;
        --pg-host)     PG_HOST="$val"; DB_MODE=external ;;
        --pg-port)     PG_PORT="$val"; DB_MODE=external ;;
        --pg-db)       PG_DB="$val"; DB_MODE=external ;;
        --pg-user)     PG_USER="$val"; DB_MODE=external ;;
        --pg-password) PG_PASSWORD="$val"; DB_MODE=external ;;
        --http-port)   HTTP_PORT="$val"; HTTP_PORT_SET=1 ;;
        --http-bind)   HTTP_BIND="$val" ;;
        --site-url)    SITE_URL_FLAG="${val%/}" ;;
        --image-tag)   IMAGE_TAG="$val" ;;
        --dir)         DIR="$val" ;;
        --source)      SOURCE="$val" ;;
      esac
      ;;
    -h|--help) usage; exit 0 ;;
    --version) echo "$SCRIPT_VERSION"; exit 0 ;;
    *) die "Unknown flag: $1 (see --help)" ;;
  esac
  shift
done

case "$DIR" in
  /*) ;;
  *) die "--dir must be an absolute path (got '$DIR')" ;;
esac
DIR="${DIR%/}"

if [ -n "$DOMAIN" ] && [ "$HTTP_PORT_SET" = 1 ]; then
  die "--domain and --http-port cannot be combined. Let's Encrypt needs ports 80 and 443."
fi
if [ "$HTTP_PORT_SET" = 1 ]; then
  case "$HTTP_PORT" in
    ''|*[!0-9]*) die "--http-port must be a number" ;;
  esac
  if [ "$HTTP_PORT" -lt 1 ] || [ "$HTTP_PORT" -gt 65535 ]; then die "--http-port must be between 1 and 65535"; fi
fi
if [ -n "$SITE_URL_FLAG" ]; then
  [ -z "$DOMAIN" ] || die "--site-url applies to plain HTTP only; with --domain the site URL is https://<domain>."
  case "$SITE_URL_FLAG" in
    http://*|https://*) ;;
    *) die "--site-url must start with http:// or https://" ;;
  esac
fi
if [ -n "$HTTP_BIND" ]; then
  [ -z "$DOMAIN" ] || die "--http-bind applies to plain HTTP only and cannot be combined with --domain."
  [[ "$HTTP_BIND" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "--http-bind must be an IPv4 address, for example 127.0.0.1"
fi
if [ -n "$SOURCE" ]; then
  SOURCE="${SOURCE%/}"
  if [ ! -f "$SOURCE/apps/api/Dockerfile" ] || [ ! -f "$SOURCE/apps/web/Dockerfile" ]; then
    die "--source must point at a recvfund-server checkout (apps/api/Dockerfile and apps/web/Dockerfile not found under '$SOURCE')"
  fi
  case "$SOURCE" in
    /*) ;;
    *) SOURCE="$(cd "$SOURCE" && pwd)" ;;
  esac
fi

}

# ---------------------------------------------------------------------------
# Environment checks
# ---------------------------------------------------------------------------
banner() {
  printf '%s\n' "${C_BOLD}recv.fund installer v${SCRIPT_VERSION}${C_RESET}"
  printf '%s\n\n' "Self-hosted stablecoin payment server"
}

detect_os() {
  local kernel raw supported id match=0
  kernel="$(uname -s)"
  raw="$(uname -m)"
  case "$raw" in
    x86_64|amd64) ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) die "Unsupported CPU architecture: $raw. Images are published for amd64 and arm64." ;;
  esac
  case "$kernel" in
    Darwin)
      OS_ID=macos
      OS_NAME="macOS $(sw_vers -productVersion 2>/dev/null || true)"
      ;;
    Linux)
      [ -r /etc/os-release ] || die "Cannot detect the Linux distribution: /etc/os-release is missing."
      # shellcheck disable=SC1091
      OS_ID="$(. /etc/os-release && printf '%s' "${ID:-}")"
      # shellcheck disable=SC1091
      OS_NAME="$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-$ID}")"
      supported=" ubuntu debian linuxmint centos rhel rocky almalinux fedora arch alpine "
      # shellcheck disable=SC1091
      for id in $OS_ID $(. /etc/os-release && printf '%s' "${ID_LIKE:-}"); do
        case "$supported" in *" $id "*) match=1 ;; esac
      done
      [ "$match" = 1 ] || die "Unsupported Linux distribution: $OS_NAME. Supported: Ubuntu, Debian, Linux Mint, CentOS, RHEL, Rocky Linux, AlmaLinux, Fedora, Arch Linux, Alpine Linux."
      ;;
    *) die "Unsupported operating system: $kernel" ;;
  esac
  ok "Detected $OS_NAME ($ARCH)"
  if [ "$OS_ID" = macos ]; then
    warn "macOS is supported for local testing only, over plain HTTP."
  fi
}

port_in_use() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk 'NR>1 {print $4}' | grep -Eq "[:.]${port}\$"
  elif command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
  elif command -v netstat >/dev/null 2>&1; then
    netstat -an 2>/dev/null | grep LISTEN | awk '{print $4}' | grep -Eq "[:.]${port}\$"
  else
    return 1
  fi
}

check_ports() {
  local port
  for port in "$@"; do
    if port_in_use "$port"; then
      if [ "$DRY_RUN" = 1 ]; then
        warn "Port $port is in use (ignored in dry-run mode)."
      else
        die "Port $port is in use. Stop the service that listens on it, or use --http-port to serve behind your own proxy."
      fi
    else
      ok "Port $port is free"
    fi
  done
}

check_disk() {
  local parent="$DIR" avail_kb avail_gb
  while [ ! -d "$parent" ]; do parent="$(dirname "$parent")"; done
  avail_kb="$(df -Pk "$parent" | awk 'NR==2 {print $4}')"
  avail_gb=$(( avail_kb / 1024 / 1024 ))
  if [ "$avail_gb" -lt "$MIN_DISK_GB" ]; then
    warn "Only ${avail_gb} GB free on the filesystem holding $DIR; at least ${MIN_DISK_GB} GB is required and ${RECOMMENDED_DISK_GB} GB recommended."
    confirm "Continue anyway?" n || die "Not enough disk space."
  elif [ "$avail_gb" -lt "$RECOMMENDED_DISK_GB" ]; then
    warn "${avail_gb} GB free on the filesystem holding $DIR; ${RECOMMENDED_DISK_GB} GB or more is recommended."
  else
    ok "${avail_gb} GB free on the filesystem holding $DIR"
  fi
}

install_docker() {
  if [ "$OS_ID" = macos ]; then
    die "Docker is not installed. Install Docker Desktop (https://docs.docker.com/desktop/setup/install/mac-install/) and re-run."
  fi
  confirm "Docker is not installed. Install it now?" y || die "Docker is required."
  info "Installing Docker"
  case "$OS_ID" in
    alpine)
      as_root apk add --no-cache docker docker-cli-compose
      as_root rc-update add docker default
      as_root service docker start
      ;;
    arch)
      as_root pacman -Sy --noconfirm docker docker-compose
      as_root systemctl enable --now docker
      ;;
    *)
      curl -fsSL https://get.docker.com | as_root sh
      if command -v systemctl >/dev/null 2>&1; then
        as_root systemctl enable --now docker
      fi
      ;;
  esac
}

ensure_docker() {
  local ver major
  if ! command -v docker >/dev/null 2>&1; then
    if [ "$DRY_RUN" = 1 ]; then
      warn "Docker is not installed (ignored in dry-run mode)."
      return 0
    fi
    install_docker
  fi
  if [ "$DRY_RUN" = 1 ]; then
    ok "Docker found (daemon not checked in dry-run mode)"
    return 0
  fi
  if docker info >/dev/null 2>&1; then
    DOCKER=(docker)
  elif [ -n "$SUDO" ] && "$SUDO" docker info >/dev/null 2>&1; then
    DOCKER=("$SUDO" docker)
    say "Using sudo for docker commands (the current user is not in the docker group)."
  else
    die "Docker is installed but the daemon is not reachable. Start it (systemctl start docker) and re-run."
  fi
  "${DOCKER[@]}" compose version >/dev/null 2>&1 \
    || die "'docker compose' (v2 plugin) is not available. Install the docker-compose-plugin package and re-run."
  ver="$("${DOCKER[@]}" compose version --short 2>/dev/null || echo 0)"
  major="${ver#v}"; major="${major%%.*}"
  [ "$major" -ge 2 ] 2>/dev/null || die "docker compose v2 is required (found $ver)."
  ok "Docker $("${DOCKER[@]}" version --format '{{.Server.Version}}' 2>/dev/null || echo '?'), compose $ver"
}

require_tools() {
  local t
  for t in curl openssl; do
    command -v "$t" >/dev/null 2>&1 || die "$t is required but not installed."
  done
}

public_ip() {
  [ "$DRY_RUN" = 1 ] && return 0
  curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true
}

resolve_host() {
  if command -v getent >/dev/null 2>&1; then
    getent ahosts "$1" 2>/dev/null | awk '{print $1}' | sort -u
  elif command -v dig >/dev/null 2>&1; then
    dig +short A "$1" 2>/dev/null
  elif command -v host >/dev/null 2>&1; then
    host -t A "$1" 2>/dev/null | awk '/has address/ {print $NF}'
  fi
}

valid_domain() {
  printf '%s' "$1" | grep -Eq '^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'
}

valid_port() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

# ---------------------------------------------------------------------------
# Install directory and .env access
# ---------------------------------------------------------------------------
ensure_dir() {
  if [ -d "$DIR" ]; then
    [ -w "$DIR" ] || die "$DIR exists but is not writable by $(id -un). Run as root: curl -fsSL $INSTALL_URL | sudo bash -s -- <flags>"
  else
    if ! mkdir -p "$DIR" 2>/dev/null; then
      [ -n "$SUDO" ] || die "Cannot create $DIR. Run as root or choose another --dir."
      as_root mkdir -p "$DIR"
      as_root chown "$(id -u):$(id -g)" "$DIR"
    fi
  fi
  LOG_FILE="$DIR/install.log"
  : >> "$LOG_FILE" || die "Cannot write $LOG_FILE"
  log_line "install.sh v$SCRIPT_VERSION action=$ACTION dir=$DIR dry_run=$DRY_RUN"
}

# env_value KEY -> value from $DIR/.env, without an inline comment.
env_value() {
  local line
  line="$(grep -E "^$1=" "$DIR/.env" 2>/dev/null | tail -n 1 || true)"
  line="${line#*=}"
  line="${line%% #*}"
  printf '%s' "${line%"${line##*[![:space:]]}"}"
}

set_env_value() {
  local key="$1" value="$2" tmp
  tmp="$(mktemp "$DIR/.env.XXXXXX")"
  awk -v k="$key" -v v="$value" 'BEGIN{done=0} index($0, k"=")==1 && !done {print k"="v; done=1; next} {print} END{if(!done) print k"="v}' "$DIR/.env" > "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$DIR/.env"
}

load_existing() {
  [ -f "$DIR/.env" ] || die "No installation found in $DIR (no .env). Run a fresh install first."
  local host mapping
  host="$(env_value POSTGRES_HOST)"
  if [ "$host" = postgres ]; then DB_MODE=bundled; else DB_MODE=external; fi
  SITE_URL="$(env_value SITE_URL)"
  SITE_DOMAIN="$(env_value SITE_DOMAIN)"
  if [ "$SITE_DOMAIN" = ":80" ]; then
    SSL_MODE=http
    mapping="$(grep -E "^      - '([0-9.]+:)?[0-9]+:80'$" "$DIR/docker-compose.yml" 2>/dev/null | head -n 1 | sed -E "s/.*'(.*):80'.*/\1/")"
    HTTP_PORT="${mapping##*:}"
    if [ "$mapping" != "$HTTP_PORT" ]; then HTTP_BIND="${mapping%:*}"; fi
    [ -n "$HTTP_PORT" ] || HTTP_PORT=80
  else
    SSL_MODE=letsencrypt
    DOMAIN="$SITE_DOMAIN"
    HTTP_PORT=80
  fi
}

# ---------------------------------------------------------------------------
# Interactive configuration for a fresh install
# ---------------------------------------------------------------------------
choose_network() {
  local choice
  if [ -n "$NETWORK" ]; then
    ok "Network: $NETWORK"
    return 0
  fi
  say ""
  say "Network"
  say "  1) mainnet  - real funds"
  say "  2) testnet  - Solana devnet and test funds; recommended for a first install"
  ask choice "Choice" 2
  case "$choice" in
    1) NETWORK=mainnet ;;
    2) NETWORK=testnet ;;
    *) die "Invalid choice: $choice" ;;
  esac
}

test_postgres() {
  local args=(run --rm postgres:16-alpine pg_isready -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -t 5)
  info "Testing the connection to $PG_HOST:$PG_PORT"
  if docker_quiet "${args[@]}"; then
    ok "Postgres at $PG_HOST:$PG_PORT accepts connections"
  else
    warn "pg_isready could not reach $PG_HOST:$PG_PORT as $PG_USER (database $PG_DB). Check the host, port, firewall and pg_hba.conf."
    confirm "Continue anyway?" n || die "Database connection test failed."
  fi
}

choose_database() {
  local choice
  if [ -z "$DB_MODE" ]; then
    say ""
    say "Database"
    say "  1) external Postgres - recommended for production"
    say "  2) bundled Postgres container - for testing only; data lives in a Docker volume"
    ask choice "Choice" 2
    case "$choice" in
      1) DB_MODE=external ;;
      2) DB_MODE=bundled ;;
      *) die "Invalid choice: $choice" ;;
    esac
  fi
  if [ "$DB_MODE" = external ]; then
    [ -n "$PG_HOST" ] || ask PG_HOST "Postgres host" ""
    [ -n "$PG_HOST" ] || die "A Postgres host is required for an external database (--pg-host)."
    case "$PG_HOST" in
      localhost|127.0.0.1|::1)
        warn "'$PG_HOST' inside the api container is the container itself, not this machine. Use this host's LAN IP, or host.docker.internal on Docker Desktop."
        ;;
    esac
    [ -n "$PG_PORT" ] || ask PG_PORT "Postgres port" 5432
    valid_port "$PG_PORT" || die "Invalid Postgres port: $PG_PORT"
    [ -n "$PG_DB" ] || ask PG_DB "Database name" recv
    [ -n "$PG_USER" ] || ask PG_USER "Database user" recv
    [ -n "$PG_PASSWORD" ] || ask_secret PG_PASSWORD "Database password"
    if [ -z "$PG_SSL" ]; then
      if confirm "Connect with SSL?" n; then PG_SSL=true; else PG_SSL=false; fi
    fi
    test_postgres
  else
    PG_HOST=postgres
    PG_PORT=5432
    PG_DB=recv
    PG_USER=recv
    PG_SSL=false
    PG_PASSWORD="$(openssl rand -hex 24)"
    ok "Bundled Postgres will be started with the compose profile 'db'"
  fi
}

check_domain_dns() {
  local ip resolved
  if [ "$DRY_RUN" = 1 ]; then
    say "[dry-run] skipping the DNS check for $DOMAIN"
    return 0
  fi
  ip="$(public_ip)"
  resolved="$(resolve_host "$DOMAIN" | tr '\n' ' ')"
  if [ -z "$ip" ]; then
    warn "Could not determine this server's public IP (api.ipify.org unreachable); skipping the DNS check."
  elif [ -z "$resolved" ]; then
    warn "$DOMAIN does not resolve yet. Let's Encrypt will fail until an A/AAAA record points at $ip."
    confirm "Continue anyway?" y || die "Aborted."
  elif ! printf '%s' "$resolved" | grep -qw -- "$ip"; then
    warn "$DOMAIN resolves to $resolved but this server's public IP is $ip. Let's Encrypt will fail until the record is updated."
    confirm "Continue anyway?" y || die "Aborted."
  else
    ok "$DOMAIN resolves to this server ($ip)"
  fi
}

choose_ssl() {
  local choice default ip
  if [ -n "$DOMAIN" ]; then
    SSL_MODE=letsencrypt
  elif [ "$HTTP_PORT_SET" = 1 ]; then
    SSL_MODE=http
  else
    default=2
    say ""
    say "HTTPS"
    say "  1) Let's Encrypt - a domain name pointing at this server; ports 80 and 443 must be free"
    say "  2) plain HTTP    - by IP address, or behind your own reverse proxy"
    ask choice "Choice" "$default"
    case "$choice" in
      1) SSL_MODE=letsencrypt ;;
      2) SSL_MODE=http ;;
      *) die "Invalid choice: $choice" ;;
    esac
  fi

  if [ "$SSL_MODE" = letsencrypt ]; then
    [ "$OS_ID" != macos ] || die "Let's Encrypt is not available on macOS; use plain HTTP for local testing."
    [ -n "$DOMAIN" ] || ask DOMAIN "Domain name" ""
    valid_domain "$DOMAIN" || die "Invalid domain name: '$DOMAIN'"
    [ -n "$ACME_EMAIL" ] || ask ACME_EMAIL "Email for the Let's Encrypt account" "admin@${DOMAIN}"
    case "$ACME_EMAIL" in
      *@*.*) ;;
      *) die "Invalid email address: '$ACME_EMAIL'" ;;
    esac
    check_domain_dns
    HTTP_PORT=80
    SITE_DOMAIN="$DOMAIN"
    SITE_URL="https://${DOMAIN}"
    check_ports 80 443
  else
    if [ "$HTTP_PORT_SET" = 0 ]; then
      ask HTTP_PORT "Host port for HTTP" 80
      valid_port "$HTTP_PORT" || die "Invalid port: $HTTP_PORT"
    fi
    ACME_EMAIL=""
    SITE_DOMAIN=":80"
    check_ports "$HTTP_PORT"
    if [ -n "$SITE_URL_FLAG" ]; then
      SITE_URL="$SITE_URL_FLAG"
    else
      ip="$(public_ip)"
      [ -n "$ip" ] || ip=localhost
      if [ "$HTTP_PORT" = 80 ]; then default="http://${ip}"; else default="http://${ip}:${HTTP_PORT}"; fi
      ask SITE_URL "Public site URL (as reached by browsers; editable later in Settings)" "$default"
    fi
    SITE_URL="${SITE_URL%/}"
    case "$SITE_URL" in
      http://*|https://*) ;;
      *) die "The site URL must start with http:// or https://" ;;
    esac
  fi
}

generate_secrets() {
  AES_KEY="$(openssl rand -hex 32)"
  ADMIN_KEY="$(openssl rand -hex 24)"
  REDIS_PASSWORD="$(openssl rand -hex 24)"
  [ "${#AES_KEY}" -eq 64 ] || die "openssl produced an unexpected AES key length."
  ok "Generated AES_ENCRYPTION_KEY, ADMIN_API_KEY, POSTGRES_PASSWORD and REDIS_PASSWORD"
}

print_summary() {
  say ""
  say "${C_BOLD}Configuration${C_RESET}"
  say "  Directory:     $DIR"
  say "  OS:            $OS_NAME ($ARCH)"
  say "  Network:       $NETWORK"
  if [ "$DB_MODE" = bundled ]; then
    say "  Database:      bundled container (profile db)"
  else
    say "  Database:      $PG_USER@$PG_HOST:$PG_PORT/$PG_DB (ssl=$PG_SSL)"
  fi
  if [ "$SSL_MODE" = letsencrypt ]; then
    say "  HTTPS:         Let's Encrypt for $DOMAIN ($ACME_EMAIL)"
  else
    say "  HTTPS:         none; plain HTTP on host port $HTTP_PORT${HTTP_BIND:+, address $HTTP_BIND only}"
  fi
  say "  Site URL:      $SITE_URL"
  if [ -n "$SOURCE" ]; then
    say "  Images:        built from $SOURCE"
  else
    say "  Images:        ghcr.io/recv-fund/recvfund-api and recvfund-web, version $IMAGE_TAG"
  fi
  say "  Secrets:       generated (written only to $DIR/.env)"
  say ""
  confirm "Write the files and start the services?" y || die "Aborted; nothing was written."
}

# ---------------------------------------------------------------------------
# File templates. These are copies of recvfund-server's deploy/.env.example,
# docker-compose.prod.yml and deploy/Caddyfile. Keep them identical to the
# repo apart from the substitutions marked in README.md.
# ---------------------------------------------------------------------------
render_env() {
  cat <<EOF
# docker compose --env-file for docker-compose.prod.yml. Written by the
# installer; edit by hand only if you know what each value does.

# ":80" for plain HTTP (IP address or behind your own proxy), or the domain
# name pointing at this server for automatic HTTPS.
SITE_DOMAIN=${SITE_DOMAIN}
ACME_EMAIL=${ACME_EMAIL}
# The public address of this instance: used in payment links, emails and the
# dashboard. Editable later under Settings -> Site URL.
SITE_URL=${SITE_URL}

NETWORK_TYPE=${NETWORK}            # mainnet | testnet

# Never change after first start: it decrypts every secret in the database.
AES_ENCRYPTION_KEY=${AES_KEY}
ADMIN_API_KEY=${ADMIN_KEY}

# Postgres. Leave POSTGRES_HOST=postgres to use the bundled container
# (started with \`--profile db\`); point it at an external server otherwise.
POSTGRES_HOST=${PG_HOST}
POSTGRES_PORT=${PG_PORT}
POSTGRES_USER=${PG_USER}
POSTGRES_PASSWORD=${PG_PASSWORD}
POSTGRES_DB=${PG_DB}
POSTGRES_SSL=${PG_SSL}

REDIS_PASSWORD=${REDIS_PASSWORD}

SEND_WEBHOOKS=true
IMAGE_TAG=${IMAGE_TAG}
EOF
}

# Substitution in plain-HTTP mode: '80:80' becomes '<port>:80' and the two
# 443 mappings are removed, so only the chosen host port must be free.
render_compose() {
  local line
  while IFS= read -r line; do
    if [ "$SSL_MODE" = http ]; then
      case "$line" in
        "      - '80:80'") line="      - '${HTTP_BIND:+$HTTP_BIND:}${HTTP_PORT}:80'" ;;
        "      - '443:443'"|"      - '443:443/udp'") continue ;;
      esac
    fi
    printf '%s\n' "$line"
  done <<'EOF'
# The merchant stack. Started by the installer as
#   docker compose -p recvfund --env-file /opt/recvfund/.env [--profile db] up -d
# Images are published for amd64 and arm64. Nothing here is built on the
# merchant's server.

services:
  caddy:
    image: caddy:2-alpine
    restart: unless-stopped
    ports:
      - '80:80'
      - '443:443'
      - '443:443/udp'
    environment:
      SITE_DOMAIN: ${SITE_DOMAIN}
      ACME_EMAIL: ${ACME_EMAIL}
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy-data:/data
      - caddy-config:/config
    depends_on:
      - web
      - api

  api:
    image: ghcr.io/recv-fund/recvfund-api:${IMAGE_TAG:-latest}
    restart: unless-stopped
    environment:
      NODE_ENV: production
      PORT: 3001
      NETWORK_TYPE: ${NETWORK_TYPE}
      SITE_URL: ${SITE_URL}
      AES_ENCRYPTION_KEY: ${AES_ENCRYPTION_KEY}
      ADMIN_API_KEY: ${ADMIN_API_KEY}
      SEND_WEBHOOKS: ${SEND_WEBHOOKS:-true}
      POSTGRES_HOST: ${POSTGRES_HOST}
      POSTGRES_PORT: ${POSTGRES_PORT}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_SSL: ${POSTGRES_SSL:-false}
      REDIS_HOST: redis
      REDIS_PORT: 6379
      REDIS_PASSWORD: ${REDIS_PASSWORD}
    volumes:
      - api-logs:/repo/apps/api/logs
      - api-uploads:/repo/apps/api/uploads
    depends_on:
      redis:
        condition: service_healthy
    healthcheck:
      test: ['CMD', 'wget', '-qO-', 'http://127.0.0.1:3001/api/v1/health']
      interval: 30s
      timeout: 5s
      retries: 3

  web:
    image: ghcr.io/recv-fund/recvfund-web:${IMAGE_TAG:-latest}
    restart: unless-stopped
    environment:
      NODE_ENV: production
      # Same origin as the browser: Caddy routes /api/* to the api service.
      NEXT_PUBLIC_API_URL: /api/v1
      API_INTERNAL_URL: http://api:3001/api/v1
    depends_on:
      - api

  postgres:
    image: postgres:16-alpine
    profiles: ['db']
    restart: unless-stopped
    environment:
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB}
    volumes:
      - postgres-data:/var/lib/postgresql/data
    healthcheck:
      test: ['CMD-SHELL', 'pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}']
      interval: 5s
      timeout: 3s
      retries: 20

  redis:
    image: redis:7-alpine
    restart: unless-stopped
    command: >
      redis-server --requirepass ${REDIS_PASSWORD} --appendonly yes
    volumes:
      - redis-data:/data
    healthcheck:
      test: ['CMD', 'redis-cli', '-a', '${REDIS_PASSWORD}', 'ping']
      interval: 10s
      timeout: 3s
      retries: 5

volumes:
  caddy-data:
  caddy-config:
  postgres-data:
  redis-data:
  api-logs:
  api-uploads:
EOF
}

# Substitution in plain-HTTP mode: the global options block is dropped,
# because Caddy rejects `email` with an empty ACME_EMAIL.
render_caddyfile() {
  local line skipping=0 done_global=0
  while IFS= read -r line; do
    if [ "$SSL_MODE" = http ] && [ "$done_global" = 0 ]; then
      if [ "$skipping" = 0 ] && [ "$line" = "{" ]; then skipping=1; continue; fi
      if [ "$skipping" = 1 ]; then
        [ "$line" = "}" ] && { skipping=0; done_global=1; }
        continue
      fi
    fi
    printf '%s\n' "$line"
  done <<'EOF'
# One origin for dashboard, checkout and API. When SITE_DOMAIN is a real
# hostname Caddy obtains and renews a Let's Encrypt certificate; when it is
# ":80" the stack serves plain HTTP (behind a proxy, or by IP address).
{
	email {$ACME_EMAIL}
}

{$SITE_DOMAIN} {
	encode zstd gzip

	@api path /api /api/* /api-json /api-yaml
	handle @api {
		reverse_proxy api:3001
	}

	handle {
		reverse_proxy web:3000
	}
}
EOF
}

render_build_override() {
  cat <<EOF
# Written by install.sh --source. Builds the images from a local checkout of
# recvfund-server instead of pulling them. Loaded after docker-compose.yml.
services:
  api:
    build:
      context: ${SOURCE}
      dockerfile: apps/api/Dockerfile
  web:
    build:
      context: ${SOURCE}
      dockerfile: apps/web/Dockerfile
      args:
        NEXT_PUBLIC_API_URL: /api/v1
EOF
}

write_files() {
  local old_umask
  info "Writing $DIR/.env, docker-compose.yml and Caddyfile"
  old_umask="$(umask)"
  umask 077
  render_env > "$DIR/.env"
  chmod 600 "$DIR/.env"
  umask "$old_umask"
  render_compose > "$DIR/docker-compose.yml"
  render_caddyfile > "$DIR/Caddyfile"
  write_build_override
  ok "Files written"
}

write_build_override() {
  if [ -n "$SOURCE" ]; then
    render_build_override > "$DIR/docker-compose.build.yml"
    say "Images will be built from $SOURCE (docker-compose.build.yml)"
  fi
}

# ---------------------------------------------------------------------------
# Docker operations
# ---------------------------------------------------------------------------
fetch_images() {
  if [ -f "$DIR/docker-compose.build.yml" ]; then
    info "Building images"
    compose build --pull
    compose pull --ignore-buildable
  else
    info "Pulling images"
    compose pull
  fi
}

run_migrations() {
  info "Starting the database and cache"
  if [ "$DB_MODE" = bundled ]; then
    compose up -d --wait postgres redis
  else
    compose up -d --wait redis
  fi
  info "Running migrations"
  compose run --rm api node dist/src/db/migrate
}

start_services() {
  info "Starting services"
  compose up -d --remove-orphans
}

health_url() {
  if [ "$SSL_MODE" = letsencrypt ]; then
    printf 'https://%s/api/v1/health' "$DOMAIN"
  else
    printf 'http://%s:%s/api/v1/health' "${HTTP_BIND:-127.0.0.1}" "$HTTP_PORT"
  fi
}

wait_healthy() {
  local url waited=0 body
  url="$(health_url)"
  if [ "$DRY_RUN" = 1 ]; then
    say "[dry-run] would poll $url for up to ${HEALTH_TIMEOUT}s"
    return 0
  fi
  info "Waiting for the API to report healthy ($url)"
  while [ "$waited" -lt "$HEALTH_TIMEOUT" ]; do
    if [ "$SSL_MODE" = letsencrypt ]; then
      body="$("${DOCKER[@]}" compose -p "$PROJECT" --env-file "$DIR/.env" -f "$DIR/docker-compose.yml" exec -T api wget -qO- http://127.0.0.1:3001/api/v1/health 2>/dev/null || true)"
    else
      body="$(curl -fsS --max-time 5 "$url" 2>/dev/null || true)"
    fi
    if [[ "$body" =~ ^\{[[:space:]]*\"status\"[[:space:]]*:[[:space:]]*\"ok\"[[:space:]]*[,}] ]]; then
      ok "API healthy after ${waited}s"
      log_line "health: $body"
      return 0
    fi
    sleep 3
    waited=$(( waited + 3 ))
  done
  warn "The API did not report healthy within ${HEALTH_TIMEOUT}s. Check: cd $DIR && ${DOCKER[*]} compose -p $PROJECT logs --tail=100 api"
  return 1
}

print_done() {
  say ""
  say "${C_GREEN}${C_BOLD}recv.fund installed${C_RESET}"
  say ""
  say "  Create the root account:  ${SITE_URL}/signup"
  say "  Configuration:            ${DIR}/.env"
  say "  Logs:                     cd ${DIR} && ${DOCKER[*]} compose -p ${PROJECT} logs -f --tail=100 api"
  if [ "$SSL_MODE" = letsencrypt ]; then
    say "  Certificate:              Caddy requests it from Let's Encrypt on the first request; allow a minute."
  fi
  say ""
  say "Back up ${DIR}/.env now. AES_ENCRYPTION_KEY in that file decrypts every"
  say "secret in the database, including hot wallet keys. If it is lost they"
  say "cannot be recovered."
}

# ---------------------------------------------------------------------------
# Operations
# ---------------------------------------------------------------------------
handle_existing_install() {
  local choice
  [ -f "$DIR/.env" ] || return 0
  say ""
  say "An installation already exists in $DIR."
  say "  1) update it (pull new images, migrate, restart); the data is kept"
  say "  2) remove it and install again (deletes containers, images, volumes and $DIR)"
  say "  3) cancel"
  ask choice "Choice" 1
  case "$choice" in
    1) ACTION=update; do_update; exit 0 ;;
    2) do_reset; ACTION=install ;;
    3) die "Cancelled." ;;
    *) die "Invalid choice: $choice" ;;
  esac
}

do_install() {
  detect_os
  require_tools
  if [ -f "$DIR/.env" ]; then
    LOG_FILE="$DIR/install.log"
    handle_existing_install
  fi
  ensure_docker
  ensure_dir
  check_disk
  choose_network
  choose_database
  choose_ssl
  generate_secrets
  choose_install_tag
  print_summary
  write_files
  fetch_images
  run_migrations
  start_services
  wait_healthy
  print_done
}

# True when $1 is a newer release version than $2 (both X.Y.Z).
version_newer() {
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)" = "$1" ]
}

# Prints the newest X.Y.Z that both images have on GHCR. The packages are
# public, so an anonymous pull token can list their tags. RECV_LATEST_RELEASE
# replaces the lookup in tests.
latest_release() {
  local app token tags versions="" found
  if [ -n "${RECV_LATEST_RELEASE:-}" ]; then
    printf '%s\n' "$RECV_LATEST_RELEASE"
    return 0
  fi
  for app in api web; do
    token="$(curl -fsS --max-time 15 "https://ghcr.io/token?scope=repository:${REGISTRY_REPO}-${app}:pull" \
      | sed -E 's/.*"token":"([^"]+)".*/\1/')" || return 1
    tags="$(curl -fsS --max-time 15 -H "Authorization: Bearer $token" \
      "https://ghcr.io/v2/${REGISTRY_REPO}-${app}/tags/list?n=10000")" || return 1
    found="$(grep -oE '"[0-9]+\.[0-9]+\.[0-9]+"' <<<"$tags" | tr -d '"' | sort -u || true)"
    if [ "$app" = api ]; then
      versions="$found"
    else
      versions="$(comm -12 <(printf '%s\n' "$versions") <(printf '%s\n' "$found"))"
    fi
  done
  versions="$(printf '%s\n' "$versions" | sed '/^$/d' | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)"
  [ -n "$versions" ] || return 1
  printf '%s\n' "$versions"
}

newest_release_or_die() {
  local tag
  tag="$(latest_release)" \
    || die "Could not find the newest release on ghcr.io (network or registry unavailable). Pass --image-tag X.Y.Z to choose a version."
  printf '%s\n' "$tag"
}

# A fresh install runs --image-tag, or else the newest release.
choose_install_tag() {
  [ -n "$IMAGE_TAG" ] && return 0
  if [ -n "$SOURCE" ]; then
    IMAGE_TAG="local"
    return 0
  fi
  IMAGE_TAG="$(newest_release_or_die)"
}

# An update moves to the newest release unless --image-tag is given. It
# refuses to move a newer installed version back to an older one, which can
# only happen when a release was removed from the registry.
choose_update_tag() {
  local current newest
  [ -n "$IMAGE_TAG" ] && return 0
  current="$(env_value IMAGE_TAG)"
  if [ -n "$SOURCE" ] || [ -f "$DIR/docker-compose.build.yml" ]; then
    IMAGE_TAG="${current:-local}"
    return 0
  fi
  newest="$(newest_release_or_die)"
  if [[ "$current" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && version_newer "$current" "$newest"; then
    die "The installation runs $current, which is newer than the newest release found ($newest). Pass --image-tag to choose a version."
  fi
  if [ "$current" = "$newest" ]; then
    say "Already on the newest release, $newest. Pulling it again and restarting."
  else
    say "Updating from ${current:-an unknown version} to $newest."
  fi
  IMAGE_TAG="$newest"
}

prepare_caddy_update() {
  if [ ! -f "$DIR/Caddyfile" ] || [ -L "$DIR/Caddyfile" ]; then
    die 'Expected a regular Caddyfile; review the proxy configuration before updating.'
  fi
  CADDY_UPDATE_FILE="$(mktemp "$DIR/.Caddyfile.update.XXXXXX")"
  # Change only the known API handler, retaining the merchant's other directives.
  if ! awk '
    /^[[:space:]]*#/ { print; next }
    /^[[:space:]]*handle \/api\/\* \{[[:space:]]*$/ {
      legacy++
      match($0, /^[[:space:]]*/); indent=substr($0, 1, RLENGTH)
      print indent "@api path /api /api/* /api-json /api-yaml"
      print indent "handle @api {"
      next
    }
    /^[[:space:]]*@api path \/api \/api\/\* \/api-json \/api-yaml[[:space:]]*$/ { matcher++ }
    /^[[:space:]]*handle @api \{[[:space:]]*$/ { handler++ }
    /@api/ { references++ }
    { print }
    END {
      if (!((legacy == 1 && references == 0) || (legacy == 0 && matcher == 1 && handler == 1 && references == 2))) exit 1
    }
  ' "$DIR/Caddyfile" > "$CADDY_UPDATE_FILE"; then
    rm -f -- "$CADDY_UPDATE_FILE"
    CADDY_UPDATE_FILE=""
    die 'Unrecognized API proxy configuration. Add the /api, /api/*, /api-json and /api-yaml routes to the API upstream and review the Caddyfile before updating. No services or migrations were started.'
  fi
  info 'Validating the upgrade proxy configuration before stopping services'
  if ! compose run --rm --no-deps -T --entrypoint caddy \
    -v "$CADDY_UPDATE_FILE:/etc/caddy/Caddyfile:ro" caddy \
    validate --adapter caddyfile --config /etc/caddy/Caddyfile; then
    rm -f -- "$CADDY_UPDATE_FILE"
    CADDY_UPDATE_FILE=""
    die 'Candidate Caddy configuration is invalid. The original file and application are unchanged.'
  fi
}

apply_caddy_update() {
  local backup
  if ! cmp -s "$DIR/Caddyfile" "$CADDY_UPDATE_FILE"; then
    backup="$(mktemp "$DIR/Caddyfile.before-update.XXXXXX")"
    cp "$DIR/Caddyfile" "$backup"
    chmod 600 "$backup"
    # Retain the inode so an existing single-file bind mount sees the new content.
    cat "$CADDY_UPDATE_FILE" > "$DIR/Caddyfile"
    say "Updated API proxy routes; previous Caddyfile saved to $backup"
  fi
  rm -f -- "$CADDY_UPDATE_FILE"
  CADDY_UPDATE_FILE=""
}

do_update() {
  detect_os
  load_existing
  ensure_dir
  ensure_docker
  choose_update_tag
  # Compose's process environment selects the candidate without publishing it
  # as the installed version before its pull and migrations have succeeded.
  export IMAGE_TAG
  write_build_override
  fetch_images
  prepare_caddy_update
  info "Stopping application services before database migrations"
  compose stop caddy web api
  UPDATE_PHASE=migration
  run_migrations
  apply_caddy_update
  UPDATE_PHASE=""
  set_env_value IMAGE_TAG "$IMAGE_TAG"
  say "IMAGE_TAG set to $IMAGE_TAG"
  start_services
  wait_healthy
  say ""
  say "${C_GREEN}${C_BOLD}recv.fund updated${C_RESET}  ${SITE_URL}"
}

do_restart() {
  detect_os
  load_existing
  ensure_dir
  ensure_docker
  info "Restarting services"
  compose restart
  wait_healthy
  say "${C_GREEN}${C_BOLD}recv.fund restarted${C_RESET}  ${SITE_URL}"
}

do_status() {
  detect_os
  load_existing
  ensure_docker
  compose ps
  say ""
  if [ "$DRY_RUN" = 1 ]; then
    say "[dry-run] would request $(health_url)"
  elif [ "$SSL_MODE" = letsencrypt ]; then
    if "${DOCKER[@]}" compose -p "$PROJECT" --env-file "$DIR/.env" -f "$DIR/docker-compose.yml" exec -T api wget -qO- http://127.0.0.1:3001/api/v1/health; then
      printf '\n'
    else
      warn "The API health endpoint did not answer."
    fi
  else
    if curl -fsS --max-time 5 "$(health_url)"; then
      printf '\n'
    else
      warn "The API health endpoint did not answer at $(health_url)."
    fi
  fi
}

do_reset() {
  local typed
  detect_os
  [ -d "$DIR" ] || die "Nothing to reset: $DIR does not exist."
  [ -f "$DIR/.env" ] && load_existing
  if [ -f "$DIR/.env" ]; then
    ensure_docker
  fi
  say ""
  warn "This removes the recv.fund containers, images and volumes (including the bundled database) and deletes $DIR."
  say "Back up $DIR/.env and the database first if you may need them."
  ask typed "Type the directory path to confirm" ""
  [ "$typed" = "$DIR" ] || die "Confirmation did not match; nothing was removed."
  ask typed "Type it once more" ""
  [ "$typed" = "$DIR" ] || die "Confirmation did not match; nothing was removed."
  if [ -f "$DIR/.env" ]; then
    info "Removing containers, volumes and images"
    compose down -v --rmi all --remove-orphans || warn "docker compose down reported an error; continuing."
  fi
  info "Deleting $DIR"
  if [ "$DRY_RUN" = 1 ]; then
    say "[dry-run] rm -rf $DIR"
  elif ! rm -rf "$DIR" 2>/dev/null; then
    as_root rm -rf "$DIR"
  fi
  LOG_FILE=""
  ok "Reset complete"
}

menu() {
  local choice
  say "Operations"
  say "  1) fresh install"
  say "  2) update to the newest release"
  say "  3) restart services"
  say "  4) reset (remove containers, images and data)"
  say "  5) show status"
  say "  6) exit"
  ask choice "Choice" 1
  case "$choice" in
    1) ACTION=install ;;
    2) ACTION=update ;;
    3) ACTION=restart ;;
    4) ACTION=reset ;;
    5) ACTION=status ;;
    6) exit 0 ;;
    *) die "Invalid choice: $choice" ;;
  esac
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
parse_args "$@"
banner
if [ "$ASSUME_YES" = 1 ] && [ "$TTY_OK" = 0 ]; then
  say "Running non-interactively with defaults (--yes)."
fi
[ -n "$ACTION" ] || menu
if [ -f "$DIR/.env" ] && [ -w "$DIR" ]; then
  LOG_FILE="$DIR/install.log"
fi
case "$ACTION" in
  install) do_install ;;
  update)  do_update ;;
  restart) do_restart ;;
  reset)   do_reset ;;
  status)  do_status ;;
esac
}

# Sourcing defines the renderers without parsing arguments or running operations.
# Piped into bash (curl ... | bash) there is no source file, so BASH_SOURCE is
# empty: that is an execution, not a source.
if [ -z "${BASH_SOURCE[0]:-}" ] || [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
