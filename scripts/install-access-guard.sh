#!/usr/bin/env bash
# SiteHub Access guard installer: allows traffic to ports 80/443 on the
# external interface only from Cloudflare ranges, so Cloudflare Access
# cannot be bypassed by connecting to the server IP directly with a
# forged Host header. ufw does not filter ports published by Docker
# containers, so the rule lives in the DOCKER-USER chain.
#
# The ranges are refreshed weekly by sitehub-cf-ips-refresh.timer:
# ips-v4/ips-v6 are downloaded and the ipset sets are swapped
# atomically (see access/systemd/sitehub-cf-ips).
#
# Idempotent: every step detects prior completion and skips, so the
# script is safe to re-run. Guarantees: never deletes Docker objects,
# never edits the Docker daemon configuration; only the DOCKER-USER
# chain, the cloudflare4/cloudflare6 sets and the sitehub-cf-ips units
# are touched.
#
# Usage:
#   sudo ./scripts/install-access-guard.sh [--force]
#   sudo ./scripts/install-access-guard.sh remove

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

GUARD_DIR="${REPO_DIR}/access"
GUARD_SCRIPT="sitehub-cf-ips"
ENV_FILE=".env"
CHAIN="DOCKER-USER"
SET4="cloudflare4"
PROXY_NETWORK="proxy"
FORCE=0

log() { printf '[%s] %s\n' "$1" "$2"; }
fail() { log FAIL "$1"; exit 1; }

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    fail "run as root: sudo ./scripts/install-access-guard.sh"
  fi
}

preflight() {
  printf '\n== Preflight ==\n'
  require_root

  local dep
  for dep in docker curl iptables ip; do
    if ! command -v "$dep" >/dev/null 2>&1; then
      fail "'${dep}' not found; run 'sudo ./scripts/install.sh' first"
    fi
  done

  if ! docker network inspect "$PROXY_NETWORK" >/dev/null 2>&1; then
    fail "docker network '${PROXY_NETWORK}' does not exist; run 'sudo ./scripts/install.sh' first"
  fi

  # The DOCKER-USER chain is created by Docker; the rules need it.
  if ! iptables -n -L "$CHAIN" >/dev/null 2>&1; then
    fail "iptables chain '${CHAIN}' not found; is Docker running?"
  fi
  log OK "Docker and the ${CHAIN} chain are available"

  if [ ! -f "$ENV_FILE" ]; then
    fail "${ENV_FILE} not found; run 'sudo ./scripts/install.sh' first"
  fi
  set -a
  # shellcheck source=/dev/null
  . "./${ENV_FILE}"
  set +a
  if [ -z "${DOMAIN:-}" ]; then
    fail "DOMAIN is empty in ${ENV_FILE}"
  fi
  log OK ".env found (DOMAIN=${DOMAIN})"
}

# Enabling the guard while the wildcard record is NOT proxied through
# Cloudflare would cut every site off from the internet (all requests
# would arrive from non-Cloudflare addresses), so this is a hard stop.
check_proxied() {
  printf '\n== Preflight: DNS ==\n'
  if [ "$FORCE" -eq 1 ]; then
    log SKIP "DNS check skipped (--force)"
    return
  fi
  if ! command -v dig >/dev/null 2>&1; then
    log WARN "dig not found (apt install dnsutils); cannot verify that *.${DOMAIN} is proxied through Cloudflare"
    return
  fi
  local public_ip resolved
  public_ip="$(curl -fsS --max-time 10 https://api.ipify.org || true)"
  if [ -z "$public_ip" ]; then
    log WARN "could not detect the public IP; cannot verify that *.${DOMAIN} is proxied through Cloudflare"
    return
  fi
  resolved="$(dig +short "probe-guard-${RANDOM}.${DOMAIN}" A | tail -n1 || true)"
  if [ -z "$resolved" ]; then
    log WARN "wildcard *.${DOMAIN} does not resolve; create the Cloudflare record A *.${DOMAIN} -> ${public_ip} first"
    return
  fi
  if [ "$resolved" = "$public_ip" ]; then
    fail "wildcard *.${DOMAIN} resolves directly to this server (${resolved}), not through Cloudflare; enabling the guard now would cut the sites off from the internet. Enable the orange cloud on the A * record (see README, 'Cloudflare Access') and re-run, or pass --force"
  fi
  log OK "wildcard resolves through Cloudflare (${resolved}), not directly (${public_ip})"
}

ensure_packages() {
  printf '\n== Packages ==\n'
  if command -v ipset >/dev/null 2>&1; then
    log SKIP "ipset already installed"
    return
  fi
  DEBIAN_FRONTEND=noninteractive apt-get install -y ipset >/dev/null
  log OK "ipset installed"
}

