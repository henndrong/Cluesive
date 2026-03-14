import XCTest
import ARKit
@testable import Cluesive

final class LocalizationReadinessCoordinatorTests: XCTestCase {
    func testReadyRequiresUsableLocalizationStablePoseAndConfidence() {
        let snapshot = LocalizationReadinessCoordinator.snapshot(
            inputs: .init(
                appLocalizationState: .arkitConfirmed,
                latestLocalizationConfidence: 0.8,
                acceptedMeshAlignmentConfidence: nil,
                isPoseStable: true,
                hasPose: true,
                trackingState: .normal
            )
        )

        XCTAssertEqual(snapshot.state, .ready)
    }

    func testNoPoseIsNotReady() {
        let snapshot = LocalizationReadinessCoordinator.snapshot(
            inputs: .init(
                appLocalizationState: .arkitConfirmed,
                latestLocalizationConfidence: 0.9,
                acceptedMeshAlignmentConfidence: nil,
                isPoseStable: true,
                hasPose: false,
                trackingState: .normal
            )
        )

        XCTAssertEqual(snapshot.state, .notReady)
    }

    func testUnstablePoseIsRecovering() {
        let snapshot = LocalizationReadinessCoordinator.snapshot(
            inputs: .init(
                appLocalizationState: .meshAlignedOverride,
                latestLocalizationConfidence: 0.9,
                acceptedMeshAlignmentConfidence: nil,
                isPoseStable: false,
                hasPose: true,
                trackingState: .normal
            )
        )

        XCTAssertEqual(snapshot.state, .recovering)
        XCTAssertEqual(snapshot.reason, "Heading unstable")
    }

    func testLowConfidenceIsRecovering() {
        let snapshot = LocalizationReadinessCoordinator.snapshot(
            inputs: .init(
                appLocalizationState: .meshAlignedOverride,
                latestLocalizationConfidence: 0.4,
                acceptedMeshAlignmentConfidence: nil,
                isPoseStable: true,
                hasPose: true,
                trackingState: .normal
            )
        )

        XCTAssertEqual(snapshot.state, .recovering)
        XCTAssertEqual(snapshot.reason, "Confidence below threshold")
    }
}
