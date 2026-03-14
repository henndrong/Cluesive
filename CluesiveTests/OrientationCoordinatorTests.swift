import XCTest
@testable import Cluesive

final class OrientationCoordinatorTests: XCTestCase {
    func testNegativeDeltaMeansTurnLeft() {
        let route = PlannedRoute(
            destinationAnchorID: UUID(),
            destinationNodeID: UUID(),
            startNodeID: UUID(),
            nodePath: [UUID(), UUID()],
            segments: [
                RouteSegment(
                    fromNodeID: UUID(),
                    toNodeID: UUID(),
                    startPosition: .zero,
                    endPosition: SIMD3<Float>(1, 0, 0),
                    headingDegrees: 0,
                    distanceMeters: 1
                )
            ],
            totalDistanceMeters: 1
        )
        let target = OrientationCoordinator.makeTarget(route: route)!

        let outcome = OrientationCoordinator.update(
            state: .init(alignedSince: nil),
            inputs: .init(
                readinessState: .ready,
                target: target,
                currentHeadingDegrees: 20,
                isPoseStable: true,
                now: Date()
            )
        )

        XCTAssertEqual(outcome.snapshot.state, .turnLeft)
        XCTAssertLessThan(outcome.snapshot.deltaDegrees, 0)
    }

    func testAlignmentRequiresHoldDuration() {
        let route = PlannedRoute(
            destinationAnchorID: UUID(),
            destinationNodeID: UUID(),
            startNodeID: UUID(),
            nodePath: [UUID(), UUID()],
            segments: [
                RouteSegment(
                    fromNodeID: UUID(),
                    toNodeID: UUID(),
                    startPosition: .zero,
                    endPosition: SIMD3<Float>(1, 0, 0),
                    headingDegrees: 0,
                    distanceMeters: 1
                )
            ],
            totalDistanceMeters: 1
        )
        let target = OrientationCoordinator.makeTarget(route: route)!
        let now = Date()

        let first = OrientationCoordinator.update(
            state: .init(alignedSince: nil),
            inputs: .init(
                readinessState: .ready,
                target: target,
                currentHeadingDegrees: 2,
                isPoseStable: true,
                now: now
            )
        )
        let second = OrientationCoordinator.update(
            state: first.state,
            inputs: .init(
                readinessState: .ready,
                target: target,
                currentHeadingDegrees: 1,
                isPoseStable: true,
                now: now.addingTimeInterval(0.8)
            )
        )

        XCTAssertFalse(first.snapshot.isAligned)
        XCTAssertEqual(first.snapshot.state, .nearlyAligned)
        XCTAssertTrue(second.snapshot.isAligned)
        XCTAssertEqual(second.snapshot.state, .aligned)
    }

    func testUnstableHeadingInterruptsAlignment() {
        let route = PlannedRoute(
            destinationAnchorID: UUID(),
            destinationNodeID: UUID(),
            startNodeID: UUID(),
            nodePath: [UUID(), UUID()],
            segments: [
                RouteSegment(
                    fromNodeID: UUID(),
                    toNodeID: UUID(),
                    startPosition: .zero,
                    endPosition: SIMD3<Float>(1, 0, 0),
                    headingDegrees: 0,
                    distanceMeters: 1
                )
            ],
            totalDistanceMeters: 1
        )
        let target = OrientationCoordinator.makeTarget(route: route)!

        let outcome = OrientationCoordinator.update(
            state: .init(alignedSince: Date()),
            inputs: .init(
                readinessState: .ready,
                target: target,
                currentHeadingDegrees: 0,
                isPoseStable: false,
                now: Date()
            )
        )

        XCTAssertEqual(outcome.snapshot.state, .unstableHeading)
        XCTAssertFalse(outcome.snapshot.isAligned)
    }
}
