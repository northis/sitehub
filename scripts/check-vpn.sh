#!/usr/bin/env bash
# SiteHub VPN diagnostics: read-only health report for the SoftEther
# variant (container, tap interface, local bridge, host firewall,
# listener, sessions/DHCP and the VPN sites from the dynamic file).
#
# Prints one line per check as OK/WARN/FAIL with a hint, then a summary.
# Exit code: 0 when there are no FAIL lines, 1 otherwise.
# This script never modifies the system.
#
# Usage: sudo ./scripts/check-vpn.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

ENV_FILE="softether/.env"
SITES_FILE="traefik/dynamic/vpn-sites.yml"
CONTAINER_NAME="softether"
TAP_NAME="tap_vpn"
PROXY_NETWORK="proxy"

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

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    report FAIL "root" "iptables and ufw checks need root; run: sudo ./scripts/check-vpn.sh"
    echo "Cannot continue without root."
    exit 1
  fi
}

require_deps() {
  local missing_deps=()
  local dep
  for dep in docker ip iptables curl ufw; do
    command -v "$dep" >/dev/null 2>&1 || missing_deps+=("$dep")
  done
  if [ "${#missing_deps[@]}" -gt 0 ]; then
    report FAIL "deps" "missing: ${missing_deps[*]}; install with: sudo apt install iproute2 iptables curl ufw (docker: sudo ./scripts/install.sh)"
    echo "Cannot continue without these tools."
    exit 1
  fi
}

load_env() {
  if [ ! -f "$ENV_FILE" ]; then
    report FAIL "config" "${ENV_FILE} not found; run 'sudo ./scripts/install-vpn.sh'"
    exit 1
  fi
  set -a
  # shellcheck source=/dev/null
  . "./${ENV_FILE}"
  set +a
  local var
  for var in VPN_SERVER_PASSWORD VPN_HUB_PASSWORD; do
    if [ -z "${!var:-}" ]; then
      report FAIL "config" "${var} is empty in ${ENV_FILE}; run 'sudo ./scripts/install-vpn.sh'"
      exit 1
    fi
  done
}

# Run one server administration command through vpncmd in the container.
# Both helpers below bound the call with timeout: when the credentials do
# not match, vpncmd loops on the password prompt and would otherwise hang
# forever.
vpncmd_server() {
  docker exec softether timeout 10 vpncmd localhost:8443 /SERVER /PASSWORD:"$VPN_SERVER_PASSWORD" /CMD:"$1"
}

# Run one hub administration command through vpncmd in the container.
vpncmd_hub() {
  docker exec softether timeout 10 vpncmd localhost:8443 /SERVER /HUB:REMOTE /PASSWORD:"$VPN_HUB_PASSWORD" /CMD:"$1"
}

# Count the data lines of a vpncmd vertical table (SessionList, DhcpTable).
# The output is an 'Item|Value' header followed by one 'Name|Value' line
# per field; separators between records use '+'. The header is subtracted.
count_table_rows() {
  local output="$1" rows
  rows="$(printf '%s\n' "$output" | grep -c '|' || true)"
  if [ "$rows" -gt 0 ]; then
    rows=$((rows - 1))
  fi
  printf '%s\n' "$rows"
}

check_container() {
  if ! docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    report FAIL "container" "container '${CONTAINER_NAME}' does not exist; run 'sudo ./scripts/install-vpn.sh'"
    return
  fi
  local running
  running="$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null || true)"
  if [ "$running" = "true" ]; then
    report OK "container" "container '${CONTAINER_NAME}' is running"
  else
    report FAIL "container" "container '${CONTAINER_NAME}' is not running; start it: docker compose -f softether/compose.yaml up -d"
  fi
}

check_tap() {
  local addr
  addr="$(ip -o addr show dev "$TAP_NAME" 2>/dev/null || true)"
  if [ -z "$addr" ]; then
    report FAIL "tap" "interface '${TAP_NAME}' not found; run 'sudo ./scripts/install-vpn.sh'"
    return
  fi
  if [[ "$addr" == *"inet 10.77.77.1/24"* ]]; then
    report OK "tap" "${TAP_NAME} has 10.77.77.1/24"
  else
    report FAIL "tap" "${TAP_NAME} has no 10.77.77.1/24 address; run 'sudo ./scripts/install-vpn.sh'"
  fi
}

check_bridge() {
  local bridge_output bridge_line link_line
  bridge_output="$(vpncmd_server BridgeList 2>/dev/null || true)"
  # BridgeList rows look like '1|REMOTE|vpn|Operating'; the device column
  # is 'vpn' (SoftEther opens the host interface tap_vpn for it).
  bridge_line="$(printf '%s\n' "$bridge_output" | tr -d ' ' | grep -F '|vpn|' || true)"
  if [ -z "$bridge_line" ]; then
    report FAIL "bridge" "no 'vpn' device in BridgeList; run 'sudo ./scripts/install-vpn.sh'"
    return
  fi
  if [[ "$bridge_line" != *"|Operating"* ]]; then
    report FAIL "bridge" "device 'vpn' is not Operating; check 'docker logs ${CONTAINER_NAME}'"
    return
  fi
  link_line="$(ip -o link show dev "$TAP_NAME" 2>/dev/null || true)"
  if [[ "$link_line" == *"LOWER_UP"* ]]; then
    report OK "bridge" "device 'vpn' Operating, ${TAP_NAME} carrier up"
  else
    report FAIL "bridge" "device 'vpn' Operating but ${TAP_NAME} has no carrier; check 'docker logs ${CONTAINER_NAME}'"
  fi
}

