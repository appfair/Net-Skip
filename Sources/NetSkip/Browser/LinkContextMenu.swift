// SPDX-License-Identifier: GPL-2.0-or-later
//
// Per-link long-press menu (Open / Open in New Tab / Add Bookmark /
// Copy Link / Download Link / Share). Installed on the shared
// `WebEngineConfiguration` so both WKWebView (iOS) and Android's
// `WebView` long-press path surface the same six items.

import SwiftUI
#if !SKIP && canImport(UIKit)
import UIKit
#endif
import SkipWeb
import NetSkipModel

#if SKIP || os(iOS)

extension BrowserTabView {
    /// Hand skip-web a builder for the six-item link long-press menu.
    /// The same list is rendered as native `UIAction`s inside the
    /// WKWebView preview menu on iOS and as native `PopupMenu` items
    /// on Android — see `WebEngineConfiguration.linkContextMenuActions`.
    /// Static so it can run from `init` before `self` is fully formed;
    /// takes the configuration + store as parameters and stashes the
    /// per-action handlers as standalone closures.
    static func installLinkContextMenuActions(on configuration: WebEngineConfiguration, store: WebBrowserStore) {
        configuration.linkContextMenuActions = { url in
            logger.info("linkContextMenuActions provider invoked for url=\(url)")
            return [
                WebContextMenuAction(title: NSLocalizedString("Open", bundle: .module, comment: "link long-press menu: open the URL in the current tab")) { url in
                    NotificationCenter.default.post(name: Self.openLinkNotification, object: nil, userInfo: ["url": url, "newTab": false])
                },
                WebContextMenuAction(title: NSLocalizedString("Open in New Tab", bundle: .module, comment: "link long-press menu: open the URL in a new tab")) { url in
                    NotificationCenter.default.post(name: Self.openLinkNotification, object: nil, userInfo: ["url": url, "newTab": true])
                },
                WebContextMenuAction(title: NSLocalizedString("Add Bookmark", bundle: .module, comment: "link long-press menu: bookmark the URL")) { url in
                    Self.addLinkAsBookmark(url, store: store)
                },
                WebContextMenuAction(title: NSLocalizedString("Copy Link", bundle: .module, comment: "link long-press menu: copy the URL to the clipboard")) { url in
                    Self.copyLinkToClipboard(url)
                },
                WebContextMenuAction(title: NSLocalizedString("Download Link", bundle: .module, comment: "link long-press menu: download the URL")) { url in
                    Self.requestLinkDownload(url)
                },
                WebContextMenuAction(title: NSLocalizedString("Share…", bundle: .module, comment: "link long-press menu: open the share sheet for the URL")) { url in
                    Self.shareLink(url)
                },
            ]
        }
    }

    /// Notification dispatched by the link context menu's Open /
    /// Open in New Tab handlers so the still-being-built
    /// `BrowserTabView` instance (the one rendering the WebView) can
    /// react via `onReceive`. `userInfo`: `url: URL`, `newTab: Bool`.
    static var openLinkNotification: Notification.Name {
        return Notification.Name("linkContextOpenRequested")
    }

    static func addLinkAsBookmark(_ url: URL, store: WebBrowserStore) {
        let urlString = url.absoluteString
        guard !urlString.isEmpty else { return }
        let favorites = (try? store.loadItems(type: .favorite, ids: [])) ?? []
        if favorites.contains(where: { $0.url == urlString }) { return }
        _ = try? store.saveItems(type: .favorite, items: [PageInfo(url: urlString, title: nil)])
    }

    static func copyLinkToClipboard(_ url: URL) {
        #if SKIP
        let ctx = ProcessInfo.processInfo.androidContext
        let cm = ctx.getSystemService(android.content.Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
        cm.setPrimaryClip(android.content.ClipData.newPlainText("URL", url.absoluteString))
        #else
        UIPasteboard.general.url = url
        #endif
    }

    static func requestLinkDownload(_ url: URL) {
        let request = WebDownloadRequest(url: url, suggestedFilename: url.lastPathComponent)
        DownloadManager.shared.enqueue(request)
    }

    static func shareLink(_ url: URL) {
        #if SKIP
        let ctx = ProcessInfo.processInfo.androidContext
        let intent = android.content.Intent(android.content.Intent.ACTION_SEND)
        intent.setType("text/plain")
        intent.putExtra(android.content.Intent.EXTRA_TEXT, url.absoluteString)
        let chooser = android.content.Intent.createChooser(intent, nil)
        chooser.setFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
        ctx.startActivity(chooser)
        #else
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        let scenes = UIApplication.shared.connectedScenes
        let windowScene = scenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
        let rootVC = windowScene?.keyWindow?.rootViewController
        var presenter: UIViewController? = rootVC
        while let presented = presenter?.presentedViewController {
            presenter = presented
        }
        presenter?.present(activity, animated: true)
        #endif
    }
}

#endif
