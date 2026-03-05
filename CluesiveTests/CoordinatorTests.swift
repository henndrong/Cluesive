import XCTest
import ARKit
@testable import Cluesive

final class RelocalizationCoordinatorTests: XCTestCase {
    func testEvaluateMeshAlignmentCandidateAcceptsStrongResult() {
        let result = MeshRelocalizationResult(
            coarsePoseSeed: nil,
            refinedPoseSeed: nil,
            orientationHintDegrees: nil,
            areaHint: nil,
            confidence: 0.9,
            residualErrorMeters: 0.1,
            overlapRatio: 0.5,
            yawConfidenceDegrees: 10,
            supportingPointCount: 400,
            isStableAcrossFrames: false,
            debugReason: "test"
        )

        XCTAssertTrue(RelocalizationCoordinator.evaluateMeshAlignmentCandidate(result))
    }

    func testReconcileDecisionEntersConflictAfterThreshold() {
        let conflict = LocalizationConflictSnapshot(
            positionDeltaMeters: 1.0,
            yawDeltaDegrees: 40,
            arkitStateAtConflict: "localized",
            meshConfidenceAtConflict: 0.9,
            detectedAt: Date()
        )

        let decision = RelocalizationCoordinator.reconcileDecision(
            appLocalizationState: .meshAlignedOverride,
            localizationState: .localized,
            loadRequestedAt: Date(),
            conflict: conflict,
            conflictDisagreementFrames: 4,
            latestLocalizationConfidence: 0.7
        )

        XCTAssertEqual(String(describing: decision), String(describing: RelocalizationCoordinator.ReconciliationDecision.enterConflict))
    }

    func testEvaluateMeshAlignmentCandidateRejectsLowConfidenceBoundary() {
        let result = MeshRelocalizationResult(
            coarsePoseSeed: nil,
            refinedPoseSeed: nil,
            orientationHintDegrees: nil,
            areaHint: nil,
            confidence: 0.79,
            residualErrorMeters: 0.1,
            overlapRatio: 0.5,
            yawConfidenceDegrees: 10,
            supportingPointCount: 400,
            isStableAcrossFrames: false,
            debugReason: "test"
        )

        XCTAssertFalse(RelocalizationCoordinator.evaluateMeshAlignmentCandidate(result))
    }

    func testStabilizeMeshAlignmentCandidateRequiresThreeFrames() {
        let candidate = makeStrongMeshResult(yawDegrees: 90, translation: SIMD2<Float>(0.5, -0.2))

        let first = RelocalizationCoordinator.stabilizeMeshAlignmentCandidate(buffer: [], result: candidate)
        XCTAssertNil(first.acceptance)

        let second = RelocalizationCoordinator.stabilizeMeshAlignmentCandidate(
            buffer: first.updatedBuffer,
            result: candidate
        )
        XCTAssertNil(second.acceptance)

        let third = RelocalizationCoordinator.stabilizeMeshAlignmentCandidate(
            buffer: second.updatedBuffer,
            result: candidate
        )
        XCTAssertNotNil(third.acceptance)
    }

    func testStabilizeMeshAlignmentCandidateRejectsUnstableSeeds() {
        let first = makeStrongMeshResult(yawDegrees: 10, translation: SIMD2<Float>(0.1, 0.1))
        let second = makeStrongMeshResult(yawDegrees: 20, translation: SIMD2<Float>(0.2, 0.2))
        let unstable = makeStrongMeshResult(yawDegrees: 70, translation: SIMD2<Float>(1.4, 1.3))

        let o1 = RelocalizationCoordinator.stabilizeMeshAlignmentCandidate(buffer: [], result: first)
        let o2 = RelocalizationCoordinator.stabilizeMeshAlignmentCandidate(buffer: o1.updatedBuffer, result: second)
        let o3 = RelocalizationCoordinator.stabilizeMeshAlignmentCandidate(buffer: o2.updatedBuffer, result: unstable)

        XCTAssertNil(o3.acceptance)
        XCTAssertTrue(o3.statusText?.contains("unstable") ?? false)
    }

    func testAppLocalizationTickPlanResetsMeshAligningAfterInconclusiveFallback() {
        let plan = RelocalizationCoordinator.appLocalizationTickPlan(
            localizationState: .relocalizing,
            loadRequestedAt: Date(),
            appLocalizationState: .meshAligning,
            meshOnlyTestModeEnabled: false,
            meshFallbackActive: true,
            meshResult: nil,
            hasAppliedWorldOriginShiftForCurrentAttempt: false,
            isPoseStableForAnchorActions: true,
            latestLocalizationConfidence: 0.7,
            meshFallbackPhase: .inconclusive
        )

        XCTAssertTrue(plan.shouldResetMeshAligningToSearching)
        XCTAssertEqual(plan.resetStatusText, "Mesh Override: Rejected (inconclusive)")
    }

