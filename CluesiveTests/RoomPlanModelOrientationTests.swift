import XCTest
@testable import Cluesive

@MainActor
final class RoomPlanModelOrientationTests: XCTestCase {
    func testDestinationSelectionUpdatesState() {
        let model = RoomPlanModel()
        let anchorID = UUID()

        model.selectDestinationAnchor(anchorID)

        XCTAssertEqual(model.selectedDestinationAnchorID, anchorID)
        XCTAssertEqual(model.plannedRouteSummaryText, "Route: none")
    }

    func testStartingOrientationWithoutRouteIsBlocked() {
        let model = RoomPlanModel()

        model.startOrientationToRoute()

        XCTAssertFalse(model.isOrientationActive)
        XCTAssertEqual(model.orientationStatusText, "Orientation: waiting for localization")
    }
}
