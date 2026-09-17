#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG='/etc/komodo/periphery.config.toml'
INSTALLER_URL='https://raw.githubusercontent.com/moghtech/komodo/main/scripts/setup-periphery.py'

prompt() {
  local var_name="$1"
  local message="$2"
  local default="${3:-}"
  local value=""
  if [[ -n "$default" ]]; then
    read -r -p "$message [$default]: " value
    value="${value:-$default}"
  else
    while [[ -z "${value}" ]]; do
      read -r -p "$message: " value
      [[ -n "$value" ]] || echo 'This value is required.' >&2
    done
  fi
  printf -v "$var_name" '%s' "$value"
}

if [[ $EUID -ne 0 ]]; then
  echo 'Run with sudo: sudo bash install-periphery.sh' >&2
  exit 1
fi
for cmd in curl python3 systemctl docker; do
  command -v "$cmd" >/dev/null || { echo "Missing prerequisite: $cmd" >&2; exit 1; }
done
if ! docker info >/dev/null 2>&1; then
  echo 'Docker daemon is unavailable. Start Docker before installing Periphery.' >&2
  exit 1
fi

umask 077
if [[ -f "$CONFIG" ]]; then
  echo "Existing configuration found at $CONFIG."
  echo 'The official installer preserves it; this script will NOT overwrite credentials or keys.'
  echo 'If onboarding failed, inspect the existing config and systemd environment before retrying.'
  read -r -p 'Run the official installer to update Periphery without changing its configuration? [y/N] ' confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || exit 0
  installer=$(mktemp)
  trap 'rm -f "$installer"' EXIT
  curl -fsSL "$INSTALLER_URL" -o "$installer"
  python3 "$installer"
else
  echo 'Installing a new Komodo Periphery agent.'
  echo 'Create an enabled onboarding key in Komodo > Settings > Onboarding before continuing.'
  echo

  prompt CORE_ADDRESS 'Komodo Core address (https://host:port)'
  CORE_ADDRESS="${CORE_ADDRESS%/}"
  if [[ ! "$CORE_ADDRESS" =~ ^https?://[^[:space:]]+$ ]]; then
    echo 'Core address must be an http:// or https:// URL.' >&2
    exit 1
  fi
  if ! curl -fsSIL --max-time 15 "$CORE_ADDRESS" >/dev/null; then
    echo "Cannot reach $CORE_ADDRESS. Check DNS, HTTPS, and firewall." >&2
    exit 1
  fi

  prompt SERVER_NAME 'Server name in Komodo' "$(hostname)"
  if [[ ! "$SERVER_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
    echo 'Server name must contain only letters, numbers, dots, underscores, or hyphens.' >&2
    exit 1
  fi

  ONBOARDING_KEY=""
  while [[ -z "$ONBOARDING_KEY" ]]; do
    read -r -s -p 'Paste onboarding key (input hidden): ' ONBOARDING_KEY
    echo
    [[ -n "$ONBOARDING_KEY" ]] || echo 'This value is required.' >&2
  done

  installer=$(mktemp)
  trap 'rm -f "$installer"' EXIT
  curl -fsSL "$INSTALLER_URL" -o "$installer"
  echo "Official installer downloaded to $installer. Review it before continuing if required."
  read -r -p 'Execute the downloaded official installer? [y/N] ' confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || exit 0
  python3 "$installer" \
    --core-address="$CORE_ADDRESS" \
    --connect-as="$SERVER_NAME" \
    --onboarding-key="$ONBOARDING_KEY"
  unset ONBOARDING_KEY
fi

systemctl enable --now periphery
systemctl restart periphery
if systemctl is-active --quiet periphery; then
  echo 'Periphery service is running. Check Komodo > Servers for successful enrollment.'
else
  echo 'Periphery is not running; inspect: sudo journalctl -u periphery -n 100 --no-pager' >&2
  exit 1
fi
printf '\nRecent logs (review before sharing; redact secrets):\n'
journalctl -u periphery -n 12 --no-pager
