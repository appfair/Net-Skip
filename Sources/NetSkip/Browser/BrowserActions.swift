// SPDX-License-Identifier: GPL-2.0-or-later
//
// Top-level actions invoked by the toolbar and menus — navigation
// (back/forward/reload/home), favorites toggle, history/favorites/
// downloads/settings sheet presentation, clipboard, external
// browser hand-off, paste & go, desktop site toggle.
//
// Also the current-tab accessors (`currentViewModel`, `currentURL`,
// etc.) that nearly every action reads through.

import SwiftUI
#if !SKIP
import UIKit
#endif
import SkipWeb
import NetSkipModel

#if SKIP || os(iOS)

extension BrowserTabView {
    // MARK: - Current-tab accessors

    var currentViewModel: BrowserViewModel? {
        tabs.first(where: { $0.id == self.selectedTab })
            ?? tabs.last
    }

    var currentState: WebViewState? {
        currentViewModel?.state
    }

    var currentNavigator: WebViewNavigator? {
        currentViewModel?.navigator
    }

    var currentWebView: PlatformWebView? {
        currentNavigator?.webEngine?.webView
    }

    var currentURL: String? {
        if let url = currentState?.url {
            return url.absoluteString
        }
        if let url = currentWebView?.url {
            #if SKIP
            return url
            #else
            return url.absoluteString
            #endif
        }
        return nil
    }

    // MARK: - Navigation

    #if !SKIP
    func openURLAction(newTab: Bool) -> OpenURLAction {
        OpenURLAction(handler: { url in
            openURL(url: url.absoluteString, newTab: newTab)
            // TODO: reject unsupported URLs
            return OpenURLAction.Result.handled
        })
    }
    #endif

    func openURL(url: String, newTab: Bool) {
        logger.log("openURL: \(url) newTab=\(newTab)")
        var newURL = url
        // if the scheme netskip:// then change it to https://
        if url.hasPrefix("netskip://") {
            newURL = url.replacingOccurrences(of: "netskip://", with: "https://")
        }
        // Spawn a fresh tab when the caller asked for one or there's
        // no current tab to navigate. `newTabAction(url:)` loads the
        // page into the newly-selected tab, so we're done.
        if self.currentViewModel == nil || newTab == true {
            newTabAction(url: newURL)
            return
        }
        if let navURL = URL(string: newURL) {
            currentNavigator?.load(url: navURL)
        }
    }

    func hapticFeedback() {
        #if !SKIP
        if settings.buttonHaptics {
            triggerImpact.toggle()
        }
        #endif
    }

    func homeAction() {
        logger.info("homeAction")
        hapticFeedback()
        if let homeURL = homeURL {
            currentNavigator?.load(url: homeURL)
        }
    }

    func backAction() {
        logger.info("backAction")
        hapticFeedback()
        currentNavigator?.goBack()
    }

    func forwardAction() {
        logger.info("forwardAction")
        hapticFeedback()
        currentNavigator?.goForward()
    }

    func reloadAction() {
        logger.info("reloadAction")
        hapticFeedback()
        currentNavigator?.reload()
    }

    // MARK: - Favorites

    func favoriteAction() {
        logger.info("favoriteAction isCurrentPageFavorited=\(isCurrentPageFavorited)")
        hapticFeedback()
        guard let url = self.currentURL else { return }
        if isCurrentPageFavorited {
            if let favorites = trying(operation: { try store.loadItems(type: .favorite, ids: []) }),
               let match = favorites.first(where: { $0.url == url }) {
                logger.info("removePageFromFavorite: \(url)")
                trying { try store.removeItems(type: .favorite, ids: [match.id]) }
            }
        } else {
            logger.info("addPageToFavorite: \(url)")
            trying {
                _ = try store.saveItems(type: .favorite, items: [PageInfo(url: url, title: currentState?.pageTitle ?? currentWebView?.title)])
            }
        }
        refreshFavoritedStatus()
    }

    /// Recompute whether the current page is in the favorites store.
    /// Called when the URL changes, when the menu opens, and right
    /// after the user toggles via `favoriteAction()` so the menu
    /// label flips without waiting for the next render trigger.
    func refreshFavoritedStatus() {
        guard let url = self.currentURL else {
            isCurrentPageFavorited = false
            return
        }
        let favorites = trying(operation: { try store.loadItems(type: .favorite, ids: []) }) ?? []
        isCurrentPageFavorited = favorites.contains(where: { $0.url == url })
    }

    // MARK: - Sheet present actions

    func historyAction() {
        logger.info("historyAction")
        hapticFeedback()
        presentedSheet = .history
    }

    func favoritesAction() {
        logger.info("favoritesAction")
        hapticFeedback()
        presentedSheet = .favorites
    }

    func settingsAction() {
        logger.info("settingsAction")
        hapticFeedback()
        presentedSheet = .settings
    }

    func downloadsAction() {
        logger.info("downloadsAction")
        hapticFeedback()
        presentedSheet = .downloads
    }

    // MARK: - Page actions

