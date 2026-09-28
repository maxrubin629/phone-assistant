# Verify a Phone call

This procedure checks the complete path from Phone Assistant to a remote listener and back. Local meters and virtual-input readback establish only their own part of that path.

## Prepare

Complete setup, confirm the bridge is ready, and grant the permissions needed for the chosen mode. Use a separate receiving device and a listener who can report the words actually heard. Use headphones for the first duplex test. Keep the microphone, listening output, Phone output, and source levels fixed during each comparison.

The app does not dial or hang up Phone. Disconnecting AI audio leaves the carrier call connected.

## Test delivery

1. Start or answer the Phone call and confirm that ordinary speech reaches the listener before connecting the bridge.
2. Connect the prepared session. Confirm that Phone uses Phone Assistant as its microphone and a physical device as its output.
3. Test the user's microphone with the Just me mode at 100% software gain. Ask the listener to report clarity, level, and missing words.
4. Test assistant speech with a short known phrase and a silent gap. Confirm the physical microphone cannot explain the received phrase.
5. Complete at least two conversational exchanges. Confirm that the assistant hears the caller without receiving its own outgoing speech as caller input.

Do not infer success from a connected timer, provider connection, or moving meter. If a prerequisite fails, stop that comparison and record the failure.

## Test controls and cleanup

- Listen adds local playback without enabling the microphone.
- Join sends both permitted speakers. Take over blocks assistant speech while the assistant continues listening.
- Caller mute stops outgoing audio without changing permitted local listening.
- Participation changes and interruption must not release stale queued speech to a new audience.
- Disconnect stops app-owned audio and restores Phone's previous microphone unless the user changed it. End the carrier call separately in Phone.

Verify device-loss handling, API disconnection, and active-call Quit in separate controlled tests. A cleanup-pending state must not be recorded as verified disconnection.

## Record and diagnose

Record the OS build, device UIDs, participation mode, source level, Phone selections, listener observations, and cleanup result. The bridge's scalar report is available through `CallMenu --phone-bridge-report`; Advanced uses `--phone-test-report`. These reports contain levels and lifecycle events, not audio or transcripts.

| Observation | Next check |
| --- | --- |
| Ordinary speech fails before bridge connection | Resolve the receiver or native Phone route. |
| App meter moves but virtual-input readback is absent or degraded | Inspect the local mixer, device gain, and virtual transport. |
| Virtual-input readback is healthy but remote speech fails | Inspect Phone selection, processing, and the downstream call path. |
| Incoming caller capture is silent | Check scoped renderer attribution and the selected input route. |
| Unexpected microphone or output appears | Stop and verify the route before another transmission test. |

`--observe-phone-input` reports a three-second virtual-input level sample without saving or forwarding audio. `--check-phone-output` and `--check-call-capture` inject a synthetic signal and refuse active calls. See [bridge diagnostics](phone-bridge.md) for their scope.

Accept delivery only when the listener identifies the phrases, silence and controls work, microphone fallback cannot explain the result, and a repeated connection gives the same result. Device compatibility, long calls, and clean-Mac setup require separate qualification.