check_listener() {
  local listener_output listener_line
  listener_output="$(vpncmd_server ListenerList 2>/dev/null || true)"
  # ListenerList rows look like 'TCP 8443    |Listening'. Match the row
  # instead of a bare port number: the vpncmd banner always contains the
  # connection port, so a substring check would never fail.
  listener_line="$(printf '%s\n' "$listener_output" | tr -d ' ' | grep -F 'TCP8443|' || true)"
  if [ -n "$listener_line" ]; then
    report OK "listener" "TCP listener 8443 is present"
  else
    report FAIL "listener" "TCP listener 8443 not found; run 'sudo ./scripts/install-vpn.sh'"
  fi
}

check_accept_rules() {
  local missing=""
  if ! iptables -C DOCKER-USER -i tap_vpn -j ACCEPT 2>/dev/null; then
    missing="${missing} -i"
  fi
  if ! iptables -C DOCKER-USER -o tap_vpn -j ACCEPT 2>/dev/null; then
    missing="${missing} -o"
  fi
  if [ -z "$missing" ]; then
    report OK "iptables" "DOCKER-USER ACCEPT rules for tap_vpn in both directions"
  else
    report FAIL "iptables" "DOCKER-USER ACCEPT missing (${missing# }); restore: sudo systemctl restart sitehub-vpn-net.service"
  fi
}

check_masquerade_rules() {
  if ! docker network inspect "$PROXY_NETWORK" >/dev/null 2>&1; then
    report WARN "masquerade" "docker network '${PROXY_NETWORK}' does not exist; cannot verify MASQUERADE rules; run 'sudo ./scripts/install.sh'"
    return
  fi
  local subnets_raw subnets missing subnet
  subnets_raw="$(docker network inspect "$PROXY_NETWORK" --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null || true)"
  read -r -a subnets <<< "$subnets_raw"
  missing=""
  for subnet in "${subnets[@]}"; do
    if ! iptables -t nat -C POSTROUTING -s "$subnet" -d 10.77.77.0/24 -o tap_vpn -j MASQUERADE 2>/dev/null; then
      missing="${missing} ${subnet}"
    fi
  done
  if [ -z "$missing" ]; then
    report OK "masquerade" "POSTROUTING MASQUERADE present for: ${subnets[*]}"
  else
    report FAIL "masquerade" "POSTROUTING MASQUERADE missing for:${missing}; restore: sudo systemctl restart sitehub-vpn-net.service"
  fi
}

check_mss_rules() {
  local missing=""
  if ! iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -o tap_vpn -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; then
    missing="${missing} -o"
  fi
  if ! iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -i tap_vpn -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; then
    missing="${missing} -i"
  fi
  if [ -z "$missing" ]; then
    report OK "mss" "TCPMSS clamp rules for tap_vpn in both directions"
  else
    report FAIL "mss" "TCPMSS clamp missing (${missing# }); restore: sudo systemctl restart sitehub-vpn-net.service"
  fi
}

check_ufw() {
  local ufw_status
  ufw_status="$(ufw status 2>/dev/null || true)"
  if [[ "$ufw_status" == *"8443/tcp"* && "$ufw_status" == *"ALLOW"* ]]; then
    report OK "ufw" "8443/tcp is allowed"
  else
    report FAIL "ufw" "8443/tcp ALLOW rule not found in 'ufw status'; run 'sudo ./scripts/install-vpn.sh'"
  fi
}

check_sessions() {
  local output rows
  output="$(vpncmd_hub SessionList 2>/dev/null || true)"
  rows="$(count_table_rows "$output")"
  report OK "sessions" "${rows} row(s) in SessionList"
}

check_dhcp() {
  local output rows
  output="$(vpncmd_hub DhcpTable 2>/dev/null || true)"
  rows="$(count_table_rows "$output")"
  report OK "dhcp" "${rows} row(s) in DhcpTable"
}

check_sites() {
  if [ ! -f "$SITES_FILE" ]; then
    report OK "sites" "no VPN sites"
    return
  fi
  local urls
  urls="$(grep -v '^[[:space:]]*#' "$SITES_FILE" | grep 'url:' | grep -oE 'http://[^"[:space:]]+' || true)"
  if [ -z "$urls" ]; then
    report OK "sites" "no VPN sites"
    return
  fi
  local url code
  while IFS= read -r url; do
    if [ -z "$url" ]; then
      continue
    fi
    code="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$url" || true)"
    if [ -n "$code" ] && [ "$code" != "000" ]; then
      report OK "site" "${url} responded with HTTP ${code}"
    else
      report FAIL "site" "${url} is unreachable; check the VPN connection, the Windows Firewall rule and the site container"
    fi
  done <<< "$urls"
}

main() {
  require_root
  require_deps
  load_env
  printf 'SiteHub VPN diagnostics\n\n'
  check_container
  check_tap
  check_bridge
  check_listener
  check_accept_rules
  check_masquerade_rules
  check_mss_rules
  check_ufw
  check_sessions
  check_dhcp
  check_sites
  printf '\nSummary: %s OK, %s WARN, %s FAIL\n' "$COUNT_OK" "$COUNT_WARN" "$COUNT_FAIL"
  if [ "$COUNT_FAIL" -gt 0 ]; then
    exit 1
  fi
}

main "$@"
