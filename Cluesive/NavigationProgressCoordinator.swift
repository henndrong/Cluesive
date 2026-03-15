//
//  NavigationProgressCoordinator.swift
//  Cluesive
//
//  Pure runtime route progression, turn timing, and reroute guidance.
//

import Foundation
import simd

enum NavigationProgressCoordinator {
    static let segmentCompletionSlackMeters: Float = 0.35
    static let segmentEndpointArrivalMeters: Float = 0.5
    static let destinationArrivalMeters: Float = 0.75
    static let approachTurnDistanceMeters: Float = 1.5
    static let turnNowDistanceMeters: Float = 0.6
    static let minimumProgressBeforeNextTurnPromptMeters: Float = 0.35
    static let turnMeaningfulDeltaDegrees: Float = 20
    static let turnAlignmentToleranceDegrees: Float = 18
    static let headingAlignedAdvanceDistanceMeters: Float = 0.9
    static let headingAlignedAdvanceToleranceDegrees: Float = 20
    static let nextSegmentCommitCrossTrackMeters: Float = 0.35
    static let nextSegmentCommitProgressMeters: Float = 0.2
    static let nextSegmentCommitHoldSeconds: TimeInterval = 0.5
    static let offRouteCrossTrackMeters: Float = 1.0
    static let offRouteEndDistanceMeters: Float = 1.25
    static let offRouteProgressMeters: Float = 0.5
    static let offRouteDebounceSeconds: TimeInterval = 0.75

    struct State: Equatable {
        var activeRoute: PlannedRoute?
        var currentSegmentIndex: Int
        var lastPromptState: NavigationGuidanceState?
        var rerouteRequestedAt: Date?
        var lastAnnouncedSegmentIndex: Int?
        var lastProgressDistanceMeters: Float?
        var lastOffRouteAt: Date?
        var nextSegmentCommitCandidateIndex: Int?
        var nextSegmentCommitSince: Date?
        var startedAt: Date
    }

    struct Inputs {
        let readinessState: LocalizationReadinessState
        let route: PlannedRoute?
        let currentPose: simd_float4x4?
        let currentHeadingDegrees: Float?
        let isPoseStable: Bool
        let now: Date
    }

    struct Outcome {
        let state: State
        let snapshot: NavigationGuidanceSnapshot
    }

    static func start(route: PlannedRoute, now: Date) -> State {
        State(
            activeRoute: route,
            currentSegmentIndex: 0,
            lastPromptState: nil,
            rerouteRequestedAt: nil,
            lastAnnouncedSegmentIndex: nil,
            lastProgressDistanceMeters: nil,
            lastOffRouteAt: nil,
            nextSegmentCommitCandidateIndex: nil,
            nextSegmentCommitSince: nil,
            startedAt: now
        )
    }

