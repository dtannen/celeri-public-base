#!/usr/bin/env bash
# Run inside the base image with --network none; no application is required.
set -euo pipefail

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
node <<'JS'
const fs = require('fs');
const puppeteer = require('/usr/lib/node_modules/puppeteer');
(async () => {
    const browser = await puppeteer.launch({
        args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage'],
    });
    try {
        const page = await browser.newPage();
        await page.setContent('<h1 style="font-family: National">Report smoke check</h1>');
        await page.pdf({path: '/tmp/base-smoke-report.pdf'});
        if (fs.statSync('/tmp/base-smoke-report.pdf').size < 1000) {
            throw new Error('Empty PDF');
        }
    } finally {
        await browser.close();
    }
})().catch(error => { console.error(error); process.exit(1); });
JS

highcharts-export-server --loadConfig /etc/highcharts-export-server.json \
    --instr '{"title":{"text":"Chart smoke check"},"series":[{"data":[1,3,2]}]}' \
    --outfile /tmp/base-smoke-chart.png
python3 <<'PY'
from pathlib import Path
png = Path('/tmp/base-smoke-chart.png').read_bytes()
assert png.startswith(b'\x89PNG\r\n\x1a\n') and len(png) > 1000, 'Invalid/empty chart PNG'
PY
