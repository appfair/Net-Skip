// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
#if !SKIP
import UIKit
#endif
import SkipWeb
import NetSkipModel
import NetSkipMiniApp

#if SKIP || os(iOS)

/// The root browser surface: a `TabView` of `BrowserView`s with a
/// shared bottom chrome (URL bar + toolbar), find bar, page-zoom bar,
/// and a small set of sheets routed through `presentedSheet`.
///
/// Body composition and per-feature behaviour live in sibling files
/// under `Browser/` — `BrowserTabView.swift` is intentionally thin so
/// the high-level shape stays legible:
///
/// - `TabPersistence.swift` — restore on launch, view-model factory.
/// - `TabActions.swift` — new/close/duplicate/sort/reopen.
/// - `TabSnapshots.swift` — grid-overview pixel capture.
/// - `TabGrid.swift` — the tabs sheet and tab cards.
/// - `BottomToolbar.swift` — back/forward/tabs/new tab/more strip.
/// - `MoreMenu.swift` — the "..." menu's global actions.
/// - `FindBar.swift` / `PageZoomBar.swift` — bottom overlays.
/// - `LinkContextMenu.swift` — the long-press-a-link six-item menu.
/// - `BrowserActions.swift` — navigation, favorites, clipboard, etc.
/// - `URLBarSubmit.swift` — URL-vs-search parsing pipeline.
/// - `HistoryFavoritesSheets.swift` — history & favorites browsers.
@MainActor public struct BrowserTabView : View {
    let configuration: WebEngineConfiguration
    let store: WebBrowserStore

    @State var tabs: [BrowserViewModel] = []
    @State var selectedTab: PageInfo.ID = PageInfo.ID(0)

    /// True when the bottom chrome (URL bar + toolbar) is shown.
    /// Auto-toggled by the WebView's scrolling-down signal so a
    /// scroll-down gesture hands the chrome's pixels back to the page.
    @State var showBottomBar = true

    /// The currently-presented modal sheet, or `nil` for none. Modal
    /// sheets are mutually exclusive — this enum guarantees only one
    /// is ever live, which kept previous `showXxx: Bool` flags from
    /// disagreeing about z-order.
    @State var presentedSheet: PresentedSheet? = nil

    /// The bottom-anchored overlay currently replacing the toolbar:
    /// find-on-page or page-zoom. `nil` keeps the toolbar visible.
    @State var bottomOverlay: BottomOverlay? = nil

    @State var historyFavoriesSelection = 1
    @State var findText = ""
    @State var findMatchCount: Int = 0
    @State var tabSearchText = ""

    /// Trigger for `sensoryFeedback(.impact, ...)`. Toggled by
    /// `hapticFeedback()` so each call produces a single bump.
    @State var triggerImpact = false

    @Environment(BrowserSettings.self) var settings
    @Environment(\.colorScheme) var colorScheme

    /// In-flight per-tab UI state (not a user preference) — keep on
    /// AppStorage so a relaunch reopens the same tab the user left on.
    @AppStorage("selectedTabState") var selectedTabState: String = ""

    @State var tabsSegment: Int = 1 // 1 = Pages, 2 = Apps
    @State var runningMiniApps: Set<String> = [] // IDs of launched miniapps
    @State var activeMiniAppItem: MiniAppLaunchItem? = nil // app storage does not support Int64 (PageInfo.ID), so we serialize it as a string

    /// Stack of recently-closed-tab URLs. Most-recent first. Capped so
    /// the "Reopen Closed Tab" menu doesn't grow unbounded in long
    /// sessions. Per-session only — we explicitly don't persist these
    /// because the user's expectation is that this is undo-style, not
    /// "history".
    @State var recentlyClosedTabURLs: [String] = []
    static let recentlyClosedTabsLimit: Int = 10

    /// Height of the bottom chrome bar (back/tabs/menu/bookmarks/
    /// forward HStack). Shared with `BrowserView` so the URL bar can
    /// pad itself up by exactly this many points and sit flush against
    /// the toolbar.
    static let bottomToolbarHeight: CGFloat = 62.0

    /// Natural height of the URL bar capsule when shown — matches the
    /// 44pt capsule + 4pt top padding inside `urlBarComponentView` so
    /// there's no centered-frame gap on Compose. Collapses to zero on
    /// scroll-down so the WebView occupies the full screen.
    static let urlBarHeight: CGFloat = 62.0

    /// Uniform square hit-target for every bottom-toolbar item.
    /// Without this, glyphs with different intrinsic aspect ratios
    /// would visibly disagree on size, and the row would look ragged.
    let toolbarItemSize: CGFloat = 44.0

