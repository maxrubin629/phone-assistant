#!/usr/bin/env python3
"""Check native epoch/backpressure behavior without audio devices or a server."""
from pathlib import Path
import json
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
sources = [root/'native/Sources/CallMenu/Models/Models.swift',
           root/'native/Sources/CallMenu/Services/BoundedAudioSender.swift',
           root/'native/Tests/CallMenuChecks/Checks.swift']
with tempfile.TemporaryDirectory(prefix='codex-call-transport-') as temporary:
    directory = Path(temporary)
    binary = directory/'NativeTransportChecks'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5',
                    '-target', 'arm64-apple-macosx14.2', '-module-cache-path', str(directory/'cache'),
                    *map(str, sources), '-o', str(binary)], check=True)
    result = subprocess.run([str(binary)], text=True, capture_output=True, check=True)
    print(result.stdout.strip())
    out = root/'artifacts/native-transport'
    out.mkdir(parents=True, exist_ok=True)
    (out/'results.json').write_text(json.dumps({'passed': True, 'architecture': 'arm64',
        'hardware_audio_opened': False, 'network_connection_opened': False,
        'output': result.stdout.strip()}, indent=2) + '\n')
