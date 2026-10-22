#!/usr/bin/env python3
"""Build a Developer ID signed, optionally notarized MacDown to share.

Runs headless: every input is a flag or an environment variable, and nothing
waits for a keypress. The pipeline is

    clean -> build peg-markdown-highlight -> xcodebuild archive -> export .app
    -> refuse unless the build is a tagged, clean release
    -> Developer ID sign inside-out (hardened runtime, secure timestamp)
    -> codesign --verify --deep --strict
    -> [notarize + staple + spctl --assess]   (with --notary-profile)
    -> ditto zip

This fork does not distribute updates, so nothing is published: the zip is
the output. See CONTRIBUTING.md ("Making a signed build").
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Mapping, Optional, Protocol, Sequence

import structlog

from release_steps import (
    BundleInfo,
    ReleaseError,
    archive_name,
    load_bundle_info,
    parse_notary_result,
    require_release_version,
    signing_plan,
)

ROOT_DIR = Path(__file__).resolve().parent.parent
TOOLS_DIR = ROOT_DIR / 'Tools'

WORKSPACE = 'MacDown.xcworkspace'
SCHEME = 'MacDown'
CONFIGURATION = 'Release'
APP_NAME = 'MacDown.app'

EXIT_FAILED = 1
EXIT_REFUSED = 2

log = structlog.get_logger('build_for_release')


# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class ReleaseOptions:
    """Everything a release run needs, resolved from flags and environment.

    Attributes:
        identity: Developer ID Application signing identity.
        notary_profile: ``notarytool`` keychain profile, or None to skip
            notarization.
        build_dir: Scratch directory for derived data, archive and outputs.
        entitlements: Entitlements plist applied to the app.
    """

    identity: str
    notary_profile: Optional[str]
    build_dir: Path
    entitlements: Path


def build_parser(environ: Mapping[str, str]) -> argparse.ArgumentParser:
    """Build the argument parser, with defaults drawn from ``environ``.

    Args:
        environ: Environment variables supplying flag defaults.

    Returns:
        The parser.
    """
    parser = argparse.ArgumentParser(
        prog='build_for_release.py',
        description=__doc__.split('\n\n')[0],
        epilog='Environment variables in brackets supply the default for '
               'the matching flag. Exit status: 0 built, 1 an external tool '
               'failed, 2 a release precondition refused the build.')
    parser.add_argument(
        '--identity', default=environ.get('MACDOWN_SIGNING_IDENTITY'),
        help='Developer ID Application identity, e.g. "Developer ID '
             'Application: Name (TEAMID)" [MACDOWN_SIGNING_IDENTITY]')
    parser.add_argument(
        '--notary-profile', default=environ.get('MACDOWN_NOTARY_PROFILE'),
        help='notarytool keychain profile; when given, the app is notarized, '
             'stapled and assessed by Gatekeeper [MACDOWN_NOTARY_PROFILE]')
    parser.add_argument(
        '--build-dir', type=Path, default=ROOT_DIR / 'Build',
        help='scratch directory, wiped first (default: %(default)s)')
    parser.add_argument(
        '--entitlements', type=Path,
        default=TOOLS_DIR / 'MacDown-release.entitlements',
        help='entitlements for the app signature (default: %(default)s)')
    return parser


def parse_args(
        argv: Sequence[str], environ: Mapping[str, str]) -> ReleaseOptions:
    """Resolve release options from command-line flags and environment.

    Args:
        argv: Arguments, excluding the program name.
        environ: Environment variables supplying defaults.

    Returns:
        The options.

    Raises:
        SystemExit: The arguments are invalid (argparse prints why).
    """
    parser = build_parser(environ)
    args = parser.parse_args(list(argv))
    if not args.identity or not args.identity.strip():
        parser.error('a signing identity is required: pass --identity '
                     '"Developer ID Application: ..." or set '
                     'MACDOWN_SIGNING_IDENTITY')
    if not args.identity.startswith('Developer ID Application:'):
        parser.error('--identity must be a "Developer ID Application: ..." '
                     'identity; Gatekeeper and notarization need Developer '
                     'ID, got %r' % args.identity)
    return ReleaseOptions(
        identity=args.identity,
        notary_profile=args.notary_profile or None,
        build_dir=args.build_dir.resolve(),
        entitlements=args.entitlements.resolve(),
    )


# ---------------------------------------------------------------------------
# Command execution
# ---------------------------------------------------------------------------


class CommandFailed(ReleaseError):
    """An external tool exited non-zero or could not be started."""


class CommandRunner(Protocol):
    """Runs one external command and returns its standard output."""

    def __call__(self, args: Sequence[str], *,
                 cwd: Optional[Path] = None) -> str:
        """Run ``args``; raise CommandFailed if it exits non-zero."""
        ...


class SubprocessRunner:
    """CommandRunner backed by ``subprocess.run(check=True)``."""

    def __call__(self, args: Sequence[str], *,
                 cwd: Optional[Path] = None) -> str:
        """Run a command, capturing output.

        Args:
            args: Argument vector.
            cwd: Working directory, or None for the current one.

        Returns:
            Standard output.

        Raises:
            CommandFailed: The command failed; carries the tail of its
                output.
        """
        log.info('command_start', args=list(args), cwd=str(cwd or ''))
        try:
            result = subprocess.run(
                list(args), cwd=cwd, check=True, capture_output=True,
                text=True)
        except FileNotFoundError as exc:
            raise CommandFailed(
                '%s is not installed or not on PATH.' % args[0]) from exc
        except subprocess.CalledProcessError as exc:
            tail = '\n'.join(
                (exc.stderr or exc.stdout or '').strip().splitlines()[-25:])
            log.error('command_failed', args=list(args),
                      returncode=exc.returncode, output_tail=tail)
            raise CommandFailed('%s exited %d:\n%s' % (
                ' '.join(args), exc.returncode, tail)) from exc
        log.info('command_end', args=[args[0]])
        return result.stdout


# ---------------------------------------------------------------------------
# Pipeline
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class ReleaseResult:
    """What a successful run produced.

    Attributes:
        archive: The zip of the signed app, ready to share.
        info: Facts of the build.
        notarized: Whether the app was notarized and stapled.
    """

    archive: Path
    info: BundleInfo
    notarized: bool


def build_app(options: ReleaseOptions, run: CommandRunner) -> Path:
    """Clean, build dependencies, archive, and export the app.

    The derived data lives inside ``build_dir``, so wiping that directory is a
    complete clean of everything this build reads back.

    Args:
        options: Release options.
        run: Command runner.

    Returns:
        Path of the exported (still unsigned) ``MacDown.app``.
    """
    log.info('clean', build_dir=str(options.build_dir))
    shutil.rmtree(options.build_dir, ignore_errors=True)
    options.build_dir.mkdir(parents=True)

    log.info('build_dependency', name='peg-markdown-highlight')
    run(['make', '-C',
         str(ROOT_DIR / 'Dependency' / 'peg-markdown-highlight')])

    archive = options.build_dir / 'MacDown.xcarchive'
    command = [
        'xcodebuild', 'archive',
        '-workspace', str(ROOT_DIR / WORKSPACE),
        '-scheme', SCHEME,
        '-configuration', CONFIGURATION,
        '-derivedDataPath', str(options.build_dir / 'DerivedData'),
        '-archivePath', str(archive),
        # Everything is re-signed below with Developer ID, inside-out.
        'CODE_SIGNING_ALLOWED=NO',
    ]
    log.info('archive', archive=str(archive))
    run(command, cwd=ROOT_DIR)

    source = archive / 'Products' / 'Applications' / APP_NAME
    app = options.build_dir / APP_NAME
    log.info('export', source=str(source), app=str(app))
    run(['ditto', str(source), str(app)])
    return app


def release_app(
        app: Path,
        options: ReleaseOptions,
        run: CommandRunner) -> ReleaseResult:
    """Sign, verify, optionally notarize, and package a built app.

    Preconditions are checked before anything is signed, so a refused build
    leaves no signed artifact behind.

    Args:
        app: The exported ``MacDown.app``.
        options: Release options.
        run: Command runner.

    Returns:
        The release outputs.

    Raises:
        ReleaseError: A precondition or tool failed.
    """
    info = load_bundle_info(app)
    log.info('bundle_info', version=info.bundle_version,
             short_version=info.short_version)
    require_release_version(info)
    if not options.entitlements.is_file():
        raise ReleaseError('Entitlements file %s does not exist.'
                           % options.entitlements)

    for command in signing_plan(app, options.identity, options.entitlements):
        log.info('sign', path=command[-1])
        run(command)
    run(['codesign', '--verify', '--deep', '--strict', '--verbose=2',
         str(app)])

    notarized = False
    if options.notary_profile:
        notarized = notarize(app, options, run)
    else:
        log.warning('notarization_skipped',
                    reason='no --notary-profile; Gatekeeper will block a '
                           'first download of this build')

    archive = options.build_dir / archive_name(info.short_version)
    run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(app),
         str(archive)])
    log.info('archive_written', archive=str(archive))
    return ReleaseResult(archive=archive, info=info, notarized=notarized)


def notarize(app: Path, options: ReleaseOptions, run: CommandRunner) -> bool:
    """Notarize and staple the app, then confirm Gatekeeper accepts it.

    Args:
        app: The signed app.
        options: Release options carrying the notary profile.
        run: Command runner.

    Returns:
        True once the app is stapled and assessed.

    Raises:
        ReleaseError: Notarization was rejected or a tool failed.
    """
    submission = options.build_dir / 'notarize.zip'
    run(['ditto', '-c', '-k', '--keepParent', str(app), str(submission)])
    log.info('notarize_submit', profile=options.notary_profile)
    output = run(['xcrun', 'notarytool', 'submit', str(submission),
                  '--keychain-profile', str(options.notary_profile),
                  '--wait', '--output-format', 'json'])
    submission_id = parse_notary_result(output)
    log.info('notarize_accepted', submission=submission_id)
    submission.unlink()
    run(['xcrun', 'stapler', 'staple', str(app)])
    run(['xcrun', 'stapler', 'validate', str(app)])
    run(['spctl', '--assess', '--type', 'execute', '--verbose=4', str(app)])
    return True


def configure_logging() -> None:
    """Emit structured JSON log lines on standard error."""
    structlog.configure(
        processors=[
            structlog.processors.add_log_level,
            structlog.processors.TimeStamper(fmt='iso', utc=True),
            structlog.processors.JSONRenderer(),
        ],
        logger_factory=structlog.PrintLoggerFactory(sys.stderr),
    )


def main(argv: Sequence[str], environ: Mapping[str, str],
         run: Optional[CommandRunner] = None) -> int:
    """Run a release.

    Args:
        argv: Arguments, excluding the program name.
        environ: Environment variables.
        run: Command runner; defaults to a subprocess runner.

    Returns:
        Process exit status.
    """
    options = parse_args(argv, environ)
    runner: CommandRunner = run or SubprocessRunner()
    log.info('release_start', notarize=bool(options.notary_profile),
             build_dir=str(options.build_dir))
    try:
        app = build_app(options, runner)
        result = release_app(app, options, runner)
    except CommandFailed as exc:
        log.error('release_failed', reason=str(exc))
        print('build_for_release.py: error: %s' % exc, file=sys.stderr)
        return EXIT_FAILED
    except ReleaseError as exc:
        log.error('release_refused', reason=str(exc))
        print('build_for_release.py: error: %s' % exc, file=sys.stderr)
        return EXIT_REFUSED
    log.info('release_ready', archive=str(result.archive),
             version=result.info.short_version, notarized=result.notarized)
    return 0


if __name__ == '__main__':
    configure_logging()
    sys.exit(main(sys.argv[1:], os.environ))
