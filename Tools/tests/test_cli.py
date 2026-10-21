"""Command-line and environment option resolution."""

from __future__ import annotations

import contextlib
import io
import unittest
from pathlib import Path

import support
from build_for_release import parse_args

IDENTITY = 'Developer ID Application: Example (TEAM123456)'


class ParseArgsTests(unittest.TestCase):

    def rejects(self, argv: list[str], environ: dict[str, str]) -> str:
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            with self.assertRaises(SystemExit) as caught:
                parse_args(argv, environ)
        self.assertEqual(caught.exception.code, 2)
        return stderr.getvalue()

    def test_identity_is_required(self) -> None:
        self.assertIn('signing identity is required', self.rejects([], {}))

    def test_non_developer_id_identity_is_rejected(self) -> None:
        message = self.rejects(
            ['--identity', 'Apple Development: me (X59D3X3VUS)'], {})
        self.assertIn('Developer ID Application', message)

    def test_flags_resolve(self) -> None:
        options = parse_args(
            ['--identity', IDENTITY, '--beta', '--notary-profile', 'notary',
             '--public-ed-key', ' KEY= ', '--ed-key-file', 'k.pem'], {})
        self.assertEqual(options.identity, IDENTITY)
        self.assertTrue(options.beta)
        self.assertEqual(options.notary_profile, 'notary')
        self.assertEqual(options.public_ed_key, 'KEY=')
        self.assertEqual(options.ed_key_file, Path('k.pem'))
        self.assertEqual(options.repository, 'TuckerTucker/tkr-macdown')
        self.assertEqual(options.appcast, support.REPO_ROOT / 'appcast.xml')

    def test_environment_supplies_defaults(self) -> None:
        options = parse_args([], {
            'MACDOWN_SIGNING_IDENTITY': IDENTITY,
            'SPARKLE_PUBLIC_ED_KEY': 'KEY=',
            'SPARKLE_ED_KEY_FILE': '/secure/ed.key',
            'MACDOWN_NOTARY_PROFILE': 'notary',
        })
        self.assertEqual(options.identity, IDENTITY)
        self.assertEqual(options.public_ed_key, 'KEY=')
        self.assertEqual(options.ed_key_file, Path('/secure/ed.key'))
        self.assertEqual(options.notary_profile, 'notary')
        self.assertFalse(options.beta)

    def test_defaults_skip_notarization_and_use_keychain(self) -> None:
        options = parse_args(['--identity', IDENTITY], {})
        self.assertIsNone(options.notary_profile)
        self.assertIsNone(options.ed_key_file)
        self.assertIsNone(options.public_ed_key)

    def test_flag_overrides_environment(self) -> None:
        options = parse_args(['--identity', IDENTITY],
                             {'MACDOWN_SIGNING_IDENTITY': 'ignored'})
        self.assertEqual(options.identity, IDENTITY)


if __name__ == '__main__':
    unittest.main()
