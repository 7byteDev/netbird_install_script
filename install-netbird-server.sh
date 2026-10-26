#!/usr/bin/env bash
# NetBird Server Manager 2.0 — Ubuntu / Debian, systemd, Bash 4+
# Start: sudo bash install-netbird-server.sh [DOMAIN]
# Delete scope: /opt/netbird, its Compose resources and tagged UFW rules.
# Docker, other projects, the host NetBird client, DNS and cloud rules stay intact.
# No automatic reboot. Uninstall permanently deletes accounts, peers and certificates.
set -Eeuo pipefail
umask 077
readonly install_dir=/opt/netbird
RESET='' CYAN='' BLUE='' GREEN='' YELLOW='' RED='' BOLD=''
if [[ -t 1 && -z "${NO_COLOR+x}" && "${TERM:-dumb}" != dumb ]]; then
  RESET=$'\033[0m' CYAN=$'\033[36m' BLUE=$'\033[34m'
  GREEN=$'\033[32m' YELLOW=$'\033[33m' RED=$'\033[31m' BOLD=$'\033[1m'
fi
die() { printf '\n%sERROR: %s%s\n' "$RED" "$*" "$RESET" >&2; exit 1; }
step() { printf '\n%s==> %s%s\n' "$CYAN" "$*" "$RESET"; }
success() { printf '\n%s%s%s\n' "$GREEN" "$*" "$RESET"; }
trap 'printf "\n%sERROR at line %s. Operation stopped.%s\n" "$RED" "$LINENO" "$RESET" >&2' ERR

header() {
  printf '\n%s%s       ◢◤  NETBIRD%s\n' "$BOLD" "$CYAN" "$RESET"
  printf '%s       ◥◣  SERVER MANAGER  2.0%s\n' "$BLUE" "$RESET"
  printf '           Install · Uninstall · Status\n\n'
  printf '%sDocker stays installed during uninstall.%s\n\n' "$GREEN" "$RESET"
}