    /// Toolbar icon point size — gives a touch-friendly target without
    /// making any one icon dominate.
    let toolbarIconSize: CGFloat = 28.0

    @State var confirmCloseAllTabs: Bool = false
    @State var isCurrentPageFavorited: Bool = false

    /// Mirror of the selected tab's `BrowserViewModel.inReaderMode`
    /// kept on the parent's `@State` so menu re-renders pick up the
    /// flip immediately — class-property mutations on
    /// `BrowserViewModel` do reach the per-tab `BrowserView` (it
    /// holds the view-model as a `@Binding`), but SwiftUI doesn't
    /// propagate those observations back up to the sibling chrome
    /// in this composition. Kept in sync by `toggleReaderModeAction`
    /// and the `currentURL`-change handler.
    @State var isCurrentPageInReaderMode: Bool = false

    public init(configuration: WebEngineConfiguration, store: WebBrowserStore) {
        self.configuration = configuration
        self.store = store
        // Install link context menu actions on the configuration the
        // moment we have a reference to it. `.onAppear` was firing
        // *after* the WebView had already initialized its coordinator
        // with the configuration's current `linkContextMenuActions`
        // value (nil), so the iOS
        // `WKUIDelegate.contextMenuConfigurationForElement` hit the
        // nil branch and fell through to WKWebView's default menu.
        Self.installLinkContextMenuActions(on: configuration, store: store)
    }

    public var body: some View {
        // SkipUI insets the top edge by the system status bar
        // automatically on Android (matching iOS), so no manual
        // safe-area padding is needed here.
        bodyContent
            .onReceive(NotificationCenter.default.publisher(for: Self.openLinkNotification)) { note in
                guard let url = note.userInfo?["url"] as? URL else { return }
                let newTab = (note.userInfo?["newTab"] as? Bool) ?? false
                openURL(url: url.absoluteString, newTab: newTab)
            }
    }

