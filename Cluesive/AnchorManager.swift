//
//  AnchorManager.swift
//  Cluesive
//
//  Anchor operations and eligibility/ping logic.
//

import Foundation
import ARKit

enum AnchorManager {
    static func defaultAnchorName(for type: AnchorType, existingAnchors: [SavedSemanticAnchor]) -> String {
        let base = type.defaultNamePrefix
        let sameTypeCount = existingAnchors.filter { $0.type == type }.count
        return "\(base) \(sameTypeCount + 1)"
    }

    static func createCurrentPoseAnchor(
        type: AnchorType,
        requestedName: String,
        transform: simd_float4x4,
        existingAnchors: [SavedSemanticAnchor]
    ) -> SavedSemanticAnchor {
        let finalName = resolvedName(requestedName, type: type, existingAnchors: existingAnchors)
        return SavedSemanticAnchor(
            id: UUID(),
            name: finalName,
            type: type,
            createdAt: Date(),
            transform: transform.flatArray,
            placementMode: .currentPose
        )
    }

    static func createAimedAnchor(
        type: AnchorType,
        requestedName: String,
        worldPosition: SIMD3<Float>,
        existingAnchors: [SavedSemanticAnchor]
    ) -> SavedSemanticAnchor {
        let finalName = resolvedName(requestedName, type: type, existingAnchors: existingAnchors)
        let anchorTransform = simd_float4x4(anchorWorldPosition: worldPosition)
        return SavedSemanticAnchor(
            id: UUID(),
            name: finalName,
            type: type,
            createdAt: Date(),
            transform: anchorTransform.flatArray,
            placementMode: .aimedRaycast
        )
    }

    static func renameAnchor(
        _ anchors: inout [SavedSemanticAnchor],
        id: UUID,
        newName: String
    ) -> (successMessage: String?, errorMessage: String?) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return (nil, "Anchor name cannot be empty")
        }
        guard let idx = anchors.firstIndex(where: { $0.id == id }) else {
            return (nil, "Anchor not found")
        }
        anchors[idx].name = trimmed
        return ("Renamed anchor to \(trimmed)", nil)
    }

    static func deleteAnchor(_ anchors: inout [SavedSemanticAnchor], id: UUID) -> String? {
        guard let idx = anchors.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = anchors.remove(at: idx)
        return "Deleted anchor: \(removed.name)"
    }

    static func validateAnchorPlacementEligibility(
        currentPoseTransform: simd_float4x4?,
        appLocalizationState: AppLocalizationState,
        isPoseStableForAnchorActions: Bool,
        effectiveConfidence: Float,
        requiredConfidence: Float
    ) -> (allowed: Bool, reason: String?) {
        guard currentPoseTransform != nil else {
            return (false, "No current pose yet")
        }
        guard appLocalizationState.isUsableForAnchors else {
            return (false, "Wait for usable alignment (ARKit relocalize or mesh alignment)")
        }
        guard isPoseStableForAnchorActions else {
            return (false, "Anchor placement requires stable heading (hold steady briefly)")
        }
        guard effectiveConfidence >= requiredConfidence else {
            return (false, "Anchor placement requires stable alignment (confidence >= 70%)")
        }
        return (true, nil)
    }

    static func anchorActionEligibility(
        mode: AnchorPlacementMode,
        baseEligibility: (allowed: Bool, reason: String?),
        anchorTargetingReady: Bool,
        latestAnchorTargetPreview: AnchorTargetPreview
    ) -> (allowed: Bool, reason: String?) {
        guard baseEligibility.allowed else { return baseEligibility }
        if mode == .aimedRaycast {
            guard anchorTargetingReady, latestAnchorTargetPreview.isTargetValid else {
                return (false, latestAnchorTargetPreview.reason ?? "No target surface in center view")
            }
        }
        return (true, nil)
    }

    static func distanceAndBearing(
        from current: simd_float4x4,
        to anchorTransform: simd_float4x4,
        anchorID: UUID,
        anchorName: String
    ) -> AnchorPingResult {
        let currentPosition = current.translation
        let anchorPosition = anchorTransform.translation
        let dx = anchorPosition.x - currentPosition.x
        let dz = anchorPosition.z - currentPosition.z
        let distance = sqrt(dx * dx + dz * dz)

        let currentHeading = headingFromTransform(current)
        let targetHeading = atan2(dz, dx)
        let delta = normalizedAngle(targetHeading - currentHeading)

        return AnchorPingResult(
            anchorID: anchorID,
            anchorName: anchorName,
            distanceMeters: distance,
            bearingDegrees: delta * 180 / .pi,
            absoluteHeadingDegrees: targetHeading * 180 / .pi,
            isReachable: true
        )
    }

    static func pingSummary(from ping: AnchorPingResult) -> String {
        let absBearing = abs(ping.bearingDegrees)
        let turnText: String
        if ping.distanceMeters < 0.4 {
            turnText = "nearby"
        } else if absBearing <= 10 {
            turnText = "ahead"
        } else if ping.bearingDegrees < 0 {
            turnText = "turn left \(Int(absBearing.rounded()))°"
        } else {
            turnText = "turn right \(Int(absBearing.rounded()))°"
        }
        return String(format: "%@: %.2fm, %@", ping.anchorName, ping.distanceMeters, turnText)
    }

    static func headingFromTransform(_ transform: simd_float4x4) -> Float {
        transform.forwardYawRadians
    }

    private static func resolvedName(_ requestedName: String, type: AnchorType, existingAnchors: [SavedSemanticAnchor]) -> String {
        let trimmed = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultAnchorName(for: type, existingAnchors: existingAnchors) : trimmed
    }

    private static func normalizedAngle(_ angle: Float) -> Float {
        var value = angle
        while value > .pi { value -= 2 * .pi }
        while value < -.pi { value += 2 * .pi }
        return value
    }
}
