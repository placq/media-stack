# Perfect Media Stack Installer

An automated bash script to set up a full, self-hosted media stack with Docker, VPN integration, and Pangolin tunnel support.

## 🚀 Features

- **Automated Setup:** Installs Docker and Docker Compose (official repositories) on Ubuntu/Debian.
- **VPN Protection:** All download traffic (Transmission) is routed through a **Gluetun** container using ProtonVPN.
- **Hardware Acceleration:** Automatic detection and configuration of Intel QuickSync for Jellyfin.
- **Hardlink Support:** Pre-configures a unified `/data` folder structure optimized for atomic moves and hardlinks.
- **Tunnel Ready:** Built-in support for **Pangolin** (via Newt) for secure remote access.
- **Cloudflare Bypass:** Includes **FlareSolverr** to assist Prowlarr in indexing protected sites.
- **Auto-generated Docs:** Creates an `important_info.md` file with all your local IP addresses, ports, and internal container communication guidelines.
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
| 🛡️   | **Gluetun**      | VPN client (OpenVPN/Wireguard)                  |
| 🧩   | **FlareSolverr** | Proxy server to bypass Cloudflare protection    |
| 🌐   | **Newt**         | Pangolin Tunnel agent for remote access         |
| 🔄   | **WUD**          | Updates notifier/updater for Docker containers  |

## 🛠️ Installation

1. **Clone the repository to your server:**

   ```bash
   git clone https://github.com/placq/media-stack.git
   cd media-stack
   ```

2. **Make the script executable and run it:**

   ```bash
   chmod +x install_media.sh
   ./install_media.sh
   ```

3. **Follow the interactive prompts** to configure your VPN, Pangolin credentials, and installation path (defaults to `/opt/media-stack`).
4. **Read the generated summary:** Once finished, the script will output essential configuration steps from `important_info.md`.

## 📂 Directory Structure

The script creates a specialized structure for **Hardlinks** to save disk space and speed up imports:

```text
/opt/media-stack/
├── config/             # App data, databases, and configuration for all containers
└── data/               # Unified volume mapped to all containers
    ├── media/          # Final organized library (Movies/TV)
    └── torrents/       # Incomplete and finished downloads
```

## ⚠️ Requirements

- **OS:** Ubuntu 22.04+ or Debian 11+ recommended. I use https://community-scripts.org/scripts/docker to create a suitable LXC.
- **VPN:** ProtonVPN account (OpenVPN credentials required).
- **Tunnel:** Pangolin Newt ID/Secret (optional).