    @ViewBuilder
    private var bodyContent: some View {
        ZStack(alignment: .bottom) {
            // browserTabView fills the entire ZStack; the URL bar
            // lives inside each tab's `BrowserView` as a
            // `.bottom`-aligned overlay so the WebView extends behind
            // it. We lift it by `bottomToolbarHeight` so the URL bar
            // sits flush against the toolbar that we overlay
            // separately below.
            VStack(spacing: 0) {
                browserTabView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // Bottom chrome overlay. When find-on-page or page-zoom
            // is active the matching overlay takes the toolbar's slot
            // at the bottom — the pattern Chrome desktop uses — so
            // the user can see the count and prev/next without
            // anything else competing for the bottom strip. Close
            // button restores the toolbar.
            if let overlay = bottomOverlay {
                switch overlay {
                case .findBar:
                    findBar()
                case .pageZoom:
                    pageZoomBar()
                }
            } else {
                bottomToolbar()
            }
        }
        .background(Color.clear)
        .statusBarHidden(settings.hideStatusBar)
        // Edge-to-edge full-bleed only when the user opts in via
        // Hide Status Bar. `.all` here gives the WebView every edge
        // of the screen; the URL bar / toolbar overlays stay anchored
        // inside the (now ignored) safe area at the bottom.
        .ignoresSafeArea(edges: settings.hideStatusBar ? Edge.Set.all : Edge.Set(rawValue: 0))
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .settings: settingsView()
            case .history: historyPageInfoView()
            case .favorites: favoritesPageInfoView()
            case .historyFavorites: historyFavoritesPageInfoTabView()
            case .activeTabs: activeTabsView()
            case .downloads: DownloadsListView()
            }
        }
        .confirmationDialog(
            Text("Close all \(tabs.count) tabs?",
                 bundle: .module,
                 comment: "title for the confirmation dialog when the user has chosen to close every open tab; argument is the tab count"),
            isPresented: $confirmCloseAllTabs,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                performCloseAllTabs()
            } label: {
                Text("Close All Tabs", bundle: .module, comment: "destructive confirm button on the close-all-tabs dialog")
            }
            .accessibilityIdentifier("button.closeAllTabs.confirm")
            Button(role: .cancel) {
                confirmCloseAllTabs = false
            } label: {
                Text("Cancel", bundle: .module, comment: "cancel button on the close-all-tabs dialog")
            }
            .accessibilityIdentifier("button.closeAllTabs.cancel")
        }
        .onReceive(NotificationCenter.default.publisher(for: .downloadEnqueued)) { _ in
            if presentedSheet != .downloads {
                presentedSheet = .downloads
            }
        }
        .preferredColorScheme(settings.appearance == "dark" ? .dark : settings.appearance == "light" ? .light : nil)
        .onChange(of: settings.blockAds, initial: false) { _, _ in applyContentBlockingSettings() }
        .onChange(of: settings.blockTrackers, initial: false) { _, _ in applyContentBlockingSettings() }
        .onChange(of: settings.blockCookieBanners, initial: false) { _, _ in applyContentBlockingSettings() }
        .onChange(of: settings.contentBlockingWhitelistedDomains, initial: false) { _, _ in applyContentBlockingSettings() }
        .onChange(of: settings.contentBlockingCustomBlockedPatterns, initial: false) { _, _ in applyContentBlockingSettings() }
        .onChange(of: currentURL ?? "") { _, _ in refreshFavoritedStatus() }
    }

    /// Apply content-blocker settings to the shared
    /// `WebEngineConfiguration` and trigger an iOS rule-list reinstall
    /// on each open tab. The Android blocker reads `UserDefaults`
    /// dynamically, so its changes apply on the next request without
    /// further work here.
    func applyContentBlockingSettings() {
        configuration.contentBlockers = makeContentBlockerConfiguration(provider: ContentView.adBlockProvider)
        #if !SKIP
        Task { @MainActor in
            for tab in tabs {
                if let engine = tab.navigator.webEngine {
                    _ = await engine.reapplyContentBlockers()
                }
            }
        }
        #endif
    }

    func browserTabView() -> some View {
        TabView(selection: $selectedTab) {
            ForEach($tabs) { tab in
                BrowserView(
                    configuration: configuration,
                    store: store,
                    submitURL: { self.submitURL(text: $0) },
                    findOnPageAction: { self.findOnPageAction() },
                    favoriteAction: { self.favoriteAction() },
                    isFavorited: { self.isCurrentPageFavorited },
                    copyURLAction: { self.copyURLAction() },
                    openInExternalBrowserAction: { self.openInExternalBrowserAction() },
                    pageZoomAction: { self.pageZoomAction() },
                    toggleDesktopSiteAction: { self.toggleDesktopSiteAction() },
                    toggleReaderModeAction: { self.toggleReaderModeAction() },
                    isInReaderMode: { self.isCurrentPageInReaderMode },
                    viewModel: tab,
                    showBottomBar: $showBottomBar
                )
            }
        }
        .background(LinearGradient(colors: [currentState?.themeColor ?? Color.clear, Color.clear], startPoint: .top, endPoint: .center))
        #if !SKIP
        .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
        .indexViewStyle(PageIndexViewStyle(backgroundDisplayMode: .automatic))
        .onOpenURL { url in
            openURL(url: url.absoluteString, newTab: true)
        }
        .sensoryFeedback(.impact, trigger: triggerImpact)
        #endif
        .onChange(of: currentState?.scrollingDown) {
            let scrollingDown = currentState?.scrollingDown == false
            if self.showBottomBar != scrollingDown {
                withAnimation {
                    self.showBottomBar = scrollingDown
                }
            }
        }
        .onChange(of: selectedTab) { oldTab, newTab in
            if let oldVM = tabs.first(where: { $0.id == oldTab }) {
                if oldVM.state.url != nil {
                    captureTabSnapshot(tab: oldVM)
                }
            }
            self.showBottomBar = true
            self.selectedTabState = newTab.description
        }
        .onAppear {
            logger.info("restoring active tabs")
            restoreActiveTabs()
            self.showBottomBar = true
        }
    }

    func settingsView() -> some View {
        SettingsView(configuration: configuration, store: store, onClearCache: clearWebCacheAction)
            #if !SKIP
            .environment(\.openURL, openURLAction(newTab: true))
            #endif
    }
}

/// A modal sheet that can be presented on top of the browser.
///
/// Exactly one sheet can be present at a time — keeping these in an
/// enum (rather than five independent `@State var showXxx: Bool`
/// flags) means they can't disagree about z-order or accidentally
/// stack on top of each other.
enum PresentedSheet: String, Identifiable, Hashable {
    case settings
    case history
    case favorites
    case historyFavorites
    case activeTabs
    case downloads

    var id: String { rawValue }
}

/// Bottom-chrome overlays that replace the toolbar.
///
/// Mutually exclusive with each other and with the toolbar — `nil`
/// leaves the standard toolbar visible.
enum BottomOverlay: String, Hashable {
    case findBar
    case pageZoom
}

#endif
