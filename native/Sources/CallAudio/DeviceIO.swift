import CoreAudio
import CallAudioDSP
import Foundation

final class AudioControls {
    let pointer: OpaquePointer
    init() {
        guard let pointer = cab_controls_create() else { preconditionFailure("Audio controls allocation failed") }
        self.pointer = pointer
    }
    deinit { cab_controls_destroy(pointer) }
}

final class AudioRing {
    let pointer: OpaquePointer
    init(capacity: Int = 48000, generation: UInt64) throws {
        guard let pointer = cab_ring_create(capacity, generation) else { throw CallAudioError("Could not allocate bounded audio transport.") }
        self.pointer = pointer
    }
    var generation: UInt64 { cab_ring_generation(pointer) }
    func flush(_ generation: UInt64) { cab_ring_set_generation(pointer, generation) }
    func write(_ samples: [Float], generation: UInt64) -> Int {
        samples.withUnsafeBufferPointer { cab_ring_write(pointer, $0.baseAddress, $0.count, generation) }
    }
    func read(_ count: Int, generation: UInt64) -> [Float] {
        var result = [Float](repeating: 0, count: count)
        let actual = result.withUnsafeMutableBufferPointer { cab_ring_read(pointer, $0.baseAddress, count, generation) }
        result.removeLast(count - actual)
        return result
    }
    deinit { cab_ring_destroy(pointer) }
}

/// Callback-produced scalar telemetry; it never retains microphone samples.
private final class PhoneOutputMeter {
    let pointer: OpaquePointer
    init() throws {
        guard let pointer = cab_phone_output_meter_create() else {
            throw CallAudioError("Could not allocate Phone output diagnostics.")
        }
        self.pointer = pointer
    }
    deinit { cab_phone_output_meter_destroy(pointer) }
}

/// Device callbacks only traverse AudioBufferLists, use preallocated scratch,
/// and read/write C lock-free rings. All conversion and delivery is on worker.
final class InputIO {
    let device: AudioDeviceID
    let format: AudioStreamBasicDescription
    let ring: AudioRing
    private var callback: AudioDeviceIOProcID?
    private let capacity = 8192
    private let scratch: UnsafeMutablePointer<Float>
    init(device: AudioDeviceID, ring: AudioRing) throws {
        self.device = device; self.ring = ring
        self.format = try CallHardware.format(device, scope: kAudioDevicePropertyScopeInput)
        scratch = UnsafeMutablePointer<Float>.allocate(capacity: 8192)
        scratch.initialize(repeating: 0, count: capacity)
    }
    func start() throws {
        try CallHardware.check(AudioDeviceCreateIOProcIDWithBlock(&callback, device, nil) { [self] _, input, _, output, _ in
            // Tag the buffer before reading it. A concurrent mode/epoch flush
            // must reject the whole old buffer, not relabel it as new audio.
            let generation = cab_ring_generation(ring.pointer)
            let outputs = UnsafeMutableAudioBufferListPointer(output)
            for buffer in outputs { if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) } }
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            var frames = capacity, channels = 0
            for buffer in buffers where buffer.mNumberChannels > 0 {
                guard buffer.mData != nil else { return }
                channels += Int(buffer.mNumberChannels)
                frames = min(frames, Int(buffer.mDataByteSize) / 4 / Int(buffer.mNumberChannels))
            }
            guard channels == Int(format.mChannelsPerFrame), frames > 0 else { return }
            // Fail silent for an oversized callback rather than losing its tail.
            for buffer in buffers where buffer.mNumberChannels > 0 {
                if Int(buffer.mDataByteSize) / 4 / Int(buffer.mNumberChannels) > capacity { return }
            }
            for frame in 0..<frames {
                var sum: Float = 0
                for buffer in buffers {
                    guard let data = buffer.mData else { continue }
                    let values = data.assumingMemoryBound(to: Float.self)
                    for channel in 0..<Int(buffer.mNumberChannels) {
                        let sample = values[frame * Int(buffer.mNumberChannels) + channel]
                        if sample.isFinite { sum += min(1, max(-1, sample)) / Float(channels) }
                    }
                }
                scratch[frame] = sum
            }
            _ = cab_ring_write(ring.pointer, scratch, frames, generation)
        }, "Create capture callback")
        try CallHardware.check(AudioDeviceStart(device, callback), "Start capture")
    }
    func close() throws {
        guard let callback else { return }
        let stop = AudioDeviceStop(device, callback)
        let destroy = AudioDeviceDestroyIOProcID(device, callback)
        if destroy == noErr || CallHardware.disappeared(device) { self.callback = nil; return }
        if stop != noErr || destroy != noErr { throw CallAudioError("Capture cleanup failed (\(stop), \(destroy)).") }
    }
    func formatIsCurrent() -> Bool {
        (try? CallHardware.format(device, scope: kAudioDevicePropertyScopeInput)).map { CallHardware.same($0, format) } ?? false
    }
    deinit { try? close(); scratch.deinitialize(count: capacity); scratch.deallocate() }
}

