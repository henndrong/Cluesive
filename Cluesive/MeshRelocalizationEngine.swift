//
//  MeshRelocalizationEngine.swift
//  Cluesive
//
//  Mesh artifact extraction and geometric relocalization helpers.
//

import Foundation
import ARKit
import Vision

enum MeshRelocalizationEngine {
    struct LiveFallbackInput {
        let points: [SIMD3<Float>]
        let descriptor: MeshSignatureDescriptor
    }

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

    static func buildStructureSignature(from frame: ARFrame, mapName: String = Phase1MapStore.mapName) -> StructureSignatureArtifact? {
        guard let mesh = buildMeshMapArtifact(from: frame, mapName: mapName) else { return nil }
        return buildStructureSignature(from: mesh)
    }

    static func buildStructureSignature(from mesh: MeshMapArtifact) -> StructureSignatureArtifact? {
        let descriptor = mesh.descriptor
        guard !descriptor.dominantYawBins.isEmpty else { return nil }
        let floorY = estimateFloorY(from: mesh)
        let segments = estimateStructureSegments(from: descriptor)
        return StructureSignatureArtifact(
            mapName: mesh.mapName,
            capturedAt: mesh.capturedAt,
            dominantYawBins: descriptor.dominantYawBins,
            floorYEstimate: floorY,
            boundsMinXZ: descriptor.boundsMinXZ,
            boundsMaxXZ: descriptor.boundsMaxXZ,
            structuralSegments: segments,
            version: 1
        )
    }

    static func buildVisionIndex(from frame: ARFrame, mapName: String = Phase1MapStore.mapName) -> VisionIndexArtifact? {
        guard let featurePrint = featurePrintData(from: frame.capturedImage) else { return nil }
        let record = VisionFeatureRecord(
            id: UUID(),
            capturedAt: Date(),
            mapFromSessionTransform: frame.camera.transform.flatArray,
            featurePrintData: featurePrint
        )
        return VisionIndexArtifact(
            mapName: mapName,
            capturedAt: Date(),
            records: [record],
            version: 1
        )
    }

    static func retrieveVisionPlaceCandidate(from frame: ARFrame, saved: VisionIndexArtifact) -> VisionPlaceCandidate? {
        guard let live = featurePrintObservation(from: frame.capturedImage) else { return nil }
        var best: VisionPlaceCandidate?
        for record in saved.records {
            guard
                let savedObs = featurePrintObservation(from: record.featurePrintData),
                let transform = simd_float4x4(flatArray: record.mapFromSessionTransform)
            else { continue }
            var distance: Float = .greatestFiniteMagnitude
            do {
                try live.computeDistance(&distance, to: savedObs)
            } catch {
                continue
            }
            let confidence = max(0, min(1, 1 - distance))
            let candidate = VisionPlaceCandidate(
                recordID: record.id,
                mapFromSessionTransform: transform,
                distance: distance,
                confidence: confidence
            )
            if best == nil || candidate.distance < best!.distance {
                best = candidate
            }
        }
        return best
    }

    static func runCoarseMeshSignatureMatch(from frame: ARFrame, saved: MeshMapArtifact) -> [MeshRelocalizationHypothesis] {
        guard let liveInput = buildLiveFallbackInput(from: frame) else { return [] }
        return runCoarseMeshSignatureMatch(liveDescriptor: liveInput.descriptor, saved: saved)
    }

