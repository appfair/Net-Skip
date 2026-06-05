// SPDX-License-Identifier: GPL-2.0-or-later
//
// Smoke tests for `DefaultBrowser` — the cross-platform helper
// that wraps Android `RoleManager` and the iOS Settings deep-link.
// Doesn't assert which status is returned (depends on the device's
// current role assignment) but verifies the call doesn't throw,
// returns a valid enum, and the equality semantics are sound.

import XCTest

#if SKIP || os(iOS)
@testable import NetSkip

@available(macOS 13, *)
final class DefaultBrowserTests: XCTestCase {

    @MainActor
    func testCurrentStatusReturnsAKnownState() {
        // Whatever the device reports, the result must be one of the
        // three documented cases — never a crash, never something
        // outside the enum.
        let status = DefaultBrowser.currentStatus()
        switch status {
        case .roleUnavailable, .eligibleButNotDefault, .held:
            // ok — all three are documented valid states
            break
        }
    }

    @MainActor
    func testCurrentStatusIsStable() {
        // Two consecutive calls with no intervening role change
        // should report the same state. Catches accidental
        // counter-bump / side-effect mistakes.
        let a = DefaultBrowser.currentStatus()
        let b = DefaultBrowser.currentStatus()
        XCTAssertEqual(a, b)
    }

    func testStatusEnumEquality() {
        XCTAssertEqual(DefaultBrowserStatus.held, DefaultBrowserStatus.held)
        XCTAssertEqual(DefaultBrowserStatus.eligibleButNotDefault, DefaultBrowserStatus.eligibleButNotDefault)
        XCTAssertEqual(DefaultBrowserStatus.roleUnavailable, DefaultBrowserStatus.roleUnavailable)
        XCTAssertNotEqual(DefaultBrowserStatus.held, DefaultBrowserStatus.eligibleButNotDefault)
        XCTAssertNotEqual(DefaultBrowserStatus.eligibleButNotDefault, DefaultBrowserStatus.roleUnavailable)
    }
}

#endif
