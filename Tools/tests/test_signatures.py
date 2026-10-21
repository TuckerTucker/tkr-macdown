"""EdDSA signature handling and notarization reports."""

from __future__ import annotations

import base64
import json
import unittest

import support
from cryptography.hazmat.primitives.asymmetric.ed25519 import (
    Ed25519PrivateKey,
)
from cryptography.hazmat.primitives.serialization import (
    Encoding,
    PublicFormat,
)
from sparkle_release import (
    ReleaseError,
    parse_ed_signature,
    parse_notary_result,
    verify_ed_signature,
)

DATA = b'PK\x03\x04 a release archive'


def keypair() -> tuple[Ed25519PrivateKey, bytes]:
    private = Ed25519PrivateKey.generate()
    public = private.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
    return private, public


class VerifyTests(unittest.TestCase):

    def test_signature_from_the_matching_key_verifies(self) -> None:
        private, public = keypair()
        signature = support.b64(private.sign(DATA))
        verify_ed_signature(public, signature, DATA)

    def test_signature_from_another_key_is_refused(self) -> None:
        private, _ = keypair()
        _, other_public = keypair()
        with self.assertRaisesRegex(ReleaseError, 'does not verify'):
            verify_ed_signature(other_public,
                                support.b64(private.sign(DATA)), DATA)

    def test_signature_over_other_bytes_is_refused(self) -> None:
        private, public = keypair()
        signature = support.b64(private.sign(DATA))
        with self.assertRaises(ReleaseError):
            verify_ed_signature(public, signature, DATA + b'!')


class SignUpdateOutputTests(unittest.TestCase):

    def test_trailing_newline_is_stripped(self) -> None:
        raw = base64.b64encode(b'\x09' * 64).decode()
        self.assertEqual(parse_ed_signature(raw + '\n'), raw)

    def test_non_signature_output_is_refused(self) -> None:
        with self.assertRaises(ReleaseError):
            parse_ed_signature('sparkle:edSignature="abc" length="12"')
        with self.assertRaises(ReleaseError):
            parse_ed_signature(base64.b64encode(b'\x09' * 32).decode())


class NotaryTests(unittest.TestCase):

    def test_accepted_returns_submission_id(self) -> None:
        self.assertEqual(parse_notary_result(json.dumps(
            {'id': 'abc-123', 'status': 'Accepted'})), 'abc-123')

    def test_invalid_status_is_refused_with_log_hint(self) -> None:
        with self.assertRaisesRegex(ReleaseError,
                                    'notarytool log abc-123'):
            parse_notary_result(json.dumps(
                {'id': 'abc-123', 'status': 'Invalid'}))

    def test_unreadable_output_is_refused(self) -> None:
        with self.assertRaises(ReleaseError):
            parse_notary_result('Conducting pre-submission checks...')


if __name__ == '__main__':
    unittest.main()
