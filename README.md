

# NetBird Server Manager

A simple, menu-driven tool to install, update, back up, restore and uninstall a self-hosted NetBird server on Ubuntu or Debian.

<img width="619" height="340" alt="image" src="https://github.com/user-attachments/assets/bcc4dcf4-ac8d-4671-93de-8a538d2c214a" />

<div align="center">

[![Website](https://img.shields.io/badge/7byte.dev-Visit_website-168FFF?style=for-the-badge)](https://7byte.dev)
[![GitHub](https://img.shields.io/badge/GitHub-7byteDev-181717?style=for-the-badge&logo=github)](https://github.com/7byteDev)

[![Version](https://img.shields.io/badge/version-3.0.8-blue.svg)](VERSION)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

</div>

## Features

- Colored English menus and a guided installation using NetBird's official setup wizard.
- Docker installation when needed.
- Component selection with automatic update-version detection.
- Complete backups before updates, including configuration, data and previous images.
- Backup recovery and uninstall while keeping Docker installed.

## Requirements

- Ubuntu or Debian with systemd, root access or `sudo`, and an interactive terminal.
- A public domain pointing to your server. For Cloudflare, use **DNS only**.
- Inbound TCP **80/443** and UDP **3478** allowed in your firewall/router. The optional NetBird Proxy also needs UDP **51820**.
- Internet access and enough free disk space for backups.

Automatic updates and recovery support the standard combined `netbird-server` installation with local SQLite storage. External databases and custom storage need a separate backup workflow.

## Install

1. Download `install-netbird-server.sh` from this repository and copy it to your server.
2. Run it in your SSH session:

   ```bash
   sudo bash install-netbird-server.sh
   ```

3. Choose **1**, enter your domain and follow the official NetBird setup wizard.
4. Open your domain in a browser and create the administrator account.

The installation prepares the system and Docker. You choose the reverse proxy and optional services yourself. Files are stored in `/opt/netbird`. Configure cloud firewall rules separately.

## Main menu

| Option | Action |
| --- | --- |
| **1 — Install NetBird server** | Set up a new installation. |
| **2 — Uninstall NetBird server and its data** | Remove the deployment after typing `DELETE`. |
| **3 — Show status** | Display containers and installation status. |
| **4 — Updates and backup recovery** | Check/install updates or restore a backup. |
| **0 — Exit** | Close the script. |

## Updates and backup recovery

| Option | Action |
| --- | --- |
| **1 — Check and install updates** | Show versions, select components and confirm the update. |
| **2 — Restore a previous backup** | Choose a complete backup and confirm with `RESTORE`. |
| **0 — Back** | Return to the main menu. |

Select component numbers separated by spaces, for example `1 4`. Target versions and image tags are selected automatically. Review the plan and type **`UPDATE`** to continue.

**Update available** appears green; **Up to date** appears orange. Management and Dashboard use different version numbers. The table identifies each version's source: API, image metadata or container.

If everything is current, the script skips component selection. Use **U** for the update menu, **M** for the main menu or **0** to exit. These shortcuts are also available during component selection.

## Get an API token

The script needs authenticated access to NetBird's version API to read the installed Management version and available Management/Dashboard versions. The installed Dashboard version comes from its verified image metadata.

Before updating:

1. Open your **NetBird Dashboard**.
2. Go to **Team → Users → Owner User → Access Token**.
3. Create a temporary token with **1 day** validity and copy it.
4. When prompted by the script, enter your NetBird **HTTPS base URL**.
5. Select **1 — Personal access token**, then paste the token.

The token is masked immediately: only its first five characters remain visible. Press Enter to confirm. It stays in memory for the session and is not saved to disk.

**Delete/revoke the token in the Dashboard after the update.** The script reminds you but does not revoke it automatically. Never post the token publicly.

## Backups and uninstall

Backups are stored in `/var/backups/netbird`. Updates briefly stop running services to create a consistent backup, then recreate the selected components. If an update fails, the script offers recovery.

Restoring a backup replaces the current configuration and data with the saved state. Keep a private copy of complete backups off the server: they contain keys and other secrets.

Uninstall removes the NetBird containers, associated volumes and `/opt/netbird`, including bundled Traefik and CrowdSec when installed. **Docker, unrelated deployments and update backups are kept.** DNS and cloud firewall rules remain under your control.

## Troubleshooting

```bash
cd /opt/netbird
docker compose ps -a
docker compose logs --tail=50
```

For API errors, check the HTTPS address, certificate, token expiry and permissions. Do not share secrets from configuration files or backups.

---

Independent helper using the [official NetBird installer](https://docs.netbird.io/selfhosted/selfhosted-quickstart).

## References

- [NetBird self-hosting quickstart](https://docs.netbird.io/selfhosted/selfhosted-quickstart)
- [NetBird upgrade guide](https://docs.netbird.io/selfhosted/maintenance/upgrade)
- [NetBird backup and restore guide](https://docs.netbird.io/selfhosted/maintenance/backup)
- [Original NetBird installer](https://github.com/netbirdio/netbird/blob/main/infrastructure_files/getting-started.sh)
- [Docker Compose file merging](https://docs.docker.com/compose/how-tos/multiple-compose-files/merge/)
- [Docker installation on Ubuntu](https://docs.docker.com/engine/install/ubuntu/)
- [Docker installation on Debian](https://docs.docker.com/engine/install/debian/)

This is an independent helper, not an official NetBird project. Upstream software retains its own licenses.
