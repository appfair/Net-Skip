// SPDX-License-Identifier: GPL-2.0-or-later
//
// Tab lifecycle actions — new / close / duplicate / sort / reload /
// reopen-closed. The reopen stack is per-session only, capped, and
// never persists across launches.

import SwiftUI
import NetSkipModel

#if SKIP || os(iOS)

extension BrowserTabView {
    /// Spawn a new tab, optionally pointed at `url`. Passing `nil`
    /// reuses an existing blank tab if one is already open, matching
    /// the modern-browser convention that you only get one blank tab
    /// at a time.
    func newTabAction(url: String? = nil, inBackground: Bool = false, isPrivate: Bool = false) {
        logger.info("newTabAction url=\(url ?? "nil") inBackground=\(inBackground) isPrivate=\(isPrivate)")
        hapticFeedback()

        // Snapshot the outgoing tab BEFORE we swap the WebView. On iOS
        // WKWebView's `takeSnapshot` returns blank pixels once the view
        // leaves the window hierarchy, and SwiftUI tears it down as
        // soon as `selectedTab` changes — so capture now while the
        // pixels are still on screen.
        if let outgoing = currentViewModel {
            // ALSO synchronously mirror the live state onto the
            // viewModel's `saved*` fields. `BrowserView`'s
            // `.onChange(of: state.pageURL)` handler does this in the
            // happy path, but a fast Maestro / user gesture can move
            // past Enter → switch-tab before the SwiftUI runloop has a
            // chance to fire that `.onChange`.
            if let pageURL = outgoing.state.url, pageURL.absoluteString != "about:blank" {
                outgoing.savedURL = pageURL.absoluteString
            }
            if let pageTitle = outgoing.state.pageTitle, !pageTitle.isEmpty {
                outgoing.savedTitle = pageTitle
            }
            // Same private-tab snapshot guard as in `TabSnapshots`.
            if !outgoing.isPrivate {
                Task { @MainActor in
                    await outgoing.captureSnapshot()
                }
            }
        }

        // If requesting a blank REGULAR tab, reuse an existing blank
        // regular tab instead of creating another. Private tabs always
        // get a fresh view-model — reusing one would leak state from
        // the previous private session into a "new" private tab.
        //
        // Truly-blank means BOTH the live WebView state AND the
        // savedURL mirror are empty/about:blank. iOS WKWebView fires
        // a transient `about:blank` KVO when a backgrounded tab's
        // engine is torn down, so reading `state.url` alone would
        // misclassify a real loaded background tab as "blank" — and
        // then reuse it, clobbering its content with the user's
        // next-typed URL. (Reproduces with the qa-tab-count flow:
        // open tab A → load X → background it → open new tab → the
        // dedup loop "found" A as blank and the next navigation
        // overwrote X.)
        if url == nil && !isPrivate {
            for tab in tabs {
                if tab.isPrivate { continue }
                let liveBlank = tab.state.url == nil || tab.state.url?.absoluteString == "about:blank"
                let savedBlank = tab.savedURL.isEmpty || tab.savedURL == "about:blank"
                if liveBlank && savedBlank {
                    tab.shouldFocusURLBar = true
                    self.selectedTab = tab.id
                    logTabs()
                    return
                }
            }
        }

        let info = PageInfo(url: url)
        let vm = newViewModel(info, isPrivate: isPrivate)
        // Newly-created blank tabs auto-focus the URL bar so the user
        // can begin typing immediately. URL-having tabs don't, because
        // they have a real page to load.
        if url == nil {
            vm.shouldFocusURLBar = true
        }
        // Defensive guard against duplicate IDs. The persistent store's
        // `saveItems` should always hand us a fresh row, but if it
        // silently returns the same id twice (db error, race), the
        // `ForEach($tabs)` driving the TabView's Compose Pager crashes
        // with `Key "N" was already used`. Focus the duplicate instead
        // of appending a second copy.
        if let existing = self.tabs.first(where: { $0.id == vm.id }) {
            logger.warning("newTabAction: store returned an in-use id \(vm.id); focusing existing tab instead of appending duplicate")
            existing.shouldFocusURLBar = vm.shouldFocusURLBar
            self.selectedTab = existing.id
            logTabs()
            return
        }
        self.tabs.append(vm)
        if !inBackground || url == nil {
            self.selectedTab = vm.id
        }
        logTabs()
    }

    func closeTabAction() {
        logger.info("closeTabAction")
        hapticFeedback()
        closeTabs([self.selectedTab])
    }

    func closeTabs(_ ids: Set<PageInfo.ID>) {
        // Capture each closing tab's URL before we remove it so the user
        // can reopen via the "Reopen Closed Tab" menu item. Blank tabs
        // and about:blank don't go onto the stack — there's nothing
        // to restore.
        for id in ids {
            if let tab = tabs.first(where: { $0.id == id }) {
                // Skip private tabs entirely — re-opening a closed
                // private tab as a regular tab would leak the URL
                // out of the ephemeral session.
                if tab.isPrivate {
                    removeTabSnapshot(tabId: id)
                    continue
                }
                var url = tab.state.url?.absoluteString ?? ""
                if url.isEmpty {
                    url = tab.savedURL
                }
                if url.isEmpty {
                    let lookupIDs: Set<PageInfo.ID> = [id]
                    if let storedPage = trying(operation: { try store.loadItems(type: PageInfo.PageType.active, ids: lookupIDs) })?.first,
                       let storedURL = storedPage.url {
                        url = storedURL
                    }
                }
                if !url.isEmpty, url != "about:blank" {
                    recentlyClosedTabURLs.insert(url, at: 0)
                    if recentlyClosedTabURLs.count > Self.recentlyClosedTabsLimit {
                        recentlyClosedTabURLs.removeLast()
                    }
                }
            }
            removeTabSnapshot(tabId: id)
        }
        withAnimation {
            // Compute the subset of closing IDs that actually exist
            // in the persistent store before mutating `tabs` — private
            // tabs were never written there and their negative
            // ephemeral IDs must not be sent to `removeItems`.
            var persistedIDs: Set<PageInfo.ID> = []
            for id in ids {
                if let tab = self.tabs.first(where: { $0.id == id }), !tab.isPrivate {
                    persistedIDs.insert(id)
                }
            }
            self.tabs.removeAll(where: { ids.contains($0.id) })
            if !persistedIDs.isEmpty {
                try? store.removeItems(type: .active, ids: persistedIDs)
            }
            self.selectedTab = self.tabs.last?.id ?? self.selectedTab

            // Always leave behind a single tab.
            if self.tabs.isEmpty {
                newTabAction()
            }
        }
        logTabs()
    }

