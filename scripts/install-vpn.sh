#!/usr/bin/env bash
# SiteHub VPN variant installer: SoftEther VPN server for sites hosted on
# a Windows machine, with a local bridge into the Docker proxy network.
#
# Idempotent: every step detects prior completion and skips, so the
# script is safe to re-run. Guarantees: never deletes Docker objects,
# never edits the Docker daemon configuration, never restarts containers
# it does not own; ufw rules are only added, never removed.
#
# Usage:
#   sudo ./scripts/install-vpn.sh
#   sudo ./scripts/install-vpn.sh add-user <name> <ip>

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

SOFTETHER_DIR="${REPO_DIR}/softether"
ENV_FILE="${SOFTETHER_DIR}/.env"
COMPOSE_FILE="${SOFTETHER_DIR}/compose.yaml"
VPN_IMAGE="softethervpn/vpnserver:5.2.5188"
SOFTETHER_CONTAINER="softether"
BOOTSTRAP_CONTAINER="sitehub-vpn-bootstrap"
PROXY_NETWORK="proxy"

VPN_SUBNET="10.77.77.0/24"
VPN_PORT="8443"
BOOTSTRAP_PORT="18443"
VPN_HUB="REMOTE"
VPN_TAP="tap_vpn"

VPNCMD_TIMEOUT=10
BOOTSTRAP_WAIT_SECONDS=30
CONTAINER_WAIT_SECONDS=60
BRIDGE_WAIT_SECONDS=10
POLL_INTERVAL=2

ENV_EXISTED=0
USER_PASSWORD_GENERATED=0
BOOTSTRAP_ENDPOINT=""
BOOTSTRAP_NEEDS_PASSWORD_SET=0
VPNCMD_OUTPUT=""

log() { printf '[%s] %s\n' "$1" "$2"; }
fail() { log FAIL "$1"; exit 1; }

# vpncmd sometimes exits 0 even when the command failed, so the output
# is checked for error markers as well.
output_has_error() {
  grep -qE 'Error occurred|Command not found|failed with error code' <<< "$1"
}

# Run a prepared docker exec command line; the combined output is
# captured in VPNCMD_OUTPUT. Returns non-zero on a non-zero exit status
# (including a timeout) or on an error marker in the output.
vpncmd_exec() {
  local status=0
  VPNCMD_OUTPUT="$("$@" 2>&1)" || status=$?
  if [ "$status" -ne 0 ]; then
    return 1
  fi
  if output_has_error "$VPNCMD_OUTPUT"; then
    return 1
  fi
  return 0
}

# Must-succeed variant: on failure print the captured output and abort,
# so a partially configured server is never mistaken for a finished one.
vpncmd_do() {
  if ! vpncmd_exec "$@"; then
    printf '%s\n' "$VPNCMD_OUTPUT"
    fail "vpncmd command failed (see the output above)"
  fi
}

# Authenticated server call (one vpncmd command per invocation):
#   docker exec <container> vpncmd localhost:<port> /SERVER /PASSWORD:"$VPN_SERVER_PASSWORD" /CMD:"<command>"
# Every call is bounded by a timeout: when the credentials do not match,
# vpncmd loops on the password prompt and would otherwise hang forever.
vpncmd_server() {
  vpncmd_do docker exec "$1" timeout "$VPNCMD_TIMEOUT" vpncmd "$2" \
    /SERVER /PASSWORD:"$VPN_SERVER_PASSWORD" /CMD:"$3"
}

# Hub call:
#   docker exec <container> vpncmd localhost:<port> /SERVER /HUB:REMOTE /PASSWORD:"$VPN_HUB_PASSWORD" /CMD:"<command>"
vpncmd_hub() {
  vpncmd_do docker exec "$1" timeout "$VPNCMD_TIMEOUT" vpncmd "$2" \
    /SERVER /HUB:REMOTE /PASSWORD:"$VPN_HUB_PASSWORD" /CMD:"$3"
}

# One bounded, non-fatal attempt; used by the endpoint/credential
# detection, where a wrong combination is expected and must not abort.
vpncmd_try() {
  local container="$1" endpoint="$2" password="$3" command="$4"
  local args=(docker exec "$container" timeout "$VPNCMD_TIMEOUT" vpncmd "$endpoint" /SERVER)
  if [ -n "$password" ]; then
    args+=(/PASSWORD:"$password")
  fi
  args+=(/CMD:"$command")
  vpncmd_exec "${args[@]}"
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    fail "run as root: sudo ./scripts/install-vpn.sh"
  fi
}

