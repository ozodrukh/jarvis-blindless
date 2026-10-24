import AVFoundation
import OSLog

private let microphoneLog = Logger(subsystem: "local.blindless.jarvis", category: "microphone")

@MainActor
protocol AudioCaptureSession: AnyObject {
    func start(voiceProcessing: Bool, pcm: @escaping (Data) -> Void, changed: @escaping () -> Void) throws -> Bool
    func stop()
}

enum AudioCaptureError: Error {
    case voiceProcessingUnavailable
}

@MainActor
final class MicrophoneCapture {
    var onEvent: (([String: Any]) -> Void)?
    var onPCM: ((Data) -> Void)?
    var onDeviceChange: (() -> Void)?
    private let makeSession: () -> AudioCaptureSession
    private let permission: (@escaping (Bool) -> Void) -> Void
    private var session: AudioCaptureSession?
    private var wanted = false
    private var generation = 0
    private var requestedProcessing = false
    private let now: () -> TimeInterval
    private let schedule: (TimeInterval, @escaping () -> Void) -> DispatchWorkItem
    private var recoveryWork: DispatchWorkItem?
    private var recoveryDeadline: TimeInterval?
    private var recoveryAttempts = 0
    private var watchdog: DispatchWorkItem?
    private var startedAt: TimeInterval = 0
    private var lastBufferAt: TimeInterval?
    private var bufferCount = 0
    private var ready = false
    private var started = false

    init(makeSession: (() -> AudioCaptureSession)? = nil,
         permission: ((@escaping (Bool) -> Void) -> Void)? = nil,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         schedule: ((TimeInterval, @escaping () -> Void) -> DispatchWorkItem)? = nil) {
        self.makeSession = makeSession ?? { EngineCaptureSession() }
        self.permission = permission ?? { MicrophoneCapture.requestPermission($0) }
        self.now = now
        self.schedule = schedule ?? { delay, action in
            let work = DispatchWorkItem(block: action)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            return work
        }
    }

    private static func requestPermission(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default: completion(false)
        }
    }

    func start(voiceProcessing: Bool) {
        guard !wanted else { return }
        wanted = true; generation += 1
        requestedProcessing = voiceProcessing
        recoveryDeadline = nil; recoveryAttempts = 0
        onEvent?(["type": "microphone_starting"])
        let id = generation
        permission { [weak self] granted in
            guard let self, self.wanted, self.generation == id else { return }
            if granted { self.begin(voiceProcessing: voiceProcessing) }
            else { self.fail("Разрешите микрофон: Системные настройки → Конфиденциальность и безопасность → Микрофон → Джарвис.") }
        }
    }

    private func begin(voiceProcessing: Bool) {
        generation += 1
        let id = generation
        ready = false; started = false; bufferCount = 0; lastBufferAt = nil; startedAt = now()
        let candidate = makeSession()
        session = candidate
        do {
            let actual = try candidate.start(voiceProcessing: voiceProcessing, pcm: { [weak self] data in
                guard let self, self.wanted, self.started, self.generation == id else { return }
                guard !data.isEmpty, data.count % 2 == 0 else { return }
                self.lastBufferAt = self.now(); self.bufferCount += 1
                if !self.ready {
                    self.ready = true
                    microphoneLog.notice("Capture ready; first buffer after \(self.now() - self.startedAt, privacy: .public) s")
                    self.onEvent?(["type": "microphone_ready"])
                }
                guard self.wanted, self.generation == id else { return }
                self.onPCM?(data)
            }, changed: { [weak self] in
                guard let self, self.wanted, self.generation == id else { return }
                self.recover()
            })
            started = true
            onEvent?(["type": "input_processing", "enabled": actual])
            microphoneLog.notice("Capture started; voice processing: \(actual, privacy: .public)")
            armWatchdog()
        } catch {
            releaseSession()
            if voiceProcessing, case AudioCaptureError.voiceProcessingUnavailable = error {
                microphoneLog.error("Voice processing unavailable; releasing engine before ordinary capture")
                onEvent?(["type": "input_processing_error", "message": "Обработка голоса недоступна. Пробую обычный захват."])
                begin(voiceProcessing: false)
            } else if recoveryDeadline != nil { recover() }
            else { fail("Микрофон недоступен: \(error.localizedDescription)") }
        }
    }

    private func armWatchdog() {
        watchdog?.cancel()
        let id = generation
        let due = min((lastBufferAt ?? startedAt) + 5, recoveryDeadline ?? .infinity)
        watchdog = schedule(max(0, due - now())) { [weak self] in
            guard let self, self.wanted, self.generation == id else { return }
            if let deadline = self.recoveryDeadline, self.now() >= deadline {
                guard self.ready, let last = self.lastBufferAt, self.now() - last < 5 else {
                    self.fail("Микрофон не передаёт звук после смены устройства. Включите микрофон снова.")
                    return
                }
                self.recoveryDeadline = nil; self.recoveryAttempts = 0
            }
            if let last = self.lastBufferAt {
                if self.now() - last >= 5 { self.recover() }
                else { self.armWatchdog() }
            } else {
                self.fail("Микрофон запущен, но аудиоданные не поступают. Проверьте устройство звука и включите микрофон снова.")
            }
        }
    }

    private func recover() {
        guard wanted else { return }
        let first = recoveryDeadline == nil
        if first { recoveryDeadline = now() + 5; recoveryAttempts = 0 }
        recoveryWork?.cancel()
        releaseSession()
        if first { onDeviceChange?() }
        guard wanted else { return }
        guard recoveryAttempts < 3, let deadline = recoveryDeadline, now() + 0.5 < deadline else {
            fail("Не удалось восстановить микрофон. Проверьте устройство звука и включите микрофон снова.")
            return
        }
        onEvent?(["type": "microphone_starting"])
        let id = generation
        recoveryWork = schedule(0.5) { [weak self] in
            guard let self, self.wanted, self.generation == id else { return }
            self.recoveryAttempts += 1
            self.begin(voiceProcessing: self.requestedProcessing)
        }
    }

    private func releaseSession() {
        generation += 1
        watchdog?.cancel(); watchdog = nil
        if session != nil {
            microphoneLog.notice("Capture released; buffers: \(self.bufferCount, privacy: .public), duration: \(self.now() - self.startedAt, privacy: .public) s")
        }
        ready = false; started = false
        let old = session; session = nil
        old?.stop()
    }

    private func fail(_ message: String) {
        microphoneLog.error("Capture failed: \(message, privacy: .public)")
        stop()
        onEvent?(["type": "microphone_error", "message": message])
    }

    func stop() {
        wanted = false
        recoveryWork?.cancel(); recoveryWork = nil
        recoveryDeadline = nil; recoveryAttempts = 0
        releaseSession()
        onEvent?(["type": "microphone_stopped"])
    }
}

