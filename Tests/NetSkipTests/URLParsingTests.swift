// SPDX-License-Identifier: GPL-2.0-or-later
//
// Headless tests for the URL-bar parse / HTTPS-upgrade / local-host
// detection helpers in `Browser/URLBarSubmit.swift`. These cover the
// pure logic underneath `submitURL` without needing a SwiftUI view
// tree, so they run cleanly under both `swift test` and the Skip
// gradle harness (transpiled to JUnit, run via Robolectric or — with
// `ANDROID_SERIAL=<id>` — a connected emulator).

import XCTest
import Foundation

#if SKIP || os(iOS)
@testable import NetSkip

@available(macOS 13, *)
final class URLParsingTests: XCTestCase {

    // MARK: - fieldToURL

    func testFieldToURL_acceptsExplicitHTTPS() throws {
        let url = try XCTUnwrap(BrowserTabView.fieldToURL("https://example.com"))
        XCTAssertEqual(url.absoluteString, "https://example.com")
        XCTAssertEqual(url.scheme, "https")
    }

    func testFieldToURL_acceptsExplicitHTTP() throws {
        let url = try XCTUnwrap(BrowserTabView.fieldToURL("http://example.com/path"))
        XCTAssertEqual(url.scheme, "http")
        XCTAssertEqual(url.host, "example.com")
    }

    func testFieldToURL_acceptsFileScheme() throws {
        let url = try XCTUnwrap(BrowserTabView.fieldToURL("file:///tmp/index.html"))
        XCTAssertEqual(url.scheme, "file")
    }

