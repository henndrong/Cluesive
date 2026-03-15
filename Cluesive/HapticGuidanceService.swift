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
    private var engineIsRunning = false
    private var lastPatternKey = "none"
    private let isRuntimeMediaDisabled = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    func playIfNeeded(_ pattern: OrientationHapticPattern) {
        playIfNeeded(key: pattern.rawValue, pattern: hapticPattern(for: pattern))
    }

    func playIfNeeded(_ pattern: NavigationHapticPattern) {
        playIfNeeded(key: pattern.rawValue, pattern: hapticPattern(for: pattern))
    }

    private func playIfNeeded(key: String, pattern: HapticPatternSpec) {
        guard !isRuntimeMediaDisabled else { return }
        guard key != lastPatternKey else { return }
        lastPatternKey = key
        guard pattern != .none, CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            let engine = try preparedEngine()
            let player = try engine.makePlayer(with: try hapticPattern(spec: pattern))
            try player.start(atTime: 0)
        } catch {
            return
        }
    }

    func prepareIfNeeded() {
        guard !isRuntimeMediaDisabled else { return }
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            _ = try preparedEngine()
        } catch {
            return
        }
    }

    func stop() {
        lastPatternKey = "none"
    }

    private func preparedEngine() throws -> CHHapticEngine {
        if let engine, engineIsRunning {
            return engine
        }

        let engine = try engine ?? CHHapticEngine()
        engine.resetHandler = { [weak self] in
            Task { @MainActor in
                self?.engineIsRunning = false
            }
        }
        engine.stoppedHandler = { [weak self] _ in
            Task { @MainActor in
                self?.engineIsRunning = false
            }
        }
        self.engine = engine

        if !engineIsRunning {
            try engine.start()
            engineIsRunning = true
        }
        return engine
    }

    private enum HapticPatternSpec: Equatable {
        case none
        case pulse(intensity: Float, duration: TimeInterval)
    }

    private func hapticPattern(for pattern: OrientationHapticPattern) -> HapticPatternSpec {
        switch pattern {
        case .slow:
            return .pulse(intensity: 0.25, duration: 0.08)
        case .medium:
            return .pulse(intensity: 0.5, duration: 0.12)
        case .fast:
            return .pulse(intensity: 0.8, duration: 0.16)
        case .success:
            return .pulse(intensity: 1.0, duration: 0.2)
        case .none:
            return .none
        }
    }

    private func hapticPattern(for pattern: NavigationHapticPattern) -> HapticPatternSpec {
        switch pattern {
        case .walk:
            return .pulse(intensity: 0.2, duration: 0.08)
        case .approach:
            return .pulse(intensity: 0.45, duration: 0.12)
        case .turn:
            return .pulse(intensity: 0.8, duration: 0.16)
        case .pause:
            return .pulse(intensity: 0.35, duration: 0.2)
        case .success:
            return .pulse(intensity: 1.0, duration: 0.2)
        case .none:
            return .none
        }
    }

    private func hapticPattern(spec: HapticPatternSpec) throws -> CHHapticPattern {
        let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.6)
        let intensityValue: Float
        let duration: TimeInterval
        switch spec {
        case .pulse(let intensity, let eventDuration):
            intensityValue = intensity
            duration = eventDuration
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
