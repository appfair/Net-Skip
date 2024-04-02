// This is free software: you can redistribute and/or modify it
// under the terms of the GNU Lesser General Public License 3.0
// as published by the Free Software Foundation https://fsf.org

import XCTest
import OSLog
import Foundation
import SkipSQL
import SkipWeb
@testable import NetSkipModel

let logger: Logger = Logger(subsystem: "NetSkipModel", category: "Tests")

@available(macOS 13, *)
final class NetSkipModelTests: XCTestCase {
    func testNetSkipModel() throws {
        logger.log("running testNetSkipModel")
        XCTAssertEqual(1 + 2, 3, "basic test")
        
        // load the TestData.json file from the Resources folder and decode it into a struct
        let resourceURL: URL = try XCTUnwrap(Bundle.module.url(forResource: "TestData", withExtension: "json"))
        let testData = try JSONDecoder().decode(TestData.self, from: Data(contentsOf: resourceURL))
        XCTAssertEqual("NetSkipModel", testData.testModuleName)
    }

    func testNetSkipBrowserStore() throws {
        let ctx = SQLContext() // in-memory context
        let store = try NetSkipWebBrowserStore(url: nil)

        XCTAssertEqual(0, try store.loadItems(type: .history, ids: []).count)

        let url = URL(string: "https://www.example.org")!
        let info = PageInfo(url: url)
        try store.saveItems(type: .history, items: [info])
        var info2 = try XCTUnwrap(store.loadItems(type: .history, ids: []).first)

        let id = info2.id
        XCTAssertEqual(Int64(1), id)
        XCTAssertEqual(url, info2.url)
        XCTAssertEqual(nil, info2.title)

        info2.title = "ABC"
        try store.saveItems(type: .history, items: [info2])
        XCTAssertEqual(1, try store.loadItems(type: .history, ids: []).count, "saving existing item should update row")

        let info3 = try XCTUnwrap(store.loadItems(type: .history, ids: [id]).first)
        XCTAssertEqual("ABC", info3.title)

        // re-saving an item with id=0 should make new records
        try store.saveItems(type: .history, items: [info])
        try store.saveItems(type: .history, items: [info, info])
        XCTAssertEqual(4, try store.loadItems(type: .history, ids: []).count, "saving new items should make new rows")

        try store.removeItems(type: .history, ids: [id])
        XCTAssertEqual(3, try store.loadItems(type: .history, ids: []).count, "removing single item should remove it from store")

        try store.removeItems(type: .history, ids: [])
        XCTAssertEqual(0, try store.loadItems(type: .history, ids: []).count, "removing empty id list should clear table")

    }
}

struct TestData : Codable, Hashable {
    var testModuleName: String
}
