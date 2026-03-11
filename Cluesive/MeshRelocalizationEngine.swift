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
        let normals: [SIMD3<Float>]
        let descriptor: MeshSignatureDescriptor
    }

    struct VisionCandidateSelection {
        let candidate: VisionPlaceCandidate?
        let diagnostics: VisionRetrievalDiagnostics
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
        var points: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        for record in mesh.meshAnchors {
            points.append(contentsOf: worldSpaceVertices(for: record))
            if let flatNormals = record.normals {
                normals.append(contentsOf: worldSpaceNormals(for: flatNormals.chunked3SIMD, transform: record.transform))
            }
        }
        return buildStructureSignature(
            mapName: mesh.mapName,
            capturedAt: mesh.capturedAt,
            points: points,
            normals: normals,
            descriptor: descriptor
        )
    }

    private static func buildStructureSignature(
        mapName: String,
        capturedAt: Date,
        points: [SIMD3<Float>],
        normals: [SIMD3<Float>],
        descriptor: MeshSignatureDescriptor
    ) -> StructureSignatureArtifact? {
        guard !descriptor.dominantYawBins.isEmpty else { return nil }
        let floorY = estimateFloorY(points: points)
        let segments = estimateStructureSegments(points: points, normals: normals, descriptor: descriptor)
        return StructureSignatureArtifact(
            mapName: mapName,
            capturedAt: capturedAt,
            dominantYawBins: descriptor.dominantYawBins,
            floorYEstimate: floorY,
            boundsMinXZ: descriptor.boundsMinXZ,
            boundsMaxXZ: descriptor.boundsMaxXZ,
            structuralSegments: segments,
            version: 1
        )
    }

    static func buildVisionIndex(from frame: ARFrame, mapName: String = Phase1MapStore.mapName) -> VisionIndexArtifact? {
        guard let record = makeVisionFeatureRecord(from: frame) else { return nil }
        return buildVisionIndex(from: [record], mapName: mapName)
    }

    static func buildVisionIndex(from records: [VisionFeatureRecord], mapName: String = Phase1MapStore.mapName) -> VisionIndexArtifact? {
        guard !records.isEmpty else { return nil }
        return VisionIndexArtifact(
            mapName: mapName,
            capturedAt: Date(),
            records: records.sorted { $0.capturedAt < $1.capturedAt },
            version: 1
        )
    }

    static func makeVisionFeatureRecord(from frame: ARFrame) -> VisionFeatureRecord? {
        guard let featurePrint = featurePrintData(from: frame.capturedImage) else { return nil }
        return VisionFeatureRecord(
            id: UUID(),
            capturedAt: Date(),
            mapFromSessionTransform: frame.camera.transform.flatArray,
            featurePrintData: featurePrint
        )
    }

    static func mergeVisionFeatureRecord(
        existing: [VisionFeatureRecord],
        candidate: VisionFeatureRecord,
        maxRecords: Int = 8,
        minimumYawSeparationDegrees: Float = 25,
        minimumTranslationSeparationMeters: Float = 0.75
    ) -> [VisionFeatureRecord] {
        let recencyOrdered = (existing + [candidate]).sorted { $0.capturedAt > $1.capturedAt }
        var selected: [VisionFeatureRecord] = []
        selected.reserveCapacity(min(maxRecords, recencyOrdered.count))

        for record in recencyOrdered {
            if selected.count >= maxRecords { break }
            guard isVisionRecordDiverse(
                record,
                comparedTo: selected,
                minimumYawSeparationDegrees: minimumYawSeparationDegrees,
                minimumTranslationSeparationMeters: minimumTranslationSeparationMeters
            ) else { continue }
            selected.append(record)
        }

        if selected.isEmpty {
            selected = Array(recencyOrdered.prefix(maxRecords))
        }

        return selected.sorted { $0.capturedAt < $1.capturedAt }
    }

    static func retrieveVisionPlaceCandidate(from frame: ARFrame, saved: VisionIndexArtifact) -> VisionPlaceCandidate? {
        retrieveVisionPlaceCandidateSelection(from: frame, saved: saved).candidate
    }

    static func retrieveVisionPlaceCandidateSelection(from frame: ARFrame, saved: VisionIndexArtifact) -> VisionCandidateSelection {
        guard let live = featurePrintObservation(from: frame.capturedImage) else {
            return VisionCandidateSelection(
                candidate: nil,
                diagnostics: VisionRetrievalDiagnostics(
                    selectedDistance: nil,
                    topCandidateDistances: [],
                    candidateCount: 0,
                    distinctiveness: 0
                )
            )
        }
        var candidates: [(recordID: UUID, transform: simd_float4x4, distance: Float)] = []
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
            candidates.append((record.id, transform, distance))
        }

        let sorted = candidates.sorted { $0.distance < $1.distance }
        let topCandidates = Array(sorted.prefix(3))
        let topDistances = topCandidates.map(\.distance)
        guard let best = topCandidates.first else {
            return VisionCandidateSelection(
                candidate: nil,
                diagnostics: VisionRetrievalDiagnostics(
                    selectedDistance: nil,
                    topCandidateDistances: [],
                    candidateCount: 0,
                    distinctiveness: 0
                )
            )
        }

        let secondDistance = topCandidates.dropFirst().first?.distance ?? best.distance
        let rawScores = topCandidates.map { exp(-max($0.distance, 0) * 4) }
        let normalizedBestScore = rawScores.first.map { $0 / max(rawScores.reduce(0, +), 0.0001) } ?? 0
        let distinctiveness = max(0, min(1, (secondDistance - best.distance) / max(secondDistance, 0.001)))
        let absoluteScore = 1 / (1 + max(best.distance, 0) * 4)
        let confidence = max(0, min(1, absoluteScore * 0.45 + normalizedBestScore * 0.35 + distinctiveness * 0.20))

        return VisionCandidateSelection(
            candidate: VisionPlaceCandidate(
                recordID: best.recordID,
                mapFromSessionTransform: best.transform,
                distance: best.distance,
                confidence: confidence
            ),
            diagnostics: VisionRetrievalDiagnostics(
                selectedDistance: best.distance,
                topCandidateDistances: topDistances,
                candidateCount: sorted.count,
                distinctiveness: distinctiveness
            )
        )
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
        let worldPoints = saved.meshAnchors.flatMap { worldSpaceVertices(for: $0) }
        return downsamplePointCloud(worldPoints, maxPoints: maxPoints)
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
                anchorTransform: meshAnchor.transform,
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
        return LiveFallbackInput(points: points, normals: normals, descriptor: descriptor)
    }

    static func runICPLiteRefinement(
        hypotheses: [MeshRelocalizationHypothesis],
        frame: ARFrame,
        currentYaw: Float,
        saved: MeshMapArtifact,
        savedPoints: [SIMD3<Float>],
        livePoints: [SIMD3<Float>],
        liveNormals: [SIMD3<Float>],
        liveDescriptor: MeshSignatureDescriptor,
        savedStructure: StructureSignatureArtifact?,
        savedVision: VisionIndexArtifact?,
        visionCandidate: VisionPlaceCandidate?,
        mode: FallbackLocalizationMode
    ) -> MeshRelocalizationResult? {
        let resolvedSavedPoints = savedPoints.isEmpty ? downsampleSavedMeshPoints(saved, maxPoints: 1200) : savedPoints
        guard !livePoints.isEmpty, !resolvedSavedPoints.isEmpty else { return nil }
        let liveStructure = buildStructureSignature(
            mapName: "live",
            capturedAt: Date(),
            points: livePoints,
            normals: liveNormals,
            descriptor: liveDescriptor
        )
        let structuralHypotheses = supplementalStructuralHypotheses(saved: savedStructure, live: liveStructure)
        let candidateHypotheses = mergedHypotheses(primary: hypotheses, supplemental: structuralHypotheses)
        let resolvedVisionSelection: VisionCandidateSelection?
        if let visionCandidate {
            resolvedVisionSelection = VisionCandidateSelection(
                candidate: visionCandidate,
                diagnostics: VisionRetrievalDiagnostics(
                    selectedDistance: visionCandidate.distance,
                    topCandidateDistances: [visionCandidate.distance],
                    candidateCount: 1,
                    distinctiveness: 0
                )
            )
        } else if mode == .hybridGeometryVision, let savedVision {
            resolvedVisionSelection = retrieveVisionPlaceCandidateSelection(from: frame, saved: savedVision)
        } else {
            resolvedVisionSelection = nil
        }
        let resolvedVisionCandidate = resolvedVisionSelection?.candidate
        let visionDiagnostics = resolvedVisionSelection?.diagnostics

        let savedCentroid = centroidXZ(resolvedSavedPoints)
        let liveCentroid = centroidXZ(livePoints)

        var best: MeshRelocalizationHypothesis?
        var bestDiagnostics: MeshFallbackDiagnostics?
        var bestResidual: Float = 1
        var bestOverlap: Float = 0
        var bestScore: Float = -.infinity
        for h in candidateHypotheses {
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
            let verificationTransform = simd_float4x4(
                yawRadians: h.yawDegrees * .pi / 180,
                translation: SIMD3<Float>(combinedT.x, 0, combinedT.y)
            )
            let verification = alignmentVerificationMetrics(
                livePoints: livePoints,
                savedPoints: resolvedSavedPoints,
                mapFromSessionTransform: verificationTransform
            )
            let score = h.coarseConfidence
                + structureBoost
                + visionBoost
                + verification.overlapRatio * 0.30
                - verification.residualErrorMeters * 0.55
                - (abs(yawDelta) / 180) * 0.25
                - extentPenalty * 0.05
            if score > bestScore {
                bestScore = score
                bestResidual = verification.residualErrorMeters
                bestOverlap = verification.overlapRatio
                bestDiagnostics = MeshFallbackDiagnostics(
                    coarseConfidence: h.coarseConfidence,
                    structureScore: structureBoost,
                    visionScore: visionBoost + verification.overlapRatio * 0.30,
                    yawPenalty: (abs(yawDelta) / 180) * 0.25,
                    extentPenalty: extentPenalty * 0.05 + verification.residualErrorMeters * 0.55,
                    finalScore: score
                )
                best = MeshRelocalizationHypothesis(
                    yawDegrees: h.yawDegrees,
                    translationXZ: combinedT,
                    coarseConfidence: min(max(score, 0), 1),
                    source: "icp_refined"
                )
            }
        }

        guard let refined = best else { return nil }
        let coarse = candidateHypotheses.first
        let confidence = min(max((coarse?.coarseConfidence ?? 0) * 0.4 + refined.coarseConfidence * 0.6, 0), 1)
        let confidenceBand = fallbackConfidenceBand(for: confidence)
        let orientationHint = normalizedDegrees(refined.yawDegrees - currentYaw * 180 / .pi)
        let areaHint = simd_length(refined.translationXZ) > 1.5 ? "room edge side" : "room center side"
        let supportCount = min(livePoints.count, resolvedSavedPoints.count)
        let residual = max(0, bestResidual)
        let overlap = max(0, min(1, bestOverlap))
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
            visionSeedDistance: resolvedVisionCandidate?.distance,
            visionDiagnostics: visionDiagnostics,
            diagnostics: bestDiagnostics
        )
    }

    static func buildMeshSignatureDescriptor(from meshAnchors: [MeshAnchorRecord]) -> MeshSignatureDescriptor {
        var points: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        points.reserveCapacity(meshAnchors.reduce(0) { $0 + ($1.vertices.count / 3) })

        for record in meshAnchors {
            let recordPoints = worldSpaceVertices(for: record)
            points.append(contentsOf: recordPoints)
            if let flatNormals = record.normals {
                normals.append(contentsOf: worldSpaceNormals(for: flatNormals.chunked3SIMD, transform: record.transform))
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
        let points = artifact.meshAnchors.flatMap { worldSpaceVertices(for: $0) }
        return estimateFloorY(points: points)
    }

    private static func estimateFloorY(points: [SIMD3<Float>]) -> Float {
        guard !points.isEmpty else { return 0 }
        let ys = points.map(\.y).sorted()
        return ys[max(0, Int(Float(ys.count) * 0.05))]
    }

    private static func estimateStructureSegments(
        points: [SIMD3<Float>],
        normals: [SIMD3<Float>],
        descriptor: MeshSignatureDescriptor
    ) -> [StructureSegment2D] {
        guard !points.isEmpty, !normals.isEmpty else { return estimateStructureSegmentsFallback(from: descriptor) }

        struct SegmentAccumulator {
            var orientationDegrees: Float
            var normal: SIMD2<Float>
            var tangent: SIMD2<Float>
            var offsetValues: [Float] = []
            var tangentValues: [Float] = []
        }

        var accumulators: [String: SegmentAccumulator] = [:]
        let count = min(points.count, normals.count)
        let floorY = estimateFloorY(points: points)

        for index in 0..<count {
            let point = points[index]
            if point.y < floorY + 0.2 { continue }
            let normal3 = normals[index]
            guard abs(normal3.y) < 0.35 else { continue }
            let normal2 = SIMD2<Float>(normal3.x, normal3.z)
            let normalLength = simd_length(normal2)
            guard normalLength > 0.0001 else { continue }
            let unitNormal = normal2 / normalLength
            let tangent = SIMD2<Float>(-unitNormal.y, unitNormal.x)
            let orientation = canonicalLineOrientationDegrees(atan2(tangent.y, tangent.x) * 180 / .pi)
            let orientationBin = Int((orientation + 90) / 15)
            let offset = simd_dot(SIMD2<Float>(point.x, point.z), unitNormal)
            let offsetBin = Int((offset + 20) / 0.75)
            let key = "\(orientationBin):\(offsetBin)"
            var accumulator = accumulators[key] ?? SegmentAccumulator(
                orientationDegrees: orientation,
                normal: unitNormal,
                tangent: tangent
            )
            accumulator.offsetValues.append(offset)
            accumulator.tangentValues.append(simd_dot(SIMD2<Float>(point.x, point.z), tangent))
            accumulators[key] = accumulator
        }

        let segments = accumulators.values.compactMap { accumulator -> StructureSegment2D? in
            guard accumulator.tangentValues.count >= 24 else { return nil }
            guard
                let minT = accumulator.tangentValues.min(),
                let maxT = accumulator.tangentValues.max()
            else { return nil }
            let span = maxT - minT
            guard span >= 1.1 else { return nil }
            let offset = accumulator.offsetValues.reduce(0, +) / Float(accumulator.offsetValues.count)
            let centerOnPlane = accumulator.normal * offset
            let p0 = centerOnPlane + accumulator.tangent * minT
            let p1 = centerOnPlane + accumulator.tangent * maxT
            let supportWeight = min(1, Float(accumulator.tangentValues.count) / 240)
            return StructureSegment2D(
                start: p0,
                end: p1,
                orientationDegrees: accumulator.orientationDegrees,
                supportWeight: supportWeight
            )
        }

        let ranked = segments.sorted {
            (segmentLength($0) * $0.supportWeight) > (segmentLength($1) * $1.supportWeight)
        }
        return Array(ranked.prefix(6))
    }

    private static func estimateStructureSegmentsFallback(from descriptor: MeshSignatureDescriptor) -> [StructureSegment2D] {
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
            return StructureSegment2D(start: p0, end: p1, orientationDegrees: canonicalLineOrientationDegrees(degrees), supportWeight: weight)
        }
    }

    private static func structureAgreementBoost(
        hypothesis: MeshRelocalizationHypothesis,
        saved: StructureSignatureArtifact?,
        live: StructureSignatureArtifact?
    ) -> Float {
        guard let saved, let live else { return 0 }
        guard !saved.structuralSegments.isEmpty, !live.structuralSegments.isEmpty else { return 0 }

        let mapFromSession = simd_float4x4(
            yawRadians: hypothesis.yawDegrees * .pi / 180,
            translation: SIMD3<Float>(hypothesis.translationXZ.x, 0, hypothesis.translationXZ.y)
        )
        let transformedLive = live.structuralSegments.map { transform(segment: $0, with: mapFromSession) }
        let totalSupport = max(transformedLive.reduce(0) { $0 + $1.supportWeight }, 0.001)

        var matchedSupport: Float = 0
        for liveSegment in transformedLive {
            guard let bestSaved = saved.structuralSegments.max(by: {
                segmentCompatibility(liveSegment, $0) < segmentCompatibility(liveSegment, $1)
            }) else { continue }
            let compatibility = segmentCompatibility(liveSegment, bestSaved)
            if compatibility < 1.2 {
                matchedSupport += liveSegment.supportWeight * max(0, 1 - compatibility / 1.2)
            }
        }

        let supportScore = matchedSupport / totalSupport
        let topologyScore = max(0, 1 - abs(boundsAspectRatio(saved) - boundsAspectRatio(live)) / 3)
        return min(0.24, supportScore * 0.18 + topologyScore * 0.06)
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

    private static func isVisionRecordDiverse(
        _ candidate: VisionFeatureRecord,
        comparedTo selected: [VisionFeatureRecord],
        minimumYawSeparationDegrees: Float,
        minimumTranslationSeparationMeters: Float
    ) -> Bool {
        guard !selected.isEmpty else { return true }
        guard let candidatePose = poseComponents(for: candidate) else { return true }

        return selected.allSatisfy { record in
            guard let recordPose = poseComponents(for: record) else { return true }
            let yawDelta = angleDistanceDegrees(candidatePose.yawDegrees, recordPose.yawDegrees)
            let translationDelta = simd_distance(candidatePose.translationXZ, recordPose.translationXZ)
            return yawDelta >= minimumYawSeparationDegrees || translationDelta >= minimumTranslationSeparationMeters
        }
    }

    private static func poseComponents(for record: VisionFeatureRecord) -> (translationXZ: SIMD2<Float>, yawDegrees: Float)? {
        guard let transform = simd_float4x4(flatArray: record.mapFromSessionTransform) else { return nil }
        return (
            SIMD2<Float>(transform.translation.x, transform.translation.z),
            transform.forwardYawRadians * 180 / .pi
        )
    }

    private static func sampleMeshGeometry(
        _ geometry: ARMeshGeometry,
        anchorTransform: simd_float4x4,
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
            let pointLocal = vertexPtr.advanced(by: vertexOffset).assumingMemoryBound(to: SIMD3<Float>.self).pointee
            let point = anchorTransform.transformPoint(pointLocal)
            sampledPoints.append(point)

            if hasNormals {
                let normalIndex = min(idx, max(0, normalSource.count - 1))
                let normalOffset = normalSource.offset + normalSource.stride * normalIndex
                let normalLocal = normalPtr.advanced(by: normalOffset).assumingMemoryBound(to: SIMD3<Float>.self).pointee
                let rotated = anchorTransform.rotateVector(normalLocal)
                let length = simd_length(rotated)
                let normal = length > 0.0001 ? rotated / length : normalLocal
                sampledNormals.append(normal)
            }
            idx += step
        }

        return (sampledPoints, sampledNormals)
    }

    static func alignmentVerificationMetrics(
        livePoints: [SIMD3<Float>],
        savedPoints: [SIMD3<Float>],
        mapFromSessionTransform: simd_float4x4,
        inlierThresholdMeters: Float = 0.20
    ) -> (residualErrorMeters: Float, overlapRatio: Float) {
        guard !livePoints.isEmpty, !savedPoints.isEmpty else { return (1, 0) }

        var totalResidual: Float = 0
        var inlierCount = 0
        var evaluatedCount = 0
        let thresholdSquared = inlierThresholdMeters * inlierThresholdMeters

        for point in livePoints {
            let transformed = mapFromSessionTransform.transformPoint(point)
            guard let nearestSquaredDistance = nearestSquaredDistance(from: transformed, to: savedPoints) else { continue }
            evaluatedCount += 1
            let clampedDistance = min(sqrt(nearestSquaredDistance), 1.5)
            totalResidual += clampedDistance
            if nearestSquaredDistance <= thresholdSquared {
                inlierCount += 1
            }
        }

        guard evaluatedCount > 0 else { return (1, 0) }
        return (
            totalResidual / Float(evaluatedCount),
            Float(inlierCount) / Float(evaluatedCount)
        )
    }

    private static func supplementalStructuralHypotheses(
        saved: StructureSignatureArtifact?,
        live: StructureSignatureArtifact?
    ) -> [MeshRelocalizationHypothesis] {
        guard let saved, let live else { return [] }
        guard !saved.structuralSegments.isEmpty, !live.structuralSegments.isEmpty else { return [] }

        var hypotheses: [MeshRelocalizationHypothesis] = []
        for savedSegment in saved.structuralSegments.prefix(4) {
            for liveSegment in live.structuralSegments.prefix(4) {
                let yaw = normalizedDegrees(savedSegment.orientationDegrees - liveSegment.orientationDegrees)
                let liveMid = segmentMidpoint(liveSegment)
                let rotatedLiveMid = rotateXZ(liveMid, degrees: yaw)
                let translation = segmentMidpoint(savedSegment) - rotatedLiveMid
                let orientationScore = max(0, 1 - angleDistanceDegrees(savedSegment.orientationDegrees, liveSegment.orientationDegrees) / 45)
                let lengthScore = max(0, 1 - abs(segmentLength(savedSegment) - segmentLength(liveSegment)) / max(segmentLength(savedSegment), 0.5))
                let supportScore = min(savedSegment.supportWeight, liveSegment.supportWeight)
                let score = orientationScore * 0.35 + lengthScore * 0.35 + supportScore * 0.30
                hypotheses.append(
                    MeshRelocalizationHypothesis(
                        yawDegrees: yaw,
                        translationXZ: translation,
                        coarseConfidence: score,
                        source: "structural_segment"
                    )
                )
            }
        }
        return hypotheses.sorted { $0.coarseConfidence > $1.coarseConfidence }.prefix(4).map { $0 }
    }

    private static func mergedHypotheses(
        primary: [MeshRelocalizationHypothesis],
        supplemental: [MeshRelocalizationHypothesis]
    ) -> [MeshRelocalizationHypothesis] {
        let combined = primary + supplemental
        var merged: [MeshRelocalizationHypothesis] = []

        for hypothesis in combined.sorted(by: { $0.coarseConfidence > $1.coarseConfidence }) {
            let duplicate = merged.contains {
                angleDistanceDegrees($0.yawDegrees, hypothesis.yawDegrees) < 12 &&
                simd_distance($0.translationXZ, hypothesis.translationXZ) < 0.6
            }
            if !duplicate {
                merged.append(hypothesis)
            }
            if merged.count >= 6 { break }
        }
        return merged
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

    private static func worldSpaceVertices(for record: MeshAnchorRecord) -> [SIMD3<Float>] {
        let localPoints = record.vertices.chunked3SIMD
        guard let transform = simd_float4x4(flatArray: record.transform) else { return localPoints }
        return localPoints.map(transform.transformPoint)
    }

    private static func worldSpaceNormals(for normals: [SIMD3<Float>], transform flatTransform: [Float]) -> [SIMD3<Float>] {
        guard let transform = simd_float4x4(flatArray: flatTransform) else { return normals }
        return normals.map { normal in
            let rotated = transform.rotateVector(normal)
            let length = simd_length(rotated)
            return length > 0.0001 ? rotated / length : normal
        }
    }

    private static func nearestSquaredDistance(from point: SIMD3<Float>, to cloud: [SIMD3<Float>]) -> Float? {
        guard let first = cloud.first else { return nil }
        var best = simd_distance_squared(point, first)
        for candidate in cloud.dropFirst() {
            let distance = simd_distance_squared(point, candidate)
            if distance < best {
                best = distance
            }
        }
        return best
    }

    private static func canonicalLineOrientationDegrees(_ degrees: Float) -> Float {
        var value = normalizedDegrees(degrees)
        if value > 90 { value -= 180 }
        if value < -90 { value += 180 }
        return value
    }

    private static func segmentLength(_ segment: StructureSegment2D) -> Float {
        simd_distance(segment.start, segment.end)
    }

    private static func segmentMidpoint(_ segment: StructureSegment2D) -> SIMD2<Float> {
        (segment.start + segment.end) * 0.5
    }

    private static func rotateXZ(_ point: SIMD2<Float>, degrees: Float) -> SIMD2<Float> {
        let radians = degrees * .pi / 180
        let c = cos(radians)
        let s = sin(radians)
        return SIMD2<Float>(
            point.x * c - point.y * s,
            point.x * s + point.y * c
        )
    }

    private static func transform(segment: StructureSegment2D, with transform: simd_float4x4) -> StructureSegment2D {
        let p0 = transform.transformPoint(SIMD3<Float>(segment.start.x, 0, segment.start.y))
        let p1 = transform.transformPoint(SIMD3<Float>(segment.end.x, 0, segment.end.y))
        return StructureSegment2D(
            start: SIMD2<Float>(p0.x, p0.z),
            end: SIMD2<Float>(p1.x, p1.z),
            orientationDegrees: canonicalLineOrientationDegrees(segment.orientationDegrees + transform.forwardYawRadians * 180 / .pi),
            supportWeight: segment.supportWeight
        )
    }

    private static func segmentCompatibility(_ lhs: StructureSegment2D, _ rhs: StructureSegment2D) -> Float {
        let orientation = angleDistanceDegrees(lhs.orientationDegrees, rhs.orientationDegrees) / 45
        let centerDistance = simd_distance(segmentMidpoint(lhs), segmentMidpoint(rhs)) / 2
        let length = abs(segmentLength(lhs) - segmentLength(rhs)) / max(segmentLength(rhs), 0.5)
        return orientation * 0.4 + centerDistance * 0.4 + length * 0.2
    }

    private static func boundsAspectRatio(_ structure: StructureSignatureArtifact) -> Float {
        let extent = structure.boundsMaxXZ - structure.boundsMinXZ
        let major = max(max(abs(extent.x), abs(extent.y)), 0.1)
        let minor = max(min(abs(extent.x), abs(extent.y)), 0.1)
        return major / minor
    }
}
