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

prompt_onboarding_key() {
  local var_name="$1"
  local value=""
  while [[ -z "$value" ]]; do
    read -r -s -p 'Paste onboarding key (input hidden): ' value
    echo
    [[ -n "$value" ]] || echo 'This value is required.' >&2
  done
  printf -v "$var_name" '%s' "$value"
}

run_official_installer() {
  local installer
  installer=$(mktemp)
  trap 'rm -f "$installer"' RETURN
  curl -fsSL "$INSTALLER_URL" -o "$installer"
  echo "Official installer downloaded to $installer. Review it before continuing if required."
  read -r -p 'Execute the downloaded official installer? [y/N] ' confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || return 1
  python3 "$installer" "$@"
}

replace_onboarding_key() {
  local key="$1"
  local backup="${CONFIG}.bak"

  cp -a "$CONFIG" "$backup"
  chmod 600 "$backup"
  echo "Backed up current config to $backup"

  PERIPHERY_CONFIG="$CONFIG" PERIPHERY_NEW_ONBOARDING_KEY="$key" python3 - <<'PY'
import os
import pathlib
import re

path = pathlib.Path(os.environ["PERIPHERY_CONFIG"])
key = os.environ["PERIPHERY_NEW_ONBOARDING_KEY"]
escaped = key.replace("\\", "\\\\").replace('"', '\\"')
new_line = f'onboarding_key = "{escaped}"'
text = path.read_text(encoding="utf-8")
active = re.compile(r"^[ \t]*onboarding_key[ \t]*=[ \t]*.*$", re.M)
commented = re.compile(r"^[ \t]*#[ \t]*onboarding_key[ \t]*=[ \t]*.*$", re.M)

if active.search(text):
    text = active.sub(new_line, text, count=1)
elif commented.search(text):
    text = commented.sub(new_line, text, count=1)
else:
    if text and not text.endswith("\n"):
        text += "\n"
    text += new_line + "\n"

path.write_text(text, encoding="utf-8")
PY
  unset PERIPHERY_NEW_ONBOARDING_KEY
  chmod 600 "$CONFIG"
  echo "Updated onboarding_key in $CONFIG"

  if systemctl show periphery -p Environment --value 2>/dev/null | grep -q 'PERIPHERY_ONBOARDING_KEY='; then
    echo 'Warning: PERIPHERY_ONBOARDING_KEY is set on the systemd unit and will override the config file.' >&2
    echo 'Remove or update that Environment value, then run: sudo systemctl daemon-reload' >&2
  fi
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
  echo 'The official installer will not overwrite this file.'
  echo
  echo 'Choose an action:'
  echo '  1) Update Periphery (keep current config)'
  echo '  2) Replace onboarding key'
  echo '  3) Update Periphery and replace onboarding key'
  echo '  4) Cancel'
  prompt ACTION 'Selection'
  case "$ACTION" in
    1)
      run_official_installer || exit 0
      ;;
    2|3)
      echo
      echo 'Create or copy an onboarding key in Komodo > Settings > Onboarding.'
      echo 'If this server is already enrolled, enable Privileged on the key or Core will reject it.'
      prompt_onboarding_key ONBOARDING_KEY
      replace_onboarding_key "$ONBOARDING_KEY"
      unset ONBOARDING_KEY
      if [[ "$ACTION" == 3 ]]; then
        run_official_installer || true
      fi
      ;;
    4)
      exit 0
      ;;
    *)
      echo 'Invalid selection.' >&2
      exit 1
      ;;
  esac
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

  prompt_onboarding_key ONBOARDING_KEY
  run_official_installer \
    --core-address="$CORE_ADDRESS" \
    --connect-as="$SERVER_NAME" \
    --onboarding-key="$ONBOARDING_KEY" || exit 0
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
