# Call history

After setup, the Phone Assistant window shows call history. The sidebar groups calls by day (Today, Yesterday, weekday, then date), shows each call's result under its title, and searches titles, results and transcripts. With no calls yet, it shows an example request to give Codex. The notch still controls the live call. The window is for reading a call back, during or after it.

## What a call keeps

Each Codex phone session that carries audio becomes one record, keyed by its `session_id`:

- title, task, optional phone number, originating Codex task, start and end time
- outcome: Live, Ended, Failed, or Interrupted (the app quit or crashed during the call)
- the result from `report_call_result`
- a timeline: speech, questions the delegate sent Codex, Codex's answers, mode changes, and when the result was reported

Speech has two sources:

- **On-device, per source (macOS 26 and later).** The caller and the user's microphone are transcribed separately with Apple's `SpeechAnalyzer`, before they are mixed for the assistant, so each line is labeled by where its audio came from. The assistant's own words come from GPT-Live's output transcript. Only audio the assistant is authorized to hear in the current mode is transcribed: the microphone only in Join and Take over. Lines are final (never revised) and arrive a few seconds after they're spoken; they're placed by when they were said. Without headphones the microphone also hears the speakers, so a "You" line is dropped when most of its words match a caller or assistant line from the preceding 30 seconds.
- **Fallback.** Before macOS 26, for an unsupported language, or until the language's speech model is installed, lines come from GPT-Live's input transcript as before. A missing model is requested from the system in the background for later calls; it's shared by every app and not stored in this app.

| Label | Meaning |
| --- | --- |
| Assistant | What the assistant said. Speech that was blocked in Take over is not recorded. |
| Caller | The caller. |
| You | Your microphone, transcribed on its own (on-device mode). |
| Caller or you | Fallback only: your microphone was mixed into what the assistant heard, and the two can't be separated. |

"Just me" disconnects the assistant, so nothing is transcribed in that mode.

## Storage and retention

Each record is one owner-only (0600) JSON file in `~/Library/Application Support/com.codexcall.menu/Calls/` (directory 0700). File names are session UUIDs only. Writes are coalesced to one every two seconds during a call. Quit waits for the final write.

The last onboarding step says, before the first call, that calls are transcribed and kept on this Mac and for how long.

Settings → History:

- **Save call transcripts** (default on). When it is off, speech is not written to disk, and a live call's transcript is discarded when the call ends. The result, questions, answers and mode changes are kept either way; Codex already has them in its own task.
- **Keep calls for**: 30 days (default) or Forever. Expiry is measured from the call's end and checked at launch, hourly, and when the setting changes. A live call never expires.
- **Delete All Calls** removes every finished call. Individual calls can be deleted from the window. Deleting does not affect the result already delivered to Codex.

A record still marked Live at launch belonged to a run that did not finish it. It is marked Interrupted.

## Codex access

`call_agent_result` carries the summary and names `call_transcript` as the follow-up tool. Codex reads the transcript only when the summary is not enough:

```json
{"name": "call_transcript", "arguments": {"session_id": "<session>", "page": "2"}}
```

- With `session_id` omitted, it returns the current call or the most recent saved call.
- Pages are at most 24,000 characters, so a response fits the local control frame. The response includes `page` and `pages`.
- Each line has an offset from the call's start, such as `[1:05] Caller: …`.
- The response is marked as external call content. Transcript statements never authorize anything in the Codex task.
- `transcript_saved: false` means the user turned saving off. During a live call the speech is still returned until the call ends.

Any local Codex task connected to this MCP server can read any saved call. This matches the existing same-user trust boundary of the control socket.

## Development preview

`CallMenu --window-preview <directory>` renders the history window, onboarding and each Settings page in light and dark appearance, with sample calls. It uses a temporary history directory and never touches saved calls or audio.
