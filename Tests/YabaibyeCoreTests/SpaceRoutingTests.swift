import XCTest
@testable import YabaibyeCore

final class SpaceRoutingTests: XCTestCase {
    private let first = DisplaySpaces(uuid: "DISPLAY-A", current: 1, spaces: [Desktop(id: 1), Desktop(id: 2)])
    private let second = DisplaySpaces(uuid: "DISPLAY-B", current: 3, spaces: [Desktop(id: 3), Desktop(id: 4)])
    private let third = DisplaySpaces(uuid: "DISPLAY-C", current: 5, spaces: [Desktop(id: 5)])

    func testCurrentAndOtherDisplayResolveFromEitherFocusedDisplay() {
        let displays = [first, second]
        XCTAssertEqual(SpaceRouter.navigationDisplay(currentDisplayID: "display-a", other: false, displays: displays), first)
        XCTAssertEqual(SpaceRouter.navigationDisplay(currentDisplayID: "display-b", other: false, displays: displays), second)
        XCTAssertEqual(SpaceRouter.navigationDisplay(currentDisplayID: "display-a", other: true, displays: displays), second)
        XCTAssertEqual(SpaceRouter.navigationDisplay(currentDisplayID: "display-b", other: true, displays: displays), first)
    }

    func testReorderedDisplayListStillSelectsTheNonCurrentDisplay() {
        let displays = [second, first]
        XCTAssertEqual(SpaceRouter.navigationDisplay(currentDisplayID: first.uuid, other: true, displays: displays), second)
        XCTAssertEqual(SpaceRouter.navigationDisplay(currentDisplayID: second.uuid, other: true, displays: displays), first)
    }

    func testSingleDisplaySupportsCurrentNavigationButHasNoOtherDisplay() {
        XCTAssertEqual(SpaceRouter.navigationDisplay(currentDisplayID: first.uuid, other: false, displays: [first]), first)
        XCTAssertNil(SpaceRouter.navigationDisplay(currentDisplayID: first.uuid, other: true, displays: [first]))
    }

    func testUnknownAndEmptyDisplayListsReturnNoTarget() {
        for other in [false, true] {
            XCTAssertNil(SpaceRouter.navigationDisplay(currentDisplayID: "unknown", other: other, displays: [first, second]))
            XCTAssertNil(SpaceRouter.navigationDisplay(currentDisplayID: first.uuid, other: other, displays: []))
        }
    }

    func testThreeDisplaysFollowListOrderAndWrapAtTheEnd() {
        let displays = [second, first, third]
        XCTAssertEqual(SpaceRouter.navigationDisplay(currentDisplayID: second.uuid, other: true, displays: displays), first)
        XCTAssertEqual(SpaceRouter.navigationDisplay(currentDisplayID: first.uuid, other: true, displays: displays), third)
        XCTAssertEqual(SpaceRouter.navigationDisplay(currentDisplayID: third.uuid, other: true, displays: displays), second)
    }

    func testOtherDisplayBindingsAndSerializedSecondaryFieldRemainCompatible() throws {
        let expected = [Binding(33, shift: true, command: .cycle(-1, secondary: true)),
                        Binding(30, shift: true, command: .cycle(1, secondary: true))]
        let actual = Binding.defaults.filter { binding in
            if case .cycle(_, secondary: true) = binding.command { return true }
            return false
        }
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(actual.map(\.label), ["⌥⇧[", "⌥⇧]"])
        XCTAssertEqual(actual.map(\.actionLabel), ["另一屏幕：上个 Space", "另一屏幕：下个 Space"])
        let saved = #"{"cycle":{"_0":-1,"secondary":true}}"#
        let command = try JSONDecoder().decode(Command.self, from: Data(saved.utf8))
        XCTAssertEqual(command, .cycle(-1, secondary: true))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(command)) as? [String: Any])
        let cycle = try XCTUnwrap(object["cycle"] as? [String: Any])
        XCTAssertEqual(cycle["secondary"] as? Bool, true)
    }
}