require_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    fail "Docker is not installed; run 'sudo ./scripts/install.sh' first"
  fi
}

# True when the given container exists and is running.
container_running() {
  local running
  running="$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || true)"
  [ "$running" = "true" ]
}

preflight() {
  printf '\n== Preflight ==\n'
  require_root
  require_docker

  if ! docker network inspect "$PROXY_NETWORK" >/dev/null 2>&1; then
    fail "docker network '${PROXY_NETWORK}' does not exist; run 'sudo ./scripts/install.sh' first"
  fi
  log OK "docker network '${PROXY_NETWORK}' exists"

  # Port 8443 must be free unless the SoftEther container already owns
  # it (a re-run after a successful install).
  local listeners
  listeners="$(ss -Htlnp "sport = :${VPN_PORT}" || true)"
  if [ -z "$listeners" ]; then
    log OK "port ${VPN_PORT} is free"
  elif container_running "$SOFTETHER_CONTAINER"; then
    log SKIP "port ${VPN_PORT} is already owned by container '${SOFTETHER_CONTAINER}'"
  else
    printf '%s\n' "$listeners"
    fail "port ${VPN_PORT} is already in use (see the process above); free it and re-run"
  fi
}

load_vpn_env() {
  if [ ! -f "$ENV_FILE" ]; then
    fail "softether/.env not found; run 'sudo ./scripts/install-vpn.sh' first"
  fi
  set -a
  # shellcheck source=/dev/null
  . "$ENV_FILE"
  set +a
  local var
  for var in VPN_SERVER_PASSWORD VPN_HUB_PASSWORD VPN_USER_PASSWORD; do
    if [ -z "${!var:-}" ]; then
      fail "${var} is empty in softether/.env; fix it and re-run"
    fi
  done
}

ensure_env() {
  printf '\n== Secrets ==\n'
  if [ -f "$ENV_FILE" ]; then
    ENV_EXISTED=1
    load_vpn_env
    log SKIP "softether/.env already exists"
    return
  fi

  local server_password hub_password user_password
  server_password="$(openssl rand -hex 16)"
  hub_password="$(openssl rand -hex 16)"
  user_password="$(openssl rand -hex 16)"

  install -m 600 /dev/null "$ENV_FILE"
  {
    printf '# SoftEther VPN secrets (generated by install-vpn.sh).\n'
    printf '# Server administrator password (vpncmd /SERVER authentication).\n'
    printf 'VPN_SERVER_PASSWORD=%s\n' "$server_password"
    printf '# Password of the %s hub.\n' "$VPN_HUB"
    printf 'VPN_HUB_PASSWORD=%s\n' "$hub_password"
    printf '# Default password for VPN site users (site1, ...).\n'
    printf 'VPN_USER_PASSWORD=%s\n' "$user_password"
  } >> "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  load_vpn_env
  USER_PASSWORD_GENERATED=1

  log OK "softether/.env created (chmod 600)"
  printf '\n  VPN user password: %s\n' "$user_password"
  printf '  Save it for the SoftEther VPN Client on Windows.\n\n'
}

install_units() {
  printf '\n== systemd units ==\n'
  install -m 0755 "$SOFTETHER_DIR/systemd/sitehub-vpn-tap" /usr/local/sbin/sitehub-vpn-tap
  install -m 0755 "$SOFTETHER_DIR/systemd/sitehub-vpn-net" /usr/local/sbin/sitehub-vpn-net
  install -m 0644 "$SOFTETHER_DIR/systemd/sitehub-vpn-tap.service" /etc/systemd/system/sitehub-vpn-tap.service
  install -m 0644 "$SOFTETHER_DIR/systemd/sitehub-vpn-net.service" /etc/systemd/system/sitehub-vpn-net.service
  systemctl daemon-reload
  systemctl enable sitehub-vpn-tap.service sitehub-vpn-net.service >/dev/null
  # restart also starts inactive units and re-runs ExecStart, so the tap
  # interface and the host rules are re-applied on every run; 'enable
  # --now' would be a no-op for an already active RemainAfterExit unit.
  systemctl restart sitehub-vpn-tap.service sitehub-vpn-net.service
  log OK "host units installed and (re)started: sitehub-vpn-tap.service, sitehub-vpn-net.service"
}

