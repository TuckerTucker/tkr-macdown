"""The post-build release stage, driven with an injected command runner.

The runner is a collaborator here, not the unit under test: it stands in for
``codesign``, ``ditto`` and ``notarytool`` so the ordering and refusal logic
of :func:`build_for_release.release_app` can be exercised on a real app tree
in a temporary directory.
"""

from __future__ import annotations

import json
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path
from typing import Optional, Sequence

import support
from build_for_release import ReleaseOptions, release_app
from release_steps import ReleaseError

IDENTITY = 'Developer ID Application: Example (TEAM123456)'


class RecordingRunner:
    """Records commands; produces the outputs the real tools would."""

    def __init__(self, notary_status: str = 'Accepted') -> None:
        self.notary_status = notary_status
        self.commands: list[list[str]] = []

    def __call__(self, args: Sequence[str], *,
                 cwd: Optional[Path] = None) -> str:
        args = list(args)
        self.commands.append(args)
        if args[0] == 'ditto' and '-c' in args:
            Path(args[-1]).write_bytes(b'PK\x03\x04' + args[-2].encode())
        if args[:2] == ['xcrun', 'notarytool']:
            return json.dumps({'id': 'sub-1', 'status': self.notary_status})
        return ''

    def tools(self) -> list[str]:
        return [Path(c[0]).name if c[0] != 'xcrun' else c[1]
                for c in self.commands]


class ReleaseAppTests(unittest.TestCase):

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)
        self.app = support.build_app_tree(self.root)
        entitlements = self.root / 'release.entitlements'
        entitlements.write_text('')
        self.options = ReleaseOptions(
            identity=IDENTITY, notary_profile=None, build_dir=self.root,
            entitlements=entitlements)

    def rebuild_info(self, **info: str) -> None:
        support.write_plist(self.app / 'Contents' / 'Info.plist',
                            support.app_info(**info))

    def test_development_build_is_refused_before_anything_is_signed(
            self) -> None:
        self.rebuild_info(short_version='0.8.0d77')
        runner = RecordingRunner()
        with self.assertRaisesRegex(ReleaseError, 'development version'):
            release_app(self.app, self.options, runner)
        self.assertEqual(runner.commands, [])

    def test_missing_entitlements_are_refused_before_signing(self) -> None:
        runner = RecordingRunner()
        with self.assertRaisesRegex(ReleaseError, 'Entitlements'):
            release_app(self.app, replace(
                self.options, entitlements=self.root / 'missing'), runner)
        self.assertEqual(runner.commands, [])

    def test_build_is_signed_verified_and_zipped(self) -> None:
        runner = RecordingRunner()
        result = release_app(self.app, self.options, runner)

        tools = runner.tools()
        self.assertEqual(tools[-2:], ['codesign', 'ditto'])
        signs = [c for c in runner.commands
                 if c[0] == 'codesign' and '--sign' in c]
        self.assertEqual(Path(signs[-1][-1]), self.app)
        verify = runner.commands[len(signs)]
        self.assertEqual(verify[:4],
                         ['codesign', '--verify', '--deep', '--strict'])
        self.assertNotIn('notarytool', tools)
        self.assertFalse(result.notarized)

        self.assertEqual(result.archive.name, 'MacDown-0.8.1.zip')
        self.assertTrue(result.archive.is_file())
        zipped = runner.commands[-1]
        self.assertEqual(zipped[-2:], [str(self.app), str(result.archive)])

    def test_notarization_staples_and_assesses_before_zipping(self) -> None:
        runner = RecordingRunner()
        result = release_app(
            self.app, replace(self.options, notary_profile='p'), runner)
        tools = runner.tools()
        order = [tools.index(t) for t in ('notarytool', 'stapler', 'spctl')]
        self.assertEqual(order, sorted(order))
        final_zip = [c for c in runner.commands
                     if c[0] == 'ditto' and c[-1].endswith('0.8.1.zip')]
        self.assertGreater(runner.commands.index(final_zip[0]),
                           tools.index('spctl'))
        self.assertTrue(result.notarized)

    def test_rejected_notarization_produces_no_archive(self) -> None:
        runner = RecordingRunner(notary_status='Invalid')
        with self.assertRaisesRegex(ReleaseError, 'Invalid'):
            release_app(self.app, replace(self.options, notary_profile='p'),
                        runner)
        self.assertFalse((self.root / 'MacDown-0.8.1.zip').exists())


if __name__ == '__main__':
    unittest.main()
