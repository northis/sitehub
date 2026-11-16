#!/usr/bin/env bash
# SiteHub VPN trigger installer: the permission flag that lets a Windows
# machine bring its SoftEther connection up only on demand, and start a
# portable AnyDesk for emergency access.
#
# Idempotent: every step detects prior completion and skips, so the script
# is safe to re-run. Guarantees: never changes an existing flag value,
# never edits the SSH configuration; only creates the flag directory, the
# vpn-window command and the read-only vpnwatch user.
#
# Usage:
#   sudo ./scripts/install-vpn-trigger.sh
#   sudo ./scripts/install-vpn-trigger.sh add-key '<ssh public key>'

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WINDOW_SOURCE="${REPO_DIR}/scripts/vpn-window"
TRIGGER_DIR="/var/lib/vpn-trigger"
FLAG_FILE="${TRIGGER_DIR}/win2.until"
WINDOW_CMD="/usr/local/sbin/vpn-window"
WATCH_USER="vpnwatch"
WATCH_HOME="/home/${WATCH_USER}"
AUTHORIZED_KEYS="${WATCH_HOME}/.ssh/authorized_keys"

log() { printf '[%s] %s\n' "$1" "$2"; }
fail() { log FAIL "$1"; exit 1; }

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    fail "run as root: sudo ./scripts/install-vpn-trigger.sh"
  fi
}

preflight() {
  printf '\n== Preflight ==\n'
  require_root
  if [ ! -f "$WINDOW_SOURCE" ]; then
    fail "${WINDOW_SOURCE} is missing; is the repository complete?"
  fi
  log OK "source files are available"
}

install_flag_dir() {
  printf '\n== Flag ==\n'
  install -d -o root -g root -m 755 "$TRIGGER_DIR"
  if [ -e "$FLAG_FILE" ]; then
    log SKIP "flag already exists: ${FLAG_FILE} = $(cat "$FLAG_FILE")"
    return
  fi
  printf '0\n' > "$FLAG_FILE"
  chmod 644 "$FLAG_FILE"
  log OK "flag created: ${FLAG_FILE} = 0 (off)"
}

install_command() {
  printf '\n== Command ==\n'
  install -m 0755 "$WINDOW_SOURCE" "$WINDOW_CMD"
  log OK "installed ${WINDOW_CMD}"
}

ensure_watch_user() {
  printf '\n== Read-only SSH user ==\n'
  if id "$WATCH_USER" >/dev/null 2>&1; then
    log SKIP "user ${WATCH_USER} already exists"
  else
    adduser --disabled-password --gecos "" --shell /bin/sh "$WATCH_USER" >/dev/null
    log OK "user ${WATCH_USER} created (no password, /bin/sh)"
  fi

  # root owns the home and .ssh: vpnwatch must not be able to lift the
  # command restriction from its own key.
  chown root:root "$WATCH_HOME"
  chmod 755 "$WATCH_HOME"
  install -d "$WATCH_HOME/.ssh"
  chown root:"$WATCH_USER" "$WATCH_HOME/.ssh"
  chmod 750 "$WATCH_HOME/.ssh"
  log OK "${WATCH_HOME}/.ssh is ready (root:${WATCH_USER} 750)"

  warn_ssh_allow_lists
}

# sshd may limit logins to AllowUsers/AllowGroups; adding vpnwatch there is
# an administrator decision, so only warn.
warn_ssh_allow_lists() {
  local files=(/etc/ssh/sshd_config /etc/ssh/sshd_config.d)
  local allow_users allow_groups
  allow_users="$(grep -RhsE '^[[:space:]]*AllowUsers[[:space:]]+' "${files[@]}" 2>/dev/null || true)"
  if [ -n "$allow_users" ] && ! grep -qw "$WATCH_USER" <<< "$allow_users"; then
    log WARN "SSH AllowUsers is set without ${WATCH_USER}: add it and run 'sshd -t && systemctl reload ssh'"
  fi
  allow_groups="$(grep -RhsE '^[[:space:]]*AllowGroups[[:space:]]+' "${files[@]}" 2>/dev/null || true)"
  if [ -n "$allow_groups" ] && ! grep -qw "$WATCH_USER" <<< "$allow_groups"; then
    log WARN "SSH AllowGroups is set without ${WATCH_USER}: add it and run 'sshd -t && systemctl reload ssh'"
  fi
}

add_key() {
  local key="$1" line

  install_flag_dir
  ensure_watch_user
  printf '\n== SSH key ==\n'

  if [[ "$key" == *$'\n'* || "$key" == *$'\r'* ]]; then
    fail "the key must be a single line"
  fi
  if [[ ! "$key" =~ ^(ssh-ed25519|sk-ssh-ed25519@openssh.com|ssh-rsa|ecdsa-sha2-nistp256)[[:space:]]+[A-Za-z0-9+/=]+([[:space:]].*)?$ ]]; then
    fail "not an SSH public key: expected 'ssh-ed25519 AAAA... comment'"
  fi

  line="restrict,command=\"/usr/bin/cat ${FLAG_FILE}\" ${key}"

  touch "$AUTHORIZED_KEYS"
  if grep -qxF -- "$line" "$AUTHORIZED_KEYS"; then
    log SKIP "key already present in ${AUTHORIZED_KEYS}"
  else
    printf '%s\n' "$line" >> "$AUTHORIZED_KEYS"
    log OK "key added: read-only access to ${FLAG_FILE}"
  fi
  chown root:"$WATCH_USER" "$AUTHORIZED_KEYS"
  chmod 640 "$AUTHORIZED_KEYS"
}

print_summary() {
  printf '\n== Summary ==\n'
  echo "VPN trigger installed."
  echo
  echo "- Flag:    ${FLAG_FILE} (0 = off, -1 = always on, -2 = portable AnyDesk, -3 = AnyDesk service)"
  echo "- Command: sudo vpn-window {-2|-1|0|1..240}"
  echo "- Reader:  user ${WATCH_USER}, key may only run 'cat ${FLAG_FILE}'"
  echo
  echo "Next steps:"
  echo "1. On Windows copy scripts/windows/Check-VpnFlag.ps1 and the portable"
  echo "   AnyDesk.exe to C:\\ProgramData\\VpnTrigger (see README)."
  echo "2. Add the Windows public key:"
  echo "   sudo ./scripts/install-vpn-trigger.sh add-key '<key>'"
  echo "3. Allow a window before enabling the scheduled task: sudo vpn-window 60"
}

usage() {
  cat <<'EOF'
Usage:
  sudo ./scripts/install-vpn-trigger.sh
      Create /var/lib/vpn-trigger/win2.until, install /usr/local/sbin/vpn-window
      and create the read-only vpnwatch user.
  sudo ./scripts/install-vpn-trigger.sh add-key '<ssh public key>'
      Allow the Windows key to read the flag only.
EOF
}

main() {
  case "${1:-}" in
    "")
      preflight
      install_flag_dir
      install_command
      ensure_watch_user
      print_summary
      ;;
    add-key)
      if [ "$#" -ne 2 ]; then
        usage >&2
        exit 2
      fi
      preflight
      add_key "$2"
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
