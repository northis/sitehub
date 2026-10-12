#!/usr/bin/env bash
# SiteHub Access JWT verifier installer.
#
# Builds and starts the forwardAuth service that validates the
# Cf-Access-Jwt-Assertion header on the entry container, so a request that
# reached the origin without passing Cloudflare Access is rejected before
# it reaches a site. The service listens only inside the "proxy" Docker
# network; no ports are published.
#
# Idempotent: every step detects prior completion and skips, so the script
# is safe to re-run. Guarantees: never deletes Docker objects it does not
# own, never edits the Docker daemon configuration.
#
# Usage:
#   sudo ./scripts/install-access-verify.sh [--global]
#   sudo ./scripts/install-access-verify.sh remove

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

VERIFIER_DIR="${REPO_DIR}/access/verifier"
VERIFIER_COMPOSE="${VERIFIER_DIR}/compose.yaml"
VERIFIER_ENV="${VERIFIER_DIR}/.env"
VERIFIER_CONTAINER="cf-access-verify"
VERIFIER_IMAGE="sitehub-cf-access-verify:latest"
ENV_FILE=".env"
PROXY_NETWORK="proxy"
TRAEFIK_CONTAINER="traefik"
WAIT_SECONDS=60
JWKS_WAIT_SECONDS=30
POLL_INTERVAL=2
GLOBAL=0

log() { printf '[%s] %s\n' "$1" "$2"; }
fail() { log FAIL "$1"; exit 1; }

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    fail "run as root: sudo ./scripts/install-access-verify.sh"
  fi
}

preflight() {
  printf '\n== Preflight ==\n'
  require_root

  if ! command -v docker >/dev/null 2>&1; then
    fail "Docker is not installed; run 'sudo ./scripts/install.sh' first"
  fi
  if ! docker network inspect "$PROXY_NETWORK" >/dev/null 2>&1; then
    fail "docker network '${PROXY_NETWORK}' does not exist; run 'sudo ./scripts/install.sh' first"
  fi
  if ! docker inspect "$TRAEFIK_CONTAINER" >/dev/null 2>&1; then
    fail "container '${TRAEFIK_CONTAINER}' does not exist; run 'sudo ./scripts/install.sh' first"
  fi

  local file
  for file in "${VERIFIER_DIR}/server.js" "${VERIFIER_DIR}/Dockerfile" "$VERIFIER_COMPOSE"; do
    if [ ! -f "$file" ]; then
      fail "${file} is missing; is the repository complete?"
    fi
  done
  log OK "Docker, the '${PROXY_NETWORK}' network and the entry container are available"
}

