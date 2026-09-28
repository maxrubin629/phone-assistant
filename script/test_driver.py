#!/usr/bin/env python3
"""Exercise the Send driver in this process, without registering/loading it in HAL."""
from pathlib import Path
import json, plistlib, subprocess, sys

root=Path(__file__).resolve().parent.parent
out=root/'artifacts'/'driver-tests'; out.mkdir(parents=True,exist_ok=True)
subprocess.run([sys.executable,str(root/'script/build_drivers.py')],check=True)
bundle=root/'dist/drivers/CodexCallSend.driver'
binary=bundle/'Contents/MacOS/CodexCallSend'
info=plistlib.loads((bundle/'Contents/Info.plist').read_bytes())
assert info['CFBundleIdentifier']=='com.codexcall.audio.send'
assert info['CFBundleExecutable']=='CodexCallSend'
assert len(info['CFPlugInFactories'])==1
assert subprocess.check_output(['lipo','-archs',str(binary)],text=True).strip()=='arm64'
subprocess.run(['codesign','--verify','--strict',str(bundle)],check=True)
results=[]
for test in ('test_loopback','test_driver'):
    executable=out/test
    command=['xcrun','clang','-arch','arm64','-std=gnu11','-g','-O1','-fsanitize=address,undefined',str(root/'native/Driver'/f'{test}.c'),'-o',str(executable)]
    if test=='test_driver': command+=['-framework','CoreAudio','-framework','CoreFoundation']
    subprocess.run(command,check=True)
    result=subprocess.run([str(executable)]+([str(binary)] if test=='test_driver' else []),check=True,text=True,capture_output=True)
    print(result.stdout.strip())
    results.append({'name':test,'result':'passed','output':result.stdout.strip()})
report={'results':results,'architecture':'arm64','signatureVerified':True,'loadedIntoSystemHAL':False,'phoneCallCompatibility':'not qualified'}
(out/'results.json').write_text(json.dumps(report,indent=2)+'\n')
print(out/'results.json')
