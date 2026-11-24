import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[2] / 'Tools/promote-sparkle-release.py'
LOADER = importlib.util.spec_from_file_location('promotion', SCRIPT)
release_tool = importlib.util.module_from_spec(LOADER)
LOADER.loader.exec_module(release_tool)

TAG = 'local-0.3.26-build38'
TARGET = 'a' * 40
FILES = {
    'Agent.Guard-0.3.26.pkg': b'package',
    'Agent.Guard-0.3.26.zip': b'archive',
    'appcast.xml': b'new signed feed',
}
INFO = plistlib.dumps({'CFBundleShortVersionString': '0.3.26', 'CFBundleVersion': '38',
                       'SUPublicEDKey': 'trusted key'})
CURRENT = b'<rss xmlns:s="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><s:version>37</s:version></item></channel></rss>'


class PromotionTest(unittest.TestCase):
    def setUp(self):
        self.addCleanup((temp := tempfile.TemporaryDirectory()).cleanup)
        self.root = Path(temp.name)
        self.output = self.root / 'proposal'
        self.assets = dict(FILES)
        self.assets['SHA256SUMS.txt'] = ''.join(
            f'{hashlib.sha256(data).hexdigest()}  {name}\n'
            for name, data in FILES.items()).encode()
        self.manifest_digest = hashlib.sha256(self.assets['SHA256SUMS.txt']).hexdigest()
        self.draft = {'id': 42, 'draft': True, 'prerelease': True, 'tag_name': TAG,
                      'target_commitish': TARGET, 'assets': [
                          {'id': i, 'name': name, 'size': len(data), 'state': 'uploaded'}
                          for i, (name, data) in enumerate(self.assets.items(), 1)]}
        self.public = dict(self.draft, draft=False)
        self.mutations = 0
        self.tagged = None
        self.public_assets = self.assets.copy()
        self.draft_assets = self.assets.copy()
        self.current = CURRENT
        self.interrupt_publish = False

    def git(self, command, **unused):
        self.assertEqual(command[0], 'git')
        return self.current if command[-1].endswith('appcast.xml') else INFO

    def api(self, path):
        if path.endswith('/42'):
            # An asset fetch can increment download_count, which is not an edit.
            return dict(self.draft, assets=[dict(a, download_count=1) for a in self.draft['assets']])
        self.assertTrue(path.endswith('/tags/' + TAG))
        return self.public

    def patch_release(self, *args):
        self.assertEqual(args[1:3], ('--method', 'PATCH'))
        self.assertIn('make_latest=false', args)
        self.mutations += 1
        self.tagged = TARGET
        if self.interrupt_publish:
            raise subprocess.CalledProcessError(1, 'gh')
        return b'{}'

    def write_downloads(self, directory, assets):
        self.assertFalse(self.output.exists(), 'proposal appeared before public verification')
        for name, data in assets.items():
            (directory / name).write_bytes(data)

    def run_command(self):
        args = ['--tag', TAG, '--target', TARGET, '--manifest-sha256', self.manifest_digest,
                '--output', str(self.output)]
        with contextlib.ExitStack() as stack:
            intercepts = {
                'api': self.api,
                'gh': self.patch_release,
                'list_releases': lambda: [self.public if self.tagged == TARGET else self.draft],
                'tag_targets': lambda tag: self.tagged,
                'download_draft': lambda release, path, names: self.write_downloads(path, self.draft_assets),
                'download_public': lambda url, path, names: self.write_downloads(path, self.public_assets),
                'verify_feed': lambda *args: None,
            }
            for name, substitute in intercepts.items():
                stack.enter_context(patch.object(release_tool, name, side_effect=substitute))
            stack.enter_context(patch.object(release_tool.subprocess, 'check_output', side_effect=self.git))
            stack.enter_context(patch.object(release_tool.subprocess, 'run'))
            stack.enter_context(patch.object(release_tool.sys, 'argv', [str(SCRIPT), *args]))
            error = stack.enter_context(contextlib.redirect_stderr(io.StringIO()))
            status = release_tool.main()
        return status, error.getvalue()

    def test_valid_draft_produces_receipt_and_same_signed_bytes(self):
        self.assertEqual(self.run_command()[0], 0)
        self.assertEqual(self.mutations, 1)
        self.assertEqual((self.output / 'appcast.xml').read_bytes(), FILES['appcast.xml'])
        self.assertEqual(json.loads((self.output / 'receipt.json').read_text())['target'], TARGET)

    def test_bad_draft_hash_never_publishes(self):
        self.draft_assets['Agent.Guard-0.3.26.zip'] = b'tampered'
        status, error = self.run_command()
        self.assertEqual(status, 1)
        self.assertIn('SHA-256 mismatch', error)
        self.assertEqual(self.mutations, 0)
        self.assertFalse(self.output.exists())

    def test_public_hash_mismatch_leaves_feed_unstaged(self):
        self.public_assets['Agent.Guard-0.3.26.zip'] = b'tampered'
        self.assertEqual(self.run_command()[0], 1)
        self.assertEqual(self.mutations, 1)
        self.assertFalse(self.output.exists())
        self.public_assets = self.assets.copy()
        self.assertEqual(self.run_command()[0], 0)
        self.assertEqual(self.mutations, 1, 'retry must reuse the public release')

    def test_uncertain_publish_is_reconciled_on_retry(self):
        self.interrupt_publish = True
        self.assertEqual(self.run_command()[0], 1)
        self.assertFalse(self.output.exists())
        self.assertEqual(self.run_command()[0], 0)
        self.assertEqual(self.mutations, 1)

    def test_newer_feed_blocks_publishing_older_build(self):
        self.current = CURRENT.replace(b'37', b'39')
        self.assertEqual(self.run_command()[0], 1)
        self.assertEqual(self.mutations, 0)
        self.assertFalse(self.output.exists())

    def test_existing_tag_for_wrong_commit_blocks_all_changes(self):
        self.tagged = 'b' * 40
        self.assertEqual(self.run_command()[0], 1)
        self.assertEqual(self.mutations, 0)
        self.assertFalse(self.output.exists())

    def check_source(self, feed, live_bytes):
        source_file = self.root / 'source.xml'
        source_file.write_bytes(feed)
        info = plistlib.loads(INFO)
        info['SUFeedURL'] = release_tool.FEED_URL
        args = ['--check-feed', str(source_file), '--trusted-ref', TARGET, '--check-live']
        with contextlib.ExitStack() as stack:
            stack.enter_context(patch.object(release_tool, 'api', return_value=self.public))
            stack.enter_context(patch.object(release_tool, 'download_public',
                side_effect=lambda url, path, names: self.write_downloads(path, self.public_assets)))
            stack.enter_context(patch.object(release_tool, 'fetch_public',
                side_effect=lambda url, path: path.write_bytes(live_bytes)))
            stack.enter_context(patch.object(release_tool, 'verify_feed'))
            stack.enter_context(patch.object(release_tool.time, 'sleep'))
            stack.enter_context(patch.object(release_tool.subprocess, 'check_output',
                side_effect=lambda command, **kw: self.current if command[-1].endswith('appcast.xml')
                else plistlib.dumps(info)))
            stack.enter_context(patch.object(release_tool.sys, 'argv', [str(SCRIPT), *args]))
            stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
            errors = stack.enter_context(contextlib.redirect_stderr(io.StringIO()))
            status = release_tool.main()
        return status, errors.getvalue()

    def test_source_check_requires_identical_live_bytes(self):
        feed = CURRENT.replace(b'<s:version>37</s:version>',
            b'<s:version>38</s:version><s:shortVersionString>0.3.26</s:shortVersionString>')
        self.public_assets['appcast.xml'] = feed
        self.public_assets['SHA256SUMS.txt'] = ''.join(
            f'{hashlib.sha256(data).hexdigest()}  {name}\n'
            for name, data in self.public_assets.items() if name != 'SHA256SUMS.txt').encode()
        self.assertEqual(self.check_source(feed, feed)[0], 0)
        status, error = self.check_source(feed, CURRENT)
        self.assertEqual(status, 1)
        self.assertIn('live Sparkle update source does not match', error)


if __name__ == '__main__':
    unittest.main()