    func testFieldToURL_prependsHTTPSToBareHost() throws {
        let url = try XCTUnwrap(BrowserTabView.fieldToURL("example.com"))
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "example.com")
    }

    func testFieldToURL_prependsHTTPSToBareHostWithPath() throws {
        let url = try XCTUnwrap(BrowserTabView.fieldToURL("en.wikipedia.org/wiki/Web_browser"))
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "en.wikipedia.org")
    }

    func testFieldToURL_returnsNilForSearchTerms() {
        // Multi-word queries with spaces are treated as searches and
        // shunted to the search engine path in `submitURL`.
        XCTAssertNil(BrowserTabView.fieldToURL("cross platform browser"))
        XCTAssertNil(BrowserTabView.fieldToURL("how to make pizza"))
    }

    func testFieldToURL_returnsNilForSingleWordNoSpaceNoSDot() {
        // Single-word, no scheme, no dot — also treated as a search.
        XCTAssertNil(BrowserTabView.fieldToURL("browser"))
        XCTAssertNil(BrowserTabView.fieldToURL("hello"))
    }

    func testFieldToURL_returnsNilForEmptyString() {
        XCTAssertNil(BrowserTabView.fieldToURL(""))
    }

    func testFieldToURL_specialSchemesCurrentlyFallThroughToSearch() {
        // *** Documents an existing gap. ***
        //
        // `submitURL` checks the parsed URL's scheme against an
        // allow-list of {http, https, file, ftp, netskip}. mailto/tel/
        // sms/javascript/data are NOT in that list, so they fall
        // through to the search engine instead of being handed to
        // the system. What `fieldToURL` returns for each varies by
        // platform — Apple Foundation's `URL` parses `mailto:` and
        // `data:` as valid URLs, while Java's `URI` (used on Skip's
        // Android target) rejects the more exotic shapes outright.
        // Either way the end-user outcome is the same: nothing
        // navigates, nothing dials, nothing composes — the text is
        // searched. The asserts below pin only the cases that agree
        // across platforms; the broader gap is tracked separately.

        // `tel:` has no dot anywhere → the "no dot" branch returns
        // nil on every platform.
        XCTAssertNil(BrowserTabView.fieldToURL("tel:+15555550123"))

        // `mailto:foo@bar.com` contains a dot (the recipient host)
        // so the parser tries `URL(string:)`. On Apple platforms
        // that succeeds and returns a URL with scheme=`mailto`; on
        // Android it may return nil. Either way submitURL would
        // shunt it to search, which is the only thing tested
        // elsewhere. We just verify the call doesn't crash.
        _ = BrowserTabView.fieldToURL("mailto:foo@bar.com")
    }

    // MARK: - maybeUpgradeToHTTPS

    func testMaybeUpgradeToHTTPS_disabledIsNoOp() throws {
        let input = try XCTUnwrap(URL(string: "http://example.com/page"))
        let result = BrowserTabView.maybeUpgradeToHTTPS(input, enabled: false)
        XCTAssertEqual(result.absoluteString, "http://example.com/page")
    }

    func testMaybeUpgradeToHTTPS_upgradesHTTPHost() throws {
        let input = try XCTUnwrap(URL(string: "http://example.com/page?q=1"))
        let result = BrowserTabView.maybeUpgradeToHTTPS(input, enabled: true)
        XCTAssertEqual(result.absoluteString, "https://example.com/page?q=1")
    }

    func testMaybeUpgradeToHTTPS_leavesHTTPSAlone() throws {
        let input = try XCTUnwrap(URL(string: "https://example.com"))
        let result = BrowserTabView.maybeUpgradeToHTTPS(input, enabled: true)
        XCTAssertEqual(result.absoluteString, "https://example.com")
    }

    func testMaybeUpgradeToHTTPS_leavesLocalhostAlone() throws {
        let input = try XCTUnwrap(URL(string: "http://localhost:8080/index"))
        let result = BrowserTabView.maybeUpgradeToHTTPS(input, enabled: true)
        // Developer almost certainly meant to hit cleartext localhost.
        XCTAssertEqual(result.scheme, "http")
        XCTAssertEqual(result.host, "localhost")
    }

    func testMaybeUpgradeToHTTPS_leavesIPv4DottedQuadAlone() throws {
        let input = try XCTUnwrap(URL(string: "http://192.168.1.1/admin"))
        let result = BrowserTabView.maybeUpgradeToHTTPS(input, enabled: true)
        XCTAssertEqual(result.scheme, "http")
    }

    func testMaybeUpgradeToHTTPS_leavesSingleLabelHostAlone() throws {
        let input = try XCTUnwrap(URL(string: "http://devbox/api"))
        let result = BrowserTabView.maybeUpgradeToHTTPS(input, enabled: true)
        // No dot in host → treated as local dev target.
        XCTAssertEqual(result.scheme, "http")
    }

    func testMaybeUpgradeToHTTPS_leavesFileSchemeAlone() throws {
        let input = try XCTUnwrap(URL(string: "file:///tmp/index.html"))
        let result = BrowserTabView.maybeUpgradeToHTTPS(input, enabled: true)
        XCTAssertEqual(result.scheme, "file")
    }

    // MARK: - isLocalOrIPHost

    func testIsLocalOrIPHost_localhost() {
        XCTAssertTrue(BrowserTabView.isLocalOrIPHost("localhost"))
        XCTAssertTrue(BrowserTabView.isLocalOrIPHost("api.localhost"))
        XCTAssertTrue(BrowserTabView.isLocalOrIPHost("foo.bar.localhost"))
    }

    func testIsLocalOrIPHost_singleLabelHost() {
        // Anything without a dot — typical for `/etc/hosts` aliases.
        XCTAssertTrue(BrowserTabView.isLocalOrIPHost("devbox"))
        XCTAssertTrue(BrowserTabView.isLocalOrIPHost("router"))
    }

    func testIsLocalOrIPHost_ipv4() {
        XCTAssertTrue(BrowserTabView.isLocalOrIPHost("127.0.0.1"))
        XCTAssertTrue(BrowserTabView.isLocalOrIPHost("192.168.0.1"))
        XCTAssertTrue(BrowserTabView.isLocalOrIPHost("10.0.0.5"))
    }

    func testIsLocalOrIPHost_publicHost() {
        XCTAssertFalse(BrowserTabView.isLocalOrIPHost("example.com"))
        XCTAssertFalse(BrowserTabView.isLocalOrIPHost("en.wikipedia.org"))
        XCTAssertFalse(BrowserTabView.isLocalOrIPHost("api.github.com"))
    }

    func testIsLocalOrIPHost_almostIPv4NotMatched() {
        // Four dotted parts but not all numeric — a regular hostname,
        // not an IPv4 literal.
        XCTAssertFalse(BrowserTabView.isLocalOrIPHost("a.b.c.d"))
        // Three numeric parts (incomplete IPv4) — has a dot so it's
        // public-looking.
        XCTAssertFalse(BrowserTabView.isLocalOrIPHost("1.2.3"))
    }
}

#endif