load_verifier_env() {
  if [ ! -f "$VERIFIER_ENV" ]; then
    fail "access/verifier/.env not found"
  fi
  set -a
  # shellcheck source=/dev/null
  . "$VERIFIER_ENV"
  set +a
  if [ -z "${TEAM_DOMAIN:-}" ] || [ -z "${POLICY_AUD:-}" ]; then
    fail "TEAM_DOMAIN and POLICY_AUD must be set in access/verifier/.env"
  fi
  if [[ ! "${TEAM_DOMAIN}" =~ ^https://[A-Za-z0-9.-]+$ ]]; then
    fail "TEAM_DOMAIN in access/verifier/.env must look like https://<team-name>.cloudflareaccess.com"
  fi
  if [[ ! "${POLICY_AUD}" =~ ^[0-9a-fA-F]{64}$ ]]; then
    fail "POLICY_AUD in access/verifier/.env must be 64 hexadecimal characters (the AUD tag of the Access application)"
  fi
}

create_env() {
  if [ ! -t 0 ]; then
    fail "access/verifier/.env is missing and stdin is not a terminal; copy access/verifier/.env.example, fill it in, then re-run"
  fi
  printf 'Creating access/verifier/.env interactively:\n'
  local team_input aud_input
  read -r -p "TEAM_DOMAIN (https://<team-name>.cloudflareaccess.com): " team_input
  read -r -p "POLICY_AUD (Access application AUD tag, 64 hex chars): " aud_input
  team_input="${team_input%/}"
  if [[ ! "$team_input" =~ ^https://[A-Za-z0-9.-]+$ ]]; then
    fail "TEAM_DOMAIN must look like https://<team-name>.cloudflareaccess.com"
  fi
  if [[ ! "$aud_input" =~ ^[0-9a-fA-F]{64}$ ]]; then
    fail "POLICY_AUD must be 64 hexadecimal characters (Zero Trust -> Access controls -> Applications -> Configure -> Additional settings)"
  fi
  install -m 600 /dev/null "$VERIFIER_ENV"
  {
    printf 'TEAM_DOMAIN=%s\n' "$team_input"
    printf 'POLICY_AUD=%s\n' "$aud_input"
    printf 'PORT=4180\n'
  } > "$VERIFIER_ENV"
  log OK "access/verifier/.env created (chmod 600)"
}

ensure_config() {
  printf '\n== Settings ==\n'
  if [ -f "$VERIFIER_ENV" ]; then
    load_verifier_env
    log SKIP "access/verifier/.env already exists"
    return
  fi
  create_env
  load_verifier_env
}

build_and_start() {
  printf '\n== Verifier container ==\n'
  docker compose -f "$VERIFIER_COMPOSE" up -d --build

  local waited=0 running=""
  while [ "$waited" -lt "$WAIT_SECONDS" ]; do
    running="$(docker inspect -f '{{.State.Running}}' "$VERIFIER_CONTAINER" 2>/dev/null || true)"
    if [ "$running" = "true" ]; then break; fi
    sleep "$POLL_INTERVAL"
    waited=$((waited + POLL_INTERVAL))
  done
  if [ "$running" != "true" ]; then
    docker logs --tail 30 "$VERIFIER_CONTAINER" 2>&1 || true
    fail "container '${VERIFIER_CONTAINER}' is not running (see the log above)"
  fi
  log OK "container '${VERIFIER_CONTAINER}' is running"

  # The initial JWKS download proves that TEAM_DOMAIN is reachable and the
  # team exists; without keys every request fails closed.
  waited=0
  local logs=""
  while [ "$waited" -lt "$JWKS_WAIT_SECONDS" ]; do
    logs="$(docker logs "$VERIFIER_CONTAINER" 2>&1 || true)"
    case "$logs" in
      *"jwks: loaded"*) break ;;
    esac
    sleep "$POLL_INTERVAL"
    waited=$((waited + POLL_INTERVAL))
  done
  if [[ "$logs" == *"jwks: loaded"* ]]; then
    log OK "signing keys loaded from ${TEAM_DOMAIN}/cdn-cgi/access/certs"
  else
    printf '%s\n' "$logs" | tail -n 20
    fail "the verifier could not load the signing keys within ${JWKS_WAIT_SECONDS}s (see the log above); check TEAM_DOMAIN in access/verifier/.env"
  fi
}

verify() {
  printf '\n== Verification ==\n'
  # A request without a token must be rejected with 401.
  if docker run --rm --network "$PROXY_NETWORK" "$VERIFIER_IMAGE" \
      node -e "fetch('http://${VERIFIER_CONTAINER}:4180/').then((r) => process.exit(r.status === 401 ? 0 : 1)).catch(() => process.exit(1));"; then
    log OK "a request without an Access JWT is rejected (401)"
  else
    fail "the verifier did not reject an unauthenticated request; see 'docker logs ${VERIFIER_CONTAINER}'"
  fi
}

# CF_ACCESS_VERIFY_GLOBAL is rendered into the Traefik static configuration
# by traefik/render-config.sh: with true, cf-access-verify@file is added to
# the websecure entrypoint middlewares, so every site requires a token.
set_global_flag() {
  local value="$1"
  if [ ! -f "$ENV_FILE" ]; then
    fail "${ENV_FILE} not found; run 'sudo ./scripts/install.sh' first"
  fi
  if grep -q '^CF_ACCESS_VERIFY_GLOBAL=' "$ENV_FILE"; then
    sed -i "s|^CF_ACCESS_VERIFY_GLOBAL=.*|CF_ACCESS_VERIFY_GLOBAL=${value}|" "$ENV_FILE"
  else
    printf '\n# Require a valid Cloudflare Access JWT for every site (see README).\nCF_ACCESS_VERIFY_GLOBAL=%s\n' "$value" >> "$ENV_FILE"
  fi
}

recreate_traefik() {
  printf '\n== Entry container ==\n'
  docker compose up -d
  local waited=0 status=""
  while [ "$waited" -lt "$WAIT_SECONDS" ]; do
    status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$TRAEFIK_CONTAINER" 2>/dev/null || echo starting)"
    if [ "$status" = "healthy" ]; then break; fi
    sleep "$POLL_INTERVAL"
    waited=$((waited + POLL_INTERVAL))
  done
  if [ "$status" != "healthy" ]; then
    docker logs --tail 30 "$TRAEFIK_CONTAINER" || true
    fail "traefik did not become healthy within ${WAIT_SECONDS}s (see the log above)"
  fi
  log OK "traefik re-created and healthy"
}

enable_global() {
  printf '\n== Global attachment ==\n'
  set_global_flag true
  recreate_traefik
  if docker compose exec -T traefik grep -q 'cf-access-verify@file' /etc/traefik/traefik.yml; then
    log OK "every site now requires a valid Access JWT (public Bypass apps get 401)"
  else
    fail "cf-access-verify@file is not in the rendered traefik configuration; check 'docker logs ${TRAEFIK_CONTAINER}'"
  fi
}

print_summary() {
  printf '\n== Summary ==\n'
  echo "Access JWT verifier installed (container: ${VERIFIER_CONTAINER})."
  echo
  echo "Attach the check to the sites that must not be reachable without Access -"
  echo "one label on the site's router (Traefik picks it up without a restart):"
  echo '    traefik.http.routers.site1.middlewares: "cf-access-verify@file"'
  if [ "$GLOBAL" -eq 1 ]; then
    echo
    echo "Global mode is on (CF_ACCESS_VERIFY_GLOBAL=true in .env): every site"
    echo "requires a valid Access JWT, including public Bypass apps."
  else
    echo
    echo "Or protect every site at once: sudo ./scripts/install-access-verify.sh --global"
  fi
  echo
  echo "- Verifier log (allows and denials with reasons): docker logs ${VERIFIER_CONTAINER}"
  echo "- Remove: sudo ./scripts/install-access-verify.sh remove"
}

run_install() {
  preflight
  ensure_config
  build_and_start
  verify
  if [ "$GLOBAL" -eq 1 ]; then
    enable_global
  fi
  print_summary
}

run_remove() {
  printf '\n== Removing the Access JWT verifier ==\n'
  require_root

  # Drop the global attachment first, so sites stop depending on a
  # container that is about to disappear.
  if [ -f "$ENV_FILE" ] && grep -q '^CF_ACCESS_VERIFY_GLOBAL=true' "$ENV_FILE"; then
    set_global_flag false
    if docker inspect "$TRAEFIK_CONTAINER" >/dev/null 2>&1; then
      recreate_traefik
    fi
  fi

  if [ -f "$VERIFIER_COMPOSE" ]; then
    docker compose -f "$VERIFIER_COMPOSE" down >/dev/null 2>&1 || true
  fi
  docker rmi "$VERIFIER_IMAGE" >/dev/null 2>&1 || true
  log OK "verifier removed (access/verifier/.env is kept)"
  echo "Per-site labels 'cf-access-verify@file' must be removed from the sites,"
  echo "otherwise they answer 500 (the middleware target is gone)."
}

usage() {
  cat <<'EOF'
Usage:
  sudo ./scripts/install-access-verify.sh [--global]
      Build and start the Access JWT verifier (Traefik forwardAuth).
      --global additionally requires a valid Access JWT for every site
      (public Bypass apps get 401).
  sudo ./scripts/install-access-verify.sh remove
      Stop and remove the verifier and the global attachment.
EOF
}

main() {
  case "${1:-}" in
    "")
      run_install
      ;;
    --global)
      GLOBAL=1
      run_install
      ;;
    remove)
      run_remove
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
