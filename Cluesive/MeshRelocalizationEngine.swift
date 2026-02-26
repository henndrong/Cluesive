//
//  MeshRelocalizationEngine.swift
//  Cluesive
//
//  Mesh artifact extraction and geometric relocalization helpers.
//

import Foundation
import ARKit

enum MeshRelocalizationEngine {
    static func buildMeshMapArtifact(from frame: ARFrame, mapName: String = Phase1MapStore.mapName) -> MeshMapArtifact? {
        let meshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
        guard !meshAnchors.isEmpty else { return nil }

        var records: [MeshAnchorRecord] = []
        records.reserveCapacity(meshAnchors.count)
        for meshAnchor in meshAnchors {
            guard let record = meshAnchor.toRecord() else { continue }
            records.append(record)
        }
        guard !records.isEmpty else { return nil }

        let descriptor = buildMeshSignatureDescriptor(from: records)
        return MeshMapArtifact(
            mapName: mapName,
            capturedAt: Date(),
            meshAnchors: records,
            descriptor: descriptor,
            version: 1
        )
    }

    static func extractLiveMeshSnapshot(from frame: ARFrame) -> MeshMapArtifact? {
        buildMeshMapArtifact(from: frame, mapName: "live")
    }

    static func runCoarseMeshSignatureMatch(from frame: ARFrame, saved: MeshMapArtifact) -> [MeshRelocalizationHypothesis] {
        guard let live = extractLiveMeshSnapshot(from: frame) else { return [] }

        let s = saved.descriptor
        let l = live.descriptor
        guard !s.dominantYawBins.isEmpty, !l.dominantYawBins.isEmpty else { return [] }
        let count = min(s.dominantYawBins.count, l.dominantYawBins.count)

        var hypotheses: [MeshRelocalizationHypothesis] = []
        hypotheses.reserveCapacity(count)
        for shift in 0..<count {
            var corr: Float = 0
            for i in 0..<count {
                corr += s.dominantYawBins[i] * l.dominantYawBins[(i + shift) % count]
            }
            let yawStep = 360.0 / Float(count)
            let yaw = Float(shift) * yawStep
            let sCenter = (s.boundsMinXZ + s.boundsMaxXZ) * 0.5
            let lCenter = (l.boundsMinXZ + l.boundsMaxXZ) * 0.5
            let t = sCenter - lCenter
            let occBonus: Float = (s.occupancyHash.first == l.occupancyHash.first) ? 0.1 : 0.0
            hypotheses.append(
                MeshRelocalizationHypothesis(
                    yawDegrees: yaw,
                    translationXZ: t,
                    coarseConfidence: min(max(corr + occBonus, 0), 1),
                    source: "signature"
                )
            )
        }

        return hypotheses.sorted { $0.coarseConfidence > $1.coarseConfidence }.prefix(3).map { $0 }
    }

    static func runICPLiteRefinement(
        hypotheses: [MeshRelocalizationHypothesis],
        frame: ARFrame,
        currentYaw: Float,
        saved: MeshMapArtifact
    ) -> MeshRelocalizationResult? {
        guard let liveArtifact = extractLiveMeshSnapshot(from: frame) else { return nil }

        let livePoints = downsamplePointCloud(flatPointsToSIMD(liveArtifact.meshAnchors.flatMap(\.vertices)), maxPoints: 1200)
        let savedPoints = downsamplePointCloud(flatPointsToSIMD(saved.meshAnchors.flatMap(\.vertices)), maxPoints: 1200)
        guard !livePoints.isEmpty, !savedPoints.isEmpty else { return nil }

        let savedCentroid = centroidXZ(savedPoints)
        let liveCentroid = centroidXZ(livePoints)

        var best: MeshRelocalizationHypothesis?
        var bestScore: Float = -.infinity
        for h in hypotheses {
            let yawDelta = angleDistanceDegrees(currentYaw * 180 / .pi, h.yawDegrees)
            let centroidT = savedCentroid - liveCentroid
            let combinedT = (h.translationXZ + centroidT) * 0.5
            let extentPenalty = min(
                simd_length(
                    (saved.descriptor.boundsMaxXZ - saved.descriptor.boundsMinXZ) -
                    (liveArtifact.descriptor.boundsMaxXZ - liveArtifact.descriptor.boundsMinXZ)
                ),
                3
            )
            let score = h.coarseConfidence - (abs(yawDelta) / 180) * 0.25 - extentPenalty * 0.05
            if score > bestScore {
                bestScore = score
                best = MeshRelocalizationHypothesis(
                    yawDegrees: h.yawDegrees,
                    translationXZ: combinedT,
                    coarseConfidence: min(max(score, 0), 1),
                    source: "icp_refined"
                )
            }
        }

        guard let refined = best else { return nil }
        let coarse = hypotheses.first
        let confidence = min(max((coarse?.coarseConfidence ?? 0) * 0.4 + refined.coarseConfidence * 0.6, 0), 1)
        let orientationHint = normalizedDegrees(refined.yawDegrees - currentYaw * 180 / .pi)
        let areaHint = simd_length(refined.translationXZ) > 1.5 ? "room edge side" : "room center side"
        let supportCount = min(livePoints.count, savedPoints.count)
        let residual = min(max(1 - refined.coarseConfidence, 0), 1) * 0.35 + 0.03
        let overlap = min(max(refined.coarseConfidence * 0.75 + 0.15, 0), 1)
        let yawConfidence = max(6, 25 - confidence * 18)

        return MeshRelocalizationResult(
            coarsePoseSeed: coarse,
            refinedPoseSeed: refined,
            orientationHintDegrees: orientationHint,
            areaHint: areaHint,
            confidence: confidence,
            residualErrorMeters: residual,
            overlapRatio: overlap,
            yawConfidenceDegrees: yawConfidence,
            supportingPointCount: supportCount,
            isStableAcrossFrames: false,
            debugReason: "Coarse descriptor hypotheses + centroid/extent bounded refinement"
        )
    }

