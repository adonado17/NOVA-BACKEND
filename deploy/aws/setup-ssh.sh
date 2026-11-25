#!/usr/bin/env bash
# Run as root through SSM. The argument is an encoded PUBLIC key, never a private key.
# Usage: bash setup-ssh.sh PUBLIC_KEY_BASE64 [EXPECTED_HOST_SHA256_FINGERPRINT]
set -Eeuo pipefail
set +x
umask 077
runtime_dir=''
log() { printf '[nova-class-ssh] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
cleanup() {
  local status=$?
  trap - EXIT
  if [[ "$runtime_dir" == /run/nova-class-ssh.* && -d "$runtime_dir" ]]; then
    rm -f -- "$runtime_dir"/*
    rmdir -- "$runtime_dir" || true
  fi
  exit "$status"
}
trap cleanup EXIT

public_key_helper() {
  python3.13 - "$@" <<'PY'
import base64
import os
from pathlib import Path
import secrets
import shlex
import stat
import struct
import sys

def fields(blob):
    result = []
    while blob:
        if len(blob) < 4:
            raise ValueError('Truncated public key')
        length = struct.unpack('>I', blob[:4])[0]
        if length > len(blob) - 4:
            raise ValueError('Invalid public key field')
        result.append(blob[4:4 + length])
        blob = blob[4 + length:]
    return result

def key_line(text, algorithm, comment=None):
    text = text.strip()
    if '\n' in text or '\r' in text or '\x00' in text:
        raise ValueError('Only one public key is accepted')
    parts = text.split(maxsplit=2)
    if len(parts) < 2 or parts[0] != algorithm or (comment is not None and parts[2:] != [comment]):
        raise ValueError('Unexpected public key format')
    values = fields(base64.b64decode(parts[1], validate=True))
    if algorithm == 'ssh-rsa':
        if len(values) != 3 or values[0] != b'ssh-rsa':
            raise ValueError('Invalid RSA public key')
        exponent, modulus = (int.from_bytes(value, 'big') for value in values[1:])
        if exponent < 3 or exponent % 2 != 1 or modulus.bit_length() != 3072:
            raise ValueError('Expected an RSA 3072-bit public key')
    elif len(values) != 2 or values[0] != b'ssh-ed25519' or len(values[1]) != 32:
        raise ValueError('Expected an Ed25519 host public key')
    return ' '.join(parts)

def merge_authorized(existing, public_key):
    algorithm, encoded, _ = public_key.split(maxsplit=2)
    for line in existing.splitlines():
        if not line.strip() or line.lstrip().startswith(b'#'):
            continue
        scanner = shlex.shlex(line.decode('utf-8', errors='replace'), posix=True)
        scanner.whitespace_split = True
        scanner.commenters = ''
        try:
            first = next(scanner)
            if first == algorithm:
                candidate = next(scanner)
            elif next(scanner) == algorithm:
                candidate = next(scanner)
            else:
                continue
            if candidate == encoded:
                return existing, False
        except (StopIteration, ValueError):
            continue
    separator = b'\n' if existing and not existing.endswith(b'\n') else b''
    return existing + separator + public_key.encode('ascii') + b'\n', True

def authorize(user_id, group_id, user_home, public_key):
    user_id, group_id = int(user_id), int(group_id)
    if user_id <= 0 or user_home != '/home/ec2-user' or os.path.realpath(user_home) != user_home:
        raise ValueError('Unexpected account home')
    directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    home_fd = os.open(user_home, directory_flags)
    ssh_fd = None
    temporary = None
    try:
        home = os.fstat(home_fd)
        if home.st_uid != user_id or home.st_mode & 0o022:
            raise ValueError('Home ownership or write permissions are unsafe')
        created = False
        try:
            os.mkdir('.ssh', 0o700, dir_fd=home_fd)
            created = True
        except FileExistsError:
            pass
        ssh_fd = os.open('.ssh', directory_flags, dir_fd=home_fd)
        if created:
            os.fchown(ssh_fd, user_id, group_id)
        if os.fstat(ssh_fd).st_uid != user_id:
            raise ValueError('Unexpected .ssh owner')
        os.fchmod(ssh_fd, 0o700)
        original = None
        existing = b''
        try:
            key_fd = os.open('authorized_keys', os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=ssh_fd)
        except FileNotFoundError:
            key_fd = None
        if key_fd is not None:
            with os.fdopen(key_fd, 'rb') as stream:
                original = os.fstat(stream.fileno())
                if (not stat.S_ISREG(original.st_mode) or original.st_uid != user_id
                        or original.st_nlink != 1 or original.st_size > 1024 * 1024):
                    raise ValueError('Unexpected authorized_keys file')
                existing = stream.read(1024 * 1024 + 1)
                if len(existing) > 1024 * 1024:
                    raise ValueError('authorized_keys exceeds the safety limit')
                os.fchmod(stream.fileno(), 0o600)
        merged, added = merge_authorized(existing, public_key)
        if not added:
            return False
        temporary = '.authorized_keys.nova-' + secrets.token_hex(12)
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                             0o600, dir_fd=ssh_fd)
        with os.fdopen(descriptor, 'wb') as stream:
            os.fchown(stream.fileno(), user_id, group_id)
            os.fchmod(stream.fileno(), 0o600)
            stream.write(merged)
            stream.flush()
            os.fsync(stream.fileno())
        try:
            current = os.stat('authorized_keys', dir_fd=ssh_fd, follow_symlinks=False)
        except FileNotFoundError:
            current = None
        if original is None:
            if current is not None:
                raise ValueError('authorized_keys changed concurrently')
        elif current is None or (current.st_dev, current.st_ino, current.st_size, current.st_mtime_ns) != (
                original.st_dev, original.st_ino, original.st_size, original.st_mtime_ns):
            raise ValueError('authorized_keys changed concurrently')
        os.replace(temporary, 'authorized_keys', src_dir_fd=ssh_fd, dst_dir_fd=ssh_fd)
        temporary = None
        os.fsync(ssh_fd)
        return True
    finally:
        if temporary is not None and ssh_fd is not None:
            os.unlink(temporary, dir_fd=ssh_fd)
        if ssh_fd is not None:
            os.close(ssh_fd)
        os.close(home_fd)

def main():
    command, *args = sys.argv[1:]
    if command == 'decode':
        encoded, destination = args
        if len(encoded) > 16384:
            raise ValueError('Public key argument is too large')
        text = base64.b64decode(encoded, validate=True).decode('ascii')
        public_key = key_line(text, 'ssh-rsa', 'NOVA-classkey')
        Path(destination).write_text(public_key + '\n', encoding='ascii')
    elif command == 'host':
        print(key_line(Path(args[0]).read_text(encoding='ascii'), 'ssh-ed25519'))
    elif command == 'configuration':
        lines = [line.split(maxsplit=1) for line in Path(args[0]).read_text(encoding='utf-8').splitlines()]
        config = dict(line for line in lines if len(line) == 2)
        if (config.get('pubkeyauthentication') != 'yes' or config.get('passwordauthentication') != 'no'
                or config.get('kbdinteractiveauthentication') != 'no'
                or config.get('permitrootlogin') not in ('no', 'prohibit-password', 'without-password', 'forced-commands-only')):
            raise ValueError('Existing SSH authentication settings need review')
        expected = {'.ssh/authorized_keys', '%h/.ssh/authorized_keys',
                    '/home/ec2-user/.ssh/authorized_keys', '/home/%u/.ssh/authorized_keys'}
        if not expected.intersection(config.get('authorizedkeysfile', '').split()):
            raise ValueError('SSH does not use the expected authorized_keys location')
        algorithms = config.get('pubkeyacceptedalgorithms', '').split(',')
        if not {'rsa-sha2-256', 'rsa-sha2-512'}.intersection(algorithms):
            raise ValueError('Existing SSH configuration does not accept RSA SHA-2 signatures')
        print(config['permitrootlogin'])
    elif command == 'authorize':
        user_id, group_id, user_home, source = args
        public_key = key_line(Path(source).read_text(encoding='ascii'), 'ssh-rsa', 'NOVA-classkey')
        print('added' if authorize(user_id, group_id, user_home, public_key) else 'present')
    else:
        raise ValueError('Unknown operation')

try:
    main()
except Exception:
    print('SSH preparation validation failed; key contents are not displayed.', file=sys.stderr)
    raise SystemExit(1)
PY
}

[[ $EUID -eq 0 ]] || die 'Run as root through SSM.'
[[ $# -eq 1 || $# -eq 2 ]] || die 'Expected PUBLIC_KEY_BASE64 [EXPECTED_HOST_SHA256_FINGERPRINT].'
for executable in python3.13 ssh-keygen systemctl getent flock /usr/sbin/sshd; do
  command -v "$executable" >/dev/null 2>&1 || die "Required executable not found: $executable"
done
exec 9>/run/lock/nova-class-ssh.lock
flock -n 9 || die 'Another SSH preparation is running.'
runtime_dir=$(mktemp -d /run/nova-class-ssh.XXXXXXXX)
public_key_helper decode "$1" "$runtime_dir/client.pub"
client_info=$(ssh-keygen -l -E sha256 -f "$runtime_dir/client.pub")
[[ "$client_info" != *$'\n'* && "$client_info" == '3072 SHA256:'*' (RSA)' ]] || die 'Expected one RSA 3072-bit public key.'

host_file=/etc/ssh/ssh_host_ed25519_key.pub
[[ -f "$host_file" && ! -L "$host_file" ]] || die 'An existing Ed25519 host public key is required.'
host_public_key=$(public_key_helper host "$host_file")
host_info=$(ssh-keygen -l -E sha256 -f "$host_file")
[[ "$host_info" != *$'\n'* && "$host_info" == '256 SHA256:'*' (ED25519)' ]] || die 'Expected one Ed25519 host key.'
read -r host_bits host_fingerprint host_comment <<< "$host_info"
if [[ $# -eq 2 ]]; then
  [[ "$2" =~ ^SHA256:[A-Za-z0-9+/]{43}$ ]] || die 'Expected a SHA256 host fingerprint.'
  [[ "$2" == "$host_fingerprint" ]] || die 'The existing host fingerprint differs from the expected value.'
fi

account_name='' account_uid='' account_gid='' user_home=''
IFS=: read -r account_name account_password account_uid account_gid account_gecos user_home account_shell < <(getent passwd ec2-user)
[[ "$account_name" == ec2-user && "$account_uid" =~ ^[0-9]+$ && "$account_gid" =~ ^[0-9]+$ ]] || die 'The existing ec2-user account is required.'
[[ "$user_home" == /home/ec2-user && "$account_uid" != 0 ]] || die 'Unexpected ec2-user home or UID.'
/usr/sbin/sshd -t
/usr/sbin/sshd -T > "$runtime_dir/sshd-effective.conf"
root_login_setting=$(public_key_helper configuration "$runtime_dir/sshd-effective.conf")
if ! systemctl is-active --quiet sshd.service; then systemctl start sshd.service; fi
systemctl is-active --quiet sshd.service || die 'sshd.service did not become active.'
key_status=$(public_key_helper authorize "$account_uid" "$account_gid" "$user_home" "$runtime_dir/client.pub")
/usr/sbin/sshd -t
systemctl is-active --quiet sshd.service || die 'sshd.service is not active.'

printf 'SSH_USER=ec2-user\nSSH_PORT=22\nAUTHORIZED_KEY=%s\n' "$key_status"
printf 'CLIENT_PUBLIC_KEY_FINGERPRINT=%s\n' "$client_info"
printf 'HOST_PUBLIC_KEY=%s\nHOST_FINGERPRINT=%s\n' "$host_public_key" "$host_fingerprint"
printf 'EXISTING_PERMIT_ROOT_LOGIN=%s\n' "$root_login_setting"
log 'Existing keys and sshd settings were preserved. Verify the host fingerprint before the first login.'
