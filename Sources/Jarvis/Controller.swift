import AppKit
import AVFoundation
import JarvisCore

@MainActor
final class JarvisController: ObservableObject {
    let player: BookPlayer
    @Published var status = "Подготовка голосового режима…"
    @Published var ready = false
    @Published var microphoneOn = false
    @Published var lastHeard = ""
    @Published var lastReply = ""
    @Published var responseTime: Double?
    @Published var chatActive = false
    @Published var inputLevel: Double = 0
    @Published var inputDescription = "Уровень микрофона"
    @Published var configurationName = "Локальные настройки"
    @Published var configurationWarning = ""
    @Published var stageTimings: [String: String] = [:]
    @Published var silenceTimeout: Double = 15
    @Published var endPhrase = "закончили"
    private let configuration = ConfigurationSelection()
    private let voice = VoiceBridge()
    private let speech = SpeechOutput()
    private var requestID: Int?
    private var speaking = false
    private var started = false
    private var greeted = false
    private var dialogueID = 0
    private var runtime: URL?
    private var pendingSpeechCompletion: (() -> Void)?
    private var turnStarted: Date?
    private var speechThreshold = 0.0008

    init(player: BookPlayer? = nil) {
        let player = player ?? BookPlayer()
        self.player = player
        player.onChange = { [weak self] in self?.updateContext() }
        player.onNotice = { [weak self] text in self?.say(text) }
        voice.onEvent = { [weak self] event in self?.receive(event) }
        voice.onDeviceChange = { [weak self] in
            guard let self else { return }
            self.player.pause()
            self.interrupt()
            self.status = "Устройство звука изменилось. Книга на паузе."
        }
    }