    static func buildMeshSignatureDescriptor(from meshAnchors: [MeshAnchorRecord]) -> MeshSignatureDescriptor {
        var points: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        points.reserveCapacity(meshAnchors.reduce(0) { $0 + ($1.vertices.count / 3) })

        for record in meshAnchors {
            points.append(contentsOf: record.vertices.chunked3SIMD)
            if let flatNormals = record.normals {
                normals.append(contentsOf: flatNormals.chunked3SIMD)
            }
        }

        let dsPoints = downsamplePointCloud(points, maxPoints: 5000)
        let wallNormals = estimateWallLikePlanes(points: dsPoints, normals: normals)

        var yawBins = Array(repeating: Float(0), count: 12)
        for n in wallNormals {
            let yaw = atan2(n.z, n.x)
            var idx = Int(((yaw + .pi) / (2 * .pi)) * Float(yawBins.count))
            idx = max(0, min(yawBins.count - 1, idx))
            yawBins[idx] += 1
        }
        let yawSum = max(yawBins.reduce(0, +), 1)
        yawBins = yawBins.map { $0 / yawSum }

        let heights = dsPoints.map(\.y)
        let minY = heights.min() ?? 0
        let maxY = heights.max() ?? 1
        let hRange = max(maxY - minY, 0.001)
        var heightBins = Array(repeating: Float(0), count: 8)
        for y in heights {
            var idx = Int(((y - minY) / hRange) * Float(heightBins.count))
            idx = max(0, min(heightBins.count - 1, idx))
            heightBins[idx] += 1
        }
        let hSum = max(heightBins.reduce(0, +), 1)
        heightBins = heightBins.map { $0 / hSum }

        let xzs = dsPoints.map { SIMD2<Float>($0.x, $0.z) }
        let minX = xzs.map(\.x).min() ?? 0
        let minZ = xzs.map(\.y).min() ?? 0
        let maxX = xzs.map(\.x).max() ?? 0
        let maxZ = xzs.map(\.y).max() ?? 0
        let occupancyHash = coarseOccupancyHash(pointsXZ: xzs, minX: minX, minZ: minZ, maxX: maxX, maxZ: maxZ)

        return MeshSignatureDescriptor(
            dominantYawBins: yawBins,
            heightHistogram: heightBins,
            occupancyHash: occupancyHash,
            boundsMinXZ: SIMD2(minX, minZ),
            boundsMaxXZ: SIMD2(maxX, maxZ),
            pointCount: dsPoints.count
        )
    }

    static func downsamplePointCloud(_ points: [SIMD3<Float>], maxPoints: Int) -> [SIMD3<Float>] {
        guard points.count > maxPoints, maxPoints > 0 else { return points }
        let step = max(1, points.count / maxPoints)
        return Swift.stride(from: 0, to: points.count, by: step).map { points[$0] }
    }

    static func estimateWallLikePlanes(points: [SIMD3<Float>], normals: [SIMD3<Float>]) -> [SIMD3<Float>] {
        let _ = points
        guard !normals.isEmpty else {
            // Fallback heuristic if normals unavailable: infer no strong wall normals.
            return []
        }
        return normals.filter { abs($0.y) < 0.45 }.map { simd_normalize(SIMD3($0.x, 0, $0.z)) }
    }

    private static func coarseOccupancyHash(
        pointsXZ: [SIMD2<Float>],
        minX: Float,
        minZ: Float,
        maxX: Float,
        maxZ: Float
    ) -> [UInt64] {
        guard !pointsXZ.isEmpty else { return [0] }
        let nx = 8
        let nz = 8
        let sx = max(maxX - minX, 0.01)
        let sz = max(maxZ - minZ, 0.01)
        var bits = Array(repeating: false, count: nx * nz)
        for p in pointsXZ {
            let ix = max(0, min(nx - 1, Int(((p.x - minX) / sx) * Float(nx))))
            let iz = max(0, min(nz - 1, Int(((p.y - minZ) / sz) * Float(nz))))
            bits[iz * nx + ix] = true
        }

        var word: UInt64 = 0
        for (i, bit) in bits.enumerated() where bit {
            word |= (UInt64(1) << UInt64(i))
        }
        return [word]
    }
}
