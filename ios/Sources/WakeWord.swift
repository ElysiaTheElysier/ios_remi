import AVFoundation
import Porcupine

// Dedicated local keyword detection: no continuous speech/transcript upload.
@MainActor
final class WakeWord {
    private var engine: PorcupineManager?
    private(set) var listening = false
    var detected: (() -> Void)?
    var failed: (() -> Void)?
    func configure(key: String, modelURL: URL) throws {
        shutdown()
        engine = try PorcupineManager(accessKey: key, keywordPath: modelURL.path, sensitivity: 0.5,
            onDetection: { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.listening else { return }
                    self.pause(); self.detected?()
                }
            }, errorCallback: { [weak self] _ in
                Task { @MainActor in self?.pause(); self?.failed?() }
            })
    }
    func resume() throws {
        guard let engine else { throw ClientError(message: "Cần model Hey Remi dành cho iOS và AccessKey hợp lệ.") }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)
        try engine.start(); listening = true
    }
    func pause() { listening = false; try? engine?.stop() }
    func shutdown() { pause(); try? engine?.delete(); engine = nil }
}

// Conservative end-of-command gate; microphone levels are never logged or persisted.
struct VoiceEndpoint {
    enum Decision: Equatable { case wait, submit, empty }
    private var heardSpeech = false
    private var lastVoice = 0.0
    mutating func evaluate(elapsed: Double, db: Float) -> Decision {
        if elapsed >= 0.4 && db > -38 { heardSpeech = true; lastVoice = elapsed }
        if heardSpeech && (elapsed - lastVoice >= 1.5 || elapsed >= 30) { return .submit }
        if !heardSpeech && elapsed >= 8 { return .empty }
        return .wait
    }
}
