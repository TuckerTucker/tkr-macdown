"""Pure building blocks for a Sparkle 2 release of MacDown.

Everything here takes its inputs as parameters and performs no process
execution, so each piece is unit-testable on its own. The orchestration that
drives Xcode, ``codesign``, ``notarytool`` and Sparkle's ``sign_update`` lives
in ``build_for_release.py`` and calls into this module.
"""

from __future__ import annotations

import base64
import binascii
import datetime as _dt
import email.utils
import json
import plistlib
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Mapping, Optional, Sequence
from xml.etree import ElementTree as ET

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

SPARKLE_NS = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
BETA_CHANNEL = 'beta'
ARCHIVE_MIME_TYPE = 'application/octet-stream'
ED25519_PUBLIC_KEY_BYTES = 32
ED25519_SIGNATURE_BYTES = 64

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
# is not on a release tag. Such a build has no GitHub release to download.
_DEV_VERSION = re.compile(r'd\d+$')

ET.register_namespace('sparkle', SPARKLE_NS)


class ReleaseError(Exception):
    """A release precondition failed; the message says what and how to fix."""


def sparkle(tag: str) -> str:
    """Return ``tag`` qualified with the Sparkle XML namespace.

    Args:
        tag: Local element or attribute name, e.g. ``"version"``.

    Returns:
        The ElementTree ``{namespace}name`` form.
    """
    return '{%s}%s' % (SPARKLE_NS, tag)


# ---------------------------------------------------------------------------
# Built bundle facts
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class BundleInfo:
    """The facts a release reads from the built app's ``Info.plist``.

    Attributes:
        bundle_version: ``CFBundleVersion``; Sparkle's ``sparkle:version``.
        short_version: ``CFBundleShortVersionString``.
        build_version: ``CFBundleBuildVersion`` (``git describe`` output, with
            a trailing ``+`` when the tree was dirty), or ``""`` if absent.
        minimum_system_version: ``LSMinimumSystemVersion``.
        public_ed_key: ``SUPublicEDKey`` as built, possibly empty.
    """

    bundle_version: str
    short_version: str
    build_version: str
    minimum_system_version: str
    public_ed_key: Any


