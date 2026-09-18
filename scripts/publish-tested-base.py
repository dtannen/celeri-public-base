#!/usr/bin/env python3
"""Publish the loaded, tested base without rebuilding or running the image."""
import os
import re
import subprocess
import sys
from pathlib import Path

REPOSITORY = 'celeri/public-base'
UPGRADE_REF = 'refs/heads/codex/platform-upgrade-2026'
DIGEST = re.compile(r'sha256:[0-9a-f]{64}')


def output(*command):
    return subprocess.check_output(command, text=True, stderr=subprocess.PIPE).strip()


def validate(environment):
    event = environment.get('GITHUB_EVENT_NAME')
    branch = environment.get('GITHUB_REF')
    allowed = (
        environment.get('GITHUB_REPOSITORY') == 'dtannen/celeri-public-base'
        and environment.get('DOCKERHUB_PUBLISH_ENABLED') == 'true'
        and branch in ('refs/heads/main', UPGRADE_REF)
        and ((event == 'push' and branch == UPGRADE_REF)
             or (event == 'workflow_dispatch' and environment.get('PUBLISH_REQUESTED') == 'true'))
    )
    if not allowed:
        raise ValueError('Publication is restricted to enabled, trusted upgrade pushes or explicit manual runs.')
    sha = environment.get('GITHUB_SHA', '')
    if not re.fullmatch(r'[0-9a-f]{40}', sha):
        raise ValueError('Invalid source commit.')
    for field in ('GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT'):
        if not re.fullmatch(r'[1-9][0-9]*', environment.get(field, '')):
            raise ValueError('Invalid workflow run identity.')
    release = f"{REPOSITORY}:php8.5-{sha}-{environment['GITHUB_RUN_ID']}-{environment['GITHUB_RUN_ATTEMPT']}"
    if environment.get('RELEASE_IMAGE') != release:
        raise ValueError('Release tag does not match this commit and run.')
    return release, f'{REPOSITORY}:platform-upgrade' if branch == UPGRADE_REF else None


def registry_digest(reference):
    try:
        digest = output('docker', 'buildx', 'imagetools', 'inspect', reference,
                        '--format', '{{.Manifest.Digest}}')
    except subprocess.CalledProcessError as error:
        message = (error.stderr or '').strip().removeprefix('ERROR: ')
        absent = {'manifest unknown', 'manifest unknown: manifest unknown'}
        for prefix in (reference, f'docker.io/{reference}'):
            absent.update((f'{prefix}: not found', f'{prefix}: manifest unknown'))
        if message in absent:
            return 'absent'
        raise ValueError('Cannot read the published image; check authenticated registry access.') from None
    if not DIGEST.fullmatch(digest):
        raise ValueError('Registry returned an invalid image digest.')
    return digest


def current_commit(environment):
    response = output('git', 'ls-remote', '--exit-code', 'origin', environment['GITHUB_REF'])
    parts = response.split()
    if len(parts) != 2 or parts[1] != environment['GITHUB_REF']:
        raise ValueError('Cannot verify the current branch commit.')
    return parts[0] == environment['GITHUB_SHA']


def prepare(environment):
    _, alias = validate(environment)
    if alias:
        with Path(environment['GITHUB_ENV']).open('a') as destination:
            destination.write(f'BASE_ALIAS_BEFORE={registry_digest(alias)}\n')


def publish(environment):
    release, alias = validate(environment)
    tested = environment.get('TESTED_IMAGE_ID', '')
    if not DIGEST.fullmatch(tested):
        raise ValueError('The image identity recorded before tests is missing or invalid.')
    actual = output('docker', 'image', 'inspect', environment['LOCAL_IMAGE'], '--format', '{{.Id}}')
    if actual != tested:
        raise ValueError('The local image changed after its identity was recorded for testing.')
    if not current_commit(environment):
        print('::notice::A newer branch commit exists; skipping superseded image publication.')
        return
    if alias:
        before = environment.get('BASE_ALIAS_BEFORE', '')
        if before != 'absent' and not DIGEST.fullmatch(before):
            raise ValueError('The publication destination was not captured before the build.')
        if registry_digest(alias) != before:
            raise ValueError('The destination tag changed during this build; refusing competing publication.')
    output('docker', 'tag', tested, release)
    output('docker', 'push', release)
    digest = registry_digest(release)
    if digest == 'absent':
        raise ValueError('The pushed release manifest is missing.')
    published_alias = False
    if alias:
        # A Docker Hub build could still have been finishing at cutover. Recheck
        # after uploading layers, immediately before moving the public alias.
        if not current_commit(environment):
            print('::notice::A newer branch commit exists; keeping the unique image without promoting its tag.')
        elif registry_digest(alias) != before:
            raise ValueError('The destination tag changed during upload; refusing competing publication.')
        else:
            output('docker', 'tag', tested, alias)
            output('docker', 'push', alias)
            if registry_digest(alias) != digest:
                raise ValueError('Published alias does not match the tested release digest.')
            published_alias = True
    with Path(environment['GITHUB_STEP_SUMMARY']).open('a') as summary:
        summary.write(f'### Tested PHP 8.5 base image\n\nPublished `{release}`\n\n')
        summary.write(f'Immutable reference: `{REPOSITORY}@{digest}`\n\n')
        if published_alias:
            summary.write(f'Updated `{alias}` to that same digest.\n')
        elif alias:
            summary.write('The moving tag was not updated because the branch advanced.\n')


if __name__ == '__main__':
    try:
        if sys.argv[1:] == ['--prepare']:
            prepare(os.environ)
        elif not sys.argv[1:]:
            publish(os.environ)
        else:
            raise ValueError('Usage: publish-tested-base.py [--prepare]')
    except (KeyError, OSError, ValueError, subprocess.CalledProcessError) as error:
        # Never print subprocess diagnostics which might include credential-helper output.
        message = str(error) if isinstance(error, ValueError) else 'Base publication failed; check workflow configuration and registry access.'
        print(f'::error::{message}', file=sys.stderr)
        sys.exit(1)
