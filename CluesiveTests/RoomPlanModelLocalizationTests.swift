import XCTest
import simd
import ARKit
@testable import Cluesive

@MainActor
final class RoomPlanModelLocalizationTests: XCTestCase {
    func testPromoteToMeshAlignedOverrideTransitionsStateAndLogs() {
        let model = RoomPlanModel()
        let initialEvents = model.debugLocalizationEventCount

        model.promoteToMeshAlignedOverride(using: makeAcceptance(confidence: 0.88))
        XCTAssertEqual(model.debugAppLocalizationState, .meshAlignedOverride)
        XCTAssertGreaterThanOrEqual(model.debugLocalizationEventCount, initialEvents + 1)
    }

    func testPromoteToARKitConfirmedAfterMeshOverride() {
        let model = RoomPlanModel()

        model.promoteToMeshAlignedOverride(using: makeAcceptance(confidence: 0.86))
        model.promoteToARKitConfirmed()

        XCTAssertEqual(model.debugAppLocalizationState, .arkitConfirmed)
    }

    func testEnterLocalizationConflictTransitionsAndPausesGuidance() {
        let model = RoomPlanModel()
        let conflict = LocalizationConflictSnapshot(
            positionDeltaMeters: 1.1,
            yawDeltaDegrees: 42,
            arkitStateAtConflict: "Localized",
            meshConfidenceAtConflict: 0.84,
            detectedAt: Date()
        )

        model.enterLocalizationConflict(conflict)

        XCTAssertEqual(model.debugAppLocalizationState, .conflict)
        XCTAssertTrue(model.guidanceText.localizedCaseInsensitiveContains("conflict"))
        XCTAssertNotNil(model.localizationConflictText)
    }

    func testDegradeAppLocalizationTransitionsToDegraded() {
        let model = RoomPlanModel()
        model.promoteToMeshAlignedOverride(using: makeAcceptance(confidence: 0.85))

        model.degradeAppLocalization(reason: "test instability")

        XCTAssertEqual(model.debugAppLocalizationState, .degraded)
        XCTAssertTrue(model.guidanceText.localizedCaseInsensitiveContains("degraded"))
    }

    func testWorldOriginShiftIsNotAppliedWithoutSession() {
        let model = RoomPlanModel()

        model.applyWorldOriginShiftIfNeeded(using: makeAcceptance(confidence: 0.9))

        XCTAssertFalse(model.debugHasAppliedWorldOriginShiftForCurrentAttempt)
    }

    func testMeshOnlyRelocalizationTrackingDoesNotClearFallbackState() {
        let model = RoomPlanModel()
        model.meshOnlyTestModeEnabled = true
        model.debugSetAwaitingRelocalizationForTesting(true)
        model.debugActivateMeshFallbackForTesting()

        model.updateRelocalizationStateForTracking(.normal)

        XCTAssertTrue(model.debugMeshFallbackActive)
        XCTAssertNotNil(model.debugRelocalizationAttemptMode)
    }

    func testMeshOnlyFallbackStartKeepsSearchingUntilAcceptance() {
        let model = RoomPlanModel()
        model.meshOnlyTestModeEnabled = true
        model.debugSetSavedMeshArtifactForTesting(makeMeshArtifact())

        model.startFallbackIsolationNow()
        XCTAssertEqual(model.debugAppLocalizationState, .searching)

        model.promoteToMeshAlignedOverride(using: makeAcceptance(confidence: 0.82))
        XCTAssertEqual(model.debugAppLocalizationState, .meshAlignedOverride)
    }

    func testMeshOnlySuppressesARKitPromotion() {
        let model = RoomPlanModel()
        model.meshOnlyTestModeEnabled = true

        model.promoteToARKitConfirmed()

        XCTAssertNotEqual(model.debugAppLocalizationState, .arkitConfirmed)
    }

    func testSavedMeshPointCacheLifecycle() {
        let model = RoomPlanModel()
        model.debugSetSavedMeshArtifactForTesting(makeMeshArtifact())
        let initialCount = model.debugCachedSavedMeshPointsCount

        XCTAssertGreaterThan(initialCount, 0)

        model.clearRuntimeFallbackCaches(keepSavedMeshCache: true)
        XCTAssertEqual(model.debugCachedSavedMeshPointsCount, initialCount)

        model.clearRuntimeFallbackCaches(keepSavedMeshCache: false)
        XCTAssertEqual(model.debugCachedSavedMeshPointsCount, 0)
    }

    func testGraphLoadIsSafeWhenNoFileExists() {
        let model = RoomPlanModel()
        model.loadNavGraphFromDisk()

        XCTAssertTrue(model.navGraph.nodes.isEmpty)
        XCTAssertTrue(model.navGraph.edges.isEmpty)
    }

    func testEnteringAndLeavingGraphModeResetsSelection() {
        let model = RoomPlanModel()
        model.navGraph = seededGraph()
        let selectedID = model.navGraph.nodes[0].id

        model.setWorkspaceMode(.graph)
        model.selectWaypoint(selectedID)
        XCTAssertEqual(model.debugSelectedGraphNodeID, selectedID)

        model.setWorkspaceMode(.scan)
        XCTAssertNil(model.debugSelectedGraphNodeID)
        XCTAssertEqual(model.debugWorkspaceMode, .scan)
    }

    func testSavingGraphDoesNotEraseGraph() {
        let model = RoomPlanModel()
        model.navGraph = seededGraph()

        model.saveNavGraphToDisk()
        model.loadNavGraphFromDisk()

        XCTAssertEqual(model.navGraph.nodes.count, 2)
    }

    private func makeAcceptance(confidence: Float) -> MeshAlignmentAcceptance {
        MeshAlignmentAcceptance(
            mapFromSessionTransform: matrix_identity_float4x4,
            confidence: confidence,
            residualErrorMeters: 0.12,
            overlapRatio: 0.48,
            yawConfidenceDegrees: 8,
            acceptedAt: Date(),
            supportingFrames: 3
        )
    }

    private func makeMeshArtifact() -> MeshMapArtifact {
        let vertices: [Float] = [
            0, 0, 0,
            1, 0, 0,
            0, 1, 0,
            1, 1, 0,
            0.5, 0.5, 1,
            0.5, 0.5, -1
        ]
        let record = MeshAnchorRecord(
            id: UUID(),
            transform: matrix_identity_float4x4.flatArray,
            vertices: vertices,
            normals: nil,
            faces: [],
            capturedAt: Date(),
            classificationSummary: nil
        )
        let descriptor = MeshRelocalizationEngine.buildMeshSignatureDescriptor(from: [record])
        return MeshMapArtifact(
            mapName: "test",
            capturedAt: Date(),
            meshAnchors: [record],
            descriptor: descriptor,
            version: 1
        )
    }

    private func seededGraph() -> NavGraphArtifact {
        NavGraphArtifact(
            mapName: "test",
            createdAt: Date(),
            updatedAt: Date(),
            version: 1,
            nodes: [
                NavGraphNode(
                    id: UUID(),
                    name: "Waypoint 1",
                    position: SIMD3<Float>(0, 0, 0),
                    nodeType: .manualWaypoint,
                    linkedAnchorID: nil,
                    createdAt: Date()
                ),
                NavGraphNode(
                    id: UUID(),
                    name: "Waypoint 2",
                    position: SIMD3<Float>(1, 0, 0),
                    nodeType: .manualWaypoint,
                    linkedAnchorID: nil,
                    createdAt: Date()
                )
            ],
            edges: []
        )
    }
}
