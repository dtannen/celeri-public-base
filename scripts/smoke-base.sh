#!/usr/bin/env bash
# Run inside the base image with --network none; no application is required.
set -euo pipefail

bash "$(dirname "$0")/check-security-versions.sh"

php <<'PHP'
<?php
$required = ['apcu', 'bcmath', 'curl', 'gd', 'imap', 'intl', 'mbstring',
    'mysqli', 'pdo_mysql', 'pdo_pgsql', 'pdo_sqlite', 'redis', 'soap', 'xml',
    'zip', 'Zend OPcache'];
foreach ($required as $extension) {
    if (!extension_loaded($extension)) {
        throw new RuntimeException("Missing extension: {$extension}");
    }
}
if (ini_get('display_errors') || ini_get('display_startup_errors')) {
    throw new RuntimeException('PHP diagnostics must not enter HTTP/PDF output.');
}
if (ini_get('opcache.enable_cli') || opcache_get_status(false) !== false) {
    throw new RuntimeException('CLI OPcache must stay disabled to avoid a private cache per Horizon process.');
}
if (ini_get('memory_limit') !== '-1') {
    throw new RuntimeException('CLI must retain the pre-upgrade unlimited PHP memory limit.');
}
if (!class_exists('SoapClient') || count(imap_rfc822_parse_adrlist('smoke@example.test', 'example.test')) !== 1) {
    throw new RuntimeException('SOAP/IMAP smoke check failed.');
}
$db = new PDO('sqlite::memory:');
if ($db->query('SELECT 1')->fetchColumn() != 1) {
    throw new RuntimeException('SQLite smoke check failed.');
}
echo PHP_VERSION, " extensions OK\n";
PHP

python3 <<'PY'
import configparser
import json
from pathlib import Path
import pwd
import re
import stat
import subprocess

fpm_info = subprocess.check_output(['celeri-php-fpm', '-i'], text=True)
assert re.search(r'^opcache\.enable\s+=>\s+On\s+=>\s+On\s*$', fpm_info, re.MULTILINE), 'FPM OPcache must remain enabled'
assert re.search(r'^memory_limit\s+=>\s+512M\s+=>\s+512M\s*$', fpm_info, re.MULTILINE), 'FPM must retain its 512M memory limit'

fpm_config = subprocess.check_output(['celeri-php-fpm', '-tt'], stderr=subprocess.STDOUT, text=True)
runtime_user = pwd.getpwnam('www-data')
for name, directory in {
    'HOME': '/var/www/html/app/storage',
    'XDG_CONFIG_HOME': '/var/www/html/app/storage/.config',
    'XDG_CACHE_HOME': '/var/www/html/app/storage/.cache',
}.items():
    assert re.search(r'\benv\[' + name + r'\]\s*=\s*' + re.escape(directory) + r'\s*$', fpm_config, re.MULTILINE), f'FPM must set writable {name}'
    path = Path(directory)
    info = path.stat()
    assert path.is_dir() and info.st_uid == runtime_user.pw_uid and info.st_gid == runtime_user.pw_gid, f'{name} must belong to www-data'
    assert not stat.S_IMODE(info.st_mode) & 0o007, f'{name} must not be accessible to other users'

config = configparser.ConfigParser(interpolation=None)
config.read('/etc/supervisor/conf.d/supervisord.conf')
horizon = config['program:horizon']
assert horizon['user'] == 'www-data'
assert horizon['directory'] == '/var/www/html/app'
assert horizon['environment'] == 'HOME="/var/www/html/app/storage",USER="www-data"'
with open('/etc/highcharts-export-server.json') as source:
    exporter = json.load(source)
assert exporter['server']['host'] == '127.0.0.1'
assert exporter['highcharts']['useNpm'] is True
PY

celeri-php-fpm --test
nginx -t

# Match FPM's explicit renderer environment and privileges. Root-only Chrome
# checks cannot detect an inherited /root HOME breaking www-data requests.
renderer_output=$(mktemp -d /tmp/celeri-base-renderers.XXXXXX)
trap 'rm -rf -- "$renderer_output"' EXIT
chown www-data:www-data "$renderer_output"
renderer_command=(runuser -u www-data -- env
    HOME=/var/www/html/app/storage
    XDG_CONFIG_HOME=/var/www/html/app/storage/.config
    XDG_CACHE_HOME=/var/www/html/app/storage/.cache
    CELERI_RENDERER_OUTPUT="$renderer_output")
"${renderer_command[@]}" node <<'JS'
const fs = require('fs');
const puppeteer = require('/usr/lib/node_modules/puppeteer');
(async () => {
    if (process.getuid() === 0) throw new Error('Renderer smoke checks must not run as root');
    const browser = await puppeteer.launch({
        args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage'],
    });
    try {
        const page = await browser.newPage();
        await page.setContent('<h1 style="font-family: National">Report smoke check</h1>');
        const pdfPath = `${process.env.CELERI_RENDERER_OUTPUT}/report.pdf`;
        await page.pdf({path: pdfPath});
        const pdf = fs.readFileSync(pdfPath);
        if (pdf.length < 1000 || !pdf.subarray(0, 5).equals(Buffer.from('%PDF-'))) {
            throw new Error('Invalid/empty PDF');
        }
    } finally {
        await browser.close();
    }
})().catch(error => { console.error(error); process.exit(1); });
JS

(
    # Highcharts runs as root under Supervisor and caches bundled scripts in its
    # installation directory. Preserve that service identity; the direct Chrome
    # PDF check above exercises FPM's www-data identity. Keep CLI logs temporary.
    cd "$renderer_output"
    highcharts-export-server --loadConfig /etc/highcharts-export-server.json \
        --instr '{"title":{"text":"Chart smoke check"},"series":[{"data":[1,3,2]}]}' \
        --outfile "$renderer_output/chart.png"
)
"${renderer_command[@]}" python3 <<'PY'
import os
from pathlib import Path
png = (Path(os.environ['CELERI_RENDERER_OUTPUT']) / 'chart.png').read_bytes()
assert png.startswith(b'\x89PNG\r\n\x1a\n') and len(png) > 1000, 'Invalid/empty chart PNG'
PY
