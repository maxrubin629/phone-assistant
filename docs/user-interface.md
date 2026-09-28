# Call interface

The primary interface is a compact notch control. Click or hover to expand it. Tasks arrive from Codex through the bundled MCP executable. See [Codex connection](codex-connection.md). After setup, the app window shows [call history](call-history.md): results, Codex questions and answers, and transcripts. The notch transcript button and menu-bar Call history open it on the live or latest call.

The widget has Listen, Join, Take over, Assistant only, mute-to-caller and disconnect-audio controls. It distinguishes the user's microphone sent to the caller from the microphone sent to the assistant. Long content scrolls above a fixed footer. Hiding or collapsing never disconnects audio. The black panel meets the physical screen edge on a notched display. Compact controls sit beside the camera; expanded content stays below it. On screens without a notch it stays at top center below the menu bar.

macOS 26 uses system Liquid Glass for the mode controls within a black notch shell. Earlier supported versions use native material; Reduce Transparency uses an opaque adaptive background. Detailed routing, levels, device overrides and processing remain in Advanced audio. Settings contains Assistant (identity, voice and opening line), Connections (API key and Codex), History, Audio and Troubleshooting (audio test and Live Audio Controls). Each pane is a native grouped form that follows the system accent color. The app window (onboarding, then call history titled Calls) follows the system appearance and uses standard controls, with per-call commands as toolbar symbols. Only the notch keeps its own dark glass look. Custom speaker/listener combinations are in Live Audio Controls → Routing, opened from Settings → Troubleshooting.

Collapsed geometry follows the measured camera housing, with side controls when needed. The expanded panel is 500 points wide and measures its content up to 420 points tall. Both states remain attached to the physical top edge on a notched display. Expansion respects Reduce Motion. Add key opens Settings → Connections; Set up opens Settings → Audio. These navigation actions do not connect audio.

| Mode | Caller hears | Caller is heard by |
|---|---|---|
| Assistant | Assistant | Assistant |
| Listen | Assistant | Assistant and user |
| Join | Assistant and user | Assistant and user |
| Take over | User | Assistant and user |
| Just me | User | User |

These presets use the existing routing implementation. Take over blocks assistant audio in the mixer. Listening does not enable the microphone. Custom combinations remain accessible in Advanced without being silently converted to a preset.

Start or answer a call in Phone. A call Codex prepared connects automatically when it starts (Settings → Connections); otherwise connect audio from the notch. With Accessibility access enabled in Settings → Audio, Phone Assistant selects Phone's microphone automatically. Disconnect restores the previous choice unless the user changed it. The app does not dial or hang up Phone.

The API key entry is available from the notch (Add API key) and Settings. The key is stored in the login Keychain on this Mac and can be removed in Settings. Just me remains available without a key. During an active call, key replacement requires disconnecting audio.

To review the design without a call, `CallMenu --notch-preview <dir>` renders the notch and `CallMenu --window-preview <dir>` renders every window, in light and dark.
