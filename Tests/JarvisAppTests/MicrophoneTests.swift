import XCTest
@testable import Jarvis

@MainActor
final class MicrophoneTests: XCTestCase {
    private final class Session: AudioCaptureSession {
        var pcm: ((Data) -> Void)?
        var changed: (() -> Void)?
        var failure: Error?
        var stopped = false
        var earlyPCM = false
        var processing: [Bool] = []
        func start(voiceProcessing: Bool, pcm: @escaping (Data) -> Void, changed: @escaping () -> Void) throws -> Bool {
            processing.append(voiceProcessing)
            self.pcm = pcm; self.changed = changed
            if earlyPCM { pcm(Data([0, 0])) }
            if let failure { throw failure }
            return voiceProcessing
        }
        func stop() { stopped = true }
    }

    func testStopReleasesSessionAndNextStartCreatesFreshCapture() {
        var created = 0
        weak var previous: Session?
        let mic = MicrophoneCapture(makeSession: {
            created += 1
            let session = Session(); previous = session
            return session
        }, permission: { $0(true) })
        mic.start(voiceProcessing: false)
        XCTAssertNotNil(previous)
        mic.stop(); mic.stop()
        XCTAssertNil(previous, "Stopping must release the session, not just pause its engine")
        mic.start(voiceProcessing: false)
        XCTAssertEqual(created, 2)
        mic.stop()
    }

    func testPartialStartFailureCleansUpAndDoesNotReportReady() {
        let session = Session()
        session.failure = NSError(domain: "test", code: 1)
        let mic = MicrophoneCapture(makeSession: { session }, permission: { $0(true) })
        var events: [String] = []
        mic.onEvent = { events.append($0["type"] as? String ?? "") }
        mic.start(voiceProcessing: false)
        XCTAssertTrue(session.stopped)
        XCTAssertFalse(events.contains("microphone_ready"))
        XCTAssertTrue(events.contains("microphone_error"))
    }

    func testVoiceProcessingFailureUsesFreshUnprocessedSession() {
        let first = Session(), fallback = Session()
        first.failure = AudioCaptureError.voiceProcessingUnavailable
        var count = 0
        let mic = MicrophoneCapture(makeSession: {
            count += 1; return count == 1 ? first : fallback
        }, permission: { $0(true) })
        var modes: [Bool] = []
        mic.onEvent = { if $0["type"] as? String == "input_processing", let mode = $0["enabled"] as? Bool { modes.append(mode) } }
        mic.start(voiceProcessing: true)
        XCTAssertTrue(first.stopped)
        XCTAssertEqual(fallback.processing, [false])
        XCTAssertEqual(modes, [false])
        mic.stop()
    }
    private final class Clock {
        var time: TimeInterval = 0
        var jobs: [(TimeInterval, DispatchWorkItem)] = []
        func schedule(_ delay: TimeInterval, _ action: @escaping () -> Void) -> DispatchWorkItem {
            let work = DispatchWorkItem(block: action)
            jobs.append((time + delay, work)); return work
        }
        func advance(_ seconds: TimeInterval) {
            let end = time + seconds
            while let next = jobs.indices.min(by: { jobs[$0].0 < jobs[$1].0 }), jobs[next].0 <= end {
                let (due, work) = jobs.remove(at: next)
                time = due
                if !work.isCancelled { work.perform() }
            }
            time = end
        }
    }

    func testStopWhilePermissionPendingCannotStartCapture() {
        var permission: ((Bool) -> Void)?
        var created = 0
        let mic = MicrophoneCapture(makeSession: { created += 1; return Session() }, permission: { permission = $0 })
        mic.start(voiceProcessing: false)
        mic.stop()
        permission?(true)
        XCTAssertEqual(created, 0)
    }

    func testRouteRecoveryDropsOldAudioAndStopCancelsRestart() {
        let clock = Clock(), first = Session(), second = Session()
        var count = 0
        let mic = MicrophoneCapture(makeSession: { count += 1; return count == 1 ? first : second },
                                    permission: { $0(true) }, now: { clock.time }, schedule: clock.schedule)
        var audio: [Data] = []
        mic.onPCM = { audio.append($0) }
        mic.start(voiceProcessing: false)
        first.pcm?(Data([1, 0]))
        first.changed?()
        XCTAssertTrue(first.stopped)
        first.pcm?(Data([2, 0]))
        clock.advance(0.5)
        second.pcm?(Data([3, 0]))
        first.changed?()
        XCTAssertFalse(second.stopped, "Notifications from an old engine must not stop the new one")
        XCTAssertEqual(audio, [Data([1, 0]), Data([3, 0])])
        second.changed?()
        mic.stop()
        clock.advance(10)
        XCTAssertEqual(count, 2)
    }

    func testRepeatedRouteFailuresStopAfterThreeRecoveryAttempts() {
        let clock = Clock()
        var count = 0
        var sessions: [Session] = []
        let mic = MicrophoneCapture(makeSession: {
            count += 1
            let session = Session()
            if count > 1 { session.failure = NSError(domain: "test", code: 2) }
            sessions.append(session); return session
        }, permission: { $0(true) }, now: { clock.time }, schedule: clock.schedule)
        var errors = 0
        mic.onEvent = { if $0["type"] as? String == "microphone_error" { errors += 1 } }
        mic.start(voiceProcessing: false)
        sessions[0].changed?()
        clock.advance(10)
        XCTAssertEqual(count, 4, "Initial capture plus at most three recovery attempts")
        XCTAssertEqual(errors, 1)
        XCTAssertTrue(sessions.allSatisfy { $0.stopped })
    }