ensure_firewall() {
  printf '\n== Firewall (ufw) ==\n'
  if ! command -v ufw >/dev/null 2>&1; then
    fail "ufw is not installed; run 'sudo ./scripts/install.sh' first"
  fi
  # Only 8443/tcp is added; existing rules are never removed.
  ufw allow "${VPN_PORT}/tcp" >/dev/null
  log OK "ufw rule ensured: ${VPN_PORT}/tcp"
}

# Poll ServerStatus until an endpoint/credential combination answers:
# localhost:443 first (a fresh server listens on 443), then
# localhost:8443 (a server configured by an earlier run keeps only
# 8443). Per endpoint the credential form expected from the previous
# state is tried first, then the other one. The first combination that
# answers fixes BOOTSTRAP_ENDPOINT; answering without a password means
# the server is fresh and needs ServerPasswordSet.
detect_bootstrap_endpoint() {
  local deadline first_password second_password
  deadline=$(( $(date +%s) + BOOTSTRAP_WAIT_SECONDS ))
  if [ "$ENV_EXISTED" -eq 1 ]; then
    first_password="$VPN_SERVER_PASSWORD"
    second_password=""
  else
    first_password=""
    second_password="$VPN_SERVER_PASSWORD"
  fi
  local endpoint password
  while [ "$(date +%s)" -lt "$deadline" ]; do
    for endpoint in "localhost:443" "localhost:${VPN_PORT}"; do
      for password in "$first_password" "$second_password"; do
        if [ "$(date +%s)" -ge "$deadline" ]; then
          return 1
        fi
        if vpncmd_try "$BOOTSTRAP_CONTAINER" "$endpoint" "$password" "ServerStatus"; then
          BOOTSTRAP_ENDPOINT="$endpoint"
          BOOTSTRAP_NEEDS_PASSWORD_SET=0
          if [ -z "$password" ]; then
            BOOTSTRAP_NEEDS_PASSWORD_SET=1
          fi
          return 0
        fi
      done
    done
    sleep "$POLL_INTERVAL"
  done
  return 1
}

create_hub() {
  vpncmd_server "$BOOTSTRAP_CONTAINER" "$BOOTSTRAP_ENDPOINT" "HubList"
  if grep -qE "^Virtual Hub Name[[:space:]]*[|][[:space:]]*${VPN_HUB}[[:space:]]*$" <<< "$VPNCMD_OUTPUT"; then
    log SKIP "hub ${VPN_HUB} already exists"
    return
  fi
  vpncmd_server "$BOOTSTRAP_CONTAINER" "$BOOTSTRAP_ENDPOINT" "HubCreate REMOTE /PASSWORD:$VPN_HUB_PASSWORD"
  log OK "hub REMOTE created"
}

configure_site_user() {
  vpncmd_hub "$BOOTSTRAP_CONTAINER" "$BOOTSTRAP_ENDPOINT" "UserList"
  if grep -qE '^User Name[[:space:]]*[|][[:space:]]*site1[[:space:]]*$' <<< "$VPNCMD_OUTPUT"; then
    log SKIP "user site1 already exists"
  else
    vpncmd_hub "$BOOTSTRAP_CONTAINER" "$BOOTSTRAP_ENDPOINT" "UserCreate site1 /GROUP:none /REALNAME:none /NOTE:IPv4:10.77.77.21"
    log OK "user site1 created (fixed address 10.77.77.21)"
  fi
  vpncmd_hub "$BOOTSTRAP_CONTAINER" "$BOOTSTRAP_ENDPOINT" "UserPasswordSet site1 /PASSWORD:$VPN_USER_PASSWORD"
  vpncmd_hub "$BOOTSTRAP_CONTAINER" "$BOOTSTRAP_ENDPOINT" "UserPolicySet site1 /NAME:MultiLogins /VALUE:1"
  log OK "user site1 password and MultiLogins=1 policy ensured"
}

