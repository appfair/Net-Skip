// SPDX-License-Identifier: GPL-2.0-or-later
//
// The five-item bottom chrome (back / forward / tabs / new tab /
// more). Each icon sits in a 44pt square hit-target so different
// glyph aspect ratios don't render at visually different sizes.

import SwiftUI
#if !SKIP
import UIKit
#endif
import SkipWeb

#if SKIP || os(iOS)

extension BrowserTabView {
    var toolbarPlacement: ToolbarItemPlacement {
        #if os(macOS)
        let toolbarPlacement = ToolbarItemPlacement.automatic
        #else
        let toolbarPlacement = ToolbarItemPlacement.bottomBar
        #endif
        return toolbarPlacement
    }

    /// Bottom toolbar rendered as a manual HStack so the chrome can
    /// sit directly under the URL bar (which lives inside
    /// `BrowserView`'s own VStack) and disappear in tandem with it.
    /// Collapses to zero height when `showBottomBar` is off so the URL
    /// bar's compact slim mode is the only thing left visible.
    @ViewBuilder func bottomToolbar() -> some View {
        // Five-item bottom toolbar: back, forward, tab list, new tab,
        // "..." more menu. Share lives in the more-menu now.
        let isPrivateChrome = currentViewModel?.isPrivate == true
        HStack(spacing: 0) {
            backButton()
                .frame(width: toolbarItemSize, height: toolbarItemSize)
            Spacer()
            forwardButton()
                .frame(width: toolbarItemSize, height: toolbarItemSize)
            Spacer()
            tabsButton()
                .frame(width: toolbarItemSize, height: toolbarItemSize)
            Spacer()
            newTabToolbarButton()
                .frame(width: toolbarItemSize, height: toolbarItemSize)
            Spacer()
            ellipsisMenu()
                .frame(width: toolbarItemSize, height: toolbarItemSize)
        }
        .labelStyle(.iconOnly)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(urlBarBackground(for: colorScheme, isPrivate: isPrivateChrome))
        // Stable accessibility hook for Maestro: render a 1pt
        // sentinel overlay carrying `chrome.private` (or `.regular`)
        // when the chrome's private state changes. Avoids putting
        // the identifier on the toolbar HStack, which on iOS
        // shadows the child Button accessibility IDs and breaks
        // `tapOn: id: button.menu`. Sentinel sits behind the
        // toolbar at top-leading so it never intercepts taps.
        .overlay(alignment: .topLeading) {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityIdentifier(isPrivateChrome ? "chrome.private" : "chrome.regular")
                .allowsHitTesting(false)
        }
        // Fixed height when shown; collapses to 0 when the user
        // scrolls down. SwiftUI's natural-sized `nil` height doesn't
        // transpile cleanly to Compose, and `.infinity` greedily eats
        // the WebView's space on iOS.
        .frame(height: showBottomBar ? Self.bottomToolbarHeight : 0.0)
        .opacity(showBottomBar ? 1.0 : 0.0)
        .clipped()
    }

    @ViewBuilder func backButton() -> some View {
        let enabled = currentState?.canGoBack == true
        let backLabel = Label {
            Text("Back", bundle: .module, comment: "back button label")
        } icon: {
            Image("arrow_back_ios_new", bundle: .module)
                .font(.system(size: toolbarIconSize))
        }

        // Tap fires the `primaryAction` (single-step back) on both
        // platforms; long-press opens the back-history menu so the
        // user can jump multiple steps.
        if !enabled {
            Button {
                backAction()
            } label: {
                backLabel
            }
            .disabled(true)
            .accessibilityIdentifier("button.back")
        } else {
            Menu {
                backHistoryMenu()
            } label: {
                backLabel
            } primaryAction: {
                backAction()
            }
            .accessibilityIdentifier("button.back")
        }
    }

    @ViewBuilder func forwardButton() -> some View {
        let enabled = currentState?.canGoForward == true
        let forwardLabel = Label {
            Text("Forward", bundle: .module, comment: "forward button label")
        } icon: {
            Image("arrow_forward_ios", bundle: .module)
                .font(.system(size: toolbarIconSize))
        }

        if !enabled {
            Button {
                forwardAction()
            } label: {
                forwardLabel
            }
            .disabled(true)
            .accessibilityIdentifier("button.forward")
        } else {
            Menu {
                forwardHistoryMenu()
            } label: {
                forwardLabel
            } primaryAction: {
                forwardAction()
            }
            .accessibilityIdentifier("button.forward")
        }
    }