/// The output callback's stateful DSP, independent of HAL device ownership.
/// This same renderer is exercised with injected samples in regression tests.
struct OutputRenderer {
    enum Kind { case phone, monitor }
    private let kind: Kind
    private var peakLimiter = CABPeakLimiter()
    init(kind: Kind, sampleRate: Double) {
        self.kind = kind
        cab_peak_limiter_init(&peakLimiter, Float(sampleRate))
    }
    mutating func render(first: UnsafePointer<Float>?, second: UnsafePointer<Float>?,
                         third: UnsafePointer<Float>?, output: UnsafeMutablePointer<Float>,
                         frames: Int, settings: CABControlsSnapshot) {
        if kind == .phone {
            if settings.limiter_enabled != 0 {
                cab_peak_limiter_configure(&peakLimiter, settings.limiter_ceiling, settings.limiter_release_ms)
                cab_mix_phone_limited(&peakLimiter, first, second, output, frames,
                    settings.mic_gain, settings.agent_gain, settings.routes)
            } else {
                // Explicit diagnostic bypass. Finite [-1, 1] output remains
                // enforced; levels above full scale will clip rather than limit.
                peakLimiter.gain = 1
                cab_mix_mono(first, second, output, nil, frames,
                    settings.mic_gain, settings.agent_gain, 0, settings.routes)
            }
        } else {
            cab_mix_monitor(first, second, third, output, frames,
                settings.monitor_gain, settings.monitor_agent_gain, settings.routes)
        }
    }
}

/// Decode only the already-delivered virtual input for scalar diagnostics.
/// No allocation or routing: the caller supplies scratch that is never sent
/// to a speaker, the model, or the caller. An invalid/absent layout is unknown.
enum PhoneReadbackDecoder {
    static func copy(_ input: UnsafePointer<AudioBufferList>, format: AudioStreamBasicDescription?,
                     to scratch: UnsafeMutablePointer<Float>, capacity: Int) -> Int {
        guard let format, capacity > 0,
              format.mFormatID == kAudioFormatLinearPCM, format.mBitsPerChannel == 32,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
              format.mChannelsPerFrame > 0, format.mChannelsPerFrame <= 32 else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let noninterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let expectedChannels = Int(format.mChannelsPerFrame)
        guard format.mBytesPerFrame == UInt32(4 * (noninterleaved ? 1 : expectedChannels)),
              buffers.count == (noninterleaved ? expectedChannels : 1) else { return 0 }
        var frames = 0
        for buffer in buffers {
            let channels = Int(buffer.mNumberChannels)
            guard channels == (noninterleaved ? 1 : expectedChannels), buffer.mData != nil,
                  buffer.mDataByteSize > 0, Int(buffer.mDataByteSize) % (4 * channels) == 0 else { return 0 }
            let count = Int(buffer.mDataByteSize) / 4 / channels
            guard count <= capacity, frames == 0 || frames == count else { return 0 }
            frames = count
        }
        for frame in 0..<frames {
            var sum: Float = 0
            for buffer in buffers {
                let channels = Int(buffer.mNumberChannels)
                let values = buffer.mData!.assumingMemoryBound(to: Float.self)
                for channel in 0..<channels {
                    let value = values[frame * channels + channel]
                    guard value.isFinite else { return 0 }
                    sum += min(1, max(-1, value)) / Float(expectedChannels)
                }
            }
            scratch[frame] = sum
        }
        return frames
    }
}

