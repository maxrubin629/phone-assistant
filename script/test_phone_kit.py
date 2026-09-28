#!/usr/bin/env python3
"""Exercise installer file operations in a disposable directory, never system HAL."""
from pathlib import Path
import json
import sys
import shutil
import plistlib
import hashlib
import subprocess
from build_phone_kit import build, swift_source

root = Path(__file__).resolve().parent.parent
build(development_test=True)
output = root / 'artifacts/phone-kit-checks'
output.mkdir(parents=True, exist_ok=True)
driver = root / 'dist/drivers/CodexCallSend.driver'
# A reproducible older signed fixture exercises upgrades on clean Macs too.
# Its fingerprint is appended ONLY to this test executable, never the real helper.
fixture = output / 'Previous.driver'
if fixture.exists():
    shutil.rmtree(fixture)
shutil.copytree(driver, fixture)
info_path = fixture / 'Contents/Info.plist'
info = plistlib.loads(info_path.read_bytes())
info['CFBundleVersion'] = '2'
info_path.write_bytes(plistlib.dumps(info))
subprocess.run(['codesign', '--force', '--sign', '-', str(fixture)], check=True)
hashes = {p.relative_to(fixture).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
          for p in sorted(fixture.rglob('*')) if p.is_file()}
header = swift_source(driver)
if not sys.argv[1:]:
    literal = '[' + ','.join(json.dumps(k)+':'+json.dumps(v) for k,v in hashes.items()) + ']'
    header = header.replace('static let legacyPayloads: [[String: String]] = [',
                            'static let legacyPayloads: [[String: String]] = [' + literal + ',')
source = output / 'PhoneKitChecks.swift'
source.write_text(header
                  + (root / 'native/PhoneKit/PhoneKitInstaller.swift').read_text()
                  + '\n' + (root / 'native/PhoneKit/InstallerChecks.swift').read_text())
binary = output / 'PhoneKitChecks'
subprocess.run(['xcrun', 'swiftc', '-D', 'PHONE_KIT_TESTING', '-target', 'arm64-apple-macos14.2',
                '-module-cache-path', str(root / 'artifacts/phone-kit-module-cache'),
                str(source), '-o', str(binary)], check=True)
result = subprocess.run([str(binary), str(driver)] + (sys.argv[1:] or [str(fixture)]), text=True, capture_output=True)
if result.returncode:
    raise SystemExit(result.stdout + result.stderr)
print(result.stdout.strip())
(output / 'results.json').write_text(json.dumps({
    'result': 'passed', 'output': result.stdout.strip(),
    'systemHALModified': False, 'audioServiceRestarted': False,
    'liveActivationQualified': False,
}, indent=2) + '\n')
