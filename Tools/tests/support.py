"""Shared fixtures for the release tooling tests.

Importing this module puts ``Tools/`` on ``sys.path`` so tests run with
``python3 -m unittest discover -s Tools/tests`` from the repository root.
"""

from __future__ import annotations

import base64
import logging
import os
import plistlib
import sys
from pathlib import Path
from typing import Any, Optional

import structlog

TOOLS_DIR = Path(__file__).resolve().parent.parent
REPO_ROOT = TOOLS_DIR.parent
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

# Keep the pipeline's progress events out of the test report; failures are
# asserted on, not logged.
structlog.configure(
    wrapper_class=structlog.make_filtering_bound_logger(logging.CRITICAL))

# A 64-bit little-endian Mach-O header followed by padding.
MACH_O_BYTES = b'\xcf\xfa\xed\xfe' + b'\x00' * 28


def write_macho(path: Path) -> Path:
    """Write a file that starts with a Mach-O magic number."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(MACH_O_BYTES)
    return path


def write_plist(path: Path, data: dict[str, Any]) -> Path:
    """Write ``data`` as a binary-compatible XML plist."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, 'wb') as handle:
        plistlib.dump(data, handle)
    return path


def app_info(public_ed_key: Any = '',
             short_version: str = '0.8.1',
             bundle_version: str = '1300',
             build_version: str = 'v0.8.1') -> dict[str, Any]:
    """An Info.plist dictionary shaped like the built MacDown.app's."""
    info: dict[str, Any] = {
        'CFBundleExecutable': 'MacDown',
        'CFBundleShortVersionString': short_version,
        'CFBundleVersion': bundle_version,
        'CFBundleBuildVersion': build_version,
        'LSMinimumSystemVersion': '11.0',
    }
    if public_ed_key is not None:
        info['SUPublicEDKey'] = public_ed_key
    return info


def build_app_tree(root: Path,
                   info: Optional[dict[str, Any]] = None) -> Path:
    """Create a MacDown.app laid out like a real build with Sparkle 2.9.

    The layout mirrors the shipped ``Sparkle.framework``: a versioned
    framework (``Versions/B`` with a ``Current`` symlink and top-level
    symlinks), the ``Autoupdate`` tool, ``Updater.app``, and the
    ``Downloader``/``Installer`` XPC services, plus non-code resources.

    Args:
        root: Directory to create the app in.
        info: Info.plist contents; defaults to :func:`app_info`.

    Returns:
        Path of the app bundle.
    """
    app = root / 'MacDown.app'
    contents = app / 'Contents'
    write_plist(contents / 'Info.plist', info or app_info())
    write_macho(contents / 'MacOS' / 'MacDown')
    (contents / 'Resources').mkdir(parents=True)
    (contents / 'Resources' / 'Styles.css').write_text('body {}\n')

    framework = contents / 'Frameworks' / 'Sparkle.framework'
    version = framework / 'Versions' / 'B'
    write_macho(version / 'Sparkle')
    write_macho(version / 'Autoupdate')
    write_plist(version / 'Resources' / 'Info.plist',
                {'CFBundleExecutable': 'Sparkle'})
    updater = version / 'Updater.app'
    write_plist(updater / 'Contents' / 'Info.plist',
                {'CFBundleExecutable': 'Updater'})
    write_macho(updater / 'Contents' / 'MacOS' / 'Updater')
    for service in ('Downloader', 'Installer'):
        xpc = version / 'XPCServices' / (service + '.xpc')
        write_plist(xpc / 'Contents' / 'Info.plist',
                    {'CFBundleExecutable': service})
        write_macho(xpc / 'Contents' / 'MacOS' / service)
    os.symlink('B', framework / 'Versions' / 'Current')
    for name in ('Sparkle', 'Autoupdate', 'Updater.app', 'XPCServices',
                 'Resources'):
        os.symlink('Versions/Current/' + name, framework / name)
    return app


def b64(raw: bytes) -> str:
    """Base64-encode bytes to text."""
    return base64.b64encode(raw).decode('ascii')
