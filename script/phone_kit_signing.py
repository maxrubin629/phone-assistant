"""Build-machine signing configuration. Never embedded as a developer path."""
import os
import re
import subprocess

HELPER_ID = 'com.codexcall.phonekit.helper'
APP_ID = 'com.codexcall.menu'
RELEASE = os.environ.get('PHONE_KIT_RELEASE') == '1'
TEST_SIGNING = os.environ.get('PHONE_KIT_TEST_SIGNING') == '1'
BUILD_VERSION = os.environ.get('PHONE_KIT_BUILD_VERSION', '3.2.0')
if not re.fullmatch(r'[1-9][0-9]{0,3}\.[0-9]{1,2}\.[0-9]{1,2}', BUILD_VERSION):
    raise ValueError('PHONE_KIT_BUILD_VERSION must be a numeric major.minor.patch version.')
if RELEASE and TEST_SIGNING:
    raise ValueError('A distribution build cannot use test signing.')


def resolve_identity():
    if TEST_SIGNING:
        return '-', 'TESTTEAM01'
    output = subprocess.check_output(['security', 'find-identity', '-v', '-p', 'codesigning'], text=True)
    identities = re.findall(r'([A-F0-9]{40}) "([^"]+)"', output)
    requested = os.environ.get('PHONE_KIT_SIGNING_IDENTITY')
    prefix = 'Developer ID Application:' if RELEASE else 'Apple Development:'
    matches = [(sha, name) for sha, name in identities
               if (requested in (sha, name) if requested else name.startswith(prefix))]
    if len(matches) != 1:
        raise ValueError('Set PHONE_KIT_SIGNING_IDENTITY to one installed ' + prefix + ' identity.')
    sha, name = matches[0]
    if RELEASE and not name.startswith('Developer ID Application:'):
        raise ValueError('Distribution requires a Developer ID Application certificate.')
    certificate = subprocess.check_output(['security', 'find-certificate', '-c', name, '-p'])
    subject = subprocess.check_output(['openssl', 'x509', '-noout', '-subject', '-nameopt', 'sep_multiline'],
                                      input=certificate).decode()
    match = re.search(r'OU\s*=\s*([A-Z0-9]{10})\b', subject)
    if not match:
        raise ValueError('Cannot read the signing certificate Team ID.')
    team = match.group(1)
    if os.environ.get('PHONE_KIT_TEAM_ID', team) != team:
        raise ValueError('PHONE_KIT_TEAM_ID does not match the certificate.')
    return sha, team


SIGNING_IDENTITY, TEAM_ID = resolve_identity()


def requirement(identifier):
    return f'anchor apple generic and identifier "{identifier}" and certificate leaf[subject.OU] = "{TEAM_ID}"'


CLIENT_REQUIREMENT = requirement(APP_ID)
HELPER_REQUIREMENT = requirement(HELPER_ID)
DRIVER_REQUIREMENT = requirement('com.codexcall.audio.send')


def sign(path, identifier=None, entitlements=None, development_test=False):
    test = development_test or TEST_SIGNING
    if RELEASE and test:
        raise ValueError('Distribution cannot contain ad-hoc code.')
    command = ['codesign', '--force', '--sign', '-' if test else SIGNING_IDENTITY]
    if identifier:
        command += ['--identifier', identifier]
    if not test:
        command += ['--options', 'runtime']
        if RELEASE:
            command += ['--timestamp']
    if entitlements:
        command += ['--entitlements', str(entitlements)]
    subprocess.run(command + [str(path)], check=True)
    subprocess.run(['codesign', '--verify', '--strict', str(path)], check=True)
