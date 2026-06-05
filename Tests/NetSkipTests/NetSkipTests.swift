// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
import OSLog
import Foundation
// `@testable import NetSkip` is gated to SKIP / iOS only because the
// NetSkip module references UIKit and other iOS-only APIs inside
// `#if !SKIP` blocks that don't compile on the macOS host SwiftPM
// uses for `swift test`. On macOS this file becomes an empty test
// shell; the actual tests run via `XCSkipTests.testSkipModule()`
// which transpiles to Kotlin and runs against the Android emulator
// (set `ANDROID_SERIAL=<id>` to target a device instead of
// Robolectric).
#if SKIP || os(iOS)
@testable import NetSkip
#endif

let logger: Logger = Logger(subsystem: "NetSkip", category: "Tests")

#if SKIP || os(iOS)

@available(macOS 13, *)
final class NetSkipTests: XCTestCase {
    func testNetSkip() throws {
        logger.log("running testNetSkip")
        XCTAssertEqual(1 + 2, 3, "basic test")

        // load the TestData.json file from the Resources folder and decode it into a struct
        let resourceURL: URL = try XCTUnwrap(Bundle.module.url(forResource: "TestData", withExtension: "json"))
        let testData = try JSONDecoder().decode(TestData.self, from: Data(contentsOf: resourceURL))
        XCTAssertEqual("NetSkip", testData.testModuleName)
    }
}

struct TestData : Codable, Hashable {
    var testModuleName: String
}

#endif
