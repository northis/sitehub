#!/usr/bin/env bash
# SiteHub installer for Ubuntu servers.
#
# Idempotent: every step detects prior completion and skips, so the
# script is safe to re-run. Guarantees: never deletes Docker objects,
# never edits Docker daemon configuration, never restarts containers it
# does not own; ufw rules are only added, never removed.
#
# Usage: sudo ./scripts/install.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

ENV_FILE=".env"
NETWORK_NAME="proxy"
CONTAINER_NAME="traefik"
HEALTH_WAIT_SECONDS=120
CERT_WAIT_SECONDS=120
POLL_INTERVAL=3
DNS_WARN=0
CERT_FAIL=0

log() { printf '[%s] %s\n' "$1" "$2"; }
fail() { log FAIL "$1"; exit 1; }

load_env() {
  set -a
  # shellcheck source=/dev/null
  . "./${ENV_FILE}"
  set +a
  local var
  for var in DOMAIN LE_EMAIL CF_DNS_API_TOKEN; do
    if [ -z "${!var:-}" ]; then
      fail "${var} is empty in ${ENV_FILE}; fill it in and re-run"
    fi
  done
}

create_env() {
  if [ ! -t 0 ]; then
    fail "${ENV_FILE} is missing and stdin is not a terminal; copy .env.example to .env, fill it in, then re-run"
  fi
  printf 'Creating %s interactively:\n' "$ENV_FILE"
  local domain_input email_input token_input
  read -r -p "DOMAIN (e.g. foodomain.com): " domain_input
  read -r -p "LE_EMAIL (Let's Encrypt account email): " email_input
  read -r -p "CF_DNS_API_TOKEN (Cloudflare, Zone->DNS->Edit for the zone): " token_input
  if [ -z "$domain_input" ] || [ -z "$email_input" ] || [ -z "$token_input" ]; then
    fail "DOMAIN, LE_EMAIL and CF_DNS_API_TOKEN must not be empty"
  fi
  cp .env.example "$ENV_FILE"
  sed -i "s|^DOMAIN=.*|DOMAIN=${domain_input}|" "$ENV_FILE"
  sed -i "s|^LE_EMAIL=.*|LE_EMAIL=${email_input}|" "$ENV_FILE"
  sed -i "s|^CF_DNS_API_TOKEN=.*|CF_DNS_API_TOKEN=${token_input}|" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  load_env
  log OK ".env created (chmod 600)"
}

check_wildcard_dns() {
  # Soft check only: certificates are issued via DNS-01 (API), but sites
  # need the wildcard A record to be reachable by clients.
  if ! command -v dig >/dev/null 2>&1; then
    log WARN "dig not found (apt install dnsutils); skipping wildcard DNS check"
    DNS_WARN=1
    return
  fi
  local public_ip resolved
  public_ip="$(curl -fsS --max-time 10 https://api.ipify.org || true)"
  if [ -z "$public_ip" ]; then
    log WARN "could not detect the public IP; skipping wildcard DNS check"
    DNS_WARN=1
    return
  fi
  resolved="$(dig +short "probe-${RANDOM}.${DOMAIN}" A | tail -n1 || true)"
  if [ "$resolved" != "$public_ip" ]; then
    log WARN "wildcard DNS does not resolve to this server: probe.${DOMAIN} -> '${resolved:-none}', expected ${public_ip}; create the one-time Cloudflare record A *.${DOMAIN} -> ${public_ip}"
    DNS_WARN=1
  else
    log OK "wildcard DNS resolves to ${public_ip}"
  fi
}

preflight() {
  printf '\n== Preflight ==\n'

  if [ "$(id -u)" -ne 0 ]; then
    fail "run as root: sudo ./scripts/install.sh"
  fi

  if [ -r /etc/os-release ]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    if [ "${ID:-}" != "ubuntu" ]; then
      log WARN "not Ubuntu (${ID:-unknown}); continuing, but only Ubuntu is supported"
    elif [ "${VERSION_ID:-}" != "24.04" ]; then
      log WARN "Ubuntu ${VERSION_ID:-?} detected; 24.04 LTS is the supported version"
    else
      log OK "Ubuntu ${VERSION_ID}"
    fi
  fi

  # Ports 80/443 must be free before anything on the system is changed.
  local port listeners
  for port in 80 443; do
    listeners="$(ss -Htlnp "sport = :${port}" || true)"
    if [ -n "$listeners" ]; then
      printf '%s\n' "$listeners"
      fail "port ${port} is already in use (see the process above); free it and re-run"
    fi
  done
  log OK "ports 80 and 443 are free"

  if [ -f "$ENV_FILE" ]; then
    load_env
    log OK ".env found and valid"
  else
    create_env
  fi

  check_wildcard_dns
}

