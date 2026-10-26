# NetBird Self-Hosted Server Installer

Install a self-hosted NetBird server on Ubuntu or Debian using Docker.

## What the script does

- Updates APT package lists and upgrades installed packages.
- Installs required tools, including curl, jq, OpenSSL and htop.
- Checks domain resolution and local port availability.
- Installs Docker Engine and the Docker Compose plugin from Docker’s official APT repository.
- Enables and starts Docker.
- Opens the required ports if UFW is already active.
- Downloads and runs the official NetBird server installation assistant.

The script does not automatically reboot the server.

## Requirements

- Ubuntu or Debian with systemd.
- Root or sudo access.
- At least 1 CPU and 2 GB RAM.
- Internet access.
- A public domain pointing to the server’s public IP.
- TCP ports 80 and 443, and UDP port 3478 available.

For example:

| DNS type | Hostname | Value |
|---|---|---|
| A | netbird.example.com | Your server’s public IPv4 address |

If an AAAA record exists, it must point to a working IPv6 address on this server.

If using Cloudflare, set the record to **DNS only**.

## Firewall configuration

Allow these incoming connections in the cloud firewall and any upstream firewall:

| Protocol | Port | Source |
|---|---|---|
| TCP | 80 | Internet |
| TCP | 443 | Internet |
| UDP | 3478 | Internet |

For IPv4, the source range is `0.0.0.0/0`.

If using IPv6, configure corresponding IPv6 firewall rules.

The script cannot configure your cloud provider’s firewall. Outbound access must also permit DNS, package downloads, container downloads and HTTPS connections.

## Installation

Upload `install-netbird-server.sh` to your server, then run:

```bash
sudo bash install-netbird-server.sh
```

Replace `netbird.example.com` with your domain.

When logged in as root:

```bash
bash install-netbird-server.sh
```

You can also omit the domain and enter it when prompted:

```bash
sudo bash install-netbird-server.sh
```

Run the script interactively in a terminal.

## Installation assistant

For a new, dedicated server:

1. Select **0 — Traefik** as the reverse proxy.
2. Enter your email address for certificate notifications.
3. Answer **N** to the optional NetBird Proxy service unless you want to publish internal services to the internet.
4. Follow any remaining prompts.

Traefik handles HTTPS certificates automatically.

After installation, open:

```text
https://netbird.example.com
```

Complete the administrator account setup.

## Connect a Windows client

Install the NetBird Windows client, then open PowerShell as Administrator:

```powershell
& "C:\Program Files\NetBird\netbird.exe" up --management-url https://netbird.example.com
```

Complete the browser login using your self-hosted account.

Check the connection:

```powershell
& "C:\Program Files\NetBird\netbird.exe" status
```

## Server management

Run these commands as root, or prefix Docker commands with sudo.

### Show container status

```bash
cd /opt/netbird
docker compose ps
```

### Show recent logs

```bash
cd /opt/netbird
docker compose logs --tail=100
```

### Follow logs

```bash
cd /opt/netbird
docker compose logs -f
```

Press Ctrl+C to stop viewing logs.

### Restart services

```bash
cd /opt/netbird
docker compose restart
```

### Restart Traefik

```bash
cd /opt/netbird
docker compose restart traefik
```

## Troubleshooting

### Certificate request times out

Check that:

- The domain resolves to the server’s current public IP.
- Incoming TCP 443 is allowed.
- The cloud firewall rule applies to this VM.
- Any configured IPv6 record works.
- Cloudflare proxying is disabled for the hostname.

After correcting connectivity:

```bash
cd /opt/netbird
docker compose restart traefik
docker compose logs --since=2m traefik
```

### Windows cannot resolve the domain

Compare the default DNS answer with a public resolver:

```powershell
Resolve-DnsName netbird.example.com
Resolve-DnsName netbird.example.com -Server 1.1.1.1
```

If only the public resolver succeeds, check your local DNS server and DHCP DNS settings.

### Windows reports that the daemon is not responding

Open PowerShell as Administrator:

```powershell
& "C:\Program Files\NetBird\netbird.exe" service restart
& "C:\Program Files\NetBird\netbird.exe" status
```

View recent client logs:

```powershell
Get-Content "C:\ProgramData\netbird\client.log" -Tail 80
```

### The installer refuses to continue

The script stops when:

- `/opt/netbird` already contains files.
- Conflicting Docker or container runtime packages are installed.
- Required ports are already occupied.
- The domain cannot be resolved.
- A required installation command fails.

Inspect the reported problem before retrying. Do not delete an existing installation or its data to bypass a check.

## Backups

Back up both:

- Configuration files under `/opt/netbird`.
- Persistent data in the Docker volumes used by the deployment.

A copy of `/opt/netbird` alone does not include named Docker volume contents. Use a consistent backup method for database data.

Keep backups private because configuration and data may contain credentials and keys.

## Notes

- This installs the NetBird server stack. Enrolling the server itself as a VPN peer is a separate step.
- Existing host NetBird clients remain installed.
- Package upgrades may restart services.
- The script downloads the latest official NetBird installer, so its prompts and deployment details may change.
- Bash syntax has been checked; a complete deployment has not been tested by the script author in this environment.

## Official documentation

- NetBird: https://docs.netbird.io/selfhosted/selfhosted-quickstart
- Docker on Ubuntu: https://docs.docker.com/engine/install/ubuntu/
- Docker on Debian: https://docs.docker.com/engine/install/debian/
