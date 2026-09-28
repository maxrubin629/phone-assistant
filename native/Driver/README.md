# App-owned Send virtual microphone

Based on Apple's MIT-licensed NullAudio sample, downloaded from https://docs-assets.developer.apple.com/published/430ad6501f6f/CreatingAnAudioServerDriverPlugIn.zip. The original license is preserved in APPLE-LICENSE.txt and the source header.

The bundle publishes an input-only `Phone Assistant` microphone with its existing UID `com.codexcall.audio.send.device`, and a hidden output-only `Phone Assistant Feed`, UID `com.codexcall.audio.send.feed`. Audio written to the feed becomes microphone input 512 frames later. Both share one clock and bounded transport. The receiving side uses an application process tap and does not require a Receive driver.

- GPT-Live plus the selected microphone → app mixer → hidden feed output → Phone Assistant input → Phone microphone.
- Phone output → app-scoped Core Audio tap → agent. The driver does not capture system audio.

Build with `python3 script/build_drivers.py`. Test with `python3 script/test_driver.py`. The arm64 bundle lands at `dist/drivers/CodexCallSend.driver` and uses the configured Apple signing identity; isolated test builds may explicitly use ad-hoc signing. The tests invoke its exported HAL interface in an isolated process; they do not register it with system Core Audio. See [the virtual microphone contract](../../docs/virtual-microphone.md) for exact behavior and qualification limits.

Use the bundled [Phone Assistant Audio Bridge setup flow](../../docs/phone-kit-installation.md) to install or update the device. It validates the publisher and payload, preserves the stable device identity, and atomically replaces a recognized older installation. Activation briefly reconnects Core Audio and requires other audio to be idle. The legacy shell installer is not the user-facing setup path. Distribution signing/notarization and real Phone-call qualification remain outstanding.

The hidden feed is resolved by UID and cannot become a default output. Hidden is a discovery property, not access control. Other applications with its UID may address it. The app owns call-session activation and route restoration. The microphone retains its UID and input controls on upgrade; its former public output is removed. No new driver bundle or permission category is added. Input-only exposure addresses a suspected echo-reference interaction; successful remote Phone transmission remains to be qualified.

Per-device running counts share a clock that resets only when both sides have stopped. Late readers do not reset the feed timeline. When the last feed client stops, queued speech is cleared even if Phone still has the microphone open. Independent readers never consume each other's audio. The runtime observes the public input through a separate, scalar-only callback with its own telemetry queue.

Hardware input and output volume controls use the
amplitude curve: `gain = floor + (1 - floor) * scalar²`, with
`floor = 10^(-64/20)`. Half volume is approximately -12 dB, not the -72 dB
produced by the earlier sample-derived squared-decibel curve. Scalar zero is
the finite -64 dB floor; the separate mute control provides exact silence.
Scalar one is exactly unity. `Volume.h` supplies the shared control conversions
and PCM gain so reported decibels, setting decibels, and actual audio agree.
Non-finite control requests are rejected. The two directions retain separate
controls, stable IDs, and existing mute behavior. Existing non-unity scalar
settings have a different, substantially louder interpretation after upgrade;
this change does not establish or claim a fix for Phone's downstream processing.
