//
//  SpeechGuidanceService.swift
//  Cluesive
//
//  Minimal rate-limited speech output for orientation guidance.
//

import AVFoundation

@MainActor
final class SpeechGuidanceService {
    private var synthesizer: AVSpeechSynthesizer?
    private let minimumRepeatInterval: TimeInterval = 1.5
    private var lastPrompt: String?
    private var lastSpokenAt: Date = .distantPast
    private let isRuntimeMediaDisabled = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    func speakIfNeeded(_ snapshot: OrientationGuidanceSnapshot, now: Date = Date()) {
        guard !isRuntimeMediaDisabled else { return }
        guard !snapshot.promptText.isEmpty else { return }
        let shouldSpeak = snapshot.promptText != lastPrompt || now.timeIntervalSince(lastSpokenAt) >= minimumRepeatInterval
        guard shouldSpeak else { return }
        let synthesizer = self.synthesizer ?? AVSpeechSynthesizer()
        self.synthesizer = synthesizer
        let utterance = AVSpeechUtterance(string: snapshot.promptText)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
        lastPrompt = snapshot.promptText
        lastSpokenAt = now
    }

    func stop() {
        synthesizer?.stopSpeaking(at: .immediate)
        synthesizer = nil
        lastPrompt = nil
        lastSpokenAt = .distantPast
    }
}
