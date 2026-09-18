#!/usr/bin/env python3
"""Offline regressions for tested-image publication and moving-tag races."""
import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('publisher', Path(__file__).with_name('publish-tested-base.py'))
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)


class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.sha = 'a' * 40
        self.old = 'sha256:' + 'b' * 64
        self.new = 'sha256:' + 'c' * 64
        self.image = 'sha256:' + 'd' * 64
        self.alias = 'celeri/public-base:platform-upgrade'
        self.release = f'celeri/public-base:php8.5-{self.sha}-1234-1'
        self.environment = {
            'GITHUB_REPOSITORY': 'dtannen/celeri-public-base',
            'GITHUB_EVENT_NAME': 'push',
            'GITHUB_REF': publisher.UPGRADE_REF,
            'GITHUB_SHA': self.sha,
            'GITHUB_RUN_ID': '1234',
            'GITHUB_RUN_ATTEMPT': '1',
            'DOCKERHUB_PUBLISH_ENABLED': 'true',
            'PUBLISH_REQUESTED': 'false',
            'RELEASE_IMAGE': self.release,
            'LOCAL_IMAGE': 'celeri/public-base:check-8.5',
            'TESTED_IMAGE_ID': self.image,
            'BASE_ALIAS_BEFORE': self.old,
            'GITHUB_ENV': str(self.root / 'env'),
            'GITHUB_STEP_SUMMARY': str(self.root / 'summary'),
        }
        self.calls = []
        self.alias_digest = self.old
        self.branch_shas = [self.sha, self.sha]
        self.alias_read_count = 0
        self.race_on_alias_read = None

    def command(self, *arguments):
        self.calls.append(arguments)
        if arguments[:2] == ('git', 'ls-remote'):
            sha = self.branch_shas.pop(0)
            return f'{sha}\t{self.environment["GITHUB_REF"]}'
        if arguments[:3] == ('docker', 'image', 'inspect'):
            return self.image
        if arguments[:4] == ('docker', 'buildx', 'imagetools', 'inspect'):
            if arguments[4] == self.alias:
                self.alias_read_count += 1
                if self.alias_read_count == self.race_on_alias_read:
                    return 'sha256:' + 'e' * 64
                return self.alias_digest
            if arguments[4] == self.release:
                return self.new
        if arguments[:2] == ('docker', 'tag'):
            self.assertEqual(self.image, arguments[2], 'Tag the recorded image ID, never a mutable source tag.')
            return ''
        if arguments[:2] == ('docker', 'push'):
            if arguments[2] == self.alias:
                self.alias_digest = self.new
            return ''
        self.fail(f'Unexpected command: {arguments!r}')

    def publish(self):
        with patch.object(publisher, 'output', side_effect=self.command):
            publisher.publish(self.environment)

    def pushes(self):
        return [call[2] for call in self.calls if call[:2] == ('docker', 'push')]

    def test_success_pushes_the_recorded_image_and_promotes_matching_digest(self):
        self.publish()
        self.assertEqual([self.release, self.alias], self.pushes())
        self.assertIn(self.new, Path(self.environment['GITHUB_STEP_SUMMARY']).read_text())

    def test_disabled_publication_never_touches_registry(self):
        self.environment['DOCKERHUB_PUBLISH_ENABLED'] = 'false'
        with self.assertRaises(ValueError):
            self.publish()
        self.assertEqual([], self.calls)

    def test_untrusted_events_repositories_and_branches_cannot_publish(self):
        invalid = [
            ('GITHUB_EVENT_NAME', 'pull_request'),
            ('GITHUB_EVENT_NAME', 'pull_request_target'),
            ('GITHUB_EVENT_NAME', 'schedule'),
            ('GITHUB_REPOSITORY', 'someone/fork'),
            ('GITHUB_REF', 'refs/heads/another-branch'),
            ('GITHUB_REF', 'refs/tags/platform-upgrade'),
        ]
        for key, value in invalid:
            with self.subTest(key=key, value=value):
                environment = dict(self.environment, **{key: value})
                with self.assertRaises(ValueError):
                    publisher.validate(environment)

    def test_main_push_cannot_publish(self):
        self.environment['GITHUB_REF'] = 'refs/heads/main'
        with self.assertRaises(ValueError):
            self.publish()
        self.assertEqual([], self.calls)

    def test_manual_main_publishes_only_unique_image(self):
        self.environment.update(GITHUB_REF='refs/heads/main', GITHUB_EVENT_NAME='workflow_dispatch', PUBLISH_REQUESTED='true')
        self.publish()
        self.assertEqual([self.release], self.pushes())
        self.assertEqual(0, self.alias_read_count)

    def test_manual_check_only_cannot_publish(self):
        self.environment['GITHUB_EVENT_NAME'] = 'workflow_dispatch'
        with self.assertRaises(ValueError):
            self.publish()
        self.assertEqual([], self.calls)

    def test_changed_local_image_is_rejected(self):
        self.environment['TESTED_IMAGE_ID'] = 'sha256:' + 'e' * 64
        with self.assertRaisesRegex(ValueError, 'local image changed'):
            self.publish()
        self.assertEqual([], self.pushes())

    def test_superseded_branch_never_publishes(self):
        self.branch_shas[0] = 'f' * 40
        self.publish()
        self.assertEqual([], self.pushes())

    def test_branch_advancing_during_upload_does_not_move_alias(self):
        self.branch_shas[1] = 'f' * 40
        self.publish()
        self.assertEqual([self.release], self.pushes())

    def test_destination_changing_during_tests_is_rejected(self):
        self.race_on_alias_read = 1
        with self.assertRaisesRegex(ValueError, 'destination tag changed'):
            self.publish()
        self.assertEqual([], self.pushes())

    def test_destination_changing_during_upload_is_rejected(self):
        self.race_on_alias_read = 2
        with self.assertRaisesRegex(ValueError, 'destination tag changed'):
            self.publish()
        self.assertEqual([self.release], self.pushes())

    def test_prepare_records_existing_alias(self):
        with patch.object(publisher, 'output', side_effect=self.command):
            publisher.prepare(self.environment)
        self.assertEqual(f'BASE_ALIAS_BEFORE={self.old}\n', Path(self.environment['GITHUB_ENV']).read_text())

    def test_missing_destination_capture_prevents_any_push(self):
        self.environment.pop('BASE_ALIAS_BEFORE')
        with self.assertRaisesRegex(ValueError, 'not captured'):
            self.publish()
        self.assertEqual([], self.pushes())

    def test_registry_failure_is_not_treated_as_missing_tag(self):
        for message in ('unauthorized', 'dial tcp: timeout', 'credential helper: not found', '503 Service Unavailable'):
            with self.subTest(message=message):
                error = subprocess.CalledProcessError(1, ['docker'], stderr=message)
                with patch.object(publisher, 'output', side_effect=error):
                    with self.assertRaisesRegex(ValueError, 'authenticated registry'):
                        publisher.registry_digest(self.alias)

    def test_only_explicit_missing_manifest_is_absent(self):
        error = subprocess.CalledProcessError(1, ['docker'], stderr=f'ERROR: {self.alias}: not found')
        with patch.object(publisher, 'output', side_effect=error):
            self.assertEqual('absent', publisher.registry_digest(self.alias))

    def test_invalid_registry_digest_is_rejected(self):
        with patch.object(publisher, 'output', return_value='unexpected'):
            with self.assertRaisesRegex(ValueError, 'invalid image digest'):
                publisher.registry_digest(self.alias)

    def test_wrong_release_tag_cannot_publish(self):
        self.environment['RELEASE_IMAGE'] = 'celeri/public-base:latest'
        with self.assertRaisesRegex(ValueError, 'Release tag'):
            self.publish()
        self.assertEqual([], self.calls)


if __name__ == '__main__':
    unittest.main()
