import XCTest
import simd
@testable import Cluesive

final class NavigationPlannerTests: XCTestCase {
    func testPlannerBuildsOrderedPathAndHeadings() {
        let anchor = SavedSemanticAnchor(
            id: UUID(),
            name: "Bathroom",
            type: .roomEntrance,
            createdAt: Date(),
            transform: matrix_identity_float4x4.flatArray
        )
        let start = NavGraphNode(id: UUID(), name: "A", position: SIMD3<Float>(0, 0, 0), nodeType: .manualWaypoint, linkedAnchorID: nil, createdAt: Date())
        let middle = NavGraphNode(id: UUID(), name: "B", position: SIMD3<Float>(1, 0, 0), nodeType: .manualWaypoint, linkedAnchorID: nil, createdAt: Date())
        let destination = NavGraphNode(id: UUID(), name: "C", position: SIMD3<Float>(1, 0, 1), nodeType: .anchorLinked, linkedAnchorID: anchor.id, createdAt: Date())
        let graph = NavGraphArtifact(
            mapName: "test",
            createdAt: Date(),
            updatedAt: Date(),
            version: 1,
            nodes: [start, middle, destination],
            edges: [
                NavGraphEdge(id: UUID(), fromNodeID: start.id, toNodeID: middle.id, distanceMeters: 1),
                NavGraphEdge(id: UUID(), fromNodeID: middle.id, toNodeID: destination.id, distanceMeters: 1)
            ]
        )
        let currentPose = simd_float4x4(yawRadians: 0, translation: SIMD3<Float>(0.1, 0, 0.1))

        let result = NavigationPlanner.planRoute(
            currentPose: currentPose,
            destinationAnchorID: anchor.id,
            graph: graph,
            anchors: [anchor]
        )

        guard case .success(let route) = result else {
            return XCTFail("Expected successful route")
        }
        XCTAssertEqual(route.nodePath, [start.id, middle.id, destination.id])
        XCTAssertEqual(route.segments.count, 2)
        XCTAssertEqual(route.segments[0].headingDegrees, 0, accuracy: 0.001)
        XCTAssertEqual(route.segments[1].headingDegrees, 90, accuracy: 0.001)
    }

    func testPlannerFailsWhenDestinationAnchorNotLinked() {
        let anchor = SavedSemanticAnchor(
            id: UUID(),
            name: "Bathroom",
            type: .roomEntrance,
            createdAt: Date(),
            transform: matrix_identity_float4x4.flatArray
        )
        let graph = NavGraphArtifact.empty(mapName: "test")
        let currentPose = simd_float4x4(yawRadians: 0, translation: SIMD3<Float>(0, 0, 0))

        let result = NavigationPlanner.planRoute(
            currentPose: currentPose,
            destinationAnchorID: anchor.id,
            graph: graph,
            anchors: [anchor]
        )

        XCTAssertEqual(result, .failure(.graphInvalid))
    }

    func testPlannerFailsWhenStartPoseNotNearGraph() {
        let anchor = SavedSemanticAnchor(
            id: UUID(),
            name: "Bathroom",
            type: .roomEntrance,
            createdAt: Date(),
            transform: matrix_identity_float4x4.flatArray
        )
        let node = NavGraphNode(id: UUID(), name: "C", position: SIMD3<Float>(10, 0, 10), nodeType: .anchorLinked, linkedAnchorID: anchor.id, createdAt: Date())
        let second = NavGraphNode(id: UUID(), name: "D", position: SIMD3<Float>(11, 0, 10), nodeType: .manualWaypoint, linkedAnchorID: nil, createdAt: Date())
        let graph = NavGraphArtifact(
            mapName: "test",
            createdAt: Date(),
            updatedAt: Date(),
            version: 1,
            nodes: [node, second],
            edges: [NavGraphEdge(id: UUID(), fromNodeID: node.id, toNodeID: second.id, distanceMeters: 1)]
        )
        let currentPose = simd_float4x4(yawRadians: 0, translation: SIMD3<Float>(0, 0, 0))

        let result = NavigationPlanner.planRoute(
            currentPose: currentPose,
            destinationAnchorID: anchor.id,
            graph: graph,
            anchors: [anchor]
        )

        XCTAssertEqual(result, .failure(.startPoseNotNearGraph))
    }
}
