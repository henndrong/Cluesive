import XCTest
import simd
@testable import Cluesive

final class NavigationProgressCoordinatorTests: XCTestCase {
    func testStartsWalkingOnFirstSegment() {
        let route = makeRoute()
        let state = NavigationProgressCoordinator.start(route: route, now: Date())

        let outcome = NavigationProgressCoordinator.update(
            state: state,
            inputs: .init(
                readinessState: .ready,
                route: route,
                currentPose: simd_float4x4(yawRadians: 0, translation: SIMD3<Float>(0.1, 0, 0)),
                currentHeadingDegrees: 0,
                isPoseStable: true,
                now: Date()
            )
        )

        XCTAssertEqual(outcome.snapshot.state, .walking)
        XCTAssertEqual(outcome.snapshot.currentSegmentIndex, 0)
    }

    func testAdvancesToNextSegmentNearSegmentEnd() {
        let route = makeRoute()
        let state = NavigationProgressCoordinator.start(route: route, now: Date())

        let outcome = NavigationProgressCoordinator.update(
            state: state,
            inputs: .init(
                readinessState: .ready,
                route: route,
                currentPose: simd_float4x4(yawRadians: 0, translation: SIMD3<Float>(0.95, 0, 0.02)),
                currentHeadingDegrees: 0,
                isPoseStable: true,
                now: Date()
            )
        )

        XCTAssertEqual(outcome.state.currentSegmentIndex, 1)
    }

    func testAdvancesWhenUserHasCommittedToNextBearingNearTurn() {
        let route = makeRoute()
        let now = Date()
        let state = NavigationProgressCoordinator.start(route: route, now: now)

        let first = NavigationProgressCoordinator.update(
            state: state,
            inputs: .init(
                readinessState: .ready,
                route: route,
                currentPose: simd_float4x4(yawRadians: 0, translation: SIMD3<Float>(1.0, 0, 0.25)),
                currentHeadingDegrees: 90,
                isPoseStable: true,
                now: now
            )
        )

        let second = NavigationProgressCoordinator.update(
            state: first.state,
            inputs: .init(
                readinessState: .ready,
                route: route,
                currentPose: simd_float4x4(yawRadians: 0, translation: SIMD3<Float>(1.0, 0, 0.3)),
                currentHeadingDegrees: 90,
                isPoseStable: true,
                now: now.addingTimeInterval(0.6)
            )
        )

        XCTAssertEqual(second.state.currentSegmentIndex, 1)
        XCTAssertEqual(second.snapshot.state, .walking)
    }

    func testDoesNotAdvanceOnHeadingNudgeWithoutPhysicalCommit() {
        let route = makeRoute()
        let now = Date()
        let first = NavigationProgressCoordinator.update(
            state: NavigationProgressCoordinator.start(route: route, now: now),
            inputs: .init(
                readinessState: .ready,
                route: route,
                currentPose: simd_float4x4(yawRadians: 0, translation: SIMD3<Float>(0.8, 0, 0.02)),
                currentHeadingDegrees: 90,
                isPoseStable: true,
                now: now
            )
        )

        let second = NavigationProgressCoordinator.update(
            state: first.state,
            inputs: .init(
                readinessState: .ready,
                route: route,
                currentPose: simd_float4x4(yawRadians: 0, translation: SIMD3<Float>(0.8, 0, 0.02)),
                currentHeadingDegrees: 90,
                isPoseStable: true,
                now: now.addingTimeInterval(0.6)
            )
        )

        XCTAssertEqual(second.state.currentSegmentIndex, 0)
        XCTAssertEqual(second.snapshot.state, .approachingTurn)
    }

    func testApproachingTurnWithinThreshold() {
        let route = makeRoute()
        let state = NavigationProgressCoordinator.start(route: route, now: Date())

        let outcome = NavigationProgressCoordinator.update(
            state: state,
            inputs: .init(
                readinessState: .ready,
                route: route,
                currentPose: simd_float4x4(yawRadians: 0, translation: SIMD3<Float>(0.4, 0, 0)),
                currentHeadingDegrees: 0,
                isPoseStable: true,
                now: Date()
            )
        )

        XCTAssertEqual(outcome.snapshot.state, .approachingTurn)
    }

    func testTurnNowWithinCloseThreshold() {
        let route = makeRoute()
        let state = NavigationProgressCoordinator.start(route: route, now: Date())

        let outcome = NavigationProgressCoordinator.update(
            state: state,
            inputs: .init(
                readinessState: .ready,
                route: route,
                currentPose: simd_float4x4(yawRadians: 0, translation: SIMD3<Float>(0.8, 0, 0)),
                currentHeadingDegrees: 0,
                isPoseStable: true,
                now: Date()
            )
        )

        XCTAssertEqual(outcome.snapshot.state, .turnNow)
    }

