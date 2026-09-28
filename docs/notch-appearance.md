# Notch appearance and layout

The expanded widget is 500 points wide, with a 140-point minimum height on a
32-point hardware notch. Task information and the three mode buttons share a
row. Long titles wrap to two lines; questions add height when needed. Active
call controls use two footer rows so their labels stay readable. A narrow
display can use the vertical fallback. Actions, including Add API key, use
interactive Liquid Glass capsules. A black gradient overlays regular, frosted Liquid Glass below the content, fading from opaque
black at the top to 10% black at the bottom. The shape continues behind the
physical camera housing without a drawn cutout. Keeping this layer above the
glass preserves the fade
instead of letting the adaptive glass material soften it.

## Persistent active appearance

The nonactivating panel retains its active material appearance while another
app receives input.

CallNotchPanel implements three undocumented Objective-C appearance queries:
_hasActiveAppearance, _hasActiveAppearanceIgnoringKeyFocus, and hasKeyAppearance.
They return true only for this panel. No global method replacement is used.
The implementation does not override isKeyWindow, force application activation,
or acquire keyboard focus to retain the material.

This is a compatibility and distribution limitation, not a supported Apple API
contract. Recheck these hooks for each supported macOS version. Do not present
this implementation as ready for Mac App Store submission without replacing
the private API dependency.

## Local verification

- The isolated NSPanel rendering test retained its glass reflections after
  explicitly releasing key status and deactivating the application. Its state
  readout reported applicationActive=false and windowKey=false while another
  application was foreground.
- The delivered app was built, signed, reopened, and visually checked with its
  idle state. The Add API key control and compact mode capsules rendered as glass.
- Static previews checked long task titles, an active-call layout, and an
  assistant question. These validate layout, not live call delivery or the
  backdrop optics of a WindowServer desktop capture.
- Existing geometry checks passed for hardware attachment, centered camera spacing,
  height measurement, external displays, and narrow-display bounds.
- No audio call was connected for this UI work. No audio driver or route changed.

## Opening and closing motion

Expanded controls remain mounted at their final width and height while hidden.
This moves initial glass creation and height measurement out of each expansion
and avoids text reflow as the window grows. Hidden controls are excluded from
hit testing and accessibility. The waveform timeline updates only the
waveform instead of the whole widget.

The gradient stays at the full expanded height, anchored to the top and clipped
by the animated shell. Its fade retains the same screen coordinates as the window closes.
The fade uses fixed canvas coordinates and full layer opacity; only its
per-position gradient alpha varies. Explicit frame updates and layout resize
the window without scaling its rendered content.
The window and shell share an easing curve that starts at rest. Opening takes
0.24 seconds and closing takes 0.24 seconds. A click that pins an in-progress
hover opening leaves that animation running instead of snapping to its target.
The frame-animation state also ignores completion callbacks from superseded
transitions.

The arm64 build, geometry checks, and CallNotchTransitionChecks passed. Local
UI checks covered repeated opening, Escape closing, compact accessibility, and
unchanged expanded layout. Static previews covered compact activity, long task
titles, and questions. These checks do not measure GPU frame times or prove
that every display configuration is free of hitches.

Run the focused regression check from the project root:

```sh
swiftc native/Sources/CallMenu/App/CallNotchTransition.swift native/Tests/CallNotchTransitionChecks/main.swift -o /private/tmp/codex-notch-transition-check
/private/tmp/codex-notch-transition-check
```
