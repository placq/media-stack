# Perfect Media Stack Installer

An automated bash script to set up a full, self-hosted media stack with Docker, VPN integration, and Pangolin tunnel support.

## 🚀 Features

- **Automated Setup:** Installs Docker and Docker Compose (official repositories) on Ubuntu/Debian.
- **VPN Protection:** All download traffic (Transmission) is routed through a **Gluetun** container using ProtonVPN.
- **Hardware Acceleration:** Automatic detection and configuration of Intel QuickSync for Jellyfin.
- **Hardlink Support:** Pre-configures folder structure optimized for atomic moves and hardlinks.
- **Tunnel Ready:** Built-in support for **Pangolin** (via Newt) for secure remote access.
- **Automatic Updates:** Includes **What's Up Docker (WUD)** to keep your stack up to date.

## 📦 Services Included

| Icon | Service          | Description                                     |
| :--- | :--------------- | :---------------------------------------------- |
| 🎬   | **Jellyfin**     | Media Server (Alternative to Plex/Emby)         |
| 🎫   | **Jellyseerr**   | Request management for movies and TV shows      |
| 📥   | **Transmission** | BitTorrent client (protected by VPN)            |
| 🎥   | **Radarr**       | Automatic movie downloader                      |
| 📺   | **Sonarr**       | Automatic TV show downloader                    |
| 🔍   | **Prowlarr**     | Indexer manager (integrates with Radarr/Sonarr) |
| 📝   | **Bazarr**       | Automatic subtitle downloader                   |
| 🔄   | **WUD**          | Updates notifier/updater for Docker containers  |
| 🛡️   | **Gluetun**      | VPN client (OpenVPN/Wireguard)                  |

## 🛠️ Installation

1. **Transfer the script to your server:**

   ```bash
   scp install_media.sh user@your-server-ip:/root/
   ```

2. **Connect via SSH and run:**

   ```bash
   chmod +x install_media.sh
   ./install_media.sh
   ```

3. **Follow the interactive prompts** to configure your VPN, Pangolin credentials, and installation path.

## 📂 Directory Structure

The script creates a specialized structure for **Hardlinks**:

```text
/opt/media-stack/
├── config/             # Configuration for all containers
└── data/
    ├── media/          # Final library (Movies/TV)
    └── torrents/       # Incomplete and finished downloads
```

## ⚠️ Requirements

- **OS:** Ubuntu 22.04+ or Debian 11+ recommended. I use https://community-scripts.org/scripts/docker to create suitable LXC.
- **VPN:** ProtonVPN account (OpenVPN credentials required).
- **Tunnel:** Pangolin Newt ID/Secret (optional).
