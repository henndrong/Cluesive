//
//  LocalizationReadinessCoordinator.swift
//  Cluesive
//
//  Pure readiness gate for orientation and route start actions.
//

import ARKit

enum LocalizationReadinessCoordinator {
    static let requiredConfidence: Float = 0.70

    struct Inputs {
        let appLocalizationState: AppLocalizationState
        let latestLocalizationConfidence: Float
        let acceptedMeshAlignmentConfidence: Float?
        let isPoseStable: Bool
        let hasPose: Bool
        let trackingState: ARCamera.TrackingState
    }

    static func snapshot(inputs: Inputs) -> LocalizationReadinessSnapshot {
        let effectiveConfidence = max(inputs.latestLocalizationConfidence, inputs.acceptedMeshAlignmentConfidence ?? 0)
        guard inputs.hasPose else {
            return LocalizationReadinessSnapshot(
                state: .notReady,
                confidence: effectiveConfidence,
                reason: "No current pose",
                recommendedPrompt: "Not aligned yet. Scan walls and corners slowly."
            )
        }

        guard inputs.appLocalizationState.isUsableForNavigation else {
            return LocalizationReadinessSnapshot(
                state: .notReady,
                confidence: effectiveConfidence,
                reason: "App localization not usable yet",
                recommendedPrompt: "Not aligned yet. Scan walls and corners slowly."
            )
        }

        if case .limited = inputs.trackingState {
            return LocalizationReadinessSnapshot(
                state: .recovering,
                confidence: effectiveConfidence,
                reason: "Tracking limited",
                recommendedPrompt: "Alignment is weak. Re-scan nearby stable walls."
            )
        }

        guard inputs.isPoseStable else {
            return LocalizationReadinessSnapshot(
                state: .recovering,
                confidence: effectiveConfidence,
                reason: "Heading unstable",
                recommendedPrompt: "Hold still. Waiting for stable heading."
            )
        }

        guard effectiveConfidence >= requiredConfidence else {
            return LocalizationReadinessSnapshot(
                state: .recovering,
                confidence: effectiveConfidence,
                reason: "Confidence below threshold",
                recommendedPrompt: "Alignment is weak. Re-scan nearby stable walls."
            )
        }

        return LocalizationReadinessSnapshot(
            state: .ready,
            confidence: effectiveConfidence,
            reason: nil,
            recommendedPrompt: "Aligned. Ready to orient."
        )
    }
}
