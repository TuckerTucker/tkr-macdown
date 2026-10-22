"""Inside-out Developer ID signing of the app and the code nested in it."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

import support
from release_steps import (
    codesign_command,
    find_nested_code,
    is_mach_o,
    signing_plan,
)

IDENTITY = 'Developer ID Application: Example (TEAM123456)'


class SigningOrderTests(unittest.TestCase):

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.app = support.build_app_tree(Path(self._tmp.name))
        self.tool = (self.app / 'Contents' / 'SharedSupport' / 'bin'
                     / 'macdown')
        self.framework = (self.app / 'Contents' / 'Frameworks'
                          / 'Kit.framework')
        self.version = self.framework / 'Versions' / 'A'
        self.entitlements = Path(self._tmp.name) / 'release.entitlements'

    def plan_paths(self) -> list[Path]:
        return [Path(c[-1]) for c in
                signing_plan(self.app, IDENTITY, self.entitlements)]

    def test_plan_signs_exactly_the_nested_code_then_the_app(self) -> None:
        self.assertEqual(set(self.plan_paths()), {
            self.tool,
            self.version / 'XPCServices' / 'Service.xpc',
            self.version / 'Helper.app',
            self.framework,
            self.app,
        })

    def test_helpers_before_framework_before_app(self) -> None:
        order = self.plan_paths()
        framework_at = order.index(self.framework)
        for helper in (self.version / 'XPCServices' / 'Service.xpc',
                       self.version / 'Helper.app'):
            self.assertLess(order.index(helper), framework_at, helper)
        self.assertLess(order.index(self.tool), order.index(self.app))
        self.assertEqual(order[-1], self.app)

    def test_every_item_follows_everything_it_contains(self) -> None:
        order = self.plan_paths()
        for i, outer in enumerate(order):
            for inner in order[i + 1:]:
                self.assertFalse(
                    inner.is_relative_to(outer),
                    '%s is signed after its container %s' % (inner, outer))

    def test_symlinks_and_main_executables_are_not_signed(self) -> None:
        paths = self.plan_paths()
        self.assertNotIn(self.framework / 'Kit', paths)
        self.assertNotIn(self.framework / 'Helper.app', paths)
        self.assertNotIn(self.version / 'Kit', paths)
        self.assertNotIn(
            self.version / 'Helper.app' / 'Contents' / 'MacOS' / 'Helper',
            paths)
        self.assertNotIn(self.app / 'Contents' / 'MacOS' / 'MacDown', paths)
        self.assertNotIn(
            self.app / 'Contents' / 'Resources' / 'Styles.css', paths)

    def test_loose_dylib_is_found_by_its_mach_o_header(self) -> None:
        dylib = support.write_macho(
            self.app / 'Contents' / 'Frameworks' / 'libextra.dylib')
        self.assertIn(dylib, find_nested_code(self.app))
        self.assertTrue(is_mach_o(dylib))
        self.assertFalse(
            is_mach_o(self.app / 'Contents' / 'Resources' / 'Styles.css'))


class CodesignCommandTests(unittest.TestCase):

    def test_nested_item_keeps_its_entitlements(self) -> None:
        command = codesign_command(IDENTITY, Path('/x/Service.xpc'))
        self.assertEqual(command, [
            'codesign', '--force', '--sign', IDENTITY, '--options', 'runtime',
            '--timestamp', '--preserve-metadata=entitlements',
            '/x/Service.xpc'])

    def test_app_gets_release_entitlements(self) -> None:
        command = codesign_command(IDENTITY, Path('/x/MacDown.app'),
                                   Path('/t/release.entitlements'))
        self.assertIn('--options', command)
        self.assertEqual(command[command.index('--options') + 1], 'runtime')
        self.assertIn('--timestamp', command)
        self.assertEqual(
            command[command.index('--entitlements') + 1],
            '/t/release.entitlements')
        self.assertNotIn('--preserve-metadata=entitlements', command)
        self.assertEqual(command[-1], '/x/MacDown.app')


if __name__ == '__main__':
    unittest.main()