    func testShallowTurnStaysWalking() {
        let route = makeRoute(secondHeading: 10)
        let state = NavigationProgressCoordinator.start(route: route, now: Date())

        let outcome = NavigationProgressCoordinator.update(
            state: state,
            inputs: .init(
                readinessState: .ready,
                route: route,
                currentPose: simd_float4x4(yawRadians: 0, translation: SIMD3<Float>(0.1, 0, 0)),
                currentHeadingDegrees: 0,
                isPoseStable: true,
                now: Date()
            )
        )

        XCTAssertEqual(outcome.snapshot.state, .walking)
    }

    func testDoesNotPromptNextTurnImmediatelyAfterSegmentAdvance() {
        let route = makeThreeSegmentRoute()
        let now = Date()
        let first = NavigationProgressCoordinator.update(
            state: NavigationProgressCoordinator.start(route: route, now: now),
            inputs: .init(
                readinessState: .ready,
                route: route,
                currentPose: simd_float4x4(yawRadians: 0, translation: SIMD3<Float>(1.0, 0, 0.25)),
                currentHeadingDegrees: 90,
                isPoseStable: true,
                now: now
            )
        )

        let second = NavigationProgressCoordinator.update(
            state: first.state,
            inputs: .init(
                readinessState: .ready,
                route: route,
                currentPose: simd_float4x4(yawRadians: 0, translation: SIMD3<Float>(1.0, 0, 0.3)),
                currentHeadingDegrees: 90,
                isPoseStable: true,
                now: now.addingTimeInterval(0.6)
            )
        )

        XCTAssertEqual(second.state.currentSegmentIndex, 1)
        XCTAssertEqual(second.snapshot.state, .walking)
        XCTAssertEqual(second.snapshot.promptText, "Walk forward.")
    }

    func testDoesNotAdvanceThroughTurnWindowWithoutRotating() {
        let route = makeThreeSegmentRoute()
        let outcome = NavigationProgressCoordinator.update(
            state: NavigationProgressCoordinator.start(route: route, now: Date()),
            inputs: .init(
                readinessState: .ready,
                route: route,
                currentPose: simd_float4x4(yawRadians: 0, translation: SIMD3<Float>(1.0, 0, 0.25)),
                currentHeadingDegrees: 0,
                isPoseStable: true,
                now: Date()
            )
        )

        XCTAssertEqual(outcome.state.currentSegmentIndex, 0)
        XCTAssertEqual(outcome.snapshot.state, .turnNow)
        XCTAssertEqual(outcome.snapshot.promptText, "Turn right now.")
    }

    func testAdvancesAtTurnWindowAfterRotatingToNextHeading() {
        let route = makeThreeSegmentRoute()
        let outcome = NavigationProgressCoordinator.update(
            state: NavigationProgressCoordinator.start(route: route, now: Date()),
            inputs: .init(
                readinessState: .ready,
                route: route,
                currentPose: simd_float4x4(yawRadians: 0, translation: SIMD3<Float>(1.0, 0, 0.25)),
                currentHeadingDegrees: 90,
                isPoseStable: true,
                now: Date()
            )
        )

        XCTAssertEqual(outcome.state.currentSegmentIndex, 1)
        XCTAssertEqual(outcome.snapshot.state, .walking)
        XCTAssertEqual(outcome.snapshot.promptText, "Walk forward.")
    }

    func testArrivesNearDestination() {
        let route = makeRoute()
        let state = NavigationProgressCoordinator.State(
            activeRoute: route,
            currentSegmentIndex: 1,
            lastPromptState: nil,
            rerouteRequestedAt: nil,
            lastAnnouncedSegmentIndex: nil,
            lastProgressDistanceMeters: nil,
            lastOffRouteAt: nil,
            nextSegmentCommitCandidateIndex: nil,
            nextSegmentCommitSince: nil,
            startedAt: Date()
        )

        let outcome = NavigationProgressCoordinator.update(
            state: state,
            inputs: .init(
                readinessState: .ready,
                route: route,
                currentPose: simd_float4x4(yawRadians: 0, translation: SIMD3<Float>(1, 0, 0.45)),
                currentHeadingDegrees: 90,
                isPoseStable: true,
                now: Date()
            )
        )

        XCTAssertEqual(outcome.snapshot.state, .arrived)
        XCTAssertTrue(outcome.snapshot.hasArrived)
    }

    func testPausesWhenReadinessNotReady() {
        let route = makeRoute()
        let state = NavigationProgressCoordinator.start(route: route, now: Date())

        let outcome = NavigationProgressCoordinator.update(
            state: state,
            inputs: .init(
                readinessState: .recovering,
                route: route,
                currentPose: simd_float4x4(yawRadians: 0, translation: SIMD3<Float>(0.1, 0, 0)),
                currentHeadingDegrees: 0,
                isPoseStable: true,
                now: Date()
            )
        )

        XCTAssertEqual(outcome.snapshot.state, .paused)
    }

