"""Release preconditions read from the built Info.plist."""

from __future__ import annotations

import unittest

import support
from release_steps import (
    ReleaseError,
    read_bundle_info,
    require_release_version,
)


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

    def test_missing_version_is_refused(self) -> None:
        plist = support.app_info()
        del plist['CFBundleShortVersionString']
        with self.assertRaisesRegex(ReleaseError,
                                    'CFBundleShortVersionString'):
            read_bundle_info(plist)


if __name__ == '__main__':
    unittest.main()
