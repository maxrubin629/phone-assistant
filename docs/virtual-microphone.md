# Send virtual microphone contract

`CodexCallSend.driver` is the app-owned output-to-input transport. `CallAudio.c` derives from [Apple's Creating an Audio Server Driver Plug-in sample](https://developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in), with Apple's license retained in source and the built bundle. `Loopback.h` implements the bounded sample transport.

The bundle exposes the input-only Phone Assistant microphone at `com.codexcall.audio.send.device` and a hidden output-only feed at `com.codexcall.audio.send.feed`. The app writes the permitted microphone and generated-speech mix to the feed. Phone reads the public input. Incoming caller audio uses a separate process tap.

| Property | Contract |
|---|---|
| Bundle / device UID | `com.codexcall.audio.send` / `com.codexcall.audio.send.device` |
| CPU / deployment target | arm64 / macOS 14.0; the full app's process-tap requirement is separate |
| Format | Exactly 48,000 Hz, two channels, packed native-endian interleaved Float32 |
| Buffer | 32,768 frames, preallocated, indexed by absolute sample time |
| Delivery | Input frame `t` reads output frame `t - 512` |
| Declared latency | 512 input frames (10.667 ms); zero output latency, stream latency, and extra safety offset |
| Clock | `mach_absolute_time`, zero timestamps quantized every 512 frames; queries catch up across skipped periods |
| Lifecycle | Both devices share one clock. The first client after both sides stop anchors a new clock. Stopping the last feed client clears queued speech even if microphone readers remain open. |
| Gain | Separate input/output volume controls, unity defaults, −64 to 0 dB; squared-scalar interpolation in amplitude gives about −12 dB at 50%; each applies once |
| System alert device | Declines the default-system-device role |

The latency is transport latency alone; HAL buffering, converter queues, network latency and Phone processing add delay. Only installed loopback measurement can establish actual end-to-end latency.

Read operations never consume data, so multiple clients can read the same frames independently. A missing frame tag produces silence; ring wrap cannot replay old audio. A write that moves backward invalidates the previous time line. Non-finite audio or gain becomes silence, large finite samples clamp to ±1, and timestamp/size validation prevents unsafe integer conversion and unbounded IO loops. The ring holds at most about 683 ms, not an unbounded playback backlog.

Realtime IO uses only bounded work and `pthread_mutex_trylock`; it never waits for another callback. Contention yields silence or a dropped write. Start, Stop and configuration callbacks may take blocking locks because those are lifecycle operations. Timestamp queries also use a try-lock and return an error during the short clock-reset critical section rather than blocking. The design follows the installed public `CoreAudio/AudioServerPlugIn.h` contract: the host owns the IO cycle, supplies sample-time addresses, stops IO before configuration changes, and resynchronizes when the timestamp seed changes.

`python3 script/test_driver.py` builds and verifies the arm64 signature, runs ASan/UBSan-instrumented standalone harnesses, and writes `artifacts/driver-tests/results.json`. Transport checks cover unwritten/stale silence, wraparound, independent readers, rewinds, gaps, forced lock contention, non-finite samples, clipping and integer bounds. HAL-interface checks cover factory loading, format lists, rate rejection, latency, gain/mute, two clients, clock catch-up and epoch changes, invalid input and stop/restart. The production dynamic library itself is built normally; sanitizers instrument the harnesses and the transport-header test.

The tests load the library into their own process via `dlopen`; they do **not** load it into `coreaudiod`, modify routes, restart services, or call anyone. They prove the implemented interface behavior, not that Phone on this macOS release accepts the device. Before enabling live calls, qualify HAL discovery, silence when no writer exists, mixed mic/AI amplitude, dropout behavior at negotiated buffer sizes, sustained drift, route restoration, and Phone's actual far-end audibility. The current bundle is development-signed and has not been notarized for distribution.

Installation is bundled into the app's **Enable Phone Assistant Audio Bridge** setup action. It validates the payload, requests macOS administrator authorization, installs only Send and reconnects the single Core Audio service when activation is needed. It verifies the actual loaded UID before reporting readiness. No Mac reboot or security-setting change is requested. See [Phone Assistant Audio Bridge installation](phone-kit-installation.md) for activity checks, failure handling and live-verification limits. The legacy install script now directs users to this setup flow. Uninstall validates only Send and moves it into `/Library/Audio/CodexCallDisabled/`; no driver is deleted or removed on ordinary app Stop, and legacy user devices are preserved.
