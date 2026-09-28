#!/usr/bin/env python3
"""Build the single Apple Silicon Send HAL plug-in; never install or restart audio."""
from pathlib import Path
import json,plistlib,subprocess,uuid
from phone_kit_signing import sign, TEST_SIGNING, BUILD_VERSION
root=Path(__file__).resolve().parent.parent
for side in ('Send',):
    name='CodexCall'+side
    identifier='com.codexcall.audio.'+side.lower()
    bundle=root/'dist'/'drivers'/(name+'.driver')
    if bundle.is_symlink(): raise SystemExit('Refusing a symbolic-link build destination')
    macos=bundle/'Contents'/'MacOS';macos.mkdir(parents=True,exist_ok=True)
    factory=str(uuid.uuid5(uuid.NAMESPACE_DNS,identifier)).upper()
    data={'CFBundleExecutable':name,'CFBundleIdentifier':identifier,'CFBundleName':'Phone Assistant','CFBundleVersion':BUILD_VERSION,'CFBundleShortVersionString':'0.3.0','CFBundlePackageType':'BNDL','LSMinimumSystemVersion':'14.0','CFPlugInDynamicRegistration':False,'CFPlugInFactories':{factory:'NullAudio_Create'},'CFPlugInTypes':{'443ABAB8-E7B3-491A-B985-BEB9187030DB':[factory]}}
    with (bundle/'Contents'/'Info.plist').open('wb') as f:plistlib.dump(data,f)
    resources=bundle/'Contents/Resources';resources.mkdir(parents=True,exist_ok=True)
    (resources/'APPLE-LICENSE.txt').write_bytes((root/'native/Driver/APPLE-LICENSE.txt').read_bytes())
    subprocess.run(['xcrun','clang','-arch','arm64','-dynamiclib','-Wl,-install_name,@rpath/CodexCallSend','-std=gnu11','-fblocks','-O2','-mmacosx-version-min=14.0','-framework','CoreAudio','-framework','CoreFoundation','-DCALL_DRIVER_ID="'+identifier+'"','-DCALL_DRIVER_NAME="Phone Assistant"',str(root/'native/Driver/CallAudio.c'),'-o',str(macos/name)],check=True)
    sign(bundle)
    subprocess.run(['codesign','--verify','--strict',str(bundle)],check=True)
    arch=subprocess.check_output(['lipo','-archs',str(macos/name)],text=True).strip()
    if arch!='arm64': raise SystemExit('Unexpected architectures: '+arch)
    (root/'dist'/'drivers'/'build-manifest.json').write_text(json.dumps({'bundles':[name+'.driver'],'architecture':arch,'deviceUID':identifier+'.device','feedDeviceUID':identifier+'.feed','publicInputOnly':True,'hiddenOutputOnly':True,'sampleRate':48000,'channels':2,'inputLatencyFrames':512,'signature':'ad-hoc-test' if TEST_SIGNING else 'Apple-signed','loadedIntoHAL':False},indent=2)+'\n')
    print(bundle)
