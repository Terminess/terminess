import AVFoundation
import Speech
import SwiftUI

@MainActor
final class Dictation: ObservableObject {
    @Published private(set) var listening = false
    @Published private(set) var problem: String?
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var base = ""

    func start(appendingTo text: String, update: @escaping (String) -> Void) {
        problem = nil
        base = text.isEmpty || text.hasSuffix(" ") ? text : text + " "
        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor in
                guard status == .authorized else { self.problem = "Allow speech recognition in Settings to talk to Terminess."; return }
                AVAudioApplication.requestRecordPermission { granted in
                    Task { @MainActor in
                        guard granted else { self.problem = "Allow the microphone in Settings to talk to Terminess."; return }
                        self.begin(update: update)
                    }
                }
            }
        }
    }

    private func begin(update: @escaping (String) -> Void) {
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else { problem = "Speech recognition isn't available right now."; return }
        guard recognizer.supportsOnDeviceRecognition else {
            problem = "Dictation needs on-device speech recognition for your language."
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            req.requiresOnDeviceRecognition = true
            request = req
            let input = engine.inputNode
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in req.append(buffer) }
            engine.prepare()
            try engine.start()
            listening = true
            let base = self.base
            task = recognizer.recognitionTask(with: req) { result, error in
                Task { @MainActor in
                    if let result { update(base + result.bestTranscription.formattedString) }
                    if error != nil || result?.isFinal == true { self.stop() }
                }
            }
        } catch {
            problem = "Couldn't start the microphone."
            stop()
        }
    }

    func stop() {
        guard listening || task != nil else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        listening = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
