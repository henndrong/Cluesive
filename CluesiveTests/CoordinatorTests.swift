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