install_files() {
  printf '\n== Files ==\n'
  install -m 0755 "${GUARD_DIR}/systemd/${GUARD_SCRIPT}" "/usr/local/sbin/${GUARD_SCRIPT}"
  install -m 0644 "${GUARD_DIR}/systemd/sitehub-cf-ips.service" /etc/systemd/system/sitehub-cf-ips.service
  install -m 0644 "${GUARD_DIR}/systemd/sitehub-cf-ips-refresh.service" /etc/systemd/system/sitehub-cf-ips-refresh.service
  install -m 0644 "${GUARD_DIR}/systemd/sitehub-cf-ips-refresh.timer" /etc/systemd/system/sitehub-cf-ips-refresh.timer
  systemctl daemon-reload
  log OK "script and units installed"
}

enable_units() {
  printf '\n== systemd units ==\n'
  systemctl enable sitehub-cf-ips.service >/dev/null
  systemctl enable --now sitehub-cf-ips-refresh.timer >/dev/null
  # restart also starts an inactive unit and re-runs ExecStart, so the
  # rules and the ranges are (re)applied on every run.
  if ! systemctl restart sitehub-cf-ips.service; then
    journalctl -u sitehub-cf-ips.service -n 20 --no-pager || true
    fail "sitehub-cf-ips.service failed (see the log above)"
  fi
  log OK "guard applied: sitehub-cf-ips.service + weekly sitehub-cf-ips-refresh.timer"
}

verify() {
  printf '\n== Verification ==\n'
  local iface ranges
  iface="$(ip -o -4 route show to default | awk '{print $5; exit}')"
  if iptables -w 5 -C "$CHAIN" -i "$iface" -p tcp -m multiport --dports 80,443 \
      -m set ! --match-set "$SET4" src -j DROP 2>/dev/null; then
    log OK "${CHAIN} rule is active (external interface: ${iface})"
  else
    fail "${CHAIN} rule is missing after install; see 'journalctl -u sitehub-cf-ips.service'"
  fi

  ranges="$(ipset save "$SET4" 2>/dev/null | grep -c '^add ' || true)"
  if [ "${ranges:-0}" -gt 0 ]; then
    log OK "${SET4} contains ${ranges} range(s)"
  else
    fail "${SET4} is empty; see 'journalctl -u sitehub-cf-ips.service'"
  fi

  if systemctl is-active --quiet sitehub-cf-ips-refresh.timer; then
    log OK "weekly refresh timer is active"
  else
    fail "sitehub-cf-ips-refresh.timer is not active; see 'systemctl status sitehub-cf-ips-refresh.timer'"
  fi
}

print_summary() {
  printf '\n== Summary ==\n'
  echo "Access guard installed: ports 80/443 on the external interface are reachable only from Cloudflare ranges."
  echo "- Weekly range refresh: systemctl list-timers sitehub-cf-ips-refresh.timer"
  echo "- Refresh log: journalctl -u sitehub-cf-ips-refresh.service"
  echo "- Rules are re-applied after 'systemctl restart docker'."
  echo "- SSH (22), VPN sites and Docker-internal traffic are not affected."
  echo "- Remove: sudo ./scripts/install-access-guard.sh remove"
  echo
  echo "Note: the filter proves only that a request came from the Cloudflare"
  echo "network, not that the visitor passed Access. See the README section"
  echo "'Cloudflare Access', subsection 'Чтобы Access не обошли напрямую'."
}

run_install() {
  preflight
  check_proxied
  ensure_packages
  install_files
  enable_units
  verify
  print_summary
}

run_remove() {
  printf '\n== Removing the Access guard ==\n'
  require_root
  # Stop the timer first so it cannot re-create the sets; the ExecStop
  # of the service removes the DOCKER-USER rules.
  systemctl disable --now sitehub-cf-ips-refresh.timer >/dev/null 2>&1 || true
  systemctl disable --now sitehub-cf-ips.service >/dev/null 2>&1 || true
  if [ -x "/usr/local/sbin/${GUARD_SCRIPT}" ]; then
    "/usr/local/sbin/${GUARD_SCRIPT}" remove
  fi
  rm -f /etc/systemd/system/sitehub-cf-ips.service \
        /etc/systemd/system/sitehub-cf-ips-refresh.service \
        /etc/systemd/system/sitehub-cf-ips-refresh.timer \
        "/usr/local/sbin/${GUARD_SCRIPT}"
  systemctl daemon-reload
  log OK "guard removed (rules, sets, units and the script)"
}

usage() {
  cat <<'EOF'
Usage:
  sudo ./scripts/install-access-guard.sh [--force]
      Allow 80/443 on the external interface only from Cloudflare ranges
      and refresh the ranges weekly (systemd timer).
      --force skips the check that the wildcard record is proxied.
  sudo ./scripts/install-access-guard.sh remove
      Remove the rules, the ipset sets, the units and the script.
EOF
}

main() {
  case "${1:-}" in
    "")
      run_install
      ;;
    --force)
      FORCE=1
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
