import XCTest
import simd
@testable import Cluesive

final class GraphManagerTests: XCTestCase {
    func testCreateWaypointUsesExpectedDefaultName() {
        let graph = NavGraphArtifact.empty(mapName: "test")
        let updated = GraphManager.createWaypoint(in: graph, position: SIMD3<Float>(1, 0, 2))

        XCTAssertEqual(updated.nodes.count, 1)
        XCTAssertEqual(updated.nodes.first?.name, "Waypoint 1")
    }

    func testCreateEdgeBlocksDuplicateUndirectedEdge() {
        let graph = seededGraph()
        let first = GraphManager.createEdge(in: graph, from: graph.nodes[0].id, to: graph.nodes[1].id)
        let second = GraphManager.createEdge(in: first.graph, from: graph.nodes[1].id, to: graph.nodes[0].id)

        XCTAssertNil(first.error)
        XCTAssertEqual(second.error, "Edge already exists")
        XCTAssertEqual(second.graph.edges.count, 1)
    }

    func testCreateEdgeBlocksSelfEdge() {
        let graph = seededGraph()
        let result = GraphManager.createEdge(in: graph, from: graph.nodes[0].id, to: graph.nodes[0].id)

        XCTAssertEqual(result.error, "Cannot connect a waypoint to itself")
        XCTAssertTrue(result.graph.edges.isEmpty)
    }

    func testDeleteNodeCascadeDeletesEdges() {
        var graph = seededGraph()
        graph = GraphManager.createEdge(in: graph, from: graph.nodes[0].id, to: graph.nodes[1].id).graph

        let updated = GraphManager.deleteNode(in: graph, nodeID: graph.nodes[0].id)

        XCTAssertEqual(updated.nodes.count, 1)
        XCTAssertTrue(updated.edges.isEmpty)
    }

    func testEdgeDistanceUsesXZOnly() {
        let distance = GraphManager.edgeDistance(from: SIMD3<Float>(0, 0, 0), to: SIMD3<Float>(3, 7, 4))
        XCTAssertEqual(distance, 5, accuracy: 0.001)
    }

    func testValidationFlagsDisconnectedGraph() {
        let graph = seededGraph()
        let validation = GraphManager.validate(graph: graph, anchors: [])

        XCTAssertFalse(validation.isValid)
        XCTAssertTrue(validation.warnings.contains("Need at least 1 edge"))
        XCTAssertTrue(validation.warnings.contains("Graph contains disconnected waypoints"))
    }

    func testValidationFlagsInvalidLinkedAnchor() {
        var graph = seededGraph()
        graph.nodes[0].linkedAnchorID = UUID()
        graph.nodes[0].nodeType = .anchorLinked

        let validation = GraphManager.validate(graph: graph, anchors: [])

        XCTAssertTrue(validation.warnings.contains("Graph contains invalid anchor links"))
    }

    func testLinkingAnchorToNewNodeClearsPriorLink() {
        let anchor = makeAnchor(name: "Door")
        var graph = seededGraph()
        graph = GraphManager.linkAnchor(in: graph, nodeID: graph.nodes[0].id, anchorID: anchor.id)
        graph = GraphManager.linkAnchor(in: graph, nodeID: graph.nodes[1].id, anchorID: anchor.id)

        XCTAssertNil(graph.nodes[0].linkedAnchorID)
        XCTAssertEqual(graph.nodes[1].linkedAnchorID, anchor.id)
        XCTAssertEqual(graph.nodes[1].nodeType, .anchorLinked)
    }

    func testNavGraphStoreRoundTrip() throws {
        let graph = seededGraph()

        try Phase1MapStore.saveNavGraph(graph)
        let loaded = try Phase1MapStore.loadNavGraph()

        XCTAssertEqual(loaded?.nodes.count, graph.nodes.count)
        XCTAssertEqual(loaded?.edges.count, graph.edges.count)
    }

    private func seededGraph() -> NavGraphArtifact {
        let a = NavGraphNode(
            id: UUID(),
            name: "Waypoint 1",
            position: SIMD3<Float>(0, 0, 0),
            nodeType: .manualWaypoint,
            linkedAnchorID: nil,
            createdAt: Date()
        )
        let b = NavGraphNode(
            id: UUID(),
            name: "Waypoint 2",
            position: SIMD3<Float>(1, 0, 0.5),
            nodeType: .manualWaypoint,
            linkedAnchorID: nil,
            createdAt: Date()
        )
        return NavGraphArtifact(
            mapName: "test",
            createdAt: Date(),
            updatedAt: Date(),
            version: 1,
            nodes: [a, b],
            edges: []
        )
    }

    private func makeAnchor(name: String) -> SavedSemanticAnchor {
        SavedSemanticAnchor(
            id: UUID(),
            name: name,
            type: .door,
            createdAt: Date(),
            transform: matrix_identity_float4x4.flatArray
        )
    }
}
