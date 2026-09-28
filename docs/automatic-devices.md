# Automatic audio devices

Automatic follows the microphone and output currently selected in macOS, including changes during a running route. A user can switch from speakers to AirPods in macOS without choosing devices again in Phone Assistant. Input and output follow independently. Only participation that permits microphone use opens the physical microphone in the generated-voice runtime; the standalone audio test retains its explicit microphone opt-in.

## Selection and upgrades

The Advanced audio test offers Automatic in both physical-device selectors. A new configuration defaults to Automatic, and the Chrome + microphone preset chooses it for both endpoints. An explicitly selected device is a fixed override. Existing saved `audioRouting.v1` UIDs stay fixed after upgrade, preserving prior selections. Choosing Automatic stores an empty UID using the existing preference schema. The native Phone bridge always follows macOS independently of the Advanced application test. Existing fixed overrides remain saved for that test only. The older development controls also default to Automatic.

The runtime reads `kAudioHardwarePropertyDefaultInputDevice` and `kAudioHardwarePropertyDefaultOutputDevice`. The latter is the ordinary playback output, not the separate system sound-effects device. It never writes these properties, changes Phone's input selection, or installs anything. Automatic rejects virtual and aggregate devices to prevent routing the Phone Assistant output back into itself. If macOS selects an unsupported device, that path waits for a usable physical selection rather than guessing another endpoint.

## Running behavior

Both native audio workers reconcile physical endpoints every 100 ms while running. Detection time is separate from Core Audio/Bluetooth activation latency, so a switch may have a brief audio gap. This is not a claim of gapless playback.

- Replace the old endpoint only after its I/O callback is stopped and released. Failed cleanup retains ownership and stops the route; a second endpoint cannot use the same buffer concurrently.
- Rebuild converters for the new device's actual sample rate. Current supported native formats remain Float32 PCM, 8–192 kHz.
- Keep the captured application or Phone tap, the Phone Assistant send endpoint, the model session, and its audience/epoch unchanged. Temporarily close audio delivery during the physical change and discard samples accumulated in that gap.
- Preserve caller mute, listening choices, participation, and cancellation. Stop during a switch prevents the newly created endpoint from being retained. Never replay private output that arrived while its listening device was missing.
- When an automatic device is temporarily missing, pause that path and retry. A failed open retries at most twice per second. A missing fixed device still stops the route rather than following another device.

Automatic follows macOS even when macOS falls back to speakers after headphones disconnect. There is no additional confirmation or separate exception for an aside. This implements the user's clarification to follow the system selection continuously. A fixed override is available when that behavior is unwanted.

The default-device resolver does not authorize microphone participation. Device switching cannot turn a disabled microphone on. The standalone application's capture identity and the Phone renderer remain strictly scoped. Unrelated application/process changes still stop capture rather than widening it. A changed virtual-device or capture format still stops routing; physical format changes rebuild their converters.

## Verification

A recorded run passed 37 Swift tests, including nine device-following tests. Those tests exercise output changes independently from input, sample-rate changes on the same device, missing/reappearing defaults, retry after failed activation, fixed overrides, disabled microphone behavior, cancellation, retained ownership after failed cleanup, and mute/listening gates. Existing conversion, route-isolation, DSP concurrency, and transport checks also passed.

The rebuilt app launched and restored the existing interrupted onboarding step. Its nested signatures and helper metadata verified. The installed kit remained ready with no update pending. A read-only Core Audio snapshot after launch showed no active audio for Phone Assistant or Phone. Both AirPods input and output were present in the macOS defaults, while the sound-effects output remained Mac speakers, confirming why the ordinary playback default must be used.

These are automated/local checks, not a successful remote call. The UI automation connection failed when opening Advanced, so a user-assisted live AirPods/speaker handoff and perceived audio continuity are still pending. The subsequent [Phone bridge](phone-bridge.md) connects the native voice transport, with remote call verification still pending. No system component or permission category changes were required or installed for this feature.
