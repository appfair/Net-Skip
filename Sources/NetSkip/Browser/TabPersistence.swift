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
        let activeTabs = trying { try store.loadItems(type: PageInfo.PageType.active, ids: []) }

        var hasBlankTab = false
        var blankTabIdsToRemove: [PageInfo.ID] = []

        for activeTab in activeTabs ?? [] {
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

    func newViewModel(_ pageInfo: PageInfo) -> BrowserViewModel {
        let newID = (try? store.saveItems(type: .active, items: [pageInfo]).first) ?? PageInfo.ID(0)
        let newURL = URL(string: pageInfo.url ?? fallbackURL)
        let vm = BrowserViewModel(id: newID, navigator: WebViewNavigator(initialURL: newURL), configuration: configuration, store: store)
        vm.savedTitle = pageInfo.title ?? ""
        vm.savedURL = pageInfo.url ?? ""
        vm.isPinned = pageInfo.pinned
        return vm
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
