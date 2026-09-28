#!/usr/bin/env python3
"""Build the arm64 nested Phone Assistant Audio Bridge installer. Never installs or activates audio."""
from pathlib import Path
import hashlib
import json
import base64
import plistlib
import subprocess
import fcntl
import os
import re
from phone_kit_signing import HELPER_ID, CLIENT_REQUIREMENT, HELPER_REQUIREMENT, DRIVER_REQUIREMENT, RELEASE, sign
from verify_phone_kit import sections

ROOT = Path(__file__).resolve().parent.parent


def version_number(value: str) -> int:
    parts = value.split('.')
    if len(parts) != 3 or any(not part.isdigit() for part in parts):
        raise ValueError(f'Invalid helper build version: {value!r}')
    major, minor, patch = map(int, parts)
    if not (1 <= major <= 9999 and 0 <= minor <= 99 and 0 <= patch <= 99):
        raise ValueError(f'Helper build version exceeds CFBundleVersion constraints: {value!r}')
    return major * 10000 + minor * 100 + patch


def next_build_version(output: Path) -> str:
    # Consult installed state as well as the local counter so cleaning dist or
    # switching checkouts cannot silently reset SMJobBless's upgrade version.
    requested = os.environ.get('PHONE_KIT_BUILD_VERSION')
    if requested:
        version_number(requested)
        return requested
    if RELEASE:
        raise ValueError('Set a monotonically increasing PHONE_KIT_BUILD_VERSION for distribution.')
    counter_path = output / 'build-version.txt'
    with (output / 'build-version.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        previous = [version_number('3.0.0')]
        if counter_path.exists():
            previous.append(version_number(counter_path.read_text().strip()))
        for helper in (output / HELPER_ID, Path('/Library/PrivilegedHelperTools') / HELPER_ID):
            if helper.exists():
                info = plistlib.loads(sections(helper)[('__TEXT', '__info_plist')].rstrip(b'\0'))
                previous.append(version_number(info['CFBundleVersion']))
        number = max(previous) + 1
        value = f'{number // 10000}.{number % 10000 // 100}.{number % 100}'
        version_number(value)
        temporary = output / 'build-version.txt.new'
        temporary.write_text(value + '\n')
        temporary.replace(counter_path)
        return value


def swift_source(driver: Path) -> str:
    entries = {}
    for path in sorted(driver.rglob('*')):
        if path.is_symlink():
            raise ValueError('Phone Assistant Audio Bridge payload may not contain symlinks')
        if path.is_file():
            entries[path.relative_to(driver).as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
    literals = ',\n'.join(f'        {json.dumps(path)}: {json.dumps(digest)}' for path, digest in entries.items())
    payload = ',\n'.join(f'        {json.dumps(path)}: {json.dumps(base64.b64encode((driver/path).read_bytes()).decode())}' for path in entries)
    legacy = json.loads((ROOT/'native/PhoneKit/LegacyPayloads.json').read_text())
    legacy_swift = '[' + ','.join('[' + ','.join(json.dumps(k)+':'+json.dumps(v) for k,v in item.items()) + ']' for item in legacy) + ']'
    signing = subprocess.run(['codesign', '-d', '--verbose=4', str(driver)], text=True, capture_output=True, check=True)
    code_hash = re.search(r'^CDHash=([a-f0-9]+)$', signing.stderr, re.MULTILINE).group(1)
    return ('enum PhoneKitBuild {\n    static let files: [String: String] = [\n' + literals + '\n    ]\n'
            + '    static let payload: [String: String] = [\n' + payload + '\n    ]\n'
            + '    static let legacyPayloads: [[String: String]] = ' + legacy_swift + '\n'
            + '    static let driverRequirement = ' + json.dumps(DRIVER_REQUIREMENT) + '\n'
            + '    static let driverCodeHash = ' + json.dumps(code_hash) + '\n'
            + '    static let clientRequirement = ' + json.dumps(CLIENT_REQUIREMENT) + '\n'
            + '    static let helperRequirement = ' + json.dumps(HELPER_REQUIREMENT) + '\n}\n')


def build(development_test=False) -> Path:
    subprocess.run(['python3', str(ROOT / 'script/build_drivers.py')], check=True)
    output = ROOT / 'dist/phone-kit'
    output.mkdir(parents=True, exist_ok=True)
    version = next_build_version(output)
    source = output / 'PhoneKitHelper.swift'
    driver = ROOT / 'dist/drivers/CodexCallSend.driver'
    source.write_text(swift_source(driver)
                      + (ROOT / 'native/PhoneKit/PhoneKitInstaller.swift').read_text()
                      + (ROOT / 'native/PhoneKit/PhoneKitPrivilegedProtocol.swift').read_text()
                      + (ROOT / 'native/PhoneKit/PhoneKitDaemon.swift').read_text())
    helper = output / HELPER_ID
    info = {'CFBundleIdentifier': HELPER_ID, 'CFBundleName': 'Phone Assistant Audio Bridge',
            'CFBundleVersion': version, 'CFBundleShortVersionString': '0.3.0',
            'SMAuthorizedClients': [CLIENT_REQUIREMENT]}
    launchd = {'Label': HELPER_ID, 'MachServices': {HELPER_ID: True},
               'AssociatedBundleIdentifiers': ['com.codexcall.menu'],
               'ProcessType': 'Interactive'}
    for name, data in [('Helper-Info.plist', info), ('Helper-Launchd.plist', launchd)]:
        (output/name).write_bytes(plistlib.dumps(data, fmt=plistlib.FMT_XML))
    subprocess.run(['xcrun', 'swiftc', '-target', 'arm64-apple-macos14.2', '-O',
                    '-module-cache-path', str(ROOT / 'artifacts/phone-kit-module-cache'),
                    '-Xlinker', '-sectcreate', '-Xlinker', '__TEXT', '-Xlinker', '__info_plist', '-Xlinker', str(output/'Helper-Info.plist'),
                    '-Xlinker', '-sectcreate', '-Xlinker', '__TEXT', '-Xlinker', '__launchd_plist', '-Xlinker', str(output/'Helper-Launchd.plist'),
                    str(source), '-o', str(helper)], check=True)
    sign(helper, HELPER_ID, development_test=development_test)
    return helper


if __name__ == '__main__':
    print(build())
