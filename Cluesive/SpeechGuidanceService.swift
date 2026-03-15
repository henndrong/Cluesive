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
    private var audioSessionConfigured = false
    private let reminderInterval: TimeInterval = 6.0
    private var lastPrompt: String?
    private var lastSpokenAt: Date = .distantPast
    private let isRuntimeMediaDisabled = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    func speakIfNeeded(_ snapshot: OrientationGuidanceSnapshot, now: Date = Date()) {
        speakIfNeeded(promptText: snapshot.promptText, now: now)
    }

    func speakIfNeeded(_ snapshot: NavigationGuidanceSnapshot, now: Date = Date()) {
        speakIfNeeded(promptText: snapshot.promptText, now: now)
    }

    func speakIfNeeded(promptText: String, now: Date = Date()) {
        guard !isRuntimeMediaDisabled else { return }
        guard !promptText.isEmpty else { return }
        let synthesizer = preparedSynthesizer()
        let isReminder = promptText == lastPrompt
        if isReminder {
            guard now.timeIntervalSince(lastSpokenAt) >= reminderInterval else { return }
            guard !synthesizer.isSpeaking else { return }
        } else if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        let utterance = AVSpeechUtterance(string: promptText)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
        lastPrompt = promptText
        lastSpokenAt = now
    }

    func prepareIfNeeded() {
        guard !isRuntimeMediaDisabled else { return }
        _ = preparedSynthesizer()
    }

    func stop() {
        synthesizer?.stopSpeaking(at: .immediate)
        lastPrompt = nil
        lastSpokenAt = .distantPast
    }

    private func preparedSynthesizer() -> AVSpeechSynthesizer {
        configureAudioSessionIfNeeded()
        let synthesizer = self.synthesizer ?? AVSpeechSynthesizer()
        self.synthesizer = synthesizer
        return synthesizer
    }

    private func configureAudioSessionIfNeeded() {
        guard !audioSessionConfigured else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
            audioSessionConfigured = true
        } catch {
            return
        }
    }
}
