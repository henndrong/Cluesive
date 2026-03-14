//
//  GraphManager.swift
//  Cluesive
//
//  Manual navigation graph creation, mutation, linking, and validation helpers.
//

import Foundation
import simd

enum GraphManager {
    static func defaultWaypointName(existingNodes: [NavGraphNode]) -> String {
        "Waypoint \(existingNodes.count + 1)"
    }

    static func createWaypoint(
        in graph: NavGraphArtifact,
        position: SIMD3<Float>,
        name: String? = nil
    ) -> NavGraphArtifact {
        var updated = graph
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let node = NavGraphNode(
            id: UUID(),
            name: trimmedName.isEmpty ? defaultWaypointName(existingNodes: graph.nodes) : trimmedName,
            position: position,
            nodeType: .manualWaypoint,
            linkedAnchorID: nil,
            createdAt: Date()
        )
        updated.nodes.append(node)
        updated.updatedAt = Date()
        return updated
    }

    static func renameNode(in graph: NavGraphArtifact, nodeID: UUID, newName: String) -> NavGraphArtifact {
        var updated = graph
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = updated.nodes.firstIndex(where: { $0.id == nodeID }) else { return graph }
        updated.nodes[index].name = trimmed
        updated.updatedAt = Date()
        return updated
    }

    static func deleteNode(in graph: NavGraphArtifact, nodeID: UUID) -> NavGraphArtifact {
        var updated = graph
        updated.nodes.removeAll { $0.id == nodeID }
        updated.edges.removeAll { $0.fromNodeID == nodeID || $0.toNodeID == nodeID }
        updated.updatedAt = Date()
        return updated
    }

    static func edgeDistance(from: SIMD3<Float>, to: SIMD3<Float>) -> Float {
        simd_distance(SIMD2(from.x, from.z), SIMD2(to.x, to.z))
    }

    static func normalizedEdgeKey(_ a: UUID, _ b: UUID) -> String {
        let pair = [a.uuidString, b.uuidString].sorted()
        return "\(pair[0])|\(pair[1])"
    }

    static func createEdge(in graph: NavGraphArtifact, from fromNodeID: UUID, to toNodeID: UUID) -> (graph: NavGraphArtifact, error: String?) {
        guard fromNodeID != toNodeID else {
            return (graph, "Cannot connect a waypoint to itself")
        }
        guard let fromNode = graph.nodes.first(where: { $0.id == fromNodeID }),
              let toNode = graph.nodes.first(where: { $0.id == toNodeID }) else {
            return (graph, "Cannot connect missing waypoints")
        }
        let targetKey = normalizedEdgeKey(fromNodeID, toNodeID)
        guard !graph.edges.contains(where: { normalizedEdgeKey($0.fromNodeID, $0.toNodeID) == targetKey }) else {
            return (graph, "Edge already exists")
        }

        var updated = graph
        updated.edges.append(
            NavGraphEdge(
                id: UUID(),
                fromNodeID: fromNodeID,
                toNodeID: toNodeID,
                distanceMeters: edgeDistance(from: fromNode.position, to: toNode.position)
            )
        )
        updated.updatedAt = Date()
        return (updated, nil)
    }

    static func deleteEdge(in graph: NavGraphArtifact, edgeID: UUID) -> NavGraphArtifact {
        var updated = graph
        updated.edges.removeAll { $0.id == edgeID }
        updated.updatedAt = Date()
        return updated
    }

    static func linkAnchor(in graph: NavGraphArtifact, nodeID: UUID, anchorID: UUID?) -> NavGraphArtifact {
        var updated = graph
        if let anchorID {
            for index in updated.nodes.indices where updated.nodes[index].linkedAnchorID == anchorID {
                updated.nodes[index].linkedAnchorID = nil
                updated.nodes[index].nodeType = .manualWaypoint
            }
        }
        guard let nodeIndex = updated.nodes.firstIndex(where: { $0.id == nodeID }) else { return graph }
        updated.nodes[nodeIndex].linkedAnchorID = anchorID
        updated.nodes[nodeIndex].nodeType = anchorID == nil ? .manualWaypoint : .anchorLinked
        updated.updatedAt = Date()
        return updated
    }

