#!/usr/bin/env python3
"""Read-only verification of native blessing metadata and mutual signing requirements."""
from pathlib import Path
import plistlib
import struct
import subprocess
from phone_kit_signing import HELPER_ID, HELPER_REQUIREMENT, CLIENT_REQUIREMENT, DRIVER_REQUIREMENT

ROOT = Path(__file__).resolve().parent.parent


def sections(binary):
    data = binary.read_bytes()
    if data[:8] != bytes.fromhex('cffaedfe0c000001'):
        raise ValueError('Expected a thin Apple Silicon Mach-O helper')
    count = struct.unpack_from('<I', data, 16)[0]
    offset = 32
    result = {}
    for _ in range(count):
        command, size = struct.unpack_from('<II', data, offset)
        if command == 0x19:
            number = struct.unpack_from('<I', data, offset+64)[0]
            for index in range(number):
                section = offset+72+index*80
                name, segment = struct.unpack_from('<16s16s', data, section)
                length, file_offset = struct.unpack_from('<QI', data, section+40)
                result[(segment.rstrip(b'\0').decode(), name.rstrip(b'\0').decode())] = data[file_offset:file_offset+length]
        offset += size
    return result


def verify(bundle):
    app = plistlib.loads((bundle/'Contents/Info.plist').read_bytes())
    helper = bundle/'Contents/Library/LaunchServices'/HELPER_ID
    embedded = sections(helper)
    info = plistlib.loads(embedded[('__TEXT', '__info_plist')].rstrip(b'\0'))
    launchd = plistlib.loads(embedded[('__TEXT', '__launchd_plist')].rstrip(b'\0'))
    assert info['CFBundleIdentifier'] == HELPER_ID
    assert info['SMAuthorizedClients'] == [CLIENT_REQUIREMENT]
    assert launchd['Label'] == HELPER_ID
    assert launchd['MachServices'] == {HELPER_ID: True}
    assert 'Program' not in launchd and 'ProgramArguments' not in launchd
    assert app['SMPrivilegedExecutables'] == {HELPER_ID: HELPER_REQUIREMENT}
    assert app['PhoneKitHelperRequirement'] == HELPER_REQUIREMENT
    assert app['PhoneKitClientRequirement'] == CLIENT_REQUIREMENT
    driver = bundle/'Contents/Resources/PhoneKit/CodexCallSend.driver'
    driver_info = plistlib.loads((driver/'Contents/Info.plist').read_bytes())
    assert driver_info['CFBundleName'] == 'Phone Assistant'
    assert driver_info['CFBundleIdentifier'] == 'com.codexcall.audio.send'
    assert info['CFBundleName'] == 'Phone Assistant Audio Bridge'
    if not app.get('CallEnableBackend'):
        assert 'CallProjectRoot' not in app and 'CallServerURL' not in app
    for binary in [helper, bundle/'Contents/MacOS/CallMenu', driver/'Contents/MacOS/CodexCallSend']:
        assert subprocess.check_output(['lipo', '-archs', str(binary)], text=True).strip() == 'arm64'
    for path, requirement in [(helper, HELPER_REQUIREMENT), (bundle, CLIENT_REQUIREMENT), (driver, DRIVER_REQUIREMENT)]:
        subprocess.run(['codesign', '--verify', '--strict', '-R', '=' + requirement, str(path)], check=True)
    subprocess.run(['codesign', '--verify', '--strict', '--deep', str(bundle)], check=True)
    print('Phone Assistant Audio Bridge native helper metadata, mutual signing requirements, and nested signatures verified.')


if __name__ == '__main__':
    verify(ROOT/'dist/CallMenu.app')
