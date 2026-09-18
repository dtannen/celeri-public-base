#!/usr/bin/env bash
# Validate installed files, not just upstream metadata in a scanner's SBOM.
set -euo pipefail

# Ubuntu retains upstream Python versions when it backports security fixes.
# USN-8379-1 and USN-8712-1 identify these minimum Resolute package revisions.
for requirement in 'python3-urllib3 2.6.3-1ubuntu1.1' 'python3-pyasn1 0.6.3-1ubuntu0.1'; do
    read -r package minimum <<< "$requirement"
    installed=$(dpkg-query -W -f='${Version}' "$package")
    if ! dpkg --compare-versions "$installed" ge "$minimum"; then
        printf '%s %s is older than patched Ubuntu revision %s\n' "$package" "$installed" "$minimum" >&2
        exit 1
    fi
    printf '%s %s: Ubuntu security fixes present\n' "$package" "$installed"
done

# A pip-installed shadow copy would invalidate the distro-package evidence.
python3 <<'PY'
from pathlib import Path
import urllib3
import pyasn1
for module in (urllib3, pyasn1):
    expected = Path('/usr/lib/python3/dist-packages') / module.__name__ / '__init__.py'
    if Path(module.__file__).resolve() != expected:
        raise SystemExit(f'{module.__name__} must load from its Ubuntu package: {module.__file__}')
PY

node <<'JS'
const root = '/usr/local/lib/node_modules/npm';
const semver = require(`${root}/node_modules/semver`);
const minimums = { 'ip-address': '10.3.1', 'brace-expansion': '5.0.9', tar: '7.5.21' };
for (const [name, minimum] of Object.entries(minimums)) {
    const { version } = require(`${root}/node_modules/${name}/package.json`);
    if (!semver.gte(version, minimum)) {
        throw new Error(`npm's ${name}@${version} is older than patched ${minimum}`);
    }
    console.log(`npm's ${name}@${version}: security version check passed`);
}
JS
