"""Shared fixtures for the release tooling tests.

Importing this module puts ``Tools/`` on ``sys.path`` so tests run with
``python3 -m unittest discover -s Tools/tests`` from the repository root.
"""

from __future__ import annotations

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


def app_info(short_version: str = '0.8.1',
             bundle_version: str = '1300',
             build_version: str = 'v0.8.1') -> dict[str, Any]:
    """An Info.plist dictionary shaped like the built MacDown.app's."""
    return {
        'CFBundleExecutable': 'MacDown',
        'CFBundleShortVersionString': short_version,
        'CFBundleVersion': bundle_version,
        'CFBundleBuildVersion': build_version,
        'LSMinimumSystemVersion': '12.0',
    }


def build_app_tree(root: Path,
                   info: Optional[dict[str, Any]] = None) -> Path:
    """Create a MacDown.app laid out like a real build.

    A real build nests one standalone tool, ``SharedSupport/bin/macdown``.
    The tree also holds a versioned framework with a helper app and an XPC
    service inside it, laid out the way Xcode embeds one (``Versions/A`` with
    a ``Current`` symlink and top-level symlinks), so the inside-out order
    and the symlink handling are exercised on the shapes signing must get
    right. Non-code resources sit alongside.

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
    write_macho(contents / 'SharedSupport' / 'bin' / 'macdown')
    (contents / 'Resources').mkdir(parents=True)
    (contents / 'Resources' / 'Styles.css').write_text('body {}\n')

    framework = contents / 'Frameworks' / 'Kit.framework'
    version = framework / 'Versions' / 'A'
    write_macho(version / 'Kit')
    write_plist(version / 'Resources' / 'Info.plist',
                {'CFBundleExecutable': 'Kit'})
    helper = version / 'Helper.app'
    write_plist(helper / 'Contents' / 'Info.plist',
                {'CFBundleExecutable': 'Helper'})
    write_macho(helper / 'Contents' / 'MacOS' / 'Helper')
    xpc = version / 'XPCServices' / 'Service.xpc'
    write_plist(xpc / 'Contents' / 'Info.plist',
                {'CFBundleExecutable': 'Service'})
    write_macho(xpc / 'Contents' / 'MacOS' / 'Service')
    os.symlink('A', framework / 'Versions' / 'Current')
    for name in ('Kit', 'Helper.app', 'XPCServices', 'Resources'):
        os.symlink('Versions/Current/' + name, framework / name)
    return app
