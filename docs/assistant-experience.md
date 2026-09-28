# Assistant setup and everyday use

Phone Assistant uses a saved assistant profile and a compact notch control. Codex supplies the task through the bundled phone tools. Application capture and device overrides are available under Settings → Advanced for diagnostics.

## Setup

1. Enable Phone Assistant Audio Bridge and System Audio Access in Settings → Audio (the first onboarding step). Grant Accessibility access for automatic Phone microphone selection. Microphone Access is needed when the user joins the call.
2. Choose an assistant name, an optional owner name, voice style, and speaking pace.
3. Choose an introduction: mention AI, introduce as the owner's assistant, wait to be asked, or use custom wording. Preview the wording before finishing.
4. Add an API key and connect Codex in Settings → Connections. The key is stored in the login Keychain on this Mac.

Introduction preferences control the opening wording. The assistant is instructed to answer honestly if asked whether it is AI and not to impersonate the owner. The native adapter uses Marin and sends the saved style and pace as session instructions. There is no provider voice selector or live voice preview.

Completed setup shows the notch widget. Start or answer a call in Phone before connecting the prepared session. The bridge selects Phone's microphone automatically with Accessibility access. Listen, Join, Take over, Assistant only, caller mute, and Disconnect control the permitted routes. See [the call interface](user-interface.md).

## Saved state

The assistant profile and interrupted setup step use `assistantExperience.v1` in the `com.codexcall.menu` UserDefaults domain. Diagnostic routing preferences use `audioRouting.v1` separately. History preferences use `callHistory.v1`; call records are separate files described in [call history](call-history.md). Preference changes apply at the next voice connection. The API key is stored in the login keychain; other apps must ask your permission to read it. An `OPENAI_API_KEY` environment variable is used as-is and never saved.

Opening the app or editing a profile does not start capture, install a component, or change system defaults. Leaving the Advanced test or closing Settings stops that diagnostic route. Quit stops owned audio and reports cleanup failures.

## Verification and limits

Preference tests cover first run, interrupted and completed setup, malformed saved data, introduction behavior, and isolation from audio-routing preferences. Recorded UI checks cover setup, settings, introduction preview, participant selection, rejection without an active call, and idle Quit.

Dialing and hangup remain manual. Private asides, local ringing for assistance, provider voice previews, a clean-Mac walkthrough, and a qualified remote call remain incomplete.
