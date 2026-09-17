# Komodo Periphery installer

Installs or updates [Komodo Periphery](https://github.com/moghtech/komodo) on a Linux host so it can enroll with your Komodo Core server.

The script downloads and runs the official `setup-periphery.py` installer. It does not hardcode a Core URL; you supply the address and other values at runtime.

## Prerequisites

Run this on the host that should become a Komodo server:

- root access (`sudo`)
- `curl`, `python3`, `systemctl`
- Docker daemon running

Create an enabled onboarding key in **Komodo > Settings > Onboarding** before a first-time install.

## Usage

```bash
sudo bash install-periphery.sh
```

### First-time install

The script prompts for:

| Prompt | Example | Notes |
| --- | --- | --- |
| Komodo Core address | `https://komodo.example.com` | `http://` or `https://` URL, no trailing slash required |
| Server name in Komodo | host hostname | How this machine appears in **Komodo > Servers**. Press Enter to keep the hostname |
| Onboarding key | onboarding key from Komodo | Input is hidden |

It then downloads the official installer, asks for confirmation, and starts the `periphery` systemd service.

### Existing install

If `/etc/komodo/periphery.config.toml` already exists, the script will not overwrite credentials or keys. Confirm to run the official installer as an update only.

## After install

1. Confirm the service is active: `systemctl status periphery`
2. Check **Komodo > Servers** for the new host
3. If enrollment fails: `sudo journalctl -u periphery -n 100 --no-pager`

Do not share journal output without redacting secrets.