    static func update(state: State, inputs: Inputs) -> Outcome {
        guard let route = inputs.route ?? state.activeRoute else {
            return Outcome(
                state: State(
                    activeRoute: nil,
                    currentSegmentIndex: 0,
                    lastPromptState: .waitingForRoute,
                    rerouteRequestedAt: nil,
                    lastAnnouncedSegmentIndex: nil,
                    lastProgressDistanceMeters: nil,
                    lastOffRouteAt: nil,
                    nextSegmentCommitCandidateIndex: nil,
                    nextSegmentCommitSince: nil,
                    startedAt: state.startedAt
                ),
                snapshot: NavigationGuidanceSnapshot(
                    state: .waitingForRoute,
                    currentSegmentIndex: 0,
                    segmentCount: 0,
                    distanceToSegmentEndMeters: 0,
                    distanceToDestinationMeters: 0,
                    headingDeltaToSegmentDegrees: 0,
                    promptText: "Plan a route first.",
                    hapticPattern: .none,
                    isOffRoute: false,
                    hasArrived: false,
                    shouldTriggerReplan: false
                )
            )
        }

        let segments = route.segments
        guard !segments.isEmpty else {
            return Outcome(
                state: State(
                    activeRoute: route,
                    currentSegmentIndex: 0,
                    lastPromptState: .arrived,
                    rerouteRequestedAt: nil,
                    lastAnnouncedSegmentIndex: nil,
                    lastProgressDistanceMeters: 0,
                    lastOffRouteAt: nil,
                    nextSegmentCommitCandidateIndex: nil,
                    nextSegmentCommitSince: nil,
                    startedAt: state.startedAt
                ),
                snapshot: NavigationGuidanceSnapshot(
                    state: .arrived,
                    currentSegmentIndex: 0,
                    segmentCount: 0,
                    distanceToSegmentEndMeters: 0,
                    distanceToDestinationMeters: 0,
                    headingDeltaToSegmentDegrees: 0,
                    promptText: "Arrived.",
                    hapticPattern: .success,
                    isOffRoute: false,
                    hasArrived: true,
                    shouldTriggerReplan: false
                )
            )
        }

        guard let currentPose = inputs.currentPose else {
            let pausedState = mergedState(from: state, route: route)
            return Outcome(
                state: pausedState,
                snapshot: pausedSnapshot(
                    state: .waitingForLocalization,
                    route: route,
                    segmentIndex: pausedState.currentSegmentIndex,
                    promptText: "Hold still while localization recovers."
                )
            )
        }

        guard inputs.readinessState == .ready, inputs.isPoseStable else {
            let pausedState = mergedState(from: state, route: route)
            return Outcome(
                state: pausedState,
                snapshot: pausedSnapshot(
                    state: .paused,
                    route: route,
                    segmentIndex: pausedState.currentSegmentIndex,
                    promptText: "Hold still while localization recovers."
                )
            )
        }

        var nextState = mergedState(from: state, route: route)
        var segmentIndex = min(nextState.currentSegmentIndex, max(segments.count - 1, 0))
        var currentSegment = segments[segmentIndex]
        var metrics = progressMetrics(for: currentSegment, currentPosition: currentPose.translation, route: route, currentSegmentIndex: segmentIndex)

        let advanceDecision = shouldAdvance(
            route: route,
            currentSegmentIndex: segmentIndex,
            currentSegment: currentSegment,
            metrics: metrics,
            currentPosition: currentPose.translation,
            currentHeadingDegrees: inputs.currentHeadingDegrees,
            state: nextState,
            now: inputs.now
        )
        nextState.nextSegmentCommitCandidateIndex = advanceDecision.nextSegmentCommitCandidateIndex
        nextState.nextSegmentCommitSince = advanceDecision.nextSegmentCommitSince

        if advanceDecision.shouldAdvance, segmentIndex < segments.count - 1 {
            segmentIndex += 1
            currentSegment = segments[segmentIndex]
            metrics = progressMetrics(for: currentSegment, currentPosition: currentPose.translation, route: route, currentSegmentIndex: segmentIndex)
            nextState.nextSegmentCommitCandidateIndex = nil
            nextState.nextSegmentCommitSince = nil
        }

        nextState.currentSegmentIndex = segmentIndex
        nextState.lastProgressDistanceMeters = metrics.distanceToDestinationMeters

        if isArrived(route: route, segmentIndex: segmentIndex, metrics: metrics) {
            nextState.lastPromptState = .arrived
            nextState.lastOffRouteAt = nil
            nextState.rerouteRequestedAt = nil
            return Outcome(
                state: nextState,
                snapshot: NavigationGuidanceSnapshot(
                    state: .arrived,
                    currentSegmentIndex: segmentIndex,
                    segmentCount: segments.count,
                    distanceToSegmentEndMeters: metrics.distanceToSegmentEndMeters,
                    distanceToDestinationMeters: metrics.distanceToDestinationMeters,
                    headingDeltaToSegmentDegrees: headingDelta(currentHeadingDegrees: inputs.currentHeadingDegrees, segmentHeadingDegrees: currentSegment.headingDegrees),
                    promptText: "Arrived.",
                    hapticPattern: .success,
                    isOffRoute: false,
                    hasArrived: true,
                    shouldTriggerReplan: false
                )
            )
        }

        let offRouteNow = isOffRoute(metrics: metrics, currentSegment: currentSegment, currentPosition: currentPose.translation)
        if offRouteNow {
            let firstSeen = nextState.lastOffRouteAt ?? inputs.now
            nextState.lastOffRouteAt = firstSeen
            if inputs.now.timeIntervalSince(firstSeen) >= offRouteDebounceSeconds {
                nextState.lastPromptState = .rerouting
                nextState.rerouteRequestedAt = inputs.now
                return Outcome(
                    state: nextState,
                    snapshot: NavigationGuidanceSnapshot(
                        state: .rerouting,
                        currentSegmentIndex: segmentIndex,
                        segmentCount: segments.count,
                        distanceToSegmentEndMeters: metrics.distanceToSegmentEndMeters,
                        distanceToDestinationMeters: metrics.distanceToDestinationMeters,
                        headingDeltaToSegmentDegrees: headingDelta(currentHeadingDegrees: inputs.currentHeadingDegrees, segmentHeadingDegrees: currentSegment.headingDegrees),
                        promptText: "Rerouting.",
                        hapticPattern: .pause,
                        isOffRoute: true,
                        hasArrived: false,
                        shouldTriggerReplan: true
                    )
                )
            }
        } else {
            nextState.lastOffRouteAt = nil
        }

        let promptState = turnState(
            route: route,
            currentSegmentIndex: segmentIndex,
            currentSegment: currentSegment,
            metrics: metrics
        )
        nextState.lastPromptState = promptState
        if promptState == .walking {
            nextState.lastAnnouncedSegmentIndex = segmentIndex
        }

        let turnDelta = headingDelta(currentHeadingDegrees: inputs.currentHeadingDegrees, segmentHeadingDegrees: currentSegment.headingDegrees)
        return Outcome(
            state: nextState,
            snapshot: NavigationGuidanceSnapshot(
                state: promptState,
                currentSegmentIndex: segmentIndex,
                segmentCount: segments.count,
                distanceToSegmentEndMeters: metrics.distanceToSegmentEndMeters,
                distanceToDestinationMeters: metrics.distanceToDestinationMeters,
                headingDeltaToSegmentDegrees: turnDelta,
                promptText: prompt(for: promptState, route: route, currentSegmentIndex: segmentIndex),
                hapticPattern: haptic(for: promptState),
                isOffRoute: false,
                hasArrived: false,
                shouldTriggerReplan: false
            )
        )
    }

