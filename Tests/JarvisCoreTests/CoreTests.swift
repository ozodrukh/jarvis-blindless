import XCTest
@testable import JarvisCore

final class CoreTests: XCTestCase {
    func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testPartsKeepManifestOrder() throws {
        let root = try temporaryDirectory()
        let manifest = """
        {"version":1,"books":[{"id":"book","title":"Книга","files":["10.mp3","2.mp3"]}]}
        """
        try Data(manifest.utf8).write(to: root.appendingPathComponent("meta.json"))
        let library = try Library.load(from: root)
        XCTAssertEqual(library.books.first?.files, ["10.mp3", "2.mp3"])
    }

    func testManifestRejectsDuplicateIDsAndEscapingPaths() throws {
        let root = try temporaryDirectory()
        for books in [
            "[{\"id\":\"b\",\"title\":\"A\",\"files\":[\"a.mp3\"]},{\"id\":\"b\",\"title\":\"B\",\"files\":[\"b.mp3\"]}]",
            "[{\"id\":\"b\",\"title\":\"A\",\"files\":[\"../private.mp3\"]}]",
            "[{\"id\":\"b\",\"title\":\"A\",\"files\":[]}]"
        ] {
            try Data("{\"version\":1,\"books\":\(books)}".utf8).write(to: root.appendingPathComponent("meta.json"))
            XCTAssertThrowsError(try Library.load(from: root))
        }
    }

    func testSymlinkCannotEscapeLibrary() throws {
        let root = try temporaryDirectory()
        let other = try temporaryDirectory()
        try Data().write(to: other.appendingPathComponent("private.mp3"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("outside"), withDestinationURL: other)
        XCTAssertThrowsError(try Library.audioURL("outside/private.mp3", root: root))
    }

    func testProgressSurvivesRelaunchAndBookReordering() throws {
        let root = try temporaryDirectory()
        let url = root.appendingPathComponent("progress.json")
        var state = ProgressState()
        state.positions["one"] = Position(file: "part-two.mp3", seconds: 125)
        state.positions["two"] = Position(file: "start.mp3", seconds: 8)
        state.lastBookID = "one"
        try ProgressStore.save(state, to: url)
        let restored = try ProgressStore.load(from: url)
        XCTAssertEqual(restored.positions["one"]?.file, "part-two.mp3")
        XCTAssertEqual(restored.positions["one"]?.seconds, 125)
        XCTAssertEqual(restored.positions["two"]?.seconds, 8)
        XCTAssertEqual(restored.lastBookID, "one")
    }

    func testCorruptStateIsNotSilentlyReset() throws {
        let url = try temporaryDirectory().appendingPathComponent("progress.json")
        try Data("broken".utf8).write(to: url)
        XCTAssertThrowsError(try ProgressStore.load(from: url))
        XCTAssertEqual(try String(contentsOf: url), "broken")
    }

    func testUnknownActionCannotExecute() throws {
        let json = Data("{\"action\":\"run_shell\",\"reply\":\"ok\"}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(AssistantDecision.self, from: json))
    }
}
