"""Appcast item construction and insertion."""

from __future__ import annotations

import datetime as dt
import email.utils
import unittest
from xml.etree import ElementTree as ET

import support
from sparkle_release import (
    SPARKLE_NS,
    AppcastItem,
    BundleInfo,
    ReleaseError,
    insert_item,
    item_element,
    make_item,
    release_asset_url,
)

NS = {'sparkle': SPARKLE_NS}
NOW = dt.datetime(2026, 10, 21, 15, 30, tzinfo=dt.timezone.utc)
SIGNATURE = support.b64(b'\x01' * 64)
INFO = BundleInfo(bundle_version='1300', short_version='0.8.1',
                  build_version='v0.8.1', minimum_system_version='11.0',
                  public_ed_key=support.b64(b'\x02' * 32))


def item(beta: bool = False, info: BundleInfo = INFO) -> AppcastItem:
    return make_item(
        info, url=release_asset_url('TuckerTucker/tkr-macdown',
                                    info.short_version),
        length=4096, ed_signature=SIGNATURE, beta=beta, now=NOW)


def repo_appcast() -> str:
    return (support.REPO_ROOT / 'appcast.xml').read_text(encoding='utf-8')


class ChannelTests(unittest.TestCase):

    def test_beta_item_carries_beta_channel(self) -> None:
        element = item_element(item(beta=True))
        channels = element.findall('sparkle:channel', NS)
        self.assertEqual([c.text for c in channels], ['beta'])

    def test_stable_item_carries_no_channel(self) -> None:
        element = item_element(item(beta=False))
        self.assertEqual(element.findall('sparkle:channel', NS), [])


class InsertTests(unittest.TestCase):

    def test_inserted_item_parses_with_sparkle_namespace(self) -> None:
        text = insert_item(repo_appcast(), item(beta=True))
        root = ET.fromstring(text)
        self.assertEqual(root.tag, 'rss')
        self.assertEqual(root.get('version'), '2.0')
        items = root.findall('channel/item')
        self.assertEqual(len(items), 1)
        node = items[0]
        self.assertEqual(node.findtext('title'), 'MacDown 0.8.1')
        self.assertEqual(node.findtext('sparkle:version', namespaces=NS),
                         '1300')
        self.assertEqual(
            node.findtext('sparkle:shortVersionString', namespaces=NS),
            '0.8.1')
        self.assertEqual(
            node.findtext('sparkle:minimumSystemVersion', namespaces=NS),
            '11.0')
        self.assertEqual(node.findtext('sparkle:channel', namespaces=NS),
                         'beta')
        self.assertEqual(
            email.utils.parsedate_to_datetime(node.findtext('pubDate')), NOW)
        enclosure = node.find('enclosure')
        assert enclosure is not None
        self.assertEqual(
            enclosure.get('url'),
            'https://github.com/TuckerTucker/tkr-macdown/releases/download/'
            'v0.8.1/MacDown-0.8.1.zip')
        self.assertEqual(enclosure.get('length'), '4096')
        self.assertEqual(enclosure.get('type'), 'application/octet-stream')
        self.assertEqual(enclosure.get('{%s}edSignature' % SPARKLE_NS),
                         SIGNATURE)

    def test_serialized_prefix_is_sparkle(self) -> None:
        text = insert_item(repo_appcast(), item())
        self.assertIn('xmlns:sparkle="%s"' % SPARKLE_NS, text)
        self.assertIn('sparkle:edSignature="%s"' % SIGNATURE, text)
        self.assertTrue(text.startswith('<?xml version="1.0"'))

    def test_newest_item_goes_first_and_channel_metadata_stays(self) -> None:
        older = insert_item(repo_appcast(), item())
        newer_info = BundleInfo('1310', '0.8.2', 'v0.8.2', '11.0',
                                INFO.public_ed_key)
        text = insert_item(older, item(info=newer_info))
        channel = ET.fromstring(text).find('channel')
        assert channel is not None
        versions = [i.findtext('sparkle:version', namespaces=NS)
                    for i in channel.findall('item')]
        self.assertEqual(versions, ['1310', '1300'])
        self.assertEqual(channel.findtext('title'), 'MacDown')
        tags = [child.tag for child in channel]
        self.assertLess(tags.index('description'), tags.index('item'))

    def test_duplicate_version_is_refused(self) -> None:
        once = insert_item(repo_appcast(), item())
        with self.assertRaisesRegex(ReleaseError, 'already has an item'):
            insert_item(once, item(beta=True))

    def test_malformed_appcast_is_refused(self) -> None:
        with self.assertRaises(ReleaseError):
            insert_item('<rss><channel>', item())
        with self.assertRaises(ReleaseError):
            insert_item('<feed/>', item())

    def test_naive_pub_date_is_rejected(self) -> None:
        naive = AppcastItem('t', '1', '1', '11.0', dt.datetime(2026, 1, 1),
                            'https://x', 1, SIGNATURE)
        with self.assertRaises(ValueError):
            item_element(naive)


class RepoAppcastTests(unittest.TestCase):

    def test_committed_appcast_is_empty_rss_with_sparkle_namespace(
            self) -> None:
        text = repo_appcast()
        self.assertIn('xmlns:sparkle="%s"' % SPARKLE_NS, text)
        root = ET.fromstring(text)
        self.assertEqual((root.tag, root.get('version')), ('rss', '2.0'))
        channel = root.find('channel')
        assert channel is not None
        self.assertTrue(channel.findtext('title'))
        self.assertEqual(channel.findtext('link'),
                         'https://github.com/TuckerTucker/tkr-macdown')
        self.assertTrue(channel.findtext('description'))
        self.assertEqual(channel.findall('item'), [])


if __name__ == '__main__':
    unittest.main()
