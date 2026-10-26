#!/usr/bin/env bash
# Self-hosted NetBird SERVER installer for Ubuntu / Debian with systemd.
# Usage: sudo bash install-netbird-server.sh netbird.your-domain.de
# Without an argument the script asks for the domain.
# Before running: DNS A/AAAA must point to this host; allow inbound
# TCP 80/443 and UDP 3478 in your cloud firewall / router.
# For Cloudflare DNS use 'DNS only'. No automatic reboot is performed.
# Existing host NetBird clients are left installed.
set -Eeuo pipefail
umask 077
trap 'printf "\nFEHLER in Zeile %s. Installation angehalten.\n" "$LINENO" >&2' ERR
die() { printf 'FEHLER: %s\n' "$*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

[[ $EUID -eq 0 ]] || die 'Bitte mit sudo bash oder als root starten.'
[[ -r /etc/os-release ]] || die '/etc/os-release fehlt.'
. /etc/os-release
case "$ID" in
  ubuntu|debian) ;;
  *) die "Unterstuetzt werden Ubuntu und Debian; erkannt: $ID" ;;
esac
[[ -d /run/systemd/system ]] || die 'Dieses Skript benoetigt einen Host mit systemd.'
[[ -t 0 ]] || die 'Interaktiv starten: bash install-netbird-server.sh DOMAIN (nicht per Pipe).'
[[ $# -le 1 ]] || die 'Aufruf: bash install-netbird-server.sh [DOMAIN]'
domain=${1:-}
if [[ -z "$domain" ]]; then
  read -r -p 'NetBird-Domain (z.B. netbird.deine-domain.de): ' domain
fi
domain=${domain,,}
[[ ${#domain} -le 253 && "$domain" == *.* && "$domain" != *[!a-z0-9.-]* ]] || die 'Nur einen Domainnamen ohne https:// oder Pfad angeben.'
IFS='.' read -r -a labels <<< "$domain"
for label in "${labels[@]}"; do
  [[ ${#label} -ge 1 && ${#label} -le 63 && "$label" != -* && "$label" != *- ]] || die 'Ungueltiger Domainname.'
done
[[ "$domain" != *. && ! "$domain" =~ ^[0-9.]+$ ]] || die 'Eine oeffentliche Domain statt einer IP angeben.'
install_dir=/opt/netbird
if [[ -e "$install_dir" ]]; then
  [[ -d "$install_dir" && ! -L "$install_dir" ]] || die "$install_dir ist kein normales Verzeichnis."
  [[ -z "$(find "$install_dir" -mindepth 1 -maxdepth 1 -print -quit)" ]] || die "$install_dir ist nicht leer. Bestehende Installation zuerst pruefen; es wird nichts ueberschrieben."
fi

# Do not silently remove a different container runtime or distro Docker.
conflicts=()
for pkg in docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc; do
  if [[ "$(dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null || true)" == 'install ok installed' ]]; then
    conflicts+=("$pkg")
  fi
done
[[ ${#conflicts[@]} -eq 0 ]] || die "Konfliktpakete vorhanden: ${conflicts[*]}. Docker-Migration bitte vorab pruefen."

step 'System aktualisieren und Voraussetzungen installieren'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get -y -o Dpkg::Options::=--force-confold upgrade
apt-get install -y ca-certificates curl jq openssl dnsutils iproute2 htop

step 'DNS-Aufloesung pruefen'
dns_ips=$(getent ahosts "$domain" | awk '{print $1}' | sort -u)
[[ -n "$dns_ips" ]] || die "$domain ist noch nicht aufloesbar. DNS setzen und Skript erneut starten."
printf 'DNS fuer %s:\n%s\n' "$domain" "$dns_ips"
printf 'Diese Adressen muessen zu diesem Server gehoeren (bei NAT zur oeffentlichen IP).\n'
printf 'Cloud-Firewall/Router: TCP 80, TCP 443 und UDP 3478 muessen erreichbar sein.\n'

step 'Ports fuer den enthaltenen Traefik-Reverse-Proxy pruefen'
busy=$(ss -H -ltn '( sport = :80 or sport = :443 )')
[[ -z "$busy" ]] || die "TCP 80/443 bereits belegt. Vorhandenen Reverse-Proxy separat konfigurieren: $busy"
busy=$(ss -H -lun 'sport = :3478')
[[ -z "$busy" ]] || die "UDP 3478 bereits belegt: $busy"

step 'Docker aus dem offiziellen APT-Repository installieren'
codename=${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}
[[ -n "$codename" ]] || die 'Distributions-Codename nicht erkannt.'
# Reuse an existing Docker source instead of creating a duplicate entry.
if ! grep -RqsE '^[[:space:]]*(deb .*|URIs:.*)https://download\.docker\.com/linux/' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null; then
  install -m 0755 -d /etc/apt/keyrings
  curl --fail --silent --show-error --location --retry 3 \
    "https://download.docker.com/linux/$ID/gpg" -o /etc/apt/keyrings/docker.asc
  chmod 0644 /etc/apt/keyrings/docker.asc
  cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/$ID
Suites: $codename
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  chmod 0644 /etc/apt/sources.list.d/docker.sources
fi
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker
docker info > /dev/null
docker compose version
docker run --rm hello-world

step 'Vorhandene aktive UFW-Firewall ergaenzen'
if command -v ufw > /dev/null && LC_ALL=C ufw status | grep -q '^Status: active'; then
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw allow 3478/udp
else
  printf 'UFW nicht aktiv. Cloud-Firewall / andere Firewall selbst pruefen.\n'
fi

step 'Offiziellen NetBird-Server-Installer herunterladen'
install -d -m 0700 "$install_dir"
cd "$install_dir"
curl --fail --silent --show-error --location --retry 3 \
  https://github.com/netbirdio/netbird/releases/latest/download/getting-started.sh \
  -o getting-started.sh
bash -n getting-started.sh
export NETBIRD_DOMAIN="$domain"
# Restore interactive prompts for the upstream installer.
unset DEBIAN_FRONTEND
printf '\nIm NetBird-Assistenten:\n'
printf ' - Bei Reverse Proxy: [0] Traefik fuer einen neuen, dedizierten Server.\n'
printf ' - Optionaler NetBird Proxy: N, falls keine internen Webdienste veroeffentlicht werden sollen.\n'
printf ' - Weitere Eingaben gemaess Assistent ausfuellen.\n\n'
bash ./getting-started.sh

step 'Containerstatus'
docker compose ps
printf '\nNetBird-Assistent beendet. Dashboard: https://%s\n' "$domain"
printf 'Dort die angezeigten Schritte zur Einrichtung des Admin-Kontos abschliessen.\n'
printf 'Konfiguration und Daten: %s (sicher aufbewahren und sichern).\n' "$install_dir"
printf 'Status: cd /opt/netbird && docker compose ps\n'
printf 'Logs:   cd /opt/netbird && docker compose logs --tail=100\n'
if [[ -f /var/run/reboot-required ]]; then
  printf '\nSystem meldet: Neustart erforderlich. Nach erfolgreicher Einrichtung manuell neu starten.\n'
fi
