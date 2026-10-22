"""Pure building blocks for a signed, notarized build of MacDown.

Everything here takes its inputs as parameters and performs no process
execution, so each piece is unit-testable on its own. The orchestration that
drives Xcode, ``codesign`` and ``notarytool`` lives in ``build_for_release.py``
and calls into this module.
"""

from __future__ import annotations

import json
import plistlib
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Mapping, Optional, Sequence

# Bundle wrappers that carry their own code signature. Sealed resource
# bundles without an executable (.bundle, .lproj) are covered by the seal of
# the bundle that contains them and are not signed separately.
CODE_BUNDLE_SUFFIXES = ('.app', '.appex', '.framework', '.xpc')

# Mach-O and fat (universal) headers, in both byte orders.
MACH_O_MAGICS = frozenset({
    b'\xfe\xed\xfa\xce', b'\xce\xfa\xed\xfe',  # 32-bit
    b'\xfe\xed\xfa\xcf', b'\xcf\xfa\xed\xfe',  # 64-bit
    b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca',  # fat
    b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca',  # fat, 64-bit offsets
})

# "0.8.0d71": update_build_number.sh appends d<commits-since-tag> when HEAD
# is not on a release tag, so no tag names the build.
_DEV_VERSION = re.compile(r'd\d+$')


class ReleaseError(Exception):
    """A release precondition failed; the message says what and how to fix."""


# ---------------------------------------------------------------------------
# Built bundle facts
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class BundleInfo:
    """The facts a release reads from the built app's ``Info.plist``.

    Attributes:
        bundle_version: ``CFBundleVersion``.
        short_version: ``CFBundleShortVersionString``.
        build_version: ``CFBundleBuildVersion`` (``git describe`` output, with
            a trailing ``+`` when the tree was dirty), or ``""`` if absent.
    """

    bundle_version: str
    short_version: str
    build_version: str


def read_bundle_info(plist: Mapping[str, Any]) -> BundleInfo:
    """Extract release facts from a parsed ``Info.plist``.

    Args:
        plist: The ``Info.plist`` dictionary (e.g. from ``plistlib.load``).

    Returns:
        The bundle facts.

    Raises:
        ReleaseError: A version key is missing or empty.
    """
    def required(key: str) -> str:
        value = plist.get(key)
        if not isinstance(value, str) or not value.strip():
            raise ReleaseError(
                'The built Info.plist has no %s; cannot name the build.' % key)
        return value.strip()

    return BundleInfo(
        bundle_version=required('CFBundleVersion'),
        short_version=required('CFBundleShortVersionString'),
        build_version=str(plist.get('CFBundleBuildVersion', '')).strip(),
    )


def load_bundle_info(app: Path) -> BundleInfo:
    """Read ``Contents/Info.plist`` from a built app bundle.

    Args:
        app: Path to ``MacDown.app``.

    Returns:
        The bundle facts.
    """
    with open(app / 'Contents' / 'Info.plist', 'rb') as handle:
        return read_bundle_info(plistlib.load(handle))


def require_release_version(info: BundleInfo) -> None:
    """Refuse a build made from an untagged or dirty tree.

    A build that is shared must be reproducible from the commit its version
    names: a development version names no tag, and a dirty build matches no
    commit at all.

    Args:
        info: Facts of the built app.

    Raises:
        ReleaseError: The version is a development or dirty build.
    """
    if _DEV_VERSION.search(info.short_version):
        raise ReleaseError(
            'The built short version %r is a development version: HEAD is '
            'not on a release tag. Tag the release commit (git tag v<version>)'
            ' and rebuild.' % info.short_version)
    if info.build_version.endswith('+'):
        raise ReleaseError(
            'The build was made from a dirty tree (CFBundleBuildVersion %r). '
            'Commit or discard local changes and rebuild.'
            % info.build_version)


# ---------------------------------------------------------------------------
# Signing order of nested code
# ---------------------------------------------------------------------------


def is_mach_o(path: Path) -> bool:
    """Report whether ``path`` is a Mach-O or universal binary.

    Args:
        path: A regular file.

    Returns:
        True when the file starts with a Mach-O or fat magic number.
    """
    try:
        with open(path, 'rb') as handle:
            return handle.read(4) in MACH_O_MAGICS
    except OSError:
        return False


def _bundle_main_executable(bundle: Path) -> Optional[Path]:
    """Return the path of a code bundle's own main executable, if known."""
    if bundle.suffix == '.framework':
        current = bundle / 'Versions' / 'Current'
        if current.is_symlink():
            return (bundle / 'Versions' / Path(current.readlink()).name
                    / bundle.stem)
        return bundle / bundle.stem
    info_plist = bundle / 'Contents' / 'Info.plist'
    name = bundle.stem
    if info_plist.is_file():
        with open(info_plist, 'rb') as handle:
            try:
                name = plistlib.load(handle).get('CFBundleExecutable', name)
            except plistlib.InvalidFileException:
                pass
    return bundle / 'Contents' / 'MacOS' / name


