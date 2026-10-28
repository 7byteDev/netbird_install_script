# NetBird Server Manager

An interactive installer, updater and uninstaller for a self-hosted NetBird server on Ubuntu or Debian.

Version **3.0.3** adds component updates, complete local snapshots, snapshot recovery and a colored ASCII banner. The installer delegates deployment choices to NetBird's original interactive setup wizard.

```text

  _   _      _   ____  _         _
 | \ | | ___| |_| __ )(_)_ __ __| |
 |  \| |/ _ \ __|  _ \| | '__/ _` |
 | |\  |  __/ |_| |_) | | | | (_| |
 |_| \_|\___|\__|____/|_|_|  \__,_|
        SERVER MANAGER 3.0.8
Install | Uninstall | Update | Restore
------------------------------------------------
Developer:     Özgür Ulusoy
Website:       https://7byte.dev/
Github Repo:   https://github.com/7byteDev
------------------------------------------------

Docker stays installed during uninstall.

  [1] Install NetBird server
  [2] Uninstall NetBird server and its data
  [3] Show status
  [4] Updates and backup recovery
  [0] Exit

Select an option: 

```

## Features

- English interactive menus with cyan information, green success, yellow prompts and red errors.
- Domain input without a preset personal domain.
- System update and Docker installation when installing a new server.
- Original NetBird wizard choices: reverse proxy, optional NetBird Proxy, CrowdSec and other applicable settings.
- Independent version checks for Management, Dashboard, Proxy, Traefik and CrowdSec.
- Explicit component, release and Docker-tag selection before an update.
- A complete pre-update snapshot of configuration, persistent data and old container images.
- Recovery using the saved images and database state, including after a database migration.
- Removal of the NetBird Compose stack, optional bundled services and installation files while keeping Docker installed.
- Backups stored outside the installation directory and retained during uninstall.

## Requirements

| Requirement | Details |
| --- | --- |
| Host | Ubuntu or Debian with Bash, APT and systemd |
| Privileges | Root or `sudo` |
| Terminal | An interactive SSH/console session; run the downloaded file, not a pipe |
| Docker | Docker Engine and the Docker Compose v2 plugin |
| Update dependencies | Python 3.10+ and PyYAML (`python3-yaml`); installation is offered if missing |
| Connectivity | OS/Docker repositories, GitHub releases API and the container registry |
| Storage | Free space for configuration, data archives, saved images and headroom |

Automatic update and recovery support the **combined `netbird-server` layout with explicitly configured SQLite**, project-owned local named volumes, and files inside `/opt/netbird`. Legacy split Management/Signal/Relay layouts are detected but require a separate migration workflow.

External PostgreSQL/MySQL databases, external writable data directories, remote/custom volume drivers, anonymous/external volumes, scaled services, additional custom Compose files, symlinks and nested mounts require a tailored backup workflow. The updater stops with an explanation rather than creating an incomplete snapshot.

## Quick start

Download `install-netbird-server.sh` from this repository, review it, copy it to the server and run:

```bash
sudo bash install-netbird-server.sh
```

Optionally provide a domain as an argument; it is still shown for confirmation:

```bash
sudo bash install-netbird-server.sh netbird.example.com
```

To disable terminal colors:

```bash
sudo env NO_COLOR=1 bash install-netbird-server.sh
```

The file is self-contained. Its Python update engine is embedded in the Bash script; no additional project files are needed on the server.

## Main menu

```text
  [1] Install NetBird server
  [2] Uninstall NetBird server and its data
  [3] Show status
  [4] Updates and backup recovery
  [0] Exit
```

### Install

1. Select **1** and enter your domain without `https://`, a port or a path.
2. The script runs `apt-get update` and `apt-get upgrade`, installs prerequisites and installs Docker from its official APT repository if necessary.
3. DNS and current listeners are checked. Configure the cloud firewall/router yourself.
4. The current official NetBird setup script is downloaded and run interactively in `/opt/netbird`.
5. Choose the reverse proxy and optional services in the official wizard, then finish administrator onboarding in the dashboard.

Only the domain entered in this manager is passed as a preset wizard answer. Inherited `NETBIRD_*` preset answers are cleared in the wizard's child process so its applicable questions remain available. The manager does not force Traefik, Proxy or CrowdSec on or off.

A nonempty `/opt/netbird` is never overwritten by the install action. Use the update menu for upgrades. Installation does not reboot the host automatically and does not silently remove conflicting container-runtime packages.

### DNS and ports

Point the domain's A/AAAA records at the server. Use **DNS only** with Cloudflare for the standard direct deployment. The basic quickstart requires inbound TCP **80/443** and UDP **3478**. The optional NetBird Proxy also uses UDP **51820** in the current upstream deployment; additional published services may need additional rules.

The manager adds basic port rules to an already active UFW firewall and tags new rules `netbird-server-installer`. It does not enable UFW or configure a cloud firewall/router. Existing rules are retained. Docker-published ports can bypass UFW rules; review the provider firewall and Docker networking separately.

## Updates

Select **4 — Updates and backup recovery**:

```text
  [1] Check versions and available updates
  [2] Select components and install updates
  [3] Restore a previous backup
  [4] Configure authenticated version API
  [0] Back
```

### Version checks

The overview shows each installed component, its configured image, the latest stable upstream release and the comparison status. Management and Dashboard have **different version numbers and release cycles**; they are compared against their own releases.

Management and Dashboard versions are read **only from the authenticated `/api/instance/version` endpoint**. The manager does not substitute Docker labels/tags or GitHub releases for those two components. Traefik and CrowdSec still have separate upstream version checks; the NetBird Proxy has its own installed version command and uses the API's Management available release for coordinated updates.

The documented response provides:

| API field | Displayed meaning |
| --- | --- |
| `management_current_version` | Installed Management version |
| `management_available_version` | Available Management version |
| `dashboard_available_version` | Available Dashboard version |
| `dashboard_current_version`, if actually returned | Installed Dashboard version |

The documented example does **not** contain `dashboard_current_version`. When absent, Installed shows **Not provided by API**, and the Dashboard update status shows **Not reported by API**. Available Dashboard version is never relabelled as installed. A Dashboard target can still be explicitly selected by the operator.

### Temporary admin API token

When you select an update without a validated token in the current session, the manager first displays:

```text
ADMIN API TOKEN REQUIRED
Open your NetBird Dashboard: Team > Users > Owner User > Access Token.
Create a temporary admin access token. Set expiration to 1 day.
Copy it now; NetBird will not show the plain token again.
After the update, delete/revoke this token in the Dashboard immediately.
```

Enter the existing deployment's exact HTTPS base URL. Select **Personal access token** (`Authorization: Token`) for a token created at that Dashboard location, or **OAuth access token** (`Authorization: Bearer`) for an OAuth token. Enter the token at the hidden prompt. Submenu option **4** also allows this setup before checking versions.

The newly entered token is kept only in process memory for the current update/recovery submenu session. It is not written to disk, added to backups or printed in logs/shell commands. Leaving the submenu ends the token session. The manager reminds you to revoke the token after a successful update; it does not automatically revoke it or change its server-side expiry.

TLS validation stays enabled. HTTP redirects are rejected so the authorization header is not forwarded. HTTP 401/403, missing fields and connectivity failures are reported explicitly. A successful authenticated Management response is required before application updates proceed. Unsupported or absent API fields remain unavailable rather than guessed.

The script does not recover hashed tokens, scrape browser sessions, create tokens or reuse the distinct reverse-proxy token. Any `.manager-api.json` file created by version 3.0.2 is ignored; revoke its old token and remove that file separately. Old backups may still contain the old saved credentials.

### Install selected updates

1. Follow the temporary-token instructions when prompted, or configure the current session through submenu option **4**. Then enter component numbers separated by spaces. Nothing is preselected.
2. Choose an explicit stable target release for each component. The discovered latest stable release is offered as a default, but you can enter another stable version.
3. Confirm each Docker image tag. Dashboard, Traefik and CrowdSec normally use a `v` prefix; Management and Proxy normally omit it. Both forms are accepted if the numeric version matches the selected release. An unavailable image fails before services are stopped.
4. Review the component/image plan and type **`UPDATE`**.
5. Target images are downloaded and resolved to immutable repository digests. A small Alpine helper image is downloaded for volume archiving.
6. A complete snapshot is taken. Running project services are briefly stopped for database consistency. Previously stopped services remain stopped unless you explicitly selected them for update.
7. Only the selected services are recreated, in dependency-conscious order, using their downloaded images. Unselected previously running services are restarted with their existing containers.
8. Container state, healthchecks, restart counts and available HTTPS endpoints are checked. Verify dashboard login and actual peer connectivity yourself afterward.

Management and the optional NetBird Proxy are checked as a pair. Select matching target releases together unless the unchanged component is already known to run the same release. Dashboard is compared independently. Traefik and CrowdSec can be selected separately and are never silently included.

The updater does not run an OS upgrade, upgrade Docker, rerun NetBird's installation wizard, remove volumes or delete old images. A short maintenance interruption occurs during the snapshot and selected service recreation.

### Fixed tags and Compose overrides

The updater preserves the base Compose file and writes selected image digests to the conventional override file:

- `docker-compose.override.yml` for a `docker-compose.*` base.
- `compose.override.yaml` for a `compose.*` base.

An existing standard override is reused; its settings are preserved semantically, but YAML formatting/comments may be rewritten. More than one override file is refused to avoid an ambiguous merge. The default `docker compose` discovery reads the conventional override. If you run Compose manually with `-f`, explicitly include the override too:

```bash
cd /opt/netbird
sudo docker compose -f docker-compose.yml -f docker-compose.override.yml ps -a
```

The example assumes those filenames exist. Use your actual base/override names. Changes to the base `image:` or image variables can be masked by the override; review both files when managing tags manually.

## Backups and recovery

Snapshots are stored under:

```text
/var/backups/netbird/<UTC-timestamp>-<process-id>/
```

| Snapshot file | Contents |
| --- | --- |
| `config.tar.gz` | Installation directory, including Compose files, `.env`, server configuration, proxy token, CrowdSec configuration and bind-mounted files under the directory |
| `volumes/*.tar.gz` | Every supported data volume attached to the project containers, including Management database/keys, CrowdSec database and certificate volumes |
| `images.tar` | Previous container images and the volume helper image, saved for local recovery |
| `manifest.json` | Original service/image identities, running state and volume mount mappings |
| `checksums.json` | SHA-256 checksums of the snapshot files |
| `COMPLETE` | Marker written only after the snapshot completes |

The backup directory is root-owned with restricted permissions. **Backups contain database encryption keys, setup data, tokens and certificates. Keep them private and copy a complete snapshot off the server.** There is no automatic retention/deletion policy. Checksums detect corruption; they do not make an untrusted backup safe to import.

If the backup fails, no new application image is started and the manager attempts to restart the previously running containers. Partial backups have no `COMPLETE` marker and cannot be selected for recovery.

If an update fails after its snapshot completes, the manager offers to restore that snapshot. Restoration is an explicit choice because it replaces the current database state, including changes made after the snapshot. Downgrading only the container image may be unsafe after a database migration.

For later recovery, select **4 → 3**, choose a complete snapshot and type **`RESTORE`**. Recovery:

1. Verifies checksums and archive paths before changing the deployment.
2. Loads the saved old images before stopping current services.
3. Stops/removes project containers without deleting their volumes.
4. Preserves the current configuration in a `pre-restore-*` directory and restores the snapshot configuration.
5. Pins the saved images through local rollback tags, recreates containers without starting them and validates their volume mappings.
6. Restores volume data and starts the services recorded as running in the snapshot.

Use only trusted snapshots created for the same installation directory. External proxy configuration, external databases, cloud firewall rules and DNS are outside this local recovery workflow. The local snapshot remains available after uninstall as long as the server disk is retained.

## Uninstall

Select **2** in the main menu. Review the projects, containers, volumes and directory shown, then type **`DELETE`** to confirm permanent removal.

The manager uses `docker compose down --volumes --remove-orphans`, including the conventional override when present. It then removes any remaining resources identified by the installation's Compose project labels and verifies that no project containers, volumes or networks remain before deleting `/opt/netbird`.

The bundled `netbird-traefik`, `netbird-crowdsec`, `netbird-proxy`, `netbird-dashboard` and `netbird-server` containers are included when they belong to this installation. CrowdSec configuration, its database and Traefik/Proxy certificate volumes are included. Missing/invalid Compose files fall back to Docker project labels. Images used by the removed containers are removed only where possible without forcing deletion of images used elsewhere.

**Docker, the host NetBird client, unrelated Docker projects, update snapshots, DNS and cloud firewall rules remain.** External bind paths/volumes are displayed for manual review. An existing external reverse proxy is not treated as a bundled NetBird component. UFW cleanup targets rules tagged by this manager.

## Troubleshooting

```bash
cd /opt/netbird
sudo docker compose ps -a
sudo docker compose config --services
sudo docker compose images
sudo docker compose logs --tail=100 netbird-server
```

Do not post expanded Compose configuration, `.env`, `config.yaml`, proxy tokens or backups publicly. Use the actual service name if your configuration differs.

An HTTPS check through an external proxy can fail because of DNS, firewall, TLS or proxy configuration even when containers are running. An unauthenticated Management version endpoint returning `401`/`403` confirms an HTTP response, not successful authentication or working peer traffic. When no public address can be inferred, the manager explicitly requests a manual reachability check.

## Version 3.0.3 changes

Temporary admin-token instructions are displayed automatically before updates. Tokens remain in session memory only. Dashboard and Management version fields come exclusively from the authenticated API; missing installed Dashboard version is explicitly labelled instead of read from a different source.

## Version 3.0.2 fixes

Management version detection now uses the authenticated API exclusively. Dashboard detection validates the actual image version/source labels. API credentials are entered interactively and validated before saving.

## Version 3.0.1 fixes

Only the action description is left-aligned; SERVER MANAGER remains indented beneath the logo. The update menu now uses separate read/write descriptors for `/dev/tty`, avoiding the `File or stream is not seekable` error. An unavailable/closed terminal exits the submenu instead of repeating an error indefinitely. Ctrl+C returns without a Python traceback. A script assembly issue affecting the domain validator was also corrected.

## Validation

```bash
bash -n install-netbird-server.sh
python3 -m unittest discover -s tests -v
```

Tests use real pseudo-terminals for input/menu regression checks, and temporary directories with a fake Docker interface for update and uninstall scenarios. They cover version handling, selections, cancellation, update/restore, database/key preservation, previously stopped services, snapshot failures, corrupt archives, shared storage, external databases, override settings and uninstall recovery scenarios. They do not contact a live Docker daemon. The test fake models a trusted backup directory so the suite also runs without root.

A complete live Docker deployment and real peer connection have **not** been tested in the authoring environment. Validate on a disposable instance before relying on the recovery workflow for your server. No live server is modified merely by downloading these files.

## References

- [NetBird self-hosting quickstart](https://docs.netbird.io/selfhosted/selfhosted-quickstart)
- [NetBird upgrade guide](https://docs.netbird.io/selfhosted/maintenance/upgrade)
- [NetBird backup and restore guide](https://docs.netbird.io/selfhosted/maintenance/backup)
- [Original NetBird installer](https://github.com/netbirdio/netbird/blob/main/infrastructure_files/getting-started.sh)
- [Docker Compose file merging](https://docs.docker.com/compose/how-tos/multiple-compose-files/merge/)
- [Docker installation on Ubuntu](https://docs.docker.com/engine/install/ubuntu/)
- [Docker installation on Debian](https://docs.docker.com/engine/install/debian/)

This is an independent helper, not an official NetBird project. Upstream software retains its own licenses.