@MainActor
private final class EngineCaptureSession: AudioCaptureSession {
    private var engine: AVAudioEngine?
    private var tapInstalled = false
    private var observer: NSObjectProtocol?

    func start(voiceProcessing: Bool, pcm: @escaping (Data) -> Void, changed: @escaping () -> Void) throws -> Bool {
        let engine = AVAudioEngine()
        self.engine = engine
        let node = engine.inputNode
        if node.isVoiceProcessingEnabled != voiceProcessing {
            do { try node.setVoiceProcessingEnabled(voiceProcessing) }
            catch { throw AudioCaptureError.voiceProcessingUnavailable }
        }
        let format = node.outputFormat(forBus: 0)
        microphoneLog.notice("Input format: \(format.sampleRate, privacy: .public) Hz, \(format.channelCount, privacy: .public) channels")
        guard format.sampleRate > 0, format.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: target) else {
            throw NSError(domain: "Jarvis", code: 2, userInfo: [NSLocalizedDescriptionKey: "Не найден работающий микрофон."])
        }
        // Keep at most one converted buffer waiting for the main queue.
        let delivery = DispatchSemaphore(value: 1)
        node.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            guard delivery.wait(timeout: .now()) == .success else { return }
            var queued = false
            defer { if !queued { delivery.signal() } }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16000 / format.sampleRate) + 32
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var supplied = false
            var error: NSError?
            converter.convert(to: output, error: &error) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true; status.pointee = .haveData; return buffer
            }
            guard error == nil, output.frameLength > 0, let channel = output.int16ChannelData?[0] else { return }
            let data = Data(bytes: channel, count: Int(output.frameLength) * 2)
            queued = true
            DispatchQueue.main.async {
                defer { delivery.signal() }
                pcm(data)
            }
        }
        tapInstalled = true
        engine.prepare()
        try engine.start()
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { _ in
            // Defer teardown until notification delivery has finished.
            DispatchQueue.main.async { changed() }
        }
        return node.isVoiceProcessingEnabled
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine?.stop()
        if tapInstalled { engine?.inputNode.removeTap(onBus: 0) }
        tapInstalled = false
        engine = nil
    }
}
