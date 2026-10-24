import XCTest
import JarvisCore
@testable import Jarvis

@MainActor
final class ConversationTests: XCTestCase {
    private func controller() -> JarvisController {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return JarvisController(player: BookPlayer(stateURL: folder.appendingPathComponent("progress.json"), volume: 0))
    }

    func testEndChatInvalidatesPendingDecisionAndLateSpeech() {
        let app = controller()
        app.ready = true
        app.receive(["type": "activated"])
        app.receive(["type": "thinking", "id": 7])
        app.endChat()
        app.receive(["type": "decision", "id": 7, "decision":
            ["action": "chat", "reply": "Старый ответ", "heard": "старый вопрос"]])
        app.receive(["type": "speech", "id": -1, "local": true])
        XCTAssertFalse(app.chatActive)
        XCTAssertEqual(app.lastReply, "")
        app.close()
    }

    func testNewActivationAfterEndAllowsFreshDecision() {
        let app = controller()
        app.ready = true
        app.endChat()
        app.receive(["type": "activated"])
        app.receive(["type": "thinking", "id": 9])
        app.receive(["type": "decision", "id": 9, "decision":
            ["action": "chat", "reply": "Новый ответ", "heard": "новый вопрос"]])
        XCTAssertTrue(app.chatActive)
        XCTAssertEqual(app.lastReply, "Новый ответ")
        app.close()
    }

    func testInvalidRemoteAudioIsRejectedBeforePlayback() {
        let output = SpeechOutput(volume: 0)
        // AVAudioPlayer rejects this before playback; no model/action is involved.
        XCTAssertFalse(output.playAudio(Data("invalid".utf8), completion: {}))
        output.stop()
    }
    func testConnectingMicrophoneCanBeCancelledAndClearsOldLevel() {
        let app = controller()
        app.ready = true
        app.receive(["type": "input_level", "rms": 0.1, "peak": 0.2])
        XCTAssertGreaterThan(app.inputLevel, 0)
        app.receive(["type": "microphone_starting"])
        XCTAssertTrue(app.microphoneOn)
        XCTAssertEqual(app.inputLevel, 0)
        app.toggleMicrophone()
        XCTAssertFalse(app.microphoneOn)
        XCTAssertEqual(app.inputLevel, 0)
        app.close()
    }

    func testMicrophoneFailureClearsLevelAndShowsRetryableError() {
        let app = controller()
        app.receive(["type": "input_level", "rms": 0.1, "peak": 0.2])
        app.receive(["type": "microphone_error", "message": "Нет аудиобуферов"])
        XCTAssertFalse(app.microphoneOn)
        XCTAssertEqual(app.inputLevel, 0)
        XCTAssertEqual(app.status, "Нет аудиобуферов")
        app.close()
    }

}