ensure_docker() {
  printf '\n== Docker ==\n'
  if command -v docker >/dev/null 2>&1; then
    log SKIP "Docker already installed: $(docker --version)"
    return
  fi
  DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl >/dev/null
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  local arch codename
  arch="$(dpkg --print-architecture)"
  # shellcheck source=/dev/null
  codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}")"
  echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${codename} stable" > /etc/apt/sources.list.d/docker.list
  apt-get update -y >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
  systemctl enable --now docker
  if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
    usermod -aG docker "${SUDO_USER}"
    log OK "user ${SUDO_USER} added to the docker group (re-login to apply)"
  fi
  log OK "Docker installed: $(docker --version)"
}

ensure_firewall() {
  printf '\n== Firewall (ufw) ==\n'
  if ! command -v ufw >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y ufw >/dev/null
    log OK "ufw installed"
  fi
  # Adding rules is idempotent; existing rules are never removed.
  ufw allow OpenSSH >/dev/null
  ufw allow 80/tcp >/dev/null
  ufw allow 443/tcp >/dev/null
  log OK "ufw rules ensured: OpenSSH, 80/tcp, 443/tcp"
  local ufw_status
  ufw_status="$(ufw status)"
  if [[ "$ufw_status" == *"Status: active"* ]]; then
    log SKIP "ufw already active"
  else
    ufw --force enable >/dev/null
    log OK "ufw enabled"
  fi
}

ensure_network() {
  printf '\n== Docker network ==\n'
  if docker network inspect "${NETWORK_NAME}" >/dev/null 2>&1; then
    log SKIP "network '${NETWORK_NAME}' already exists"
  else
    docker network create "${NETWORK_NAME}" >/dev/null
    log OK "network '${NETWORK_NAME}' created"
  fi
}

deploy_traefik() {
  printf '\n== Traefik ==\n'
  docker compose up -d
  log OK "compose project started"

  local waited=0 status=""
  while [ "$waited" -lt "$HEALTH_WAIT_SECONDS" ]; do
    status="$(docker inspect -f '{{.State.Health.Status}}' "${CONTAINER_NAME}" 2>/dev/null || echo starting)"
    if [ "$status" = "healthy" ]; then break; fi
    sleep "$POLL_INTERVAL"
    waited=$((waited + POLL_INTERVAL))
  done
  if [ "$status" != "healthy" ]; then
    docker logs --tail 50 "${CONTAINER_NAME}" || true
    fail "traefik did not become healthy within ${HEALTH_WAIT_SECONDS}s (status: ${status}); see the logs above"
  fi
  log OK "traefik is healthy"

  # Wait for the wildcard certificate to appear in the ACME storage.
  # A failure here is not fatal: traefik keeps serving and retrying.
  local waited_cert=0 acme=""
  while [ "$waited_cert" -lt "$CERT_WAIT_SECONDS" ]; do
    acme="$(docker compose exec -T traefik cat /letsencrypt/acme.json 2>/dev/null || true)"
    case "$acme" in
      *"*.${DOMAIN}"*) break ;;
    esac
    sleep "$POLL_INTERVAL"
    waited_cert=$((waited_cert + POLL_INTERVAL))
  done
  if [[ "$acme" == *"*.${DOMAIN}"* ]]; then
    log OK "wildcard certificate *.${DOMAIN} issued"
  else
    CERT_FAIL=1
    log FAIL "wildcard certificate not issued within ${CERT_WAIT_SECONDS}s; check 'docker logs traefik' and './scripts/check.sh' (typical cause: invalid CF_DNS_API_TOKEN). Traefik keeps running; fix .env and re-run this script."
  fi

  # Any HTTP response over TLS (even 404) proves the entry point works.
  local code
  code="$(curl -ks -o /dev/null -w '%{http_code}' --max-time 10 -H "Host: ${DOMAIN}" "https://localhost/" || true)"
  if [ -n "$code" ] && [ "$code" != "000" ]; then
    log OK "TLS on :443 responds (HTTP ${code} for Host: ${DOMAIN}; 404 is expected until sites are deployed)"
  else
    CERT_FAIL=1
    log FAIL "no TLS response on :443; check 'docker logs traefik' and './scripts/check.sh'"
  fi
}

print_summary() {
  printf '\n== Summary ==\n'
  echo "SiteHub entry container deployed (container: ${CONTAINER_NAME})."
  if [ "$DNS_WARN" -eq 1 ]; then
    echo "- Create the one-time Cloudflare record: A *.${DOMAIN} -> <this server's public IP>"
  fi
  if [ "$CERT_FAIL" -eq 1 ]; then
    echo "- Certificate/TLS check FAILED: inspect 'docker logs traefik', fix .env, then re-run this script"
  fi
  echo "- Deploy the example site:"
  echo "    cd examples/stub-site && DOMAIN=${DOMAIN} docker compose up -d"
  echo "  then open https://stub.${DOMAIN}/"
  echo "- Diagnostics at any time: ./scripts/check.sh"
}

main() {
  preflight
  ensure_docker
  ensure_firewall
  ensure_network
  deploy_traefik
  print_summary
}

main "$@"