    static func progressMetrics(
        for segment: RouteSegment,
        currentPosition: SIMD3<Float>,
        route: PlannedRoute,
        currentSegmentIndex: Int
    ) -> NavigationProgressMetrics {
        let start = SIMD2<Float>(segment.startPosition.x, segment.startPosition.z)
        let end = SIMD2<Float>(segment.endPosition.x, segment.endPosition.z)
        let point = SIMD2<Float>(currentPosition.x, currentPosition.z)
        let vector = end - start
        let pointVector = point - start
        let length = simd_length(vector)
        if length <= 0.0001 {
            let distanceToEnd = simd_length(point - end)
            return NavigationProgressMetrics(
                projectedProgressMeters: 0,
                crossTrackErrorMeters: distanceToEnd,
                distanceToSegmentEndMeters: distanceToEnd,
                distanceToDestinationMeters: distanceToEnd + remainingDistance(route: route, after: currentSegmentIndex)
            )
        }

        let axis = vector / length
        let projection = simd_dot(pointVector, axis)
        let clampedProjection = max(0, min(length, projection))
        let closestPoint = start + axis * clampedProjection
        let crossTrack = simd_length(point - closestPoint)
        let distanceToEnd = max(0, length - clampedProjection)
        let distanceToDestination = distanceToEnd + remainingDistance(route: route, after: currentSegmentIndex)

        return NavigationProgressMetrics(
            projectedProgressMeters: clampedProjection,
            crossTrackErrorMeters: crossTrack,
            distanceToSegmentEndMeters: distanceToEnd,
            distanceToDestinationMeters: distanceToDestination
        )
    }

    private static func remainingDistance(route: PlannedRoute, after currentSegmentIndex: Int) -> Float {
        guard currentSegmentIndex + 1 < route.segments.count else { return 0 }
        return route.segments[(currentSegmentIndex + 1)...].reduce(0) { $0 + $1.distanceMeters }
    }

    private static func mergedState(from state: State, route: PlannedRoute) -> State {
        State(
            activeRoute: route,
            currentSegmentIndex: min(state.currentSegmentIndex, max(route.segments.count - 1, 0)),
            lastPromptState: state.lastPromptState,
            rerouteRequestedAt: state.rerouteRequestedAt,
            lastAnnouncedSegmentIndex: state.lastAnnouncedSegmentIndex,
            lastProgressDistanceMeters: state.lastProgressDistanceMeters,
            lastOffRouteAt: state.lastOffRouteAt,
            nextSegmentCommitCandidateIndex: state.nextSegmentCommitCandidateIndex,
            nextSegmentCommitSince: state.nextSegmentCommitSince,
            startedAt: state.startedAt
        )
    }