    func testAppLocalizationTickPlanDegradesWhenMeshAlignedButUnstable() {
        let plan = RelocalizationCoordinator.appLocalizationTickPlan(
            localizationState: .relocalizing,
            loadRequestedAt: Date(),
            appLocalizationState: .meshAlignedOverride,
            meshOnlyTestModeEnabled: false,
            meshFallbackActive: false,
            meshResult: nil,
            hasAppliedWorldOriginShiftForCurrentAttempt: true,
            isPoseStableForAnchorActions: false,
            latestLocalizationConfidence: 0.2,
            meshFallbackPhase: .matched
        )

        XCTAssertTrue(plan.shouldDegradeMeshAlignedOverride)
        XCTAssertEqual(plan.degradeReason, "Pose stability and confidence dropped after mesh alignment")
    }

    func testReconcileDecisionPromotesWithoutConflict() {
        let decision = RelocalizationCoordinator.reconcileDecision(
            appLocalizationState: .meshAlignedOverride,
            localizationState: .localized,
            loadRequestedAt: Date(),
            conflict: nil,
            conflictDisagreementFrames: 0,
            latestLocalizationConfidence: 0.5
        )

        XCTAssertEqual(
            String(describing: decision),
            String(describing: RelocalizationCoordinator.ReconciliationDecision.promoteARKitConfirmed)
        )
    }

    func testReconcileDecisionTrustsARKitWhenHighConfidenceAndMeshWeak() {
        let conflict = LocalizationConflictSnapshot(
            positionDeltaMeters: 1.2,
            yawDeltaDegrees: 45,
            arkitStateAtConflict: "localized",
            meshConfidenceAtConflict: 0.7,
            detectedAt: Date()
        )

        let decision = RelocalizationCoordinator.reconcileDecision(
            appLocalizationState: .meshAlignedOverride,
            localizationState: .localized,
            loadRequestedAt: Date(),
            conflict: conflict,
            conflictDisagreementFrames: 1,
            latestLocalizationConfidence: 0.95
        )

        XCTAssertEqual(
            String(describing: decision),
            String(describing: RelocalizationCoordinator.ReconciliationDecision.resetConflictCounterAndPromote)
        )
    }

    func testFallbackDecisionRequiresConfirmationForMediumBand() {
        XCTAssertEqual(
            RelocalizationCoordinator.fallbackDecision(for: .medium),
            .needsUserConfirmation
        )
    }

    func testFallbackDecisionAcceptsHighBand() {
        XCTAssertEqual(
            RelocalizationCoordinator.fallbackDecision(for: .high),
            .accept
        )
    }

    func testAppLocalizationTickPlanDoesNotEnterMeshAligningInMeshOnlyMode() {
        let plan = RelocalizationCoordinator.appLocalizationTickPlan(
            localizationState: .relocalizing,
            loadRequestedAt: Date(),
            appLocalizationState: .searching,
            meshOnlyTestModeEnabled: true,
            meshFallbackActive: true,
            meshResult: nil,
            hasAppliedWorldOriginShiftForCurrentAttempt: false,
            isPoseStableForAnchorActions: true,
            latestLocalizationConfidence: 0.4,
            meshFallbackPhase: .coarseMatching
        )

        XCTAssertEqual(
            String(describing: plan.startAction),
            String(describing: RelocalizationCoordinator.AppLocalizationStartAction.none)
        )
    }

    private func makeStrongMeshResult(yawDegrees: Float, translation: SIMD2<Float>) -> MeshRelocalizationResult {
        let seed = MeshRelocalizationHypothesis(
            yawDegrees: yawDegrees,
            translationXZ: translation,
            coarseConfidence: 0.9,
            source: "test"
        )
        return MeshRelocalizationResult(
            coarsePoseSeed: seed,
            refinedPoseSeed: seed,
            orientationHintDegrees: 0,
            areaHint: "test",
            confidence: 0.9,
            residualErrorMeters: 0.1,
            overlapRatio: 0.5,
            yawConfidenceDegrees: 8,
            supportingPointCount: 350,
            isStableAcrossFrames: true,
            debugReason: "test"
        )
    }
}

final class RelocalizationAttemptCoordinatorTests: XCTestCase {
    func testShouldEscalateToMicroMovementWhenStationaryAttemptIsCompleteAndTimedOut() {
        let state = RelocalizationAttemptState(
            mode: .stationary360,
            startedAt: Date().addingTimeInterval(-12),
            rotationAccumulatedDegrees: 340,
            featurePointMedianRecent: 150,
            sawRelocalizingTracking: true,
            stableNormalFrames: 5,
            timeoutSeconds: 10
        )

        XCTAssertTrue(
            RelocalizationAttemptCoordinator.shouldEscalateToMicroMovement(
                state: state,
                localizationState: .relocalizing
            )
        )
    }

