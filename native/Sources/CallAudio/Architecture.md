# Native CallAudio runtime

This library routes an existing Phone call through Core Audio.
It does not dial, answer, infer call state, install a driver, or change default
devices. An explicit virtual device must
already exist and Phone must use its input.

## Routes

`PhoneRouting` selects the speaking and listening participants independently.
Its default sends agent speech to the caller and caller audio to the agent,
without opening the physical microphone or local listening output. Selecting
`user` as speaker and `both` as listener lets the owner speak while the agent
continues listening. See [PhoneRouting.swift](PhoneRouting.swift) for the route
mapping.

The table below describes the older `CallAudioMode` routes, which the
library still defines for `CallAudioConfiguration.mode`. They differ from
`PhoneRouting`, particularly for background operation and takeover.

| Mode | Mic → caller | Agent → caller | Caller → model | Mic → model | Caller → user | Agent → user |
|---|---:|---:|---:|---:|---:|---:|
| agent | off | on | on | off | on | optional |
| join | on | on | on | on | on | optional |
| takeOver | on | off | off | off | on | off |
| privateAside | off | off | off | on | on | on |

Microphone routes also require explicit microphone opt-in. The Phone send gate
starts closed and opens only when the controller acknowledges audio readiness.
Private owner responses have a separate ring that the Phone mixer cannot read.
Caller listening can be disabled independently of caller-to-model capture.

## Ownership and threading

`CallAudioRuntime` serializes lifecycle and conversion on one worker. Start,
stop, preflight, and normal controls must be called off the UI thread; Core Audio
can block. `setSendMuted` closes an atomic gate immediately and asynchronously
flushes before applying the latest unmute intent. `stopAsync` immediately
disables routes and cancels pending startup before scheduling cleanup.

Capture `lifecycleRevision` when a start is requested, before queuing it, and
pass it to `start(...expectedLifecycleRevision:)`. A cancelled queued start
cannot enable audio later. Use `stopAndReport()` to show cleanup failures.
All callbacks run on the worker. They must enqueue network/UI work without
blocking; the model handler is not an audio callback.

Core Audio callbacks only traverse buffer lists, downmix or duplicate channels,
mix finite samples, and use preallocated C rings. They do not allocate, lock,
convert sample rates, call the network, or update UI. Rings use single-producer,
single-consumer ownership and atomically tagged generations. A generation
change does not edit either endpoint's indices. Audio already handed to the
hardware may finish its current buffer when a control changes.

The caller tap is a private mono tap-only aggregate: it contains no microphone
subdevice. Exactly one active Phone/avconferenced renderer is required, Phone
must be running, and an open FaceTime app blocks capture. There is no all-system
fallback. The default managed listening path uses `mutedWhenTapped` and a
separate physical monitor. This avoids duplicate caller play-through. Destroying
the owned tap restores Phone's normal output. An optional external listening
configuration leaves Phone unmuted and does not claim to control its volume.

Device UIDs are explicit. The public virtual microphone and hidden output feed
use stereo Float32 at 48 kHz. The runtime verifies the public input and writes
through the feed. Microphone and monitor devices must be
physical. Sample-rate conversion runs on the worker with stateful
`AVAudioConverter`; model transport is PCM16 mono at 24 kHz. Model packets carry
an epoch and monotonically increasing sample position. Incoming speech carries
the same epoch and a strictly increasing sequence. Mode changes require a new
epoch; old audio is flushed before a new audience can receive it.

Every queue is bounded to 48,000 or 24,000 frames. Any overflow fails closed;
live capture backlog or worker delays above 500 ms also stop the route. Empty
reads yield silence. Device disappearance, format changes, changed caller
attribution, and capture stalls stop all owned routes. Cleanup attempts every
endpoint and both aggregate/tap resources even if one operation fails. Failed
callback owners retain their buffers and controls so cleanup failure cannot
free memory that HAL still accesses.

## Verification and remaining qualification

`swift test --package-path native --filter RuntimeContractsTests` exercises
attribution, all modes, participant isolation through an injected model sink,
epoch/sequence rejection, cancelled startup, invalid configurations without
opening devices, PCM constraints, overflow/staleness faults, and stateful
conversion. `native/Tests/CallAudioDSPChecks/run.sh` exercises ring ordering,
concurrent generation changes, lifecycle cancellation, mixing and clipping.
Its sanitizer modes are documented beside that script.

The implementation was compiled and tested without opening a microphone,
capturing a call, installing a driver, or changing the user's audio setup.
An existing active Phone call is required for first connection; prepared output
is not reported as caller capture readiness. Actual tap-only aggregate startup,
Phone input recognition, physical monitoring, permission prompts, device loss,
and extended-call behavior still require an explicit hardware test.

Separate input/output clocks are not yet adaptively drift-corrected. The runtime
converts nominal sample rates and stops if buffering becomes stale or overflows.
This is bounded failure behavior, not a claim of qualified long-call drift
compensation. HAL calls run off the UI thread but are not hosted in a killable
helper process; a blocked teardown can leave cleanup pending, which the UI must
report rather than claiming disconnection is verified.
