//
//  OrientationCoordinator.swift
//  Cluesive
//
//  Pure orientation guidance state machine and prompt banding.
//

import Foundation

enum OrientationCoordinator {
    static let defaultToleranceDegrees: Float = 8
    static let defaultAlignedHoldSeconds: TimeInterval = 0.75

    struct State {
        var alignedSince: Date?
    }

    struct Inputs {
        let readinessState: LocalizationReadinessState
        let target: OrientationTarget?
        let currentHeadingDegrees: Float?
        let isPoseStable: Bool
        let now: Date
    }

    struct Outcome {
        let state: State
        let snapshot: OrientationGuidanceSnapshot
    }

    static func makeTarget(route: PlannedRoute, targetSegmentIndex: Int = 0, toleranceDegrees: Float = defaultToleranceDegrees) -> OrientationTarget? {
        guard route.segments.indices.contains(targetSegmentIndex) else { return nil }
        return OrientationTarget(
            route: route,
            targetSegmentIndex: targetSegmentIndex,
            desiredHeadingDegrees: route.segments[targetSegmentIndex].headingDegrees,
            toleranceDegrees: toleranceDegrees
        )
    }

    static func update(state: State, inputs: Inputs) -> Outcome {
        guard inputs.readinessState == .ready else {
            return Outcome(
                state: State(alignedSince: nil),
                snapshot: OrientationGuidanceSnapshot(
                    state: .waitingForLocalization,
                    currentHeadingDegrees: inputs.currentHeadingDegrees ?? 0,
                    desiredHeadingDegrees: inputs.target?.desiredHeadingDegrees ?? 0,
                    deltaDegrees: 0,
                    promptText: "Not aligned yet. Scan the room slowly.",
                    hapticPattern: .none,
                    isAligned: false
                )
            )
        }

        guard let target = inputs.target, let currentHeadingDegrees = inputs.currentHeadingDegrees else {
            return Outcome(
                state: State(alignedSince: nil),
                snapshot: OrientationGuidanceSnapshot(
                    state: .waitingForRoute,
                    currentHeadingDegrees: inputs.currentHeadingDegrees ?? 0,
                    desiredHeadingDegrees: 0,
                    deltaDegrees: 0,
                    promptText: "Choose a destination.",
                    hapticPattern: .none,
                    isAligned: false
                )
            )
        }

        guard inputs.isPoseStable else {
            return Outcome(
                state: State(alignedSince: nil),
                snapshot: OrientationGuidanceSnapshot(
                    state: .unstableHeading,
                    currentHeadingDegrees: currentHeadingDegrees,
                    desiredHeadingDegrees: target.desiredHeadingDegrees,
                    deltaDegrees: normalizedDegrees(target.desiredHeadingDegrees - currentHeadingDegrees),
                    promptText: "Hold still.",
                    hapticPattern: .none,
                    isAligned: false
                )
            )
        }

        let deltaDegrees = normalizedDegrees(target.desiredHeadingDegrees - currentHeadingDegrees)
        let absDelta = abs(deltaDegrees)
        if absDelta <= target.toleranceDegrees {
            let alignedSince = state.alignedSince ?? inputs.now
            let heldLongEnough = inputs.now.timeIntervalSince(alignedSince) >= defaultAlignedHoldSeconds
            return Outcome(
                state: State(alignedSince: alignedSince),
                snapshot: OrientationGuidanceSnapshot(
                    state: heldLongEnough ? .aligned : .nearlyAligned,
                    currentHeadingDegrees: currentHeadingDegrees,
                    desiredHeadingDegrees: target.desiredHeadingDegrees,
                    deltaDegrees: deltaDegrees,
                    promptText: heldLongEnough ? "Aligned. Ready to navigate." : "A little more.",
                    hapticPattern: heldLongEnough ? .success : .slow,
                    isAligned: heldLongEnough
                )
            )
        }

        let nextState: OrientationGuidanceState
        let promptText: String
        let hapticPattern: OrientationHapticPattern
        if absDelta <= 15 {
            nextState = .nearlyAligned
            promptText = "A little more."
            hapticPattern = .slow
        } else if deltaDegrees < 0 {
            nextState = .turnLeft
            promptText = "Turn left."
            hapticPattern = absDelta > 45 ? .fast : .medium
        } else {
            nextState = .turnRight
            promptText = "Turn right."
            hapticPattern = absDelta > 45 ? .fast : .medium
        }

        return Outcome(
            state: State(alignedSince: nil),
            snapshot: OrientationGuidanceSnapshot(
                state: nextState,
                currentHeadingDegrees: currentHeadingDegrees,
                desiredHeadingDegrees: target.desiredHeadingDegrees,
                deltaDegrees: deltaDegrees,
                promptText: promptText,
                hapticPattern: hapticPattern,
                isAligned: false
            )
        )
    }
}
