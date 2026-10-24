import XCTest
import JarvisCore
@testable import Jarvis

@MainActor
final class PlayerTests: XCTestCase {
    private func fixture(seconds: Double = 2) throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        // Real silent PCM files exercise AVAudioPlayer without audible output.
        let count = UInt32(seconds * 16000) * 2
        var wav = Data("RIFF".utf8)
        func number<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { wav.append(contentsOf: $0) }
        }
        number(UInt32(36) + count); wav.append(Data("WAVEfmt ".utf8)); number(UInt32(16))
        number(UInt16(1)); number(UInt16(1)); number(UInt32(16000)); number(UInt32(32000))
        number(UInt16(2)); number(UInt16(16)); wav.append(Data("data".utf8)); number(count)
        wav.append(Data(repeating: 0, count: Int(count)))
        for name in ["one.wav", "two.wav"] { try wav.write(to: root.appendingPathComponent(name)) }
        try Data("{\"version\":1,\"books\":[{\"id\":\"demo\",\"title\":\"Проверка\",\"files\":[\"one.wav\",\"two.wav\"]}]}".utf8).write(to: root.appendingPathComponent("meta.json"))
        return (root, root.appendingPathComponent("progress.json"))
    }

    private func decision(_ action: String, heard: String = "") throws -> AssistantDecision {
        let data = try JSONSerialization.data(withJSONObject: ["action": action, "reply": "", "heard": heard])
        return try JSONDecoder().decode(AssistantDecision.self, from: data)
    }

    func testResumeRestoresRealPlayerPositionAfterRelaunch() async throws {
        let (root, url) = try fixture()
        var state = ProgressState(); state.libraryPath = root.path; state.lastBookID = "demo"
        try ProgressStore.save(state, to: url)
        let first = BookPlayer(stateURL: url, volume: 0)
        _ = try first.perform(decision("resume"))
        try await Task.sleep(nanoseconds: 250_000_000)
        first.pause()
        let before = try ProgressStore.load(from: url).positions["demo"]!
        first.close()
        XCTAssertGreaterThan(before.seconds, 0.1)
        let second = BookPlayer(stateURL: url, volume: 0)
        defer { second.close() }
        _ = try second.perform(decision("resume"))
        second.pause()
        let after = try ProgressStore.load(from: url).positions["demo"]!
        XCTAssertEqual(after.file, before.file)
        XCTAssertEqual(after.seconds, before.seconds, accuracy: 0.1)
    }

    func testRestartNeedsAnExplicitSecondTurn() async throws {
        let (root, url) = try fixture()
        var state = ProgressState()
        state.libraryPath = root.path; state.lastBookID = "demo"
        state.positions["demo"] = Position(file: "two.wav", seconds: 1)
        try ProgressStore.save(state, to: url)
        let player = BookPlayer(stateURL: url, volume: 0)
        defer { player.close() }
        _ = try player.perform(decision("restart"))
        XCTAssertEqual(try ProgressStore.load(from: url).positions["demo"]?.seconds, 1)
        _ = try player.perform(decision("confirm", heard: "нет"))
        XCTAssertEqual(try ProgressStore.load(from: url).positions["demo"]?.seconds, 1)
        _ = try player.perform(decision("restart"))
        _ = try player.perform(decision("restart", heard: "Джарвис, да"))
        player.pause()
        let restored = try ProgressStore.load(from: url)
        XCTAssertEqual(restored.positions["demo"]?.file, "one.wav")
        XCTAssertLessThan(restored.positions["demo"]!.seconds, 0.5)
    }

    func testPlayerAdvancesToNextFileAndMarksBookFinished() async throws {
        let (root, url) = try fixture(seconds: 0.15)
        var state = ProgressState(); state.libraryPath = root.path; state.lastBookID = "demo"
        try ProgressStore.save(state, to: url)
        let player = BookPlayer(stateURL: url, volume: 0)
        defer { player.close() }
        _ = try player.perform(decision("resume"))
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let restored = try ProgressStore.load(from: url)
        XCTAssertEqual(restored.positions["demo"]?.file, "two.wav")
        XCTAssertEqual(restored.positions["demo"]?.finished, true)
        XCTAssertFalse(player.isPlaying)
    }

    func testMissingFirstFileDoesNotEraseSavedPosition() async throws {
        let (root, url) = try fixture()
        var state = ProgressState(); state.libraryPath = root.path; state.lastBookID = "demo"
        state.positions["demo"] = Position(file: "two.wav", seconds: 1)
        try ProgressStore.save(state, to: url)
        try FileManager.default.removeItem(at: root.appendingPathComponent("one.wav"))
        let player = BookPlayer(stateURL: url, volume: 0)
        defer { player.close() }
        _ = try player.perform(decision("restart"))
        XCTAssertThrowsError(try player.perform(decision("confirm", heard: "да")))
        let restored = try ProgressStore.load(from: url)
        XCTAssertEqual(restored.positions["demo"], Position(file: "two.wav", seconds: 1))
    }

    func testEndingConversationClearsRestartWithoutChangingSavedPosition() throws {
        let (root, url) = try fixture()
        var state = ProgressState(); state.libraryPath = root.path; state.lastBookID = "demo"
        state.positions["demo"] = Position(file: "two.wav", seconds: 1)
        try ProgressStore.save(state, to: url)
        let player = BookPlayer(stateURL: url, volume: 0)
        defer { player.close() }
        _ = try player.perform(decision("restart"))
        XCTAssertEqual(player.context["pending_restart"] as? String, "demo")
        player.endConversation()
        let reply = try player.perform(decision("confirm", heard: "да"))
        XCTAssertTrue(reply.contains("устарело"))
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(try ProgressStore.load(from: url).positions["demo"], Position(file: "two.wav", seconds: 1))
    }
}
