"""Public-key parsing and merge fixtures; no private keys, SSH, users, or AWS."""
import base64
from contextlib import redirect_stdout
import io
from pathlib import Path
import re
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch
import yaml

DIRECTORY = Path(__file__).resolve().parent
SCRIPT = (DIRECTORY / 'setup-ssh.sh').read_text(encoding='utf-8')
SOURCE = SCRIPT.split('  python3.13 - "$@" <<\'PY\'\n', 1)[1].split('\nPY\n}', 1)[0]
HELPER = {}
exec(compile(SOURCE.split('\ntry:\n    main()', 1)[0], 'ssh-public-key-helper', 'exec'), HELPER)


def field(value):
    return struct.pack('>I', len(value)) + value


def rsa_fixture(bits=3072, low_bits=1, comment='NOVA-classkey'):
    # Synthetic public modulus, not a generated or usable private key.
    modulus = ((1 << (bits - 1)) | low_bits).to_bytes((bits + 7) // 8, 'big')
    if modulus[0] & 128:
        modulus = b'\0' + modulus
    blob = field(b'ssh-rsa') + field(b'\x01\0\x01') + field(modulus)
    return 'ssh-rsa ' + base64.b64encode(blob).decode('ascii') + ' ' + comment


CONFIGURATION = '''pubkeyauthentication yes
passwordauthentication no
kbdinteractiveauthentication no
permitrootlogin prohibit-password
authorizedkeysfile .ssh/authorized_keys .ssh/authorized_keys2
pubkeyacceptedalgorithms ssh-ed25519,rsa-sha2-512,rsa-sha2-256
'''


class SshPreparationFixtures(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='ssh-test-', dir=DIRECTORY)
        self.directory = Path(self.temporary.name).resolve()
        self.assertTrue(self.directory.is_relative_to(DIRECTORY))

    def tearDown(self):
        self.temporary.cleanup()

    def run_helper(self, command, *args):
        output = io.StringIO()
        with patch.object(sys, 'argv', ['ssh-public-key-helper', command, *map(str, args)]), redirect_stdout(output):
            HELPER['main']()
        return output.getvalue().strip()

    def test_template_contains_only_one_scoped_rule(self):
        template = yaml.safe_load((DIRECTORY / 'ssh-access.yaml').read_text(encoding='utf-8'))
        self.assertEqual(set(template['Parameters']), {'GroupId', 'ClientIpv4Cidr'})
        resources = template['Resources']
        self.assertEqual(len(resources), 1)
        rule = resources['ClassSshIngress']
        self.assertEqual(rule['Type'], 'AWS::EC2::SecurityGroupIngress')
        self.assertEqual(rule['Properties']['GroupId'], {'Ref': 'GroupId'})
        self.assertEqual(rule['Properties']['CidrIp'], {'Ref': 'ClientIpv4Cidr'})
        self.assertEqual((rule['Properties']['IpProtocol'], rule['Properties']['FromPort'], rule['Properties']['ToPort']),
                         ('tcp', 22, 22))

    def test_template_rejects_ranges_and_invalid_ipv4(self):
        template = yaml.safe_load((DIRECTORY / 'ssh-access.yaml').read_text(encoding='utf-8'))
        pattern = re.compile(template['Parameters']['ClientIpv4Cidr']['AllowedPattern'])
        self.assertIsNotNone(pattern.fullmatch('203.0.113.10/32'))
        for address in ('0.0.0.0/0', '203.0.113.0/24', '256.1.2.3/32', '1.2.3/32', '::1/128'):
            self.assertIsNone(pattern.fullmatch(address))

    def test_decode_accepts_one_rsa_3072_public_key(self):
        public = rsa_fixture()
        target = self.directory / 'client.pub'
        self.run_helper('decode', base64.b64encode((public + '\n').encode('ascii')).decode('ascii'), target)
        self.assertEqual(target.read_text(encoding='ascii'), public + '\n')

    def test_decode_rejects_wrong_size_comment_options_or_multiple_keys(self):
        for public in (rsa_fixture(2048), rsa_fixture(comment='other-comment'),
                       'no-pty ' + rsa_fixture(), rsa_fixture() + '\n' + rsa_fixture(low_bits=3)):
            with self.subTest(public_type=public.split()[0]), self.assertRaises(ValueError):
                HELPER['key_line'](public, 'ssh-rsa', 'NOVA-classkey')

    def test_decode_rejects_non_public_key_content(self):
        target = self.directory / 'client.pub'
        encoded = base64.b64encode(b'-----BEGIN OPENSSH PRIVATE KEY-----\nFAKE-FIXTURE').decode('ascii')
        with self.assertRaises(ValueError):
            self.run_helper('decode', encoded, target)
        self.assertFalse(target.exists())

    def test_merge_preserves_existing_bytes_and_adds_one_key(self):
        existing = b'# Existing comment\r\n' + rsa_fixture(low_bits=3).encode('ascii')
        merged, added = HELPER['merge_authorized'](existing, rsa_fixture())
        self.assertTrue(added)
        self.assertTrue(merged.startswith(existing + b'\n'))
        self.assertTrue(merged.endswith(rsa_fixture().encode('ascii') + b'\n'))

    def test_merge_is_idempotent_despite_different_comment(self):
        existing = rsa_fixture(comment='existing-comment').encode('ascii') + b'\n'
        merged, added = HELPER['merge_authorized'](existing, rsa_fixture())
        self.assertFalse(added)
        self.assertEqual(merged, existing)

    def test_merge_does_not_weaken_existing_key_options(self):
        existing = ('command="echo restricted command",no-pty ' + rsa_fixture() + '\n').encode('ascii')
        merged, added = HELPER['merge_authorized'](existing, rsa_fixture())
        self.assertFalse(added)
        self.assertEqual(merged, existing)

    def test_host_output_requires_public_ed25519_format(self):
        source = self.directory / 'host.pub'
        blob = field(b'ssh-ed25519') + field(bytes(range(32)))
        public = 'ssh-ed25519 ' + base64.b64encode(blob).decode('ascii') + ' fixture-host'
        source.write_text(public + '\n', encoding='ascii')
        self.assertEqual(self.run_helper('host', source), public)
        source.write_text('-----BEGIN OPENSSH PRIVATE KEY-----\nFAKE-FIXTURE', encoding='ascii')
        with self.assertRaises(ValueError):
            self.run_helper('host', source)

    def test_configuration_requires_existing_key_only_authentication(self):
        source = self.directory / 'sshd.conf'
        source.write_text(CONFIGURATION, encoding='utf-8')
        self.assertEqual(self.run_helper('configuration', source), 'prohibit-password')
        for before, after in [('passwordauthentication no', 'passwordauthentication yes'),
                              ('kbdinteractiveauthentication no', 'kbdinteractiveauthentication yes'),
                              ('permitrootlogin prohibit-password', 'permitrootlogin yes'),
                              ('pubkeyauthentication yes', 'pubkeyauthentication no'),
                              ('rsa-sha2-512,rsa-sha2-256', 'ssh-rsa')]:
            source.write_text(CONFIGURATION.replace(before, after), encoding='utf-8')
            with self.subTest(setting=before), self.assertRaises(ValueError):
                self.run_helper('configuration', source)


if __name__ == '__main__':
    unittest.main()
