"""The post-build release stage, driven with an injected command runner.

The runner is a collaborator here, not the unit under test: it stands in for
``codesign``, ``ditto``, ``notarytool`` and ``sign_update`` so the ordering and
refusal logic of :func:`build_for_release.release_app` can be exercised on a
real app tree in a temporary directory. ``sign_update`` is replaced by a real
Ed25519 signature over the real archive bytes.
"""

from __future__ import annotations

import base64
import datetime as dt
import json
import shutil
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path
from typing import Optional, Sequence
from xml.etree import ElementTree as ET

import support
from build_for_release import ReleaseOptions, release_app
from cryptography.hazmat.primitives.asymmetric.ed25519 import (
    Ed25519PrivateKey,
)
from cryptography.hazmat.primitives.serialization import (
    Encoding,
    PublicFormat,
)
from sparkle_release import SPARKLE_NS, ReleaseError

IDENTITY = 'Developer ID Application: Example (TEAM123456)'
NOW = dt.datetime(2026, 10, 21, 12, 0, tzinfo=dt.timezone.utc)


class RecordingRunner:
    """Records commands; produces the outputs the real tools would."""

    def __init__(self, signer: Ed25519PrivateKey,
                 notary_status: str = 'Accepted') -> None:
        self.signer = signer
        self.notary_status = notary_status
        self.commands: list[list[str]] = []

    def __call__(self, args: Sequence[str], *,
                 cwd: Optional[Path] = None) -> str:
        args = list(args)
        self.commands.append(args)
        if args[0] == 'ditto' and '-c' in args:
            Path(args[-1]).write_bytes(b'PK\x03\x04' + args[-2].encode())
        if args[0].endswith('sign_update'):
            data = Path(args[-1]).read_bytes()
            return base64.b64encode(self.signer.sign(data)).decode() + '\n'
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
        self.key = Ed25519PrivateKey.generate()
        public = self.key.public_key().public_bytes(Encoding.Raw,
                                                    PublicFormat.Raw)
        self.app = support.build_app_tree(
            self.root, support.app_info(public_ed_key=support.b64(public)))
        sparkle_bin = self.root / 'bin'
        sparkle_bin.mkdir()
        (sparkle_bin / 'sign_update').write_text('')
        entitlements = self.root / 'release.entitlements'
        entitlements.write_text('')
        self.appcast = self.root / 'appcast.xml'
        shutil.copy(support.REPO_ROOT / 'appcast.xml', self.appcast)
        self.options = ReleaseOptions(
            identity=IDENTITY, public_ed_key=None, ed_key_file=None,
            ed_account=None, notary_profile=None, beta=False,
            build_dir=self.root, appcast=self.appcast,
            repository='TuckerTucker/tkr-macdown', sparkle_bin=sparkle_bin,
            entitlements=entitlements)

    def rebuild_info(self, **info: object) -> None:
        support.write_plist(self.app / 'Contents' / 'Info.plist',
                            support.app_info(**info))  # type: ignore[arg-type]

    def test_empty_key_is_refused_before_anything_is_signed(self) -> None:
        self.rebuild_info(public_ed_key='')
        before = self.appcast.read_text()
        runner = RecordingRunner(self.key)
        with self.assertRaisesRegex(ReleaseError, 'empty SUPublicEDKey'):
            release_app(self.app, self.options, runner, NOW)
        self.assertEqual(runner.commands, [])
        self.assertEqual(self.appcast.read_text(), before)

    def test_stable_release_signs_packages_and_publishes(self) -> None:
        runner = RecordingRunner(self.key)
        result = release_app(self.app, self.options, runner, NOW)

        tools = runner.tools()
        self.assertEqual(tools[-3:], ['codesign', 'ditto', 'sign_update'])
        signs = [c for c in runner.commands
                 if c[0] == 'codesign' and '--sign' in c]
        self.assertEqual(Path(signs[-1][-1]), self.app)
        verify = runner.commands[len(signs)]
        self.assertEqual(verify[:4],
                         ['codesign', '--verify', '--deep', '--strict'])
        self.assertNotIn('notarytool', tools)

        self.assertEqual(result.archive.name, 'MacDown-0.8.1.zip')
        item = ET.parse(self.appcast).getroot().find('channel/item')
        assert item is not None
        self.assertIsNone(item.find('{%s}channel' % SPARKLE_NS))
        enclosure = item.find('enclosure')
        assert enclosure is not None
        self.assertEqual(enclosure.get('length'),
                         str(result.archive.stat().st_size))

    def test_beta_release_is_on_beta_channel(self) -> None:
        release_app(self.app, replace(self.options, beta=True),
                    RecordingRunner(self.key), NOW)
        item = ET.parse(self.appcast).getroot().find('channel/item')
        assert item is not None
        self.assertEqual(item.findtext('{%s}channel' % SPARKLE_NS), 'beta')

    def test_notarization_staples_and_assesses_before_zipping(self) -> None:
        runner = RecordingRunner(self.key)
        release_app(self.app, replace(self.options, notary_profile='p'),
                    runner, NOW)
        tools = runner.tools()
        order = [tools.index(t) for t in
                 ('notarytool', 'stapler', 'spctl', 'sign_update')]
        self.assertEqual(order, sorted(order))
        final_zip = [c for c in runner.commands
                     if c[0] == 'ditto' and c[-1].endswith('0.8.1.zip')]
        self.assertGreater(runner.commands.index(final_zip[0]),
                           tools.index('spctl'))

    def test_rejected_notarization_publishes_nothing(self) -> None:
        before = self.appcast.read_text()
        runner = RecordingRunner(self.key, notary_status='Invalid')
        with self.assertRaisesRegex(ReleaseError, 'Invalid'):
            release_app(self.app, replace(self.options, notary_profile='p'),
                        runner, NOW)
        self.assertNotIn('sign_update', runner.tools())
        self.assertEqual(self.appcast.read_text(), before)

    def test_signing_with_a_key_the_app_does_not_trust_is_refused(
            self) -> None:
        before = self.appcast.read_text()
        with self.assertRaisesRegex(ReleaseError, 'does not verify'):
            release_app(self.app, self.options,
                        RecordingRunner(Ed25519PrivateKey.generate()), NOW)
        self.assertEqual(self.appcast.read_text(), before)

    def test_ed_key_file_and_account_reach_sign_update(self) -> None:
        runner = RecordingRunner(self.key)
        release_app(self.app, replace(self.options,
                                      ed_key_file=Path('/k/ed.key'),
                                      ed_account='macdown'), runner, NOW)
        sign = runner.commands[-1]
        self.assertEqual(sign[sign.index('--ed-key-file') + 1], '/k/ed.key')
        self.assertEqual(sign[sign.index('--account') + 1], 'macdown')


if __name__ == '__main__':
    unittest.main()