    /// Top-level toolbar "new tab" button. A short tap opens a fresh
    /// regular blank tab (the existing behaviour); long-press surfaces
    /// a small Menu with "New Tab" and "New Private Tab" so power
    /// users can spawn a private tab without going through the
    /// More-menu. Same `Menu { ... } primaryAction:` pattern as the
    /// long-pressable forward button above.
    @ViewBuilder func newTabToolbarButton() -> some View {
        Menu {
            Button(action: { newTabAction() }) {
                Label {
                    Text("New Tab", bundle: .module, comment: "long-press menu label for opening a new blank regular tab from the toolbar + button")
                } icon: {
                    Image("add_2", bundle: .module)
                }
            }
            .accessibilityIdentifier("menu.newTabToolbar.newTab")

            Button(action: { newPrivateTabAction() }) {
                Label {
                    Text("New Private Tab", bundle: .module, comment: "long-press menu label for opening a new private (ephemeral) tab from the toolbar + button")
                } icon: {
                    Image("lock", bundle: .module)
                }
            }
            .accessibilityIdentifier("menu.newTabToolbar.newPrivateTab")
        } label: {
            Label {
                Text("New Tab", bundle: .module, comment: "toolbar button label for opening a new blank tab")
            } icon: {
                Image("add_2", bundle: .module)
                    .font(.system(size: toolbarIconSize))
            }
        } primaryAction: {
            newTabAction()
        }
        // Match Android's top-down menu order — see the matching
        // comment on `tabsButton()` above.
        .menuOrder(.fixed)
        .accessibilityIdentifier("button.newTab")
        .accessibilityLabel(Text("New Tab", bundle: .module, comment: "accessibility label for the toolbar new-tab button"))
    }

    /// Share button — kept around for callers (favicon menu and any
    /// future surface) that want a ShareLink wrapped in a labelled
    /// view. Not currently placed on the bottom toolbar.
    @ViewBuilder func shareToolbarButton() -> some View {
        let url = currentState?.url?.absoluteString ?? ""
        let canShare = !url.isEmpty && url != "about:blank"
        ShareLink(item: canShare ? url : fallbackURL) {
            Label {
                Text("Share", bundle: .module, comment: "toolbar share button label")
            } icon: {
                Image("ios_share", bundle: .module)
                    .font(.system(size: toolbarIconSize))
            }
        }
        .disabled(!canShare)
        .accessibilityIdentifier("button.share")
        .accessibilityLabel(Text("Share page", bundle: .module, comment: "accessibility label for the toolbar share button"))
    }

