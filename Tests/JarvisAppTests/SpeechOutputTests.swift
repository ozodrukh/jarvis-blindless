import AVFoundation
import XCTest
@testable import Jarvis

@MainActor
final class SpeechOutputTests: XCTestCase {
    func testConfiguredFormatsProduceNativePlayableAudioWithSignal() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let python = root.appendingPathComponent(".runtime/venv/bin/python")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw XCTSkip("Prepare the Python runtime to check real TTS decoders")
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let process = Process()
        process.executableURL = python
        process.currentDirectoryURL = root
        process.arguments = ["-c", """
        import sys
        from pathlib import Path
        sys.path.insert(0, 'voice')
        from configuration import load_config
        from providers import _speech_audio
        fixtures = Path('tests/fixtures/tts')
        for name, mime in [('mp3','audio/mpeg'), ('pcm','audio/pcm'), ('opus','audio/ogg'),
                           ('wav','audio/wav'), ('flac','audio/flac'), ('aac','audio/aac')]:
            settings = load_config()['tts']
            settings['response_format'] = name
            audio = _speech_audio((fixtures / f'tone.{name}').read_bytes(), mime, settings, lambda: False, 16000000)
            suffix = 'wav' if name in ('pcm', 'opus') else name
            (Path(sys.argv[1]) / f'{name}.{suffix}').write_bytes(audio)
        """, temporary.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        for name in ["mp3", "pcm", "opus", "wav", "flac", "aac"] {
            let suffix = ["pcm", "opus"].contains(name) ? "wav" : name
            let url = temporary.appendingPathComponent("\(name).\(suffix)")
            let data = try Data(contentsOf: url)
            let player = try AVAudioPlayer(data: data)
            XCTAssertTrue(player.prepareToPlay(), name)
            XCTAssertGreaterThanOrEqual(player.duration, 0.24, name)
            XCTAssertLessThan(player.duration, 0.5, name)
            let file = try AVAudioFile(forReading: url)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                       frameCapacity: AVAudioFrameCount(file.length)))
            try file.read(into: buffer)
            let channel = try XCTUnwrap(buffer.floatChannelData?[0])
            let samples = UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
            XCTAssertGreaterThan(samples.map { abs($0) }.max() ?? 0, 0.01, name)
            XCTAssertEqual(file.processingFormat.channelCount, 1, name)
        }
    }
}
