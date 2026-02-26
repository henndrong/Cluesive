//
//  GuidanceCoordinator.swift
//  Cluesive
//
//  Pure guidance text decision helpers for scanning/relocalization states.
//

import Foundation
import ARKit

enum GuidanceCoordinator {
    struct ScanHeuristicInputs {
        let now: Date
        let yawSweepWindowStart: Date
        let yawSweepAccumulated: Float
        let lastMovementAt: Date
        let mapReadinessWarningsText: String?
        let scanReadinessQualityScore: Float
    }

    struct ScanHeuristicDecision {
        let guidanceText: String
        let shouldResetYawSweepWindow: Bool
    }

    static func trackingLimitedGuidance(_ reason: ARCamera.TrackingState.Reason) -> String {
        switch reason {
        case .initializing:
            return "Initializing tracking. Hold steady, then begin scanning slowly."
        case .excessiveMotion:
            return "Move slower. Sweep the phone smoothly."
        case .insufficientFeatures:
            return "Aim at textured surfaces, edges, and furniture."
        case .relocalizing:
            return "Relocalizing. Point at previously scanned walls and large objects."
        @unknown default:
            return "Tracking limited. Slow down and scan more of the room."
        }
    }

    static func scanningGuidance(
        trackingState: ARCamera.TrackingState,
        mappingStatus: ARFrame.WorldMappingStatus,
        heuristics: ScanHeuristicInputs
    ) -> ScanHeuristicDecision {
        switch trackingState {
        case .notAvailable:
            return ScanHeuristicDecision(
                guidanceText: "Tracking unavailable. Move to a brighter area and restart.",
                shouldResetYawSweepWindow: false
            )
        case .limited(let reason):
            return ScanHeuristicDecision(
                guidanceText: trackingLimitedGuidance(reason),
                shouldResetYawSweepWindow: false
            )
        case .normal:
            break
        }

        if mappingStatus == .limited || mappingStatus == .notAvailable {
            return ScanHeuristicDecision(
                guidanceText: "Keep scanning walls and furniture. Pan left and right for coverage.",
                shouldResetYawSweepWindow: false
            )
        }

        let shouldResetWindow = heuristics.now.timeIntervalSince(heuristics.yawSweepWindowStart) > 4
        let stillForTooLong = heuristics.now.timeIntervalSince(heuristics.lastMovementAt) > 2.0

        var guidance: String
        if stillForTooLong {
            guidance = "Move slowly through the room. Scan both sides and corners."
        } else if heuristics.yawSweepAccumulated < (.pi / 6) {
            guidance = "Pan left/right a bit more to improve map coverage."
        } else if mappingStatus == .extending {
            guidance = "Good scan. Continue covering unscanned areas."
        } else {
            guidance = "Mapping looks good. You can save when coverage is complete."
        }

        if let warnings = heuristics.mapReadinessWarningsText,
           !warnings.isEmpty,
           heuristics.scanReadinessQualityScore < 0.65
        {
            guidance = "Reloc robustness hint: \(warnings)"
        }

        return ScanHeuristicDecision(
            guidanceText: guidance,
            shouldResetYawSweepWindow: shouldResetWindow
        )
    }
}
