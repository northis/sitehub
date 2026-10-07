#!/usr/bin/env bash
# SiteHub diagnostics: read-only health report for the entry container.
#
# Prints one line per check as OK/WARN/FAIL with a hint, then a summary.
# Exit code: 0 when there are no FAIL lines, 1 otherwise.
# This script never modifies the system.
#
# Usage: ./scripts/check.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

ENV_FILE=".env"
NETWORK_NAME="proxy"
CONTAINER_NAME="traefik"
ACME_MOUNTPOINT="/letsencrypt"
ACME_FILE="${ACME_MOUNTPOINT}/acme.json"
CERT_WARN_DAYS=21

COUNT_OK=0
COUNT_WARN=0
COUNT_FAIL=0

report() {
  local status="$1" name="$2" detail="$3"
  case "$status" in
    OK) COUNT_OK=$((COUNT_OK + 1)) ;;
    WARN) COUNT_WARN=$((COUNT_WARN + 1)) ;;
    FAIL) COUNT_FAIL=$((COUNT_FAIL + 1)) ;;
  esac
  printf '%-4s %-12s %s\n' "$status" "$name" "$detail"
}

require_deps() {
  local missing=()
  local dep
  for dep in docker jq openssl curl dig base64; do
    command -v "$dep" >/dev/null 2>&1 || missing+=("$dep")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    report FAIL "deps" "missing: ${missing[*]}; install with: sudo apt install jq openssl curl dnsutils"
    echo "Cannot continue without these tools."
    exit 1
  fi
}

load_domain() {
  if [ ! -f "$ENV_FILE" ]; then
    report FAIL "config" "${ENV_FILE} not found; run 'sudo ./scripts/install.sh' first"
    exit 1
  fi
  set -a
  # shellcheck source=/dev/null
  . "./${ENV_FILE}"
  set +a
  if [ -z "${DOMAIN:-}" ]; then
    report FAIL "config" "DOMAIN is empty in ${ENV_FILE}"
    exit 1
  fi
}

check_traefik() {
  if ! docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    report FAIL "traefik" "container '${CONTAINER_NAME}' does not exist; run 'sudo ./scripts/install.sh'"
    return
  fi
  local health
  health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$CONTAINER_NAME" 2>/dev/null || echo unknown)"
  if [ "$health" = "healthy" ]; then
    report OK "traefik" "container healthy"
  else
    report FAIL "traefik" "container status: ${health}; see 'docker logs ${CONTAINER_NAME}'"
  fi
}

check_ports() {
  local port listeners
  for port in 80 443; do
    listeners="$(ss -Htln "sport = :${port}" || true)"
    if [ -n "$listeners" ]; then
      report OK "port-${port}" "listening"
    else
      report FAIL "port-${port}" "nothing is listening on :${port}"
    fi
  done
}

check_network() {
  if ! docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
    report FAIL "network" "'${NETWORK_NAME}' does not exist; run 'sudo ./scripts/install.sh'"
    return
  fi
  local members
  members="$(docker network inspect "$NETWORK_NAME" --format '{{range .Containers}}{{.Name}} {{end}}' | sed 's/ $//')"
  report OK "network" "'${NETWORK_NAME}' exists; attached: ${members:-none}"
}

check_certificate() {
  local volume
  volume="$(docker inspect "$CONTAINER_NAME" --format "{{range .Mounts}}{{if eq .Destination \"${ACME_MOUNTPOINT}\"}}{{.Name}}{{end}}{{end}}" 2>/dev/null || true)"
  if [ -z "$volume" ]; then
    report FAIL "cert" "ACME volume not found on '${CONTAINER_NAME}'; is traefik deployed?"
    return
  fi
  local acme cert_b64
  acme="$(docker run --rm -v "${volume}:/data:ro" alpine cat "/data/${ACME_FILE##*/}" 2>/dev/null || true)"
  if [ -z "$acme" ]; then
    report FAIL "cert" "${ACME_FILE} is missing or empty in volume '${volume}'; check 'docker logs ${CONTAINER_NAME}' (typical cause: invalid CF_DNS_API_TOKEN)"
    return
  fi
  cert_b64="$(printf '%s' "$acme" | jq -r --arg d "*.${DOMAIN}" '[.[] | .Certificates[]? | select(.domain.main == $d)][0].certificate // empty')"
  if [ -z "$cert_b64" ]; then
    report FAIL "cert" "no certificate for *.${DOMAIN} in ACME storage; check 'docker logs ${CONTAINER_NAME}'"
    return
  fi
  local enddate end_epoch now_epoch days_left
  enddate="$(printf '%s' "$cert_b64" | base64 -d | openssl x509 -noout -enddate | cut -d= -f2)"
  end_epoch="$(date -d "$enddate" +%s)"
  now_epoch="$(date +%s)"
  days_left=$(( (end_epoch - now_epoch) / 86400 ))
  if [ "$days_left" -lt "$CERT_WARN_DAYS" ]; then
    report WARN "cert" "*.${DOMAIN} expires in ${days_left} day(s) (${enddate}); renewal should happen automatically - check 'docker logs ${CONTAINER_NAME}'"
  else
    report OK "cert" "*.${DOMAIN} valid, expires in ${days_left} day(s) (${enddate})"
  fi
}

check_dns() {
  local public_ip resolved
  public_ip="$(curl -fsS --max-time 10 https://api.ipify.org || true)"
  if [ -z "$public_ip" ]; then
    report WARN "dns" "could not detect the public IP; skipping"
    return
  fi
  resolved="$(dig +short "probe-check-${RANDOM}.${DOMAIN}" A | tail -n1 || true)"
  if [ "$resolved" = "$public_ip" ]; then
    report OK "dns" "wildcard *.${DOMAIN} resolves to ${public_ip}"
  else
    report WARN "dns" "wildcard *.${DOMAIN} resolves to '${resolved:-none}', expected ${public_ip}; create the Cloudflare record A *.${DOMAIN} -> ${public_ip}"
  fi
}

check_redirect() {
  local out code url
  out="$(curl -s -o /dev/null --max-time 10 -w '%{http_code} %{redirect_url}' -H "Host: ${DOMAIN}" "http://localhost/" || true)"
  code="${out%% *}"
  url="${out#* }"
  if [ "$code" = "301" ] || [ "$code" = "308" ]; then
    case "$url" in
      https://*) report OK "redirect" "http:// -> ${code} ${url}" ;;
      *) report FAIL "redirect" "got ${code} but Location is not https: '${url}'" ;;
    esac
  else
    report FAIL "redirect" "expected 301/308 on http://localhost/ (Host: ${DOMAIN}), got '${code:-no response}'"
  fi
}

main() {
  require_deps
  load_domain
  printf 'SiteHub diagnostics for DOMAIN=%s\n\n' "$DOMAIN"
  check_traefik
  check_ports
  check_network
  check_certificate
  check_dns
  check_redirect
  printf '\nSummary: %s OK, %s WARN, %s FAIL\n' "$COUNT_OK" "$COUNT_WARN" "$COUNT_FAIL"
  if [ "$COUNT_FAIL" -gt 0 ]; then
    exit 1
  fi
}

main "$@"
