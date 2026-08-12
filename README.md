# Media Stack Installer

An interactive installer for a self-hosted media stack on Ubuntu or Debian, including Proxmox LXC. It configures Docker, ProtonVPN, Pangolin, Tailscale, automatic Transmission port forwarding and delayed automatic updates.

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

Newt never receives the host Docker socket directly. Its discovery traffic goes through a read-only proxy with write requests disabled.

## Proxmox LXC preparation

Tailscale is installed inside the media LXC, not on the Proxmox host. Before running the installer, execute the following on the Proxmox host, replacing `CTID` with the media container ID:

```bash
pct set CTID --dev0 /dev/net/tun
pct set CTID --features keyctl=1,nesting=1
pct stop CTID
pct start CTID
```

An unprivileged Debian or Ubuntu LXC is recommended. The installer checks systemd, TUN access and nested Docker by starting a test container, and stops with a useful error if the LXC is not ready.

Give the LXC a stable LAN address, preferably with a DHCP reservation. If its address later changes, the generated Docker port bindings must be regenerated.

## Requirements

- Ubuntu or Debian with systemd
- ProtonVPN account with OpenVPN credentials and port forwarding
- Pangolin endpoint plus Newt ID and secret
- A Tailscale account/tailnet
- Root or sudo access
- Optional: a NAS share mounted and writable inside the LXC for external configuration backups

Seerr uses the official `ghcr.io/seerr-team/seerr:v3` image and its configuration directory is owned by UID/GID `1000:1000` as required by the project.

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

Tailscale may print an authentication URL during installation. Open it to add the LXC to your tailnet. The installer configures private HTTPS access to every web interface using Tailscale Serve.

For the external backup prompt, enter an already-mounted absolute directory such as `/mnt/nas/media-stack-backups`, or leave it empty. The installer deliberately does not create that directory: this prevents a missing NAS mount from silently placing backups on the LXC disk.

After installation, restrict access to the media LXC in your tailnet policy. A practical policy grants Jellyfin and Seerr to regular household members, while ports `9091`, `7878`, `8989`, `9696` and `6767` are limited to administrators. Do not expose those administration ports through Pangolin.

## Automatic Transmission port forwarding

Gluetun obtains a forwarded port from ProtonVPN. A systemd timer reads it every minute and updates Transmission through its authenticated RPC API. Changes after a VPN reconnect are handled automatically; there is no manual helper or dashboard step.

```bash
sudo systemctl status media-stack-port-sync.timer
sudo systemctl start media-stack-port-sync.service
sudo journalctl -u media-stack-port-sync.service
```

## Automatic updates and recovery

There is no update dashboard and no notification service. A systemd timer checks container images nightly.

- A candidate image must remain unchanged for seven days before installation.
- Candidates mature independently in safe groups: Gluetun with Transmission, Newt with its socket proxy, and each remaining application separately.
- An immature update for one group does not block other groups.
- Configuration is backed up before deployment; an optional copy is placed on the mounted NAS.
- The updater requires all containers, declared health checks, the VPN and local HTTP interfaces to remain stable for 60 seconds.
- Startup failure, health failure or restart churn restores configuration and previous images automatically.
- Five local configuration backups, ten external backups and two rollback images per service are retained.
- A failed candidate is delayed again before another automatic attempt.

The delay can be changed in `/opt/media-stack/.env`:

```dotenv
UPDATE_DELAY_DAYS='7'
```

The installer also enables Debian/Ubuntu unattended security updates for the LXC itself. Container image updates and operating-system security updates are therefore handled separately.

## Jellyseerr migration

If an existing `config/jellyseerr` directory is found, the old container is stopped before its SQLite/configuration files are copied. A migration archive is created first. The old Jellyseerr container is removed only after the new Seerr container reports healthy; an installation failure restarts the old container.

## Data layout

```text
/opt/media-stack/
├── .env
├── docker-compose.yml
├── important_info.md
├── sync_transmission_port.sh
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
sudo journalctl -u media-stack-update.service
```

Secrets are stored only in `.env`, which is created with mode `600`. Generated documentation does not contain passwords.
