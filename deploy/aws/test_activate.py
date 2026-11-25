"""Local fixtures for the activation's validation/rendering; no AWS or services."""
from contextlib import redirect_stdout
import io
import hashlib
import json
from pathlib import Path
import stat
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import zipfile

DIRECTORY = Path(__file__).resolve().parent
SCRIPT = (DIRECTORY / 'activate.sh').read_text(encoding='utf-8')
SOURCE = SCRIPT.split('  python3.13 - "$@" <<\'PY\'\n', 1)[1].split('\nPY\n}', 1)[0]
HELPER = {}
exec(compile(SOURCE.split('\ntry:\n    main()', 1)[0], 'activation-helper', 'exec'), HELPER)

NGINX = '''server {
    listen 80 default_server;
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/letsencrypt;
        try_files $uri =404;
    }
    location / { return 301 https://3.19.116.135$request_uri; }
}
server {
    listen 443 ssl default_server;
    ssl_certificate /etc/letsencrypt/live/nova-ip/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/nova-ip/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Authorization $http_authorization;
        proxy_set_header Host $host;
    }
}
'''


class ActivationFixtures(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='activation-test-', dir=DIRECTORY)
        self.directory = Path(self.temporary.name).resolve()
        self.assertTrue(self.directory.is_relative_to(DIRECTORY))

    def tearDown(self):
        self.temporary.cleanup()

    def run_helper(self, command, *args):
        output = io.StringIO()
        with patch.object(sys, 'argv', ['activation-helper', command, *map(str, args)]), redirect_stdout(output):
            HELPER['main']()
        return output.getvalue().strip()

    def archive(self, extra=(), monorepo=False):
        path = self.directory / 'api.zip'
        with zipfile.ZipFile(path, 'w') as archive:
            archive.writestr('package.json', json.dumps({'name': 'nova-studio-backend', 'dependencies': {'express': '5'}}))
            archive.writestr('package-lock.json', '{}')
            prefix = 'backend/' if monorepo else ''
            archive.writestr(prefix + 'src/server.js', '// fixture')
            archive.writestr(prefix + 'src/app.js', '// fixture')
            for name in extra:
                archive.writestr(name, 'fixture')
        return path

    def test_prepare_normalizes_public_origins(self):
        result = self.run_helper('prepare-arguments', 'nova-artifacts', 'releases/api.zip', 'us-east-2',
                                 'https://d123.cloudfront.net/,https://d123.cloudfront.net,http://localhost:4200')
        self.assertEqual(result, 'https://d123.cloudfront.net,http://localhost:4200')

    def test_prepare_rejects_wildcards_credentials_and_paths(self):
        for origin in ('*', 'https://*.example.com', 'https://user:password@example.com', 'https://example.com/login', ''):
            with self.subTest(origin=origin), self.assertRaises(ValueError):
                self.run_helper('prepare-arguments', 'nova-artifacts', 'api.zip', 'us-east-2', origin)

    def test_cutover_requires_distinct_https_frontend_and_public_ipv4(self):
        self.assertEqual(self.run_helper('cutover-arguments', 'https://d123.cloudfront.net/', '3.19.116.135'),
                         'https://d123.cloudfront.net')
        for frontend, ip in [('http://d123.cloudfront.net', '3.19.116.135'),
                             ('https://d123.cloudfront.net', '127.0.0.1'),
                             ('https://3.19.116.135', '3.19.116.135')]:
            with self.subTest(frontend=frontend, ip=ip), self.assertRaises(ValueError):
                self.run_helper('cutover-arguments', frontend, ip)

    def test_extract_accepts_standalone_backend(self):
        destination = self.directory / 'release'
        self.run_helper('extract', self.archive(), destination)
        self.assertTrue((destination / 'src/server.js').is_file())

    def test_sha256_validates_downloaded_artifact_bytes(self):
        archive = self.archive()
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        self.run_helper('sha256', archive, digest)
        for invalid in ('0' * 64, 'not-a-hash'):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                self.run_helper('sha256', archive, invalid)

    def test_extract_rejects_monorepo_layout(self):
        with self.assertRaises(ValueError):
            self.run_helper('extract', self.archive(monorepo=True), self.directory / 'release')

    def test_extract_rejects_private_files_and_traversal(self):
        for name in ('../escape', 'src/../../escape', '.env', 'src/.env.production', 'src/key.pem',
                     'node_modules/package/index.js', '.git/config', '.aws/credentials'):
            with self.subTest(name=name), self.assertRaises(ValueError):
                self.run_helper('extract', self.archive([name]), self.directory / 'release')
        self.assertFalse((self.directory.parent / 'escape').exists())

    def test_extract_rejects_duplicate_normalized_paths(self):
        with self.assertRaises(ValueError):
            self.run_helper('extract', self.archive(['src//app.js']), self.directory / 'release')

    def test_extract_rejects_symlinks(self):
        archive = self.archive()
        with zipfile.ZipFile(archive, 'a') as stream:
            entry = zipfile.ZipInfo('src/link')
            entry.create_system = 3
            entry.external_attr = (stat.S_IFLNK | 0o777) << 16
            stream.writestr(entry, '/etc/passwd')
        with self.assertRaises(ValueError):
            self.run_helper('extract', archive, self.directory / 'release')

    def test_runtime_copy_preserves_private_values_without_printing(self):
        source = self.directory / 'private.fixture'
        original = ('MONGODB_URI="mongodb+srv://PLACEHOLDER/fixture"\n'
                    'JWT_SECRET="FAKE-FIXTURE-$-VALUE-\\\\-WITH-QUOTES-\\\""\nPORT=3000\n')
        source.write_text(original, encoding='utf-8')
        destination = self.directory / 'candidate.fixture'
        metadata = SimpleNamespace(st_uid=0, st_mode=stat.S_IFREG | 0o600)
        with patch.object(Path, 'stat', return_value=metadata):
            output = self.run_helper('environment', source, destination, '3001', 'https://d123.cloudfront.net')
        self.assertEqual(output, '')
        self.assertEqual(source.read_text(encoding='utf-8'), original)
        result = destination.read_text(encoding='utf-8')
        self.assertIn(original.splitlines()[0], result)
        self.assertIn(original.splitlines()[1], result)
        self.assertIn('PORT=3001\n', result)
        self.assertNotIn('PORT=3000', result)

    def test_nginx_preserves_tls_and_acme_and_proxies_both_api_paths(self):
        source, destination = self.directory / 'nginx.conf', self.directory / 'new.conf'
        source.write_text(NGINX, encoding='utf-8')
        self.run_helper('nginx', source, destination, 'https://d123.cloudfront.net')
        result = destination.read_text(encoding='utf-8')
        self.assertEqual(result.split('server {')[1], NGINX.split('server {')[1])
        for line in ('ssl_certificate /etc/letsencrypt/live/nova-ip/fullchain.pem;',
                     'ssl_certificate_key /etc/letsencrypt/live/nova-ip/privkey.pem;',
                     'ssl_protocols TLSv1.2 TLSv1.3;', 'location = /api {', 'location ^~ /api/ {'):
            self.assertIn(line, result)
        self.assertEqual(result.count('proxy_pass http://127.0.0.1:3000;'), 2)
        self.assertIn('return 302 https://d123.cloudfront.net$request_uri;', result)
        for alias, route in [('registro.html', 'register'), ('iniciar-sesion.html', 'login'), ('perfil.html', 'profile')]:
            self.assertIn(f'location = /{alias} {{ return 302 https://d123.cloudfront.net/{route}$is_args$args; }}', result)
        self.assertEqual(source.read_text(encoding='utf-8'), NGINX)

    def test_nginx_supports_later_api_updates(self):
        source, first, second = [self.directory / name for name in ('old.conf', 'first.conf', 'second.conf')]
        source.write_text(NGINX, encoding='utf-8')
        self.run_helper('nginx', source, first, 'https://d123.cloudfront.net')
        self.run_helper('nginx', first, second, 'https://d456.cloudfront.net')
        result = second.read_text(encoding='utf-8')
        self.assertIn('return 302 https://d456.cloudfront.net$request_uri;', result)
        self.assertEqual(result.count('location = /api {'), 1)
        self.assertEqual(result.count('proxy_pass http://127.0.0.1:3000;'), 2)
        self.assertIn('return 302 https://d456.cloudfront.net/login$is_args$args;', result)

    def test_nginx_rejects_unrecognized_configuration(self):
        source = self.directory / 'nginx.conf'
        source.write_text('server { listen 443; }', encoding='utf-8')
        with self.assertRaises(ValueError):
            self.run_helper('nginx', source, self.directory / 'new.conf', 'https://d123.cloudfront.net')

    def test_readiness_requires_ready(self):
        source = self.directory / 'ready.json'
        source.write_text('{"status":"ready"}', encoding='utf-8')
        self.run_helper('ready', source)
        source.write_text('{"status":"unavailable"}', encoding='utf-8')
        with self.assertRaises(ValueError):
            self.run_helper('ready', source)


if __name__ == '__main__':
    unittest.main()
