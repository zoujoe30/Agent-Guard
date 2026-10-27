#!/usr/bin/env python3
"""Offline fixtures use a disposable test key only; no Keychain or network."""
import base64
from pathlib import Path
import plistlib
import subprocess
import tempfile
import zipfile
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[2]
verifier = root / 'Tools/verify-sparkle-update.py'
ns = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
with tempfile.TemporaryDirectory(prefix='agentguard-feed-tests-') as temporary:
    folder = Path(temporary)
    swift = folder / 'fixture.swift'
    swift.write_text('''import Foundation
import CryptoKit
// Deliberately fixed disposable fixture key. Never a release key.
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
if CommandLine.arguments.count == 1 { print(key.publicKey.rawRepresentation.base64EncodedString()) }
else { print(try key.signature(for: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))).base64EncodedString()) }
''')
    signer = folder / 'fixture'
    subprocess.run(['/usr/bin/swiftc', str(swift), '-o', str(signer)], check=True)
    public = subprocess.check_output([str(signer)], text=True).strip()
    archive = folder / 'Agent Guard-1.0.0.zip'
    info = {'CFBundleIdentifier': 'com.local.agentguard', 'CFBundleVersion': '99',
            'CFBundleShortVersionString': '1.0.0', 'SUPublicEDKey': public}
    with zipfile.ZipFile(archive, 'w') as package:
        package.writestr('Agent Guard.app/Contents/Info.plist', plistlib.dumps(info))
    signature = subprocess.check_output([str(signer), str(archive)], text=True).strip()
    rss = ET.Element('rss', version='2.0')
    item = ET.SubElement(ET.SubElement(rss, 'channel'), 'item')
    ET.SubElement(item, ns + 'version').text = '99'
    ET.SubElement(item, ns + 'shortVersionString').text = '1.0.0'
    enclosure = ET.SubElement(item, 'enclosure', {
        'url': 'https://github.com/test/repo/releases/download/test/Agent%20Guard-1.0.0.zip',
        'length': str(archive.stat().st_size), ns + 'edSignature': signature})
    feed = folder / 'appcast.xml'
    def signed_feed():
        content = ET.tostring(rss, encoding='utf-8', xml_declaration=True) + b'\n'
        feed.write_bytes(content)
        sig = subprocess.check_output([str(signer), str(feed)], text=True).strip()
        feed.write_bytes(content + f'<!-- sparkle-signatures:\nedSignature: {sig}\nlength: {len(content)}\n-->\n'.encode())
    def check(label, success, key=public):
        result = subprocess.run(['python3', str(verifier), '--zip', str(archive),
                                 '--appcast', str(feed), '--public-key', key], capture_output=True, text=True)
        assert (result.returncode == 0) == success, (label, result.stdout, result.stderr)
        print(label + ': passed')
    signed_feed()
    original = feed.read_bytes()
    check('valid signed feed and ZIP', True)
    feed.write_bytes(original.replace(b'1.0.0', b'1.0.1', 1))
    check('tampered feed', False)
    feed.write_bytes(original + b'<item/>')
    check('unsigned trailing XML', False)
    feed.write_bytes(ET.tostring(rss))
    check('unsigned feed', False)
    feed.write_bytes(original)
    check('wrong trusted key', False, base64.b64encode(bytes(32)).decode())
    enclosure.set('length', str(archive.stat().st_size + 1))
    signed_feed()
    check('signed incorrect ZIP length', False)
    enclosure.set('length', str(archive.stat().st_size))
    enclosure.set('url', 'http://github.com/test/repo/releases/download/test/Agent%20Guard-1.0.0.zip')
    signed_feed()
    check('signed insecure download URL', False)
    enclosure.set('url', 'https://github.com/test/repo/releases/download/test/Agent%20Guard-1.0.0.zip')
    enclosure.set(ns + 'edSignature', base64.b64encode(bytes(64)).decode())
    signed_feed()
    check('signed feed with forged ZIP signature', False)
print('Sparkle release regression: 8 assertions passed')
