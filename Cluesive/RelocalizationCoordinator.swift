//
//  RelocalizationCoordinator.swift
//  Cluesive
//
//  Pure relocalization decision helpers for mesh acceptance and ARKit reconciliation.
//

import Foundation
import ARKit

enum RelocalizationCoordinator {
    enum AppLocalizationStartAction {
        case none
        case reconcileMeshOverride
        case promoteARKitConfirmed
        case enterMeshAligning
    }

    struct MeshOverrideFollowUpActions {
        let shouldValidatePostShiftAlignment: Bool
        let shouldReconcileAfterPostShift: Bool
    }

    enum ReconciliationDecision {
        case noAction
        case promoteARKitConfirmed
        case incrementConflictCounter
        case resetConflictCounterAndPromote
        case enterConflict
    }

    struct MeshStabilizationOutcome {
        let updatedBuffer: [MeshRelocalizationResult]
        let acceptance: MeshAlignmentAcceptance?
        let statusText: String?
    }

    static func evaluateMeshAlignmentCandidate(_ result: MeshRelocalizationResult) -> Bool {
        guard result.confidence >= 0.80 else { return false }
        guard result.residualErrorMeters <= 0.20 else { return false }
        guard result.overlapRatio >= 0.35 else { return false }
        guard result.yawConfidenceDegrees <= 12 else { return false }
        guard result.supportingPointCount >= 250 else { return false }
        return true
    }

    static func stabilizeMeshAlignmentCandidate(
        buffer: [MeshRelocalizationResult],
        result: MeshRelocalizationResult,
        now: Date = Date()
    ) -> MeshStabilizationOutcome {
        var updatedBuffer = buffer
        updatedBuffer.append(result)
        if updatedBuffer.count > 5 {
            updatedBuffer.removeFirst(updatedBuffer.count - 5)
        }

        guard evaluateMeshAlignmentCandidate(result) else {
            let status = String(
                format: "Mesh Override: Rejected (conf %.0f%%, residual %.2fm, overlap %.0f%%)",
                result.confidence * 100,
                result.residualErrorMeters,
                result.overlapRatio * 100
            )
            return MeshStabilizationOutcome(updatedBuffer: updatedBuffer, acceptance: nil, statusText: status)
        }

        guard updatedBuffer.count >= 3 else {
            return MeshStabilizationOutcome(
                updatedBuffer: updatedBuffer,
                acceptance: nil,
                statusText: "Mesh Override: Candidate good, waiting for stability"
            )
        }

        let recent = Array(updatedBuffer.suffix(3))
        guard recent.allSatisfy({ evaluateMeshAlignmentCandidate($0) }) else {
            return MeshStabilizationOutcome(updatedBuffer: updatedBuffer, acceptance: nil, statusText: nil)
        }

        let seeds = recent.compactMap(\.refinedPoseSeed)
        guard seeds.count == 3, let latestSeed = seeds.last else {
            return MeshStabilizationOutcome(updatedBuffer: updatedBuffer, acceptance: nil, statusText: nil)
        }

        let yawStable = seeds.dropLast().allSatisfy { angleDistanceDegrees($0.yawDegrees, latestSeed.yawDegrees) <= 10 }
        let transStable = seeds.dropLast().allSatisfy {
            simd_distance($0.translationXZ, latestSeed.translationXZ) <= 0.45
        }
        guard yawStable, transStable else {
            return MeshStabilizationOutcome(
                updatedBuffer: updatedBuffer,
                acceptance: nil,
                statusText: "Mesh Override: Candidate unstable across frames"
            )
        }

        let mapFromSession = simd_float4x4(
            yawRadians: latestSeed.yawDegrees * .pi / 180,
            translation: SIMD3<Float>(latestSeed.translationXZ.x, 0, latestSeed.translationXZ.y)
        )
        let conf = recent.map(\.confidence).reduce(0, +) / Float(recent.count)
        let residual = recent.map(\.residualErrorMeters).reduce(0, +) / Float(recent.count)
        let overlap = recent.map(\.overlapRatio).reduce(0, +) / Float(recent.count)
        let yawConf = recent.map(\.yawConfidenceDegrees).reduce(0, +) / Float(recent.count)
        let acceptance = MeshAlignmentAcceptance(
            mapFromSessionTransform: mapFromSession,
            confidence: conf,
            residualErrorMeters: residual,
            overlapRatio: overlap,
            yawConfidenceDegrees: yawConf,
            acceptedAt: now,
            supportingFrames: recent.count
        )
        return MeshStabilizationOutcome(updatedBuffer: updatedBuffer, acceptance: acceptance, statusText: nil)
    }

    static func computeARKitMeshDisagreement(
        frame: ARFrame,
        acceptance: MeshAlignmentAcceptance,
        arkitStateAtConflict: String,
        thresholdPositionMeters: Float = 0.75,
        thresholdYawDegrees: Float = 25
    ) -> LocalizationConflictSnapshot? {
        let arkitYaw = frame.camera.transform.forwardYawRadians * 180 / .pi
        let meshYaw = acceptance.mapFromSessionTransform.forwardYawRadians * 180 / .pi
        let yawDelta = angleDistanceDegrees(arkitYaw, meshYaw)

        let arkitPos = frame.camera.transform.translation
        let meshPos = acceptance.mapFromSessionTransform.translation
        let posDelta = simd_distance(SIMD2<Float>(arkitPos.x, arkitPos.z), SIMD2<Float>(meshPos.x, meshPos.z))

        guard posDelta > thresholdPositionMeters || yawDelta > thresholdYawDegrees else { return nil }
        return LocalizationConflictSnapshot(
            positionDeltaMeters: posDelta,
            yawDeltaDegrees: yawDelta,
            arkitStateAtConflict: arkitStateAtConflict,
            meshConfidenceAtConflict: acceptance.confidence,
            detectedAt: Date()
        )
    }