    func start() {
        guard !started else { return }
        started = true
        let parent = Bundle.main.bundleURL.deletingLastPathComponent()
        let candidates = [parent.appendingPathComponent(".runtime"), parent.deletingLastPathComponent().appendingPathComponent(".runtime")]
        let runtime = candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("venv/bin/python").path) } ?? candidates[0]
        self.runtime = runtime
        let selected = ProcessInfo.processInfo.environment["JARVIS_CONFIG"].map { URL(fileURLWithPath: $0) } ?? configuration.url
        configurationName = selected?.lastPathComponent ?? "Локальные настройки · выберите файл при настройке"
        do { try voice.start(runtime: runtime, configuration: selected) }
        catch { status = error.localizedDescription; started = false }
    }

    func restartVoice() {
        interrupt(); voice.stop(); ready = false; microphoneOn = false
        started = false; greeted = false
        configurationWarning = ""; stageTimings = [:]
        status = "Перезапускаю голосовой режим…"; start()
    }

    private func updateContext() { voice.send(["type": "context", "context": player.context]) }

    func receive(_ event: [String: Any]) {
        switch event["type"] as? String {
        case "configuration":
            if let settings = event["settings"] as? [String: Any] {
                voice.voiceProcessing = (settings["audio"] as? [String: Any])?["voice_processing"] as? Bool ?? true
                speechThreshold = (settings["audio"] as? [String: Any])?["speech_threshold"] as? Double ?? 0.0008
                silenceTimeout = (settings["conversation"] as? [String: Any])?["silence_timeout_seconds"] as? Double ?? 15
                endPhrase = ((settings["conversation"] as? [String: Any])?["end_phrases"] as? [String])?.first ?? "закончили"
                speech.localVoice = settings["local_voice"] as? String ?? ""
                speech.language = settings["speech_language"] as? String ?? "ru-RU"
            }
        case "config_error": configurationWarning = event["message"] as? String ?? "Проверьте файл настроек."
        case "input_level":
            let rms = event["rms"] as? Double ?? 0
            inputLevel = min(1, max(0, (20 * log10(max(rms, 0.00001)) + 70) / 60))
            let peak = event["peak"] as? Double ?? 0
            inputDescription = peak >= 0.98 ? "Слишком громко" : (rms < speechThreshold ? "Тихо · проверьте уровень при речи" : "Микрофон слышит звук")
        case "metric":
            guard let stage = event["stage"] as? String, let id = event["id"] as? Int,
                  stage == "tts" ? id == dialogueID : id == requestID else { return }
            let provider = event["provider"] as? String ?? ""
            let elapsed = event["elapsed"] as? Double ?? 0
            let fallback = event["fallback"] as? Bool ?? false
            stageTimings[stage] = "\(provider) · \(String(format: "%.2f", elapsed)) с" + (fallback ? " · резерв" : "")
        case "speech":
            guard let id = event["id"] as? Int, id == dialogueID,
                  let completion = pendingSpeechCompletion else { return }
            pendingSpeechCompletion = nil
            if let turnStarted { responseTime = Date().timeIntervalSince(turnStarted) }
            turnStarted = nil
            var success = false
            if event["local"] as? Bool == false, let encoded = event["data"] as? String,
               encoded.count <= 22_000_000, let data = Data(base64Encoded: encoded) {
                success = speech.playAudio(data, failure: { [weak self] in
                    guard let self, self.dialogueID == id else { return }
                    self.stageTimings["tts"] = "macos · резерв после ошибки воспроизведения"
                    if !self.speech.say(self.lastReply, completion: completion) { self.speechUnavailable() }
                }, completion: completion)
                if !success { stageTimings["tts"] = "macos · резерв после ошибки воспроизведения" }
            }
            if !success { success = speech.say(lastReply, completion: completion) }
            if !success { speechUnavailable() }
        case "chat_ended": finishConversation(acknowledge: event["reason"] as? String == "command")
        case "status": status = event["message"] as? String ?? "Подготовка…"
        case "ready":
            ready = true; updateContext()
            if ProcessInfo.processInfo.environment["JARVIS_NO_MICROPHONE"] == "1" {
                status = "Готов. Микрофон выключен."
            } else { voice.startMicrophone() }
        case "microphone_starting":
            microphoneOn = true; inputLevel = 0; inputDescription = "Подключаю микрофон…"
            status = "Подключаю микрофон…"
        case "microphone_stopped":
            microphoneOn = false; inputLevel = 0; inputDescription = "Микрофон выключен"
        case "microphone_ready":
            microphoneOn = true; status = "Слушаю обращение «Джарвис»."
            if !greeted { greeted = true; say("Я готов. Можешь обратиться ко мне.", dialogue: false, remember: false) }
        case "microphone_error":
            microphoneOn = false; inputLevel = 0; inputDescription = "Микрофон недоступен"
            status = event["message"] as? String ?? "Микрофон недоступен."
        case "activated":
            dialogueID += 1
            chatActive = true; pendingSpeechCompletion = nil; stageTimings = [:]
            requestID = nil; speech.stop(); speaking = false
            player.pause(); updateContext()
            status = "Слушаю запрос…"; NSSound.beep()
        case "thinking":
            chatActive = true
            turnStarted = Date()
            requestID = event["id"] as? Int; status = "Обдумываю запрос…"
        case "decision":
            guard let id = event["id"] as? Int, id == requestID,
                  let raw = event["decision"], let data = try? JSONSerialization.data(withJSONObject: raw),
                  let decision = try? JSONDecoder().decode(AssistantDecision.self, from: data) else { return }
            requestID = nil; lastHeard = decision.heard ?? "Голосовой запрос"
            responseTime = event["elapsed"] as? Double
            do {
                let response = try player.perform(decision)
                let resume = player.isPlaying
                if resume { player.pause() }
                updateContext(); say(response, resumeBook: resume)
            } catch { say(error.localizedDescription) }
        case "error":
            if let id = event["id"] as? Int, id != requestID { return }
            requestID = nil
            let message = event["message"] as? String ?? "Не удалось обработать запрос."
            if ready { say(message) } else { status = message }
        case "stopped":
            ready = false; microphoneOn = false; started = false
            voice.stop()
            status = event["message"] as? String ?? "Голосовой режим остановился."
        case "idle":
            if !speaking { status = microphoneOn ? "Слушаю обращение «Джарвис»." : "Микрофон выключен." }
        default: break
        }
    }

    func say(_ text: String, resumeBook: Bool = false, dialogue: Bool = true, remember: Bool = true) {
        dialogueID += 1
        let generation = dialogueID
        if dialogue { chatActive = true }
        lastReply = text; speaking = true; status = "Отвечаю…"
        if remember { voice.send(["type": "tool_result", "text": text]) }
        voice.send(["type": "speaking", "value": true])
        pendingSpeechCompletion = { [weak self] in
            guard let self, self.dialogueID == generation else { return }
            self.speaking = false
            self.voice.send(["type": "speaking", "value": false])
            if resumeBook {
                self.chatActive = false
                self.voice.send(["type": "cancel"])
                do { try self.player.continuePrepared() }
                catch { self.say(error.localizedDescription); return }
            } else if dialogue && self.microphoneOn && self.chatActive {
                self.status = "Можно продолжить разговор. Чтобы закончить, скажи «\(self.endPhrase)»."
                // Let speaker reverberation decay before recording the next turn.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                    guard let self, self.dialogueID == generation, self.microphoneOn else { return }
                    self.updateContext(); self.voice.send(["type": "listen"])
                }
                return
            }
            self.status = self.microphoneOn ? "Слушаю обращение «Джарвис»." : "Микрофон выключен."
        }
        voice.send(["type": "synthesize", "id": generation, "text": text])
    }

    private func speechUnavailable() {
        pendingSpeechCompletion = nil; speaking = false; chatActive = false
        voice.send(["type": "cancel"])
        status = "Установите русский голос: Системные настройки → Универсальный доступ → Чтение и речь."
    }

    func interrupt() {
        dialogueID += 1
        chatActive = false; pendingSpeechCompletion = nil; turnStarted = nil
        requestID = nil; speech.stop(); speaking = false
        voice.send(["type": "cancel"])
        voice.send(["type": "speaking", "value": false])
    }

    func endChat() {
        voice.send(["type": "end_chat"])
        finishConversation(acknowledge: false)
    }

    private func finishConversation(acknowledge: Bool) {
        interrupt(); player.endConversation()
        status = microphoneOn ? "Разговор завершён. Слушаю обращение «Джарвис»." : "Разговор завершён. Микрофон выключен."
        if acknowledge { _ = speech.say("Разговор завершён.", completion: {}) }
    }

    func chooseConfiguration() {
        guard let runtime else { return }
        let panel = NSOpenPanel()
        panel.title = "Выберите JSON-файл настроек Джарвиса"
        panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.voice.validateConfiguration(url, runtime: runtime) { [weak self] error in
                guard let self else { return }
                if let error { self.configurationWarning = error; return }
                self.configuration.remember(url)
                self.restartVoice()
            }
        }
    }

    func listen() {
        guard ready, microphoneOn else { return }
        interrupt(); updateContext(); voice.send(["type": "activate"])
    }

    func toggleMicrophone() {
        if microphoneOn {
            interrupt(); voice.stopMicrophone(); microphoneOn = false; status = "Микрофон выключен."
        } else { voice.startMicrophone() }
    }

    func sendText(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ready, !text.isEmpty else { return }
        interrupt(); player.pause(); updateContext()
        lastHeard = text
        voice.send(["type": "text", "text": text])
    }

    func playBook(_ book: Book) {
        interrupt()
        let raw: [String: Any] = ["action": "play", "book_id": book.id, "reply": "", "heard": "Выбор книги в окне"]
        do {
            let decision = try JSONDecoder().decode(AssistantDecision.self, from: JSONSerialization.data(withJSONObject: raw))
            let reply = try player.perform(decision)
            let resume = player.isPlaying
            if resume { player.pause() }
            say(reply, resumeBook: resume)
        } catch { say(error.localizedDescription) }
    }

    func chooseLibrary() {
        let panel = NSOpenPanel()
        panel.title = "Выберите папку audiobooks с файлом meta.json"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                guard let self else { return }
                do { try self.player.loadLibrary(url); self.say("Библиотека загружена. Книг: \(self.player.books.count).") }
                catch { self.say(error.localizedDescription) }
            }
        }
    }

    func pauseBook() { player.pause(); interrupt(); say("Книга на паузе.") }
    func close() { player.onNotice = nil; player.close(); speech.stop(); voice.stop() }
}
