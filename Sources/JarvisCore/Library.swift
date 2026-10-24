import Foundation

public struct JarvisError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct Book: Codable, Identifiable, Equatable {
    public let id: String
    public let title: String
    public let author: String?
    public let aliases: [String]?
    public let files: [String]
}

public struct Library: Decodable {
    public let version: Int
    public let books: [Book]

    public static func load(from root: URL) throws -> Library {
        let url = root.appendingPathComponent("meta.json")
        let library: Library
        do { library = try JSONDecoder().decode(Library.self, from: Data(contentsOf: url)) }
        catch { throw JarvisError("Не удалось прочитать meta.json: \(error.localizedDescription)") }
        guard library.version == 1 else { throw JarvisError("Нужен формат библиотеки версии 1.") }
        var ids = Set<String>()
        for book in library.books {
            guard !book.id.isEmpty, !book.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !book.files.isEmpty, ids.insert(book.id).inserted,
                  Set(book.files).count == book.files.count else {
                throw JarvisError("У каждой книги нужны уникальный id, название и непустой список разных файлов.")
            }
            for file in book.files { _ = try audioURL(file, root: root) }
        }
        return library
    }

    public static func audioURL(_ path: String, root: URL) throws -> URL {
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let result = base.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"),
              !path.split(separator: "/").contains(".."),
              result.path.hasPrefix(base.path + "/") else {
            throw JarvisError("Файл книги должен находиться внутри папки audiobooks.")
        }
        return result
    }
}

public struct Position: Codable, Equatable {
    public var file: String
    public var seconds: Double
    public var finished: Bool
    public init(file: String, seconds: Double, finished: Bool = false) {
        self.file = file; self.seconds = seconds; self.finished = finished
    }
}

public struct ProgressState: Codable {
    public var version = 1
    public var libraryPath: String?
    public var lastBookID: String?
    public var positions: [String: Position] = [:]
    public init() {}
}

public enum ProgressStore {
    public static func load(from url: URL) throws -> ProgressState {
        guard FileManager.default.fileExists(atPath: url.path) else { return ProgressState() }
        let state = try JSONDecoder().decode(ProgressState.self, from: Data(contentsOf: url))
        guard state.version == 1, state.positions.values.allSatisfy({ $0.seconds.isFinite && $0.seconds >= 0 && $0.seconds < Double(Int.max) }) else {
            throw JarvisError("Файл сохранений повреждён. Он оставлен без изменений.")
        }
        return state
    }

    public static func save(_ state: ProgressState, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
    }
}

public enum AssistantAction: String, Codable {
    case chat, play, pause, resume, restart, confirm, cancel
    case listBooks = "list_books"
    case whereStopped = "where_stopped"
    case lastBook = "last_book"
}

public struct AssistantDecision: Codable {
    public let action: AssistantAction
    public let bookID: String?
    public let reply: String
    public let heard: String?
    public let page: Int?
    enum CodingKeys: String, CodingKey {
        case action, reply, heard, page
        case bookID = "book_id"
    }
}