def read_bundle_info(plist: Mapping[str, Any]) -> BundleInfo:
    """Extract release facts from a parsed ``Info.plist``.

    Args:
        plist: The ``Info.plist`` dictionary (e.g. from ``plistlib.load``).

    Returns:
        The bundle facts.

    Raises:
        ReleaseError: A key Sparkle needs is missing or empty.
    """
    def required(key: str) -> str:
        value = plist.get(key)
        if not isinstance(value, str) or not value.strip():
            raise ReleaseError(
                'The built Info.plist has no %s; cannot describe the update.'
                % key)
        return value.strip()

    return BundleInfo(
        bundle_version=required('CFBundleVersion'),
        short_version=required('CFBundleShortVersionString'),
        build_version=str(plist.get('CFBundleBuildVersion', '')).strip(),
        minimum_system_version=required('LSMinimumSystemVersion'),
        public_ed_key=plist.get('SUPublicEDKey'),
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


def require_public_ed_key(info: BundleInfo) -> bytes:
    """Refuse a build that can never verify an update.

    Sparkle 2 accepts an update only when its EdDSA signature verifies against
    ``SUPublicEDKey``. A build where that key is empty or malformed would ship
    a working app whose updater is permanently dead, so it must not be
    released.

    Args:
        info: Facts of the built app.

    Returns:
        The 32 raw bytes of the Ed25519 public key.

    Raises:
        ReleaseError: The key is missing, empty, not base64, or not 32 bytes.
    """
    key = info.public_ed_key
    how = ('Pass --public-ed-key (or set SPARKLE_PUBLIC_ED_KEY) to the value '
           'printed by `Pods/Sparkle/bin/generate_keys -p`.')
    if not isinstance(key, str) or not key.strip():
        raise ReleaseError(
            'The built app has an empty SUPublicEDKey, so it could never '
            'verify an update. ' + how)
    try:
        raw = base64.b64decode(key.strip(), validate=True)
    except (binascii.Error, ValueError) as exc:
        raise ReleaseError(
            'The built app\'s SUPublicEDKey is not valid base64 (%s). %s'
            % (exc, how)) from exc
    if len(raw) != ED25519_PUBLIC_KEY_BYTES:
        raise ReleaseError(
            'The built app\'s SUPublicEDKey decodes to %d bytes; an Ed25519 '
            'public key is %d. %s' % (len(raw), ED25519_PUBLIC_KEY_BYTES, how))
    return raw


def require_release_version(info: BundleInfo) -> None:
    """Refuse a build made from an untagged or dirty tree.

    The download URL is derived from the short version (``v<short>``), so a
    development version would point the appcast at a release that does not
    exist, and a dirty build is not reproducible from any commit.

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

    Walks the bundle without following symlinks (a framework's top-level
    ``Autoupdate -> Versions/Current/Autoupdate`` links would otherwise be
    signed twice). A code item is a code bundle (``.app``, ``.appex``,
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
    (Sparkle's ``Downloader.xpc`` ships with its own); the app is given the
    release entitlements file.

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
        ``codesign`` argument vectors: nested helpers, then the frameworks
        that contain them, then the app last.
    """
    plan = [codesign_command(identity, item)
            for item in find_nested_code(app, is_code_file)]
    plan.append(codesign_command(identity, app, entitlements))
    return plan


# ---------------------------------------------------------------------------
# Notarization and EdDSA signatures
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


def parse_ed_signature(output: str) -> str:
    """Validate the signature printed by ``sign_update -p``.

    Args:
        output: Standard output of ``sign_update -p <archive>``.

    Returns:
        The base64 EdDSA signature.

    Raises:
        ReleaseError: The output is not a single base64 64-byte signature.
    """
    signature = output.strip()
    try:
        raw = base64.b64decode(signature, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise ReleaseError(
            'sign_update printed %r, not a base64 signature.'
            % signature) from exc
    if len(raw) != ED25519_SIGNATURE_BYTES:
        raise ReleaseError(
            'sign_update printed a %d-byte signature; Ed25519 signatures are '
            '%d bytes.' % (len(raw), ED25519_SIGNATURE_BYTES))
    return signature


def verify_ed_signature(
        public_key: bytes, signature: str, data: bytes) -> None:
    """Verify an archive signature against the key the app will check with.

    This is the check the shipped app performs before installing an update,
    run before publishing so a key mismatch is caught here rather than by
    every user's updater.

    Args:
        public_key: Raw 32-byte Ed25519 key from the built ``SUPublicEDKey``.
        signature: Base64 signature from ``sign_update``.
        data: The archive bytes that were signed.

    Raises:
        ReleaseError: The signature does not verify against the app's key.
    """
    try:
        Ed25519PublicKey.from_public_bytes(public_key).verify(
            base64.b64decode(signature), data)
    except InvalidSignature as exc:
        raise ReleaseError(
            'The archive signature does not verify against the built app\'s '
            'SUPublicEDKey: the private key used by sign_update is not the '
            'pair of that public key. Sign with the matching key '
            '(--ed-key-file) or rebuild with the matching --public-ed-key.'
        ) from exc


# ---------------------------------------------------------------------------
# Appcast
# ---------------------------------------------------------------------------


def archive_name(short_version: str) -> str:
    """Name of the release archive for a version.

    Args:
        short_version: ``CFBundleShortVersionString``.

    Returns:
        e.g. ``"MacDown-0.8.0.zip"``.
    """
    return 'MacDown-%s.zip' % short_version


def release_asset_url(repository: str, short_version: str) -> str:
    """Download URL of the archive attached to the GitHub release.

    Args:
        repository: ``owner/name`` on GitHub.
        short_version: ``CFBundleShortVersionString``; the release tag is
            ``v<short_version>``.

    Returns:
        The asset URL.
    """
    return 'https://github.com/%s/releases/download/v%s/%s' % (
        repository, short_version, archive_name(short_version))


@dataclass(frozen=True)
class AppcastItem:
    """One update entry in the appcast.

    Attributes:
        title: Human-readable title shown by Sparkle.
        version: ``sparkle:version`` (``CFBundleVersion``).
        short_version: ``sparkle:shortVersionString``.
        minimum_system_version: ``sparkle:minimumSystemVersion``.
        pub_date: Publication time; must be timezone-aware.
        url: Enclosure download URL.
        length: Archive size in bytes.
        ed_signature: Base64 EdDSA signature of the archive.
        channel: ``"beta"`` for pre-releases, None for stable.
    """

    title: str
    version: str
    short_version: str
    minimum_system_version: str
    pub_date: _dt.datetime
    url: str
    length: int
    ed_signature: str
    channel: Optional[str] = None


def make_item(
        info: BundleInfo,
        *,
        url: str,
        length: int,
        ed_signature: str,
        beta: bool,
        now: _dt.datetime) -> AppcastItem:
    """Describe a built release as an appcast item.

    Args:
        info: Facts of the built app.
        url: Archive download URL.
        length: Archive size in bytes.
        ed_signature: Base64 EdDSA signature of the archive.
        beta: True for a pre-release on the beta channel.
        now: Publication time (timezone-aware).

    Returns:
        The item.
    """
    return AppcastItem(
        title='MacDown %s' % info.short_version,
        version=info.bundle_version,
        short_version=info.short_version,
        minimum_system_version=info.minimum_system_version,
        pub_date=now,
        url=url,
        length=length,
        ed_signature=ed_signature,
        channel=BETA_CHANNEL if beta else None,
    )


def item_element(item: AppcastItem) -> ET.Element:
    """Render an appcast item as an RSS ``<item>`` element.

    Args:
        item: The item.

    Returns:
        The element.

    Raises:
        ValueError: ``pub_date`` is naive or ``length`` is not positive.
    """
    if item.pub_date.tzinfo is None:
        raise ValueError('pub_date must be timezone-aware')
    if item.length <= 0:
        raise ValueError('length must be positive, got %d' % item.length)
    element = ET.Element('item')
    ET.SubElement(element, 'title').text = item.title
    ET.SubElement(element, 'pubDate').text = email.utils.format_datetime(
        item.pub_date)
    ET.SubElement(element, sparkle('version')).text = item.version
    ET.SubElement(
        element, sparkle('shortVersionString')).text = item.short_version
    ET.SubElement(element, sparkle('minimumSystemVersion')).text = (
        item.minimum_system_version)
    if item.channel is not None:
        ET.SubElement(element, sparkle('channel')).text = item.channel
    ET.SubElement(element, 'enclosure', {
        'url': item.url,
        'length': str(item.length),
        'type': ARCHIVE_MIME_TYPE,
        sparkle('edSignature'): item.ed_signature,
    })
    return element


def parse_appcast(text: str) -> ET.Element:
    """Parse an appcast, keeping comments.

    Args:
        text: The appcast XML.

    Returns:
        The ``<rss>`` root element.

    Raises:
        ReleaseError: The document is not an RSS feed with a channel.
    """
    parser = ET.XMLParser(target=ET.TreeBuilder(insert_comments=True))
    try:
        root = ET.fromstring(text, parser=parser)
    except ET.ParseError as exc:
        raise ReleaseError('The appcast is not valid XML: %s' % exc) from exc
    if root.tag != 'rss' or root.find('channel') is None:
        raise ReleaseError('The appcast has no <rss><channel> element.')
    return root


def require_new_version(appcast: str, version: str) -> ET.Element:
    """Refuse a version the appcast already publishes.

    Args:
        appcast: The current appcast XML.
        version: The ``sparkle:version`` about to be added.

    Returns:
        The parsed ``<rss>`` root.

    Raises:
        ReleaseError: The appcast is malformed, or already lists ``version``
            (Sparkle would see two updates with one identity; republishing a
            version must be a deliberate hand edit).
    """
    root = parse_appcast(appcast)
    for old in root.iterfind('channel/item'):
        if old.findtext(sparkle('version')) == version:
            raise ReleaseError(
                'The appcast already has an item for sparkle:version %s.'
                % version)
    return root


def insert_item(appcast: str, item: AppcastItem) -> str:
    """Add an item to an appcast, newest first.

    Args:
        appcast: The current appcast XML.
        item: The release to add.

    Returns:
        The updated appcast XML.

    Raises:
        ReleaseError: The appcast is malformed or already lists this
            ``sparkle:version`` (see :func:`require_new_version`).
    """
    root = require_new_version(appcast, item.version)
    channel = root.find('channel')
    assert channel is not None  # parse_appcast guarantees it.
    existing = channel.findall('item')
    position = (list(channel).index(existing[0]) if existing
                else len(channel))
    channel.insert(position, item_element(item))
    ET.indent(root, space='  ')
    body = ET.tostring(root, encoding='unicode')
    return '<?xml version="1.0" encoding="utf-8"?>\n' + body + '\n'
