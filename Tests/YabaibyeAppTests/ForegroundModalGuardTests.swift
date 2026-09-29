import XCTest
import AppKit
@testable import Yabaibye

final class ForegroundModalGuardTests: XCTestCase {
    private typealias Reply = (AXError, CFTypeRef?)

    private struct Fixture {
        // These handles are identity tokens only; every attribute read is injected.
        let window = AXUIElementCreateApplication(900001)
        let child = AXUIElementCreateApplication(900002)
        var windowReplies: [String: Reply] = [
            kAXRoleAttribute: (.success, kAXWindowRole as NSString),
            kAXModalAttribute: (.success, kCFBooleanFalse),
            kAXChildrenAttribute: (.success, [] as NSArray)
        ]
        var childReply: Reply = (.success, kAXGroupRole as NSString)

        func allowsRaise() -> Bool {
            ForegroundModalGuard.allowsRaise(window, read: { element, attribute in
                if CFEqual(element, window) {
                    return windowReplies[attribute] ?? (.attributeUnsupported, nil)
                }
                if CFEqual(element, child), attribute == kAXRoleAttribute { return childReply }
                return (.failure, nil)
            })
        }
    }

    func testOrdinaryWindowWithoutModalChildrenAllowsRaise() {
        var fixture = Fixture()
        XCTAssertTrue(fixture.allowsRaise())
        fixture.windowReplies[kAXChildrenAttribute] = (.success, [fixture.child] as NSArray)
        XCTAssertTrue(fixture.allowsRaise())
    }

    func testModalWindowPreventsRaise() {
        var fixture = Fixture()
        fixture.windowReplies[kAXModalAttribute] = (.success, kCFBooleanTrue)
        XCTAssertFalse(fixture.allowsRaise())
    }

    func testAttachedSheetPreventsRaisingItsOrdinaryParent() {
        var fixture = Fixture()
        fixture.windowReplies[kAXChildrenAttribute] = (.success, [fixture.child] as NSArray)
        fixture.childReply = (.success, kAXSheetRole as NSString)
        XCTAssertFalse(fixture.allowsRaise())
    }

    func testFocusedElementMustHaveConfirmedWindowRole() {
        let replies: [Reply] = [
            (.success, kAXSheetRole as NSString),
            (.success, kAXGroupRole as NSString),
            (.success, nil),
            (.success, NSNumber(value: 7)),
            (.cannotComplete, nil),
            (.attributeUnsupported, nil),
            (.noValue, nil)
        ]
        for reply in replies {
            var fixture = Fixture()
            fixture.windowReplies[kAXRoleAttribute] = reply
            XCTAssertFalse(fixture.allowsRaise())
        }
    }

    func testOptionalModalAndChildrenAttributesCanBeUnsupported() {
        for modalError in [AXError.attributeUnsupported, .noValue] {
            for childrenError in [AXError.attributeUnsupported, .noValue] {
                var fixture = Fixture()
                fixture.windowReplies[kAXModalAttribute] = (modalError, nil)
                fixture.windowReplies[kAXChildrenAttribute] = (childrenError, nil)
                XCTAssertTrue(fixture.allowsRaise())
            }
        }
    }

    func testCommunicationFailuresDoNotMeanNoModalOrNoChildren() {
        for attribute in [kAXModalAttribute, kAXChildrenAttribute] {
            for error in [AXError.cannotComplete, .invalidUIElement, .apiDisabled, .failure] {
                var fixture = Fixture()
                fixture.windowReplies[attribute] = (error, nil)
                XCTAssertFalse(fixture.allowsRaise())
            }
        }
    }

    func testMalformedSuccessfulModalValuesPreventRaise() {
        let values: [CFTypeRef?] = [nil, "false" as NSString, [] as NSArray]
        for value in values {
            var fixture = Fixture()
            fixture.windowReplies[kAXModalAttribute] = (.success, value)
            XCTAssertFalse(fixture.allowsRaise())
        }
    }

    func testMalformedSuccessfulChildrenValuesPreventRaise() {
        let values: [CFTypeRef?] = [nil, "none" as NSString, ["not-an-AX-element"] as NSArray]
        for value in values {
            var fixture = Fixture()
            fixture.windowReplies[kAXChildrenAttribute] = (.success, value)
            XCTAssertFalse(fixture.allowsRaise())
        }
    }

    func testUnsupportedChildRoleDoesNotInventASheet() {
        for error in [AXError.attributeUnsupported, .noValue] {
            var fixture = Fixture()
            fixture.windowReplies[kAXChildrenAttribute] = (.success, [fixture.child] as NSArray)
            fixture.childReply = (error, nil)
            XCTAssertTrue(fixture.allowsRaise())
        }
    }

    func testChildRoleFailuresAndMalformedValuesPreventRaise() {
        let replies: [Reply] = [(.cannotComplete, nil), (.invalidUIElement, nil),
                                (.success, nil), (.success, NSNumber(value: 7))]
        for reply in replies {
            var fixture = Fixture()
            fixture.windowReplies[kAXChildrenAttribute] = (.success, [fixture.child] as NSArray)
            fixture.childReply = reply
            XCTAssertFalse(fixture.allowsRaise())
        }
    }
}
