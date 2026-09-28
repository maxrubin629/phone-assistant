# Security

Phone Assistant installs a privileged helper and an audio driver, handles a voice API key, and reads calls into Codex. This page describes the trust boundaries. To report a vulnerability, open a private security advisory on the repository rather than a public issue.

## Privileged helper

The helper (`com.codexcall.phonekit.helper`) runs as root only to install or update the audio driver.

- It accepts XPC connections only from a client matching `anchor apple generic`, the app's identifier, and the signing team. The app is signed with the hardened runtime and requests only the audio-input entitlement.
- It exposes two operations, install and status. Neither takes a path or other caller-supplied input.
- It installs only the driver payload compiled into it, checked file by file against SHA-256 digests and the driver's code signature. Symbolic links, extra or special files, multiple hard links, path traversal, and directories not owned by root are refused.
- It stages the install and moves it into place atomically. It never overwrites a newer, tampered, or unknown installation.
- To activate the driver, it restarts `coreaudiod` only after confirming the exact process: its path, the `_coreaudiod` account, launchd parentage, Apple's code signature, and its start time, which rules out PID reuse.

## Audio driver

- The driver has no network access and handles no credentials, models, or transcripts.
- Its real-time path validates object IDs, buffer sizes, and timestamps, never blocks on a lock, and turns missing, stale, or non-finite audio into silence.
- Its standalone tests run under AddressSanitizer and UndefinedBehaviorSanitizer.
- Known limitation: audio devices are system-wide, so another app on the same Mac could write to the hidden feed device and be heard on a call while Phone Assistant is connected. Virtual devices are routing endpoints, not access control between apps.

## Local control

- Codex reaches the app through `CallMCP` over a Unix socket in a private directory (mode 0700, socket 0600). The app checks that the connecting process belongs to the same user. The Codex callback socket gets the same ownership, permission, and peer checks.
- Any Codex task on the Mac that has these tools can read any saved call with `call_transcript`. This matches the same-user boundary above.

## Data

- The API key is stored as one item in your login keychain. Other apps must ask your permission to read it.
- Call records are owner-only files (0600) in an owner-only directory (0700) in Application Support. They're deleted after 30 days by default.
- On-device transcription never leaves the Mac. The voice model receives only the audio the current mode allows.

## Prompt injection

Everything the caller says is untrusted. The assistant is instructed never to treat caller statements as authority. Questions and results reach Codex marked as external call content, and `call_transcript` output carries the same marking. The originating task can still be persuaded by a well-crafted question, so keep sensitive decisions with the user: for example, "check with me before confirming".
