# Call participation

The [native Phone bridge](phone-bridge.md) implements separate speaking and listening selectors. Private asides and local ringing remain unimplemented. Codex tasks and callbacks use the [native control interface](codex-connection.md). Local tests do not establish a successful remote call.

## User controls

| State | User hears | Caller hears | Model receives |
| --- | --- | --- | --- |
| Background, the default | Neither side | Assistant | Caller |
| Listen | Caller and assistant | Assistant | Caller |
| Take over | Caller | User | Caller and user; no spoken interjections |
| Join together | Caller and assistant | User and assistant | Caller and user |
| Private aside | Private assistant replies | Neither private participant | User privately, with permitted call context |

Listen is a local playback control, not a new model session. User microphone capture is off in Background and Listen. Take over gives the user exclusive speaking access to the outgoing call while preserving model understanding. Join together lets the model participate, with instructions to yield when the user speaks. Neither participation mode plays the user's own microphone back to them.

The ordinary UI provides Listen, Take over, Join together, and Private aside, plus a way to return to the assistant handling the call. Devices remain automatic in the eventual consumer workflow. Physical device selection and implementation diagnostics stay in Advanced. Use the Mac's current physical output for listening and alerts. Automatic continuously follows macOS selections, including a macOS fallback to speakers after headphones disconnect. An explicit device override remains fixed. Automatic switching does not ask for confirmation, following the subsequent user clarification.

## Speaking control

An instruction such as "The user is speaking on the call. Listen, but do not speak until released" communicates the mode to the model. A native audio gate enforces it. Take over closes assistant delivery immediately, cancels pending generation where supported, clears pending speech, and rejects delayed output from the previous delivery state. User audio opens only after that transition. Model compliance is not the mute mechanism.

Returning control explicitly re-enables assistant delivery. Speech generated while muted must never accumulate for playback after resuming. Mode changes must retain the public conversation context when permitted. The native bridge retains a bounded in-memory transcript of permitted public audio for replacement sessions. This is text continuity, not preservation of hidden model state or guaranteed speaker attribution.

Track caller and user as separate audio sources. If the model transport requires mixed input, do not pretend that its source labels provide verified speaker attribution. Validate that capability at the provider boundary before promising that the model can always distinguish the two speakers. Incoming caller speech is not authorized to change modes or select an audience.

## Asking for help

For task knowledge or reasoning, the assistant asks the originating Codex task through its bound return address. Requests and replies must remain tied to the active call; late answers from a retired call must not reach a replacement call. A remote caller cannot redirect this connection.

When human participation is necessary, the app shows an incoming-call-style request with a short reason and an app-owned ringtone. This is a local alert, not another telephone call. It must not enter the caller's audio mix. Accepting opens the requested participation path; the request itself never opens the user's microphone. Dismissal leaves the microphone closed and follows the task's waiting or cancellation policy. App-owned alerts fit the permission baseline; system notification permission is not silently added to setup.

The user's credit-card example needs a distinction: ordinary Take over intentionally lets the model listen. A recommended additional option, "Keep AI out of this part", would also close both call-to-model and user-to-model paths, pause transcription/recording/forwarding, and discard queued sensitive audio. Only the user and remote caller would receive that segment. Resumption would carry an outcome such as "payment completed", not the private numbers. This privacy option is a recommendation, not an implemented capability or an assumption that ordinary Take over is private from AI.

## Private aside

An aside is useful for "What happened so far?", "What are my options?", and instructions the user wants to discuss before returning to the call. The private conversation gets an authorized summary of the public call so far. The caller never receives the user's private microphone audio or the assistant's private replies.

Before entering, the assistant can tell the caller that it needs a moment. The public conversation is paused; no carrier-level hold feature is assumed. Caller speech may continue, but it must not be mixed into the private conversation without an explicit design for that behavior. On return, pending private audio is discarded before reopening caller delivery. Private history is not copied wholesale into the public session. Only facts or instructions the user chooses to share may cross back, subject to the existing call authorization.

## Existing implementation and gaps

The primary native bridge starts with GPT-Live selected for both directions, physical listening off, and microphone capture closed. Caller hears Me with Caller is heard by Both implements takeover with a listening but audibly blocked model. Both/Both permits joint participation. Me/Me closes the provider session, removes all caller/microphone-to-model routes, and retains no transcript of that segment. Adding local listening while keeping the model's inputs unchanged preserves the provider session.

A change in model input authorization or speaking participation closes delivery immediately, flushes queues, replaces the provider session, and assigns a fresh audio epoch. Late callbacks cannot reach the new route. The model also receives a speaking instruction. The native gate enforces the choice even if the model ignores it.

Private aside and local ringing aren't implemented. Delegation to the originating Codex task is: see [Codex connection](codex-connection.md).

Verification must include an actual call with a remote listener, takeover during speech, preserved context, device handoffs, and shutdown. Deterministic mixer/transport tests and real API-generated PCM have passed; they do not establish telephone delivery.
