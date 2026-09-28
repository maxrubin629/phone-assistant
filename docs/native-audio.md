# Native audio controls

The app connects an existing Phone call to GPT-Live, the user's microphone, and a selected listening output. It does not dial or hang up Phone. Disconnect stops the app's audio and voice session while the carrier call remains connected.

## Connect a call

1. Complete Audio setup and enable Phone Assistant Audio Bridge and System Audio Access.
2. Grant Accessibility access for Phone microphone selection. Grant Microphone Access if you want to speak through the bridge.
3. Add an API key in Settings → Connections for modes that use the assistant.
4. Start or answer a call in Phone, then connect the prepared session.
5. Choose Listen, Join, Take over, or Assistant only in the notch controls.

The bridge selects Phone Assistant as Phone's microphone and verifies the active input route before it opens audio. Stop restores the previous selection unless the user changed it. Phone's output must remain a physical listening device.

## Levels and diagnostic routing

Live audio controls adjust gain and mute for each permitted route. They cannot enable a destination excluded by the participation controls. Caller mute leaves local listening unchanged.

Settings → Advanced provides application capture and the Phone microphone test. The Chrome + microphone preset uses 315% application gain and 53% microphone gain. These diagnostic settings are separate from the normal Phone bridge. Leaving the test or closing Settings stops its route.

Automatic device selection follows macOS without changing system defaults. A missing automatic endpoint pauses and retries; a missing fixed endpoint stops the route. See [automatic devices](automatic-devices.md).

## Limits

A connected state or moving meter does not prove that the remote caller hears intelligible speech. Use the [call test procedure](phone-audio-test-plan.md) to qualify delivery, interruption, mute, and cleanup. See [the Phone bridge](phone-bridge.md) for routing and [installation](phone-kit-installation.md) for setup and upgrade behavior.
