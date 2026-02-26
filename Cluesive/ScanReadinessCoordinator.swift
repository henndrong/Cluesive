//
//  ScanReadinessCoordinator.swift
//  Cluesive
//
//  Pure scan quality/readiness scoring and presentation helpers.
//

import Foundation
import ARKit

enum ScanReadinessCoordinator {
    struct MetricBuffers {
        let mappingSamples: [ARFrame.WorldMappingStatus]
        let featurePointSamples: [Int]
        let trackingNormalSamples: [Bool]
    }

    struct MapReadinessPresentation {
        let readinessText: String
        let readinessScoreText: String
        let warningsText: String
        let saveMapWarningText: String?
    }

    static func appendSamples(
        mappingSamples: [ARFrame.WorldMappingStatus],
        featurePointSamples: [Int],
        trackingNormalSamples: [Bool],
        frame: ARFrame,
        maxSamples: Int = 180
    ) -> MetricBuffers {
        var mapping = mappingSamples
        var features = featurePointSamples
        var trackingNormal = trackingNormalSamples

        mapping.append(frame.worldMappingStatus)
        features.append(frame.rawFeaturePoints?.points.count ?? 0)
        let isTrackingNormal = {
            if case .normal = frame.camera.trackingState { return true }
            return false
        }()
        trackingNormal.append(isTrackingNormal)

        if mapping.count > maxSamples { mapping.removeFirst(mapping.count - maxSamples) }
        if features.count > maxSamples { features.removeFirst(features.count - maxSamples) }
        if trackingNormal.count > maxSamples { trackingNormal.removeFirst(trackingNormal.count - maxSamples) }

        return MetricBuffers(
            mappingSamples: mapping,
            featurePointSamples: features,
            trackingNormalSamples: trackingNormal
        )
    }

    static func computeScanReadinessSnapshot(
        recentMappingSamples: [ARFrame.WorldMappingStatus],
        recentFeaturePointSamples: [Int],
        recentTrackingNormalSamples: [Bool],
        sessionYawCoverageAccumulated: Float,
        sessionTranslationAccumulated: Float
    ) -> ScanReadinessSnapshot {
        let mappedCount = recentMappingSamples.filter { $0 == .mapped }.count
        let mappingMappedRatio = recentMappingSamples.isEmpty ? 0 : Float(mappedCount) / Float(recentMappingSamples.count)
        let trackingNormalCount = recentTrackingNormalSamples.filter { $0 }.count
        let trackingNormalRatio = recentTrackingNormalSamples.isEmpty ? 0 : Float(trackingNormalCount) / Float(recentTrackingNormalSamples.count)
        let medianFeature = median(recentFeaturePointSamples)
        let yawCoverageDegrees = min(sessionYawCoverageAccumulated * 180 / .pi, 1080)
        let translationDistanceMeters = sessionTranslationAccumulated

        var score: Float = 0
        score += min(mappingMappedRatio / 0.7, 1) * 0.30
        score += min(trackingNormalRatio / 0.8, 1) * 0.20
        score += min(Float(medianFeature) / 350, 1) * 0.20
        score += min(yawCoverageDegrees / 540, 1) * 0.15
        score += min(translationDistanceMeters / 4.0, 1) * 0.15

        var warnings: [String] = []
        if mappingMappedRatio < 0.45 { warnings.append("Mapping stability low (mapped frames inconsistent)") }
        if medianFeature < 180 { warnings.append("Low feature richness; scan textured edges/furniture") }
        if yawCoverageDegrees < 300 { warnings.append("Limited rotational coverage; rotate in place more") }
        if translationDistanceMeters < 1.5 { warnings.append("Not enough viewpoint movement for robust relocalization") }
        if trackingNormalRatio < 0.6 { warnings.append("Tracking frequently limited; slow down and revisit") }

        return ScanReadinessSnapshot(
            mappingMappedRatio: mappingMappedRatio,
            featurePointMedian: medianFeature,
            yawCoverageDegrees: yawCoverageDegrees,
            translationDistanceMeters: translationDistanceMeters,
            trackingNormalRatio: trackingNormalRatio,
            qualityScore: min(max(score, 0), 1),
            warnings: warnings
        )
    }

    static func mapReadinessPresentation(snapshot: ScanReadinessSnapshot) -> MapReadinessPresentation {
        let pct = Int((snapshot.qualityScore * 100).rounded())
        let label: String
        switch snapshot.qualityScore {
        case ..<0.45: label = "Weak"
        case ..<0.65: label = "Fair"
        case ..<0.82: label = "Good"
        default: label = "Strong"
        }

        return MapReadinessPresentation(
            readinessText: "Map Readiness: \(pct)% (\(label))",
            readinessScoreText: String(
                format: "Readiness details: mapped %.0f%%, features %d, rotation %.0f°, move %.1fm",
                snapshot.mappingMappedRatio * 100,
                snapshot.featurePointMedian,
                snapshot.yawCoverageDegrees,
                snapshot.translationDistanceMeters
            ),
            warningsText: snapshot.warnings.prefix(2).joined(separator: " | "),
            saveMapWarningText: saveReadinessWarningIfNeeded(snapshot: snapshot)
        )
    }

    static func saveReadinessWarningIfNeeded(snapshot: ScanReadinessSnapshot) -> String? {
        guard snapshot.qualityScore < 0.65 else { return nil }
        return "This map may relocalize poorly from random starts. Scan more viewpoints and rotate 360° in key areas before saving."
    }

    private static func median(_ values: [Int]) -> Int {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }
}