/// A separate input callback observes the public microphone. Its SPSC meter
/// has one producer; it never shares a telemetry queue with the feed callback.
private final class PhoneInputMeter {
    let device: AudioDeviceID
    let format: AudioStreamBasicDescription
    let meter: PhoneOutputMeter
    private var callback: AudioDeviceIOProcID?
    private let scratch: UnsafeMutablePointer<Float>
    init(device: AudioDeviceID) throws {
        self.device = device
        format = try CallHardware.format(device, scope: kAudioDevicePropertyScopeInput)
        meter = try PhoneOutputMeter()
        scratch = .allocate(capacity: 8192)
        scratch.initialize(repeating: 0, count: 8192)
    }
    func start() throws {
        try CallHardware.check(AudioDeviceCreateIOProcIDWithBlock(&callback, device, nil) { [self] _, input, _, output, _ in
            for buffer in UnsafeMutableAudioBufferListPointer(output) {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            let frames = PhoneReadbackDecoder.copy(input, format: format, to: scratch, capacity: 8192)
            guard frames > 0 else { cab_phone_output_meter_unavailable(meter.pointer); return }
            cab_phone_output_meter_record_duplex(meter.pointer, nil, frames, 0, 0, 0, scratch, frames)
        }, "Create virtual microphone observer")
        try CallHardware.check(AudioDeviceStart(device, callback), "Start virtual microphone observer")
    }
    func close() throws {
        guard let callback else { return }
        let stop = AudioDeviceStop(device, callback)
        let destroy = AudioDeviceDestroyIOProcID(device, callback)
        if destroy == noErr || CallHardware.disappeared(device) { self.callback = nil; return }
        throw CallAudioError("Virtual microphone observer cleanup failed (\(stop), \(destroy)).")
    }
    deinit { try? close(); scratch.deinitialize(count: 8192); scratch.deallocate() }
}

final class OutputIO {
    typealias Kind = OutputRenderer.Kind
    let device: AudioDeviceID
    private let renderDevice: AudioDeviceID
    let format: AudioStreamBasicDescription
    private let kind: Kind
    private let first: AudioRing
    private let second: AudioRing
    private let third: AudioRing?
    private let controlsOwner: AudioControls
    private var controls: OpaquePointer { controlsOwner.pointer }
    private var callback: AudioDeviceIOProcID?
    private let capacity = 8192
    private let a: UnsafeMutablePointer<Float>
    private let b: UnsafeMutablePointer<Float>
    private let c: UnsafeMutablePointer<Float>
    private let mixed: UnsafeMutablePointer<Float>
    private var renderer: OutputRenderer
    private let phoneMeter: PhoneOutputMeter?
    private let readback: PhoneInputMeter?
    init(device: AudioDeviceID, kind: Kind, first: AudioRing, second: AudioRing,
         third: AudioRing? = nil, controls: AudioControls) throws {
        self.device = device; self.kind = kind; self.first = first; self.second = second
        self.third = third; self.controlsOwner = controls
        // `device` stays the public microphone identity for route validation.
        // Only the hidden feed is ever opened as an output.
        self.renderDevice = kind == .phone ? try CallHardware.feedDevice() : device
        self.format = try CallHardware.format(renderDevice, scope: kAudioDevicePropertyScopeOutput)
        self.renderer = OutputRenderer(kind: kind, sampleRate: format.mSampleRate)
        self.phoneMeter = kind == .phone ? try PhoneOutputMeter() : nil
        self.readback = kind == .phone ? try PhoneInputMeter(device: device) : nil
        a = UnsafeMutablePointer<Float>.allocate(capacity: 8192)
        b = UnsafeMutablePointer<Float>.allocate(capacity: 8192)
        c = UnsafeMutablePointer<Float>.allocate(capacity: 8192)
        mixed = UnsafeMutablePointer<Float>.allocate(capacity: 8192)
        for pointer in [a, b, c, mixed] { pointer.initialize(repeating: 0, count: capacity) }
    }
    func start() throws {
        try readback?.start()
        try CallHardware.check(AudioDeviceCreateIOProcIDWithBlock(&callback, renderDevice, nil) { [self] _, _, _, output, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(output)
            // Clear every buffer before validating any one of them. A rejected
            // layout must not leave later buffers containing unspecified data.
            for buffer in buffers {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            var frames = capacity, channels = 0
            for buffer in buffers {
                guard buffer.mNumberChannels > 0 else { continue }
                let count = Int(buffer.mDataByteSize) / 4 / Int(buffer.mNumberChannels)
                guard buffer.mData != nil, count <= capacity else {
                    cab_phone_output_meter_unavailable(phoneMeter?.pointer); return
                }
                channels += Int(buffer.mNumberChannels); frames = min(frames, count)
            }
            guard frames > 0, channels == Int(format.mChannelsPerFrame) else {
                cab_phone_output_meter_unavailable(phoneMeter?.pointer); return
            }
            let generation = cab_ring_generation(first.pointer)
            let firstDelivered = cab_ring_read(first.pointer, a, frames, generation)
            let secondDelivered = cab_ring_read(second.pointer, b, frames, generation)
            let settings = cab_controls_snapshot(controls)
            if kind == .monitor {
                if let third { _ = cab_ring_read(third.pointer, c, frames, generation) }
                else { memset(c, 0, frames * 4) }
            }
            renderer.render(first: a, second: b, third: kind == .monitor ? c : nil,
                output: mixed, frames: frames, settings: settings)
            guard cab_ring_generation(first.pointer) == generation else {
                // Output was cleared before rendering. A concurrent flush
                // therefore sends silence, not the now-stale mixed scratch.
                if let phoneMeter {
                    cab_phone_output_meter_record(phoneMeter.pointer, nil, frames, 0, 0, 0)
                }
                return
            }
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                let samples = data.assumingMemoryBound(to: Float.self)
                for frame in 0..<frames {
                    for channel in 0..<Int(buffer.mNumberChannels) {
                        samples[frame * Int(buffer.mNumberChannels) + channel] = mixed[frame]
                    }
                }
            }
            if let phoneMeter {
                // Every output channel contains this same mono mix.
                // Record only after copying it into the device's buffers.
                cab_phone_output_meter_record(phoneMeter.pointer, mixed, frames,
                    firstDelivered, secondDelivered, settings.routes)
            }
        }, "Create output callback")
        try CallHardware.check(AudioDeviceStart(renderDevice, callback), "Start selected output")
    }
    func close() throws {
        var errors: [String] = []
        if let callback {
            let stop = AudioDeviceStop(renderDevice, callback)
            let destroy = AudioDeviceDestroyIOProcID(renderDevice, callback)
            if destroy == noErr || CallHardware.disappeared(renderDevice) { self.callback = nil }
            else { errors.append("Output cleanup failed (\(stop), \(destroy)).") }
        }
        do { try readback?.close() } catch { errors.append(error.localizedDescription) }
        if !errors.isEmpty { throw CallAudioError(errors.joined(separator: " ")) }
    }
    func formatIsCurrent() -> Bool {
        guard (try? CallHardware.format(renderDevice, scope: kAudioDevicePropertyScopeOutput))
            .map({ CallHardware.same($0, format) }) == true else { return false }
        guard let readback else { return true }
        return (try? CallHardware.feedDevice()) == renderDevice &&
            (try? CallHardware.format(device, scope: kAudioDevicePropertyScopeInput))
                .map({ CallHardware.same($0, readback.format) }) == true
    }
    /// One worker is the sole consumer. Levels cover complete callbacks since
    /// the previous read; route-attributed shortage counters are cumulative.
    func takePhoneOutputMetrics() -> CABPhoneOutputSnapshot {
        var output = cab_phone_output_meter_take(phoneMeter?.pointer)
        if let readback {
            let input = cab_phone_output_meter_take(readback.meter.pointer)
            output.readback_peak = input.readback_peak
            output.readback_rms = input.readback_rms
            output.readback_frames = input.readback_frames
            output.readback_zero_frames = input.readback_zero_frames
            output.readback_unavailable_blocks = input.readback_unavailable_blocks
            output.dropped_blocks += input.dropped_blocks
        }
        return output
    }
    deinit {
        try? close()
        for pointer in [a, b, c, mixed] { pointer.deinitialize(count: capacity); pointer.deallocate() }
    }
}