    @ViewBuilder func tabsButton() -> some View {
        Menu {
            Button(action: { newTabAction() }) {
                Label {
                    Text("New Tab", bundle: .module, comment: "new tab button label")
                } icon: {
                    Image("plus", bundle: .module)
                }
            }
            .accessibilityIdentifier("menu.newTab")

            Button(action: { newPrivateTabAction() }) {
                Label {
                    Text("New Private Tab", bundle: .module, comment: "tabs long-press menu label for opening a new private (ephemeral) browser tab")
                } icon: {
                    Image("lock", bundle: .module)
                }
            }
            .accessibilityIdentifier("menu.newPrivateTab")

            Button(action: duplicateTabAction) {
                Label {
                    Text("Duplicate Tab", bundle: .module, comment: "menu label that opens a new tab pointing at the same URL as the current tab")
                } icon: {
                    Image("plus.square.on.square", bundle: .module)
                }
            }
            .accessibilityIdentifier("menu.duplicateTab")
            .disabled(currentURL == nil)

            Button(action: closeTabAction) {
                Label {
                    Text("Close Tab", bundle: .module, comment: "close tab button label")
                } icon: {
                    Image("xmark", bundle: .module)
                }
            }
            .accessibilityIdentifier("menu.closeTab")

            Button(action: reopenClosedTabAction) {
                Label {
                    Text("Reopen Closed Tab", bundle: .module, comment: "menu label to restore the most recently closed tab")
                } icon: {
                    Image("arrow.clockwise", bundle: .module)
                }
            }
            .accessibilityIdentifier("menu.reopenClosedTab")
            .disabled(recentlyClosedTabURLs.isEmpty)

            // Up to four older recently-closed tabs surfaced as
            // individual quick-reopen items. The first entry is what
            // `reopenClosedTabAction` above pops; these rows offer
            // single-tap access to the rest of the stack.
            ForEach(0..<min(4, max(0, recentlyClosedTabURLs.count - 1)), id: \.self) { offset in
                let entryIndex = offset + 1
                let entryURL = recentlyClosedTabURLs[entryIndex]
                Button(action: { reopenRecentlyClosedTab(at: entryIndex) }) {
                    Label {
                        Text(verbatim: tabDomainFromURL(entryURL))
                    } icon: {
                        Image("arrow.clockwise", bundle: .module)
                    }
                }
                .accessibilityIdentifier("menu.reopenClosedTab.\(entryIndex)")
            }

            Button(action: reloadAllTabsAction) {
                Label {
                    Text("Reload All Tabs", bundle: .module, comment: "menu label that triggers a reload on every open tab at once")
                } icon: {
                    Image("arrow.clockwise", bundle: .module)
                }
            }
            .accessibilityIdentifier("menu.reloadAllTabs")
            .disabled(tabs.isEmpty)

            Button(action: sortTabsByDomainAction) {
                Label {
                    Text("Sort Tabs by Domain", bundle: .module, comment: "menu label that re-orders every open tab alphabetically by its host name — the modern Tab Manager tidy-up action")
                } icon: {
                    Image("sort_by_alpha", bundle: .module)
                }
            }
            .accessibilityIdentifier("menu.sortTabsByDomain")
            .disabled(tabs.count < 2)

            Button(role: .destructive, action: closeOtherTabsAction) {
                Label {
                    Text("Close Other Tabs", bundle: .module, comment: "menu label to close every open tab except the currently selected one")
                } icon: {
                    Image("delete_sweep", bundle: .module)
                }
            }
            .accessibilityIdentifier("menu.closeOtherTabs")
            .disabled(tabs.count <= 1)

            Button(role: .destructive, action: closeAllTabsAction) {
                Label {
                    Text("Close All Tabs", bundle: .module, comment: "menu label to close every open tab")
                } icon: {
                    Image("delete_sweep", bundle: .module)
                }
            }
            .accessibilityIdentifier("menu.closeAllTabs")
            .disabled(tabs.count <= 1)
        } label: {
            Label {
                Text("Tabs", bundle: .module, comment: "tabs button label")
            } icon: {
                tabCountIcon()
                    .font(.system(size: toolbarIconSize))
            }
        } primaryAction: {
            tabListAction()
        }
        // iOS' default Menu order ("priority") reverses items in
        // popovers that expand upward from a bottom toolbar, so on
        // iOS the same code that reads "New Tab → New Private Tab →
        // Duplicate Tab → …" top-to-bottom on Android would render
        // "Close All Tabs → Close Other Tabs → … → New Tab" — exact
        // inverse. `.menuOrder(.fixed)` pins iOS to declaration order
        // so both platforms agree.
        .menuOrder(.fixed)
        .accessibilityIdentifier("button.tabs")
    }

    @ViewBuilder func tabCountIcon() -> some View {
        #if !SKIP
        // iOS: Label icons in toolbars require a static Image, not a
        // dynamic view. Pre-render the tab count badge to a UIImage
        // via ImageRenderer and cache it.
        let img = Self.renderedTabCountImage(for: tabs.count)
        Image(uiImage: img)
            .renderingMode(.template)
        #else
        // Android/Skip: dynamic views work fine as toolbar icons.
        let display = tabs.count >= 100 ? "99+" : "\(tabs.count)"
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(lineWidth: 2.0)
                .frame(width: 28, height: 28)
            Text(verbatim: display)
                .font(.system(size: tabs.count >= 100 ? 11.0 : 14.0, weight: .bold))
        }
        #endif
    }

    #if !SKIP
    /// Cache of pre-rendered tab-count badge images keyed by count.
    private static var tabCountImageCache: [Int: UIImage] = [:]

    /// Returns a cached UIImage for the given tab count, rendering it
    /// if needed. For tab counts ≥ 100 the three-digit string blows
    /// out of the 28×28 badge; modern browsers show "99+" instead.
    static func renderedTabCountImage(for count: Int) -> UIImage {
        if let cached = tabCountImageCache[count] {
            return cached
        }
        let display = count >= 100 ? "99+" : "\(count)"
        let badge = ZStack {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(lineWidth: 2.0)
                .frame(width: 28, height: 28)
            Text(verbatim: display)
                .font(.system(size: count >= 100 ? 11.0 : 14.0, weight: .bold))
        }
        .foregroundStyle(Color.primary)

        let renderer = ImageRenderer(content: badge)
        renderer.scale = UIScreen.main.scale
        let image = renderer.uiImage ?? UIImage()
        tabCountImageCache[count] = image
        return image
    }
    #endif
}

#endif
