//
//  HapticGuidanceService.swift
//  Cluesive
//
//  Minimal banded haptic feedback for orientation guidance.
//

import CoreHaptics

@MainActor
final class HapticGuidanceService {
    private var engine: CHHapticEngine?
    private var lastPattern: OrientationHapticPattern = .none
    private let isRuntimeMediaDisabled = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    func playIfNeeded(_ pattern: OrientationHapticPattern) {
        guard !isRuntimeMediaDisabled else { return }
        guard pattern != lastPattern else { return }
        lastPattern = pattern
        guard pattern != .none, CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            if engine == nil {
                engine = try CHHapticEngine()
            }
            try engine?.start()
            let player = try engine?.makePlayer(with: hapticPattern(for: pattern))
            try player?.start(atTime: 0)
        } catch {
            return
        }
    }

    func stop() {
        lastPattern = .none
        engine?.stop(completionHandler: nil)
    }

    private func hapticPattern(for pattern: OrientationHapticPattern) throws -> CHHapticPattern {
        let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.6)
        let intensityValue: Float
        let duration: TimeInterval
        switch pattern {
        case .slow:
            intensityValue = 0.25
            duration = 0.08
        case .medium:
            intensityValue = 0.5
            duration = 0.12
        case .fast:
            intensityValue = 0.8
            duration = 0.16
        case .success:
            intensityValue = 1.0
            duration = 0.2
        case .none:
            intensityValue = 0
            duration = 0.01
        }
        let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: intensityValue)
        let event = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [intensity, sharpness],
            relativeTime: 0,
            duration: duration
        )
        return try CHHapticPattern(events: [event], parameters: [])
    }
}