    static func nearestWaypoint(
        to anchor: SavedSemanticAnchor,
        in graph: NavGraphArtifact,
        thresholdMeters: Float
    ) -> NavGraphNode? {
        guard let transform = simd_float4x4(flatArray: anchor.transform) else { return nil }
        let anchorPosition = transform.translation
        return graph.nodes
            .map { node in (node, edgeDistance(from: node.position, to: anchorPosition)) }
            .filter { $0.1 <= thresholdMeters }
            .sorted { $0.1 < $1.1 }
            .first?
            .0
    }

    static func validate(graph: NavGraphArtifact, anchors: [SavedSemanticAnchor]) -> GraphValidationResult {
        var warnings: [String] = []
        var disconnectedNodeIDs: [UUID] = []
        var duplicatePairs: [(UUID, UUID)] = []
        let nodeIDs = Set(graph.nodes.map(\.id))

        if graph.nodes.count < 2 {
            warnings.append("Need at least 2 waypoints")
        }
        if graph.edges.isEmpty {
            warnings.append("Need at least 1 edge")
        }

        var seenEdgeKeys = Set<String>()
        for edge in graph.edges {
            if !nodeIDs.contains(edge.fromNodeID) || !nodeIDs.contains(edge.toNodeID) {
                warnings.append("Graph contains edges with missing waypoints")
                break
            }
            let key = normalizedEdgeKey(edge.fromNodeID, edge.toNodeID)
            if !seenEdgeKeys.insert(key).inserted {
                duplicatePairs.append((edge.fromNodeID, edge.toNodeID))
            }
        }
        if !duplicatePairs.isEmpty {
            warnings.append("Graph contains duplicate edges")
        }

        let anchorIDs = Set(anchors.map(\.id))
        let invalidLinkedNodes = graph.nodes.filter { linked in
            guard let linkedAnchorID = linked.linkedAnchorID else { return false }
            return !anchorIDs.contains(linkedAnchorID)
        }
        if !invalidLinkedNodes.isEmpty {
            warnings.append("Graph contains invalid anchor links")
        }

        if graph.nodes.count > 1 {
            let adjacency = buildAdjacency(graph: graph)
            let reachable = traverse(start: graph.nodes[0].id, adjacency: adjacency)
            disconnectedNodeIDs = graph.nodes.map(\.id).filter { !reachable.contains($0) }
            if !disconnectedNodeIDs.isEmpty {
                warnings.append("Graph contains disconnected waypoints")
            }
        }

        let hasDoor = anchors.contains { $0.type == .door }
        let hasRoomEntrance = anchors.contains { $0.type == .roomEntrance }
        let linkedAnchorIDs = Set(graph.nodes.compactMap(\.linkedAnchorID))
        if hasDoor && hasRoomEntrance {
            let linkedTypes = Set(anchors.filter { linkedAnchorIDs.contains($0.id) }.map(\.type))
            if !linkedTypes.contains(.door) || !linkedTypes.contains(.roomEntrance) {
                warnings.append("Link door and room entrance anchors to graph waypoints")
            }
        }

        return GraphValidationResult(
            isValid: warnings.isEmpty,
            warnings: warnings,
            linkedAnchorCount: linkedAnchorIDs.count,
            disconnectedNodeIDs: disconnectedNodeIDs,
            duplicateEdgePairs: duplicatePairs
        )
    }

    private static func buildAdjacency(graph: NavGraphArtifact) -> [UUID: Set<UUID>] {
        var adjacency: [UUID: Set<UUID>] = [:]
        for node in graph.nodes {
            adjacency[node.id] = adjacency[node.id, default: []]
        }
        for edge in graph.edges {
            adjacency[edge.fromNodeID, default: []].insert(edge.toNodeID)
            adjacency[edge.toNodeID, default: []].insert(edge.fromNodeID)
        }
        return adjacency
    }

    private static func traverse(start: UUID, adjacency: [UUID: Set<UUID>]) -> Set<UUID> {
        var visited: Set<UUID> = []
        var stack: [UUID] = [start]

        while let current = stack.popLast() {
            guard visited.insert(current).inserted else { continue }
            stack.append(contentsOf: adjacency[current, default: []].filter { !visited.contains($0) })
        }

        return visited
    }
}
