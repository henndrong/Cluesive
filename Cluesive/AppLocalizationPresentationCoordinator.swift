//
//  AppLocalizationPresentationCoordinator.swift
//  Cluesive
//
//  Pure presentation helpers for app-localization UI/debug labels.
//

import Foundation

enum AppLocalizationPresentationCoordinator {
    struct Inputs {
        let appLocalizationState: AppLocalizationState
        let appLocalizationSource: AppLocalizationSource
        let acceptedMeshAlignmentConfidence: Float?
        let meshFallbackResultConfidence: Float?
        let latestLocalizationConfidence: Float
        let arkitLocalizationStateText: String
        let hasAppliedWorldOriginShift: Bool
    }

    struct Presentation {
        let appLocalizationStateText: String
        let appLocalizationSourceText: String
        let appLocalizationConfidenceText: String
        let appLocalizationPromptText: String
        let arkitVsAppStateText: String
        let meshOverrideAppliedText: String
    }

    static func presentation(inputs: Inputs) -> Presentation {
        let state = inputs.appLocalizationState
        let confidence = effectiveConfidence(inputs: inputs)
        let clampedConfidence = max(0, min(1, confidence))

        return Presentation(
            appLocalizationStateText: "App Localization: \(state.displayLabel)",
            appLocalizationSourceText: "Localization Source: \(inputs.appLocalizationSource.displayLabel)",
            appLocalizationConfidenceText: "App localization confidence: \(Int((clampedConfidence * 100).rounded()))%",
            appLocalizationPromptText: promptText(for: state),
            arkitVsAppStateText: "ARKit: \(inputs.arkitLocalizationStateText) | App: \(state.displayLabel)",
            meshOverrideAppliedText: "World Origin Shift: \(inputs.hasAppliedWorldOriginShift ? "Yes" : "No")"
        )
    }

    private static func effectiveConfidence(inputs: Inputs) -> Float {
        switch inputs.appLocalizationState {
        case .meshAlignedOverride:
            return inputs.acceptedMeshAlignmentConfidence
                ?? (inputs.meshFallbackResultConfidence ?? inputs.latestLocalizationConfidence)
        case .arkitConfirmed:
            return max(inputs.latestLocalizationConfidence, inputs.acceptedMeshAlignmentConfidence ?? 0)
        case .meshAligning:
            return inputs.meshFallbackResultConfidence ?? 0
        default:
            return inputs.latestLocalizationConfidence
        }
    }

    private static func promptText(for state: AppLocalizationState) -> String {
        switch state {
        case .searching:
            return "Searching for usable alignment. Scan walls/corners slowly."
        case .meshAligning:
            return "Mesh aligning in progress. Hold position if safe and rotate slowly."
        case .meshAlignedOverride:
            return "Aligned (provisional via mesh). Move slowly; ARKit still confirming."
        case .arkitConfirmed:
            return "Aligned. You can proceed."
        case .conflict:
            return "Alignment conflict detected. Stop and scan walls/corners."
        case .degraded:
            return "Alignment degraded. Move slowly and rescan strong geometry."
        }
    }
}
