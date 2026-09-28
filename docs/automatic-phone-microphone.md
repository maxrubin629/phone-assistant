# Automatic Phone microphone

Connecting the main Phone bridge or starting the Phone diagnostic test now selects **Phone Assistant** in Apple's Phone app. The user grants Phone Assistant Accessibility access once in Audio setup. The app opens the permission settings when a connection cannot proceed without it.

`CallAutomation` owns the Accessibility menu adapter and a shared selection lease. It identifies Phone by `com.apple.mobilephone` and the Audio menu by `com.apple.facetime.menu.video`. On macOS 27, this menu has a flat Microphone section followed by an Output section. Only the microphone entries are eligible. The adapter reads `AXMenuItemMarkChar` and verifies the checked entry after selection. Unknown structure, ambiguous choices, missing permission, and unreadable checkmarks stop the connection.

After the menu is verified, the existing audio runtime checks the actual Phone helper's input device. Startup allows one second for that route to settle, checking cancellation between attempts. No outgoing or captured audio starts until the route is accepted. Ongoing route validation remains enabled.

The lease records the prior checked entry before sending AXPress. Failed startup, Stop, and orderly Quit stop owned audio before restoring that choice. Cancellation drains the pending menu operation before restoration. If the user selected another microphone, cleanup preserves it. If Phone Assistant was already selected before connecting, it remains selected. Missing prior devices or failed restoration leave cleanup pending for retry. Two app connections cannot acquire the selection simultaneously.

The implementation leaves Phone's Output selection and macOS default devices unchanged. It temporarily activates Phone to operate its menu and returns focus if Phone still owns focus afterward. English menu headings are currently required. Force-quit and process crashes do not run restoration; recovery is held in memory for the lifetime of the app.

## Verification

- Live UI inspection confirmed the Phone Audio menu's stable identifier, flat microphone/output sections, and Phone Assistant entry on macOS 27.
- Eight tests cover selection/restoration, preserving user changes, an already-selected virtual microphone, rejected selection, an AX failure after mutation, a missing previous device with retry, competing owners, cancellation during verification, and unavailable permission/menu recovery.
- The complete native test script passed, including audio route, DSP, and transport checks. The application built and its staged signatures passed verification.
- The rebuilt Audio setup UI exposes Automatic Phone microphone and Allow Phone control. After granting the authorized permission, the app recognized it as Ready. On macOS 27, this permission is named Device Control and Data Access and the app appears as CallMenu.
- A live round trip through the production Accessibility adapter passed on September 23: `Use System Setting` → `Phone Assistant` → `Use System Setting`. The adapter checked the actual menu mark after each change. No call was placed and no audio was captured or played. Evidence: `artifacts/phone-microphone-automation-2026-09-23/selection-check.json`.
- Debug builds support `open -n dist/CallMenu.app --args --check-phone-selection /absolute/path/report.json`. This runs the same selection/restoration service in a separate diagnostic app process, writes the three verified microphone choices, and exits without initializing the call bridge or MCP server. Run only while no call/audio connection is active. This verifies menu control; active call routing and remote intelligibility require a separate call test.
