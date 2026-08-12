# Media Stack Installer

An interactive installer for a self-hosted media stack on Ubuntu or Debian. It configures Docker, ProtonVPN, Pangolin, Tailscale and delayed automatic updates.

## Access model

| Service | LAN | Tailscale | Public via Pangolin |
| --- | :---: | :---: | :---: |
| Jellyfin | Yes | Yes | Yes |
| Seerr | Yes | Yes | Yes |
| Transmission | Yes | Yes | No |
| Sonarr | Yes | Yes | No |
| Radarr | Yes | Yes | No |
| Prowlarr | Yes | Yes | No |
| Bazarr | Yes | Yes | No |
| FlareSolverr | No | No | No |

Only Jellyfin and Seerr are internet-facing. Administrative applications are bound to loopback and the detected LAN address, with private remote access provided by Tailscale Serve.

## Included services

- Jellyfin
- Seerr
- Transmission routed through Gluetun and ProtonVPN
- Sonarr, Radarr, Prowlarr and Bazarr
- FlareSolverr
- Newt for Pangolin
- A restricted Docker Socket Proxy used by Newt for label discovery

Newt never receives the host Docker socket directly. Its read-only discovery traffic goes through a proxy that blocks write requests.

## Automatic updates

There is no update dashboard and no notification service. A systemd timer checks container images nightly.

- A new image must remain unchanged for seven days before installation.
- The entire stack is stopped before creating a configuration backup.
- The updater recreates the stack and waits for running/healthy containers.
- A failed startup or health check restores the configuration and previous images.
- Five configuration backups and two rollback images per service are retained.

The delay can be changed in `/opt/media-stack/.env`:

```dotenv
UPDATE_DELAY_DAYS='7'
```

## Requirements

- Ubuntu or Debian with systemd
- ProtonVPN account with OpenVPN credentials and port forwarding
- Pangolin endpoint plus Newt ID and secret
- A Tailscale account/tailnet
- Root or sudo access

Seerr uses the official `ghcr.io/seerr-team/seerr:v3` image and runs as UID/GID `1000:1000` as required by the project.

## Installation

Download the installer first so its interactive prompts continue to read from the terminal:

```bash
installer=$(mktemp)
curl -fsSL https://raw.githubusercontent.com/placq/media-stack/main/install_media.sh -o "$installer"
sudo bash "$installer"
rm -f "$installer"
```

Alternatively, clone this repository and run:

```bash
chmod +x install_media.sh
sudo ./install_media.sh
```

Tailscale may print an authentication URL during installation. Open it to add the server to your tailnet. The installer then configures private HTTPS access to every web interface using Tailscale Serve.

## Data layout

```text
/opt/media-stack/
├── .env
├── docker-compose.yml
├── update_stack.sh
├── backups/
├── config/
└── data/
    ├── media/
    │   ├── movies/
    │   └── tv/
    └── torrents/
        ├── incomplete/
        ├── movies/
        └── tv/
```

All download and library paths share a single `/data` mount, allowing Sonarr and Radarr to use hardlinks instead of copying files.

## Useful commands

```bash
cd /opt/media-stack
sudo docker compose ps
sudo systemctl status media-stack-update.timer
sudo systemctl start media-stack-update.service
sudo ./port.sh
```

Secrets are stored only in `.env`, which is created with mode `600`. Generated documentation does not contain passwords.