    private static func pausedSnapshot(
        state: NavigationGuidanceState,
        route: PlannedRoute,
        segmentIndex: Int,
        promptText: String
    ) -> NavigationGuidanceSnapshot {
        NavigationGuidanceSnapshot(
            state: state,
            currentSegmentIndex: segmentIndex,
            segmentCount: route.segments.count,
            distanceToSegmentEndMeters: 0,
            distanceToDestinationMeters: 0,
            headingDeltaToSegmentDegrees: 0,
            promptText: promptText,
            hapticPattern: .pause,
            isOffRoute: false,
            hasArrived: false,
            shouldTriggerReplan: false
        )
    }

    private struct AdvanceDecision {
        let shouldAdvance: Bool
        let nextSegmentCommitCandidateIndex: Int?
        let nextSegmentCommitSince: Date?
    }

    private static func shouldAdvance(
        route: PlannedRoute,
        currentSegmentIndex: Int,
        currentSegment: RouteSegment,
        metrics: NavigationProgressMetrics,
        currentPosition: SIMD3<Float>,
        currentHeadingDegrees: Float?,
        state: State,
        now: Date
    ) -> AdvanceDecision {
        let distanceToEndNode = GraphManager.edgeDistance(from: currentPosition, to: currentSegment.endPosition)
        if let nextSegment = upcomingTurnSegment(route: route, currentSegmentIndex: currentSegmentIndex, currentSegment: currentSegment),
           metrics.distanceToSegmentEndMeters <= approachTurnDistanceMeters {
            guard let currentHeadingDegrees else {
                return AdvanceDecision(
                    shouldAdvance: false,
                    nextSegmentCommitCandidateIndex: nil,
                    nextSegmentCommitSince: nil
                )
            }

            let nextHeadingDelta = abs(normalizedDegrees(nextSegment.headingDegrees - currentHeadingDegrees))
            let isAlignedForTurn = nextHeadingDelta <= turnAlignmentToleranceDegrees
            let isAtTurnCommitPoint =
                metrics.distanceToSegmentEndMeters <= turnNowDistanceMeters ||
                distanceToEndNode <= segmentEndpointArrivalMeters

            return AdvanceDecision(
                shouldAdvance: isAlignedForTurn && isAtTurnCommitPoint,
                nextSegmentCommitCandidateIndex: nil,
                nextSegmentCommitSince: nil
            )
        }

        if metrics.distanceToSegmentEndMeters <= segmentCompletionSlackMeters || distanceToEndNode <= segmentEndpointArrivalMeters {
            return AdvanceDecision(
                shouldAdvance: true,
                nextSegmentCommitCandidateIndex: nil,
                nextSegmentCommitSince: nil
            )
        }

        guard currentSegmentIndex < route.segments.count - 1,
              distanceToEndNode <= headingAlignedAdvanceDistanceMeters,
              let currentHeadingDegrees else {
            return AdvanceDecision(
                shouldAdvance: false,
                nextSegmentCommitCandidateIndex: nil,
                nextSegmentCommitSince: nil
            )
        }

        let nextSegment = route.segments[currentSegmentIndex + 1]
        let nextHeadingDelta = abs(normalizedDegrees(nextSegment.headingDegrees - currentHeadingDegrees))
        let nextMetrics = progressMetrics(
            for: nextSegment,
            currentPosition: currentPosition,
            route: route,
            currentSegmentIndex: currentSegmentIndex + 1
        )
        let isCommittedToNextSegment =
            nextHeadingDelta <= headingAlignedAdvanceToleranceDegrees &&
            nextMetrics.crossTrackErrorMeters <= nextSegmentCommitCrossTrackMeters &&
            nextMetrics.projectedProgressMeters >= nextSegmentCommitProgressMeters

        guard isCommittedToNextSegment else {
            return AdvanceDecision(
                shouldAdvance: false,
                nextSegmentCommitCandidateIndex: nil,
                nextSegmentCommitSince: nil
            )
        }

        let candidateIndex = currentSegmentIndex + 1
        let commitSince: Date
        if state.nextSegmentCommitCandidateIndex == candidateIndex, let existingSince = state.nextSegmentCommitSince {
            commitSince = existingSince
        } else {
            commitSince = now
        }

        return AdvanceDecision(
            shouldAdvance: now.timeIntervalSince(commitSince) >= nextSegmentCommitHoldSeconds,
            nextSegmentCommitCandidateIndex: candidateIndex,
            nextSegmentCommitSince: commitSince
        )
    }

