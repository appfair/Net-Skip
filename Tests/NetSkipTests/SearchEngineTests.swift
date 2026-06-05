// SPDX-License-Identifier: GPL-2.0-or-later
//
// Headless tests for the bundled `SearchEngine` catalog and its
// `lookup` fallback. Cover identifier uniqueness, queryURL emission
// for representative engines, and homeURL parseability. No network
// calls — suggestions are out of scope here.

import XCTest
import Foundation
import NetSkipModel

#if SKIP || os(iOS)
@testable import NetSkip

@available(macOS 13, *)
final class SearchEngineTests: XCTestCase {

    func testDefaultSearchEnginesNonEmpty() {
        XCTAssertFalse(SearchEngine.defaultSearchEngines.isEmpty)
    }

    func testDefaultSearchEnginesHaveUniqueIDs() {
        let ids = SearchEngine.defaultSearchEngines.map { $0.id }
        let unique = Set(ids)
        XCTAssertEqual(ids.count, unique.count, "duplicate SearchEngine id(s) in defaultSearchEngines")
    }

    func testDefaultSearchEnginesNamesNonEmpty() {
        for engine in SearchEngine.defaultSearchEngines {
            XCTAssertFalse(engine.name().isEmpty, "engine \(engine.id) returned empty display name")
        }
    }

    func testHomeURLsParseAsURLs() {
        for engine in SearchEngine.defaultSearchEngines {
            let url = URL(string: engine.homeURL)
            XCTAssertNotNil(url, "engine \(engine.id) homeURL is not a valid URL: \(engine.homeURL)")
            // Most engines now serve HTTPS, but Baidu still ships
            // http://www.baidu.com/ as its canonical home — assert
            // only that the scheme is one of the two web schemes.
            let scheme = url?.scheme ?? ""
            XCTAssertTrue(scheme == "http" || scheme == "https", "engine \(engine.id) home URL has unexpected scheme '\(scheme)': \(engine.homeURL)")
        }
    }

    func testLookupReturnsExactMatch() throws {
        let engine = try XCTUnwrap(SearchEngine.lookup(id: "duckduckgo"))
        XCTAssertEqual(engine.id, "duckduckgo")
    }

    func testLookupReturnsKnownEngines() throws {
        // Spot-check the rest of the catalog.
        for id in ["google", "bing", "yahoo", "ecosia", "qwant", "startpage", "kagi"] {
            let engine = try XCTUnwrap(SearchEngine.lookup(id: id), "lookup failed for known engine: \(id)")
            XCTAssertEqual(engine.id, id)
        }
    }

    func testLookupFallsBackToFirstForUnknownID() throws {
        let unknown = try XCTUnwrap(SearchEngine.lookup(id: "this-engine-does-not-exist"))
        let first = try XCTUnwrap(SearchEngine.defaultSearchEngines.first)
        XCTAssertEqual(unknown.id, first.id, "unknown id should fall back to the first engine")
    }

    func testLookupFallsBackForEmptyID() throws {
        let result = try XCTUnwrap(SearchEngine.lookup(id: ""))
        let first = try XCTUnwrap(SearchEngine.defaultSearchEngines.first)
        XCTAssertEqual(result.id, first.id)
    }

    // MARK: - queryURL

    func testDuckDuckGoQueryURLContainsQuery() throws {
        let engine = try XCTUnwrap(SearchEngine.lookup(id: "duckduckgo"))
        let url = try XCTUnwrap(engine.queryURL("cats", "en_US"))
        XCTAssertTrue(url.hasPrefix("https://duckduckgo.com/"), "unexpected DDG queryURL host: \(url)")
        XCTAssertTrue(url.contains("cats"), "DDG queryURL did not embed query string: \(url)")
    }

    func testGoogleQueryURLContainsQuery() throws {
        let engine = try XCTUnwrap(SearchEngine.lookup(id: "google"))
        let url = try XCTUnwrap(engine.queryURL("rust async", "en_US"))
        XCTAssertTrue(url.hasPrefix("https://www.google.com/"), "unexpected Google queryURL host: \(url)")
        XCTAssertTrue(url.contains("rust async"), "Google queryURL did not embed query: \(url)")
    }

    func testQueryURLForEveryEngineProducesAURL() throws {
        // Each engine's queryURL closure should return a parseable
        // URL for a non-empty query — a smoke check that catches
        // template-string mistakes.
        for engine in SearchEngine.defaultSearchEngines {
            let raw = try XCTUnwrap(engine.queryURL("hello", "en_US"), "engine \(engine.id) returned nil queryURL")
            XCTAssertNotNil(URL(string: raw), "engine \(engine.id) queryURL did not parse as URL: \(raw)")
        }
    }
}

#endif
