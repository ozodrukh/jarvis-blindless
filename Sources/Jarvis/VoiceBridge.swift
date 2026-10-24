import AppKit
import AVFoundation

@MainActor
final class VoiceBridge {
    var onEvent: (([String: Any]) -> Void)?
    var onDeviceChange: (() -> Void)?
    private var process: Process?
    private var input: FileHandle?
    private let writeQueue = DispatchQueue(label: "jarvis.voice.input")
    private let generationLock = NSLock()
    private let pcmWrite = DispatchSemaphore(value: 1)
    private var messageGeneration = 0
    private lazy var microphone: MicrophoneCapture = {
        let microphone = MicrophoneCapture()
        microphone.onPCM = { [weak self] data in self?.send(["type": "pcm", "data": data.base64EncodedString()]) }
        microphone.onEvent = { [weak self] event in
            guard let self else { return }
            if let type = event["type"] as? String, ["microphone_starting", "microphone_stopped"].contains(type) {
                self.send(["type": "cancel"])
            }
            self.onEvent?(event)
        }
        microphone.onDeviceChange = { [weak self] in self?.onDeviceChange?() }
        return microphone
    }()
    var voiceProcessing = true

    func start(runtime: URL, configuration: URL? = nil) throws {
        guard process == nil else { return }
        generationLock.lock(); messageGeneration = 0; generationLock.unlock()
        let executable = runtime.appendingPathComponent("venv/bin/python")
        let worker = Bundle.main.resourceURL!.appendingPathComponent("voice/worker.py")
        guard FileManager.default.isExecutableFile(atPath: executable.path),
              FileManager.default.fileExists(atPath: runtime.appendingPathComponent("models/assets.json").path) else {
            throw NSError(domain: "Jarvis", code: 1, userInfo: [NSLocalizedDescriptionKey: "Сначала запустите «Настроить Джарвиса.command» рядом с приложением. Для подготовки нужен интернет."])
        }
        let task = Process(), stdin = Pipe(), stdout = Pipe()
        task.executableURL = executable
        task.arguments = [worker.path, "--runtime", runtime.path]
        if let configuration { task.arguments? += ["--config", configuration.path] }
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["HF_HUB_OFFLINE"] = "1"
        environment["TRANSFORMERS_OFFLINE"] = "1"
        task.environment = environment
        task.standardInput = stdin; task.standardOutput = stdout
        let log = runtime.appendingPathComponent("voice.log")
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
        task.standardError = try FileHandle(forWritingTo: log)
        task.terminationHandler = { [weak self] task in
            DispatchQueue.main.async {
                guard let self, self.process === task else { return }
                self.onEvent?(["type": "stopped", "message": "Голосовой режим остановился. Можно перезапустить его кнопкой в окне."])
            }
        }
        try task.run()
        process = task; input = stdin.fileHandleForWriting
        let reader = stdout.fileHandleForReading
        DispatchQueue(label: "jarvis.voice.output").async { [weak self] in
            var buffer = Data()
            while true {
                let data = reader.availableData
                if data.isEmpty { break }
                buffer.append(data)
                while let index = buffer.firstIndex(of: 10) {
                    let line = buffer[..<index]
                    buffer.removeSubrange(...index)
                    guard let event = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
                    DispatchQueue.main.async {
                        guard let self, self.process === task else { return }
                        if let generation = event["client_generation"] as? Int {
                            self.generationLock.lock()
                            let current = self.messageGeneration
                            self.generationLock.unlock()
                            guard generation == current else { return }
                        }
                        self.onEvent?(event)
                    }
                }
            }
        }
    }

    func validateConfiguration(_ url: URL, runtime: URL, completion: @escaping (String?) -> Void) {
        let task = Process(), output = Pipe()
        task.executableURL = runtime.appendingPathComponent("venv/bin/python")
        task.arguments = [Bundle.main.resourceURL!.appendingPathComponent("voice/worker.py").path,
                          "--validate-config", "--config", url.path]
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        DispatchQueue.global(qos: .userInitiated).async {
            var message: String?
            do {
                try task.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                if task.terminationStatus != 0 || event?["type"] as? String != "configuration_valid" {
                    message = event?["message"] as? String ?? "Не удалось проверить файл настроек."
                }
            } catch { message = "Не удалось запустить проверку настроек. Сначала выполните первоначальную настройку." }
            DispatchQueue.main.async { completion(message) }
        }
    }

    func send(_ message: [String: Any]) {
        guard let handle = input else { return }
        var message = message
        generationLock.lock()
        if let kind = message["type"] as? String, ["cancel", "end_chat", "activate", "text"].contains(kind) {
            messageGeneration += 1
        }
        message["client_generation"] = messageGeneration
        generationLock.unlock()
        let gate = message["type"] as? String == "pcm" ? pcmWrite : nil
        if let gate, gate.wait(timeout: .now()) != .success { return }
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { gate?.signal(); return }
        writeQueue.async {
            defer { gate?.signal() }
            try? handle.write(contentsOf: data + Data([10]))
        }
    }

    func startMicrophone() {
        guard let process, process.isRunning else { return }
        microphone.start(voiceProcessing: voiceProcessing)
    }

    func stopMicrophone() { microphone.stop() }

    func stop() {
        stopMicrophone()
        process?.terminationHandler = nil
        if let process, process.isRunning { process.terminate() }
        try? input?.close()
        process = nil; input = nil
    }
}

@MainActor
final class SpeechOutput: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var current: AVSpeechUtterance?
    private var completion: (() -> Void)?
    private var audio: AVAudioPlayer?
    private var audioFailure: (() -> Void)?
    private let volume: Float
    var localVoice = ""
    var language = "ru-RU"
    init(volume: Float = 1) { self.volume = volume; super.init(); synthesizer.delegate = self }
    func stop() {
        current = nil; completion = nil; audioFailure = nil
        audio?.stop(); audio = nil
        synthesizer.stopSpeaking(at: .immediate)
    }
    func say(_ text: String, completion: @escaping () -> Void) -> Bool {
        stop()
        guard let voice = AVSpeechSynthesisVoice(identifier: localVoice) ?? AVSpeechSynthesisVoice(language: language) else { return false }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice; utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.volume = volume
        current = utterance; self.completion = completion
        synthesizer.speak(utterance)
        return true
    }

    func playAudio(_ data: Data, failure: (() -> Void)? = nil, completion: @escaping () -> Void) -> Bool {
        stop()
        guard data.count <= 16_000_000, let player = try? AVAudioPlayer(data: data), player.prepareToPlay() else { return false }
        player.delegate = self; player.volume = volume
        audio = player; self.completion = completion; audioFailure = failure
        guard player.play() else { audio = nil; self.completion = nil; audioFailure = nil; return false }
        return true
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.audio === player else { return }
            self.audio = nil
            let completion = self.completion, failure = self.audioFailure
            self.completion = nil; self.audioFailure = nil
            if !flag, let failure { failure() } else { completion?() }
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        audioPlayerDidFinishPlaying(player, successfully: false)
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, self.current === utterance else { return }
            self.current = nil
            let completion = self.completion; self.completion = nil; completion?()
        }
    }
}
