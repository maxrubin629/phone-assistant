# Bundled Phone Assistant Audio Bridge

The app bundles the virtual microphone and native installation helper. Enable and Update use the app's setup screen with macOS administrator authorization. System Audio Access and optional Microphone Access are the only capture permissions. There is no separate driver download, shell-script authorization, kernel extension, security-policy change, or Mac reboot.

The stable installation path remains `/Library/Audio/Plug-Ins/HAL/CodexCallSend.driver`. The device's display name is Phone Assistant; its UID remains `com.codexcall.audio.send.device`.

The app keeps its internal `CallMenu.app` path and `com.codexcall.menu` identity so existing permissions, settings, and MCP registrations stay attached to the same app. Finder and macOS display it as Phone Assistant.

The signed helper accepts only fixed install and status operations over authenticated NSXPC. It verifies the app's signing requirement, and the app verifies the helper's signing requirement and exact build hash. The payload and its complete manifest are compiled into the helper. Caller-controlled paths, commands, process IDs, and payloads are not accepted. Read-only `--status` and `--check` are available for diagnostics.

An existing exact payload is reused. Recognized older payloads can be upgraded at the same path with an atomic swap. Legacy ad-hoc builds require an exact compiled-in fingerprint; later builds require the same publisher's signature, expected identity, and a lower version. Unknown or newer installations are preserved. Staging rejects symlinks, hard links, special files, traversal, and unsafe ownership. The previous payload remains under a name without the `.driver` extension until activation succeeds.

Installation and activation check for active audio. Activation verifies one Apple-signed `/usr/sbin/coreaudiod` process, its owner, parent, PID and start time, then signals that exact process. Launchd starts Core Audio again. No broad process-name kill or fallback security change is used. The app waits for the stable device UID and expected display name before reporting Ready. Activation failure is shown explicitly. A retained staging backup after failure does not register as another driver.

The native helper uses the deprecated SMJobBless API. Its compatibility and setup experience require qualification on each supported macOS release.

For the full setup contract, signing configuration, build commands, routing behavior, and remaining qualification, see [portable routing and distribution](distribution-scope.md).