    func testReadyRequiresFirstBufferButSilenceIsStillValidAudio() {
        let clock = Clock(), session = Session()
        let mic = MicrophoneCapture(makeSession: { session }, permission: { $0(true) }, now: { clock.time }, schedule: clock.schedule)
        var ready = 0
        mic.onEvent = { if $0["type"] as? String == "microphone_ready" { ready += 1 } }
        mic.start(voiceProcessing: false)
        XCTAssertEqual(ready, 0)
        for _ in 0..<10 {
            clock.advance(1)
            session.pcm?(Data([0, 0]))
        }
        XCTAssertEqual(ready, 1)
        XCTAssertFalse(session.stopped, "Quiet audio must not trigger recovery")
        mic.stop()
    }

    func testNoFirstBufferFailsAndReleasesCapture() {
        let clock = Clock(), session = Session()
        let mic = MicrophoneCapture(makeSession: { session }, permission: { $0(true) }, now: { clock.time }, schedule: clock.schedule)
        var errors = 0, ready = 0
        mic.onEvent = {
            if $0["type"] as? String == "microphone_error" { errors += 1 }
            if $0["type"] as? String == "microphone_ready" { ready += 1 }
        }
        mic.start(voiceProcessing: false)
        clock.advance(5)
        session.pcm?(Data([0, 0]))
        XCTAssertTrue(session.stopped)
        XCTAssertEqual(errors, 1)
        XCTAssertEqual(ready, 0)
    }

    func testStreamStallAttemptsRecoveryAndEventuallyReleasesEverything() {
        let clock = Clock()
        var sessions: [Session] = []
        let mic = MicrophoneCapture(makeSession: { let session = Session(); sessions.append(session); return session },
                                    permission: { $0(true) }, now: { clock.time }, schedule: clock.schedule)
        var errors = 0
        mic.onEvent = { if $0["type"] as? String == "microphone_error" { errors += 1 } }
        mic.start(voiceProcessing: false)
        sessions[0].pcm?(Data([0, 0]))
        clock.advance(11)
        XCTAssertEqual(errors, 1)
        XCTAssertTrue(sessions.allSatisfy { $0.stopped })
        mic.stop()
    }

    func testLateOldBufferCannotDeclareRecoveredSessionReady() {
        let clock = Clock(), first = Session(), second = Session()
        var count = 0
        let mic = MicrophoneCapture(makeSession: { count += 1; return count == 1 ? first : second },
                                    permission: { $0(true) }, now: { clock.time }, schedule: clock.schedule)
        var ready = 0
        mic.onEvent = { if $0["type"] as? String == "microphone_ready" { ready += 1 } }
        mic.start(voiceProcessing: false)
        first.changed?(); clock.advance(0.5)
        first.pcm?(Data([0, 0]))
        XCTAssertEqual(ready, 0)
        second.pcm?(Data([0, 0]))
        XCTAssertEqual(ready, 1)
        mic.stop()
    }

    func testFailedStartCannotDeliverAudioOrBecomeReady() {
        let session = Session()
        session.earlyPCM = true; session.failure = NSError(domain: "test", code: 3)
        let mic = MicrophoneCapture(makeSession: { session }, permission: { $0(true) })
        var audio = 0, ready = 0
        mic.onPCM = { _ in audio += 1 }
        mic.onEvent = { if $0["type"] as? String == "microphone_ready" { ready += 1 } }
        mic.start(voiceProcessing: false)
        XCTAssertEqual(audio, 0)
        XCTAssertEqual(ready, 0)
    }

    func testDeniedPermissionDoesNotAllocateAudioDevice() {
        var created = 0, errors = 0
        let mic = MicrophoneCapture(makeSession: { created += 1; return Session() }, permission: { $0(false) })
        mic.onEvent = { if $0["type"] as? String == "microphone_error" { errors += 1 } }
        mic.start(voiceProcessing: true)
        XCTAssertEqual(created, 0)
        XCTAssertEqual(errors, 1)
    }

    func testManualRestartIgnoresOldPermissionAndWatchdog() {
        let clock = Clock()
        var permissions: [(Bool) -> Void] = [], sessions: [Session] = []
        let mic = MicrophoneCapture(makeSession: { let session = Session(); sessions.append(session); return session },
                                    permission: { permissions.append($0) }, now: { clock.time }, schedule: clock.schedule)
        mic.start(voiceProcessing: false)
        mic.stop()
        mic.start(voiceProcessing: false)
        permissions[0](true)
        XCTAssertTrue(sessions.isEmpty)
        permissions[1](true)
        sessions[0].pcm?(Data([0, 0]))
        mic.stop()
        mic.start(voiceProcessing: false)
        permissions[2](true)
        for _ in 0..<6 { clock.advance(1); sessions[1].pcm?(Data([0, 0])) }
        XCTAssertFalse(sessions[1].stopped)
        mic.stop()
    }

    func testRouteStormIsBoundedEvenWhenEachEngineReceivesAudio() {
        let clock = Clock()
        var sessions: [Session] = [], errors = 0
        let mic = MicrophoneCapture(makeSession: { let session = Session(); sessions.append(session); return session },
                                    permission: { $0(true) }, now: { clock.time }, schedule: clock.schedule)
        mic.onEvent = { if $0["type"] as? String == "microphone_error" { errors += 1 } }
        mic.start(voiceProcessing: false)
        for _ in 0..<4 {
            sessions.last?.pcm?(Data([0, 0]))
            sessions.last?.changed?()
            clock.advance(0.5)
        }
        XCTAssertEqual(sessions.count, 4)
        XCTAssertEqual(errors, 1)
        XCTAssertTrue(sessions.allSatisfy { $0.stopped })
    }

}
