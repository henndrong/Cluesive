//
//  RelocalizationAttemptCoordinator.swift
//  Cluesive
//
//  Pure relocalization attempt state/guidance helpers (stationary sweep -> micro-movement).
//

import Foundation
import ARKit

enum RelocalizationAttemptCoordinator {
    struct MetricUpdateOutcome {
        let state: RelocalizationAttemptState
        let lastYaw: Float
    }

    static func initialState(now: Date = Date()) -> RelocalizationAttemptState {
        RelocalizationAttemptState(
            mode: .stationary360,
            startedAt: now,
            rotationAccumulatedDegrees: 0,
            featurePointMedianRecent: 0,
            sawRelocalizingTracking: false,
            stableNormalFrames: 0,
            timeoutSeconds: 10
        )
    }

    static func updateMetrics(
        state: RelocalizationAttemptState,
        previousYaw: Float?,
        currentYaw: Float,
        trackingState: ARCamera.TrackingState,
        recentFeatureMedian: Int
    ) -> MetricUpdateOutcome {
        var updated = state

        if let last = previousYaw {
            let delta = abs(normalizedRadians(currentYaw - last)) * 180 / .pi
            updated.rotationAccumulatedDegrees += delta
        }

        if case .limited(.relocalizing) = trackingState {
            updated.sawRelocalizingTracking = true
        }
        if case .normal = trackingState {
            updated.stableNormalFrames += 1
        } else {
            updated.stableNormalFrames = 0
        }
        updated.featurePointMedianRecent = recentFeatureMedian

        return MetricUpdateOutcome(state: updated, lastYaw: currentYaw)
    }

    static func shouldEscalateToMicroMovement(
        state: RelocalizationAttemptState?,
        localizationState: LocalizationState,
        now: Date = Date()
    ) -> Bool {
        guard let state, state.mode == .stationary360 else { return false }
        let elapsed = now.timeIntervalSince(state.startedAt)
        return state.rotationAccumulatedDegrees >= 330 &&
            elapsed >= state.timeoutSeconds &&
            state.featurePointMedianRecent >= 120 &&
            localizationState != .localized
    }

    static func escalatedMicroMovementState(
        from state: RelocalizationAttemptState,
        now: Date = Date()
    ) -> RelocalizationAttemptState {
        guard state.mode == .stationary360 else { return state }
        var updated = state
        updated.mode = .microMovementFallback
        updated.startedAt = now
        updated.timeoutSeconds = 14
        return updated
    }

    static func shouldTriggerMeshFallback(
        hasSavedMeshArtifact: Bool,
        state: RelocalizationAttemptState?,
        meshFallbackActive: Bool,
        localizationState: LocalizationState,
        now: Date = Date()
    ) -> Bool {
        guard hasSavedMeshArtifact else { return false }
        guard let state else { return false }
        guard state.mode == .microMovementFallback else { return false }
        guard !meshFallbackActive else { return false }
        guard localizationState != .localized else { return false }
        let elapsed = now.timeIntervalSince(state.startedAt)
        return elapsed >= state.timeoutSeconds || (elapsed >= 8 && state.featurePointMedianRecent >= 180)
    }

    static func currentGuidanceSnapshot(
        state: RelocalizationAttemptState?,
        localizationState: LocalizationState,
        now: Date = Date()
    ) -> RelocalizationGuidanceSnapshot? {
        guard let state else { return nil }
        let elapsed = now.timeIntervalSince(state.startedAt)
        let relocQuality = relocalizationAttemptQualityScore(state: state)

        switch state.mode {
        case .stationary360:
            let progress = min(Int(state.rotationAccumulatedDegrees.rounded()), 360)
            return RelocalizationGuidanceSnapshot(
                attemptMode: state.mode,
                attemptProgressText: "Rotation progress: \(progress)° / 360°",
                recommendedActionText: stationaryRelocPrompt(
                    rotationDegrees: state.rotationAccumulatedDegrees,
                    featureMedian: state.featurePointMedianRecent
                ),
                stationaryAttemptReadyToEscalate: shouldEscalateToMicroMovement(
                    state: state,
                    localizationState: localizationState,
                    now: now
                ),
                relocalizationQualityScore: relocQuality
            )
        case .microMovementFallback:
            return RelocalizationGuidanceSnapshot(
                attemptMode: state.mode,
                attemptProgressText: String(
                    format: "Fallback active (%.0fs elapsed). Feature median: %d",
                    elapsed,
                    state.featurePointMedianRecent
                ),
                recommendedActionText: microMovementRelocPrompt(),
                stationaryAttemptReadyToEscalate: false,
                relocalizationQualityScore: relocQuality
            )
        }
    }

    static func stationaryRelocPrompt(rotationDegrees: Float, featureMedian: Int) -> String {
        if rotationDegrees < 90 {
            return "Relocalizing (Stationary): hold position and rotate slowly. Aim at walls, corners, and furniture edges."
        }
        if featureMedian < 150 {
            return "Keep rotating, and point at textured surfaces and furniture edges to improve matching."
        }
        if rotationDegrees < 300 {
            return "Good coverage so far. Continue rotating slowly to complete a full sweep."
        }
        return "Nearly done. Finish the 360° sweep and pause briefly for a match."
    }

    static func microMovementRelocPrompt() -> String {
        "Take 1-2 small steps, pause, then rotate left/right slowly about 90°. Point at large previously scanned surfaces."
    }

    private static func relocalizationAttemptQualityScore(state: RelocalizationAttemptState) -> Float {
        var score: Float = 0
        if state.sawRelocalizingTracking { score += 0.20 }
        score += min(Float(state.stableNormalFrames) / 20, 1) * 0.35
        score += min(Float(state.featurePointMedianRecent) / 300, 1) * 0.25
        score += min(state.rotationAccumulatedDegrees / 360, 1) * 0.20
        return min(max(score, 0), 1)
    }

    private static func normalizedRadians(_ angle: Float) -> Float {
        var value = angle
        while value > .pi { value -= 2 * .pi }
        while value < -.pi { value += 2 * .pi }
        return value
    }
}
