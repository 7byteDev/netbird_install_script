#!/usr/bin/env bash
# NetBird Server Manager 3.0 — Ubuntu / Debian, systemd, Bash 4+
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
  printf '\n%s%s' "$BOLD" "$CYAN"
  cat <<'LOGO'
  _   _      _   ____  _         _
 | \ | | ___| |_| __ )(_)_ __ __| |
 |  \| |/ _ \ __|  _ \| | '__/ _` |
 | |\  |  __/ |_| |_) | | | | (_| |
 |_| \_|\___|\__|____/|_|_|  \__,_|
LOGO
  printf '%s%s        SERVER MANAGER 3.0%s\n' "$RESET" "$BLUE" "$RESET"
  printf '       Install | Uninstall | Update | Restore\n\n'
  printf '%sDocker stays installed during uninstall.%s\n\n' "$GREEN" "$RESET"
}

validate_doupdate_menu() {
  check_path
  command -v docker >/dev/null || die 'Docker is required for update and recovery.'
  docker info >/dev/null 2>&1 || die 'Docker daemon is not available.'
  docker compose version >/dev/null 2>&1 || die 'Docker Compose v2 is required.'
  if ! command -v python3 >/dev/null || ! python3 -c 'import yaml' >/dev/null 2>&1; then
    local answer
    read -r -p 'Update/recovery needs python3 and python3-yaml. Install these packages? (yes/no): ' answer
    case "${answer,,}" in
      y|yes) apt-get update; apt-get install -y python3 python3-yaml ;;
      *) printf 'Cancelled.\n'; return 0 ;;
    esac
  fi
  python3 - "$install_dir" <<'NETBIRD_UPDATE_PY'
"""Embedded update engine for NetBird Server Manager; Python 3.10+ and PyYAML."""
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import time
import urllib.request
import yaml

class Failure(RuntimeError):
    pass

def ask(message):
    with open('/dev/tty', 'r+') as tty:
        tty.write(message)
        tty.flush()
        answer = tty.readline()
        if not answer:
            raise Failure('Input closed; operation cancelled.')
        return answer.strip()

def semver(value):
    m = re.fullmatch(r'v?(\d+)\.(\d+)\.(\d+)', value or '')
    return tuple(map(int, m.groups())) if m else None

def repository(image):
    image = image.split('@')[0]
    head, slash, tail = image.rpartition('/')
    tail = tail.split(':')[0]
    return head + slash + tail

def safe_archive(path):
    # Validate before passing archives to tar, including link destinations.
    with tarfile.open(path, 'r:gz') as archive:
        for member in archive:
            name = Path(member.name)
            if name.is_absolute() or '..' in name.parts or member.isdev() or member.isfifo():
                raise Failure('Unsafe archive entry: ' + member.name)
            if member.issym() or member.islnk():
                link = Path(member.linkname)
                if link.is_absolute() or '..' in link.parts:
                    raise Failure('Unsupported archive link: ' + member.name)