    func reopenClosedTabAction() {
        guard !recentlyClosedTabURLs.isEmpty else { return }
        let url = recentlyClosedTabURLs.removeFirst()
        logger.info("reopenClosedTabAction: \(url)")
        hapticFeedback()
        newTabAction(url: url)
    }

    /// Pop the recently-closed entry at a specific index and reopen
    /// it. Used by the inline quick-reopen items below the standard
    /// "Reopen Closed Tab" entry so the user can pick any item from
    /// the stack without first popping (and then having to undo) all
    /// the ones above it.
    func reopenRecentlyClosedTab(at index: Int) {
        guard index >= 0 && index < recentlyClosedTabURLs.count else { return }
        let url = recentlyClosedTabURLs.remove(at: index)
        logger.info("reopenRecentlyClosedTab idx=\(index) url=\(url)")
        hapticFeedback()
        newTabAction(url: url)
    }

    func closeAllTabsAction() {
        logger.info("closeAllTabsAction")
        hapticFeedback()
        confirmCloseAllTabs = true
    }

    /// Opens a fresh tab pointing at the current tab's URL. Honours the
    /// "Open Links in Background" setting so power users who keep that
    /// flipped on don't lose their place when forking a tab.
    func duplicateTabAction() {
        logger.info("duplicateTabAction url=\(self.currentURL ?? "nil")")
        guard let url = self.currentURL else { return }
        hapticFeedback()
        newTabAction(url: url, inBackground: settings.openLinksInBackground)
    }

    /// Re-orders the `tabs` array alphabetically by each tab's host.
    /// Resolves each tab's URL through the same three-level fallback
    /// `closeTabs` uses (live page URL → savedURL mirror → persistent
    /// store) so iOS-backgrounded tabs whose WebView state has been
    /// reset still sort where they belong. Stable enough that two tabs
    /// on the same host keep their existing relative order.
    func sortTabsByDomainAction() {
        logger.info("sortTabsByDomainAction count=\(self.tabs.count)")
        hapticFeedback()
        var domainByID: [PageInfo.ID: String] = [:]
        for tab in tabs {
            var url = tab.state.url?.absoluteString ?? ""
            if url.isEmpty {
                url = tab.savedURL
            }
            if url.isEmpty {
                if let storedPage = trying(operation: { try store.loadItems(type: .active, ids: [tab.id]) })?.first,
                   let storedURL = storedPage.url {
                    url = storedURL
                }
            }
            domainByID[tab.id] = tabDomainFromURL(url).lowercased()
        }
        withAnimation {
            self.tabs.sort(by: { lhs, rhs in
                let lDom = domainByID[lhs.id] ?? ""
                let rDom = domainByID[rhs.id] ?? ""
                if lDom == rDom {
                    return false
                }
                return lDom < rDom
            })
        }
    }

    /// Fires `navigator.reload()` on every open tab. Useful after the
    /// network reconnects, a sign-in state changes, or a remote-config
    /// updates.
    func reloadAllTabsAction() {
        logger.info("reloadAllTabsAction count=\(self.tabs.count)")
        hapticFeedback()
        for tab in self.tabs {
            tab.navigator.reload()
        }
    }

    /// Closes every tab except the currently selected one — the classic
    /// "tidy up" shortcut after research sessions leave a dozen
    /// background tabs behind. Pinned tabs are spared.
    func closeOtherTabsAction() {
        logger.info("closeOtherTabsAction count=\(self.tabs.count) selected=\(self.selectedTab)")
        hapticFeedback()
        var otherIDs: Set<PageInfo.ID> = []
        for tab in self.tabs {
            if tab.id == self.selectedTab { continue }
            if tab.isPinned { continue }
            otherIDs.insert(tab.id)
        }
        guard !otherIDs.isEmpty else { return }
        closeTabs(otherIDs)
    }

    func performCloseAllTabs() {
        logger.info("performCloseAllTabs count=\(self.tabs.count)")
        var allIDs: Set<PageInfo.ID> = []
        for tab in self.tabs {
            if tab.isPinned { continue }
            allIDs.insert(tab.id)
        }
        guard !allIDs.isEmpty else { return }
        closeTabs(allIDs)
    }

    func newPrivateTabAction() {
        logger.info("newPrivateTabAction")
        newTabAction(isPrivate: true)
    }

    func tabListAction() {
        logger.info("tabListAction")
        hapticFeedback()
        captureAllTabSnapshots()
        // Each opening of the tab overview starts with no filter
        // applied. Leaving stale search text would hide most tabs when
        // the user re-enters the sheet expecting to see everything.
        self.tabSearchText = ""
        self.presentedSheet = .activeTabs
    }
}

#endif
