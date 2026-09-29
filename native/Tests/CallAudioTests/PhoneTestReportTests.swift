import Foundation
import XCTest
@testable import CallAudio

final class PhoneTestReportTests: XCTestCase {
    private func report() -> PhoneTestReport {
        PhoneTestReport(nativePlayback: true, microphoneEnabled: true, microphoneGain: 1.06, callerGain: 1.96)
    }
    func testOlderReportsWithoutOriginRemainReadable() throws {
        var original = report(); original.append(meters: .init(), muted: false)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: original.encoded()) as? [String: Any])
        object.removeValue(forKey: "origin")
        object.removeValue(forKey: "startupSamples")
        var samples = try XCTUnwrap(object["samples"] as? [[String: Any]])
        samples[0].removeValue(forKey: "phoneReadback")
        object["samples"] = samples
        let oldData = try JSONSerialization.data(withJSONObject: object)
        let restored = try JSONDecoder().decode(PhoneTestReport.self, from: oldData)
        XCTAssertNil(restored.origin)
        XCTAssertNil(restored.startupSamples)
        XCTAssertNil(restored.samples.first?.phoneReadback)
        XCTAssertEqual(restored.id, original.id)
        XCTAssertNoThrow(try restored.encoded())
    }
    func testLongBridgeCallReportStaysWithinLimitAndSaves() throws {
        var report = PhoneTestReport(nativePlayback: false, microphoneEnabled: true,
            microphoneGain: 1, callerGain: 1, origin: .phoneBridge)
        report.setNativePlayback(false)
        report.event("routing", detail: "Speaker: user; listener: user")
        report.setLiveTuning(CallAudioTuning(microphoneGain: 1))
        report.event("devices", detail: "Microphone: MacBook Pro Microphone · Listening: MacBook Pro Speakers")
        report.event("running")
        // Three minutes of meter windows, well past the sample limits.
        for index in 0..<900 {
            var meters = CallAudioMeters(caller: 0.1, microphone: 0.2, agent: 0.05)
            meters.renderedPhonePeak = 0.2; meters.renderedPhoneRMS = 0.05; meters.renderedPhoneFrames = 9600
            meters.phoneReadbackFrames = 9600; meters.phoneReadbackPeak = 0.2; meters.phoneReadbackRMS = 0.05
            meters.phoneReadbackZeroFrames = UInt64(index % 3 == 0 ? 0 : 10)
            report.append(meters: meters, muted: false)
        }
        XCTAssertLessThanOrEqual(try report.encoded().count, PhoneTestReportStorage.maximumBytes)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        try PhoneTestReportStorage.save(report, to: url)
        XCTAssertEqual(try PhoneTestReportStorage.load(from: url)?.id, report.id)
    }
    func testBridgeAndAdvancedReportsCannotOverwriteEachOther() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let advancedURL = directory.appendingPathComponent(PhoneTestReportStorage.defaultURL.lastPathComponent)
        let bridgeURL = directory.appendingPathComponent(PhoneTestReportStorage.bridgeURL.lastPathComponent)
        XCTAssertNotEqual(advancedURL, bridgeURL)
        let advanced = report()
        var bridge = PhoneTestReport(nativePlayback: false, microphoneEnabled: true,
            microphoneGain: 1, callerGain: 1, origin: .phoneBridge)
        bridge.event("running")
        var meters = CallAudioMeters(microphone: 0.4)
        meters.renderedPhonePeak = 0.39; meters.renderedPhoneRMS = 0.1
        meters.renderedPhoneFrames = 9600
        bridge.append(meters: meters, muted: false)
        try PhoneTestReportStorage.save(bridge, to: bridgeURL)
        // An older Advanced queue finishing afterwards cannot erase this run.
        try PhoneTestReportStorage.save(advanced, to: advancedURL)
        let restored = try XCTUnwrap(PhoneTestReportStorage.load(from: bridgeURL))
        XCTAssertEqual(restored.origin, .phoneBridge)
        XCTAssertEqual(restored.id, bridge.id)
        XCTAssertEqual(restored.samples[0].renderedPhoneFrames, 9600)
        XCTAssertEqual(try PhoneTestReportStorage.load(from: advancedURL)?.id, advanced.id)
    }
    func testBoundedScalarWindowsAndEventsRoundTrip() throws {
        var report = report()
        report.event("running")
        for index in 0..<400 {
            var meters = CallAudioMeters(caller: 0.25, microphone: 0.4)
            meters.renderedPhonePeak = Float(index) / 1000
            meters.renderedPhoneRMS = 0.1; meters.renderedPhoneFrames = 9600
            meters.microphoneCaptureFrames = 9400; meters.callerCaptureFrames = 9300
            meters.microphoneOutputUnderrunFrames = UInt64(index)
            meters.agentOutputUnderrunFrames = 0; meters.renderedPhoneDroppedTelemetryBlocks = 2
            meters.phoneReadbackFrames = 9600; meters.phoneReadbackZeroFrames = 200
            meters.phoneReadbackPeak = 0.05; meters.phoneReadbackRMS = 0.01
            let now = report.startedAt.addingTimeInterval(Double(index) / 5)
            report.append(meters: meters, muted: index % 2 == 0, now: now)
            report.event("level", detail: String(repeating: "x", count: 600), now: now)
        }
        XCTAssertEqual(report.samples.count, 150)
        XCTAssertEqual(report.samples.first?.elapsed, 50)
        XCTAssertEqual(report.samples.last?.microphoneOutputUnderrunFrames, 399)
        XCTAssertEqual(report.startupSamples?.count, 75)
        XCTAssertEqual(report.startupSamples?.first?.elapsed, 0)
        XCTAssertEqual(try XCTUnwrap(report.startupSamples?.last?.elapsed), 14.8, accuracy: 0.000001)
        XCTAssertEqual(report.startupSamples?.first?.phoneReadback?.frames, 9600)
        XCTAssertEqual(report.samples.last?.renderedPhoneFrames, 9600)
        XCTAssertEqual(report.samples.last?.microphoneCaptureFrames, 9400)
        XCTAssertEqual(report.samples.last?.renderedPhoneDroppedTelemetryBlocks, 2)
        XCTAssertEqual(report.events.count, 20)
        XCTAssertTrue(report.events.allSatisfy { $0.detail?.count == 500 })
        let data = try report.encoded()
        XCTAssertLessThan(data.count, PhoneTestReportStorage.maximumBytes)
        XCTAssertEqual(try JSONDecoder().decode(PhoneTestReport.self, from: data), report)
        let text = String(decoding: data, as: UTF8.self)
        for forbidden in ["pcm", "transcript", "apiKey", "telephone", "audioRouting", "microphoneUID"] {
            XCTAssertFalse(text.contains(forbidden))
        }
    }
    func testStoppingRejectsLateSamplesAndFailureSurvivesCleanup() throws {
        var report = report()
        report.event("running")
        report.append(meters: .init(microphone: 0.2), muted: false)
        report.event("failed", detail: "Capture ended")
        report.event("stopping"); report.event("stopped")
        report.event("running")
        report.append(meters: .init(microphone: 1), muted: false)
        XCTAssertEqual(report.state, "failed")
        XCTAssertEqual(report.failureDetail, "Capture ended")
        XCTAssertTrue(report.isFinalized)
        XCTAssertEqual(report.samples.count, 1)
        XCTAssertEqual(report.events.last?.state, "stopped")
        var stopped = self.report()
        stopped.event("stopping")
        stopped.append(meters: .init(), muted: true)
        stopped.event("running")
        XCTAssertEqual(stopped.state, "stopping")
        stopped.event("stopped")
        XCTAssertTrue(stopped.samples.isEmpty)
        XCTAssertTrue(stopped.isFinalized)
    }
    func testNonfiniteLevelsRemainEncodableAndMarkedInvalid() throws {
        var report = report()
        var meters = CallAudioMeters(caller: .nan, microphone: .infinity)
        meters.renderedPhonePeak = -.infinity; meters.renderedPhoneRMS = -1
        report.append(meters: meters, muted: false, now: report.startedAt.addingTimeInterval(-1))
        XCTAssertEqual(report.samples[0].invalidScalarCount, 4)
        XCTAssertEqual(report.samples[0].elapsed, 0)
        XCTAssertNoThrow(try report.encoded())
    }
    func testLiveMicrophoneVolumeIsReportedWithoutChangingCompletedReports() throws {
        var report = report()
        report.event("running")
        report.setMicrophoneGain(3)
        XCTAssertEqual(report.microphoneGain, 3)
        XCTAssertEqual(report.events.last?.state, "microphoneVolume")
        XCTAssertEqual(report.events.last?.detail, "300%")
        report.setMicrophoneGain(.nan)
        XCTAssertEqual(report.microphoneGain, 3)
        report.event("stopped")
        let finished = report
        report.setMicrophoneGain(1)
        XCTAssertEqual(report, finished)
        XCTAssertNoThrow(try report.encoded())
    }
    func testMissingReadbackIsDistinctFromSilenceAndInvalidCountsAreRejected() throws {
        var report = report()
        report.append(meters: .init(phoneReadbackUnavailableBlocks: 25), muted: false)
        XCTAssertEqual(report.samples[0].phoneReadback?.frames, 0)
        XCTAssertNil(report.samples[0].phoneReadback?.peak)
        report.append(meters: .init(phoneReadbackFrames: 480, phoneReadbackZeroFrames: 480), muted: false)
        XCTAssertEqual(report.samples[1].phoneReadback?.peak, 0)
        XCTAssertEqual(report.samples[1].phoneReadback?.rms, 0)
        XCTAssertNoThrow(try report.encoded())
        report.append(meters: .init(phoneReadbackFrames: 1, phoneReadbackZeroFrames: 2), muted: false)
        XCTAssertThrowsError(try report.encoded())
    }
    func testAtomicPrivateLatestReplacementAndBoundedLoading() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("latest-phone-test.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertNil(try PhoneTestReportStorage.load(from: url))
        let first = report()
        try PhoneTestReportStorage.save(first, to: url)
        XCTAssertEqual(try PhoneTestReportStorage.load(from: url), first)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        var next = report(); next.event("stopped")
        try PhoneTestReportStorage.save(next, to: url)
        XCTAssertEqual(try PhoneTestReportStorage.load(from: url), next)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [url.lastPathComponent])
        try Data(repeating: 0, count: PhoneTestReportStorage.maximumBytes + 1).write(to: url)
        XCTAssertThrowsError(try PhoneTestReportStorage.load(from: url))
    }
    func testLoadRejectsOversizedArraysWithinByteLimit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("latest-phone-test.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var report = report(); report.append(meters: .init(), muted: false)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: report.encoded()) as? [String: Any])
        let sample = try XCTUnwrap((object["samples"] as? [[String: Any]])?.first)
        object["samples"] = Array(repeating: sample, count: 151)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        XCTAssertThrowsError(try PhoneTestReportStorage.load(from: url))
        object["samples"] = [sample]
        object["startupSamples"] = Array(repeating: sample, count: 76)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        XCTAssertThrowsError(try PhoneTestReportStorage.load(from: url))
    }
    func testLoadRejectsConflictingLifecycleAndNegativeLevels() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("latest-phone-test.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var report = report(); report.append(meters: .init(), muted: false); report.event("stopped")
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: report.encoded()) as? [String: Any])
        var object = original; object["state"] = "running"
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        XCTAssertThrowsError(try PhoneTestReportStorage.load(from: url))
        object = original
        var samples = try XCTUnwrap(object["samples"] as? [[String: Any]])
        samples[0]["microphonePeak"] = -1
        object["samples"] = samples
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        XCTAssertThrowsError(try PhoneTestReportStorage.load(from: url))
    }
}