configure_secure_nat() {
  vpncmd_hub "$BOOTSTRAP_CONTAINER" "$BOOTSTRAP_ENDPOINT" "SecureNatEnable"
  vpncmd_hub "$BOOTSTRAP_CONTAINER" "$BOOTSTRAP_ENDPOINT" "NatDisable"
  vpncmd_hub "$BOOTSTRAP_CONTAINER" "$BOOTSTRAP_ENDPOINT" "SecureNatHostSet /MAC:none /IP:10.77.77.254 /MASK:255.255.255.0"
  vpncmd_hub "$BOOTSTRAP_CONTAINER" "$BOOTSTRAP_ENDPOINT" "DhcpSet /START:10.77.77.100 /END:10.77.77.200 /MASK:255.255.255.0 /EXPIRE:7200 /GW:none /DNS:none /DNS2:none /DOMAIN:none /LOG:yes"
  vpncmd_hub "$BOOTSTRAP_CONTAINER" "$BOOTSTRAP_ENDPOINT" "DhcpEnable"
  log OK "SecureNAT enabled (NAT off, DHCP 10.77.77.100-10.77.77.200, virtual host 10.77.77.254)"
}

configure_listeners() {
  vpncmd_server "$BOOTSTRAP_CONTAINER" "$BOOTSTRAP_ENDPOINT" "ListenerList"
  if grep -qE "^TCP[[:space:]]+${VPN_PORT}[[:space:]]*[|]" <<< "$VPNCMD_OUTPUT"; then
    log SKIP "TCP listener ${VPN_PORT} already exists"
  else
    vpncmd_server "$BOOTSTRAP_CONTAINER" "$BOOTSTRAP_ENDPOINT" "ListenerCreate 8443"
    log OK "TCP listener 8443 created"
  fi

  # The 8443 listener exists in both states; use it from here on.
  local endpoint="localhost:${VPN_PORT}"
  vpncmd_server "$BOOTSTRAP_CONTAINER" "$endpoint" "PortsUDPSet 0"
  log OK "UDP listeners disabled"

  vpncmd_server "$BOOTSTRAP_CONTAINER" "$endpoint" "ListenerList"
  local listeners="$VPNCMD_OUTPUT" port
  for port in 992 1194 5555 443; do
    if grep -qE "^TCP[[:space:]]+${port}[[:space:]]*[|]" <<< "$listeners"; then
      vpncmd_server "$BOOTSTRAP_CONTAINER" "$endpoint" "ListenerDelete ${port}"
      log OK "TCP listener ${port} deleted"
    else
      log SKIP "TCP listener ${port} already absent"
    fi
  done

  vpncmd_server "$BOOTSTRAP_CONTAINER" "$endpoint" "Flush"
  log OK "SoftEther configuration flushed"
}

export_server_cert() {
  # ServerCertGet writes the file relative to the container working
  # directory, which is the bind-mounted softether/data directory.
  vpncmd_do docker exec -w /var/lib/softether "$BOOTSTRAP_CONTAINER" timeout "$VPNCMD_TIMEOUT" vpncmd \
    "localhost:${VPN_PORT}" /SERVER /PASSWORD:"$VPN_SERVER_PASSWORD" /CMD:"ServerCertGet server.cer"
  log OK "server certificate exported to softether/data/server.cer"
}

# The temporary bootstrap container must not outlive the script: --rm
# removes it as soon as it is stopped.
cleanup_bootstrap_container() {
  if ! command -v docker >/dev/null 2>&1; then
    return
  fi
  if docker inspect "$BOOTSTRAP_CONTAINER" >/dev/null 2>&1; then
    docker stop "$BOOTSTRAP_CONTAINER" >/dev/null 2>&1 || true
  fi
}

