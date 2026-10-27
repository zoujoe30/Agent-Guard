#!/usr/bin/env python3
"""Prepare signed Sparkle release metadata locally. Never publish or export keys."""
import argparse
import base64
import datetime
import email.utils
import hashlib
from pathlib import Path, PurePosixPath
import plistlib
import re
import subprocess
import sys
from urllib.parse import unquote, urlsplit
import xml.etree.ElementTree as ET
import zipfile

SPARKLE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', SPARKLE)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--zip', required=True, type=Path, dest='archive')
    parser.add_argument('--version', required=True)
    parser.add_argument('--build', required=True)
    parser.add_argument('--download-url', required=True)
    parser.add_argument('--sign-update', required=True, type=Path)
    parser.add_argument('--output-dir', type=Path, default=Path('updates'))
    parser.add_argument('--keychain-account', default='ed25519')
    args = parser.parse_args()
    archive = args.archive.resolve(strict=True)
    signer = args.sign_update.resolve(strict=True)
    if not re.fullmatch(r'\d+(?:\.\d+){1,2}', args.version):
        raise ValueError('version must be numeric, for example 0.3.21')
    if not re.fullmatch(r'[1-9]\d*', args.build):
        raise ValueError('build must be a positive integer')
    url = urlsplit(args.download_url)
    if (url.scheme != 'https' or url.hostname != 'github.com' or url.username
            or url.password or url.port or url.query or url.fragment):
        raise ValueError('download URL must be a direct HTTPS github.com release asset URL')
    parts = unquote(url.path).split('/')
    if (len(parts) != 7 or parts[3:5] != ['releases', 'download']
            or not all(parts[1:3]) or not parts[5]
            or parts[6] != archive.name):
        raise ValueError('download URL must identify this ZIP in owner/repo/releases/download/tag/filename')
    if archive.suffix.lower() != '.zip':
        raise ValueError('release archive must be ZIP')
    with zipfile.ZipFile(archive) as package:
        names = package.namelist()
        if len(names) != len(set(names)):
            raise ValueError('ZIP contains duplicate paths')
        for name in names:
            path = PurePosixPath(name)
            if (path.is_absolute() or '..' in path.parts or '\\' in name
                    or not path.parts or path.parts[0] != 'Agent Guard.app'):
                raise ValueError('ZIP must contain only Agent Guard.app with safe relative paths')
        info = plistlib.loads(package.read('Agent Guard.app/Contents/Info.plist'))
        if (info.get('CFBundleIdentifier') != 'com.local.agentguard'
                or info.get('CFBundleShortVersionString') != args.version
                or str(info.get('CFBundleVersion')) != args.build):
            raise ValueError('ZIP bundle identifier/version/build does not match requested release')
        public_key = info.get('SUPublicEDKey', '')
        if len(base64.b64decode(public_key, validate=True)) != 32:
            raise ValueError('ZIP is missing a valid SUPublicEDKey')
        if 'Agent Guard.app/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle' not in names:
            raise ValueError('ZIP is missing embedded Sparkle')
    output = args.output_dir.resolve()
    if output.exists() and any(output.iterdir()):
        raise ValueError('output directory must be empty; preserve the previous signed appcast separately')
    sign_command = [str(signer), '--account', args.keychain_account]
    signature = subprocess.check_output(sign_command + ['-p', str(archive)], text=True).strip()
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError('sign_update did not return a valid Ed25519 signature')
    # Verify against the public key embedded in the app, not merely another
    # Keychain identity. CryptoKit is supplied by macOS; Swift is already needed
    # to build Agent Guard. Only public material is passed to this verifier.
    verifier = '''import Foundation
import CryptoKit
let a = CommandLine.arguments
let key = try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: a[1])!)
let data = try Data(contentsOf: URL(fileURLWithPath: a[3]))
guard key.isValidSignature(Data(base64Encoded: a[2])!, for: data) else { exit(1) }
'''
    import tempfile
    with tempfile.TemporaryDirectory(prefix='agentguard-public-verify-') as temporary:
        source = Path(temporary) / 'verify.swift'
        source.write_text(verifier)
        subprocess.run(['/usr/bin/swift', str(source), public_key, signature, str(archive)], check=True)
    rss = ET.Element('rss', version='2.0')
    channel = ET.SubElement(rss, 'channel')
    ET.SubElement(channel, 'title').text = 'Agent Guard Updates'
    ET.SubElement(channel, 'link').text = f'https://github.com/{parts[1]}/{parts[2]}'
    ET.SubElement(channel, 'description').text = 'Agent Guard signed application updates'
    item = ET.SubElement(channel, 'item')
    ET.SubElement(item, 'title').text = f'Agent Guard {args.version}'
    ET.SubElement(item, 'pubDate').text = email.utils.format_datetime(datetime.datetime.now(datetime.timezone.utc))
    ET.SubElement(item, f'{{{SPARKLE}}}version').text = args.build
    ET.SubElement(item, f'{{{SPARKLE}}}shortVersionString').text = args.version
    ET.SubElement(item, f'{{{SPARKLE}}}minimumSystemVersion').text = info.get('LSMinimumSystemVersion', '14.0')
    ET.SubElement(item, 'enclosure', {
        'url': args.download_url, 'length': str(archive.stat().st_size),
        'type': 'application/octet-stream', f'{{{SPARKLE}}}edSignature': signature,
    })
    output.mkdir(parents=True, exist_ok=True)
    appcast = output / 'appcast.xml'
    ET.indent(rss)
    ET.ElementTree(rss).write(appcast, encoding='utf-8', xml_declaration=True)
    # Also sign the feed, so SURequireSignedFeed can be enabled safely.
    subprocess.run(sign_command + [str(appcast)], check=True)
    subprocess.run(sign_command + ['--verify', str(appcast)], check=True)
    ET.parse(appcast)
    checksums = []
    for asset in (archive, appcast):
        with asset.open('rb') as stream:
            digest = hashlib.sha256()
            for block in iter(lambda: stream.read(1024 * 1024), b''):
                digest.update(block)
        checksums.append(f'{digest.hexdigest()}  {asset.name}')
    (output / 'SHA256SUMS.txt').write_text('\n'.join(checksums) + '\n')
    print(f'Prepared {appcast} and SHA256SUMS.txt; nothing has been published.')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError, zipfile.BadZipFile, subprocess.CalledProcessError) as error:
        print(f'error: {error}', file=sys.stderr)
        sys.exit(1)
