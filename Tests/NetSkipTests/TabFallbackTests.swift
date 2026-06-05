// SPDX-License-Identifier: GPL-2.0-or-later
//
// Headless tests for `BrowserTabView.effectiveURL(for:)` /
// `effectiveTitle(for:)` and the `BrowserViewModel` initial state.
// These exercise the savedURL / savedTitle mirror that backs the
// tab grid when a tab's WebView is detached (iOS) or about:blank
// (transient KVO during teardown). The live `WebViewState` is
// `internal(set)` in `SkipWeb`, so we can't drive its `url` field
// from a test — but the no-live-state case is exactly the one the
// fallback exists for, and that's what we cover here.

import XCTest
import Foundation
import NetSkipModel

#if SKIP || os(iOS)
import SkipWeb
@testable import NetSkip

@available(macOS 13, *)
final class TabFallbackTests: XCTestCase {

    // MARK: - Helpers

    /// Build a stand-alone view-model without going through
    /// `BrowserTabView.newViewModel`, which would require a full
    /// view. We supply a navigator with the desired initial URL and
    /// an in-memory SQL store so the model has somewhere to point
    /// without touching disk.
    @MainActor
    func makeViewModel(savedURL: String = "", savedTitle: String = "", initialURL: String? = nil, isPrivate: Bool = false) throws -> BrowserViewModel {
        let store: WebBrowserStore = try SQLBrowserStore(url: nil)
        let navigator = WebViewNavigator(initialURL: initialURL.flatMap { URL(string: $0) })
        let config = WebEngineConfiguration()
        let vm = BrowserViewModel(id: 1, navigator: navigator, configuration: config, store: store, isPrivate: isPrivate)
        vm.savedURL = savedURL
        vm.savedTitle = savedTitle
        return vm
    }

    // MARK: - effectiveURL fallback

    @MainActor
    func testEffectiveURLFallsBackToSavedURLWhenLiveIsNil() throws {
        let vm = try makeViewModel(savedURL: "https://en.wikipedia.org/wiki/1")
        // Fresh view-model: state.url is nil (no WebView attached).
        XCTAssertNil(vm.state.url, "freshly-constructed BrowserViewModel should have nil live URL")
        XCTAssertEqual(BrowserTabView.effectiveURL(for: vm), "https://en.wikipedia.org/wiki/1")
    }

    @MainActor
    func testEffectiveURLReturnsEmptyWhenNothingSaved() throws {
        let vm = try makeViewModel()
        XCTAssertEqual(BrowserTabView.effectiveURL(for: vm), "")
    }

    @MainActor
    func testEffectiveTitleFallsBackToSavedTitleWhenLiveIsNil() throws {
        let vm = try makeViewModel(savedTitle: "Wikipedia — 1 (number)")
        XCTAssertNil(vm.state.pageTitle, "freshly-constructed BrowserViewModel should have nil live title")
        XCTAssertEqual(BrowserTabView.effectiveTitle(for: vm), "Wikipedia — 1 (number)")
    }

    @MainActor
    func testEffectiveTitleReturnsEmptyWhenNothingSaved() throws {
        let vm = try makeViewModel()
        XCTAssertEqual(BrowserTabView.effectiveTitle(for: vm), "")
    }

    // MARK: - BrowserViewModel construction

    @MainActor
    func testNewViewModelDefaultsAreSensible() throws {
        let vm = try makeViewModel()
        XCTAssertEqual(vm.id, 1)
        XCTAssertEqual(vm.savedURL, "")
        XCTAssertEqual(vm.savedTitle, "")
        XCTAssertFalse(vm.isPinned)
        XCTAssertFalse(vm.isPrivate)
        XCTAssertFalse(vm.shouldFocusURLBar)
        XCTAssertFalse(vm.inReaderMode)
    }

    @MainActor
    func testNewViewModelInitialURLFlowsToNavigator() throws {
        let vm = try makeViewModel(initialURL: "https://example.com/start")
        // The navigator stores initialURL for the engine-recreation
        // restore path — kept current by updatePageURL after the
        // 2026-06-04 fix in netskip-tab-state-restoration.md.
        XCTAssertEqual(vm.navigator.initialURL?.absoluteString, "https://example.com/start")
    }

    @MainActor
    func testPrivateFlagPersists() throws {
        let vm = try makeViewModel(isPrivate: true)
        XCTAssertTrue(vm.isPrivate)
    }

    @MainActor
    func testSavedURLAndTitleAreMutable() throws {
        let vm = try makeViewModel()
        vm.savedURL = "https://example.com/page"
        vm.savedTitle = "Example"
        XCTAssertEqual(BrowserTabView.effectiveURL(for: vm), "https://example.com/page")
        XCTAssertEqual(BrowserTabView.effectiveTitle(for: vm), "Example")
    }
}

#endif