def checksum(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()

class Manager:
    COMPONENTS = {
        'netbird-server': ('NetBird Management', 'netbirdio/netbird'),
        'management': ('NetBird Management (legacy)', 'netbirdio/netbird'),
        'dashboard': ('NetBird Dashboard', 'netbirdio/dashboard'),
        'proxy': ('NetBird Proxy', 'netbirdio/netbird'),
        'traefik': ('Traefik', 'traefik/traefik'),
        'crowdsec': ('CrowdSec', 'crowdsecurity/crowdsec'),
    }
    ORDER = {'crowdsec': 0, 'netbird-server': 1, 'management': 1,
             'traefik': 2, 'dashboard': 3, 'proxy': 4}

    def __init__(self, root, backups='/var/backups/netbird', prompt=ask):
        self.root = Path(root)
        self.backups = Path(backups)
        self.ask = prompt
        self.base = self.overlay = None
        self.project = None
        self.latest_cache = {}
        self.colors = sys.stdout.isatty() and 'NO_COLOR' not in os.environ

    def say(self, text, color=36):
        print(f'\033[{color}m{text}\033[0m' if self.colors else text, flush=True)

    def run(self, args, capture=True, check=True):
        result = subprocess.run([str(x) for x in args], text=True,
                                stdout=subprocess.PIPE if capture else None,
                                stderr=subprocess.PIPE if capture else None)
        if check and result.returncode:
            # Do not echo expanded config/env contents or credentials on failure.
            raise Failure(f'{args[0]} {args[1] if len(args)>1 else ""} failed (exit {result.returncode}).')
        return result.stdout.strip() if capture and result.returncode == 0 else ('' if capture else result.returncode)

    def docker(self, *args, **kwargs):
        return self.run(['docker', *args], **kwargs)

    def inspect(self, *ids):
        return json.loads(self.docker('inspect', *ids)) if ids else []

    def dc(self, *args, **kwargs):
        command = ['docker', 'compose', '--project-directory', self.root, '-f', self.base]
        if self.overlay and self.overlay.exists():
            command += ['-f', self.overlay]
        if self.project:
            command += ['-p', self.project]
        return self.run(command + list(args), **kwargs)

    def load(self):
        if not self.root.is_dir() or self.root.is_symlink():
            raise Failure('Installation directory missing or unsafe. Use Restore if recovering a backup.')
        candidates = [self.root / n for n in ('compose.yaml', 'compose.yml', 'docker-compose.yaml', 'docker-compose.yml') if (self.root / n).exists()]
        if len(candidates) != 1:
            raise Failure('Exactly one Compose base file is required in the installation directory.')
        self.base = candidates[0]
        overrides = [self.root / n for n in ('compose.override.yaml', 'compose.override.yml', 'docker-compose.override.yaml', 'docker-compose.override.yml') if (self.root / n).exists()]
        if len(overrides) > 1:
            raise Failure('Multiple Compose override files found; merge them before using this updater.')
        self.overlay = overrides[0] if overrides else self.root / ('docker-compose.override.yml' if self.base.name.startswith('docker-') else 'compose.override.yaml')
        for path in (self.base, self.overlay):
            if path.is_symlink():
                raise Failure('Symlinked Compose files are not supported by the updater.')
        if self.overlay.exists():
            overlay_data = yaml.safe_load(self.overlay.read_text()) or {}
            if not isinstance(overlay_data, dict) or not isinstance(overlay_data.get('services', {}), dict):
                raise Failure('Unsupported Compose override structure.')
        # Find the actual project even when COMPOSE_PROJECT_NAME was set at install.
        all_ids = self.docker('ps', '-aq').split()
        projects = {c.get('Config', {}).get('Labels', {}).get('com.docker.compose.project')
                    for c in self.inspect(*all_ids)
                    if c.get('Config', {}).get('Labels', {}).get('com.docker.compose.project.working_dir') == str(self.root)}
        projects.discard(None)
        if len(projects) > 1:
            raise Failure('Multiple projects use this directory; resolve the ambiguity first.')
        self.project = next(iter(projects), self.project)
        config = json.loads(self.dc('config', '--format', 'json'))
        self.project = self.project or config.get('name')
        if not self.project:
            raise Failure('Compose project could not be determined.')
        ids = self.docker('ps', '-aq', '--filter', 'label=com.docker.compose.project=' + self.project).split()
        self.containers = self.inspect(*ids)
        for c in self.containers:
            wd = c.get('Config', {}).get('Labels', {}).get('com.docker.compose.project.working_dir')
            if wd and wd != str(self.root):
                raise Failure('Project name collision with another installation directory.')
            files = c.get('Config', {}).get('Labels', {}).get('com.docker.compose.project.config_files', '')
            if files and any(Path(f).resolve() not in {self.base.resolve(), self.overlay.resolve()} for f in files.split(',')):
                raise Failure('This deployment uses additional Compose files. Merge them into the base/standard override before using this updater.')
        self.config = config
        self.by_service = {}
        for c in self.containers:
            if c.get('Config', {}).get('Labels', {}).get('com.docker.compose.oneoff', '').lower() == 'true':
                continue
            service = c['Config']['Labels'].get('com.docker.compose.service')
            if service in self.by_service:
                raise Failure('Scaled services are not supported by this updater.')
            if service:
                self.by_service[service] = c
        return self

    def installed(self, service):
        c = self.by_service.get(service)
        if not c:
            return 'Unknown'
        programs = {
            'netbird-server': ['/go/bin/netbird-server', '--version'],
            'management': ['/go/bin/netbird-mgmt', '--version'],
            'proxy': ['/go/bin/netbird-proxy', '--version'],
            'traefik': ['traefik', 'version'],
            'crowdsec': ['cscli', 'version'],
        }
        if service in programs and c.get('State', {}).get('Running'):
            out = self.docker('exec', c['Id'], *programs[service], check=False)
            match = re.search(r'(?<![\d.])v?(\d+\.\d+\.\d+(?:[-+][\w.-]+)?)', out)
            if match:
                return 'v' + match.group(1)
        recorded = self.root / '.netbird-manager-versions.json'
        if recorded.is_file():
            try:
                item = json.loads(recorded.read_text()).get(service, {})
                if item.get('image_id') == c['Image'] and semver(item.get('version')):
                    return 'v' + item['version'].lstrip('v')
            except (ValueError, OSError):
                pass
        # OS image labels can report e.g. Ubuntu 24.04. Never treat those as app versions.
        ref = c.get('Config', {}).get('Image', '')
        tag = ref.rsplit('/', 1)[-1].split(':', 1)[-1] if '@' not in ref and ':' in ref.rsplit('/', 1)[-1] else ''
        return 'v' + tag.lstrip('v') if semver(tag) else 'Unknown'

    def latest(self, repo):
        if repo not in self.latest_cache:
            try:
                req = urllib.request.Request('https://api.github.com/repos/' + repo + '/releases/latest', headers={'Accept': 'application/vnd.github+json', 'User-Agent': 'NetBird-Server-Manager'})
                with urllib.request.urlopen(req, timeout=12) as response:
                    release = json.load(response)
                value = release.get('tag_name', '')
                self.latest_cache[repo] = value if not release.get('prerelease') and not release.get('draft') and semver(value) else 'Unknown'
            except Exception:
                self.latest_cache[repo] = 'Unknown'
        return self.latest_cache[repo]

    def overview(self):
        self.load()
        self.services = [s for s in self.config['services'] if s in self.COMPONENTS]
        print('\n{:<4} {:<29} {:<17} {:<17} {}'.format('#', 'Component', 'Installed', 'Latest stable', 'Status'))
        for index, service in enumerate(self.services, 1):
            current = self.installed(service)
            available = self.latest(self.COMPONENTS[service][1])
            a, b = semver(current), semver(available)
            status = 'Unknown' if a is None or b is None else ('Update available' if b > a else ('Up to date' if a == b else 'Installed newer'))
            print(f'{index:<4} {self.COMPONENTS[service][0]:<29} {current:<17} {available:<17} {status}')
            print('     Image: ' + self.config['services'][service].get('image', '(not configured)'))
        for service, spec in self.config['services'].items():
            commands = spec.get('command') or []
            if not isinstance(commands, list):
                commands = [commands]
            for command in commands:
                if 'experimental.plugins.' in str(command) and '.version=' in str(command):
                    print('Plugin setting (review compatibility manually): ' + str(command))
        print('\nManagement and Dashboard have independent versions. Unknown does not mean up to date.')
        return self.services

    def selection(self, text):
        numbers = text.split()
        if not numbers or any(not n.isdigit() or not 1 <= int(n) <= len(self.services) for n in numbers):
            raise Failure('Enter one or more service numbers separated by spaces; no services were selected.')
        return list(dict.fromkeys(self.services[int(n)-1] for n in numbers))

    def validate_pair(self, targets):
        management = 'netbird-server' if 'netbird-server' in self.config['services'] else 'management'
        if 'proxy' in self.config['services'] and (management in targets or 'proxy' in targets):
            if management in targets and 'proxy' in targets:
                if semver(targets[management]) != semver(targets['proxy']):
                    raise Failure('Select matching Management and Proxy target versions.')
            else:
                # Unknown or mismatched pairs must be selected together instead of guessed.
                changed = management if management in targets else 'proxy'
                other = 'proxy' if changed == management else management
                if semver(self.installed(other)) != semver(targets[changed]):
                    raise Failure('Select Management and Proxy together with matching target versions; the unchanged version is unknown or different.')

    def preflight(self):
        if 'netbird-server' not in self.by_service or 'management' in self.config['services']:
            raise Failure('Automatic backup/update supports the combined netbird-server layout only. Legacy split-server layouts need migration first.')
        # Check the actual mounted server config, not only a guessed host filename.
        cfg = [m for m in self.by_service['netbird-server'].get('Mounts', []) if m['Destination'] == '/etc/netbird/config.yaml' and m['Type'] == 'bind']
        if len(cfg) != 1 or not Path(cfg[0]['Source']).is_file():
            raise Failure('Cannot verify the mounted Management configuration; backup stopped.')
        data = yaml.safe_load(Path(cfg[0]['Source']).read_text())
        store = (data or {}).get('store', {})
        # The combined server nests store below server; both layouts are checked.
        if not store:
            store = (data or {}).get('server', {}).get('store', {})
        if not isinstance(store, dict) or str(store.get('engine', '')).lower() != 'sqlite':
            raise Failure('Only explicitly configured SQLite storage is supported automatically. PostgreSQL/MySQL/unknown stores require database-specific backup and restore.')
        if any(c.get('State', {}).get('Paused') for c in self.containers):
            raise Failure('Unpause project containers before updating.')
        self.volumes = set()
        for c in self.containers:
            for m in c.get('Mounts', []):
                if m['Type'] == 'volume':
                    self.volumes.add(m['Name'])
                elif m['Type'] == 'bind':
                    source = Path(m['Source']).resolve()
                    if source != self.root and self.root not in source.parents:
                        if str(source) not in ('/run/docker.sock', '/var/run/docker.sock', '/etc/localtime', '/etc/timezone') or m.get('RW', False):
                            raise Failure('External bind mount needs its own backup workflow: ' + str(source))
        management_data = [m for m in self.by_service['netbird-server'].get('Mounts', []) if m['Destination'] == '/var/lib/netbird' and m['Type'] in ('volume', 'bind')]
        if not management_data:
            raise Failure('Management data is not persistently mounted; update refused.')
        for env in self.by_service['netbird-server'].get('Config', {}).get('Env', []):
            key, _, value = env.partition('=')
            if ('STORE_ENGINE' in key and value.lower() not in ('', 'sqlite')) or ('DSN' in key and value):
                raise Failure('External database environment overrides require a database-specific backup workflow.')
        # Every other container mounting these volumes could invalidate a stopped copy.
        all_ids = self.docker('ps', '-aq').split()
        own_ids = {c['Id'] for c in self.containers}
        for c in self.inspect(*all_ids):
            if c['Id'] not in own_ids and any(m.get('Name') in self.volumes for m in c.get('Mounts', [])):
                raise Failure('A data volume is shared with a container outside this project.')
        for volume in self.volumes:
            info = json.loads(self.docker('volume', 'inspect', volume))[0]
            if info.get('Driver') != 'local' or info.get('Options'):
                raise Failure('Remote or custom volume drivers need an explicit backup workflow: ' + volume)
            if info.get('Labels', {}).get('com.docker.compose.project') != self.project:
                raise Failure('External or anonymous volumes need an explicit backup workflow: ' + volume)
        if any(not c.get('Config', {}).get('Labels', {}).get('com.docker.compose.service') or c.get('Config', {}).get('Labels', {}).get('com.docker.compose.oneoff', '').lower() == 'true' for c in self.containers):
            raise Failure('Remove temporary one-off project containers before taking an update snapshot.')
        # Refuse symlinks/nested mount points in the managed directory.
        root_device = self.root.stat().st_dev
        for path in self.root.rglob('*'):
            if path.is_symlink() or path.stat().st_dev != root_device or os.path.ismount(path):
                raise Failure('Symlink or nested mount in installation directory: ' + str(path))

    def ensure_backup_root(self):
        if self.backups.is_symlink() or self.root == self.backups or self.root in self.backups.resolve().parents:
            raise Failure('Backup directory must be outside the installation directory and must not be a symlink.')
        self.backups.mkdir(mode=0o700, parents=True, exist_ok=True)
        if self.backups.stat().st_uid != 0:
            raise Failure('Backup directory must be owned by root.')
        self.backups.chmod(0o700)

    def image_override(self, images):
        original = self.overlay.read_text() if self.overlay.exists() else None
        data = yaml.safe_load(original) if original else {}
        if not isinstance(data, dict):
            raise Failure('Unsupported Compose override format.')
        data.setdefault('services', {})
        for service, image in images.items():
            data['services'].setdefault(service, {})['image'] = image
        temporary = self.overlay.with_name(self.overlay.name + '.tmp')
        temporary.write_text(yaml.safe_dump(data, sort_keys=False))
        temporary.chmod(0o600)
        temporary.replace(self.overlay)
        try:
            self.dc('config', '--quiet')
        except Exception:
            if original is None:
                self.overlay.unlink()
            else:
                self.overlay.write_text(original)
            raise

    def restart_original(self, containers, exclude=()):
        for c in containers:
            if c.get('State', {}).get('Running') and c['Config']['Labels'].get('com.docker.compose.service') not in exclude:
                if self.docker('inspect', c['Id'], check=False):
                    self.docker('start', c['Id'])

    def snapshot(self, helper):
        self.ensure_backup_root()
        # Estimate raw image + data space with headroom before any downtime.
        ids = sorted({c['Image'] for c in self.containers} | {helper})
        size = sum(json.loads(self.docker('image', 'inspect', image))[0].get('Size', 0) for image in ids)
        size += sum(p.stat().st_size for p in self.root.rglob('*') if p.is_file())
        for volume in self.volumes:
            used = self.docker('run', '--rm', '--network', 'none', '--mount', f'type=volume,src={volume},dst=/data,readonly', helper, 'du', '-sk', '/data')
            size += int(used.split()[0]) * 1024
        if shutil.disk_usage(self.backups).free < int(size * 1.3) + 64 * 1024 * 1024:
            raise Failure('Insufficient free space for a complete backup with headroom.')
        stamp = dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
        backup = self.backups / (stamp + '-' + str(os.getpid()))
        backup.mkdir(mode=0o700)
        (backup / 'volumes').mkdir(mode=0o700)
        manifest = {'format': 1, 'created_utc': stamp, 'install_dir': str(self.root), 'project': self.project,
                    'helper': helper, 'containers': [{'service': c['Config']['Labels'].get('com.docker.compose.service'), 'image_id': c['Image'], 'version': self.installed(c['Config']['Labels'].get('com.docker.compose.service')), 'running': c.get('State', {}).get('Running', False)} for c in self.containers],
                    'volumes': [{'name': v, 'archive': f'volumes/{i}.tar.gz', 'uses': [{'service': c['Config']['Labels']['com.docker.compose.service'], 'destination': m['Destination']} for c in self.containers for m in c.get('Mounts', []) if m.get('Name') == v]} for i, v in enumerate(sorted(self.volumes))]}
        self.say('Saving old images for offline recovery: ' + str(backup))
        self.docker('image', 'save', '-o', backup / 'images.tar', *ids)
        stopped = False
        try:
            running = [c['Id'] for c in self.containers if c.get('State', {}).get('Running')]
            if running:
                stopped = True
                self.docker('stop', '--time', '30', *running, capture=False)
            self.run(['tar', '--numeric-owner', '-czpf', backup / 'config.tar.gz', '-C', self.root, '.'])
            safe_archive(backup / 'config.tar.gz')
            for volume in manifest['volumes']:
                self.docker('run', '--rm', '--network', 'none', '--mount', f'type=volume,src={volume["name"]},dst=/data,readonly', '--mount', f'type=bind,src={backup / "volumes"},dst=/backup', helper, 'tar', 'czpf', '/backup/' + Path(volume['archive']).name, '-C', '/data', '.')
                safe_archive(backup / volume['archive'])
            (backup / 'manifest.json').write_text(json.dumps(manifest, indent=2))
            files = ['manifest.json', 'images.tar', 'config.tar.gz'] + [v['archive'] for v in manifest['volumes']]
            hashes = {name: checksum(backup / name) for name in files}
            (backup / 'checksums.json').write_text(json.dumps(hashes, indent=2))
            (backup / 'COMPLETE').write_text('Backup complete\n')
            self.say('Backup complete: ' + str(backup), 32)
            return backup
        except BaseException:
            if stopped:
                self.restart_original(self.containers)
            self.say('Backup incomplete; no application update was performed. Partial backup: ' + str(backup), 31)
            raise

    def health(self, services):
        deadline = time.monotonic() + 120
        stable = 0
        while time.monotonic() < deadline:
            ids = self.dc('ps', '-a', '-q', *services).split()
            containers = self.inspect(*ids)
            ready = len(containers) == len(services)
            for c in containers:
                state = c.get('State', {})
                if not state.get('Running') or state.get('Restarting') or c.get('RestartCount', 0):
                    ready = False
                if state.get('Health', {}).get('Status', 'healthy') != 'healthy':
                    ready = False
            stable = stable + 1 if ready else 0
            if stable >= 3:
                return
            time.sleep(3)
        raise Failure('Services did not reach a stable running/healthy state within 120 seconds.')

    def web_check(self):
        # HTTPS checks are observable tests, not proof of peer connectivity.
        for service in ('dashboard', 'netbird-server'):
            spec = self.config['services'].get(service, {})
            labels = spec.get('labels', {})
            for key, value in labels.items():
                if '.rule' not in key:
                    continue
                match = re.search(r'Host\(`([^`]+)`\)', value)
                if match:
                    domain = match.group(1)
                    path = '/' if service == 'dashboard' else '/api/instance/version'
                    req = urllib.request.Request('https://' + domain + path, headers={'User-Agent': 'NetBird-Server-Manager'})
                    try:
                        with urllib.request.urlopen(req, timeout=15) as response:
                            code = response.status
                    except urllib.error.HTTPError as e:
                        code = e.code
                    except Exception:
                        self.say('HTTPS check failed for ' + domain + path + '. Check DNS, certificates and reverse proxy.', 31)
                        return False
                    allowed = (200, 401, 403) if service == 'netbird-server' else (200,)
                    if code not in allowed:
                        self.say(f'HTTPS check returned HTTP {code}: {domain}{path}', 31)
                        return False
                    print(f'HTTPS reachable: {domain}{path} (HTTP {code})')
                    break
            else:
                self.say('Public HTTPS address could not be inferred for ' + service + '; verify it manually.', 33)
        return True

    def update(self):
        self.overview()
        selected = self.selection(self.ask('Select component numbers (space-separated; none preselected): '))
        targets = {}
        for service in selected:
            latest = self.latest(self.COMPONENTS[service][1])
            prompt = f'Target release for {service}' + (f' [{latest}]' if latest != 'Unknown' else '') + ': '
            value = self.ask(prompt) or (latest if latest != 'Unknown' else '')
            if not semver(value):
                raise Failure('Enter an explicit stable version, e.g. v1.2.3. No latest tag or prerelease is accepted.')
            targets[service] = value
        self.validate_pair(targets)
        self.preflight()
        planned = {}
        for service, version in targets.items():
            repo = repository(self.config['services'][service]['image'])
            tag = ('v' if service in ('dashboard', 'traefik', 'crowdsec') else '') + version.lstrip('v')
            tag_answer = self.ask(f'Docker image tag for {service} [{tag}]: ')
            if tag_answer:
                tag = tag_answer
            if semver(tag) != semver(version):
                raise Failure('The Docker tag must match the selected release (with or without a v prefix).')
            planned[service] = repo + ':' + tag
        self.say('\nUpdate plan (selected services will be started, including currently stopped services):')
        for service in selected:
            print(f'  {service}: {self.installed(service)} -> {targets[service]} ({planned[service]})')
            print('  Release notes: https://github.com/' + self.COMPONENTS[service][1] + '/releases/tag/' + targets[service])
        print('All running project services will stop briefly for a complete consistent backup.')
        print('Backup location: ' + str(self.backups) + '; Docker and OS packages are not updated.')
        if self.ask('Type UPDATE to download images, back up and apply this plan: ') != 'UPDATE':
            print('Cancelled.')
            return
        original_containers = list(self.containers)
        # Resolve downloaded releases to immutable digests before stopping anything.
        pinned, version_records = {}, {}
        for service, image in planned.items():
            self.docker('pull', image, capture=False)
            info = json.loads(self.docker('image', 'inspect', image))[0]
            digests = info.get('RepoDigests') or []
            if not digests:
                raise Failure('Downloaded image has no repository digest: ' + image)
            pinned[service] = digests[0]
            version_records[service] = {'image_id': info['Id'], 'version': targets[service]}
        self.docker('pull', 'alpine:3', capture=False)
        helper = json.loads(self.docker('image', 'inspect', 'alpine:3'))[0]['Id']
        backup = self.snapshot(helper)
        try:
            self.image_override(pinned)
            record_file = self.root / '.netbird-manager-versions.json'
            records = json.loads(record_file.read_text()) if record_file.exists() else {}
            records.update(version_records)
            record_file.write_text(json.dumps(records, indent=2))
            self.restart_original(original_containers, exclude=selected)
            for service in sorted(selected, key=lambda s: self.ORDER[s]):
                self.dc('up', '-d', '--no-deps', '--force-recreate', '--pull', 'never', service, capture=False)
                self.health([service])
            self.health([s for s in selected])
            self.load()
            for service in selected:
                observed = self.installed(service)
                if semver(observed) and semver(observed) != semver(targets[service]):
                    raise Failure('Started application version differs from the selected release: ' + service)
            if not self.web_check():
                raise Failure('The public HTTPS verification failed.')
            self.say('\nUpdate completed. Installed application versions:', 32)
            for service in selected:
                print('  ' + service + ': ' + self.installed(service))
            self.dc('ps', '-a', capture=False)
            print('Backup retained: ' + str(backup))
            print('Sign in to the dashboard and verify peers, policies, networks and a real peer connection.')
        except BaseException as error:
            self.say('Update failed: ' + str(error) + '. Backup and previous images are retained at ' + str(backup), 31)
            self.say('Database migrations may require restoring data as well as old images.', 33)
            if self.ask('Type RESTORE to restore this snapshot now, or press Enter to keep the current state: ') == 'RESTORE':
                self.restore(backup, confirmed=True)
                return
            else:
                print('Use Restore a previous backup in the update menu. No automatic data rollback was performed.')
            raise

    def verify_backup(self, backup):
        backup = Path(backup)
        if backup.is_symlink() or not (backup / 'COMPLETE').is_file():
            raise Failure('This is not a complete backup.')
        hashes = json.loads((backup / 'checksums.json').read_text())
        if not {'manifest.json', 'config.tar.gz', 'images.tar'} <= set(hashes):
            raise Failure('Backup file list is incomplete.')
        for name, expected in hashes.items():
            path = backup / name
            if Path(name).is_absolute() or '..' in Path(name).parts or path.is_symlink() or not path.is_file() or checksum(path) != expected:
                raise Failure('Backup checksum validation failed: ' + name)
        manifest = json.loads((backup / 'manifest.json').read_text())
        if manifest.get('format') != 1 or manifest.get('install_dir') != str(self.root):
            raise Failure('Backup format or installation directory does not match.')
        for volume in manifest['volumes']:
            if volume['archive'] not in hashes or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]+', volume['name']):
                raise Failure('Invalid backup volume description.')
            safe_archive(backup / volume['archive'])
        safe_archive(backup / 'config.tar.gz')
        return manifest

    def restore(self, backup, confirmed=False):
        backup = Path(backup)
        manifest = self.verify_backup(backup)
        if not confirmed and self.ask('Restore replaces current configuration and database state. Type RESTORE to continue: ') != 'RESTORE':
            print('Cancelled.')
            return
        self.project = manifest['project']
        ids = self.docker('ps', '-aq', '--filter', 'label=com.docker.compose.project=' + self.project).split()
        current = self.inspect(*ids)
        own = {c['Id'] for c in current}
        for c in current:
            wd = c.get('Config', {}).get('Labels', {}).get('com.docker.compose.project.working_dir')
            if wd and wd != str(self.root):
                raise Failure('Project collision; restore refused.')
        all_ids = self.docker('ps', '-aq').split()
        restore_volumes = {v['name'] for v in manifest['volumes']}
        for c in self.inspect(*all_ids):
            if c['Id'] not in own and any(m.get('Name') in restore_volumes for m in c.get('Mounts', [])):
                raise Failure('A restore volume is shared with another project.')
        if self.root.is_symlink() or os.path.ismount(self.root):
            raise Failure('Unsafe installation directory.')
        if self.root.exists():
            device = self.root.stat().st_dev
            for p in self.root.rglob('*'):
                if p.is_symlink() or p.stat().st_dev != device or os.path.ismount(p):
                    raise Failure('Unsafe installation directory entry: ' + str(p))
        # Load and validate old images before stopping or replacing the current stack.
        self.docker('image', 'load', '-i', backup / 'images.tar', capture=False)
        self.docker('image', 'inspect', manifest['helper'])
        for c in manifest['containers']:
            self.docker('image', 'inspect', c['image_id'])
        if ids:
            running = [c['Id'] for c in current if c.get('State', {}).get('Running')]
            if running:
                self.docker('stop', '--time', '30', *running, capture=False)
            self.docker('rm', *ids, capture=False)  # never -v during restore
        if self.root.exists():
            # Preserve the pre-restore filesystem instead of deleting it.
            rescue = self.backups / ('pre-restore-' + dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + str(os.getpid()))
            rescue.mkdir(mode=0o700, parents=True)
            shutil.copytree(self.root, rescue / 'configuration', symlinks=False)
            shutil.rmtree(self.root)
        self.root.mkdir(mode=0o700, parents=True)
        self.run(['tar', '--numeric-owner', '-xzpf', backup / 'config.tar.gz', '-C', self.root])
        self.base = self.overlay = None
        self.load()
        if self.project != manifest['project']:
            raise Failure('Restored Compose project differs from the snapshot.')
        rollback = {}
        for c in manifest['containers']:
            service = c['service']
            if not service or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*', service):
                raise Failure('Invalid service name in backup.')
            ref = 'netbird-manager-rollback/' + service.lower() + ':' + manifest['created_utc'].lower()
            self.docker('tag', c['image_id'], ref)
            rollback[service] = ref
        self.image_override(rollback)
        (self.root / '.netbird-manager-versions.json').write_text(json.dumps({c['service']: {'image_id': c['image_id'], 'version': c.get('version', 'Unknown')} for c in manifest['containers']}, indent=2))
        self.dc('create', '--pull', 'never', capture=False)
        restored_ids = self.dc('ps', '-a', '-q').split()
        restored = {c['Config']['Labels'].get('com.docker.compose.service'): c for c in self.inspect(*restored_ids)}
        for volume in manifest['volumes']:
            for use in volume.get('uses', []):
                mounts = restored.get(use['service'], {}).get('Mounts', [])
                if not any(m.get('Name') == volume['name'] and m.get('Destination') == use['destination'] for m in mounts):
                    raise Failure('Restored volume mapping differs from snapshot; restore stopped before copying data.')
            self.docker('volume', 'inspect', volume['name'])
            self.docker('run', '--rm', '--network', 'none', '--mount', f'type=volume,src={volume["name"]},dst=/data', '--mount', f'type=bind,src={backup},dst=/backup,readonly', manifest['helper'], 'sh', '-c', 'find /data -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + && tar xzpf "$1" -C /data', 'restore', '/backup/' + volume['archive'])
        running_services = [c['service'] for c in manifest['containers'] if c['running']]
        if running_services:
            self.dc('start', *running_services, capture=False)
            self.health(running_services)
        self.say('Snapshot restored. Verify dashboard access and real peer connectivity.', 32)

    def restore_menu(self):
        self.ensure_backup_root()
        backups = sorted([p for p in self.backups.iterdir() if p.is_dir() and not p.is_symlink() and (p / 'COMPLETE').is_file()], reverse=True)
        if not backups:
            print('No complete backups found.')
            return
        for i, path in enumerate(backups, 1):
            print(f'  [{i}] {path.name}')
        answer = self.ask('Backup number (0 to cancel): ')
        if answer == '0':
            return
        if not answer.isdigit() or not 1 <= int(answer) <= len(backups):
            raise Failure('Invalid backup selection.')
        self.restore(backups[int(answer)-1])

    def menu(self):
        while True:
            self.say('\nUPDATE AND RECOVERY')
            print('  [1] Check versions and available updates\n  [2] Select components and install updates\n  [3] Restore a previous backup\n  [0] Back')
            try:
                choice = self.ask('Select an option: ')
                if choice == '0':
                    return
                if choice == '1':
                    self.latest_cache.clear()
                    self.overview()
                elif choice == '2':
                    self.latest_cache.clear()
                    self.update()
                elif choice == '3':
                    self.restore_menu()
                else:
                    print('Please enter 0, 1, 2, 3 or 4.')
            except (Failure, OSError, ValueError, yaml.YAMLError) as e:
                self.say('ERROR: ' + str(e), 31)
            except KeyboardInterrupt:
                self.say('Operation interrupted. If deployment had started, use the retained backup for recovery.', 31)