bootstrap_softether() {
  printf '\n== SoftEther bootstrap ==\n'
  if container_running "$SOFTETHER_CONTAINER"; then
    log SKIP "container '${SOFTETHER_CONTAINER}' is already running"
    return
  fi

  mkdir -p "$SOFTETHER_DIR/data" "$SOFTETHER_DIR/logs"
  log OK "softether/data and softether/logs are ready"

  trap cleanup_bootstrap_container EXIT
  docker run -d --rm --name "$BOOTSTRAP_CONTAINER" \
    -p "127.0.0.1:${BOOTSTRAP_PORT}:443" \
    -v "$SOFTETHER_DIR/data:/var/lib/softether" \
    "$VPN_IMAGE" >/dev/null
  log OK "temporary bootstrap container started (127.0.0.1:${BOOTSTRAP_PORT} -> 443)"

  if ! detect_bootstrap_endpoint; then
    printf '%s\n' "$VPNCMD_OUTPUT"
    fail "SoftEther did not answer within ${BOOTSTRAP_WAIT_SECONDS}s (see the output above)"
  fi

  if [ "$BOOTSTRAP_NEEDS_PASSWORD_SET" -eq 1 ]; then
    vpncmd_do docker exec "$BOOTSTRAP_CONTAINER" timeout "$VPNCMD_TIMEOUT" vpncmd "$BOOTSTRAP_ENDPOINT" \
      /SERVER /CMD:"ServerPasswordSet ${VPN_SERVER_PASSWORD}"
    log OK "server administrator password set"
  else
    log SKIP "server administrator password already set"
  fi
  log OK "bootstrap endpoint: ${BOOTSTRAP_ENDPOINT}"

  create_hub
  configure_site_user
  configure_secure_nat
  configure_listeners
  export_server_cert

  docker stop "$BOOTSTRAP_CONTAINER" >/dev/null
  log OK "temporary bootstrap container stopped and removed"
}

start_softether() {
  printf '\n== SoftEther container ==\n'
  docker compose -f "$COMPOSE_FILE" up -d

  local waited=0 running=""
  while [ "$waited" -lt "$CONTAINER_WAIT_SECONDS" ]; do
    running="$(docker inspect -f '{{.State.Running}}' "$SOFTETHER_CONTAINER" 2>/dev/null || true)"
    if [ "$running" = "true" ]; then
      break
    fi
    sleep "$POLL_INTERVAL"
    waited=$((waited + POLL_INTERVAL))
  done
  if [ "$running" != "true" ]; then
    docker logs --tail 50 "$SOFTETHER_CONTAINER" 2>/dev/null || true
    fail "container '${SOFTETHER_CONTAINER}' did not start within ${CONTAINER_WAIT_SECONDS}s (see the logs above)"
  fi
  log OK "container '${SOFTETHER_CONTAINER}' is running"
}

# True when the last BridgeList output shows the tap device in the
# Operating state.
bridge_operating() {
  grep -qE '[|][[:space:]]*vpn[[:space:]]*[|][[:space:]]*Operating' <<< "$VPNCMD_OUTPUT"
}

ensure_bridge() {
  printf '\n== Local bridge ==\n'
  vpncmd_server "$SOFTETHER_CONTAINER" "localhost:${VPN_PORT}" "BridgeList"
  if bridge_operating; then
    log SKIP "bridge REMOTE <-> tap_vpn is already operating"
    return
  fi

  # BridgeCreate is a quiet no-op for an existing entry. A non-operating
  # entry recovers by itself because SoftEther reopens the tap interface
  # about once per second, so wait briefly and re-check.
  vpncmd_server "$SOFTETHER_CONTAINER" "localhost:${VPN_PORT}" "BridgeCreate REMOTE /DEVICE:vpn /TAP:yes"
  vpncmd_server "$SOFTETHER_CONTAINER" "localhost:${VPN_PORT}" "Flush"

  local waited=0
  while [ "$waited" -lt "$BRIDGE_WAIT_SECONDS" ]; do
    sleep "$POLL_INTERVAL"
    waited=$((waited + POLL_INTERVAL))
    vpncmd_server "$SOFTETHER_CONTAINER" "localhost:${VPN_PORT}" "BridgeList"
    if bridge_operating; then
      log OK "bridge REMOTE <-> tap_vpn is operating"
      return
    fi
  done
  fail "bridge device vpn is not operating; check 'ip link show ${VPN_TAP}' and re-run"
}

# Site user names appear in vpncmd commands and in Traefik route names,
# so keep them to a safe character set.
validate_user_name() {
  local name="$1"
  if [[ ! "$name" =~ ^[A-Za-z0-9_-]+$ ]]; then
    fail "invalid user name '${name}': use letters, digits, '-' and '_' only"
  fi
}

