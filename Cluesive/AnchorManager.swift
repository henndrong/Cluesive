//
//  AnchorManager.swift
//  Cluesive
//
//  Anchor operations and eligibility/ping logic.
//

import Foundation
import ARKit

enum AnchorManager {
    struct ModePresentationState {
        let isAnchorModePresented: Bool
        let showDebugOverlay: Bool
        let anchorPlacementMode: AnchorPlacementMode
        let anchorTargetPreviewText: String?
        let anchorModeStatusText: String
        let anchorTargetingReady: Bool
        let consecutiveValidRaycastFrames: Int
    }

    struct TargetPreviewState {
        let preview: AnchorTargetPreview
        let previewText: String?
        let targetingReady: Bool
        let consecutiveValidRaycastFrames: Int
    }

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

    static func anchorModeStatusText(
        for mode: AnchorPlacementMode,
        eligibility: (allowed: Bool, reason: String?)
    ) -> String {
        guard eligibility.allowed else {
            return eligibility.reason ?? "Anchor placement unavailable"
        }
        switch mode {
        case .aimedRaycast:
            return "Ready to place aimed anchor"
        case .currentPose:
            return "Ready to place current-position anchor"
        }
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

    static func currentRaycastTarget(
        latestAnchorTargetPreview: AnchorTargetPreview,
        anchorTargetingReady: Bool
    ) -> SIMD3<Float>? {
        guard latestAnchorTargetPreview.isTargetValid else { return nil }
        guard anchorTargetingReady else { return nil }
        return latestAnchorTargetPreview.worldPosition
    }

    static func enterAnchorModePresentationState() -> ModePresentationState {
        ModePresentationState(
            isAnchorModePresented: true,
            showDebugOverlay: false,
            anchorPlacementMode: .aimedRaycast,
            anchorTargetPreviewText: nil,
            anchorModeStatusText: "Relocalize and aim at a landmark",
            anchorTargetingReady: false,
            consecutiveValidRaycastFrames: 0
        )
    }

    static func exitAnchorModePresentationState(currentPlacementMode: AnchorPlacementMode) -> ModePresentationState {
        ModePresentationState(
            isAnchorModePresented: false,
            showDebugOverlay: true,
            anchorPlacementMode: currentPlacementMode,
            anchorTargetPreviewText: nil,
            anchorModeStatusText: "Relocalize and aim at a landmark",
            anchorTargetingReady: false,
            consecutiveValidRaycastFrames: 0
        )
    }

    static func loadAnchorsFromDisk() -> (anchors: [SavedSemanticAnchor], operationMessage: String?, errorMessage: String?) {
        do {
            let anchors = try Phase1MapStore.loadAnchors()
            return (anchors, anchors.isEmpty ? nil : "Loaded \(anchors.count) anchor(s)", nil)
        } catch {
            return ([], nil, "Anchors load failed: \(error.localizedDescription)")
        }
    }

    static func saveAnchors(_ anchors: [SavedSemanticAnchor], successMessage: String) -> (operationMessage: String?, errorMessage: String?) {
        do {
            try Phase1MapStore.saveAnchors(anchors)
            return (successMessage, nil)
        } catch {
            return (nil, "Anchors save failed: \(error.localizedDescription)")
        }
    }

    static func inactiveTargetPreviewState() -> TargetPreviewState {
        TargetPreviewState(
            preview: AnchorTargetPreview(isTargetValid: false, worldPosition: nil, reason: "No target", surfaceKind: nil),
            previewText: nil,
            targetingReady: false,
            consecutiveValidRaycastFrames: 0
        )
    }

    static func hereModeTargetPreviewState(
        currentPoseTransform: simd_float4x4?,
        baseEligibility: (allowed: Bool, reason: String?)
    ) -> TargetPreviewState {
        TargetPreviewState(
            preview: AnchorTargetPreview(
                isTargetValid: true,
                worldPosition: currentPoseTransform?.translation,
                reason: nil,
                surfaceKind: "device_pose"
            ),
            previewText: baseEligibility.allowed ? "Here mode: saves current phone position" : baseEligibility.reason,
            targetingReady: baseEligibility.allowed,
            consecutiveValidRaycastFrames: 0
        )
    }

    static func unavailableRaycastPreviewState(reason: String) -> TargetPreviewState {
        TargetPreviewState(
            preview: AnchorTargetPreview(isTargetValid: false, worldPosition: nil, reason: reason, surfaceKind: nil),
            previewText: reason,
            targetingReady: false,
            consecutiveValidRaycastFrames: 0
        )
    }

    static func raycastHitPreviewState(
        hitPosition: SIMD3<Float>,
        hitSurfaceKind: String,
        currentPoseTransform: simd_float4x4?,
        baseEligibility: (allowed: Bool, reason: String?),
        previousConsecutiveValidFrames: Int,
        requiredStableFrames: Int = 3
    ) -> TargetPreviewState {
        let consecutive = previousConsecutiveValidFrames + 1
        let ready = baseEligibility.allowed && consecutive >= requiredStableFrames
        let distance = simd_distance(hitPosition, currentPoseTransform?.translation ?? hitPosition)
        let text = String(format: ready ? "Target locked %.2fm" : "Hold steady on target %.2fm", distance)
        return TargetPreviewState(
            preview: AnchorTargetPreview(
                isTargetValid: true,
                worldPosition: hitPosition,
                reason: nil,
                surfaceKind: hitSurfaceKind
            ),
            previewText: text,
            targetingReady: ready,
            consecutiveValidRaycastFrames: consecutive
        )
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
