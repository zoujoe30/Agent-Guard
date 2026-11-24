#!/usr/bin/env python3
"""Promote a verified GitHub draft and prepare a protected-branch feed proposal."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET


REPO = 'zoujoe30/Agent-Guard'
API = f'repos/{REPO}'
NS = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
ROOT = Path(__file__).resolve().parents[1]
FEED_URL = f'https://raw.githubusercontent.com/{REPO}/main/updates/appcast.xml'


def gh(*args):
    return subprocess.check_output(['gh', *args], cwd=ROOT)


def api(path):
    return json.loads(gh('api', path))


def list_releases():
    pages = json.loads(gh('api', '--paginate', '--slurp', f'{API}/releases?per_page=100'))
    return [release for page in pages for release in page]


def tag_targets(tag):
    origin = f'https://github.com/{REPO}.git'
    ref = f'refs/tags/{tag}'
    refs = subprocess.check_output(['git', 'ls-remote', origin, ref, ref + '^{}'], text=True)
    values = {name: sha for sha, name in (line.split() for line in refs.splitlines())}
    return values.get(ref + '^{}', values.get(ref))


def digest(path):
    hasher = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            hasher.update(chunk)
    return hasher.hexdigest()


def validate_assets(directory, filenames, manifest_hash):
    if set(path.name for path in directory.iterdir()) != {*filenames, 'SHA256SUMS.txt'}:
        raise ValueError('release must have exactly the four expected assets')
    manifest = directory / 'SHA256SUMS.txt'
    if digest(manifest) != manifest_hash:
        raise ValueError('manifest SHA-256 differs from the owner-approved digest')
    entries = [re.fullmatch(r'([0-9a-f]{64})  ([A-Za-z0-9.-]+)', line)
               for line in manifest.read_text().splitlines()]
    if len(entries) != len(filenames) or any(match is None for match in entries):
        raise ValueError('invalid checksum manifest')
    hashes = {match[2]: match[1] for match in entries}
    if set(hashes) != set(filenames):
        raise ValueError('manifest lists unexpected or duplicate assets')
    for filename, expected in hashes.items():
        if digest(directory / filename) != expected:
            raise ValueError(f'SHA-256 mismatch for {filename}')


def draft_identity(release):
    fields = ('id', 'tag_name', 'target_commitish', 'draft', 'prerelease', 'name', 'body')
    assets = ('id', 'name', 'size', 'state', 'digest', 'updated_at')
    return ([release.get(field) for field in fields],
            sorted(tuple(asset.get(field) for field in assets) for asset in release['assets']))


def download_draft(release, directory, names):
    assets = release['assets']
    if len(assets) != len(names) or {a['name'] for a in assets} != set(names):
        raise ValueError('draft must contain exactly the four expected assets')
    for asset in assets:
        if asset['state'] != 'uploaded' or not 0 < asset['size'] <= 100_000_000:
            raise ValueError(f'invalid draft asset: {asset["name"]}')
        if type(asset['id']) is not int:
            raise ValueError('invalid GitHub asset identifier')
        path = directory / asset['name']
        with path.open('wb') as out:
            subprocess.run(['gh', 'api', '-H', 'Accept: application/octet-stream',
                            f'{API}/releases/assets/{asset["id"]}'],
                           cwd=ROOT, stdout=out, check=True)
        if path.stat().st_size != asset['size']:
            raise ValueError(f'draft asset length mismatch: {asset["name"]}')


def fetch_public(url, destination):
    subprocess.run(['curl', '--disable', '--fail', '--silent', '--show-error',
                    '--location', '--proto', '=https', '--proto-redir', '=https',
                    '--retry', '3', '--retry-all-errors', '--max-time', '30',
                    '--max-filesize', '100000000', '--output', str(destination), url], check=True)


def download_public(base_url, directory, names):
    for name in names:
        fetch_public(f'{base_url}/{name}', directory / name)

def verify_feed(directory, zip_name, base_url, public_key, version, build):
    archive = directory / zip_name
    appcast = directory / 'appcast.xml'
    subprocess.run([sys.executable, str(ROOT / 'Tools/verify-sparkle-update.py'),
                    '--appcast', str(appcast), '--zip', str(archive),
                    '--public-key', public_key, '--download-url', f'{base_url}/{zip_name}'],
                   check=True)
    items = ET.parse(appcast).findall('./channel/item')
    expected = {'version': build, 'shortVersionString': version,
                'minimumSystemVersion': '14.0', 'hardwareRequirements': 'arm64'}
    if len(items) != 1 or any(items[0].findtext(NS + name) != value
                              for name, value in expected.items()):
        raise ValueError('expected one signed Apple Silicon macOS 14+ item for the target version/build')


def current_feed_build(feed):
    builds = [int(item.findtext(NS + 'version'))
              for item in ET.fromstring(feed).findall('./channel/item')]
    if not builds:
        raise ValueError('current update source has no build')
    return max(builds)


def promote(args):
    expected_sha = args.target
    if not re.fullmatch(r'[0-9a-f]{40}', expected_sha):
        raise ValueError('target must be a full Git commit SHA')
    if not re.fullmatch(r'[0-9a-f]{64}', args.manifest_sha256):
        raise ValueError('manifest SHA-256 must be 64 lowercase hex characters')
    subprocess.run(['git', 'merge-base', '--is-ancestor', expected_sha, 'HEAD'],
                   cwd=ROOT, check=True)
    info = plistlib.loads(subprocess.check_output(
        ['git', 'show', f'{expected_sha}:AppInfo.plist'], cwd=ROOT))
    trusted = plistlib.loads(subprocess.check_output(
        ['git', 'show', 'HEAD:AppInfo.plist'], cwd=ROOT))
    public_key = trusted['SUPublicEDKey']
    if info['SUPublicEDKey'] != public_key:
        raise ValueError('release target changes the existing Sparkle trust key')
    version = info['CFBundleShortVersionString']
    build = str(info['CFBundleVersion'])
    if not re.fullmatch(r'[0-9]+(?:\.[0-9]+){2}', version) or not re.fullmatch(r'[1-9][0-9]*', build):
        raise ValueError('invalid target version or build')
    tag = f'local-{version}-build{build}'
    if tag != args.tag:
        raise ValueError('tag does not match target version/build')
    base = f'https://github.com/{REPO}/releases/download/{tag}'
    zip_name = f'Agent.Guard-{version}.zip'
    files = [f'Agent.Guard-{version}.pkg', zip_name, 'appcast.xml']
    names = [*files, 'SHA256SUMS.txt']
    matching = [r for r in list_releases() if r['tag_name'] == tag]
    if len(matching) != 1:
        raise ValueError('expected exactly one matching owner-staged draft or published release')
    release = matching[0]
    if release['prerelease'] is not True:
        raise ValueError('matched release is not a pre-release')
    tagged = tag_targets(tag)
    if tagged and tagged != expected_sha:
        raise ValueError('existing tag points to a different commit')
    if release['draft'] and not tagged and release['target_commitish'] != expected_sha:
        raise ValueError('draft must name the exact target SHA')
    if not release['draft'] and tagged != expected_sha:
        raise ValueError('public release tag does not resolve to the approved commit')
    current_feed = subprocess.check_output(['git', 'show', 'HEAD:updates/appcast.xml'], cwd=ROOT)
    baseline = current_feed_build(current_feed)
    if int(build) < baseline or (release['draft'] and int(build) <= baseline):
        raise ValueError('release would roll back or duplicate the current feed build')

    with tempfile.TemporaryDirectory(prefix='agentguard-release-') as temporary:
        work = Path(temporary)
        if release['draft']:
            draft = work / 'draft'
            draft.mkdir()
            download_draft(release, draft, names)
            validate_assets(draft, files, args.manifest_sha256)
            verify_feed(draft, zip_name, base, public_key, version, build)
            # Check the draft again immediately before the only mutation.
            current = api(f'{API}/releases/{release["id"]}')
            if draft_identity(current) != draft_identity(release) or tag_targets(tag) != tagged:
                raise ValueError('draft or tag changed during verification; retry after reconciliation')
            gh('api', '--method', 'PATCH', f'{API}/releases/{release["id"]}',
               '-F', 'draft=false', '-F', 'prerelease=true', '-f', 'make_latest=false')

        public = api(f'{API}/releases/tags/{tag}')
        if (public['id'] != release['id'] or public['draft'] or not public['prerelease']
                or tag_targets(tag) != expected_sha):
            raise ValueError('public release identity, pre-release status or tag target mismatch')
        actual_names = [asset['name'] for asset in public['assets']]
        if sorted(actual_names) != sorted(names):
            raise ValueError('public release asset names differ from the approved set')
        verified = work / 'public'
        verified.mkdir()
        download_public(base, verified, names)
        validate_assets(verified, files, args.manifest_sha256)
        verify_feed(verified, zip_name, base, public_key, version, build)
        if int(build) == baseline and (verified / 'appcast.xml').read_bytes() != current_feed:
            raise ValueError('the current feed already has this build with different bytes')

        args.output.mkdir()
        (args.output / 'appcast.xml').write_bytes((verified / 'appcast.xml').read_bytes())
        (args.output / 'receipt.json').write_text(json.dumps({
            'release': f'https://github.com/{REPO}/releases/tag/{tag}',
            'target': expected_sha,
            'already_current': int(build) == baseline,
            'assets': {name: {'url': f'{base}/{name}', 'sha256': digest(verified / name),
                              'bytes': (verified / name).stat().st_size} for name in names},
        }, indent=2) + '\n')


def check_update_source(args):
    trusted = plistlib.loads(subprocess.check_output(
        ['git', 'show', f'{args.trusted_ref}:AppInfo.plist'], cwd=ROOT))
    if trusted['SUFeedURL'] != FEED_URL:
        raise ValueError('source checkout uses a different Sparkle update URL')
    feed = args.check_feed.read_bytes()
    items = ET.fromstring(feed).findall('./channel/item')
    if len(items) != 1:
        raise ValueError('expected a single item in the proposed feed')
    version = items[0].findtext(NS + 'shortVersionString', '')
    build = items[0].findtext(NS + 'version', '')
    if not re.fullmatch(r'[0-9]+(?:\.[0-9]+){2}', version) or not re.fullmatch(r'[1-9][0-9]*', build):
        raise ValueError('invalid version/build in proposed feed')
    tag = f'local-{version}-build{build}'
    release = api(f'{API}/releases/tags/{tag}')
    if release['draft'] or not release['prerelease'] or release['tag_name'] != tag:
        raise ValueError('appcast target must be a published public pre-release')
    prior = subprocess.check_output(
        ['git', 'show', f'{args.trusted_ref}:updates/appcast.xml'], cwd=ROOT)
    if int(build) <= current_feed_build(prior) and feed != prior:
        raise ValueError('new appcast must increase the existing trusted build')
    base = f'https://github.com/{REPO}/releases/download/{tag}'
    zip_name = f'Agent.Guard-{version}.zip'
    files = [f'Agent.Guard-{version}.pkg', zip_name, 'appcast.xml']
    names = [*files, 'SHA256SUMS.txt']
    if sorted(a['name'] for a in release['assets']) != sorted(names):
        raise ValueError('public release does not contain the four expected assets')
    with tempfile.TemporaryDirectory(prefix='agentguard-source-') as temporary:
        directory = Path(temporary)
        download_public(base, directory, names)
        if (directory / 'appcast.xml').read_bytes() != feed:
            raise ValueError('repository appcast differs from the signed public release asset')
        manifest_digest = digest(directory / 'SHA256SUMS.txt')
        validate_assets(directory, files, manifest_digest)
        verify_feed(directory, zip_name, base, trusted['SUPublicEDKey'], version, build)
        if args.check_live:
            for attempt in range(6):
                fetch_public(FEED_URL, directory / 'live.xml')
                if (directory / 'live.xml').read_bytes() == feed:
                    break
                if attempt < 5:
                    time.sleep(10)
            else:
                raise ValueError('live Sparkle update source does not match the merged appcast')
    print(f'Verified Sparkle update source for {tag}: {FEED_URL}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tag')
    parser.add_argument('--target')
    parser.add_argument('--manifest-sha256')
    parser.add_argument('--output', type=Path)
    parser.add_argument('--check-feed', type=Path, help='verify the appcast against the public release')
    parser.add_argument('--trusted-ref', default='HEAD', help='trusted Git ref for key and baseline feed')
    parser.add_argument('--check-live', action='store_true', help='also verify the configured live feed bytes')
    args = parser.parse_args()
    try:
        if args.check_feed:
            check_update_source(args)
        else:
            if not all((args.tag, args.target, args.manifest_sha256, args.output)):
                raise ValueError('promotion requires --tag, --target, --manifest-sha256, and --output')
            if args.output.exists():
                raise ValueError('output path must not already exist')
            promote(args)
    except (OSError, ValueError, KeyError, TypeError, ET.ParseError, subprocess.CalledProcessError) as error:
        print(f'error: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
