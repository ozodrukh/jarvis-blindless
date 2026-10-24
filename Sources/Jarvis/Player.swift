import AppKit
import AVFoundation
import JarvisCore

@MainActor
final class BookPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var books: [Book] = []
    @Published private(set) var currentID: String?
    @Published private(set) var isPlaying = false
    @Published private(set) var summary = "Выберите папку с книгами."
    @Published private(set) var problem = ""
    private(set) var root: URL?
    private var state = ProgressState()
    private var storageAvailable = true
    private var audio: AVAudioPlayer?
    private var partIndex = 0
    private var timer: Timer?
    private var pendingRestart: (id: String, time: Date)?
    private let volume: Float
    let stateURL: URL
    var onChange: (() -> Void)?
    var onNotice: ((String) -> Void)?

    init(stateURL explicitStateURL: URL? = nil, volume: Float = 1) {
        let override = ProcessInfo.processInfo.environment["JARVIS_STATE_DIR"].map { URL(fileURLWithPath: $0) }
        let folder = override ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Джарвис")
        stateURL = explicitStateURL ?? folder.appendingPathComponent("progress.json")
        self.volume = volume
        super.init()
        do {
            state = try ProgressStore.load(from: stateURL)
            if let path = state.libraryPath { try loadLibrary(URL(fileURLWithPath: path)) }
        } catch {
            if FileManager.default.fileExists(atPath: stateURL.path) {
                // A missing library is recoverable; corrupt progress must not be overwritten.
                do { _ = try ProgressStore.load(from: stateURL) }
                catch { storageAvailable = false }
            }
            problem = error.localizedDescription
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in if self?.isPlaying == true { self?.checkpoint() } }
        }
    }

    func loadLibrary(_ url: URL) throws {
        let library = try Library.load(from: url)
        pause()
        books = library.books; root = url; currentID = nil; audio = nil
        state.libraryPath = url.path
        if storageAvailable { try save() }
        summary = books.isEmpty ? "В библиотеке пока нет книг." : "Книг в библиотеке: \(books.count)."
        problem = ""
        onChange?()
    }

    private func save() throws {
        guard storageAvailable else { throw JarvisError("Не удалось прочитать сохранения. Нужна помощь с файлом progress.json; он оставлен без изменений.") }
        try ProgressStore.save(state, to: stateURL)
    }

    @discardableResult
    func checkpoint() -> Bool {
        guard let id = currentID, let audio, let book = books.first(where: { $0.id == id }) else { return true }
        guard state.positions[id]?.finished != true else { return true }
        state.positions[id] = Position(file: book.files[partIndex], seconds: audio.currentTime,
            finished: state.positions[id]?.finished ?? false)
        do { try save() }
        catch {
            audio.pause(); isPlaying = false
            let message = "Не удалось сохранить место. Книга остановлена: \(error.localizedDescription)"
            if problem != message { problem = message; onNotice?(message) }
            return false
        }
        updateSummary()
        return true
    }

    func pause() {
        audio?.pause(); isPlaying = false
        checkpoint(); onChange?()
    }

    func continuePrepared() throws {
        guard let audio, audio.play() else { throw JarvisError("Не удалось включить звук книги.") }
        isPlaying = true; updateSummary(); onChange?()
    }

    private func book(_ id: String?) throws -> Book {
        guard let id = id ?? currentID ?? state.lastBookID,
              let book = books.first(where: { $0.id == id }) else {
            throw JarvisError("Выбери книгу. Можно сказать: список книг.")
        }
        return book
    }

    private func start(_ book: Book, fromStart: Bool = false) throws -> String {
        guard storageAvailable else { try save(); return "" }
        guard let root else { throw JarvisError("Сначала нужно выбрать папку с книгами.") }
        pause()
        let saved = fromStart ? nil : state.positions[book.id]
        if saved?.finished == true {
            pendingRestart = (book.id, Date())
            return "Книга «\(book.title)» уже закончена. Начать сначала? Скажи да или отмена."
        }
        let index: Int
        if let saved {
            guard let found = book.files.firstIndex(of: saved.file) else {
                throw JarvisError("Сохранённой части нет в списке файлов. Проверь библиотеку или попроси начать книгу сначала.")
            }
            index = found
        } else { index = 0 }
        let url = try Library.audioURL(book.files[index], root: root)
        guard FileManager.default.fileExists(atPath: url.path) else { throw JarvisError("Файл книги «\(book.title)» отсутствует: \(book.files[index]).") }
        let prepared = try AVAudioPlayer(contentsOf: url)
        prepared.volume = volume
        guard prepared.prepareToPlay() else { throw JarvisError("Не удалось прочитать аудиофайл.") }
        prepared.delegate = self
        prepared.currentTime = min(saved?.seconds ?? 0, max(0, prepared.duration - 0.05))
        guard prepared.play() else { throw JarvisError("Не удалось воспроизвести аудиофайл.") }
        audio = prepared; partIndex = index; currentID = book.id; isPlaying = true
        state.lastBookID = book.id
        state.positions[book.id] = Position(file: book.files[index], seconds: prepared.currentTime)
        pendingRestart = nil; problem = ""
        guard checkpoint() else { throw JarvisError(problem) }
        onChange?()
        return fromStart ? "Начинаю «\(book.title)» сначала." : "Продолжаю «\(book.title)». Часть \(index + 1)."
    }

    private func confirmationIntent(_ text: String) -> AssistantAction? {
        var words = text.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
        if let first = words.first, ["джарвис", "джарвиз", "жарвис", "jarvis"].contains(first) { words.removeFirst() }
        let phrase = words.joined(separator: " ")
        if ["да", "давай", "да начинай", "подтверждаю", "да подтверждаю", "начинай сначала", "да сначала", "да начни сначала"].contains(phrase) { return .confirm }
        if ["нет", "отмена", "не надо", "не начинай", "нет не надо", "нет отмена"].contains(phrase) { return .cancel }
        return nil
    }

    func perform(_ decision: AssistantDecision) throws -> String {
        var action = decision.action
        // Resolve explicit confirmation from the transcript even if the model
        // labels the short answer as chat; the pending request remains required.
        if pendingRestart != nil, let intent = confirmationIntent(decision.heard ?? "") { action = intent }
        switch action {
        case .chat: return decision.reply
        case .pause: pause(); return "Книга на паузе."
        case .play: return try start(book(decision.bookID))
        case .resume: return try start(book(nil))
        case .listBooks:
            guard !books.isEmpty else { return "В библиотеке пока нет книг. Попроси помочь добавить книги в папку audiobooks." }
            let page = min(max(0, decision.page ?? 0), (books.count - 1) / 5)
            let start = page * 5
            let items = books.dropFirst(start).prefix(5).enumerated().map { "\(start + $0.offset + 1). \($0.element.title)." }.joined(separator: " ")
            return items + (start + 5 < books.count ? " Чтобы услышать дальше, попроси следующую страницу списка." : "")
        case .lastBook:
            guard let id = state.lastBookID, let book = books.first(where: { $0.id == id }) else { return "Ты ещё не слушал книги из этой библиотеки." }
            return "Последняя книга — «\(book.title)». Можно сказать: продолжи книгу."
        case .whereStopped:
            let book = try book(decision.bookID)
            guard let position = state.positions[book.id] else { return "Ты ещё не начинал «\(book.title)»." }
            if position.finished { return "Книга «\(book.title)» закончена." }
            let part = book.files.firstIndex(of: position.file).map { String($0 + 1) } ?? "изменена в библиотеке"
            return "«\(book.title)». Часть \(part), \(Int(position.seconds) / 60) минут \(Int(position.seconds) % 60) секунд от начала части."
        case .restart:
            let book = try book(decision.bookID)
            pendingRestart = (book.id, Date()); onChange?()
            return "Начать «\(book.title)» сначала? Скажи да или отмена."
        case .confirm:
            guard let pendingRestart, Date().timeIntervalSince(pendingRestart.time) < 30 else {
                self.pendingRestart = nil; onChange?()
                return "Подтверждение устарело. Попроси начать сначала ещё раз."
            }
            guard confirmationIntent(decision.heard ?? "") == .confirm else { return "Чтобы начать сначала, скажи да. Чтобы сохранить место — отмена." }
            return try start(book(pendingRestart.id), fromStart: true)
        case .cancel:
            pendingRestart = nil; onChange?(); return "Отменено. Место в книге сохранено."
        }
    }

    var context: [String: Any] {
        let positions = state.positions.mapValues { ["file": $0.file, "seconds": $0.seconds, "finished": $0.finished] as [String: Any] }
        return ["books": books.enumerated().map { ["id": $0.element.id, "title": $0.element.title, "number": $0.offset + 1, "author": $0.element.author ?? "", "aliases": $0.element.aliases ?? []] as [String: Any] },
            "current_book_id": currentID as Any? ?? NSNull(), "last_book_id": state.lastBookID as Any? ?? NSNull(),
            "is_playing": isPlaying, "positions": positions,
            "pending_restart": pendingRestart.flatMap { Date().timeIntervalSince($0.time) < 30 ? $0.id : nil } as Any? ?? NSNull()]
    }

    private func updateSummary() {
        guard let id = currentID, let book = books.first(where: { $0.id == id }), let audio else { return }
        let seconds = Int(audio.currentTime)
        summary = "\(book.title) · Часть \(partIndex + 1) из \(book.files.count) · \(seconds / 60):\(String(format: "%02d", seconds % 60)) · \(isPlaying ? "Играет" : "Пауза")"
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.audio === player, let id = self.currentID,
                  let book = self.books.first(where: { $0.id == id }), let root = self.root else { return }
            do {
                guard flag else { throw JarvisError("Не удалось дочитать часть книги.") }
                self.state.positions[id] = Position(file: book.files[self.partIndex], seconds: player.duration)
                if self.partIndex + 1 < book.files.count {
                    let next = self.partIndex + 1
                    let prepared = try AVAudioPlayer(contentsOf: Library.audioURL(book.files[next], root: root))
                    prepared.volume = self.volume
                    prepared.delegate = self
                    guard prepared.play() else { throw JarvisError("Не удалось открыть следующую часть.") }
                    self.audio = prepared; self.partIndex = next; self.isPlaying = true
                    self.state.positions[id] = Position(file: book.files[next], seconds: 0)
                } else {
                    self.isPlaying = false
                    self.state.positions[id] = Position(file: book.files[self.partIndex], seconds: player.duration, finished: true)
                    self.onNotice?("Книга «\(book.title)» закончена.")
                }
                try self.save(); self.updateSummary(); self.onChange?()
            } catch {
                self.audio = nil; self.isPlaying = false; self.problem = error.localizedDescription
                self.summary = "Книга остановлена."
                try? self.save()
                self.onNotice?(error.localizedDescription)
            }
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.audio === player else { return }
            self.audio = nil; self.isPlaying = false; self.summary = "Книга остановлена."
            self.problem = "Ошибка чтения аудиофайла. Сохранённое место оставлено без изменений."
            self.onNotice?(self.problem)
        }
    }

    func close() { pause(); timer?.invalidate() }

    func endConversation() { pendingRestart = nil; onChange?() }
}
