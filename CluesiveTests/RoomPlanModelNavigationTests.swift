import XCTest
import simd
@testable import Cluesive

@MainActor
final class RoomPlanModelNavigationTests: XCTestCase {
    func testOrientationSuccessAutoStartsNavigation() {
        let model = RoomPlanModel()
        let route = makeRoute()

        model.configureNavigationForTesting(
            route: route,
            selectedDestinationAnchorID: route.destinationAnchorID,
            currentPose: simd_float4x4(yawRadians: 0, translation: SIMD3<Float>(0, 0, 0))
        )

        model.forceOrientationAlignedForTesting()

        XCTAssertTrue(model.isNavigationActive)
        XCTAssertEqual(model.navigationStatusText, "Navigation: active")
    }

    func testStartingNavigationWithoutRouteIsBlocked() {
        let model = RoomPlanModel()

        model.startNavigation()

        XCTAssertFalse(model.isNavigationActive)
        XCTAssertEqual(model.navigationStatusText, "Navigation: waiting for localization")
    }

    func testStopNavigationClearsState() {
        let model = RoomPlanModel()
        let route = makeRoute()
        model.configureNavigationForTesting(
            route: route,
            selectedDestinationAnchorID: route.destinationAnchorID,
            currentPose: simd_float4x4(yawRadians: 0, translation: SIMD3<Float>(0, 0, 0))
        )
        model.startNavigation()

        model.stopNavigation()

        XCTAssertFalse(model.isNavigationActive)
        XCTAssertEqual(model.navigationProgressText, "Navigation progress: n/a")
        XCTAssertEqual(model.navigationInstructionText, "Instruction: n/a")
    }

    func testRerouteRequestReplacesRouteOnSuccess() {
        let model = RoomPlanModel()
        let destinationID = UUID()
        let destinationAnchor = SavedSemanticAnchor(
            id: destinationID,
            name: "Bathroom",
            type: .roomEntrance,
            createdAt: Date(),
            transform: matrix_identity_float4x4.flatArray
        )
        let nodeA = NavGraphNode(id: UUID(), name: "A", position: SIMD3<Float>(0, 0, 0), nodeType: .manualWaypoint, linkedAnchorID: nil, createdAt: Date())
        let nodeB = NavGraphNode(id: UUID(), name: "B", position: SIMD3<Float>(1, 0, 0), nodeType: .manualWaypoint, linkedAnchorID: nil, createdAt: Date())
        let nodeC = NavGraphNode(id: UUID(), name: "C", position: SIMD3<Float>(2, 0, 0), nodeType: .anchorLinked, linkedAnchorID: destinationID, createdAt: Date())
        let graph = NavGraphArtifact(
            mapName: "test",
            createdAt: Date(),
            updatedAt: Date(),
            version: 1,
            nodes: [nodeA, nodeB, nodeC],
            edges: [
                NavGraphEdge(id: UUID(), fromNodeID: nodeA.id, toNodeID: nodeB.id, distanceMeters: 1),
                NavGraphEdge(id: UUID(), fromNodeID: nodeB.id, toNodeID: nodeC.id, distanceMeters: 1)
            ]
        )

        model.anchors = [destinationAnchor]
        model.navGraph = graph
        model.selectDestinationAnchor(destinationID)
        model.configureNavigationForTesting(
            route: makeRoute(destinationAnchorID: destinationID),
            selectedDestinationAnchorID: destinationID,
            currentPose: simd_float4x4(yawRadians: 0, translation: SIMD3<Float>(0.1, 0, 0))
        )

        model.replanActiveNavigationFromCurrentPose()

        XCTAssertEqual(model.navigationStatusText, "Navigation: active")
        XCTAssertTrue(model.plannedRouteSummaryText.contains("Bathroom"))
    }

    func testNavigationPausesWhenLocalizationDegrades() {
        let model = RoomPlanModel()
        let route = makeRoute()
        model.configureNavigationForTesting(
            route: route,
            selectedDestinationAnchorID: route.destinationAnchorID,
            currentPose: simd_float4x4(yawRadians: 0, translation: SIMD3<Float>(0.1, 0, 0))
        )
        model.startNavigation()

        model.simulateNavigationFrameForTesting(
            currentPose: simd_float4x4(yawRadians: 0, translation: SIMD3<Float>(0.1, 0, 0)),
            readinessState: .recovering
        )

        XCTAssertEqual(model.navigationStatusText, "Navigation: paused")
    }

    private func makeRoute(destinationAnchorID: UUID = UUID()) -> PlannedRoute {
        let start = UUID()
        let finish = UUID()
        return PlannedRoute(
            destinationAnchorID: destinationAnchorID,
            destinationNodeID: finish,
            startNodeID: start,
            nodePath: [start, finish],
            segments: [
                RouteSegment(
                    fromNodeID: start,
                    toNodeID: finish,
                    startPosition: .zero,
                    endPosition: SIMD3<Float>(1, 0, 0),
                    headingDegrees: 0,
                    distanceMeters: 1
                )
            ],
            totalDistanceMeters: 1
        )
    }
}
