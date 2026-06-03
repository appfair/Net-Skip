// SPDX-License-Identifier: GPL-2.0-or-later
//
// The "..." more-menu and the back/forward history submenus. The
// more menu only carries non-page-specific actions (Home, Paste &
// Go, Bookmarks, History, Downloads, Settings) — page-specific
// actions live in the favicon menu in the URL bar.

import SwiftUI
import SkipWeb

#if SKIP || os(iOS)

extension BrowserTabView {
    @ViewBuilder func ellipsisMenu() -> some View {
        // Global navigation + app-level actions only. Page-specific
        // actions (Find on Page, Share, Copy URL, Add to Favorites,
        // Page Zoom, Desktop/Mobile Site) live in the favicon menu
        // in the URL bar — see `BrowserView.faviconPageMenu`.
        Menu {
            Button(action: homeAction) {
                Label {
                    Text("Home", bundle: .module, comment: "home button label")
                } icon: {
                    Image("house", bundle: .module)
                }
            }
            .accessibilityIdentifier("menu.home")

            Button(action: pasteAndGoAction) {
                Label {
                    Text("Paste and Go", bundle: .module, comment: "menu label for pasting the clipboard contents into the URL bar and navigating to that page")
                } icon: {
                    Image("content_paste", bundle: .module)
                }
            }
            .accessibilityIdentifier("menu.pasteAndGo")

            Divider()

            Button(action: favoritesAction) {
                Label {
                    Text("Bookmarks", bundle: .module, comment: "bookmarks menu label")
                } icon: {
                    Image("book", bundle: .module)
                }
            }
            .accessibilityIdentifier("menu.bookmarks")

            Button(action: historyAction) {
                Label {
                    Text("History", bundle: .module, comment: "history menu label")
                } icon: {
                    Image("history", bundle: .module)
                }
            }
            .accessibilityIdentifier("menu.history")

            Button(action: downloadsAction) {
                Label {
                    Text("Downloads", bundle: .module, comment: "downloads menu label")
                } icon: {
                    Image("download", bundle: .module)
                }
            }
            .accessibilityIdentifier("menu.downloads")

            Divider()

            Button(action: settingsAction) {
                Label {
                    Text("Settings", bundle: .module, comment: "settings button label")
                } icon: {
                    Image("gearshape", bundle: .module)
                }
            }
            .accessibilityIdentifier("menu.settings")
        } label: {
            Label {
                Text("Menu", bundle: .module, comment: "hamburger menu label")
            } icon: {
                // `pending` is the Material Symbol for "horizontal
                // dots inside a circle" — the user explicitly asked
                // for a circle-with-dots affordance for More rather
                // than the bare ellipsis dots.
                Image("pending", bundle: .module)
                    .font(.system(size: toolbarIconSize))
            }
        }
        // Force top-down order so the iOS menu reads the same as
        // Android. Without this, SwiftUI sees the More button sits
        // at the bottom of the screen, opens the menu upward, and
        // reverses items so the "first" sits closest to the
        // button — which on this toolbar means Home prints last.
        #if !SKIP
        .menuOrder(.fixed)
        #endif
        .accessibilityIdentifier("button.menu")
    }

    @ViewBuilder func backHistoryMenu() -> some View {
        ForEach(Array((currentState?.backList ?? []).enumerated()), id: \.0) {
            historyItem(item: $0.1)
        }
    }

    @ViewBuilder func forwardHistoryMenu() -> some View {
        ForEach(Array((currentState?.forwardList ?? []).enumerated()), id: \.0) {
            historyItem(item: $0.1)
        }
    }

    @ViewBuilder func historyItem(item: WebHistoryItem) -> some View {
        Button(item.title?.isEmpty == false ? (item.title ?? "") : item.url) {
            currentViewModel?.navigator.go(item)
        }
        .accessibilityIdentifier("menu.historyItem.\(item.url)")
    }
}

#endif