# The note address must be a fixed address inside the VPN subnet,
# outside the DHCP pool, and must not collide with the host address
# (10.77.77.1) or the SecureNAT virtual host (10.77.77.254).
validate_user_address() {
  local ip="$1"
  if [[ ! "$ip" =~ ^10\.77\.77\.(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])$ ]]; then
    fail "invalid address '${ip}': expected an IPv4 address inside ${VPN_SUBNET}"
  fi
  local last="${BASH_REMATCH[1]}"
  if [ "$last" -lt 1 ] || [ "$last" -gt 254 ]; then
    fail "invalid address '${ip}': expected a host address inside ${VPN_SUBNET} (1-254)"
  fi
  if [ "$last" -eq 1 ] || [ "$last" -eq 254 ]; then
    fail "address '${ip}' is reserved: 10.77.77.1 belongs to ${VPN_TAP}, 10.77.77.254 to SecureNAT"
  fi
  if [ "$last" -ge 100 ] && [ "$last" -le 200 ]; then
    fail "address '${ip}' is inside the DHCP pool 10.77.77.100-10.77.77.200; choose a fixed address outside the pool"
  fi
}

add_user() {
  local name="$1" ip="$2"
  printf '\n== Add VPN user ==\n'
  validate_user_name "$name"
  validate_user_address "$ip"

  if ! container_running "$SOFTETHER_CONTAINER"; then
    fail "container '${SOFTETHER_CONTAINER}' is not running; run 'sudo ./scripts/install-vpn.sh' first"
  fi
  load_vpn_env

  vpncmd_hub "$SOFTETHER_CONTAINER" "localhost:${VPN_PORT}" "UserList"
  if grep -qE "^User Name[[:space:]]*[|][[:space:]]*${name}[[:space:]]*$" <<< "$VPNCMD_OUTPUT"; then
    log SKIP "user ${name} already exists"
  else
    vpncmd_hub "$SOFTETHER_CONTAINER" "localhost:${VPN_PORT}" "UserCreate ${name} /GROUP:none /REALNAME:none /NOTE:IPv4:${ip}"
    vpncmd_hub "$SOFTETHER_CONTAINER" "localhost:${VPN_PORT}" "UserPasswordSet ${name} /PASSWORD:$VPN_USER_PASSWORD"
    vpncmd_hub "$SOFTETHER_CONTAINER" "localhost:${VPN_PORT}" "UserPolicySet ${name} /NAME:MultiLogins /VALUE:1"
    log OK "user ${name} created (fixed address ${ip})"
  fi

  printf -- '- Add the route to traefik/dynamic/vpn-sites.yml: http://%s:<port>\n' "$ip"
  printf '  Traefik watches the file and applies the route without a restart.\n'
}

print_summary() {
  printf '\n== Summary ==\n'
  local server_ip
  server_ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"

  echo "SoftEther VPN server installed (container: ${SOFTETHER_CONTAINER})."
  echo
  echo "SoftEther VPN Client parameters for Windows:"
  printf -- '- Server: %s:%s\n' "${server_ip:-IP}" "$VPN_PORT"
  printf -- '- Hub: %s\n' "$VPN_HUB"
  printf -- '- User: site1\n'
  if [ "$USER_PASSWORD_GENERATED" -eq 1 ]; then
    printf -- '- Password: %s\n' "$VPN_USER_PASSWORD"
  else
    printf -- '- Password: see VPN_USER_PASSWORD in softether/.env\n'
  fi
  printf -- '- Server certificate for pinning: softether/data/server.cer\n'
  echo
  echo "Next steps:"
  echo "- Deploy the site on Windows and add its route to traefik/dynamic/vpn-sites.yml"
  echo "- Diagnostics at any time: sudo ./scripts/check-vpn.sh"
}

usage() {
  cat <<'EOF'
Usage:
  sudo ./scripts/install-vpn.sh
      Install the SoftEther VPN server, hub REMOTE, user site1 and the
      local bridge for sites hosted on a Windows machine.
  sudo ./scripts/install-vpn.sh add-user <name> <ip>
      Add a VPN site host user with a fixed IPv4 address from the VPN
      subnet (outside the DHCP pool).
EOF
}

run_install() {
  preflight
  ensure_env
  install_units
  ensure_firewall
  bootstrap_softether
  start_softether
  ensure_bridge
  print_summary
}

run_add_user() {
  require_root
  require_docker
  add_user "$1" "$2"
}

main() {
  case "${1:-}" in
    "")
      run_install
      ;;
    add-user)
      if [ "$#" -ne 3 ]; then
        usage >&2
        exit 2
      fi
      run_add_user "$2" "$3"
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