    func testCurrentGuidanceSnapshotForMicroMovementIncludesFallbackText() {
        let state = RelocalizationAttemptState(
            mode: .microMovementFallback,
            startedAt: Date().addingTimeInterval(-3),
            rotationAccumulatedDegrees: 100,
            featurePointMedianRecent: 210,
            sawRelocalizingTracking: true,
            stableNormalFrames: 8,
            timeoutSeconds: 14
        )

        let snapshot = RelocalizationAttemptCoordinator.currentGuidanceSnapshot(
            state: state,
            localizationState: .relocalizing
        )

        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.attemptMode, .microMovementFallback)
        XCTAssertTrue(snapshot?.recommendedActionText.contains("small steps") ?? false)
    }
}

final class ScanReadinessCoordinatorTests: XCTestCase {
    func testSaveReadinessWarningShownForLowQualitySnapshot() {
        let snapshot = ScanReadinessSnapshot(
            mappingMappedRatio: 0.2,
            featurePointMedian: 80,
            yawCoverageDegrees: 90,
            translationDistanceMeters: 0.3,
            trackingNormalRatio: 0.3,
            qualityScore: 0.3,
            warnings: ["low"]
        )

        XCTAssertNotNil(ScanReadinessCoordinator.saveReadinessWarningIfNeeded(snapshot: snapshot))
    }

    func testMapReadinessPresentationUsesStrongLabel() {
        let snapshot = ScanReadinessSnapshot(
            mappingMappedRatio: 0.95,
            featurePointMedian: 350,
            yawCoverageDegrees: 540,
            translationDistanceMeters: 4.5,
            trackingNormalRatio: 0.95,
            qualityScore: 0.9,
            warnings: []
        )

        let presentation = ScanReadinessCoordinator.mapReadinessPresentation(snapshot: snapshot)
        XCTAssertTrue(presentation.readinessText.contains("(Strong)"))
        XCTAssertNil(presentation.saveMapWarningText)
    }
}

final class GuidanceCoordinatorTests: XCTestCase {
    func testTrackingLimitedGuidanceForRelocalizing() {
        let text = GuidanceCoordinator.trackingLimitedGuidance(.relocalizing)
        XCTAssertTrue(text.contains("Relocalizing"))
    }

    func testScanningGuidanceResetsYawWindowWhenExpired() {
        let decision = GuidanceCoordinator.scanningGuidance(
            trackingState: .normal,
            mappingStatus: .mapped,
            heuristics: .init(
                now: Date(),
                yawSweepWindowStart: Date().addingTimeInterval(-5),
                yawSweepAccumulated: 0,
                lastMovementAt: Date(),
                mapReadinessWarningsText: nil,
                scanReadinessQualityScore: 0.9
            )
        )

        XCTAssertTrue(decision.shouldResetYawSweepWindow)
    }
}

final class AppLocalizationPresentationCoordinatorTests: XCTestCase {
    func testMeshAlignedOverrideUsesMeshConfidenceForPresentation() {
        let presentation = AppLocalizationPresentationCoordinator.presentation(
            inputs: .init(
                appLocalizationState: .meshAlignedOverride,
                appLocalizationSource: .meshICP,
                acceptedMeshAlignmentConfidence: 0.86,
                meshFallbackResultConfidence: 0.7,
                latestLocalizationConfidence: 0.2,
                arkitLocalizationStateText: "Relocalizing",
                hasAppliedWorldOriginShift: true
            )
        )

        XCTAssertTrue(presentation.appLocalizationConfidenceText.contains("86%"))
        XCTAssertTrue(presentation.meshOverrideAppliedText.contains("Yes"))
        XCTAssertTrue(presentation.appLocalizationPromptText.contains("provisional"))
    }
}

final class AnchorManagerDualLocalizationTests: XCTestCase {
    func testAnchorPlacementBlockedDuringConflict() {
        let eligibility = AnchorManager.validateAnchorPlacementEligibility(
            currentPoseTransform: matrix_identity_float4x4,
            appLocalizationState: .conflict,
            isPoseStableForAnchorActions: true,
            effectiveConfidence: 0.9,
            requiredConfidence: 0.7
        )

        XCTAssertFalse(eligibility.allowed)
    }

    func testAnchorPlacementBlockedDuringDegraded() {
        let eligibility = AnchorManager.validateAnchorPlacementEligibility(
            currentPoseTransform: matrix_identity_float4x4,
            appLocalizationState: .degraded,
            isPoseStableForAnchorActions: true,
            effectiveConfidence: 0.9,
            requiredConfidence: 0.7
        )

        XCTAssertFalse(eligibility.allowed)
    }
}
