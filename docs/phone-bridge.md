# Native Phone bridge

The normal Apple Silicon app now connects directly to GPT-Live through URLSession WebSocket. It needs no local server or project path. The bundled Phone Assistant Audio Bridge is unchanged.

## Controls

Two independent selectors each offer GPT-Live, Me, and Both:

- Caller hears chooses generated voice, the selected physical microphone, or their mix.
- Caller is heard by chooses model input, local listening, or both. Local listening includes assistant speech whenever the assistant is allowed to speak.

GPT-Live/GPT-Live is the background default. No physical microphone or listening output is opened. Listening alone never enables the microphone. Me/Both lets the owner speak while the model listens silently. Both/Both enables joint participation. Me/Me disconnects the provider; no call audio or transcript from that segment is forwarded when GPT-Live later resumes.

When Me or Both is selected for speaking, **Microphone to caller** adjusts the
owner's outgoing voice from 0% to 400%. The level changes during a connection and
is remembered under `phoneBridgeMicrophoneGain`. New installations and Reset use
100%. Existing saved gain is preserved on upgrade and initially also supplies the
microphone-to-model level. The live panel can then adjust those paths independently.
Advanced test levels remain separate.

### Live audio controls

The main window's **Live audio controls** button opens a separate window that can
stay beside Phone. It controls the current bridge; it does not start a second test
engine. Its four sections are:

- **Levels:** independent gain and mute for microphone-to-caller, GPT-to-caller,
  caller-to-user, GPT-to-user, microphone-to-GPT and caller-to-GPT. Controls cannot
  enable a destination excluded by the main participant selectors. Gain and mute
  changes do not replace the voice session or restart capture.
- **Processing:** peak limiter enabled/bypassed, ceiling (10–99.9%) and release
  (10–1000 ms). The default remains enabled, 98%, 80 ms. Bypass uses finite full-scale
  hard clipping, so it is a comparison control rather than a quality improvement.
  **Let Phone handle caller playback** changes the existing process tap's documented
  description property. It leaves Phone's own selected output audible, and disables
  app caller monitoring to prevent doubled playback. In Me/Me it closes the app's
  unused listening output. It requires local listening; removing local listening
  restores managed playback. No call is dialed, disconnected, or rerouted globally.
- **Devices:** physical microphone and app listening output, using stable UIDs or
  Automatic. Explicit changes reuse the existing endpoint replacement path and may
  briefly pause app audio. Automatic follows macOS. These overrides last for this
  app session and do not change system defaults or Phone's microphone selection.
- **Hardware:** the selected physical microphone/output and both directions of
  Phone Assistant expose volume and mute only when the HAL property exists and is
  writable. These are explicit user device changes and may affect other clients;
  they are not automatically adjusted or restored. Values refresh every two seconds.

The window shows microphone, outgoing mix and virtual-input readback peak/RMS,
caller level, and shortage/lost-measurement counters. No-frames is distinct from
silence. **Mark fade now** timestamps a local event; **Copy diagnostics** copies
bounded levels and control history without audio, transcript, call identity or key.
**Reset levels and limiter** resets software gains, path mutes and limiter settings;
it leaves hardware, selected devices, native playback and global caller-send mute
alone. Only the main microphone-to-caller gain is persisted. Other troubleshooting
settings start normally when the app relaunches.

Apple/Phone processing is not represented by fake switches. This app adds no noise
gate, automatic gain control or echo cancellation. Device sample rates remain
automatic; the virtual device remains stereo Float32 at 48 kHz. Live controls do
not require another permission category, driver installation, or security change.

Local verification for these controls: 77 CallAudio tests passed, including limiter
bypass/ceiling/release, independent monitor gain, route authorization, mute and
cancellation, and native playback's endpoint requirements. The synthetic capture
check switched the existing tap both ways, read back the selected behaviors and
preserved a 997 Hz signal (peak 0.10000003, RMS 0.07071069) with no format changes.
UI checks verified the Levels window, independent gain/mute/reset, and 300% gain
retention across relaunch. Full UI inspection of Processing remains incomplete:
SkyComputerUseService crashed in `Array.remove(at:)`; Phone Assistant stayed running.
No active call was changed, hardware volume was not altered, and no new driver
was installed. A successful remote call or fade fix is not claimed.

