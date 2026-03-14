//
//  NavigationPlanner.swift
//  Cluesive
//
//  Pure route planning from current pose to a linked destination anchor.
//

import Foundation
import simd

enum NavigationPlanner {
    static let defaultStartThresholdMeters: Float = 1.25

    static func planRoute(
        currentPose: simd_float4x4,
        destinationAnchorID: UUID,
        graph: NavGraphArtifact,
        anchors: [SavedSemanticAnchor],
        startThresholdMeters: Float = defaultStartThresholdMeters
    ) -> Result<PlannedRoute, RoutePlanningError> {
        let validation = GraphManager.validate(graph: graph, anchors: anchors)
        guard validation.isValid else {
            return .failure(.graphInvalid)
        }

        guard let destinationNode = GraphManager.node(forLinkedAnchorID: destinationAnchorID, in: graph) else {
            return .failure(.destinationAnchorNotLinked)
        }

        guard let startNode = GraphManager.nearestNode(
            to: currentPose.translation,
            in: graph,
            thresholdMeters: startThresholdMeters
        ) else {
            return .failure(.startPoseNotNearGraph)
        }

        let adjacency = GraphManager.adjacency(graph: graph)
        guard let nodePath = shortestPath(
            from: startNode.id,
            to: destinationNode.id,
            graph: graph,
            adjacency: adjacency
        ) else {
            return .failure(.noPath)
        }

        let nodeMap = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
        let segments = makeSegments(nodePath: nodePath, nodeMap: nodeMap)
        let totalDistance = segments.reduce(0) { $0 + $1.distanceMeters }

        return .success(
            PlannedRoute(
                destinationAnchorID: destinationAnchorID,
                destinationNodeID: destinationNode.id,
                startNodeID: startNode.id,
                nodePath: nodePath,
                segments: segments,
                totalDistanceMeters: totalDistance
            )
        )
    }

    private static func shortestPath(
        from start: UUID,
        to goal: UUID,
        graph: NavGraphArtifact,
        adjacency: [UUID: Set<UUID>]
    ) -> [UUID]? {
        var distances = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, Float.greatestFiniteMagnitude) })
        var previous: [UUID: UUID] = [:]
        var unvisited = Set(graph.nodes.map(\.id))
        distances[start] = 0
        let edgeMap = Dictionary(uniqueKeysWithValues: graph.edges.map { (GraphManager.normalizedEdgeKey($0.fromNodeID, $0.toNodeID), $0.distanceMeters) })

        while !unvisited.isEmpty {
            guard let current = unvisited.min(by: { distances[$0, default: .greatestFiniteMagnitude] < distances[$1, default: .greatestFiniteMagnitude] }),
                  distances[current, default: .greatestFiniteMagnitude].isFinite else {
                break
            }

            unvisited.remove(current)
            if current == goal { break }

            for neighbor in adjacency[current, default: []] where unvisited.contains(neighbor) {
                let key = GraphManager.normalizedEdgeKey(current, neighbor)
                let edgeDistance = edgeMap[key] ?? Float.greatestFiniteMagnitude
                let candidate = distances[current, default: .greatestFiniteMagnitude] + edgeDistance
                if candidate < distances[neighbor, default: .greatestFiniteMagnitude] {
                    distances[neighbor] = candidate
                    previous[neighbor] = current
                }
            }
        }

        guard start == goal || previous[goal] != nil else { return nil }
        var path: [UUID] = [goal]
        var cursor = goal
        while cursor != start {
            guard let prev = previous[cursor] else { return nil }
            path.append(prev)
            cursor = prev
        }
        return path.reversed()
    }

    private static func makeSegments(nodePath: [UUID], nodeMap: [UUID: NavGraphNode]) -> [RouteSegment] {
        guard nodePath.count >= 2 else { return [] }
        var segments: [RouteSegment] = []
        for index in 0..<(nodePath.count - 1) {
            guard let from = nodeMap[nodePath[index]],
                  let to = nodeMap[nodePath[index + 1]] else { continue }
            let dx = to.position.x - from.position.x
            let dz = to.position.z - from.position.z
            let headingDegrees = atan2(dz, dx) * 180 / .pi
            segments.append(
                RouteSegment(
                    fromNodeID: from.id,
                    toNodeID: to.id,
                    startPosition: from.position,
                    endPosition: to.position,
                    headingDegrees: headingDegrees,
                    distanceMeters: GraphManager.edgeDistance(from: from.position, to: to.position)
                )
            )
        }
        return segments
    }
}
