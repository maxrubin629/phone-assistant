from pathlib import Path
import plistlib,shutil,subprocess,os,tempfile
from build_phone_kit import build as build_phone_kit
from phone_kit_signing import HELPER_ID, HELPER_REQUIREMENT, CLIENT_REQUIREMENT, RELEASE, BUILD_VERSION, sign
from verify_phone_kit import verify as verify_phone_kit
root=Path(__file__).resolve().parent.parent
def replace(source, destination):
    # Write a new file and rename it into place. Overwriting in place would
    # change pages a running copy of the app still maps, and macOS kills a
    # process whose code no longer matches its signature.
    staged = destination.with_name('.' + destination.name + '.staging')
    shutil.copy2(source, staged)
    os.replace(staged, destination)
bundle=root/'dist'/'CallMenu.app';content=bundle/'Contents';macos=content/'MacOS';macos.mkdir(parents=True,exist_ok=True)
configuration='release' if RELEASE else 'debug'
binary=root/('native/.build/'+configuration+'/CallMenu')
replace(binary,macos/'CallMenu')
mcp_binary=root/('native/.build/'+configuration+'/CallMCP')
if not mcp_binary.is_file(): raise SystemExit('Build the bundled CallMCP executable before staging the app.')
replace(mcp_binary,macos/'CallMCP')
sign(macos/'CallMCP')
helper=build_phone_kit()
helpers=content/'Library/LaunchServices'; helpers.mkdir(parents=True,exist_ok=True)
replace(helper,helpers/HELPER_ID)
old_helper=content/'Helpers/PhoneKitInstaller'
if old_helper.exists(): old_helper.unlink()
kit=content/'Resources/PhoneKit'; kit.mkdir(parents=True,exist_ok=True)
payload=kit/'CodexCallSend.driver'
if payload.is_symlink(): raise SystemExit('Refusing symlink bundle staging destination')
if payload.exists(): shutil.rmtree(payload)
shutil.copytree(root/'dist/drivers/CodexCallSend.driver',payload)
shutil.copy2(root/'dist/drivers/build-manifest.json',kit/'build-manifest.json')
def compile_icon(resources):
    # actool renders the Icon Composer bundle into Assets.car for macOS 26's
    # Liquid Glass icons, and AppIcon.icns for earlier releases.
    with tempfile.TemporaryDirectory() as work:
        catalog=Path(work)/'Empty.xcassets'; catalog.mkdir()
        (catalog/'Contents.json').write_text('{"info":{"author":"xcode","version":1}}')
        output=Path(work)/'out'; output.mkdir()
        subprocess.run(['xcrun','actool',str(catalog),str(root/'native/Resources/AppIcon.icon'),'--compile',str(output),
            '--app-icon','AppIcon','--target-device','mac','--platform','macosx','--minimum-deployment-target','14.2',
            '--output-partial-info-plist',str(Path(work)/'icon.plist')],check=True,stdout=subprocess.DEVNULL)
        for name in ('Assets.car','AppIcon.icns'): replace(output/name,resources/name)
compile_icon(content/'Resources')
data={'CFBundleExecutable':'CallMenu','CFBundleIdentifier':'com.codexcall.menu','CFBundleName':'Phone Assistant','CFBundleDisplayName':'Phone Assistant','CFBundlePackageType':'APPL','CFBundleVersion':BUILD_VERSION,'CFBundleShortVersionString':'0.3.0','LSMinimumSystemVersion':'14.2','CFBundleIconName':'AppIcon','CFBundleIconFile':'AppIcon','LSUIElement':True,'NSMicrophoneUsageDescription':'Route the microphone you select to the caller or your selected listening output.','NSAudioCaptureUsageDescription':'Capture only the application you select and route its audio to the caller or your listening output.'}
data.update({'SMPrivilegedExecutables': {HELPER_ID: HELPER_REQUIREMENT},
             'PhoneKitHelperRequirement': HELPER_REQUIREMENT,
             'PhoneKitClientRequirement': CLIENT_REQUIREMENT})
with (content/'Info.plist').open('wb') as f:plistlib.dump(data,f)
entitlements=root/'dist/phone-kit/App.entitlements'
entitlements.write_bytes(plistlib.dumps({'com.apple.security.device.audio-input': True}))
sign(bundle, entitlements=entitlements)
subprocess.run(['codesign','--verify','--strict','--deep',str(bundle)],check=True)
verify_phone_kit(bundle)
print(bundle)

if RELEASE:
    raise SystemExit(0)

