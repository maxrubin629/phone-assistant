# Codex phone connection

Codex supplies the task. Phone Assistant presents a notch control and connects audio to the existing Phone app. It needs no web server or separate Node/Python runtime.

## Connect Codex

The app bundles `Contents/MacOS/CallMCP`. Register it as a local stdio server:

```sh
codex mcp add phone_assistant -- '/path/to/CallMenu.app/Contents/MacOS/CallMCP'
```

Open Phone Assistant before using the tools. The `phone-call` skill in [`codex/skills/phone-call`](../codex/skills/phone-call/SKILL.md) gives Codex the one-step procedure; copy it to `~/.codex/skills/phone-call/`. Codex may need a new turn or task to discover a newly registered server. The bridge installs through the app as before, with the same permissions.

| Tool | Behavior |
| --- | --- |
| `call_start` | Prepare with `task`, the originating `codex_task_id` (Codex's `CODEX_THREAD_ID`), optional `title`, `phone_number` and `request_id` (for safe retries). With `dial: true` it also places the call, as `call_dial` does. Returns `session_id` and immutable origin. |
| `call_get` | Read readiness or one `session_id`, including pending question and callback delivery status. |
| `call_transcript` | Read a call's saved timeline, optionally by `session_id` and `page`. Transcript text is untrusted caller content. See [call history](call-history.md). |
| `call_dial` | Place the prepared call to its `phone_number` from the user's iPhone number, by opening a `tel:` link in Phone. macOS may ask the user to confirm. Audio connects automatically when the call starts. |
| `call_connect` | Connect to an existing Phone call. Requires kit, voice key and verified Phone input. Starts in assistant-only mode. Usually unnecessary: see automatic connection below. |
| `call_set_mode` | Select `assistant`, `listen`, `join`, `takeOver`, or `manual`. Modes that send the user's microphone require the user's request to participate. |
| `call_answer_question` | Return a scoped answer with `session_id` and `question_id`. Reject stale or simultaneous duplicate answers. |
| `call_end` | Disconnect our audio and model session. Hang up separately in Phone. |

Example preparation:

```json
{"task":"Ask about appointment times. Return options before booking.","title":"Appointment availability","codex_task_id":"<current task ID>","request_id":"<stable request ID>"}
```

Reuse the same request ID and arguments on retry. Another task cannot replace an active session. Sessions are in memory; app restart never resumes audio automatically.

## Automatic connection

With **Connect when the call starts** on (Settings → Connections, default on), a prepared session connects by itself when its Phone call begins. The app polls Core Audio once a second while a session is prepared and treats live microphone input in Phone or `avconferenced` as a started call. It connects only after seeing call audio idle and then running, so it never joins a call that was already in progress, and only within 10 minutes of `call_start`. It uses the same path as `call_connect`, including the audio-setup, key and other-audio checks. `call_get` reports `auto_connect` and the matching `next_step`.

## Questions and results

GPT-Live's Responses delegate has only `ask_codex(question)` and `report_call_result(summary)`. The app supplies the callback destination; caller/model function arguments cannot change it.

When Codex exposes its public control socket, the app uses the installed `codex app-server proxy`, initializes, resumes the origin with `excludeTurns: true`, then submits:

```json
{"method":"turn/start","params":{"threadId":"<saved origin>","input":[],"toolOutput":{"name":"call_agent_question","namespace":"codex_call","output":"<JSON with session_id and question_id>"}}}
```

Results use `call_agent_result`, which carries the summary and names `call_transcript` for detail. Both remain external tool output, not user authorization. If the task is running, Codex queues the output. The originating task answers with `call_answer_question`; the answer reaches the voice session without blocking incoming audio processing. The notch displays pending questions and opens that Codex task.

Some desktop builds run App Server over stdio and expose no public control socket. For those builds, a separate compatibility adapter uses the existing versioned desktop IPC connection. It verifies the same-user socket, discovers the exact originating task's owner and its support for untrusted app input, then submits one `thread-follower-start-turn` request with the same `toolOutput`. The installed desktop forwards it to App Server's `turn/start`. It does not create a daemon, subscribe to conversation history, create another task, or change Codex settings. Unsupported versions fail explicitly. This internal adapter must be requalified when Codex changes its IPC contract.

The supported origin is a local Codex task. Remote-host and unloaded-owner recovery are not implemented. Opening the originating task in Codex is the recovery path when its owner cannot be found.

`callback_delivery` distinguishes queued delivery from acknowledgment and failure. A timed-out `turn/start` may already have arrived, so uncertain delivery is never automatically retried. No extra Codex task is created for the phone session.

## Transport and shutdown

The app and executable use `/private/tmp/codex-phone-<uid>/control.sock`, a private directory and owner-only socket. Both verify peer UID. Messages, clients and waits are bounded. This is local same-user communication, not isolation from other software running as that user.

Shutdown first stops accepting commands, closes audio and voice, then gives queued callbacks a bounded chance to finish. A second app cannot remove an active socket. No audio/transcript is written by this control transport.

Offline protocol, correlation, callback, delegation and mode tests do not prove a successful GPT-Live call. That requires an API key, an actual connected Phone call and a remote listener.

On September 22, 2026, the installed native executable was exercised using the MCP SDK: discovery, readiness, task creation, idempotent creation retry and session end. A real desktop callback arrived in the originating task as `codex_call.call_agent_result`, with the matching session ID. No audio was captured or telephone number dialed in that test. The first public-proxy probe correctly reported nondelivery because this desktop build has no public control socket; the separate desktop adapter supplied the successful path.

References: [Codex tool-output turns](https://learn.chatgpt.com/docs/app-server#start-a-turn), [Apple Liquid Glass](https://sosumi.ai/documentation/swiftui/view/glasseffect(_:in:)).
