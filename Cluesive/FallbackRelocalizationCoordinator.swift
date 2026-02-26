//
//  FallbackRelocalizationCoordinator.swift
//  Cluesive
//
//  Pure room-signature fallback relocalization state and presentation helpers.
//

import Foundation

enum FallbackRelocalizationCoordinator {
    struct Presentation {
        let isActive: Bool
        let text: String
        let modeText: String
        let promptText: String?
        let confidenceText: String
        let guidanceOverride: String?
    }

    struct StartOutcome {
        let state: FallbackRelocalizationState?
        let presentation: Presentation?
    }

    struct ProgressOutcome {
        let state: FallbackRelocalizationState
        let presentation: Presentation?
        let shouldRunMatch: Bool
    }

    struct MatchOutcome {
        let state: FallbackRelocalizationState
        let presentation: Presentation
    }

    static func beginOutcome(
        currentState: FallbackRelocalizationState,
        hasRoomSignatureArtifact: Bool,
        hasSavedArtifact: Bool,
        now: Date = Date()
    ) -> StartOutcome? {
        guard !currentState.isActive else { return nil }

        guard hasRoomSignatureArtifact, hasSavedArtifact else {
            return StartOutcome(
                state: nil,
                presentation: Presentation(
                    isActive: false,
                    text: "Fallback Reloc: Unavailable (no room signature)",
                    modeText: "Fallback Mode: None",
                    promptText: "No saved room signature artifact. Continue ARKit relocalization or rescan/save with signature support.",
                    confidenceText: "Fallback confidence: 0%",
                    guidanceOverride: nil
                )
            )
        }

        return StartOutcome(
            state: FallbackRelocalizationState(
                isActive: true,
                mode: .roomPlanSignature,
                startedAt: now,
                scanProgressText: "Fallback scan started",
                matchResult: nil,
                failureReason: nil,
                rotationAccumulatedDegrees: 0,
                lastYaw: nil
            ),
            presentation: Presentation(
                isActive: true,
                text: "Fallback Reloc: Scanning room layout",
                modeText: "Fallback Mode: Room Signature",
                promptText: "Fallback active: hold position if safe and rotate slowly, aiming at long walls/openings/furniture.",
                confidenceText: "Fallback confidence: 0%",
                guidanceOverride: nil
            )
        )
    }

    static func updateProgress(
        state: FallbackRelocalizationState,
        currentYaw: Float,
        now: Date = Date()
    ) -> ProgressOutcome {
        var updated = state
        if let last = updated.lastYaw {
            let delta = abs(normalizedRadians(currentYaw - last)) * 180 / .pi
            updated.rotationAccumulatedDegrees += delta
        }
        updated.lastYaw = currentYaw

        let progress = Int(min(updated.rotationAccumulatedDegrees, 360).rounded())
        updated.scanProgressText = "Fallback scan progress: \(progress)° / 360°"

        let elapsed = now.timeIntervalSince(updated.startedAt)
        if updated.matchResult == nil, updated.rotationAccumulatedDegrees >= 180 || elapsed > 6 {
            return ProgressOutcome(state: updated, presentation: nil, shouldRunMatch: true)
        }

        return ProgressOutcome(
            state: updated,
            presentation: Presentation(
                isActive: true,
                text: "Fallback Reloc: Scanning room layout",
                modeText: "Fallback Mode: \(updated.mode.displayName)",
                promptText: "Fallback active: rotate slowly 180–360° and aim at long walls, openings, and large furniture.",
                confidenceText: updated.matchResult.map { "Fallback confidence: \(Int(($0.confidence * 100).rounded()))%" } ?? "Fallback confidence: 0%",
                guidanceOverride: nil
            ),
            shouldRunMatch: false
        )
    }

    static func matchFailureOutcome(state: FallbackRelocalizationState) -> MatchOutcome {
        var updated = state
        updated.failureReason = "Inconclusive room-signature match"
        updated.matchResult = nil
        return MatchOutcome(
            state: updated,
            presentation: Presentation(
                isActive: true,
                text: "Fallback Reloc: Inconclusive",
                modeText: "Fallback Mode: \(updated.mode.displayName)",
                promptText: "Fallback layout match was inconclusive. Move toward a wall/corner, repeat a slow sweep, then continue ARKit relocalization.",
                confidenceText: "Fallback confidence: 0%",
                guidanceOverride: nil
            )
        )
    }

    static func matchSuccessOutcome(
        state: FallbackRelocalizationState,
        result: RoomSignatureMatchResult
    ) -> MatchOutcome {
        var updated = state
        updated.matchResult = result

        let prompt = result.confidence >= 0.55
            ? result.recommendedPrompt
            : "Low-confidence layout hint: \(result.recommendedPrompt) If unsure, move to a wall/corner and retry."

        return MatchOutcome(
            state: updated,
            presentation: Presentation(
                isActive: true,
                text: result.confidence >= 0.55 ? "Fallback Reloc: Matched" : "Fallback Reloc: Low-confidence match",
                modeText: "Fallback Mode: Room Signature",
                promptText: prompt,
                confidenceText: "Fallback confidence: \(Int((result.confidence * 100).rounded()))%",
                guidanceOverride: prompt
            )
        )
    }

    static func resetState(now: Date = Date()) -> FallbackRelocalizationState {
        FallbackRelocalizationState(
            isActive: false,
            mode: .none,
            startedAt: now,
            scanProgressText: "Idle",
            matchResult: nil,
            failureReason: nil,
            rotationAccumulatedDegrees: 0,
            lastYaw: nil
        )
    }

    static func resetPresentation() -> Presentation {
        Presentation(
            isActive: false,
            text: "Fallback Reloc: Inactive",
            modeText: "Fallback Mode: None",
            promptText: nil,
            confidenceText: "Fallback confidence: 0%",
            guidanceOverride: nil
        )
    }

    static func shouldTriggerRoomSignatureFallback(
        hasRoomSignatureArtifact: Bool,
        relocalizationAttemptState: RelocalizationAttemptState?,
        localizationState: LocalizationState,
        fallbackIsActive: Bool,
        now: Date = Date()
    ) -> Bool {
        guard hasRoomSignatureArtifact else { return false }
        guard let state = relocalizationAttemptState else { return false }
        guard state.mode == .microMovementFallback else { return false }
        if localizationState == .localized { return false }
        if fallbackIsActive { return false }

        let elapsed = now.timeIntervalSince(state.startedAt)
        if elapsed >= state.timeoutSeconds { return true }
        if state.featurePointMedianRecent > 180 && elapsed >= 8 { return true }
        return false
    }

    static func pipelineState(meshFallbackActive: Bool, roomSignatureFallbackActive: Bool) -> String {
        if meshFallbackActive {
            return "ARKit primary + Mesh fallback"
        }
        if roomSignatureFallbackActive {
            return "ARKit primary + Room Signature fallback"
        }
        return "ARKit primary"
    }

    private static func normalizedRadians(_ angle: Float) -> Float {
        var value = angle
        while value > .pi { value -= 2 * .pi }
        while value < -.pi { value += 2 * .pi }
        return value
    }
}