    static func shouldTrustARKitOverMesh(
        latestLocalizationConfidence: Float,
        conflict: LocalizationConflictSnapshot
    ) -> Bool {
        latestLocalizationConfidence > 0.9 && conflict.meshConfidenceAtConflict < 0.82
    }

    static func shouldEnterMeshAligning(
        localizationState: LocalizationState,
        loadRequestedAt: Date?,
        meshFallbackActive: Bool,
        appLocalizationState: AppLocalizationState
    ) -> Bool {
        let arkitLocalizedAfterLoad = localizationState == .localized && loadRequestedAt != nil
        guard !arkitLocalizedAfterLoad else { return false }
        return meshFallbackActive && appLocalizationState == .searching
    }

    static func appLocalizationStartAction(
        localizationState: LocalizationState,
        loadRequestedAt: Date?,
        appLocalizationState: AppLocalizationState,
        meshFallbackActive: Bool
    ) -> AppLocalizationStartAction {
        if localizationState == .localized, loadRequestedAt != nil {
            if appLocalizationState == .meshAlignedOverride {
                return .reconcileMeshOverride
            }
            if appLocalizationState != .conflict {
                return .promoteARKitConfirmed
            }
            return .none
        }

        if shouldEnterMeshAligning(
            localizationState: localizationState,
            loadRequestedAt: loadRequestedAt,
            meshFallbackActive: meshFallbackActive,
            appLocalizationState: appLocalizationState
        ) {
            return .enterMeshAligning
        }

        return .none
    }

    static func shouldAttemptMeshAcceptance(
        meshResult: MeshRelocalizationResult?,
        appLocalizationState: AppLocalizationState,
        hasAppliedWorldOriginShiftForCurrentAttempt: Bool
    ) -> Bool {
        guard meshResult != nil else { return false }
        guard appLocalizationState != .arkitConfirmed, appLocalizationState != .conflict else { return false }
        return !hasAppliedWorldOriginShiftForCurrentAttempt
    }

    static func acceptedMeshOverrideStatusText(_ acceptance: MeshAlignmentAcceptance) -> String {
        String(
            format: "Mesh Override: Accepted (conf %.0f%%, residual %.2fm, overlap %.0f%%)",
            acceptance.confidence * 100,
            acceptance.residualErrorMeters,
            acceptance.overlapRatio * 100
        )
    }

    static func shouldDegradeMeshAlignedOverride(
        appLocalizationState: AppLocalizationState,
        isPoseStableForAnchorActions: Bool,
        latestLocalizationConfidence: Float
    ) -> Bool {
        appLocalizationState == .meshAlignedOverride && !isPoseStableForAnchorActions && latestLocalizationConfidence < 0.35
    }

    static func shouldResetMeshAligningToSearching(
        appLocalizationState: AppLocalizationState,
        meshFallbackPhase: MeshFallbackPhase
    ) -> Bool {
        appLocalizationState == .meshAligning && meshFallbackPhase == .inconclusive
    }

    static func meshAligningRejectedStatusText() -> String {
        "Mesh Override: Rejected (inconclusive)"
    }

    static func meshOverrideFollowUpActions(
        appLocalizationState: AppLocalizationState,
        localizationState: LocalizationState
    ) -> MeshOverrideFollowUpActions {
        guard appLocalizationState == .meshAlignedOverride else {
            return MeshOverrideFollowUpActions(
                shouldValidatePostShiftAlignment: false,
                shouldReconcileAfterPostShift: false
            )
        }
        return MeshOverrideFollowUpActions(
            shouldValidatePostShiftAlignment: true,
            shouldReconcileAfterPostShift: localizationState == .localized
        )
    }

    static func arkitConfirmedMeshOverrideStatusText(hasAppliedWorldOriginShift: Bool) -> String {
        hasAppliedWorldOriginShift
            ? "Mesh Override: Applied; ARKit confirmed alignment"
            : "Mesh Override: Not needed (ARKit confirmed)"
    }

    static func degradedGuidanceText(reason: String) -> String {
        "Alignment degraded. \(reason). Face a wall/corner and rotate slowly."
    }

    static func conflictPresentation(conflict: LocalizationConflictSnapshot) -> (localizationConflictText: String, guidanceText: String) {
        let pos = String(format: "%.2f", conflict.positionDeltaMeters)
        let yaw = String(format: "%.0f", conflict.yawDeltaDegrees)
        return (
            "ARKit/mesh conflict: Δpos \(pos)m, Δyaw \(yaw)°",
            "Alignment conflict detected. Stop and scan walls/corners for re-alignment."
        )
    }

    static func reconcileDecision(
        appLocalizationState: AppLocalizationState,
        localizationState: LocalizationState,
        loadRequestedAt: Date?,
        conflict: LocalizationConflictSnapshot?,
        conflictDisagreementFrames: Int,
        latestLocalizationConfidence: Float
    ) -> ReconciliationDecision {
        guard appLocalizationState == .meshAlignedOverride else {
            if localizationState == .localized, loadRequestedAt != nil {
                return .promoteARKitConfirmed
            }
            return .noAction
        }

        guard let conflict else {
            return .promoteARKitConfirmed
        }

        if shouldTrustARKitOverMesh(latestLocalizationConfidence: latestLocalizationConfidence, conflict: conflict) {
            return .resetConflictCounterAndPromote
        }

        if conflictDisagreementFrames + 1 >= 5 {
            return .enterConflict
        }

        return .incrementConflictCounter
    }
}