    private static func upcomingTurnSegment(
        route: PlannedRoute,
        currentSegmentIndex: Int,
        currentSegment: RouteSegment
    ) -> RouteSegment? {
        guard currentSegmentIndex < route.segments.count - 1 else { return nil }
        let nextSegment = route.segments[currentSegmentIndex + 1]
        let delta = abs(normalizedDegrees(nextSegment.headingDegrees - currentSegment.headingDegrees))
        return delta >= turnMeaningfulDeltaDegrees ? nextSegment : nil
    }

    private static func isArrived(route: PlannedRoute, segmentIndex: Int, metrics: NavigationProgressMetrics) -> Bool {
        segmentIndex >= max(route.segments.count - 1, 0) && metrics.distanceToDestinationMeters <= destinationArrivalMeters
    }

    private static func turnState(
        route: PlannedRoute,
        currentSegmentIndex: Int,
        currentSegment: RouteSegment,
        metrics: NavigationProgressMetrics
    ) -> NavigationGuidanceState {
        guard currentSegmentIndex < route.segments.count else { return .walking }
        guard upcomingTurnSegment(route: route, currentSegmentIndex: currentSegmentIndex, currentSegment: currentSegment) != nil else {
            return .walking
        }
        let minimumProgressBeforePrompt = min(
            minimumProgressBeforeNextTurnPromptMeters,
            max(currentSegment.distanceMeters * 0.5, 0)
        )
        guard metrics.projectedProgressMeters >= minimumProgressBeforePrompt else {
            return .walking
        }
        if metrics.distanceToSegmentEndMeters <= turnNowDistanceMeters {
            return .turnNow
        }
        if metrics.distanceToSegmentEndMeters <= approachTurnDistanceMeters {
            return .approachingTurn
        }
        return .walking
    }

    private static func isOffRoute(metrics: NavigationProgressMetrics, currentSegment: RouteSegment, currentPosition: SIMD3<Float>) -> Bool {
        if metrics.crossTrackErrorMeters > offRouteCrossTrackMeters {
            return true
        }
        let distanceToEndNode = GraphManager.edgeDistance(from: currentPosition, to: currentSegment.endPosition)
        if metrics.projectedProgressMeters >= offRouteProgressMeters &&
            metrics.crossTrackErrorMeters > offRouteCrossTrackMeters * 0.5 &&
            distanceToEndNode > offRouteEndDistanceMeters {
            return true
        }
        return false
    }

    private static func headingDelta(currentHeadingDegrees: Float?, segmentHeadingDegrees: Float) -> Float {
        guard let currentHeadingDegrees else { return 0 }
        return normalizedDegrees(segmentHeadingDegrees - currentHeadingDegrees)
    }

    private static func prompt(for state: NavigationGuidanceState, route: PlannedRoute, currentSegmentIndex: Int) -> String {
        switch state {
        case .approachingTurn:
            return turnPrompt(route: route, currentSegmentIndex: currentSegmentIndex, suffix: "soon")
        case .turnNow:
            return turnPrompt(route: route, currentSegmentIndex: currentSegmentIndex, suffix: "now")
        case .walking:
            return "Walk forward."
        case .rerouting:
            return "Rerouting."
        case .paused, .waitingForLocalization:
            return "Hold still while localization recovers."
        case .waitingForRoute:
            return "Plan a route first."
        case .arrived:
            return "Arrived."
        case .idle:
            return ""
        }
    }

    private static func turnPrompt(route: PlannedRoute, currentSegmentIndex: Int, suffix: String) -> String {
        guard currentSegmentIndex < route.segments.count - 1 else { return "Walk forward." }
        let currentSegment = route.segments[currentSegmentIndex]
        let nextSegment = route.segments[currentSegmentIndex + 1]
        let delta = normalizedDegrees(nextSegment.headingDegrees - currentSegment.headingDegrees)
        let direction = delta < 0 ? "left" : "right"
        return "Turn \(direction) \(suffix)."
    }

    private static func haptic(for state: NavigationGuidanceState) -> NavigationHapticPattern {
        switch state {
        case .walking:
            return .walk
        case .approachingTurn:
            return .approach
        case .turnNow:
            return .turn
        case .rerouting, .paused, .waitingForLocalization:
            return .pause
        case .arrived:
            return .success
        case .idle, .waitingForRoute:
            return .none
        }
    }
}