    /// Clears every tab's web cache (disk + memory + offline
    /// application cache) but explicitly leaves cookies and local
    /// storage intact so the user remains signed in everywhere they
    /// were. iOS / Android share their data stores across `WKWebView`
    /// / `WebView` instances, so dispatching the removal on each
    /// tab's engine guarantees the platform store is touched at
    /// least once.
    func clearWebCacheAction() {
        logger.info("clearWebCacheAction")
        hapticFeedback()
        let cacheTypes: Set<WebSiteDataType> = [.diskCache, .memoryCache, .offlineWebApplicationCache]
        for tab in self.tabs {
            if let engine = tab.navigator.webEngine {
                Task {
                    do {
                        try await engine.removeData(ofTypes: cacheTypes, modifiedSince: .distantPast)
                    } catch {
                        logger.warning("clearWebCacheAction: failed to clear cache: \(error)")
                    }
                }
            }
        }
    }

    func copyURLAction() {
        guard let url = currentState?.url else { return }
        let pageURL = url.absoluteString
        logger.info("copyURLAction: \(pageURL)")
        hapticFeedback()
        #if SKIP
        let ctx = ProcessInfo.processInfo.androidContext
        let cm = ctx.getSystemService(android.content.Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
        cm.setPrimaryClip(android.content.ClipData.newPlainText("URL", pageURL))
        #else
        UIPasteboard.general.string = pageURL
        #endif
    }

    /// Hand the current page URL to Google Translate so the user can
    /// read it in their preferred language. Uses Google Translate's
    /// public website-translation endpoint, which loads through any
    /// modern user agent without account requirements. Falls back
    /// gracefully (no-op) when there's no live page URL.
    func translatePageAction() {
        guard let url = currentState?.url,
              let encoded = url.absoluteString.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed) else { return }
        let pageURL = url.absoluteString
        logger.info("translatePageAction: \(pageURL)")
        hapticFeedback()
        // `op=websites` is the modern Google Translate URL contract
        // for translating an entire site; `tl=auto` lets Translate
        // pick the user's locale automatically.
        let translateURL = "https://translate.google.com/?sl=auto&tl=auto&op=websites&u=\(encoded)"
        openURL(url: translateURL, newTab: false)
    }

    /// Hands the current page URL to the system's default browser —
    /// the escape hatch when a site doesn't render in this WebView.
    /// On iOS this lands in Safari (or whatever the user set as their
    /// default browser). On Android we filter our own package out of
    /// the chooser so the user isn't offered a redundant self-entry.
    func openInExternalBrowserAction() {
        guard let url = currentState?.url else { return }
        let pageURL = url.absoluteString
        logger.info("openInExternalBrowserAction: \(pageURL)")
        hapticFeedback()
        #if SKIP
        let ctx = ProcessInfo.processInfo.androidContext
        let selfPackage = ctx.packageName
        let baseIntent = android.content.Intent(android.content.Intent.ACTION_VIEW, android.net.Uri.parse(pageURL))
        let pm = ctx.packageManager
        let resolveInfos = pm.queryIntentActivities(baseIntent, 0)
        // Build one explicit Intent per non-self handler so the
        // chooser shows only third-party browsers. If we're the only
        // handler installed, fall back to launching the base intent.
        var targeted: [android.content.Intent] = []
        for info in resolveInfos {
            let pkg = info.activityInfo.packageName
            if pkg == selfPackage { continue }
            let explicit = android.content.Intent(android.content.Intent.ACTION_VIEW, android.net.Uri.parse(pageURL))
            explicit.setPackage(pkg)
            targeted.append(explicit)
        }
        if targeted.isEmpty {
            baseIntent.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
            ctx.startActivity(baseIntent)
        } else if targeted.count == 1 {
            let only = targeted[0]
            only.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
            ctx.startActivity(only)
        } else {
            let chooser = android.content.Intent.createChooser(baseIntent, "Open in browser")
            chooser.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
            ctx.startActivity(chooser)
        }
        #else
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
        #endif
    }

    func pasteAndGoAction() {
        logger.info("pasteAndGoAction")
        hapticFeedback()
        let clipboardText: String?
        #if SKIP
        let ctx = ProcessInfo.processInfo.androidContext
        let cm = ctx.getSystemService(android.content.Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
        if let clip = cm.primaryClip, clip.itemCount > 0 {
            clipboardText = clip.getItemAt(0).coerceToText(ctx)?.toString()
        } else {
            clipboardText = nil
        }
        #else
        clipboardText = UIPasteboard.general.string
        #endif
        guard let text = clipboardText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            logger.info("pasteAndGoAction: clipboard empty")
            return
        }
        // Reuse the URL bar's submit pipeline so the same heuristic
        // (URL vs search query) applies as if the user had typed it.
        submitURL(text: text)
    }

    func toggleDesktopSiteAction() {
        logger.info("toggleDesktopSiteAction: \(!settings.requestDesktopSite)")
        hapticFeedback()
        settings.requestDesktopSite.toggle()
        currentNavigator?.reload()
    }
}

#endif
