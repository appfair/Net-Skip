// SPDX-License-Identifier: GPL-2.0-or-later
//
// Tab persistence — loading saved tabs out of the SQL store on
// launch, creating new view-models, and the live → saved* mirror
// fallback helpers that keep tab cards readable when a backgrounded
// WKWebView fires `about:blank` during teardown.

import SwiftUI
import SkipWeb
import NetSkipModel

#if SKIP || os(iOS)

extension BrowserTabView {
    func restoreActiveTabs() {
        // Guard against re-entry. The `browserTabView()` view's
        // `.onAppear` fires again whenever the parent body's
        // structure changes — switching `bottomOverlay` between
        // `findBar` / `pageZoom` / `nil` recomposes the bottom slot,
        // which on Android (Compose's LaunchedEffect-style semantics)
        // re-runs `onAppear` on the sibling `TabView`. Without this
        // guard, the second call re-appends the already-restored
        // tabs, two view-models in `tabs` end up sharing the same
        // `id`, and Compose's `LazyList` crashes with `Key "1" was
        // already used. If you are using LazyColumn/Row please make
        // sure you provide a unique key for each item.`
        if !self.tabs.isEmpty { return }

        let activeTabs = trying { try store.loadItems(type: PageInfo.PageType.active, ids: []) }

        var hasBlankTab = false
        var blankTabIdsToRemove: [PageInfo.ID] = []
        var seenIDs: Set<PageInfo.ID> = []

        for activeTab in activeTabs ?? [] {
            // Defensive dedupe by id — a corrupted store with two rows
            // sharing an id would otherwise produce two view-models with
            // the same `BrowserViewModel.id`, which the `ForEach($tabs)`
            // backing the Compose Pager rejects with `Key "N" was
            // already used`.
            if !seenIDs.insert(activeTab.id).inserted {
                logger.warning("restoreActiveTabs: skipping duplicate id \(activeTab.id) from store")
                continue
            }

            let isBlank = activeTab.url == nil || activeTab.url == "" || activeTab.url == "about:blank"

            // Only keep one blank tab; remove duplicates from the database.
            if isBlank {
                if hasBlankTab {
                    blankTabIdsToRemove.append(activeTab.id)
                    continue
                }
                hasBlankTab = true
            }

            logger.log("restoring tab \(activeTab.id): \(activeTab.url ?? "NONE") title=\(activeTab.title ?? "")")
            let viewModel = newViewModel(activeTab)
            self.tabs.append(viewModel)
        }

        if !blankTabIdsToRemove.isEmpty {
            logger.info("removing \(blankTabIdsToRemove.count) duplicate blank tabs")
            try? store.removeItems(type: .active, ids: Set(blankTabIdsToRemove))
        }

        // Always have at least one tab open.
        if self.tabs.isEmpty {
            newTabAction()
        }

        // Select the most recently selected tab if it still exists.
        if let selectedTabID = PageInfo.ID(selectedTabState), self.tabs.contains(where: { $0.id == selectedTabID }) {
            self.selectedTab = selectedTabID
        } else {
            self.selectedTab = tabs.last?.id ?? self.selectedTab
        }
    }

    func newViewModel(_ pageInfo: PageInfo, isPrivate: Bool = false) -> BrowserViewModel {
        // Private tabs are NEVER written to the `active` store — that
        // would leak the visited URL onto disk via the next restore.
        // Fall back to a fresh ephemeral ID drawn from the same source
        // the store would have used, so private tab IDs still don't
        // collide with regular tabs in the live `tabs` array.
        let newID: PageInfo.ID
        if isPrivate {
            newID = Self.nextEphemeralTabID()
        } else {
            newID = (try? store.saveItems(type: .active, items: [pageInfo]).first) ?? PageInfo.ID(0)
        }
        let newURL = URL(string: pageInfo.url ?? fallbackURL)
        let cfg = isPrivate ? privateConfiguration : configuration
        let vm = BrowserViewModel(id: newID, navigator: WebViewNavigator(initialURL: newURL), configuration: cfg, store: store, isPrivate: isPrivate)
        vm.savedTitle = pageInfo.title ?? ""
        vm.savedURL = pageInfo.url ?? ""
        vm.isPinned = pageInfo.pinned
        return vm
    }

    /// Monotonically increasing counter used for private-tab IDs.
    /// Starts from a very large negative value so it can never collide
    /// with the SQLite AUTOINCREMENT IDs the regular `active` store
    /// hands out (SQLite IDs are non-negative). Process-local — private
    /// tab IDs aren't persistent and don't need to.
    nonisolated(unsafe) private static var ephemeralTabIDCounter: PageInfo.ID = PageInfo.ID.min
    private static func nextEphemeralTabID() -> PageInfo.ID {
        ephemeralTabIDCounter += 1
        return ephemeralTabIDCounter
    }

    func logTabs() {
        logger.info("selected=\(selectedTab) count=\(self.tabs.count)")
    }

    /// Best-known URL for a tab. Prefers the WKWebView's live
    /// `state.url`, but falls through to the persisted `savedURL`
    /// mirror when the live value is `about:blank` (transient reset
    /// from a backgrounded WebView's KVO) or empty.
    static func effectiveURL(for tab: BrowserViewModel) -> String {
        let live = tab.state.url?.absoluteString ?? ""
        if live.isEmpty || live == "about:blank" {
            return tab.savedURL
        }
        return live
    }

    /// Best-known title for a tab. Same backgrounded-WebView reasoning
    /// as `effectiveURL`.
    static func effectiveTitle(for tab: BrowserViewModel) -> String {
        let live = tab.state.pageTitle ?? ""
        return live.isEmpty ? tab.savedTitle : live
    }
}

#endif