validate_domain() {
  local domain=$1 label
  local -a labels
  [[ ${#domain} -le 253 && "$domain" == *.* && "$domain" != *[!a-z0-9.-]* ]] || return 1
  [[ "$domain" != *. && ! "$domain" =~ ^[0-9.]+$ ]] || return 1
  IFS='.' read -r -a labels <<< "$domain"
  for label in "${labels[@]}"; do
    [[ ${#label} -ge 1 && ${#label} -le 63 && "$label" != -* && "$label" != *- ]] || return 1
  done
}

check_path() {
  [[ ! -L "$install_dir" ]] || die "$install_dir is a symlink; inspect it manually."
  [[ ! -e "$install_dir" || -d "$install_dir" ]] || die "$install_dir is not a directory."
  if [[ -d "$install_dir" ]]; then
    # Refuse nested mounts too, so host directories cannot be erased through mounts.
    local target
    while IFS= read -r target; do
      case "$target" in
        "$install_dir"|"$install_dir"/*) die "Mount found under $install_dir: $target. Unmount it first." ;;
      esac
    done < <(findmnt -rn -o TARGET)
  fi
}

install_server() {
  local domain=${1:-} label dns_ips busy codename pkg
  local -a conflicts=()
  check_path
  if [[ -d "$install_dir" ]]; then
    [[ -z "$(find "$install_dir" -mindepth 1 -maxdepth 1 -print -quit)" ]] || die "$install_dir is not empty. Check status or uninstall using the menu first."
  fi
  while :; do
    read -r -p "${YELLOW}NetBird domain [${domain:-cloud.ukm.net.tr}]: ${RESET}" answer
    domain=${answer:-${domain:-cloud.ukm.net.tr}}
    domain=${domain,,}
    if validate_domain "$domain"; then break; fi
    printf 'Invalid domain. Enter a hostname without https://, a port or a path.\n'
    domain=''
  done
if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1; then
# Do not silently remove a different container runtime or distro Docker.
conflicts=()
for pkg in docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc; do
  if [[ "$(dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null || true)" == 'install ok installed' ]]; then
    conflicts+=("$pkg")
  fi
done
[[ ${#conflicts[@]} -eq 0 ]] || die "Conflicting packages: ${conflicts[*]}. Review the Docker migration before continuing."

fi

step 'Updating the system and installing prerequisites'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get -y -o Dpkg::Options::=--force-confold upgrade
apt-get install -y ca-certificates curl jq openssl dnsutils iproute2 htop

step 'Checking DNS resolution'
dns_ips=$({ getent ahosts "$domain" || true; } | awk '{print $1}' | sort -u)
[[ -n "$dns_ips" ]] || die "$domain does not resolve. Configure DNS and run the installer again."
printf 'DNS for %s:\n%s\n' "$domain" "$dns_ips"
printf 'These addresses must point to this server (its public IP when behind NAT).\n'
printf 'Cloud firewall/router: allow inbound TCP 80/443 and UDP 3478. Use Cloudflare DNS only.\n'

step 'Checking ports for the bundled Traefik reverse proxy'
busy=$(ss -H -ltn '( sport = :80 or sport = :443 )')
[[ -z "$busy" ]] || die "TCP 80/443 already in use. Configure the existing reverse proxy separately: $busy"
busy=$(ss -H -lun 'sport = :3478')
[[ -z "$busy" ]] || die "UDP 3478 already in use: $busy"

if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1; then
step 'Installing Docker from the official APT repository'
codename=${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}
[[ -n "$codename" ]] || die 'Distribution codename could not be detected.'
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
fi
systemctl enable --now docker
docker info > /dev/null
docker compose version
docker run --rm hello-world


step 'Adding UFW rules for this installer'
install -d -m 0700 "$install_dir"
if command -v ufw >/dev/null && LC_ALL=C ufw status | grep -q '^Status: active'; then
  # Tagged rules can be identified during uninstall. Existing matching rules
  # are left unchanged by UFW and are therefore not claimed by this installer.
  for rule in 80/tcp 443/tcp 3478/udp; do
    if LC_ALL=C ufw status | awk -v r="$rule" '$1 == r && $2 == "ALLOW" { found=1 } END { exit !found }'; then
      printf 'Existing UFW rule retained: %s\n' "$rule"
    else
      ufw allow "$rule" comment netbird-server-installer
    fi
  done
else
  printf 'UFW is inactive. Allow TCP 80/443 and UDP 3478 in the cloud firewall.\n'
fi
step 'Downloading the official NetBird server installer'
install -d -m 0700 "$install_dir"
cd "$install_dir"
curl --fail --silent --show-error --location --retry 3 \
  https://github.com/netbirdio/netbird/releases/latest/download/getting-started.sh \
  -o getting-started.sh
bash -n getting-started.sh
export NETBIRD_DOMAIN="$domain"
export NETBIRD_REVERSE_PROXY_TYPE=0
export NETBIRD_ENABLE_PROXY=false
export NETBIRD_NON_INTERACTIVE=false
# Keep the official installer's email/onboarding prompts.
unset DEBIAN_FRONTEND
printf '\nIn the NetBird setup wizard:\n'
printf ' - The bundled Traefik reverse proxy handles HTTPS.\n'
printf ' - Optional NetBird Proxy is disabled for this standard VPN installation.\n'
printf ' - Complete the remaining prompts, including your certificate email.\n\n'
bash ./getting-started.sh

step 'Container status'
docker compose ps
success "NetBird setup wizard finished. Dashboard: https://$domain"
printf 'Open the dashboard to finish setting up your administrator account.\n'
printf 'Configuration and data: %s (keep secure and back up).\n' "$install_dir"
printf 'Status: cd /opt/netbird && docker compose ps\n'
printf 'Logs:   cd /opt/netbird && docker compose logs --tail=100\n'
if [[ -f /var/run/reboot-required ]]; then
  printf '\nThe system requires a reboot. Reboot manually after completing setup.\n'
fi

}

status_server() {
  if command -v docker >/dev/null && docker info >/dev/null 2>&1; then
    docker ps -a --filter label=com.docker.compose.project=netbird
    if [[ -f "$install_dir/docker-compose.yml" ]]; then
      (cd "$install_dir" && docker compose ps -a)
    fi
  else
    printf 'Docker is missing or its daemon is unavailable.\n'
  fi
  printf '\nInstallation directory: %s\n' "$install_dir"
  if [[ -d "$install_dir" ]]; then du -sh "$install_dir"; fi
}

uninstall_server() {
  check_path
  command -v docker >/dev/null || die 'Docker is missing. Installation files are retained for manual inspection.'
  docker info >/dev/null 2>&1 || die 'Docker daemon is unavailable. Start Docker and retry uninstall.'
  command -v jq >/dev/null || die 'jq is missing: apt-get install -y jq'
  local inventory project id image mountpoint row confirmation
  local -a projects=(netbird) containers=() volumes=() networks=() images=() external=() rules=()
  # Recover project identity from working-directory labels even when YAML was deleted.
  inventory=$(docker ps -aq)
  if [[ -n "$inventory" ]]; then
    while IFS= read -r id; do
      row=$(docker inspect "$id")
      if [[ "$(jq -r '.[0].Config.Labels["com.docker.compose.project.working_dir"] // ""' <<< "$row")" == "$install_dir" ]]; then
        project=$(jq -r '.[0].Config.Labels["com.docker.compose.project"] // empty' <<< "$row")
        if [[ -n "$project" ]]; then projects+=("$project"); fi
      fi
    done <<< "$inventory"
  fi
  mapfile -t projects < <(printf '%s\n' "${projects[@]}" | sort -u)
  for project in "${projects[@]}"; do
    while IFS= read -r id; do
      [[ -n "$id" ]] && containers+=("$id")
    done < <(docker ps -aq --filter "label=com.docker.compose.project=$project")
    while IFS= read -r id; do
      [[ -n "$id" ]] && volumes+=("$id")
    done < <(docker volume ls -q --filter "label=com.docker.compose.project=$project")
    while IFS= read -r id; do
      [[ -n "$id" ]] && networks+=("$id")
    done < <(docker network ls -q --filter "label=com.docker.compose.project=$project")
  done
  for id in "${containers[@]}"; do
    row=$(docker inspect "$id")
    local working_dir
    working_dir=$(jq -r '.[0].Config.Labels["com.docker.compose.project.working_dir"] // ""' <<< "$row")
    [[ -z "$working_dir" || "$working_dir" == "$install_dir" ]] || die "Project name collision: container $id belongs to $working_dir. Inspect it manually."
    images+=("$(jq -r '.[0].Image' <<< "$row")")
    # Unlabelled/external volumes or bind paths outside our install directory
    # cannot be proven exclusive to this installation. Show rather than erase them.
    while IFS= read -r mountpoint; do
      [[ -n "$mountpoint" ]] || continue
      case "$mountpoint" in
        "$install_dir"|"$install_dir"/*) ;;
        *) external+=("$mountpoint") ;;
      esac
    done < <(jq -r '.[0].Mounts[]? | select(.Type == "bind") | .Source' <<< "$row")
    while IFS= read -r mountpoint; do
      [[ -n "$mountpoint" ]] || continue
      if [[ ! " ${volumes[*]} " == *" $mountpoint "* ]]; then
        external+=("Docker volume: $mountpoint")
      fi
    done < <(jq -r '.[0].Mounts[]? | select(.Type == "volume") | .Name' <<< "$row")
  done
  if [[ -n "$inventory" ]]; then
    while IFS= read -r id; do
      [[ " ${containers[*]} " == *" $id "* ]] && continue
      row=$(docker inspect "$id")
      while IFS= read -r mountpoint; do
        case "$mountpoint" in
          "$install_dir"|"$install_dir"/*) die "Unrelated container $id mounts $mountpoint. Uninstall stopped." ;;
        esac
      done < <(jq -r '.[0].Mounts[]? | select(.Type == "bind") | .Source' <<< "$row")
    done <<< "$inventory"
  fi
  printf '\n%sPERMANENTLY DELETE:%s\n' "$RED" "$RESET"
  printf '  Directory: %s (including database, configuration and certificates)\n' "$install_dir"
  printf '  Compose projects: %s\n' "${projects[*]}"
  printf '  Container: %s\n' "${containers[*]:-none}"
  printf '  Volumes: %s\n' "${volumes[*]:-none}"
  printf '  Networks: %s\n' "${networks[*]:-none}"
  printf '  Images used by these containers, if no other container uses them.\n'
  printf '  UFW rules tagged netbird-server-installer.\n'
  if ((${#external[@]})); then
    printf '\nExternal data is retained (review ownership manually):\n'
    printf '  %s\n' "${external[@]}"
  fi
  printf '\nAccounts and registered peers will be lost. Docker and the host client stay installed.\n'
  read -r -p "${RED}Type DELETE to confirm: ${RESET}" confirmation
  [[ "$confirmation" == DELETE ]] || { printf 'Cancelled.\n'; return 0; }
  # Remove containers with their anonymous volumes. No global Docker prune.
  if ((${#containers[@]})); then docker rm -fv "${containers[@]}"; fi
  if ((${#volumes[@]})); then docker volume rm "${volumes[@]}"; fi
  if ((${#networks[@]})); then docker network rm "${networks[@]}"; fi
  if ((${#images[@]})); then
    mapfile -t images < <(printf '%s\n' "${images[@]}" | sort -u)
    for image in "${images[@]}"; do
      if [[ -z "$(docker ps -aq --filter "ancestor=$image")" ]]; then
        if ! docker image rm "$image"; then
          printf 'Image retained (for example, multiple tags): %s\n' "$image"
        fi
      fi
    done
  fi
  if command -v ufw >/dev/null; then
    # Delete only our tagged rules, highest rule number first (including IPv6).
    mapfile -t rules < <(LC_ALL=C ufw status numbered | sed -n '/# netbird-server-installer$/s/^\[[[:space:]]*\([0-9][0-9]*\)\].*/\1/p' | sort -rn)
    for id in "${rules[@]}"; do ufw --force delete "$id"; done
  fi
  check_path
  cd /
  rm -rf --one-file-system -- "$install_dir"
  success 'NetBird server removed. Docker stays installed. You can now install again.'
  printf 'Manage cloud firewall rules and DNS records separately in your provider portal.\n'
  if ((${#external[@]})); then printf 'The external data listed above has been retained.\n'; fi
}

main() {
  [[ $EUID -eq 0 ]] || die 'Run with sudo bash or as root.'
  [[ -r /etc/os-release ]] || die '/etc/os-release is missing.'
  . /etc/os-release
  case "$ID" in ubuntu|debian) ;; *) die 'Only Ubuntu and Debian are supported.' ;; esac
  [[ -d /run/systemd/system ]] || die 'A host running systemd is required.'
  [[ -t 0 ]] || die 'Run the file interactively, not through a pipe.'
  [[ $# -le 1 ]] || die 'Usage: sudo bash install-netbird-server.sh [DOMAIN]'
  # Prevent simultaneous install/uninstall operations.
  exec 9>/run/lock/netbird-server-manager.lock
  flock -n 9 || die 'Another NetBird Server Manager is already running.'
  local choice answer
  while :; do
    header
    printf '%s  [1] Install NetBird server%s\n' "$GREEN" "$RESET"
    printf '%s  [2] Uninstall NetBird server and its data%s\n' "$RED" "$RESET"
    printf '%s  [3] Show status%s\n' "$CYAN" "$RESET"
    printf '  [0] Exit\n\n'
    read -r -p "${BOLD}Select an option: ${RESET}" choice || exit 0
    case "$choice" in
      1) install_server "${1:-}" ;;
      2) uninstall_server ;;
      3) status_server ;;
      0) exit 0 ;;
      *) printf 'Please enter 0, 1, 2 or 3.\n' ;;
    esac
    read -r -p 'Press Enter to return to the menu ...' answer || exit 0
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
