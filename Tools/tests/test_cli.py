"""Command-line and environment option resolution."""

from __future__ import annotations

import contextlib
import io
import unittest

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
            ['--identity', IDENTITY, '--notary-profile', 'notary'], {})
        self.assertEqual(options.identity, IDENTITY)
        self.assertEqual(options.notary_profile, 'notary')
        self.assertEqual(options.entitlements, support.TOOLS_DIR
                         / 'MacDown-release.entitlements')

    def test_environment_supplies_defaults(self) -> None:
        options = parse_args([], {
            'MACDOWN_SIGNING_IDENTITY': IDENTITY,
            'MACDOWN_NOTARY_PROFILE': 'notary',
        })
        self.assertEqual(options.identity, IDENTITY)
        self.assertEqual(options.notary_profile, 'notary')

    def test_defaults_skip_notarization(self) -> None:
        options = parse_args(['--identity', IDENTITY], {})
        self.assertIsNone(options.notary_profile)

    def test_update_options_are_gone(self) -> None:
        self.rejects(['--identity', IDENTITY, '--beta'], {})
        self.rejects(['--identity', IDENTITY, '--public-ed-key', 'K='], {})

    def test_flag_overrides_environment(self) -> None:
        options = parse_args(['--identity', IDENTITY],
                             {'MACDOWN_SIGNING_IDENTITY': 'ignored'})
        self.assertEqual(options.identity, IDENTITY)


if __name__ == '__main__':
    unittest.main()