def find_nested_code(
        app: Path,
        is_code_file: Callable[[Path], bool] = is_mach_o) -> list[Path]:
    """List every separately signed code item inside ``app``, inside-out.

    Walks the bundle without following symlinks (a versioned framework's
    top-level links into ``Versions/Current`` would otherwise be signed
    twice). A code item is a code bundle (``.app``, ``.appex``,
    ``.framework``, ``.xpc``) or a standalone Mach-O file that is not the main
    executable of its enclosing bundle (those are signed with the bundle).

    The result is ordered so every item precedes anything that contains it:
    deeper paths first, ties broken by path for determinism. ``app`` itself is
    not included.

    Args:
        app: The application bundle.
        is_code_file: Predicate deciding whether a regular file is signable
            code. Injected so the walk can be driven by any population.

    Returns:
        Paths of nested code, in signing order.
    """
    main_executables: set[Path] = set()
    bundles: list[Path] = []
    files: list[Path] = []

    def walk(directory: Path) -> None:
        for entry in sorted(directory.iterdir()):
            if entry.is_symlink():
                continue
            if entry.is_dir():
                if entry.suffix in CODE_BUNDLE_SUFFIXES:
                    bundles.append(entry)
                    main = _bundle_main_executable(entry)
                    if main is not None:
                        main_executables.add(main)
                walk(entry)
            elif entry.is_file():
                files.append(entry)

    walk(app)
    main_executables.add(_bundle_main_executable(app) or app)
    loose = [f for f in files
             if f not in main_executables and is_code_file(f)]
    return order_inside_out(bundles + loose)


def order_inside_out(paths: Sequence[Path]) -> list[Path]:
    """Order paths so each one comes before any path that contains it.

    Args:
        paths: Paths to order.

    Returns:
        The paths, deepest first, then lexicographically.
    """
    return sorted(paths, key=lambda p: (-len(p.parts), str(p)))


def codesign_command(
        identity: str,
        path: Path,
        entitlements: Optional[Path] = None) -> list[str]:
    """Build the Developer ID ``codesign`` invocation for one item.

    Every item gets the hardened runtime and a secure timestamp, both of which
    notarization requires. Nested items keep their existing entitlements
    (a nested helper may ship with its own); the app is given the release
    entitlements file.

    Args:
        identity: Signing identity, e.g. ``"Developer ID Application: ..."``.
        path: The item to sign.
        entitlements: Entitlements plist for this item, or None to preserve
            whatever entitlements the item already carries.

    Returns:
        The argument vector.
    """
    command = ['codesign', '--force', '--sign', identity,
               '--options', 'runtime', '--timestamp']
    if entitlements is None:
        command.append('--preserve-metadata=entitlements')
    else:
        command += ['--entitlements', str(entitlements)]
    command.append(str(path))
    return command


def signing_plan(
        app: Path,
        identity: str,
        entitlements: Path,
        is_code_file: Callable[[Path], bool] = is_mach_o) -> list[list[str]]:
    """Build the full inside-out signing sequence for ``app``.

    Args:
        app: The application bundle.
        identity: Developer ID Application signing identity.
        entitlements: Entitlements plist applied to the app itself.
        is_code_file: Predicate for standalone code files (see
            :func:`find_nested_code`).

    Returns:
        ``codesign`` argument vectors: nested code innermost first, then the
        app last.
    """
    plan = [codesign_command(identity, item)
            for item in find_nested_code(app, is_code_file)]
    plan.append(codesign_command(identity, app, entitlements))
    return plan


# ---------------------------------------------------------------------------
# Notarization and packaging
# ---------------------------------------------------------------------------


def parse_notary_result(output: str) -> str:
    """Check ``notarytool submit --wait --output-format json`` output.

    ``notarytool`` can exit 0 for a submission Apple rejected, so the status
    in its report is what decides.

    Args:
        output: The JSON printed by ``notarytool``.

    Returns:
        The submission id.

    Raises:
        ReleaseError: The output is unreadable or the status is not Accepted.
    """
    try:
        report = json.loads(output)
    except json.JSONDecodeError as exc:
        raise ReleaseError(
            'Could not read notarytool output: %s' % exc) from exc
    submission = str(report.get('id', ''))
    status = report.get('status')
    if status != 'Accepted':
        raise ReleaseError(
            'Notarization finished with status %r. See why with: '
            'xcrun notarytool log %s --keychain-profile <profile>'
            % (status, submission or '<submission-id>'))
    return submission


def archive_name(short_version: str) -> str:
    """Name of the zip a build is shared as.

    Args:
        short_version: ``CFBundleShortVersionString``.

    Returns:
        e.g. ``"MacDown-0.8.0.zip"``.
    """
    return 'MacDown-%s.zip' % short_version
