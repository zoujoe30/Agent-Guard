#!/usr/bin/env python3
"""Verify signed appcast and release ZIP using a trusted public key, without Keychain."""
import argparse
import base64
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
from urllib.parse import unquote, urlsplit
import xml.etree.ElementTree as ET
import zipfile

NS = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
PREFIX = b'<!-- sparkle-signatures:\n'


def verify(args):
    public = base64.b64decode(args.public_key, validate=True)
    if len(public) != 32:
        raise ValueError('trusted public key must decode to 32 bytes')
    feed = args.appcast.read_bytes()
    offset = feed.rfind(PREFIX)
    if offset < 0:
        raise ValueError('appcast is unsigned')
    content = feed[:offset]
    end = feed.find(b'-->', offset)
    if end < 0 or feed[end + 3:].strip():
        raise ValueError('invalid signature block or unsigned trailing content')
    fields = {}
    for line in feed[offset + len(PREFIX):end].decode('utf-8').splitlines():
        if ':' not in line:
            continue
        key, value = line.split(':', 1)
        if key in fields:
            raise ValueError('duplicate feed signature field')
        fields[key] = value.strip()
    if int(fields.get('length', '-1')) != len(content):
        raise ValueError('signed appcast length mismatch')
    feed_signature = fields.get('edSignature', '')
    if len(base64.b64decode(feed_signature, validate=True)) != 64:
        raise ValueError('invalid feed signature')
    # Parse only signed bytes. Unauthenticated trailing XML cannot influence selection.
    root = ET.fromstring(content)
    if root.tag != 'rss':
        raise ValueError('appcast must be RSS')
    with zipfile.ZipFile(args.zip) as package:
        names = package.namelist()
        if len(names) != len(set(names)):
            raise ValueError('duplicate ZIP entries')
        info = plistlib.loads(package.read('Agent Guard.app/Contents/Info.plist'))
    if info.get('CFBundleIdentifier') != 'com.local.agentguard':
        raise ValueError('wrong bundle identifier')
    if info.get('SUPublicEDKey') != args.public_key:
        raise ValueError('ZIP public key differs from trusted public key')
    build = str(info.get('CFBundleVersion', ''))
    version = info.get('CFBundleShortVersionString', '')
    matches = [item for item in root.findall('./channel/item')
               if item.findtext(NS + 'version') == build
               and item.findtext(NS + 'shortVersionString') == version]
    if len(matches) != 1:
        raise ValueError('feed must contain exactly one matching ZIP version/build')
    enclosures = matches[0].findall('enclosure')
    if len(enclosures) != 1:
        raise ValueError('matching feed item must contain exactly one enclosure')
    enclosure = enclosures[0]
    url = urlsplit(enclosure.get('url', ''))
    parts = unquote(url.path).split('/')
    if (url.scheme != 'https' or url.hostname != 'github.com' or url.username
            or url.password or url.port or url.query or url.fragment
            or len(parts) != 7 or parts[3:5] != ['releases', 'download']
            or not all(parts[1:3]) or not parts[5] or parts[6] != args.zip.name):
        raise ValueError('enclosure URL must identify this ZIP as an HTTPS GitHub release asset')
    if args.download_url and args.download_url != enclosure.get('url'):
        raise ValueError('enclosure URL differs from expected download URL')
    if int(enclosure.get('length', '-1')) != args.zip.stat().st_size:
        raise ValueError('ZIP enclosure length mismatch')
    archive_signature = enclosure.get(NS + 'edSignature', '')
    if len(base64.b64decode(archive_signature, validate=True)) != 64:
        raise ValueError('invalid ZIP signature')
    with tempfile.TemporaryDirectory(prefix='agentguard-public-verify-') as folder:
        folder = Path(folder)
        signed = folder / 'feed-content.xml'
        signed.write_bytes(content)
        source = folder / 'verify.swift'
        source.write_text('''import Foundation
import CryptoKit
let args = CommandLine.arguments
let key = try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: args[1])!)
for index in stride(from: 2, to: args.count, by: 2) {
 let data = try Data(contentsOf: URL(fileURLWithPath: args[index + 1]))
 guard key.isValidSignature(Data(base64Encoded: args[index])!, for: data) else {
  fputs("Invalid Ed25519 signature: \\(args[index + 1])\\n", stderr)
  exit(1)
 }
}
''')
        subprocess.run(['/usr/bin/swift', str(source), args.public_key,
                        feed_signature, str(signed), archive_signature, str(args.zip.resolve())], check=True)
    print(f'Verified signed appcast and ZIP: Agent Guard {version} (build {build})')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--appcast', type=Path, required=True)
    parser.add_argument('--zip', type=Path, required=True)
    parser.add_argument('--public-key', required=True, help='trusted SUPublicEDKey from existing release/source')
    parser.add_argument('--download-url', help='optional exact expected GitHub release asset URL')
    args = parser.parse_args()
    verify(args)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError, zipfile.BadZipFile, ET.ParseError, subprocess.CalledProcessError) as error:
        print(f'error: {error}', file=sys.stderr)
        sys.exit(1)