On September 20, the automatic startup report captured the continuing signal
through 26 seconds while the user reported another remote fade around four
seconds. Virtual readback stayed about 16 dB below the app's output across the
early and later intervals. The app's peak was 0.1331, leaving headroom for a 300%
microphone setting (about +9.54 dB, predicted peak 0.3993 for that same input).
That level adjustment addresses quietness. It does not establish the cause or
resolution of the remote fade; the report cannot measure Phone's downstream
processing or the listener's received audio.

Physical devices default to the current macOS input and ordinary output, including changes during a call. Advanced application-test device overrides do not apply to normal calls; they remain saved for that test only. The app never changes macOS default devices. Managed capture suppresses Phone's original playback, and only authorized local listening is rendered; the explicit native-playback comparison leaves Phone's output audible. Unrelated applications are not captured. The app verifies that the active Phone renderer is actually using the stable Phone Assistant UID for input before capturing or claiming a connected bridge, and periodically rechecks it.

## Try a call

1. Finish the existing assistant setup. Add a key in Settings → Voice if one was not supplied in the process environment.
2. Enable **Automatic Phone microphone** in Audio setup once, then start or answer a test call in Apple's Phone app with a willing remote listener.
3. In Phone Assistant, choose the speaking and listening participants, then Connect Phone audio. The app selects Phone Assistant in Phone’s microphone menu and verifies the checkmark before checking the active audio route.
4. Have the listener speak and confirm what each participant can hear. Exercise takeover, both speaking, and Me/Me before using the bridge for a real task.
5. Disconnect when finished. This restores Phone's ordinary playback and the microphone selected before connecting, unless you changed Phone's microphone during the call. It does not hang up.

Automatic microphone selection uses the public Accessibility API and requires Accessibility access for Phone Assistant. It does not use AppleScript or request Apple Events Automation access. The app operates only the Microphone section of Phone's Audio menu and leaves output and macOS default devices unchanged. The current selector recognizes the English Phone menu. See [automatic Phone microphone](automatic-phone-microphone.md) for lifecycle and verification details.

## Phone in Advanced audio test

The existing Application dropdown includes **Phone**. Selecting it retains the test's microphone, listening output, and microphone opt-in. Start requires an active Phone call and automatically selects Phone Assistant as Phone's microphone. Phone's output must remain physical, selected directly or through Use System Setting. It does not dial or connect GPT-Live.

This selection reuses the production Phone capture engine because Phone's shared renderer is not part of its ordinary application process tree. Caller audio has its own capture/listening path and cannot enter the outgoing mix. Only the enabled microphone can reach the caller. The existing listening toggle becomes Hear caller, and the source volume controls caller listening. Mute caller sending leaves listening unchanged. Stop, leaving the test screen, and Quit release both test engines and restore ordinary playback. The Chrome preset remains available.

Local checks cover saved selections, microphone opt-in, isolated production mixer routes, caller-send mute, cancelled startup, and existing Chrome behavior. Twenty-two focused tests passed for the source selector and route validation. A successful caller-hears-microphone test still needs a remote listener.

### Diagnosing outgoing cutouts

The **Let Phone handle caller playback** switch is a controlled comparison in Advanced, available only with Phone selected and while the test is stopped. It leaves Phone's original playback unmuted and opens no app listening output. Microphone forwarding, gain, virtual input selection checks, and caller capture stay the same. Saved microphone/listening choices are preserved, and the option defaults off for existing installations. While it is on, Phone controls listening output/volume and the app's listening controls are disabled. This is a diagnostic option, not a verified fix for remote cutouts.

Phone tests now show actual post-mix callback peak/RMS and route-specific microphone underruns. Disabled agent routes and caller mute do not create false microphone-underrun counts. Microphone/caller meters accumulate over the full reporting interval. Callback telemetry is preallocated and bounded; incomplete telemetry is flagged. These local measurements still do not prove remote intelligibility.

The app keeps only the latest Phone test's last 150 scalar samples and 20 status events in `~/Library/Application Support/CodexCall/Diagnostics/latest-phone-test.json`, with owner-only file permissions. It records startup settings, changes to gains/mute/devices, stop/failure, worker observation times, capture frames, and output levels. It saves no audio, transcript, telephone number, or API key. Disk writes occur on a separate queue; a write failure does not stop audio. Copy test diagnostics exports this same report. The command below reads it without starting audio:

```sh
dist/CallMenu.app/Contents/MacOS/CallMenu --phone-test-report
```

