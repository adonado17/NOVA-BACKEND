#!/usr/bin/env bash
# Run as root through SSM. Never use bash -x. All arguments are public identifiers.
# prepare ARTIFACT_BUCKET ARTIFACT_KEY AWS_REGION CORS_ORIGINS [SHA256]
# cutover FRONTEND_HTTPS_ORIGIN PUBLIC_IPV4
set -Eeuo pipefail
set +x
umask 077
export AWS_PAGER='' AWS_CLI_AUTO_PROMPT=off

stage='initialization'
runtime_dir=''
backup_dir=''
release_dir=''
previous_link=''
candidate_was_active=0
restore_candidate=0
restore_primary=0
completed=0

log() { printf '[nova-api] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# Validation and rendering are local operations; this helper never prints secrets.
helper() {
  python3.13 - "$@" <<'PY'
import ipaddress
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import sys
from urllib.parse import urlsplit
import zipfile

def origin(value):
    url = urlsplit(value)
    if (url.scheme not in ('http', 'https') or not url.hostname
            or not re.fullmatch(r'[a-zA-Z0-9.-]+', url.hostname)
            or url.username or url.password or url.path not in ('', '/')
            or url.query or url.fragment):
        raise ValueError('Invalid origin')
    port = url.port
    default = 443 if url.scheme == 'https' else 80
    return f'{url.scheme}://{url.hostname.lower()}' + (f':{port}' if port and port != default else '')

def write_env(source, destination, port, origins):
    source = Path(source)
    info = source.stat()
    if source.is_symlink() or info.st_uid != 0 or info.st_mode & 0o077:
        raise ValueError('Environment file must be root-owned and private')
    content = source.read_text(encoding='utf-8')
    if '\x00' in content or not all(re.search(rf'(?m)^{key}=', content)
                                   for key in ('MONGODB_URI', 'JWT_SECRET')):
        raise ValueError('Missing private runtime configuration')
    lines = [line for line in content.splitlines()
             if not re.match(r'^(?:NODE_ENV|PORT|CORS_ORIGINS)=', line)]
    encoded = origins.replace('\\', '\\\\').replace('"', '\\"')
    lines += ['NODE_ENV=production', f'PORT={port}', f'CORS_ORIGINS="{encoded}"']
    Path(destination).write_text('\n'.join(lines) + '\n', encoding='utf-8')
    os.chmod(destination, 0o600)

def main():
    command, *args = sys.argv[1:]
    if command == 'prepare-arguments':
        bucket, key, region, raw = args
        if not re.fullmatch(r'[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]', bucket):
            raise ValueError('Invalid artifact bucket')
        if not key or key.startswith('/') or any(ord(c) < 32 for c in key):
            raise ValueError('Invalid artifact key')
        if not re.fullmatch(r'[a-z]{2}(?:-gov)?-[a-z]+-[0-9]+', region):
            raise ValueError('Invalid region')
        origins = [origin(item.strip()) for item in raw.split(',') if item.strip()]
        if not origins:
            raise ValueError('At least one frontend origin is required')
        print(','.join(dict.fromkeys(origins)))
    elif command == 'cutover-arguments':
        raw, address = args
        target = origin(raw)
        ip = ipaddress.IPv4Address(address)
        if not ip.is_global or not target.startswith('https://') or target == f'https://{ip}':
            raise ValueError('HTTPS frontend and public API IPv4 must be distinct')
        print(target)
    elif command == 'extract':
        archive_path, destination = args
        required = {'package.json', 'package-lock.json', 'src/server.js', 'src/app.js'}
        with zipfile.ZipFile(archive_path) as archive:
            names = set()
            total = 0
            if len(archive.infolist()) > 10000:
                raise ValueError('Too many archive entries')
            for item in archive.infolist():
                name = item.filename
                parts = PurePosixPath(name).parts
                mode = stat.S_IFMT(item.external_attr >> 16)
                normalized = PurePosixPath(name).as_posix().rstrip('/')
                if (not parts or name.startswith('/') or '\\' in name or '..' in parts
                        or any(ord(char) < 32 for char in name)
                        or any(':' in part for part in parts) or normalized in names
                        or mode not in (0, stat.S_IFREG, stat.S_IFDIR)):
                    raise ValueError('Unsafe archive entry')
                if (any(part in ('.git', 'node_modules', '.aws') for part in parts)
                        or any((part == '.env' or part.startswith('.env.')) and part != '.env.example'
                               for part in parts)
                        or Path(name).suffix.lower() in ('.pem', '.key', '.p12', '.pfx')
                        or parts[-1] in ('id_rsa', 'id_dsa', 'id_ed25519', '.npmrc', 'credentials', 'credentials.json')):
                    raise ValueError('Private files or installed dependencies in artifact')
                names.add(normalized)
                total += item.file_size
                if total > 512 * 1024 * 1024:
                    raise ValueError('Artifact exceeds size limit')
            if not required.issubset(names):
                raise ValueError('Expected standalone backend at archive root')
            archive.extractall(destination)
        package = json.loads((Path(destination) / 'package.json').read_text(encoding='utf-8-sig'))
        if package.get('name') != 'nova-studio-backend' or not package.get('dependencies'):
            raise ValueError('Unexpected backend package')
    elif command == 'sha256':
        path, expected = args
        if not re.fullmatch(r'[a-fA-F0-9]{64}', expected):
            raise ValueError('Invalid SHA256')
        with Path(path).open('rb') as stream:
            actual = hashlib.file_digest(stream, 'sha256').hexdigest()
        if actual != expected.lower():
            raise ValueError('Artifact SHA256 mismatch')
    elif command == 'environment':
        write_env(*args)
    elif command == 'write-state':
        target, release, origins = args
        Path(target).write_text(json.dumps({'release': release, 'origins': origins}) + '\n', encoding='utf-8')
        os.chmod(target, 0o600)
    elif command == 'read-state':
        source = Path(args[0])
        info = source.stat()
        if source.is_symlink() or info.st_uid != 0 or info.st_mode & 0o077:
            raise ValueError('Candidate metadata must be root-owned and private')
        value = json.loads(source.read_text(encoding='utf-8'))
        release = Path(value['release'])
        if (release.parent != Path('/opt/nova/api-releases') or release.is_symlink()
                or not (release / 'src/server.js').is_file()):
            raise ValueError('Invalid candidate release')
        origins = ','.join(origin(item) for item in value['origins'].split(','))
        print(release)
        print(origins)
    elif command == 'ready':
        body = json.loads(Path(args[0]).read_text(encoding='utf-8'))
        if body.get('status') != 'ready':
            raise ValueError('API is not ready')
    elif command == 'frontend':
        if not re.search(r'<app-root(?:\s|>)', Path(args[0]).read_text(encoding='utf-8')):
            raise ValueError('Frontend did not return the Angular application')
    elif command == 'cors':
        path, expected = args
        lines = Path(path).read_text(encoding='iso-8859-1').splitlines()
        headers = dict(line.split(':', 1) for line in lines if ':' in line and not line.startswith('HTTP/'))
        headers = {key.lower().strip(): value.strip() for key, value in headers.items()}
        if (headers.get('access-control-allow-origin') != expected
                or 'authorization' not in headers.get('access-control-allow-headers', '').lower()
                or 'access-control-allow-credentials' in headers):
            raise ValueError('Candidate CORS verification failed')
    elif command == 'nginx':
        source, destination, frontend = args
        text = Path(source).read_text(encoding='utf-8')
        if 'ssl_certificate /etc/letsencrypt/live/nova-ip/fullchain.pem;' not in text:
            raise ValueError('Unexpected TLS configuration; review before changing it')
        pattern = re.compile(r'^([ \t]*)location[ \t]+/[ \t]*\{[ \t]*\n(.*?)^\1\}', re.M | re.S)
        candidates = [match for match in pattern.finditer(text)
                      if 'proxy_pass http://127.0.0.1:3000;' in match.group(2)]
        if len(candidates) == 1:
            match = candidates[0]
            indent, body = match.group(1), match.group(2)
            aliases = {'registro.html': 'register', 'iniciar-sesion.html': 'login', 'perfil.html': 'profile'}
            if any(f'location = /{alias}' in text for alias in aliases):
                raise ValueError('Review existing legacy redirects')
            redirects = ''.join(f'{indent}location = /{alias} {{ return 302 {frontend}/{route}$is_args$args; }}\n'
                                for alias, route in aliases.items())
            replacement = (f'{indent}location = /api {{\n{body}{indent}}}\n'
                           f'{indent}location ^~ /api/ {{\n{body}{indent}}}\n'
                           f'{redirects}'
                           f'{indent}location / {{ return 302 {frontend}$request_uri; }}')
        elif not candidates:
            redirects = list(re.finditer(r'^([ \t]*)location / \{ return 302 https://[^;\s]+\$request_uri; \}', text, re.M))
            exact_api = re.findall(r'^([ \t]*)location = /api \{\n(.*?)^\1\}', text, re.M | re.S)
            subtree_api = re.findall(r'^([ \t]*)location \^~ /api/ \{\n(.*?)^\1\}', text, re.M | re.S)
            if (len(redirects) != 1 or len(exact_api) != 1 or len(subtree_api) != 1
                    or any('proxy_pass http://127.0.0.1:3000;' not in body
                           for _, body in exact_api + subtree_api)):
                raise ValueError('Unexpected existing API proxy configuration')
            match = redirects[0]
            replacement = f'{match.group(1)}location / {{ return 302 {frontend}$request_uri; }}'
        else:
            raise ValueError('Expected exactly one existing HTTPS root proxy')
        result = text[:match.start()] + replacement + text[match.end():]
        if not candidates:
            for alias, route in {'registro.html': 'register', 'iniciar-sesion.html': 'login', 'perfil.html': 'profile'}.items():
                alias_pattern = re.compile(r'^([ \t]*)location = /' + re.escape(alias) + r' \{ return 302 [^;\s]+; \}', re.M)
                result, count = alias_pattern.subn(lambda item: f'{item.group(1)}location = /{alias} {{ return 302 {frontend}/{route}$is_args$args; }}', result)
                if count != 1:
                    raise ValueError('Missing or duplicate legacy redirect')
        Path(destination).write_text(result, encoding='utf-8')
    else:
        raise ValueError('Unknown helper operation')

try:
    main()
except Exception:
    print('NOVA activation validation failed; private values are not displayed.', file=sys.stderr)
    raise SystemExit(1)
PY
}

wait_ready() {
  local attempts=30
  until curl --fail --silent --max-time 5 --noproxy '*' "$@" --output "$runtime_dir/ready.json" \
      && helper ready "$runtime_dir/ready.json" 2>/dev/null; do
    attempts=$((attempts - 1))
    (( attempts > 0 )) || return 1
    sleep 3
  done
}

check_cors() {
  local base=$1 origin=$2 status
  shift 2
  status=$(curl --silent --max-time 10 --noproxy '*' "$@" --output /dev/null \
    --dump-header "$runtime_dir/cors.headers" --write-out '%{http_code}' \
    --request OPTIONS --header "Origin: $origin" \
    --header 'Access-Control-Request-Method: POST' \
    --header 'Access-Control-Request-Headers: Authorization, Content-Type' "$base/api/reservations") || return 1
  [[ "$status" == 204 ]] && helper cors "$runtime_dir/cors.headers" "$origin"
}

backup_file() {
  if [[ -f "$1" && ! -L "$1" ]]; then cp -p -- "$1" "$2";
  elif [[ ! -e "$1" && ! -L "$1" ]]; then touch "$2.absent";
  else die 'Expected an ordinary configuration file.'; fi
}

restore_file() {
  if [[ -f "$1.absent" ]]; then rm -f -- "$2"; else cp -p -- "$1" "$2"; fi
}

switch_link() {
  if [[ -e "$2.next" && ! -L "$2.next" ]]; then
    log 'Refusing to replace a non-symlink staging path.'
    return 1
  fi
  ln -sfn -- "$1" "$2.next"
  mv -Tf -- "$2.next" "$2"
}

cleanup() {
  local status=$?
  local rollback_ok=1
  trap - EXIT
  set +e
  if (( status != 0 && completed == 0 )); then
    log "Failed during $stage; private values are not displayed."
    if (( restore_primary == 1 )); then
      systemctl stop nova.service || rollback_ok=0
      restore_file "$backup_dir/nova.service" /etc/systemd/system/nova.service || rollback_ok=0
      restore_file "$backup_dir/api.env" /etc/nova/api.env || rollback_ok=0
      restore_file "$backup_dir/nova.conf" /etc/nginx/conf.d/nova.conf || rollback_ok=0
      if [[ -n "$previous_link" ]]; then switch_link "$previous_link" /opt/nova/current-api || rollback_ok=0;
      else rm -f -- /opt/nova/current-api || rollback_ok=0; fi
      systemctl daemon-reload || rollback_ok=0
      if systemctl restart nova.service && wait_ready http://127.0.0.1:3000/api/ready && (( rollback_ok == 1 )); then
        log 'Previous service restored and readiness verified.'
      else log 'ROLLBACK NEEDS ATTENTION: previous service did not become ready.'; fi
      if nginx -t && systemctl reload nginx.service \
          && wait_ready --connect-to "$public_ip:443:127.0.0.1:443" "https://$public_ip/api/ready" \
          && (( rollback_ok == 1 )); then log 'Previous Nginx and HTTPS readiness restored.';
      else log 'ROLLBACK NEEDS ATTENTION: verify Nginx through SSM.'; fi
    elif (( restore_candidate == 1 )); then
      systemctl stop nova-api-candidate.service
      restore_file "$runtime_dir/candidate.service" /etc/systemd/system/nova-api-candidate.service
      restore_file "$runtime_dir/candidate.env" /etc/nova/api-candidate.env
      restore_file "$runtime_dir/candidate.json" /var/lib/nova-api-deploy/candidate.json
      systemctl daemon-reload
      if (( candidate_was_active == 1 )); then
        if systemctl start nova-api-candidate.service && wait_ready http://127.0.0.1:3001/api/ready; then
          log 'Previous candidate readiness verified.'
        else log 'ROLLBACK NEEDS ATTENTION: previous candidate is not ready.'; fi
      fi
      log 'Production service was not changed.'
    fi
    [[ -z "$release_dir" ]] || log "Release retained: $release_dir"
  fi
  if [[ "$runtime_dir" == /run/nova-api-activate.* && -d "$runtime_dir" ]]; then
    rm -f -- "$runtime_dir"/*
    rmdir -- "$runtime_dir"
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

[[ $EUID -eq 0 ]] || die 'Run as root through Systems Manager.'
[[ $# -ge 1 ]] || die 'Expected prepare or cutover.'
phase=$1
shift
[[ "$phase" == prepare || "$phase" == cutover ]] || die 'Expected prepare or cutover.'
exec 9>/run/lock/nova-activate.lock
flock -n 9 || die 'Another NOVA activation is running.'
runtime_dir=$(mktemp -d /run/nova-api-activate.XXXXXXXX)
for executable in curl python3.13 runuser nginx systemctl /usr/bin/node-24 /usr/bin/npm-24; do
  command -v "$executable" >/dev/null 2>&1 || die "Missing executable: $executable"
done
id nova >/dev/null 2>&1 || die 'The nova service user must already exist.'
[[ -f /var/lib/nova/bootstrap-ready && -f /etc/nova/nova.env ]] || die 'Existing NOVA configuration is required.'
[[ -f /etc/systemd/system/nova.service && -f /etc/nginx/conf.d/nova.conf ]] || die 'Existing service and Nginx configuration are required.'
[[ -z "$(systemctl show nova.service --property DropInPaths --value)" ]] || die 'Review nova.service drop-ins before changing its unit.'
systemctl is-active --quiet nginx.service || die 'Existing Nginx must be active.'
nginx -t
[[ ! -L /var/lib/nova-api-deploy ]] || die 'Deployment state directory must not be a symlink.'
install -d -o root -g root -m 0700 /var/lib/nova-api-deploy

write_unit() {
  local target=$1 directory=$2 environment=$3 description=$4
  cat > "$target" <<UNIT
[Unit]
Description=$description
Wants=network-online.target
After=network-online.target
ConditionPathExists=$directory/src/server.js
ConditionPathExists=$environment

[Service]
Type=simple
User=nova
Group=nova
WorkingDirectory=$directory
Environment=HOME=/var/lib/nova
EnvironmentFile=$environment
ExecStart=/usr/bin/node-24 $directory/src/server.js
Restart=on-failure
RestartSec=5
TimeoutStopSec=15
KillSignal=SIGTERM
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT
}

if [[ "$phase" == prepare ]]; then
  [[ $# -eq 4 || $# -eq 5 ]] || die 'prepare requires BUCKET KEY REGION CORS_ORIGINS [SHA256].'
  bucket=$1 artifact_key=$2 region=$3
  cors_origins=$(helper prepare-arguments "$bucket" "$artifact_key" "$region" "$4")
  expected_sha=${5:-}
  command -v aws >/dev/null 2>&1 || die 'AWS CLI must already be installed.'
  stage='checking the existing application'
  wait_ready http://127.0.0.1:3000/api/ready || die 'Existing application is not ready; production was not changed.'
  stage='preparing the standalone release'
  install -d -o root -g root -m 0755 /opt/nova/api-releases /opt/nova/node24-bin
  release_dir=$(mktemp -d "/opt/nova/api-releases/$(date -u +%Y%m%dT%H%M%SZ)-XXXXXXXX")
  aws s3 cp "s3://$bucket/$artifact_key" "$runtime_dir/api.zip" --region "$region" --only-show-errors --no-progress
  [[ -z "$expected_sha" ]] || helper sha256 "$runtime_dir/api.zip" "$expected_sha"
  helper extract "$runtime_dir/api.zip" "$release_dir"
  chmod 0755 "$release_dir"
  chown -R nova:nova "$release_dir"
  ln -sfn /usr/bin/node-24 /opt/nova/node24-bin/node
  ln -sfn /usr/bin/npm-24 /opt/nova/node24-bin/npm
  (
    cd "$release_dir"
    runuser -u nova -- env -i HOME=/var/lib/nova \
      PATH=/opt/nova/node24-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin \
      /usr/bin/npm-24 ci --omit=dev --no-audit --no-fund
  )
  helper environment /etc/nova/nova.env "$runtime_dir/new-candidate.env" 3001 "$cors_origins"
  write_unit "$runtime_dir/new-candidate.service" "$release_dir" /etc/nova/api-candidate.env 'NOVA standalone API candidate'
  backup_file /etc/systemd/system/nova-api-candidate.service "$runtime_dir/candidate.service"
  backup_file /etc/nova/api-candidate.env "$runtime_dir/candidate.env"
  backup_file /var/lib/nova-api-deploy/candidate.json "$runtime_dir/candidate.json"
  if systemctl is-active --quiet nova-api-candidate.service; then candidate_was_active=1; fi
  restore_candidate=1
  stage='starting the isolated candidate on port 3001'
  install -o root -g root -m 0600 "$runtime_dir/new-candidate.env" /etc/nova/api-candidate.env
  install -o root -g root -m 0644 "$runtime_dir/new-candidate.service" /etc/systemd/system/nova-api-candidate.service
  systemctl daemon-reload
  systemctl restart nova-api-candidate.service
  wait_ready http://127.0.0.1:3001/api/ready || die 'Candidate failed readiness.'
  check_cors http://127.0.0.1:3001 "${cors_origins%%,*}" || die 'Candidate failed CORS preflight.'
  helper write-state "$runtime_dir/new-candidate.json" "$release_dir" "$cors_origins"
  install -o root -g root -m 0600 "$runtime_dir/new-candidate.json" /var/lib/nova-api-deploy/candidate.json
  completed=1
  log 'Candidate is ready on port 3001. nova.service, public Nginx and original secrets were preserved.'
else
  [[ $# -eq 2 ]] || die 'cutover requires FRONTEND_HTTPS_ORIGIN PUBLIC_IPV4.'
  frontend=$(helper cutover-arguments "$@")
  public_ip=$2
  mapfile -t candidate < <(helper read-state /var/lib/nova-api-deploy/candidate.json)
  [[ ${#candidate[@]} -eq 2 ]] || die 'No validated candidate state.'
  release_dir=${candidate[0]} cors_origins=${candidate[1]}
  [[ ",$cors_origins," == *",$frontend,"* ]] || die 'Frontend origin is absent from candidate CORS_ORIGINS.'
  [[ ! -e /opt/nova/current-api || -L /opt/nova/current-api ]] || die 'current-api must be a symlink.'
  [[ "$(systemctl show nova-api-candidate.service --property WorkingDirectory --value)" == "$release_dir" ]] || die 'Candidate unit does not match its release.'
  systemctl is-active --quiet nova-api-candidate.service || die 'Prepare the candidate first.'
  wait_ready http://127.0.0.1:3001/api/ready || die 'Candidate is not ready.'
  check_cors http://127.0.0.1:3001 "$frontend" || die 'Candidate CORS does not allow the frontend.'
  stage='verifying the frontend before changing production'
  curl --fail --silent --location --max-redirs 3 --max-time 30 --proto '=https' --proto-redir '=https' \
    --output "$runtime_dir/frontend.html" "$frontend/" || die 'Frontend HTTPS is unavailable.'
  helper frontend "$runtime_dir/frontend.html"
  helper environment /etc/nova/api-candidate.env "$runtime_dir/new-api.env" 3000 "$cors_origins"
  write_unit "$runtime_dir/new-api.service" /opt/nova/current-api /etc/nova/api.env 'NOVA standalone API'
  helper nginx /etc/nginx/conf.d/nova.conf "$runtime_dir/new-nginx.conf" "$frontend"
  install -d -o root -g root -m 0700 /var/lib/nova-api-deploy/rollbacks
  backup_dir=$(mktemp -d "/var/lib/nova-api-deploy/rollbacks/$(date -u +%Y%m%dT%H%M%SZ)-XXXXXXXX")
  backup_file /etc/systemd/system/nova.service "$backup_dir/nova.service"
  backup_file /etc/nova/api.env "$backup_dir/api.env"
  backup_file /etc/nginx/conf.d/nova.conf "$backup_dir/nova.conf"
  if [[ -L /opt/nova/current-api ]]; then previous_link=$(readlink /opt/nova/current-api); fi
  printf '%s\n' "$previous_link" > "$backup_dir/previous-link"
  restore_primary=1
  stage='activating the API on port 3000'
  install -o root -g root -m 0644 "$runtime_dir/new-nginx.conf" /etc/nginx/conf.d/nova.conf
  nginx -t
  systemctl stop nova.service
  switch_link "$release_dir" /opt/nova/current-api
  install -o root -g root -m 0600 "$runtime_dir/new-api.env" /etc/nova/api.env
  install -o root -g root -m 0644 "$runtime_dir/new-api.service" /etc/systemd/system/nova.service
  systemctl daemon-reload
  systemctl start nova.service
  wait_ready http://127.0.0.1:3000/api/ready || die 'API failed readiness after cutover.'
  systemctl reload nginx.service
  stage='verifying HTTPS and CORS after cutover'
  wait_ready --connect-to "$public_ip:443:127.0.0.1:443" "https://$public_ip/api/ready" || die 'HTTPS readiness failed.'
  check_cors "https://$public_ip" "$frontend" --connect-to "$public_ip:443:127.0.0.1:443" || die 'HTTPS CORS failed.'
  location=$(curl --fail --silent --max-time 10 --noproxy '*' --connect-to "$public_ip:443:127.0.0.1:443" \
    --output /dev/null --write-out '%{redirect_url}' "https://$public_ip/")
  [[ "$location" == "$frontend/" ]] || die 'Root redirect does not point to the frontend.'
  systemctl stop nova-api-candidate.service
  completed=1
  log "API cutover verified. Previous configuration retained in $backup_dir."
  log 'The original monorepo release, certificate files and renewal timer were not changed.'
fi