    static func runCoarseMeshSignatureMatch(liveDescriptor: MeshSignatureDescriptor, saved: MeshMapArtifact) -> [MeshRelocalizationHypothesis] {
        let s = saved.descriptor
        let l = liveDescriptor
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

    static func downsampleSavedMeshPoints(_ saved: MeshMapArtifact, maxPoints: Int) -> [SIMD3<Float>] {
        downsamplePointCloud(flatPointsToSIMD(saved.meshAnchors.flatMap(\.vertices)), maxPoints: maxPoints)
    }

    static func buildLiveFallbackInput(
        from frame: ARFrame,
        maxAnchors: Int = 10,
        maxPointsPerAnchor: Int = 240,
        maxTotalPoints: Int = 1200
    ) -> LiveFallbackInput? {
        let meshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
        guard !meshAnchors.isEmpty else { return nil }

        var points: [SIMD3<Float>] = []
        points.reserveCapacity(maxTotalPoints)
        var normals: [SIMD3<Float>] = []
        normals.reserveCapacity(maxTotalPoints)

        for meshAnchor in meshAnchors.prefix(maxAnchors) {
            let sampled = sampleMeshGeometry(
                meshAnchor.geometry,
                maxPoints: maxPointsPerAnchor,
                remainingCapacity: maxTotalPoints - points.count
            )
            if sampled.points.isEmpty { continue }
            points.append(contentsOf: sampled.points)
            if !sampled.normals.isEmpty {
                normals.append(contentsOf: sampled.normals)
            }
            if points.count >= maxTotalPoints { break }
        }

        guard !points.isEmpty else { return nil }
        let descriptor = buildMeshSignatureDescriptor(points: points, normals: normals)
        return LiveFallbackInput(points: points, descriptor: descriptor)
    }

    static func runICPLiteRefinement(
        hypotheses: [MeshRelocalizationHypothesis],
        frame: ARFrame,
        currentYaw: Float,
        saved: MeshMapArtifact,
        savedPoints: [SIMD3<Float>],
        livePoints: [SIMD3<Float>],
        liveDescriptor: MeshSignatureDescriptor,
        savedStructure: StructureSignatureArtifact?,
        savedVision: VisionIndexArtifact?,
        visionCandidate: VisionPlaceCandidate?,
        mode: FallbackLocalizationMode
    ) -> MeshRelocalizationResult? {
        let resolvedSavedPoints = savedPoints.isEmpty ? downsampleSavedMeshPoints(saved, maxPoints: 1200) : savedPoints
        guard !livePoints.isEmpty, !resolvedSavedPoints.isEmpty else { return nil }
        let liveStructure = buildStructureSignature(
            from: MeshMapArtifact(
                mapName: "live",
                capturedAt: Date(),
                meshAnchors: [],
                descriptor: liveDescriptor,
                version: 1
            )
        )
        let resolvedVisionCandidate: VisionPlaceCandidate?
        if let visionCandidate {
            resolvedVisionCandidate = visionCandidate
        } else if mode == .hybridGeometryVision, let savedVision {
            resolvedVisionCandidate = retrieveVisionPlaceCandidate(from: frame, saved: savedVision)
        } else {
            resolvedVisionCandidate = nil
        }

        let savedCentroid = centroidXZ(resolvedSavedPoints)
        let liveCentroid = centroidXZ(livePoints)

        var best: MeshRelocalizationHypothesis?
        var bestScore: Float = -.infinity
        for h in hypotheses {
            let yawDelta = angleDistanceDegrees(currentYaw * 180 / .pi, h.yawDegrees)
            let centroidT = savedCentroid - liveCentroid
            let combinedT = (h.translationXZ + centroidT) * 0.5
            let structureBoost = structureAgreementBoost(
                hypothesis: h,
                saved: savedStructure,
                live: liveStructure
            )
            let visionBoost: Float
            if let resolvedVisionCandidate {
                let visionYaw = resolvedVisionCandidate.mapFromSessionTransform.forwardYawRadians * 180 / .pi
                let yawAgreement = max(0, 1 - angleDistanceDegrees(h.yawDegrees, visionYaw) / 180)
                visionBoost = (resolvedVisionCandidate.confidence * 0.2) + (yawAgreement * 0.1)
            } else {
                visionBoost = 0
            }
            let extentPenalty = min(
                simd_length(
                    (saved.descriptor.boundsMaxXZ - saved.descriptor.boundsMinXZ) -
                    (liveDescriptor.boundsMaxXZ - liveDescriptor.boundsMinXZ)
                ),
                3
            )
            let score = h.coarseConfidence
                + structureBoost
                + visionBoost
                - (abs(yawDelta) / 180) * 0.25
                - extentPenalty * 0.05
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
        let confidenceBand = fallbackConfidenceBand(for: confidence)
        let orientationHint = normalizedDegrees(refined.yawDegrees - currentYaw * 180 / .pi)
        let areaHint = simd_length(refined.translationXZ) > 1.5 ? "room edge side" : "room center side"
        let supportCount = min(livePoints.count, resolvedSavedPoints.count)
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
            debugReason: "Hybrid structure/vision-seeded descriptor + centroid/extent bounded refinement",
            confidenceBand: confidenceBand,
            visionSeedDistance: resolvedVisionCandidate?.distance
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

        return buildMeshSignatureDescriptor(points: points, normals: normals)
    }

    private static func buildMeshSignatureDescriptor(points: [SIMD3<Float>], normals: [SIMD3<Float>]) -> MeshSignatureDescriptor {
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

    private static func estimateFloorY(from artifact: MeshMapArtifact) -> Float {
        let points = artifact.meshAnchors.flatMap(\.vertices).chunked3SIMD
        guard !points.isEmpty else { return 0 }
        let ys = points.map(\.y).sorted()
        return ys[max(0, Int(Float(ys.count) * 0.05))]
    }

    private static func estimateStructureSegments(from descriptor: MeshSignatureDescriptor) -> [StructureSegment2D] {
        guard !descriptor.dominantYawBins.isEmpty else { return [] }
        let center = (descriptor.boundsMinXZ + descriptor.boundsMaxXZ) * 0.5
        let radius = simd_length(descriptor.boundsMaxXZ - descriptor.boundsMinXZ) * 0.5
        let yawStep = 360.0 / Float(descriptor.dominantYawBins.count)
        return descriptor.dominantYawBins.enumerated().compactMap { idx, weight in
            guard weight > 0.04 else { return nil }
            let degrees = Float(idx) * yawStep - 180
            let rad = degrees * .pi / 180
            let dir = SIMD2<Float>(cos(rad), sin(rad))
            let tangent = SIMD2<Float>(-dir.y, dir.x)
            let p0 = center - tangent * radius * 0.5
            let p1 = center + tangent * radius * 0.5
            return StructureSegment2D(start: p0, end: p1, orientationDegrees: degrees, supportWeight: weight)
        }
    }

    private static func structureAgreementBoost(
        hypothesis: MeshRelocalizationHypothesis,
        saved: StructureSignatureArtifact?,
        live: StructureSignatureArtifact?
    ) -> Float {
        guard let saved, let live else { return 0 }
        guard !saved.dominantYawBins.isEmpty, !live.dominantYawBins.isEmpty else { return 0 }
        let count = min(saved.dominantYawBins.count, live.dominantYawBins.count)
        var corr: Float = 0
        for i in 0..<count {
            corr += saved.dominantYawBins[i] * live.dominantYawBins[i]
        }
        let shiftedYawDistance = angleDistanceDegrees(hypothesis.yawDegrees, 0)
        let yawPenalty = (shiftedYawDistance / 180) * 0.05
        return max(0, min(corr, 1) * 0.12 - yawPenalty)
    }

    private static func fallbackConfidenceBand(for confidence: Float) -> FallbackConfidenceBand {
        if confidence >= 0.82 { return .high }
        if confidence >= 0.65 { return .medium }
        return .low
    }

    private static func featurePrintData(from pixelBuffer: CVPixelBuffer) -> Data? {
        guard let observation = featurePrintObservation(from: pixelBuffer) else { return nil }
        return try? NSKeyedArchiver.archivedData(withRootObject: observation, requiringSecureCoding: true)
    }

    private static func featurePrintObservation(from data: Data) -> VNFeaturePrintObservation? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: data)
    }

    private static func featurePrintObservation(from pixelBuffer: CVPixelBuffer) -> VNFeaturePrintObservation? {
        autoreleasepool {
            let request = VNGenerateImageFeaturePrintRequest()
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
            do {
                try handler.perform([request])
                return request.results?.first as? VNFeaturePrintObservation
            } catch {
                return nil
            }
        }
    }

    private static func sampleMeshGeometry(
        _ geometry: ARMeshGeometry,
        maxPoints: Int,
        remainingCapacity: Int
    ) -> (points: [SIMD3<Float>], normals: [SIMD3<Float>]) {
        let capacity = max(0, min(maxPoints, remainingCapacity))
        guard capacity > 0 else { return ([], []) }

        let vertexSource = geometry.vertices
        guard vertexSource.count > 0 else { return ([], []) }
        let normalSource = geometry.normals
        let sampleCount = min(vertexSource.count, capacity)
        let step = max(1, vertexSource.count / sampleCount)

        let vertexPtr = vertexSource.buffer.contents()
        let normalPtr = normalSource.buffer.contents()
        let hasNormals = normalSource.count > 0

        var sampledPoints: [SIMD3<Float>] = []
        sampledPoints.reserveCapacity(sampleCount)
        var sampledNormals: [SIMD3<Float>] = []
        sampledNormals.reserveCapacity(sampleCount)

        var idx = 0
        while idx < vertexSource.count && sampledPoints.count < sampleCount {
            let vertexOffset = vertexSource.offset + vertexSource.stride * idx
            let point = vertexPtr.advanced(by: vertexOffset).assumingMemoryBound(to: SIMD3<Float>.self).pointee
            sampledPoints.append(point)

            if hasNormals {
                let normalIndex = min(idx, max(0, normalSource.count - 1))
                let normalOffset = normalSource.offset + normalSource.stride * normalIndex
                let normal = normalPtr.advanced(by: normalOffset).assumingMemoryBound(to: SIMD3<Float>.self).pointee
                sampledNormals.append(normal)
            }
            idx += step
        }

        return (sampledPoints, sampledNormals)
    }

    static func estimateWallLikePlanes(points: [SIMD3<Float>], normals: [SIMD3<Float>]) -> [SIMD3<Float>] {
        let _ = points
        guard !normals.isEmpty else {
            // Fallback heuristic if normals unavailable: infer no strong wall normals.
            return []
        }
        return normals.compactMap { normal in
            guard abs(normal.y) < 0.45 else { return nil }
            let flattened = SIMD3<Float>(normal.x, 0, normal.z)
            let length = simd_length(flattened)
            guard length > 0.0001, length.isFinite else { return nil }
            let unit = flattened / length
            guard unit.x.isFinite, unit.y.isFinite, unit.z.isFinite else { return nil }
            return unit
        }
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