if __name__ == '__main__':
    os.umask(0o077)
    Manager(sys.argv[1]).menu()
NETBIRD_UPDATE_PY
}

main() {
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

# Run the original wizard unchanged, with only the domain explicitly entered here.
# Clear inherited preset answers in the child process so its prompts stay available.
run_official_installer() (
  local selected_domain=$1 variable
  while IFS= read -r variable; do
    unset "$variable"
  done < <(compgen -A variable NETBIRD_ || true)
  unset DEBIAN_FRONTEND
  export NETBIRD_DOMAIN="$selected_domain"
  bash ./getting-started.sh
)

install_server() {
  local domain=${1:-} label dns_ips busy codename pkg
  local -a conflicts=()
  check_path
  if [[ -d "$install_dir" ]]; then
    [[ -z "$(find "$install_dir" -mindepth 1 -maxdepth 1 -print -quit)" ]] || die "$install_dir is not empty. Check status or uninstall using the menu first."
  fi
  while :; do
    if [[ -n "$domain" ]]; then
      read -r -p "${YELLOW}NetBird domain [$domain]: ${RESET}" answer
      domain=${answer:-$domain}
    else
      read -r -p "${YELLOW}Enter your NetBird domain: ${RESET}" domain
    fi
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
apt-get install -y ca-certificates curl jq openssl dnsutils iproute2 htop python3 python3-yaml

step 'Checking DNS resolution'
dns_ips=$({ getent ahosts "$domain" || true; } | awk '{print $1}' | sort -u)
[[ -n "$dns_ips" ]] || die "$domain does not resolve. Configure DNS and run the installer again."
printf 'DNS for %s:\n%s\n' "$domain" "$dns_ips"
printf 'These addresses must point to this server (its public IP when behind NAT).\n'
printf 'Cloud firewall/router: allow inbound TCP 80/443 and UDP 3478. Use Cloudflare DNS only.\n'

step 'Showing current listeners for the setup wizard'
busy=$(ss -H -ltn '( sport = :80 or sport = :443 )')
if [[ -n "$busy" ]]; then
  printf '%sTCP 80/443 already in use. Select an appropriate existing reverse proxy option in the official wizard:%s\n%s\n' "$YELLOW" "$RESET" "$busy"
fi
busy=$(ss -H -lun 'sport = :3478')
if [[ -n "$busy" ]]; then
  printf '%sUDP 3478 already in use. Review this listener and the wizard configuration:%s\n%s\n' "$YELLOW" "$RESET" "$busy"
fi

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
printf '\n%sStarting the original interactive NetBird setup wizard.%s\n' "$CYAN" "$RESET"
printf 'Choose your reverse proxy, optional services and all remaining settings in the wizard.\n'
printf 'Only the domain you entered above is passed as a preset answer.\n\n'
run_official_installer "$domain"

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

# The official installer defines traefik, crowdsec and proxy in this same
# Compose stack. Prefer its own teardown; use label-based recovery if YAML
# is missing/invalid, or if down leaves orphaned resources behind.
compose_cleanup() {
  local project file='' override
  local -a compose_args=()
  for file in "$install_dir/docker-compose.yml" "$install_dir/docker-compose.yaml" "$install_dir/compose.yml" "$install_dir/compose.yaml"; do
    [[ -f "$file" ]] && break
  done
  [[ -f "$file" ]] || { printf 'Compose file missing; using Docker project labels.\n'; return 0; }
  if ! docker compose version >/dev/null 2>&1; then
    printf 'Compose plugin unavailable; using Docker project labels.\n'
    return 0
  fi
  compose_args=(--project-directory "$install_dir" --file "$file")
  for override in compose.override.yaml compose.override.yml docker-compose.override.yaml docker-compose.override.yml; do
    if [[ -f "$install_dir/$override" ]]; then compose_args+=(--file "$install_dir/$override"); fi
  done
  for project in "$@"; do
    if docker compose "${compose_args[@]}" --project-name "$project" config --quiet; then
      step "Stopping the complete Compose stack: $project (including bundled Traefik and CrowdSec)"
      if ! docker compose "${compose_args[@]}" --project-name "$project" down --volumes --remove-orphans; then
        printf '%sCompose teardown did not finish; checking remaining labelled resources.%s\n' "$YELLOW" "$RESET"
      fi
    else
      printf 'Compose configuration invalid; using Docker project labels for %s.\n' "$project"
    fi
  done
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
  if ((${#containers[@]})); then
    printf '\nContainers selected for removal (including optional services):\n'
    for id in "${containers[@]}"; do
      row=$(docker inspect "$id")
      jq -r '.[0] | "  \(.Name | ltrimstr("/")) | \(.Config.Image // .Image) | \(.State.Status // "unknown")"' <<< "$row"
    done
  fi
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
  compose_cleanup "${projects[@]}"
  # Remove leftovers after Compose teardown, including stopped/Created orphans.
  # Query fresh inventories: do not treat an already deleted resource as an error.
  for project in "${projects[@]}"; do
    inventory=$(docker ps -aq --filter "label=com.docker.compose.project=$project")
    while IFS= read -r id; do
      [[ -n "$id" ]] || continue
      docker rm -fv "$id"
    done <<< "$inventory"
    inventory=$(docker volume ls -q --filter "label=com.docker.compose.project=$project")
    while IFS= read -r id; do
      [[ -n "$id" ]] || continue
      docker volume rm "$id"
    done <<< "$inventory"
    inventory=$(docker network ls -q --filter "label=com.docker.compose.project=$project")
    while IFS= read -r id; do
      [[ -n "$id" ]] || continue
      docker network rm "$id"
    done <<< "$inventory"
  done
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
  step 'Verifying that no containers, volumes or networks remain for the selected projects'
  for project in "${projects[@]}"; do
    inventory=$(docker ps -aq --filter "label=com.docker.compose.project=$project")
    [[ -z "$inventory" ]] || die "Containers remain for $project: $inventory. Installation files retained."
    inventory=$(docker volume ls -q --filter "label=com.docker.compose.project=$project")
    [[ -z "$inventory" ]] || die "Volumes remain for $project: $inventory. Installation files retained."
    inventory=$(docker network ls -q --filter "label=com.docker.compose.project=$project")
    [[ -z "$inventory" ]] || die "Networks remain for $project: $inventory. Installation files retained."
  done
  check_path
  cd /
  rm -rf --one-file-system -- "$install_dir"
  [[ ! -e "$install_dir" ]] || die "Installation directory still exists: $install_dir"
  success 'NetBird server removed. Docker stays installed. You can now install again.'
  printf 'Manage cloud firewall rules and DNS records separately in your provider portal.\n'
  if ((${#external[@]})); then printf 'The external data listed above has been retained.\n'; fi
}

update_menu() {
  check_path
  command -v docker >/dev/null || die 'Docker is required for update and recovery.'
  docker info >/dev/null 2>&1 || die 'Docker daemon is not available.'
  docker compose version >/dev/null 2>&1 || die 'Docker Compose v2 is required.'
  if ! command -v python3 >/dev/null || ! python3 -c 'import yaml' >/dev/null 2>&1; then
    local answer
    read -r -p 'Update/recovery needs python3 and python3-yaml. Install these packages? (yes/no): ' answer
    case "${answer,,}" in
      y|yes) apt-get update; apt-get install -y python3 python3-yaml ;;
      *) printf 'Cancelled.\n'; return 0 ;;
    esac
  fi
  python3 - "$install_dir" <<'NETBIRD_UPDATE_PY'
"""Embedded update engine for NetBird Server Manager; Python 3.10+ and PyYAML."""
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import time
import urllib.request
import yaml

class Failure(RuntimeError):
    pass

def ask(message):
    with open('/dev/tty', 'r+') as tty:
        tty.write(message)
        tty.flush()
        answer = tty.readline()
        if not answer:
            raise Failure('Input closed; operation cancelled.')
        return answer.strip()

def semver(value):
    m = re.fullmatch(r'v?(\d+)\.(\d+)\.(\d+)', value or '')
    return tuple(map(int, m.groups())) if m else None

def repository(image):
    image = image.split('@')[0]
    head, slash, tail = image.rpartition('/')
    tail = tail.split(':')[0]
    return head + slash + tail

def safe_archive(path):
    # Validate before passing archives to tar, including link destinations.
    with tarfile.open(path, 'r:gz') as archive:
        for member in archive:
            name = Path(member.name)
            if name.is_absolute() or '..' in name.parts or member.isdev() or member.isfifo():
                raise Failure('Unsafe archive entry: ' + member.name)
            if member.issym() or member.islnk():
                link = Path(member.linkname)
                if link.is_absolute() or '..' in link.parts:
                    raise Failure('Unsupported archive link: ' + member.name)

def checksum(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()

class Manager:
    COMPONENTS = {
        'netbird-server': ('NetBird Management', 'netbirdio/netbird'),
        'management': ('NetBird Management (legacy)', 'netbirdio/netbird'),
        'dashboard': ('NetBird Dashboard', 'netbirdio/dashboard'),
        'proxy': ('NetBird Proxy', 'netbirdio/netbird'),
        'traefik': ('Traefik', 'traefik/traefik'),
        'crowdsec': ('CrowdSec', 'crowdsecurity/crowdsec'),
    }
    ORDER = {'crowdsec': 0, 'netbird-server': 1, 'management': 1,
             'traefik': 2, 'dashboard': 3, 'proxy': 4}

    def __init__(self, root, backups='/var/backups/netbird', prompt=ask):
        self.root = Path(root)
        self.backups = Path(backups)
        self.ask = prompt
        self.base = self.overlay = None
        self.project = None
        self.latest_cache = {}
        self.colors = sys.stdout.isatty() and 'NO_COLOR' not in os.environ

    def say(self, text, color=36):
        print(f'\033[{color}m{text}\033[0m' if self.colors else text, flush=True)

    def run(self, args, capture=True, check=True):
        result = subprocess.run([str(x) for x in args], text=True,
                                stdout=subprocess.PIPE if capture else None,
                                stderr=subprocess.PIPE if capture else None)
        if check and result.returncode:
            # Do not echo expanded config/env contents or credentials on failure.
            raise Failure(f'{args[0]} {args[1] if len(args)>1 else ""} failed (exit {result.returncode}).')
        return result.stdout.strip() if capture and result.returncode == 0 else ('' if capture else result.returncode)

    def docker(self, *args, **kwargs):
        return self.run(['docker', *args], **kwargs)

    def inspect(self, *ids):
        return json.loads(self.docker('inspect', *ids)) if ids else []

    def dc(self, *args, **kwargs):
        command = ['docker', 'compose', '--project-directory', self.root, '-f', self.base]
        if self.overlay and self.overlay.exists():
            command += ['-f', self.overlay]
        if self.project:
            command += ['-p', self.project]
        return self.run(command + list(args), **kwargs)

    def load(self):
        if not self.root.is_dir() or self.root.is_symlink():
            raise Failure('Installation directory missing or unsafe. Use Restore if recovering a backup.')
        candidates = [self.root / n for n in ('compose.yaml', 'compose.yml', 'docker-compose.yaml', 'docker-compose.yml') if (self.root / n).exists()]
        if len(candidates) != 1:
            raise Failure('Exactly one Compose base file is required in the installation directory.')
        self.base = candidates[0]
        overrides = [self.root / n for n in ('compose.override.yaml', 'compose.override.yml', 'docker-compose.override.yaml', 'docker-compose.override.yml') if (self.root / n).exists()]
        if len(overrides) > 1:
            raise Failure('Multiple Compose override files found; merge them before using this updater.')
        self.overlay = overrides[0] if overrides else self.root / ('docker-compose.override.yml' if self.base.name.startswith('docker-') else 'compose.override.yaml')
        for path in (self.base, self.overlay):
            if path.is_symlink():
                raise Failure('Symlinked Compose files are not supported by the updater.')
        if self.overlay.exists():
            overlay_data = yaml.safe_load(self.overlay.read_text()) or {}
            if not isinstance(overlay_data, dict) or not isinstance(overlay_data.get('services', {}), dict):
                raise Failure('Unsupported Compose override structure.')
        # Find the actual project even when COMPOSE_PROJECT_NAME was set at install.
        all_ids = self.docker('ps', '-aq').split()
        projects = {c.get('Config', {}).get('Labels', {}).get('com.docker.compose.project')
                    for c in self.inspect(*all_ids)
                    if c.get('Config', {}).get('Labels', {}).get('com.docker.compose.project.working_dir') == str(self.root)}
        projects.discard(None)
        if len(projects) > 1:
            raise Failure('Multiple projects use this directory; resolve the ambiguity first.')
        self.project = next(iter(projects), self.project)
        config = json.loads(self.dc('config', '--format', 'json'))
        self.project = self.project or config.get('name')
        if not self.project:
            raise Failure('Compose project could not be determined.')
        ids = self.docker('ps', '-aq', '--filter', 'label=com.docker.compose.project=' + self.project).split()
        self.containers = self.inspect(*ids)
        for c in self.containers:
            wd = c.get('Config', {}).get('Labels', {}).get('com.docker.compose.project.working_dir')
            if wd and wd != str(self.root):
                raise Failure('Project name collision with another installation directory.')
            files = c.get('Config', {}).get('Labels', {}).get('com.docker.compose.project.config_files', '')
            if files and any(Path(f).resolve() not in {self.base.resolve(), self.overlay.resolve()} for f in files.split(',')):
                raise Failure('This deployment uses additional Compose files. Merge them into the base/standard override before using this updater.')
        self.config = config
        self.by_service = {}
        for c in self.containers:
            if c.get('Config', {}).get('Labels', {}).get('com.docker.compose.oneoff', '').lower() == 'true':
                continue
            service = c['Config']['Labels'].get('com.docker.compose.service')
            if service in self.by_service:
                raise Failure('Scaled services are not supported by this updater.')
            if service:
                self.by_service[service] = c
        return self

    def installed(self, service):
        c = self.by_service.get(service)
        if not c:
            return 'Unknown'
        programs = {
            'netbird-server': ['/go/bin/netbird-server', '--version'],
            'management': ['/go/bin/netbird-mgmt', '--version'],
            'proxy': ['/go/bin/netbird-proxy', '--version'],
            'traefik': ['traefik', 'version'],
            'crowdsec': ['cscli', 'version'],
        }
        if service in programs and c.get('State', {}).get('Running'):
            out = self.docker('exec', c['Id'], *programs[service], check=False)
            match = re.search(r'(?<![\d.])v?(\d+\.\d+\.\d+(?:[-+][\w.-]+)?)', out)
            if match:
                return 'v' + match.group(1)
        recorded = self.root / '.netbird-manager-versions.json'
        if recorded.is_file():
            try:
                item = json.loads(recorded.read_text()).get(service, {})
                if item.get('image_id') == c['Image'] and semver(item.get('version')):
                    return 'v' + item['version'].lstrip('v')
            except (ValueError, OSError):
                pass
        # OS image labels can report e.g. Ubuntu 24.04. Never treat those as app versions.
        ref = c.get('Config', {}).get('Image', '')
        tag = ref.rsplit('/', 1)[-1].split(':', 1)[-1] if '@' not in ref and ':' in ref.rsplit('/', 1)[-1] else ''
        return 'v' + tag.lstrip('v') if semver(tag) else 'Unknown'

    def latest(self, repo):
        if repo not in self.latest_cache:
            try:
                req = urllib.request.Request('https://api.github.com/repos/' + repo + '/releases/latest', headers={'Accept': 'application/vnd.github+json', 'User-Agent': 'NetBird-Server-Manager'})
                with urllib.request.urlopen(req, timeout=12) as response:
                    release = json.load(response)
                value = release.get('tag_name', '')
                self.latest_cache[repo] = value if not release.get('prerelease') and not release.get('draft') and semver(value) else 'Unknown'
            except Exception:
                self.latest_cache[repo] = 'Unknown'
        return self.latest_cache[repo]

    def overview(self):
        self.load()
        self.services = [s for s in self.config['services'] if s in self.COMPONENTS]
        print('\n{:<4} {:<29} {:<17} {:<17} {}'.format('#', 'Component', 'Installed', 'Latest stable', 'Status'))
        for index, service in enumerate(self.services, 1):
            current = self.installed(service)
            available = self.latest(self.COMPONENTS[service][1])
            a, b = semver(current), semver(available)
            status = 'Unknown' if a is None or b is None else ('Update available' if b > a else ('Up to date' if a == b else 'Installed newer'))
            print(f'{index:<4} {self.COMPONENTS[service][0]:<29} {current:<17} {available:<17} {status}')
            print('     Image: ' + self.config['services'][service].get('image', '(not configured)'))
        for service, spec in self.config['services'].items():
            commands = spec.get('command') or []
            if not isinstance(commands, list):
                commands = [commands]
            for command in commands:
                if 'experimental.plugins.' in str(command) and '.version=' in str(command):
                    print('Plugin setting (review compatibility manually): ' + str(command))
        print('\nManagement and Dashboard have independent versions. Unknown does not mean up to date.')
        return self.services

    def selection(self, text):
        numbers = text.split()
        if not numbers or any(not n.isdigit() or not 1 <= int(n) <= len(self.services) for n in numbers):
            raise Failure('Enter one or more service numbers separated by spaces; no services were selected.')
        return list(dict.fromkeys(self.services[int(n)-1] for n in numbers))

    def validate_pair(self, targets):
        management = 'netbird-server' if 'netbird-server' in self.config['services'] else 'management'
        if 'proxy' in self.config['services'] and (management in targets or 'proxy' in targets):
            if management in targets and 'proxy' in targets:
                if semver(targets[management]) != semver(targets['proxy']):
                    raise Failure('Select matching Management and Proxy target versions.')
            else:
                # Unknown or mismatched pairs must be selected together instead of guessed.
                changed = management if management in targets else 'proxy'
                other = 'proxy' if changed == management else management
                if semver(self.installed(other)) != semver(targets[changed]):
                    raise Failure('Select Management and Proxy together with matching target versions; the unchanged version is unknown or different.')

    def preflight(self):
        if 'netbird-server' not in self.by_service or 'management' in self.config['services']:
            raise Failure('Automatic backup/update supports the combined netbird-server layout only. Legacy split-server layouts need migration first.')
        # Check the actual mounted server config, not only a guessed host filename.
        cfg = [m for m in self.by_service['netbird-server'].get('Mounts', []) if m['Destination'] == '/etc/netbird/config.yaml' and m['Type'] == 'bind']
        if len(cfg) != 1 or not Path(cfg[0]['Source']).is_file():
            raise Failure('Cannot verify the mounted Management configuration; backup stopped.')
        data = yaml.safe_load(Path(cfg[0]['Source']).read_text())
        store = (data or {}).get('store', {})
        # The combined server nests store below server; both layouts are checked.
        if not store:
            store = (data or {}).get('server', {}).get('store', {})
        if not isinstance(store, dict) or str(store.get('engine', '')).lower() != 'sqlite':
            raise Failure('Only explicitly configured SQLite storage is supported automatically. PostgreSQL/MySQL/unknown stores require database-specific backup and restore.')
        if any(c.get('State', {}).get('Paused') for c in self.containers):
            raise Failure('Unpause project containers before updating.')
        self.volumes = set()
        for c in self.containers:
            for m in c.get('Mounts', []):
                if m['Type'] == 'volume':
                    self.volumes.add(m['Name'])
                elif m['Type'] == 'bind':
                    source = Path(m['Source']).resolve()
                    if source != self.root and self.root not in source.parents:
                        if str(source) not in ('/run/docker.sock', '/var/run/docker.sock', '/etc/localtime', '/etc/timezone') or m.get('RW', False):
                            raise Failure('External bind mount needs its own backup workflow: ' + str(source))
        management_data = [m for m in self.by_service['netbird-server'].get('Mounts', []) if m['Destination'] == '/var/lib/netbird' and m['Type'] in ('volume', 'bind')]
        if not management_data:
            raise Failure('Management data is not persistently mounted; update refused.')
        for env in self.by_service['netbird-server'].get('Config', {}).get('Env', []):
            key, _, value = env.partition('=')
            if ('STORE_ENGINE' in key and value.lower() not in ('', 'sqlite')) or ('DSN' in key and value):
                raise Failure('External database environment overrides require a database-specific backup workflow.')
        # Every other container mounting these volumes could invalidate a stopped copy.
        all_ids = self.docker('ps', '-aq').split()
        own_ids = {c['Id'] for c in self.containers}
        for c in self.inspect(*all_ids):
            if c['Id'] not in own_ids and any(m.get('Name') in self.volumes for m in c.get('Mounts', [])):
                raise Failure('A data volume is shared with a container outside this project.')
        for volume in self.volumes:
            info = json.loads(self.docker('volume', 'inspect', volume))[0]
            if info.get('Driver') != 'local' or info.get('Options'):
                raise Failure('Remote or custom volume drivers need an explicit backup workflow: ' + volume)
            if info.get('Labels', {}).get('com.docker.compose.project') != self.project:
                raise Failure('External or anonymous volumes need an explicit backup workflow: ' + volume)
        if any(not c.get('Config', {}).get('Labels', {}).get('com.docker.compose.service') or c.get('Config', {}).get('Labels', {}).get('com.docker.compose.oneoff', '').lower() == 'true' for c in self.containers):
            raise Failure('Remove temporary one-off project containers before taking an update snapshot.')
        # Refuse symlinks/nested mount points in the managed directory.
        root_device = self.root.stat().st_dev
        for path in self.root.rglob('*'):
            if path.is_symlink() or path.stat().st_dev != root_device or os.path.ismount(path):
                raise Failure('Symlink or nested mount in installation directory: ' + str(path))

    def ensure_backup_root(self):
        if self.backups.is_symlink() or self.root == self.backups or self.root in self.backups.resolve().parents:
            raise Failure('Backup directory must be outside the installation directory and must not be a symlink.')
        self.backups.mkdir(mode=0o700, parents=True, exist_ok=True)
        if self.backups.stat().st_uid != 0:
            raise Failure('Backup directory must be owned by root.')
        self.backups.chmod(0o700)

    def image_override(self, images):
        original = self.overlay.read_text() if self.overlay.exists() else None
        data = yaml.safe_load(original) if original else {}
        if not isinstance(data, dict):
            raise Failure('Unsupported Compose override format.')
        data.setdefault('services', {})
        for service, image in images.items():
            data['services'].setdefault(service, {})['image'] = image
        temporary = self.overlay.with_name(self.overlay.name + '.tmp')
        temporary.write_text(yaml.safe_dump(data, sort_keys=False))
        temporary.chmod(0o600)
        temporary.replace(self.overlay)
        try:
            self.dc('config', '--quiet')
        except Exception:
            if original is None:
                self.overlay.unlink()
            else:
                self.overlay.write_text(original)
            raise

    def restart_original(self, containers, exclude=()):
        for c in containers:
            if c.get('State', {}).get('Running') and c['Config']['Labels'].get('com.docker.compose.service') not in exclude:
                if self.docker('inspect', c['Id'], check=False):
                    self.docker('start', c['Id'])

    def snapshot(self, helper):
        self.ensure_backup_root()
        # Estimate raw image + data space with headroom before any downtime.
        ids = sorted({c['Image'] for c in self.containers} | {helper})
        size = sum(json.loads(self.docker('image', 'inspect', image))[0].get('Size', 0) for image in ids)
        size += sum(p.stat().st_size for p in self.root.rglob('*') if p.is_file())
        for volume in self.volumes:
            used = self.docker('run', '--rm', '--network', 'none', '--mount', f'type=volume,src={volume},dst=/data,readonly', helper, 'du', '-sk', '/data')
            size += int(used.split()[0]) * 1024
        if shutil.disk_usage(self.backups).free < int(size * 1.3) + 64 * 1024 * 1024:
            raise Failure('Insufficient free space for a complete backup with headroom.')
        stamp = dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
        backup = self.backups / (stamp + '-' + str(os.getpid()))
        backup.mkdir(mode=0o700)
        (backup / 'volumes').mkdir(mode=0o700)
        manifest = {'format': 1, 'created_utc': stamp, 'install_dir': str(self.root), 'project': self.project,
                    'helper': helper, 'containers': [{'service': c['Config']['Labels'].get('com.docker.compose.service'), 'image_id': c['Image'], 'version': self.installed(c['Config']['Labels'].get('com.docker.compose.service')), 'running': c.get('State', {}).get('Running', False)} for c in self.containers],
                    'volumes': [{'name': v, 'archive': f'volumes/{i}.tar.gz', 'uses': [{'service': c['Config']['Labels']['com.docker.compose.service'], 'destination': m['Destination']} for c in self.containers for m in c.get('Mounts', []) if m.get('Name') == v]} for i, v in enumerate(sorted(self.volumes))]}
        self.say('Saving old images for offline recovery: ' + str(backup))
        self.docker('image', 'save', '-o', backup / 'images.tar', *ids)
        stopped = False
        try:
            running = [c['Id'] for c in self.containers if c.get('State', {}).get('Running')]
            if running:
                stopped = True
                self.docker('stop', '--time', '30', *running, capture=False)
            self.run(['tar', '--numeric-owner', '-czpf', backup / 'config.tar.gz', '-C', self.root, '.'])
            safe_archive(backup / 'config.tar.gz')
            for volume in manifest['volumes']:
                self.docker('run', '--rm', '--network', 'none', '--mount', f'type=volume,src={volume["name"]},dst=/data,readonly', '--mount', f'type=bind,src={backup / "volumes"},dst=/backup', helper, 'tar', 'czpf', '/backup/' + Path(volume['archive']).name, '-C', '/data', '.')
                safe_archive(backup / volume['archive'])
            (backup / 'manifest.json').write_text(json.dumps(manifest, indent=2))
            files = ['manifest.json', 'images.tar', 'config.tar.gz'] + [v['archive'] for v in manifest['volumes']]
            hashes = {name: checksum(backup / name) for name in files}
            (backup / 'checksums.json').write_text(json.dumps(hashes, indent=2))
            (backup / 'COMPLETE').write_text('Backup complete\n')
            self.say('Backup complete: ' + str(backup), 32)
            return backup
        except BaseException:
            if stopped:
                self.restart_original(self.containers)
            self.say('Backup incomplete; no application update was performed. Partial backup: ' + str(backup), 31)
            raise

    def health(self, services):
        deadline = time.monotonic() + 120
        stable = 0
        while time.monotonic() < deadline:
            ids = self.dc('ps', '-a', '-q', *services).split()
            containers = self.inspect(*ids)
            ready = len(containers) == len(services)
            for c in containers:
                state = c.get('State', {})
                if not state.get('Running') or state.get('Restarting') or c.get('RestartCount', 0):
                    ready = False
                if state.get('Health', {}).get('Status', 'healthy') != 'healthy':
                    ready = False
            stable = stable + 1 if ready else 0
            if stable >= 3:
                return
            time.sleep(3)
        raise Failure('Services did not reach a stable running/healthy state within 120 seconds.')

    def web_check(self):
        # HTTPS checks are observable tests, not proof of peer connectivity.
        for service in ('dashboard', 'netbird-server'):
            spec = self.config['services'].get(service, {})
            labels = spec.get('labels', {})
            for key, value in labels.items():
                if '.rule' not in key:
                    continue
                match = re.search(r'Host\(`([^`]+)`\)', value)
                if match:
                    domain = match.group(1)
                    path = '/' if service == 'dashboard' else '/api/instance/version'
                    req = urllib.request.Request('https://' + domain + path, headers={'User-Agent': 'NetBird-Server-Manager'})
                    try:
                        with urllib.request.urlopen(req, timeout=15) as response:
                            code = response.status
                    except urllib.error.HTTPError as e:
                        code = e.code
                    except Exception:
                        self.say('HTTPS check failed for ' + domain + path + '. Check DNS, certificates and reverse proxy.', 31)
                        return False
                    allowed = (200, 401, 403) if service == 'netbird-server' else (200,)
                    if code not in allowed:
                        self.say(f'HTTPS check returned HTTP {code}: {domain}{path}', 31)
                        return False
                    print(f'HTTPS reachable: {domain}{path} (HTTP {code})')
                    break
            else:
                self.say('Public HTTPS address could not be inferred for ' + service + '; verify it manually.', 33)
        return True

    def update(self):
        self.overview()
        selected = self.selection(self.ask('Select component numbers (space-separated; none preselected): '))
        targets = {}
        for service in selected:
            latest = self.latest(self.COMPONENTS[service][1])
            prompt = f'Target release for {service}' + (f' [{latest}]' if latest != 'Unknown' else '') + ': '
            value = self.ask(prompt) or (latest if latest != 'Unknown' else '')
            if not semver(value):
                raise Failure('Enter an explicit stable version, e.g. v1.2.3. No latest tag or prerelease is accepted.')
            targets[service] = value
        self.validate_pair(targets)
        self.preflight()
        planned = {}
        for service, version in targets.items():
            repo = repository(self.config['services'][service]['image'])
            tag = ('v' if service in ('dashboard', 'traefik', 'crowdsec') else '') + version.lstrip('v')
            tag_answer = self.ask(f'Docker image tag for {service} [{tag}]: ')
            if tag_answer:
                tag = tag_answer
            if semver(tag) != semver(version):
                raise Failure('The Docker tag must match the selected release (with or without a v prefix).')
            planned[service] = repo + ':' + tag
        self.say('\nUpdate plan (selected services will be started, including currently stopped services):')
        for service in selected:
            print(f'  {service}: {self.installed(service)} -> {targets[service]} ({planned[service]})')
            print('  Release notes: https://github.com/' + self.COMPONENTS[service][1] + '/releases/tag/' + targets[service])
        print('All running project services will stop briefly for a complete consistent backup.')
        print('Backup location: ' + str(self.backups) + '; Docker and OS packages are not updated.')
        if self.ask('Type UPDATE to download images, back up and apply this plan: ') != 'UPDATE':
            print('Cancelled.')
            return
        original_containers = list(self.containers)
        # Resolve downloaded releases to immutable digests before stopping anything.
        pinned, version_records = {}, {}
        for service, image in planned.items():
            self.docker('pull', image, capture=False)
            info = json.loads(self.docker('image', 'inspect', image))[0]
            digests = info.get('RepoDigests') or []
            if not digests:
                raise Failure('Downloaded image has no repository digest: ' + image)
            pinned[service] = digests[0]
            version_records[service] = {'image_id': info['Id'], 'version': targets[service]}
        self.docker('pull', 'alpine:3', capture=False)
        helper = json.loads(self.docker('image', 'inspect', 'alpine:3'))[0]['Id']
        backup = self.snapshot(helper)
        try:
            self.image_override(pinned)
            record_file = self.root / '.netbird-manager-versions.json'
            records = json.loads(record_file.read_text()) if record_file.exists() else {}
            records.update(version_records)
            record_file.write_text(json.dumps(records, indent=2))
            self.restart_original(original_containers, exclude=selected)
            for service in sorted(selected, key=lambda s: self.ORDER[s]):
                self.dc('up', '-d', '--no-deps', '--force-recreate', '--pull', 'never', service, capture=False)
                self.health([service])
            self.health([s for s in selected])
            self.load()
            for service in selected:
                observed = self.installed(service)
                if semver(observed) and semver(observed) != semver(targets[service]):
                    raise Failure('Started application version differs from the selected release: ' + service)
            if not self.web_check():
                raise Failure('The public HTTPS verification failed.')
            self.say('\nUpdate completed. Installed application versions:', 32)
            for service in selected:
                print('  ' + service + ': ' + self.installed(service))
            self.dc('ps', '-a', capture=False)
            print('Backup retained: ' + str(backup))
            print('Sign in to the dashboard and verify peers, policies, networks and a real peer connection.')
        except BaseException as error:
            self.say('Update failed: ' + str(error) + '. Backup and previous images are retained at ' + str(backup), 31)
            self.say('Database migrations may require restoring data as well as old images.', 33)
            if self.ask('Type RESTORE to restore this snapshot now, or press Enter to keep the current state: ') == 'RESTORE':
                self.restore(backup, confirmed=True)
                return
            else:
                print('Use Restore a previous backup in the update menu. No automatic data rollback was performed.')
            raise

    def verify_backup(self, backup):
        backup = Path(backup)
        if backup.is_symlink() or not (backup / 'COMPLETE').is_file():
            raise Failure('This is not a complete backup.')
        hashes = json.loads((backup / 'checksums.json').read_text())
        if not {'manifest.json', 'config.tar.gz', 'images.tar'} <= set(hashes):
            raise Failure('Backup file list is incomplete.')
        for name, expected in hashes.items():
            path = backup / name
            if Path(name).is_absolute() or '..' in Path(name).parts or path.is_symlink() or not path.is_file() or checksum(path) != expected:
                raise Failure('Backup checksum validation failed: ' + name)
        manifest = json.loads((backup / 'manifest.json').read_text())
        if manifest.get('format') != 1 or manifest.get('install_dir') != str(self.root):
            raise Failure('Backup format or installation directory does not match.')
        for volume in manifest['volumes']:
            if volume['archive'] not in hashes or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]+', volume['name']):
                raise Failure('Invalid backup volume description.')
            safe_archive(backup / volume['archive'])
        safe_archive(backup / 'config.tar.gz')
        return manifest

    def restore(self, backup, confirmed=False):
        backup = Path(backup)
        manifest = self.verify_backup(backup)
        if not confirmed and self.ask('Restore replaces current configuration and database state. Type RESTORE to continue: ') != 'RESTORE':
            print('Cancelled.')
            return
        self.project = manifest['project']
        ids = self.docker('ps', '-aq', '--filter', 'label=com.docker.compose.project=' + self.project).split()
        current = self.inspect(*ids)
        own = {c['Id'] for c in current}
        for c in current:
            wd = c.get('Config', {}).get('Labels', {}).get('com.docker.compose.project.working_dir')
            if wd and wd != str(self.root):
                raise Failure('Project collision; restore refused.')
        all_ids = self.docker('ps', '-aq').split()
        restore_volumes = {v['name'] for v in manifest['volumes']}
        for c in self.inspect(*all_ids):
            if c['Id'] not in own and any(m.get('Name') in restore_volumes for m in c.get('Mounts', [])):
                raise Failure('A restore volume is shared with another project.')
        if self.root.is_symlink() or os.path.ismount(self.root):
            raise Failure('Unsafe installation directory.')
        if self.root.exists():
            device = self.root.stat().st_dev
            for p in self.root.rglob('*'):
                if p.is_symlink() or p.stat().st_dev != device or os.path.ismount(p):
                    raise Failure('Unsafe installation directory entry: ' + str(p))
        # Load and validate old images before stopping or replacing the current stack.
        self.docker('image', 'load', '-i', backup / 'images.tar', capture=False)
        self.docker('image', 'inspect', manifest['helper'])
        for c in manifest['containers']:
            self.docker('image', 'inspect', c['image_id'])
        if ids:
            running = [c['Id'] for c in current if c.get('State', {}).get('Running')]
            if running:
                self.docker('stop', '--time', '30', *running, capture=False)
            self.docker('rm', *ids, capture=False)  # never -v during restore
        if self.root.exists():
            # Preserve the pre-restore filesystem instead of deleting it.
            rescue = self.backups / ('pre-restore-' + dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + str(os.getpid()))
            rescue.mkdir(mode=0o700, parents=True)
            shutil.copytree(self.root, rescue / 'configuration', symlinks=False)
            shutil.rmtree(self.root)
        self.root.mkdir(mode=0o700, parents=True)
        self.run(['tar', '--numeric-owner', '-xzpf', backup / 'config.tar.gz', '-C', self.root])
        self.base = self.overlay = None
        self.load()
        if self.project != manifest['project']:
            raise Failure('Restored Compose project differs from the snapshot.')
        rollback = {}
        for c in manifest['containers']:
            service = c['service']
            if not service or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*', service):
                raise Failure('Invalid service name in backup.')
            ref = 'netbird-manager-rollback/' + service.lower() + ':' + manifest['created_utc'].lower()
            self.docker('tag', c['image_id'], ref)
            rollback[service] = ref
        self.image_override(rollback)
        (self.root / '.netbird-manager-versions.json').write_text(json.dumps({c['service']: {'image_id': c['image_id'], 'version': c.get('version', 'Unknown')} for c in manifest['containers']}, indent=2))
        self.dc('create', '--pull', 'never', capture=False)
        restored_ids = self.dc('ps', '-a', '-q').split()
        restored = {c['Config']['Labels'].get('com.docker.compose.service'): c for c in self.inspect(*restored_ids)}
        for volume in manifest['volumes']:
            for use in volume.get('uses', []):
                mounts = restored.get(use['service'], {}).get('Mounts', [])
                if not any(m.get('Name') == volume['name'] and m.get('Destination') == use['destination'] for m in mounts):
                    raise Failure('Restored volume mapping differs from snapshot; restore stopped before copying data.')
            self.docker('volume', 'inspect', volume['name'])
            self.docker('run', '--rm', '--network', 'none', '--mount', f'type=volume,src={volume["name"]},dst=/data', '--mount', f'type=bind,src={backup},dst=/backup,readonly', manifest['helper'], 'sh', '-c', 'find /data -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + && tar xzpf "$1" -C /data', 'restore', '/backup/' + volume['archive'])
        running_services = [c['service'] for c in manifest['containers'] if c['running']]
        if running_services:
            self.dc('start', *running_services, capture=False)
            self.health(running_services)
        self.say('Snapshot restored. Verify dashboard access and real peer connectivity.', 32)

    def restore_menu(self):
        self.ensure_backup_root()
        backups = sorted([p for p in self.backups.iterdir() if p.is_dir() and not p.is_symlink() and (p / 'COMPLETE').is_file()], reverse=True)
        if not backups:
            print('No complete backups found.')
            return
        for i, path in enumerate(backups, 1):
            print(f'  [{i}] {path.name}')
        answer = self.ask('Backup number (0 to cancel): ')
        if answer == '0':
            return
        if not answer.isdigit() or not 1 <= int(answer) <= len(backups):
            raise Failure('Invalid backup selection.')
        self.restore(backups[int(answer)-1])

    def menu(self):
        while True:
            self.say('\nUPDATE AND RECOVERY')
            print('  [1] Check versions and available updates\n  [2] Select components and install updates\n  [3] Restore a previous backup\n  [0] Back')
            try:
                choice = self.ask('Select an option: ')
                if choice == '0':
                    return
                if choice == '1':
                    self.latest_cache.clear()
                    self.overview()
                elif choice == '2':
                    self.latest_cache.clear()
                    self.update()
                elif choice == '3':
                    self.restore_menu()
                else:
                    print('Please enter 0, 1, 2, 3 or 4.')
            except (Failure, OSError, ValueError, yaml.YAMLError) as e:
                self.say('ERROR: ' + str(e), 31)
            except KeyboardInterrupt:
                self.say('Operation interrupted. If deployment had started, use the retained backup for recovery.', 31)

if __name__ == '__main__':
    os.umask(0o077)
    Manager(sys.argv[1]).menu()
NETBIRD_UPDATE_PY
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
    printf '%s  [4] Updates and backup recovery%s\n' "$YELLOW" "$RESET"
    printf '  [0] Exit\n\n'
    read -r -p "${BOLD}Select an option: ${RESET}" choice || exit 0
    case "$choice" in
      1) install_server "${1:-}" ;;
      2) uninstall_server ;;
      3) status_server ;;
      4) update_menu ;;
      0) exit 0 ;;
      *) printf 'Please enter 0, 1, 2, 3 or 4.\n' ;;
    esac
    read -r -p 'Press Enter to return to the menu ...' answer || exit 0
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