`--observe-phone-input` now measures about ten seconds of virtual input in roughly 200 ms windows, including hardware input/output gain and mute snapshots. It does not generate sound or save/forward audio. Zero delivered frames have null peak/RMS; actual silent frames have measured zero levels. It reports capture format stability and observer backlog/dropped frames. InputIO downmixes and sanitizes samples, so the observer is not a bit-exact multichannel recording. Receipt-time windows are asynchronous to the app's meter windows; a peak ratio alone is not a precise attenuation measurement.

Both the earlier tone test and these local diagnostics can pass while Phone's downstream processing changes remote audio. Before claiming a cutout fix, repeat the same call configuration with a remote listener and correlate the report with readback during the fade.

## Connection and isolation

The native adapter uses the installed OpenAI Live protocol, PCM16 mono at 24 kHz, gpt-live-1, and Marin. It applies assistant identity/introduction/style/pace and the task at session creation. Responses delegation uses gpt-6-sol at low reasoning effort (override with `DELEGATE_MODEL` and `DELEGATE_REASONING_EFFORT`). Its only tools are `ask_codex` and `report_call_result`, both bound to the originating Codex task.

An API key entered in Settings → Connections is stored as one item in your login keychain; other apps must ask your permission to read it. It is never written into preferences, logs, the app bundle, or a credential file. The WebSocket uses an ephemeral URLSession with caches, cookies, and credential storage disabled. Authorized development launches can load an existing project key into the child app's environment without copying it. The app does not silently search for project credential files. A key from the environment is used for that launch only and is not saved.

The worker emits only authorized caller/microphone samples. Output-only model operation sends silence as the protocol clock. Native caller and monitor mixers remain separate. Caller mute closes only outgoing telephone audio, so local listening can continue. It does not hide authorized user speech from the model.

Changing model input authorization or speaking participation immediately closes all routes, retires the provider, flushes pending speech, and creates a new epoch/session. Late output/failure callbacks are ignored. Public context is carried as an explicitly labeled, bounded in-memory transcript, not hidden model state. This context is never written to disk; [call history](call-history.md) saves its own transcript according to the user's History settings. Pure local-listening changes keep the provider session alive.

Microphone permission is requested only for speaking participation. Provider startup must succeed before caller sending opens. Runtime faults, lost Phone input, closed transport, stalled sends, and bounded-buffer overflow stop the bridge and restore Phone's ordinary playback. Disconnect and Quit cancel delivery before device cleanup; cleanup failures remain visible and prevent claiming success.

## Verification and limits

The September 20, 2026 checks covered all nine participant combinations through the phone, monitor, and model mixers. A native provider connection returned 4,800 bytes of generated PCM without microphone capture, Phone capture, physical playback, or a call. Recorded UI checks covered setup, selector changes, rejection without an active call, and idle Quit. These results do not establish active-call shutdown or remote speech quality.

During an operator-led call that day, a three-second virtual-input read measured 143,424 frames, peak 0.00710, and RMS 0.001066. No audio was saved. This establishes a nonzero local signal, not intelligibility at the remote endpoint. The app meter and readback were not synchronized, so they do not establish an attenuation ratio.

Normal calls follow macOS device choices separately from Advanced test overrides. Input validation removes output-only devices from the candidate set, then rejects wrong, inactive, or ambiguous microphones. A route with only the virtual microphone as an output is rejected. A user-speaking route requires an available physical microphone. Some duplex output devices still need compatibility testing.

Private asides and local ringing remain unimplemented. Codex task delivery is described in [Codex connection](codex-connection.md). Remote delivery, echo behavior, long-call clock stability, device handoffs, clean-Mac setup, and distribution still need qualification on real calls; see the [call test procedure](phone-audio-test-plan.md).

## Developer diagnostics

- `--check-phone-output` writes a private 997 Hz signal into the virtual microphone and reads it back. It refuses active Phone or FaceTime audio.
- `--check-call-capture` checks the synthetic source through the production muted process tap and reports format changes. It also refuses active calls.
- `--observe-phone-input` reads the virtual input for three seconds and reports peak, RMS, and frame counts. It does not save or forward audio, generate sound, change selections, or install components.

Run these flags with the executable in the signed app bundle. Diagnostics release owned I/O when they finish. Their scalar output is a local signal check, not proof of remote delivery.
