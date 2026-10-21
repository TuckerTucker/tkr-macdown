"""Release preconditions read from the built Info.plist."""

from __future__ import annotations

import unittest

import support
from sparkle_release import (
    ReleaseError,
    read_bundle_info,
    require_public_ed_key,
    require_release_version,
)

KEY = b'\x07' * 32


class PublicKeyTests(unittest.TestCase):

    def refuses(self, value: object) -> None:
        info = read_bundle_info(support.app_info(public_ed_key=value))
        with self.assertRaisesRegex(ReleaseError, 'SUPublicEDKey'):
            require_public_ed_key(info)

    def test_empty_key_is_refused(self) -> None:
        # What $(SPARKLE_PUBLIC_ED_KEY) expands to when the setting is unset.
        self.refuses('')

    def test_blank_missing_and_non_string_keys_are_refused(self) -> None:
        self.refuses(' \n\t')
        self.refuses(None)
        self.refuses(42)

    def test_malformed_and_wrong_length_keys_are_refused(self) -> None:
        self.refuses('not base64!')
        self.refuses(support.b64(b'\x07' * 31))

    def test_valid_key_is_returned_raw(self) -> None:
        info = read_bundle_info(support.app_info(
            public_ed_key=support.b64(KEY)))
        self.assertEqual(require_public_ed_key(info), KEY)


class VersionTests(unittest.TestCase):

    def test_tagged_clean_build_passes(self) -> None:
        require_release_version(read_bundle_info(support.app_info()))
        require_release_version(read_bundle_info(
            support.app_info(short_version='0.9.0b1')))

    def test_development_version_is_refused(self) -> None:
        info = read_bundle_info(support.app_info(short_version='0.8.0d71'))
        with self.assertRaisesRegex(ReleaseError, 'development version'):
            require_release_version(info)

    def test_dirty_build_is_refused(self) -> None:
        info = read_bundle_info(support.app_info(build_version='v0.8.1+'))
        with self.assertRaisesRegex(ReleaseError, 'dirty'):
            require_release_version(info)


class BundleInfoTests(unittest.TestCase):

    def test_missing_minimum_system_version_is_refused(self) -> None:
        plist = support.app_info()
        del plist['LSMinimumSystemVersion']
        with self.assertRaisesRegex(ReleaseError, 'LSMinimumSystemVersion'):
            read_bundle_info(plist)


if __name__ == '__main__':
    unittest.main()
