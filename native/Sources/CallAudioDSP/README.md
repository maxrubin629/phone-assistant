# Callback DSP and transport

This C11 target provides callback-safe queues, routing controls, and mixing. It
depends on the C runtime and is usable from Swift through `CallAudioDSP.h`.

`CABRing` carries mono float PCM between one producer and one consumer. Allocate
the ring and callback scratch buffers before starting audio. Each endpoint owns
its index; the control thread changes only an atomic generation. Slots retain
the generation under which they were written. A consumer drops obsolete slots
and zero-fills missing output. A producer never overwrites unread data: overload
drops the incoming tail and increments `overflow_frames`.

Changing generations does not immediately free queued capacity. The consumer
drains obsolete samples on its next read. Keep consumers reading even when a
route is muted. This preserves single-writer ownership of the two indices and
avoids races caused by resetting a running queue. Never reuse a generation value
during the lifetime of a ring. Read and write calls use a finite snapshot of the
queue; work is bounded by requested frames and ring capacity.

Callbacks must remain the sole endpoint for each ring. Two outputs require two
rings, even when they receive identical samples. Stop both endpoints before
destroying a ring. Snapshot counters are independent atomic reads, so a snapshot
is diagnostic rather than a transaction. `stale_frames` includes samples
discarded when a generation change invalidates a read; generation rejection and
underrun counters describe separate failure conditions.

`CABControls` stores six route flags and independently atomic gains. Each gain
is constrained to 0–4; non-finite or negative input becomes zero. Start with all
routes disabled, set gains, and then enable the intended routes. All PCM is
sanitized and clipped to finite values in `[-1, 1]`. This is defensive clipping,
not a dynamics processor.

Controls begin enabled at revision 1, with phone transmission muted. Send mute
masks both microphone-to-caller and agent-to-caller while preserving the stored
route matrix. Disabling controls masks every route. `cab_controls_cancel`
atomically disables routes and increments a revision in one operation, so an
emergency-stop handler can silence future callback snapshots without waiting
for device teardown. An already executing callback may finish its current
buffer. Async startup captures the revision before queuing work and finishes
with `cab_controls_enable_if_revision`; this prevents a cancelled startup from
enabling routes after the cancellation. Unconditional `set_enabled(true)` is
for controlled lifecycle operations, not completion of asynchronous startup.

The phone mixer accepts microphone and public agent speech. The separate local
monitor mixer accepts caller, public agent speech, and owner-only agent speech.
Owner-only speech has no argument in the phone mixer. Each route must also be
gated at ingress and invalidated when changing mode; the mixer is the final
output gate, not the complete session policy.

Run the DSP checks from the project root:

```sh
sh native/Tests/CallAudioDSPChecks/run.sh
DSP_SANITIZER_FLAGS='-fsanitize=thread' sh native/Tests/CallAudioDSPChecks/run.sh
DSP_SANITIZER_FLAGS='-fsanitize=address,undefined' sh native/Tests/CallAudioDSPChecks/run.sh
```

The checks exercise exact queue boundaries, overflow and wraparound, concurrent
ordered transfer, generation changes racing both endpoints, finite sample and
gain handling, and separation of phone and local monitor routes. No test opens
an audio device or captures a microphone.