    func testTriggersRerouteAfterSustainedOffRoute() {
        let route = makeRoute()
        let now = Date()
        let first = NavigationProgressCoordinator.update(
            state: NavigationProgressCoordinator.start(route: route, now: now),
            inputs: .init(
                readinessState: .ready,
                route: route,
                currentPose: simd_float4x4(yawRadians: 0, translation: SIMD3<Float>(0.6, 0, 1.4)),
                currentHeadingDegrees: 0,
                isPoseStable: true,
                now: now
            )
        )

        let second = NavigationProgressCoordinator.update(
            state: first.state,
            inputs: .init(
                readinessState: .ready,
                route: route,
                currentPose: simd_float4x4(yawRadians: 0, translation: SIMD3<Float>(0.6, 0, 1.4)),
                currentHeadingDegrees: 0,
                isPoseStable: true,
                now: now.addingTimeInterval(1.0)
            )
        )

        XCTAssertEqual(second.snapshot.state, .rerouting)
        XCTAssertTrue(second.snapshot.shouldTriggerReplan)
    }

    func testTransientOffRouteDoesNotTriggerReroute() {
        let route = makeRoute()
        let now = Date()
        let outcome = NavigationProgressCoordinator.update(
            state: NavigationProgressCoordinator.start(route: route, now: now),
            inputs: .init(
                readinessState: .ready,
                route: route,
                currentPose: simd_float4x4(yawRadians: 0, translation: SIMD3<Float>(0.6, 0, 1.4)),
                currentHeadingDegrees: 0,
                isPoseStable: true,
                now: now.addingTimeInterval(0.2)
            )
        )

        XCTAssertFalse(outcome.snapshot.shouldTriggerReplan)
    }

    func testComputesRemainingDistanceAfterPartialProgress() {
        let route = makeRoute()
        let metrics = NavigationProgressCoordinator.progressMetrics(
            for: route.segments[0],
            currentPosition: SIMD3<Float>(0.25, 0, 0),
            route: route,
            currentSegmentIndex: 0
        )

        XCTAssertEqual(metrics.distanceToDestinationMeters, 1.25, accuracy: 0.001)
    }

    private func makeRoute(secondHeading: Float = 90) -> PlannedRoute {
        let start = UUID()
        let turn = UUID()
        let finish = UUID()
        return PlannedRoute(
            destinationAnchorID: UUID(),
            destinationNodeID: finish,
            startNodeID: start,
            nodePath: [start, turn, finish],
            segments: [
                RouteSegment(
                    fromNodeID: start,
                    toNodeID: turn,
                    startPosition: SIMD3<Float>(0, 0, 0),
                    endPosition: SIMD3<Float>(1, 0, 0),
                    headingDegrees: 0,
                    distanceMeters: 1
                ),
                RouteSegment(
                    fromNodeID: turn,
                    toNodeID: finish,
                    startPosition: SIMD3<Float>(1, 0, 0),
                    endPosition: SIMD3<Float>(1 + cos(secondHeading * .pi / 180), 0, sin(secondHeading * .pi / 180)),
                    headingDegrees: secondHeading,
                    distanceMeters: 1
                )
            ],
            totalDistanceMeters: 2
        )
    }

    private func makeThreeSegmentRoute() -> PlannedRoute {
        let start = UUID()
        let firstTurn = UUID()
        let secondTurn = UUID()
        let finish = UUID()
        return PlannedRoute(
            destinationAnchorID: UUID(),
            destinationNodeID: finish,
            startNodeID: start,
            nodePath: [start, firstTurn, secondTurn, finish],
            segments: [
                RouteSegment(
                    fromNodeID: start,
                    toNodeID: firstTurn,
                    startPosition: SIMD3<Float>(0, 0, 0),
                    endPosition: SIMD3<Float>(1, 0, 0),
                    headingDegrees: 0,
                    distanceMeters: 1
                ),
                RouteSegment(
                    fromNodeID: firstTurn,
                    toNodeID: secondTurn,
                    startPosition: SIMD3<Float>(1, 0, 0),
                    endPosition: SIMD3<Float>(1, 0, 1),
                    headingDegrees: 90,
                    distanceMeters: 1
                ),
                RouteSegment(
                    fromNodeID: secondTurn,
                    toNodeID: finish,
                    startPosition: SIMD3<Float>(1, 0, 1),
                    endPosition: SIMD3<Float>(2, 0, 1),
                    headingDegrees: 0,
                    distanceMeters: 1
                )
            ],
            totalDistanceMeters: 3
        )
    }
}
