import CoreAudio
import Foundation
import CallAudioDSP

/// Opt-in diagnostics: raw virtual-input observation during an operator-led
/// call, or an isolated synthetic test that refuses active Phone/FaceTime audio.
/// No physical microphone, speaker, network, or audio recording is involved.
public enum PhoneOutputProbe {
    /// Read only the virtual microphone's signal during an operator-led test.
    /// Samples are reduced to levels immediately and never saved or forwarded.
    public static func observeInput() throws -> String {
        let device = try CallHardware.sendDevice(ApplicationAudioRuntime.sendDeviceUID)
        let ring = try AudioRing(generation: 1)
        let input = try InputIO(device: device, ring: ring)
        let duration = 10.0, interval = 0.2
        var observation = PhoneInputObservation()
        var windows: [[String: Any]] = []
        var elapsed = 0.0
        var startedAt = Date()
        var originalError: Error?
        do {
            try input.start()
            startedAt = Date()
            let start = ProcessInfo.processInfo.systemUptime
            var nextWindow = interval
            while elapsed < duration {
                // Do not count silence padding from polling an empty ring as
                // captured audio or as a hardware underrun.
                let queued = min(8192, cab_ring_queued_frames(ring.pointer))
                let samples = queued > 0 ? ring.read(queued, generation: 1) : []
                elapsed = ProcessInfo.processInfo.systemUptime - start
                observation.append(samples, elapsed: elapsed)
                if elapsed >= nextWindow || elapsed >= duration {
                    var window = observation.finishWindow(elapsed: elapsed, sampleRate: input.format.mSampleRate).json
                    window["hardware"] = observationHardware(device)
                    window["formatUnchanged"] = input.formatIsCurrent()
                    let counters = cab_ring_counters(ring.pointer)
                    window["observerOverflowFramesTotal"] = counters.overflow_frames
                    window["observerStaleFramesTotal"] = counters.stale_frames
                    window["queuedFramesAtWindowEnd"] = cab_ring_queued_frames(ring.pointer)
                    windows.append(window)
                    nextWindow = elapsed + interval
                }
                if elapsed < duration { Thread.sleep(forTimeInterval: 0.005) }
            }
        } catch { originalError = error }
        do { try input.close() }
        catch {
            let previous = originalError.map { "\($0.localizedDescription) " } ?? ""
            throw CallAudioError(previous + "Virtual-input observer cleanup failed: \(error.localizedDescription)")
        }
        if let originalError { throw originalError }
        var report = observation.total.json
        report["version"] = 2
        report["device"] = "Phone Assistant"
        report["deviceUID"] = ApplicationAudioRuntime.sendDeviceUID
        report["durationSeconds"] = elapsed
        report["startedAtUnixSeconds"] = startedAt.timeIntervalSince1970
        report["nominalWindowSeconds"] = interval
        report["sampleRate"] = input.format.mSampleRate
        report["windows"] = windows
        report["audioSaved"] = false
        report["audioForwarded"] = false
        report["signalInjected"] = false
        report["measurement"] = "Virtual input readback, downmixed and sanitized to mono; before Phone's downstream processing."
        report["timing"] = "Windows use observer receipt time, not hardware sample timestamps. Frame shortfalls include startup and callback/worker scheduling; last-frame age measures delivery to this observer."
        report["interpretation"] = "No frames gives null peak/RMS; zeroFrames counts actual delivered zero samples. Neither silence nor an estimated frame shortfall alone proves a transport failure. clippedFrames counts samples at +/-1 after downmix/sanitization. Hardware readings are snapshots taken at each window end; null means unavailable."
        return String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self)
    }

    private static func observationHardware(_ device: AudioDeviceID) -> [String: Any] {
        func direction(_ scope: AudioObjectPropertyScope) -> [String: Any] {
            func gain(_ selector: AudioObjectPropertySelector) -> Any {
                guard let value = try? CallHardware.value(device, selector, initial: Float32(0), scope: scope),
                      value.isFinite else { return NSNull() }
                return value
            }
            let mute = try? CallHardware.value(device, kAudioDevicePropertyMute, initial: UInt32(0), scope: scope)
            return ["volumeScalar": gain(kAudioDevicePropertyVolumeScalar),
                    "volumeDecibels": gain(kAudioDevicePropertyVolumeDecibels),
                    "muted": mute.map { $0 != 0 } as Any? ?? NSNull()]
        }
        return ["input": direction(kAudioDevicePropertyScopeInput),
                "output": direction(kAudioDevicePropertyScopeOutput)]
    }

    private static func requireIdlePhone() throws {
        let processes = try CallHardware.list(kAudioHardwarePropertyProcessObjectList)
        for process in processes {
            let bundle = try? CallHardware.string(process, kAudioProcessPropertyBundleID)
            guard ["com.apple.mobilephone", "com.apple.avconferenced", "com.apple.FaceTime"].contains(bundle ?? "") else { continue }
            for property in [kAudioProcessPropertyIsRunningInput, kAudioProcessPropertyIsRunningOutput] {
                guard (try? CallHardware.value(process, property, initial: UInt32(0))) != 1 else {
                    throw CallAudioError("End the test call before checking the virtual microphone.")
                }
            }
        }
        for uid in [ApplicationAudioRuntime.sendDeviceUID, ApplicationAudioRuntime.feedDeviceUID] {
            let device = try CallHardware.device(uid)
            guard try CallHardware.value(device, kAudioDevicePropertyDeviceIsRunningSomewhere, initial: UInt32(0)) == 0 else {
                throw CallAudioError("Stop audio routing before running the virtual microphone test.")
            }
        }
    }

    /// Exercise the production hidden feed plus independent microphone observer.
    /// Refuse any active virtual-device client; do not interrupt live routing.
    public static func checkAutomaticReadback(sustained: Bool = false) throws -> String {
        try requireIdlePhone()
        let device = try CallHardware.sendDevice(ApplicationAudioRuntime.sendDeviceUID)
        guard try CallHardware.value(device, kAudioDevicePropertyDeviceIsRunningSomewhere, initial: UInt32(0)) == 0 else {
            throw CallAudioError("Stop audio routing before checking automatic readback.")
        }
        let microphone = try AudioRing(generation: 1), agent = try AudioRing(generation: 1)
        let controls = AudioControls()
        let output = try OutputIO(device: device, kind: .phone, first: microphone, second: agent, controls: controls)
        cab_controls_set_routes(controls.pointer, CallAudioRoutes.microphoneToCaller.rawValue)
        cab_controls_set_send_muted(controls.pointer, false)
        _ = cab_controls_enable_if_revision(controls.pointer, cab_controls_revision(controls.pointer))
        var report = PhoneTestReport(nativePlayback: false, microphoneEnabled: false, microphoneGain: 1, callerGain: 1)
        var originalError: Error?
        let duration = sustained ? 20.0 : 2.0
        let interval = sustained ? 0.2 : 0.05
        let signalEnd = duration - (sustained ? 1.5 : 0.8)
        do {
            try output.start()
            report.event("running")
            let start = ProcessInfo.processInfo.systemUptime
            var position = 0, nextWindow = interval
            while ProcessInfo.processInfo.systemUptime - start < duration {
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                if elapsed < signalEnd, cab_ring_queued_frames(microphone.pointer) < 1920 {
                    let tone = (0..<960).map { Float(0.1 * sin(2 * Double.pi * 997 * Double(position + $0) / 48000)) }
                    position += tone.count
                    guard microphone.write(tone, generation: 1) == tone.count else { throw CallAudioError("Probe overflow") }
                }
                if elapsed >= nextWindow {
                    let meter = output.takePhoneOutputMetrics()
                    report.append(meters: .init(renderedPhonePeak: meter.peak, renderedPhoneRMS: meter.rms,
                        renderedPhoneFrames: meter.rendered_frames, renderedPhoneDroppedTelemetryBlocks: meter.dropped_blocks,
                        phoneReadbackPeak: meter.readback_peak, phoneReadbackRMS: meter.readback_rms,
                        phoneReadbackFrames: meter.readback_frames, phoneReadbackZeroFrames: meter.readback_zero_frames,
                        phoneReadbackUnavailableBlocks: meter.readback_unavailable_blocks), muted: false)
                    nextWindow = elapsed + interval
                }
                Thread.sleep(forTimeInterval: 0.005)
            }
        } catch { originalError = error }
        cab_controls_cancel(controls.pointer)
        try output.close()
        if let originalError { throw originalError }
        report.event("stopped")
        let windows = report.samples
        let peak = windows.compactMap { $0.phoneReadback?.peak }.max() ?? 0
        let frames = windows.reduce(UInt64(0)) { $0 + ($1.phoneReadback?.frames ?? 0) }
        let receivedFromStart = windows.first?.phoneReadback?.frames ?? 0 > 0
        let tailSilent = windows.suffix(4).allSatisfy {
            guard let readback = $0.phoneReadback else { return false }
            return readback.frames > 0 && readback.zeroFrames == readback.frames
        }
        let noLoss = windows.allSatisfy { $0.renderedPhoneDroppedTelemetryBlocks == 0 && $0.phoneReadback?.unavailableBlocks == 0 }
        let steadyWindows = windows.filter { $0.elapsed > 1 && $0.elapsed < signalEnd }
        let steady = !sustained || (!steadyWindows.isEmpty && steadyWindows.allSatisfy {
            guard let input = $0.phoneReadback, let rms = input.rms else { return false }
            return input.frames > 0 && rms > 0.065 && rms < 0.076
        })
        let passed = receivedFromStart && frames > 48000 && peak > 0.09 && peak < 0.11 && tailSilent && noLoss && steady
        let object: [String: Any] = ["passed": passed, "readbackFrames": frames, "readbackPeak": peak,
            "receivedFromFirstWindow": receivedFromStart, "silentTail": tailSilent, "noTelemetryLoss": noLoss,
            "extraInputIOProc": true, "transport": "separate-hidden-feed", "physicalMicrophoneUsed": false, "audioSaved": false,
            "durationSeconds": duration, "steadySignal": steady, "steadyWindows": steadyWindows.count,
            "report": try JSONSerialization.jsonObject(with: report.encoded())]
        return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    public static func run(captureFormat: Bool = false) throws -> String {
        try requireIdlePhone()
        let device = try CallHardware.sendDevice(ApplicationAudioRuntime.sendDeviceUID)
        let microphone = try AudioRing(generation: 1), agent = try AudioRing(generation: 1)
        let captured = try AudioRing(capacity: 192000, generation: 1)
        let controls = AudioControls()
        let output = try OutputIO(device: device, kind: .phone, first: microphone, second: agent, controls: controls)
        var input: InputIO?
        var tap: CallerTap?
        var formatChanges: [String] = []
        func describe(_ format: AudioStreamBasicDescription) -> String {
            "\(format.mSampleRate) Hz, \(format.mChannelsPerFrame) channels, flags \(format.mFormatFlags), \(format.mBytesPerFrame) bytes/frame"
        }
        var initialFormat = AudioStreamBasicDescription()
        let converter = try MonoConverter(from: 48000, to: 48000)
        var cleanupErrors: [String] = []
        var samples: [Float] = []
        var originalError: Error?
        do {
            cab_controls_set_routes(controls.pointer, CallAudioRoutes.microphoneToCaller.rawValue)
            cab_controls_set_send_muted(controls.pointer, false)
            let revision = cab_controls_revision(controls.pointer)
            guard cab_controls_enable_if_revision(controls.pointer, revision) else { throw CallAudioError("Probe cancelled") }
            if captureFormat {
                try output.start()
                guard let process = try CallHardware.list(kAudioHardwarePropertyProcessObjectList).first(where: {
                    (try? CallHardware.value($0, kAudioProcessPropertyPID, initial: pid_t(0))) == getpid()
                }) else { throw CallAudioError("Probe process was not registered") }
                let ownTap = CallerTap(process: process); tap = ownTap
                try ownTap.start(manageListening: true)
                // Verify the same live property change used by the control
                // panel, scoped only to this synthetic probe's own process.
                try ownTap.setManagedListening(false)
                try ownTap.setManagedListening(true)
                input = try InputIO(device: ownTap.device, ring: captured)
            } else { input = try InputIO(device: device, ring: captured) }
            initialFormat = input!.format
            try input!.start()
            if !captureFormat { try output.start() }
            var position = 0
            let end = ProcessInfo.processInfo.systemUptime + 2
            while ProcessInfo.processInfo.systemUptime < end {
                if cab_ring_queued_frames(microphone.pointer) < 1920 {
                    let tone = (0..<960).map { Float(0.1 * sin(2 * Double.pi * 997 * Double(position + $0) / 48000)) }
                    position += tone.count
                    let converted = try converter.convert(tone)
                    guard microphone.write(converted, generation: 1) == converted.count else { throw CallAudioError("Probe output overflow") }
                }
                samples += captured.read(8192, generation: 1)
                let actual = try CallHardware.format(input!.device, scope: kAudioDevicePropertyScopeInput)
                if !CallHardware.same(actual, initialFormat), !formatChanges.contains(describe(actual)) {
                    formatChanges.append(describe(actual))
                }
                Thread.sleep(forTimeInterval: 0.005)
            }
        } catch { originalError = error }
        cab_controls_cancel(controls.pointer)
        do { try output.close() } catch { cleanupErrors.append(error.localizedDescription) }
        do { try input?.close() } catch { cleanupErrors.append(error.localizedDescription) }
        do { try tap?.close() } catch { cleanupErrors.append(error.localizedDescription) }
        guard cleanupErrors.isEmpty else { throw CallAudioError(cleanupErrors.joined(separator: " ")) }
        if let originalError { throw originalError }
        let window = Array(samples.dropFirst(Int(initialFormat.mSampleRate / 2)).suffix(Int(initialFormat.mSampleRate)))
        let peak = window.map { abs($0) }.max() ?? 0
        let rms = sqrt(window.reduce(Double(0)) { $0 + Double($1 * $1) } / Double(max(1, window.count)))
        let crossings = zip(window, window.dropFirst()).filter { $0.0 <= 0 && $0.1 > 0 }.count
        let frequency = Double(crossings) * initialFormat.mSampleRate / Double(max(1, window.count))
        let passed = window.count >= Int(initialFormat.mSampleRate / 2) && peak > 0.05 && peak < 0.11
            && rms > 0.04 && abs(frequency - 997) < 10 && formatChanges.isEmpty
        let report: [String: Any] = ["passed": passed, "capturedFrames": samples.count,
            "rate": initialFormat.mSampleRate, "peak": peak, "rms": rms, "frequency": frequency,
            "initialFormat": describe(initialFormat), "formatChanges": formatChanges,
            "expectedPeak": 0.1, "livePlaybackSwitchVerified": captureFormat,
            "route": captureFormat ? "synthetic signal → production muted process tap → input capture" : "synthetic microphone PCM → production converter/mixer/output → installed Phone Assistant → input capture"]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

/// Whether a Phone call's audio is live: Phone, or the Continuity conference
/// daemon that carries iPhone calls, has running microphone input. Read-only.
public enum PhoneCallActivity {
    public static func callAudioRunning() -> Bool {
        guard let processes = try? CallHardware.list(kAudioHardwarePropertyProcessObjectList) else { return false }
        return processes.contains { process in
            let bundle = (try? CallHardware.string(process, kAudioProcessPropertyBundleID)) ?? ""
            guard ["com.apple.mobilephone", "com.apple.avconferenced"].contains(bundle) else { return false }
            return (try? CallHardware.value(process, kAudioProcessPropertyIsRunningInput, initial: UInt32(0))) == 1
        }
    }
}
