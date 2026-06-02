// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
#if !SKIP
import UIKit
#endif
import SkipWeb
import NetSkipModel
import NetSkipMiniApp

#if SKIP || os(iOS)

let fallbackURL = "about:blank"

/// Opaque chrome background — used by both the URL bar capsule and the
/// bottom toolbar so the WebView's content never bleeds through.
/// `secondarySystemBackground` adapts to dark mode on iOS; Skip's
/// translation of the same Color picks up Material's secondary surface.
#if SKIP
let urlBarBackground = Color(white: 0.92)
#else
let urlBarBackground = Color(uiColor: UIColor.secondarySystemBackground)
#endif
//
//let bottomBarBackground = Color.clear

/// The list of tabs that holds a BrowserView
@MainActor public struct BrowserTabView : View {
    let configuration: WebEngineConfiguration
    let store: WebBrowserStore

    @State var tabs: [BrowserViewModel] = []
    @State var selectedTab: PageInfo.ID = PageInfo.ID(0)

    @State var showBottomBar = true
    @State var showActiveTabs = false
    @State var showSettings = false
    @State var showHistory = false
    @State var showFavorites = false
    @State var showHistoryFavorites = false
    @State var showDownloads = false
    @State var historyFavoriesSelection = 1
    @State var showFindBar = false
    @State var showPageZoom = false
    @State var findText = ""
    @State var findMatchCount: Int = 0
    @State var tabSearchText = ""

    @State var triggerImpact = false
    @State var triggerWarning = false
    @State var triggerError = false
    @State var triggerStart = false
    @State var triggerStop = false

    @Environment(NetSkipSettings.self) var settings

    /// In-flight per-tab UI state (not a user preference) — keep on AppStorage.
    @AppStorage("selectedTabState") var selectedTabState: String = ""

    @State var tabsSegment: Int = 1 // 1 = Pages, 2 = Apps
    @State var runningMiniApps: Set<String> = [] // IDs of launched miniapps
    @State var activeMiniAppItem: MiniAppLaunchItem? = nil // app storage does not support Int64 (PageInfo.ID), so we serialize it as a string

    /// Stack of recently-closed-tab URLs. Most-recent first. Capped so the
    /// "Reopen Closed Tab" menu doesn't grow unbounded in long sessions.
    /// Per-session only — we explicitly don't persist these because the
    /// user's expectation is that this is undo-style, not "history".
    @State var recentlyClosedTabURLs: [String] = []
    private static let recentlyClosedTabsLimit: Int = 10

    /// Height of the bottom chrome bar (back/tabs/menu/bookmarks/forward
    /// HStack). Shared with `BrowserView` so the URL bar can pad itself
    /// up by exactly this many points and sit flush against the toolbar.
    // ~30% taller than before (48 → 62) — gives the toolbar / URL
    // bar a friendlier, more touchable feel without dominating the
    // viewport. Same scale applied to icon and font sizes below.
    static let bottomToolbarHeight: CGFloat = 62.0

    /// Natural height of the URL bar capsule when shown — matches the
    /// 44pt capsule + 4pt top padding inside `urlBarComponentView` so
    /// there's no centered-frame gap on Compose. Collapses to zero on
    /// scroll-down so the WebView occupies the full screen.
    static let urlBarHeight: CGFloat = 62.0

    @State var confirmCloseAllTabs: Bool = false
    @State var isCurrentPageFavorited: Bool = false

    public init(configuration: WebEngineConfiguration, store: WebBrowserStore) {
        self.configuration = configuration
        self.store = store
    }

    public var body: some View {
        // SkipUI insets the top edge by the system status bar automatically on Android
        // (matching iOS), so no manual safe-area padding is needed here.
        bodyContent
    }

    @ViewBuilder
    private var bodyContent: some View {
        ZStack(alignment: .bottom) {
            // browserTabView fills the entire ZStack; the URL bar lives
            // inside each tab's `BrowserView` as a `.bottom`-aligned
            // overlay so the WebView extends behind it. We lift it by
            // `bottomToolbarHeight` so the URL bar sits flush against
            // the toolbar that we overlay separately below.
            VStack(spacing: 0) {
                browserTabView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // Bottom chrome overlay. When find-on-page is active the
            // find bar takes the toolbar's slot at the bottom — the
            // pattern Chrome desktop uses — so the user can see the
            // count and prev/next without anything else competing for
            // the bottom strip. Close button restores the toolbar.
            if showFindBar {
                findBar()
            } else {
                bottomToolbar()
            }
            if showPageZoom {
                pageZoomBar()
            }
        }
        .background(Color.clear)
        .statusBarHidden(settings.hideStatusBar)
        // Edge-to-edge full-bleed only when the user opts in via
        // Hide Status Bar. `.all` here gives the WebView every edge of
        // the screen; the URL bar / toolbar overlays stay anchored
        // inside the (now ignored) safe area at the bottom.
        .ignoresSafeArea(edges: settings.hideStatusBar ? Edge.Set.all : Edge.Set(rawValue: 0))
        .sheet(isPresented: $showSettings) { settingsView() }
        .sheet(isPresented: $showHistoryFavorites) { historyFavoritesPageInfoTabView() }
        .sheet(isPresented: $showHistory) { historyPageInfoView() }
        .sheet(isPresented: $showFavorites) { favoritesPageInfoView() }
        .sheet(isPresented: $showActiveTabs) { activeTabsView() }
        .sheet(isPresented: $showDownloads) { NetSkipDownloadsListView() }
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
        .onReceive(NotificationCenter.default.publisher(for: .netSkipDownloadEnqueued)) { _ in
            if !showDownloads {
                showDownloads = true
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

    /// Apply content-blocker settings to the shared `WebEngineConfiguration` and
    /// trigger an iOS rule-list reinstall on each open tab. The Android blocker
    /// reads `UserDefaults` dynamically, so its changes apply on the next request
    /// without further work here.
    func applyContentBlockingSettings() {
        configuration.contentBlockers = netSkipMakeContentBlockerConfiguration(provider: ContentView.adBlockProvider)
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

    var toolbarPlacement: ToolbarItemPlacement {
        #if os(macOS)
        let toolbarPlacement = ToolbarItemPlacement.automatic
        #else
        let toolbarPlacement = ToolbarItemPlacement.bottomBar
        #endif
        return toolbarPlacement
    }

    /// Bottom toolbar rendered as a manual HStack so the chrome can sit
    /// directly under the URL bar (which lives inside `BrowserView`'s own
    /// VStack) and disappear in tandem with it. Replaces the previous
    /// `.toolbar(.bottomBar)` placement that required a `NavigationStack`
    /// wrapper. Collapses to zero height when `showBottomBar` is off so
    /// the URL bar's compact slim mode is the only thing left visible.
    @ViewBuilder func bottomToolbar() -> some View {
        // Six-item bottom toolbar: back, forward, new tab, share,
        // tab list, "..." more menu. Each item gets a fixed square
        // hit-target so different glyph aspect ratios (a thin
        // chevron next to a chunky share arrow next to a circle of
        // dots) don't render at visually different sizes — the user
        // explicitly asked for uniform toolbar buttons.
        HStack(spacing: 0) {
            backButton()
                .frame(width: toolbarItemSize, height: toolbarItemSize)
            Spacer()
            forwardButton()
                .frame(width: toolbarItemSize, height: toolbarItemSize)
            Spacer()
            newTabToolbarButton()
                .frame(width: toolbarItemSize, height: toolbarItemSize)
            Spacer()
            shareToolbarButton()
                .frame(width: toolbarItemSize, height: toolbarItemSize)
            Spacer()
            tabsButton()
                .frame(width: toolbarItemSize, height: toolbarItemSize)
            Spacer()
            ellipsisMenu()
                .frame(width: toolbarItemSize, height: toolbarItemSize)
        }
        .labelStyle(.iconOnly)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(urlBarBackground)
        // Fixed height when shown; collapses to 0 when the user
        // scrolls down. SwiftUI's natural-sized `nil` height doesn't
        // transpile cleanly to Compose, and `.infinity` greedily
        // eats the WebView's space on iOS.
        .frame(height: showBottomBar ? Self.bottomToolbarHeight : 0.0)
        .opacity(showBottomBar ? 1.0 : 0.0)
        .clipped()
    }

    /// Uniform square hit-target for every bottom-toolbar item.
    /// Without this, glyphs with different intrinsic aspect ratios
    /// would visibly disagree on size, and the row would look ragged.
    let toolbarItemSize: CGFloat = 44.0

    func browserTabView() -> some View {
        // Both platforms now use SwiftUI's TabView (Skip translates it
        // to a Compose Pager on Android). We previously had a custom
        // paged ScrollView on iOS for "swipe past last tab spawns a
        // new tab" with adjacent-tab peek; the user reverted that —
        // they prefer the standard TabView for consistency between
        // the two platforms.
        TabView(selection: $selectedTab) {
            ForEach($tabs) { tab in
                BrowserView(configuration: configuration, store: store, submitURL: { self.submitURL(text: $0) }, viewModel: tab, showSettings: $showSettings, showBottomBar: $showBottomBar)
            }
        }
        .background(LinearGradient(colors: [currentState?.themeColor ?? Color.clear, Color.clear], startPoint: .top, endPoint: .center))
        #if !SKIP
        .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
        .indexViewStyle(PageIndexViewStyle(backgroundDisplayMode: .automatic))
        .onOpenURL { url in
            openURL(url: url.absoluteString, newTab: true)
        }
        .sensoryFeedback(.start, trigger: triggerStart)
        .sensoryFeedback(.stop, trigger: triggerStop)
        .sensoryFeedback(.impact, trigger: triggerImpact)
        .sensoryFeedback(.warning, trigger: triggerWarning)
        .sensoryFeedback(.error, trigger: triggerError)
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

    func restoreActiveTabs() {
        // restore the saved tabs
        let activeTabs = trying { try store.loadItems(type: PageInfo.PageType.active, ids: []) }

        var hasBlankTab = false
        var blankTabIdsToRemove: [PageInfo.ID] = []

        for activeTab in activeTabs ?? [] {
            let isBlank = activeTab.url == nil || activeTab.url == "" || activeTab.url == "about:blank"

            // Only keep one blank tab; remove duplicates from the database
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

        // Clean up duplicate blank tabs from the database
        if !blankTabIdsToRemove.isEmpty {
            logger.info("removing \(blankTabIdsToRemove.count) duplicate blank tabs")
            try? store.removeItems(type: .active, ids: Set(blankTabIdsToRemove))
        }

        // always have at least one tab open
        if self.tabs.isEmpty {
            newTabAction()
        }

        // select the most recently selected tab if it exists
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

    // MARK: - Tab Snapshots

    func snapshotDirectory() -> URL {
        let dir = URL.cachesDirectory.appendingPathComponent("tab-snapshots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func snapshotPath(for tabId: PageInfo.ID) -> URL {
        return BrowserViewModel.snapshotPath(for: tabId)
    }

    func captureTabSnapshot(tab: BrowserViewModel) {
        Task { @MainActor in
            await tab.captureSnapshot()
        }
    }

    func captureAllTabSnapshots() {
        for tab in tabs {
            if tab.state.url != nil {
                captureTabSnapshot(tab: tab)
            }
        }
    }

    func removeTabSnapshot(tabId: PageInfo.ID) {
        let path = snapshotPath(for: tabId)
        try? FileManager.default.removeItem(at: path)
    }

    func loadSnapshotImage(for tabId: PageInfo.ID) -> UIImage? {
        let path = snapshotPath(for: tabId)
        guard let data = try? Data(contentsOf: path) else { return nil }
        return UIImage(data: data)
    }

    // MARK: - Tab Overview

    func activeTabsView() -> some View {
        // `preferredColorScheme(.dark)` forces dark Material / iOS
        // chrome for the whole sheet — including the top app bar
        // background and icon colors — so the navigation strip
        // stops being a light-on-dark island sitting above the
        // dark tabs grid. iOS already pinned this via
        // `.toolbarBackground(...)`/`toolbarColorScheme(...)` below,
        // but those are iOS-only modifiers; this works on both.
        NavigationStack {
            VStack(spacing: 0) {
                if settings.enableMiniApps {
                    Picker(selection: $tabsSegment) {
                        Text("Pages", bundle: .module, comment: "tab segment for pages")
                            .tag(1)
                        Text("Apps", bundle: .module, comment: "tab segment for miniapps")
                            .tag(2)
                    } label: {
                        EmptyView()
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }

                if tabsSegment == 1 || !settings.enableMiniApps {
                    pagesTabContent
                } else {
                    miniAppsTabContent
                }
            }
            .background(Color(white: 0.12))
            #if !SKIP
            // Whole tabs sheet uses a hard-coded dark background, so
            // semantic system colors (placeholder text, secondary
            // labels, separators) must resolve to their dark-mode
            // values — otherwise a Light-Mode iOS device renders the
            // search-bar placeholder dark-grey on dark-grey. On
            // Skip / Android the equivalent is achieved by
            // explicitly tinting the search field's placeholder in
            // `tabSearchField` (Compose ignores the SwiftUI
            // colorScheme env in some Skip 1.5 transpilations).
            .environment(\.colorScheme, .dark)
            #endif
            // Pluralization via Swift dispatch rather than xcstrings
            // `variations.plural.{one,other}`. Skip-Lite's runtime
            // chokes on `%lld` format-specifier strings inside
            // plural variations (`MissingFormatArgumentException`
            // out of Kotlin's `String.format`), so the cleanest
            // cross-platform answer is to pick the right singular /
            // plural source string ourselves; each variant lives as
            // a standalone entry in Localizable.xcstrings with its
            // own translations.
            .navigationTitle(tabsSegment == 1 || !settings.enableMiniApps
                ? (tabs.count == 1
                    ? Text("1 Tab", bundle: .module, comment: "tabs sheet navigation title when exactly one tab is open")
                    : Text("\(tabs.count) Tabs", bundle: .module, comment: "tabs sheet navigation title when more than one tab is open; argument is the count"))
                : Text("Mini Apps", bundle: .module, comment: "tabs sheet title when on the Mini Apps segment"))
            #if !SKIP
            .navigationBarTitleDisplayMode(.inline)
            // The tab grid below has a hard-coded dark background
            // (Color(white: 0.12)) regardless of system appearance,
            // so the navigation bar must match. `toolbarColorScheme`
            // alone has regressed on iOS 26 — it leaves the title
            // dark when the toolbar background is light, giving a
            // dark-on-dark title against the dark grid below. Pin
            // both the bar background AND the color scheme so the
            // title renders in white regardless of system theme.
            .toolbarBackground(Color(white: 0.12), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if tabsSegment == 1 || !settings.enableMiniApps {
                        Button(action: {
                            newTabAction()
                            showActiveTabs = false
                        }) {
                            Image("plus", bundle: .module)
                        }
                        .accessibilityIdentifier("button.tabs.new")
                        .accessibilityLabel(Text("New Tab", bundle: .module, comment: "accessibility label for the new-tab toolbar button in the tab overview"))
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        showActiveTabs = false
                    } label: {
                        Text("Done", bundle: .module, comment: "done button title")
                            .bold()
                    }
                    .accessibilityIdentifier("button.tabs.done")
                }
            }
        }
        #if !SKIP
        .presentationDetents([.large])
        #endif
        .preferredColorScheme(.dark)
    }

    var pagesTabContent: some View {
        VStack(spacing: 0) {
            tabSearchField

            let visibleTabs = filteredTabs
            if visibleTabs.isEmpty && !tabSearchText.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image("magnifyingglass", bundle: .module)
                        .font(.system(size: 36))
                        .foregroundStyle(Color.white.opacity(0.4))
                    Text("No matching tabs", bundle: .module, comment: "empty-state message when the tab-overview search has no matches")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.white.opacity(0.6))
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("label.tabSearch.empty")
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                        ForEach(visibleTabs) { tab in
                            tabCardView(tab: tab)
                        }
                    }
                    .padding(12)
                }
            }
        }
    }

    /// Subset of `tabs` matching the current `tabSearchText`. Empty search
    /// passes everything through unchanged. The match is case-insensitive
    /// and falls back to the view-model's saved fields when the live
    /// WebView state hasn't been populated for a background tab — the
    /// same fallback chain the tab card uses for its display text.
    var filteredTabs: [BrowserViewModel] {
        let query = tabSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if query.isEmpty { return tabs }
        return tabs.filter { tab in
            let titleSource = tab.state.pageTitle ?? tab.savedTitle
            let urlSource = tab.state.url?.absoluteString ?? tab.savedURL
            return titleSource.lowercased().contains(query) || urlSource.lowercased().contains(query)
        }
    }

    @ViewBuilder var tabSearchField: some View {
        HStack(spacing: 8) {
            Image("magnifyingglass", bundle: .module)
                .foregroundStyle(Color.white.opacity(0.6))
            TextField(text: $tabSearchText) {
                // Skip / Android: Compose's TextField propagates the
                // placeholder's `.foregroundStyle` to the hint color,
                // so we tint it explicitly here to avoid the
                // dark-grey-on-dark default. iOS picks this up too.
                Text("Search Tabs", bundle: .module, comment: "placeholder text for the search field in the tab overview")
                    .foregroundStyle(Color.white.opacity(0.55))
            }
            .textFieldStyle(.plain)
            .foregroundStyle(Color.white)
            #if !SKIP
            .autocorrectionDisabled(true)
            .textInputAutocapitalization(.never)
            #endif
            .accessibilityIdentifier("field.tabSearch")

            if !tabSearchText.isEmpty {
                Button {
                    tabSearchText = ""
                } label: {
                    Image("xmark.circle.fill", bundle: .module)
                        .foregroundStyle(Color.white.opacity(0.6))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("button.tabSearch.clear")
                .accessibilityLabel(Text("Clear search", bundle: .module, comment: "accessibility label for clearing the tab-overview search field"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(white: 0.22))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    var miniAppsTabContent: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                ForEach(sampleMiniApps) { app in
                    miniAppCardView(app: app)
                }
            }
            .padding(12)
        }
        .sheet(item: $activeMiniAppItem) { item in
            miniAppSheet(appID: item.appID)
        }
    }

    @ViewBuilder func miniAppCardView(app: MiniAppCatalogEntry) -> some View {
        let isRunning = runningMiniApps.contains(app.id)
        let snapshotImage = loadMiniAppSnapshotImage(for: app.id)

        Button {
            activeMiniAppItem = MiniAppLaunchItem(appID: app.id)
            if !isRunning {
                runningMiniApps.insert(app.id)
            }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                // Title bar
                HStack(spacing: 4) {
                    Image("widgets", bundle: .module)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.white.opacity(0.7))
                    Text(app.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.white)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if isRunning {
                        Button {
                            closeMiniApp(id: app.id)
                        } label: {
                            Image("close", bundle: .module)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color.white.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(isRunning ? Color.accentColor : Color(white: 0.28))

                // Content area — show snapshot if available, otherwise placeholder
                ZStack {
                    Color(white: 0.95)
                    if let snapshotImage = snapshotImage {
                        Image(uiImage: snapshotImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        VStack(spacing: 6) {
                            Image("widgets", bundle: .module)
                                .font(.system(size: 28))
                                .foregroundStyle(isRunning ? Color.accentColor : Color.gray.opacity(0.4))
                            Text(app.description)
                                .font(.system(size: 11))
                                .foregroundStyle(Color.gray.opacity(0.7))
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .padding(.horizontal, 8)
                        }
                    }
                }
                .frame(height: 140)
                .clipped()
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isRunning ? Color.accentColor : Color(white: 0.3), lineWidth: isRunning ? 2.0 : 0.5)
            )
            .shadow(color: .black.opacity(0.3), radius: 3, y: 2)
        }
        .buttonStyle(.plain)
    }

    func miniAppSheet(appID: String) -> some View {
        Group {
            if let entry = sampleMiniApps.first(where: { $0.id == appID }) {
                MiniAppHostingView(entry: entry, onDismiss: {
                    activeMiniAppItem = nil
                }, onSnapshot: { pngData in
                    saveMiniAppSnapshot(appID: appID, pngData: pngData)
                })
            }
        }
    }

    func saveMiniAppSnapshot(appID: String, pngData: Data) {
        let path = miniAppSnapshotPath(for: appID)
        do {
            try pngData.write(to: path)
        } catch {
            logger.warning("Failed to save miniapp snapshot: \(error)")
        }
    }

    func loadMiniAppSnapshotImage(for appID: String) -> UIImage? {
        let path = miniAppSnapshotPath(for: appID)
        guard let data = try? Data(contentsOf: path) else { return nil }
        return UIImage(data: data)
    }

    func closeMiniApp(id: String) {
        runningMiniApps.remove(id)
        // Clear the miniapp's persistent storage and snapshot
        let storageDir = miniAppStorageBaseDirectory.appendingPathComponent(id)
        try? FileManager.default.removeItem(at: storageDir)
        let snapshotFile = miniAppSnapshotPath(for: id)
        try? FileManager.default.removeItem(at: snapshotFile)
    }

    @ViewBuilder func tabCardView(tab: BrowserViewModel) -> some View {
        let isActive = tab.id == selectedTab
        let title = tab.state.pageTitle ?? tab.savedTitle
        let urlString = tab.state.url?.absoluteString ?? tab.savedURL
        let domain = tabDomainFromURL(urlString)
        let snapshotImage = loadSnapshotImage(for: tab.id)

        Button {
            // Mirror the outgoing tab's live state onto its saved
            // fields and capture a fresh snapshot before the swap, for
            // the same reason `newTabAction` does — once SwiftUI tears
            // down the leaving BrowserView's WebView, neither state
            // nor pixels are recoverable.
            if let outgoing = currentViewModel, outgoing.id != tab.id {
                if let pageURL = outgoing.state.url {
                    outgoing.savedURL = pageURL.absoluteString
                }
                if let pageTitle = outgoing.state.pageTitle, !pageTitle.isEmpty {
                    outgoing.savedTitle = pageTitle
                }
                Task { @MainActor in
                    await outgoing.captureSnapshot()
                }
            }
            withAnimation {
                self.selectedTab = tab.id
                self.showActiveTabs = false
            }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                // Title bar — sized up so the title text is readable
                // at a glance and the close button is a fingertip
                // target (not the previous 10-point pinhole).
                HStack(spacing: 6) {
                    if tab.isPinned {
                        Image("push_pin", bundle: .module)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Color.white)
                            .accessibilityIdentifier("indicator.tab.pinned")
                    }
                    Text(title.isEmpty ? (domain.isEmpty ? "New Tab" : domain) : title)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.white)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    // Reserve trailing space inside the header for
                    // the close button that's rendered as a sibling
                    // overlay below. We can't put the actual Button
                    // here because it's inside the outer card Button's
                    // label, and on iOS the outer Button consumes the
                    // tap before the nested Button sees it.
                    Color.clear
                        .frame(width: 32, height: 32)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(
                    isActive
                        ? Color.accentColor
                        : (domain.isEmpty ? Color(white: 0.28) : domainAvatarColor(for: domain).opacity(0.85))
                )

                // Snapshot preview area
                ZStack(alignment: .topLeading) {
                    Color(white: 0.95)
                    if let snapshotImage = snapshotImage {
                        Image(uiImage: snapshotImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else if !domain.isEmpty {
                        // No snapshot, but we know the domain — render a
                        // favicon-style colored letter avatar. The color
                        // is a deterministic hash of the domain so the
                        // same site is always the same color across
                        // sessions, and the contrast against the white
                        // card background reads well at thumbnail size.
                        VStack(spacing: 10) {
                            ZStack {
                                Circle()
                                    .fill(domainAvatarColor(for: domain))
                                    .frame(width: 64, height: 64)
                                Text(verbatim: domainAvatarLetter(for: domain))
                                    .font(.system(size: 30, weight: .semibold))
                                    .foregroundStyle(Color.white)
                            }
                            Text(verbatim: domain)
                                .font(.system(size: 13))
                                .foregroundStyle(Color(white: 0.35))
                                .lineLimit(1)
                                .padding(.horizontal, 8)
                        }
                    } else {
                        // Brand-new blank tab — no URL yet.
                        Image("magnifyingglass", bundle: .module)
                            .font(.system(size: 28))
                            .foregroundStyle(Color.gray.opacity(0.4))
                    }

                }
                .frame(height: 180)
                .clipped()
                // Favicon overlay — sits above the snapshot preview
                // via `.overlay(alignment:)` rather than as a ZStack
                // sibling. On iOS the ZStack-sibling layout was being
                // covered by the aspect-fill snapshot Image, even
                // though the favicon was declared later in code (the
                // greedy intrinsic-size resolution for `.aspectRatio
                // (.fill)` pushes drawn pixels above sibling content
                // in some SwiftUI iOS 17/26 builds). `.overlay` is an
                // explicit z-order layer and renders cleanly on both
                // platforms.
                .overlay(alignment: .topLeading) {
                    if !urlString.isEmpty {
                        FaviconView(urlString: urlString, size: 26.0, cornerRadius: 6.0)
                            .padding(7)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.white)
                                    .shadow(color: Color.black.opacity(0.18), radius: 3, y: 1)
                            )
                            .padding(10)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isActive ? Color.accentColor : Color(white: 0.3), lineWidth: isActive ? 2.5 : 0.5)
            )
            .shadow(color: .black.opacity(0.3), radius: 3, y: 2)
        }
        .buttonStyle(.plain)
        // Close button rendered as a SIBLING overlay outside the
        // outer Button's label — iOS's button hit-testing consumes
        // every tap inside the parent label first, so a nested
        // close Button never gets the gesture. As an overlay on the
        // tab card itself, it owns its taps cleanly on both
        // platforms. The `Color.clear` spacer in the header reserves
        // the trailing width so the title text doesn't run under
        // the X.
        .overlay(alignment: .topTrailing) {
            Button {
                removeTabSnapshot(tabId: tab.id)
                closeTabs([tab.id])
            } label: {
                Image("xmark", bundle: .module)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.9))
                    .frame(width: 32, height: 32)
                    #if !SKIP
                    .contentShape(Rectangle())
                    #endif
            }
            .buttonStyle(.plain)
            .padding(.trailing, 6)
            .padding(.top, 0)
            .accessibilityIdentifier("button.tab.close")
            .accessibilityLabel(Text("Close tab", bundle: .module, comment: "accessibility label for closing an individual tab from the tab overview"))
        }
        .contextMenu {
            Button(action: { copyURLForTab(tab) }) {
                Label {
                    Text("Copy URL", bundle: .module, comment: "context-menu item that copies a single tab's URL to the clipboard from the tab overview")
                } icon: {
                    Image("content_copy", bundle: .module)
                }
            }
            .accessibilityIdentifier("menu.tabCard.copyURL")
            .disabled((tab.state.url?.absoluteString ?? tab.savedURL).isEmpty)

            if tab.isPinned {
                Button(action: { toggleTabPin(tab) }) {
                    Label {
                        Text("Unpin Tab", bundle: .module, comment: "context-menu item that removes the pin from a previously pinned tab card")
                    } icon: {
                        Image("keep_off", bundle: .module)
                    }
                }
                .accessibilityIdentifier("menu.tabCard.unpin")
            } else {
                Button(action: { toggleTabPin(tab) }) {
                    Label {
                        Text("Pin Tab", bundle: .module, comment: "context-menu item that pins a tab to the start of the tab list so it stays at the top of the overview grid")
                    } icon: {
                        Image("push_pin", bundle: .module)
                    }
                }
                .accessibilityIdentifier("menu.tabCard.pin")
            }

            Button(role: .destructive, action: {
                removeTabSnapshot(tabId: tab.id)
                closeTabs([tab.id])
            }) {
                Label {
                    Text("Close Tab", bundle: .module, comment: "context-menu item that closes a single tab from the tab overview")
                } icon: {
                    Image("xmark", bundle: .module)
                }
            }
            .accessibilityIdentifier("menu.tabCard.close")
        }
    }

    /// Flip the pin state on a tab and haptic-confirm. Pinned tabs
    /// float to the start of the tab list so the user can find them
    /// at a glance in the overview grid.
    func toggleTabPin(_ tab: BrowserViewModel) {
        logger.info("toggleTabPin id=\(tab.id) wasPinned=\(tab.isPinned)")
        hapticFeedback()
        tab.isPinned.toggle()
        // Persist the new pin state on the tab's `active` row so the
        // pin survives app relaunches — without this, restarting the
        // app would forget every user-pinned tab.
        if var pageInfo = trying(operation: { try store.loadItems(type: .active, ids: [tab.id]) })?.first {
            pageInfo.pinned = tab.isPinned
            _ = trying { try store.saveItems(type: .active, items: [pageInfo]) }
        }
        // Re-float pinned tabs to the front so the grid order matches
        // the user's mental model: pinned first, then everything else
        // in its previous order.
        withAnimation {
            self.tabs.sort(by: { lhs, rhs in
                if lhs.isPinned != rhs.isPinned {
                    return lhs.isPinned && !rhs.isPinned
                }
                return false
            })
        }
    }

    /// Copies the URL of a specific tab to the system clipboard. Mirrors
    /// `copyURLAction` but acts on the passed-in tab rather than the
    /// currently selected one — needed for the tab-card context menu,
    /// where the user might right-click a background tab.
    func copyURLForTab(_ tab: BrowserViewModel) {
        let url = tab.state.url?.absoluteString ?? tab.savedURL
        guard !url.isEmpty else { return }
        logger.info("copyURLForTab id=\(tab.id) url=\(url)")
        hapticFeedback()
        #if SKIP
        let ctx = ProcessInfo.processInfo.androidContext
        let cm = ctx.getSystemService(android.content.Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
        cm.setPrimaryClip(android.content.ClipData.newPlainText("URL", url))
        #else
        UIPasteboard.general.string = url
        #endif
    }

    func tabDomainFromURL(_ urlString: String) -> String {
        guard let url = URL(string: urlString) else { return urlString }
        var host = url.host ?? ""
        if host.hasPrefix("www.") {
            host = host.replacingOccurrences(of: "www.", with: "")
        }
        return host
    }

    /// Single-character label for a domain-letter tab-card avatar. Uses
    /// the first character of the domain (post-`www.`-strip) uppercased.
    /// Falls back to a neutral glyph for blank tabs.
    func domainAvatarLetter(for domain: String) -> String {
        guard let first = domain.first else { return "?" }
        return String(first).uppercased()
    }

    /// Deterministic background color for a domain-letter avatar. Same
    /// domain always produces the same hue so the user can recognize a
    /// site by its colour across tabs, history, and reopen-closed
    /// surfaces. Saturation and brightness are tuned for legible white
    /// foreground text at thumbnail size — mid-saturation jewel tones
    /// rather than full-bright primaries.
    func domainAvatarColor(for domain: String) -> Color {
        // Domain names are ASCII (host names), so iterating ASCII byte
        // values gives a stable hash across iOS and the Skip Kotlin
        // transpilation (which treats `Character.unicodeScalars.value`
        // as BigInteger and refuses the implicit cast to Int).
        var sum: Int = 0
        var position: Int = 0
        for ch in domain {
            if let ascii = ch.asciiValue {
                sum = sum + Int(ascii) * (position + 1)
                position = position + 1
            }
        }
        let hue = Double(sum % 360) / 360.0
        return Color(hue: hue, saturation: 0.55, brightness: 0.62)
    }

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
        // if we have no open tabs, of if the current tab is not blank, then open it in a new URL
        if self.currentViewModel == nil || (newTab == true && self.currentURL == nil) {
            newTabAction(url: url) // this will set the current tab
        }
        var newURL = url
        // if the scheme netskip:// then change it to https://
        if url.hasPrefix("netskip://") {
            newURL = url.replacingOccurrences(of: "netskip://", with: "https://")
        }
        if let navURL = URL(string: newURL) {
            currentNavigator?.load(url: navURL)
        }
    }

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


    func historyFavoritesPageInfoTabView() -> some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker(selection: $historyFavoriesSelection) {
                    Text("History", bundle: .module, comment: "tab selection for viewing the history list")
                        .tag(1)
                    Text("Favorites", bundle: .module, comment: "tab selection for viewing the favorites list")
                        .tag(2)
                } label: {
                    EmptyView()
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                if historyFavoriesSelection == 1 {
                    historyPageInfoView()
                } else {
                    favoritesPageInfoView()
                }
            }
        }
        #if !SKIP
        .presentationDetents([.medium, .large])
        #endif
    }

    func favoritesPageInfoView() -> some View {
        NavigationStack { favoritesPageInfoListView() }
    }

    @ViewBuilder
    func favoritesPageInfoListView() -> some View {
        PageInfoListView(type: PageInfo.PageType.favorite, store: store, onSelect: { pageInfo in
            logger.info("select favorite: \(pageInfo.url ?? "NONE")")
            if let url = pageInfo.url {
                openURL(url: url, newTab: true)
            }
        }, onDelete: { pageInfos in
            //logger.info("delete histories: \(pageInfos.map(\.url))")
        }, onOpenInNewTab: { pageInfo in
            logger.info("openInNewTab favorite: \(pageInfo.url ?? "NONE")")
            if let url = pageInfo.url {
                newTabAction(url: url, inBackground: settings.openLinksInBackground)
            }
        }, onOpenAllInTabs: { pageInfos in
            logger.info("openAllInTabs favorites: count=\(pageInfos.count)")
            // Bulk-open backgrounds all but the last to mimic the
            // canonical "open all bookmarks" gesture in desktop browsers.
            for (i, pageInfo) in pageInfos.enumerated() {
                if let url = pageInfo.url {
                    let isLast = i == pageInfos.count - 1
                    newTabAction(url: url, inBackground: !isLast)
                }
            }
        }, toolbarItems: {
            ToolbarItem(placement: .automatic) {
                Button {
                    showFavorites = false
                    showHistoryFavorites = false
                } label: {
                    Text("Done", bundle: .module, comment: "done button title")
                        .bold()
                }
            }
        })
    }

    func historyPageInfoView() -> some View {
        NavigationStack { historyPageInfoListView() }
    }

    @ViewBuilder
    func historyPageInfoListView() -> some View {
        PageInfoListView(type: PageInfo.PageType.history, store: store, onSelect: { pageInfo in
            logger.info("select history: \(pageInfo.url ?? "NONE")")
            if let url = pageInfo.url {
                openURL(url: url, newTab: true)
            }
        }, onDelete: { pageInfos in
            //logger.info("delete histories: \(pageInfos.map(\.url))")
        }, onOpenInNewTab: { pageInfo in
            logger.info("openInNewTab history: \(pageInfo.url ?? "NONE")")
            if let url = pageInfo.url {
                newTabAction(url: url, inBackground: settings.openLinksInBackground)
            }
        }, onOpenAllInTabs: nil, toolbarItems: {
            ToolbarItem(placement: .automatic) {
                Button {
                    showHistory = false
                    showHistoryFavorites = false
                } label: {
                    Text("Done", bundle: .module, comment: "done button title")
                        .bold()
                }
            }
        })
    }

    // Toolbar icon point size — 22 → 28 (~30% larger) gives a more
    // touch-friendly target without making any one icon dominate.
    let toolbarIconSize: CGFloat = 28.0

    @ViewBuilder func backButton() -> some View {
        let enabled = currentState?.canGoBack == true
        let backLabel = Label {
            Text("Back", bundle: .module, comment: "back button label")
        } icon: {
            Image("arrow_back_ios_new", bundle: .module)
                .font(.system(size: toolbarIconSize))
        }

        // Tap fires the `primaryAction` (single-step back) on both platforms;
        // long-press opens the back-history menu so the user can jump
        // multiple steps. SkipWeb exposes `backList` on Android, and the
        // SkipUI accessibility-identifier-propagation fix means the
        // generated `DropdownMenuItem`s are addressable from UI tests.
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

    @ViewBuilder func showHistoryFavoritesButton() -> some View {
        Button(action: showHistoryFavoritesAction) {
            Label {
                Text("Bookmarks", bundle: .module, comment: "bookmarks button label")
            } icon: {
                Image("book", bundle: .module)
                    .font(.system(size: toolbarIconSize))
            }
        }
        .accessibilityIdentifier("button.history.favorites")
    }

    /// Top-level toolbar "new tab" button. Opens a fresh blank tab
    /// with the URL bar auto-focused (via `shouldFocusURLBar` set
    /// inside `newTabAction`) so the user can type immediately.
    @ViewBuilder func newTabToolbarButton() -> some View {
        Button(action: { newTabAction() }) {
            Label {
                Text("New Tab", bundle: .module, comment: "toolbar button label for opening a new blank tab")
            } icon: {
                Image("add_2", bundle: .module)
                    .font(.system(size: toolbarIconSize))
            }
        }
        .accessibilityIdentifier("button.newTab")
        .accessibilityLabel(Text("New Tab", bundle: .module, comment: "accessibility label for the toolbar new-tab button"))
    }

    /// Top-level toolbar share button. Hands the current page URL
    /// off to the platform share sheet via `ShareLink`. Disabled
    /// when there's nothing meaningful to share (blank tab).
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
            // `reopenClosedTabAction` above pops; this row offers
            // single-tap access to the rest of the stack without
            // making the user re-pop-then-undo. Indexed by domain so
            // the menu reads naturally even when the same site shows
            // up multiple times in the recently-closed list.
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
        .accessibilityIdentifier("button.tabs")
    }

    @ViewBuilder func findBar() -> some View {
        HStack(spacing: 8) {
            TextField("Find on page", text: $findText)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                #if !SKIP
                .autocorrectionDisabled(true)
                #endif
                .onSubmit {
                    executeFindOnPage(findText)
                }
                .onChange(of: findText, initial: false) { _, newValue in
                    // Recompute the match count whenever the query
                    // changes — matches what the system find-navigator
                    // on iOS shows alongside its prev/next buttons.
                    Task { @MainActor in
                        await countFindMatches(newValue)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.gray.opacity(0.15))
                .cornerRadius(8)
                .accessibilityIdentifier("field.findOnPage")

            // Match count — "12" matches, or "No matches" when the
            // query is non-empty but the page contains zero hits. The
            // empty-search case suppresses the label entirely so the
            // bar reads cleanly before the user starts typing.
            if !findText.isEmpty {
                Text(findMatchCount == 0 ? "No matches" : "\(findMatchCount)", bundle: .module, comment: "find-on-page match-count label: number of matches or the literal 'No matches' phrase")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(findMatchCount == 0 ? Color.red : Color.secondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("label.findOnPage.count")
            }

            Button(action: {
                executeFindOnPage(findText, backwards: true)
            }) {
                Image("arrow_back_ios_new", bundle: .module)
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(findText.isEmpty || findMatchCount == 0)
            .accessibilityIdentifier("button.findOnPage.previous")
            .accessibilityLabel(Text("Previous match", bundle: .module, comment: "accessibility label for the find-on-page Previous-match button"))

            Button(action: {
                executeFindOnPage(findText, backwards: false)
            }) {
                Image("arrow_forward_ios", bundle: .module)
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(findText.isEmpty || findMatchCount == 0)
            .accessibilityIdentifier("button.findOnPage.next")
            .accessibilityLabel(Text("Next match", bundle: .module, comment: "accessibility label for the find-on-page Next-match button"))

            Button(action: {
                clearFindHighlights()
                showFindBar = false
                findText = ""
            }) {
                Image("xmark", bundle: .module)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("button.findOnPage.close")
            .accessibilityLabel(Text("Close find on page", bundle: .module, comment: "accessibility label for the find-on-page close button"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        // Explicit height matches the bottom toolbar — Compose's
        // VStack on Android otherwise hands all available space to
        // `browserTabView()`'s `.frame(maxHeight: .infinity)` and the
        // find bar collapses to zero pixels.
        .frame(height: 48.0)
        .background(Color(white: 0.95))
    }

    @ViewBuilder func pageZoomBar() -> some View {
        HStack(spacing: 0) {
            Spacer()

            HStack(spacing: 2) {
                // Decrease zoom button (small A)
                Button(action: {
                    hapticFeedback()
                    settings.textZoom = max(settings.textZoom - 0.15, 0.5)
                }) {
                    Text(verbatim: "A")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 40, height: 36)
                }
                .buttonStyle(.plain)
                .disabled(settings.textZoom <= 0.5)
                .accessibilityIdentifier("button.zoom.decrease")
                .accessibilityLabel(Text("Decrease text size", bundle: .module, comment: "accessibility label for the page-zoom decrease button"))

                // Current zoom percentage (tap to reset to 100%)
                Button(action: {
                    hapticFeedback()
                    settings.textZoom = 1.0
                }) {
                    let pct = Int((settings.textZoom * 100).rounded())
                    Text(verbatim: "\(pct)%")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 56, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("button.zoom.reset")
                .accessibilityLabel(Text("Reset text size", bundle: .module, comment: "accessibility label for the page-zoom reset button (tap to return to 100%)"))

                // Increase zoom button (large A)
                Button(action: {
                    hapticFeedback()
                    settings.textZoom = min(settings.textZoom + 0.15, 3.0)
                }) {
                    Text(verbatim: "A")
                        .font(.system(size: 19, weight: .medium))
                        .frame(width: 40, height: 36)
                }
                .buttonStyle(.plain)
                .disabled(settings.textZoom >= 3.0)
                .accessibilityIdentifier("button.zoom.increase")
                .accessibilityLabel(Text("Increase text size", bundle: .module, comment: "accessibility label for the page-zoom increase button"))
            }
            .background(Color.gray.opacity(0.15))
            .cornerRadius(8)

            Spacer()

            // Dismiss button
            Button(action: {
                showPageZoom = false
            }) {
                Image("xmark.circle.fill", bundle: .module)
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.leading, 8)
            .accessibilityIdentifier("button.zoom.dismiss")
            .accessibilityLabel(Text("Close page zoom", bundle: .module, comment: "accessibility label for the page-zoom dismiss button"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(white: 0.95))
    }

    @ViewBuilder func tabCountIcon() -> some View {
        #if !SKIP
        // iOS: Label icons in toolbars require a static Image, not a dynamic view.
        // Pre-render the tab count badge to a UIImage via ImageRenderer and cache it.
        let img = Self.renderedTabCountImage(for: tabs.count)
        Image(uiImage: img)
            .renderingMode(.template)
        #else
        // Android/Skip: dynamic views work fine as toolbar icons
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(lineWidth: 2.0)
                .frame(width: 28, height: 28)
            Text("\(tabs.count)")
                .font(.system(size: 14, weight: .bold))
        }
        #endif
    }

    #if !SKIP
    /// Cache of pre-rendered tab count badge images keyed by count.
    private static var tabCountImageCache: [Int: UIImage] = [:]

    /// Returns a cached UIImage for the given tab count, rendering it if needed.
    private static func renderedTabCountImage(for count: Int) -> UIImage {
        if let cached = tabCountImageCache[count] {
            return cached
        }
        let badge = ZStack {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(lineWidth: 2.0)
                .frame(width: 28, height: 28)
            Text("\(count)")
                .font(.system(size: 14, weight: .bold))
        }
        .foregroundStyle(Color.primary)

        let renderer = ImageRenderer(content: badge)
        renderer.scale = UIScreen.main.scale
        let image = renderer.uiImage ?? UIImage()
        tabCountImageCache[count] = image
        return image
    }
    #endif

    @ViewBuilder func ellipsisMenu() -> some View {
        Menu {
            Button(action: reloadAction) {
                Label {
                    Text("Reload", bundle: .module, comment: "reload button label")
                } icon: {
                    Image("arrow.clockwise", bundle: .module)
                }
            }
            .accessibilityIdentifier("menu.reload")

            Button(action: homeAction) {
                Label {
                    Text("Home", bundle: .module, comment: "home button label")
                } icon: {
                    Image("house", bundle: .module)
                }
            }
            .accessibilityIdentifier("menu.home")

            Button(action: findOnPageAction) {
                Label {
                    Text("Find on Page", bundle: .module, comment: "find on page button label")
                } icon: {
                    Image("magnifyingglass", bundle: .module)
                }
            }
            .accessibilityIdentifier("menu.findOnPage")

            Divider()

            Button(action: favoriteAction) {
                Label {
                    if isCurrentPageFavorited {
                        Text("Remove from Favorites", bundle: .module, comment: "menu label when the current page is already saved as a favorite — tapping removes it")
                    } else {
                        Text("Add to Favorites", bundle: .module, comment: "add to favorites button label")
                    }
                } icon: {
                    Image("star", bundle: .module)
                }
            }
            .accessibilityIdentifier(isCurrentPageFavorited ? "menu.removeFavorite" : "menu.addFavorite")
            .disabled(currentURL == nil)

            ShareLink(item: currentState?.url?.absoluteString ?? fallbackURL) {
                Label {
                    Text("Share", bundle: .module, comment: "share button label")
                } icon: {
                    Image("ios_share", bundle: .module)
                }
            }
            .accessibilityIdentifier("menu.share")

            Button(action: copyURLAction) {
                Label {
                    Text("Copy URL", bundle: .module, comment: "menu label for copying the current page URL to the clipboard")
                } icon: {
                    Image("content_copy", bundle: .module)
                }
            }
            .accessibilityIdentifier("menu.copyURL")
            .disabled(currentState?.url == nil)

            Button(action: pasteAndGoAction) {
                Label {
                    Text("Paste and Go", bundle: .module, comment: "menu label for pasting the clipboard contents into the URL bar and navigating to that page")
                } icon: {
                    Image("content_paste", bundle: .module)
                }
            }
            .accessibilityIdentifier("menu.pasteAndGo")

            Button(action: openInExternalBrowserAction) {
                Label {
                    Text("Open in External Browser", bundle: .module, comment: "menu label that hands the current page URL to the system's default browser — the escape hatch for sites that don't render correctly in this WebView")
                } icon: {
                    Image("open_in_browser", bundle: .module)
                }
            }
            .accessibilityIdentifier("menu.openInExternalBrowser")
            .disabled(currentState?.url == nil)

            // Translate Page — temporarily disabled while we
            // consider the right customization (provider choice,
            // target language picker, in-place vs new-tab behavior).
            // The `translatePageAction` implementation below remains
            // ready for re-enabling once the design lands.
            /*
            Button(action: translatePageAction) {
                Label {
                    Text("Translate Page", bundle: .module, comment: "menu label that loads the current page through Google Translate so the user can read foreign-language content in their own language")
                } icon: {
                    Image("translate", bundle: .module)
                }
            }
            .accessibilityIdentifier("menu.translatePage")
            .disabled(currentState?.url == nil)
            */

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

            Button(action: pageZoomAction) {
                Label {
                    Text("Page Zoom", bundle: .module, comment: "page zoom button label")
                } icon: {
                    Image("textformat.size", bundle: .module)
                }
            }
            .accessibilityIdentifier("menu.pageZoom")

            Button(action: toggleDesktopSiteAction) {
                Label {
                    Text(settings.requestDesktopSite ? "Mobile Site" : "Desktop Site", bundle: .module, comment: "desktop/mobile site toggle")
                } icon: {
                    Image(settings.requestDesktopSite ? "smartphone" : "computer", bundle: .module)
                }
            }
            .accessibilityIdentifier("menu.desktopSite")

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

    @MainActor func submitURL(text: String) {
        logger.log("URLBar submit")
        if let parsedURL = fieldToURL(text),
            ["http", "https", "file", "ftp", "netskip"].contains(parsedURL.scheme ?? "") {
            // HTTPS upgrade — when the user typed/pasted a bare `http://`
            // URL and the setting is on, rewrite it to `https://` before
            // dispatching. Localhost and IP literals are left alone since
            // those are typically explicitly chosen by developers.
            let finalURL: URL = Self.maybeUpgradeToHTTPS(parsedURL, enabled: settings.upgradeToHTTPS)
            logger.log("loading url: \(finalURL)")
            self.currentNavigator?.load(url: finalURL)
        } else {
            logger.log("URL search bar entry: \(text)")
            if let searchEngine = SearchEngine.lookup(id: settings.searchEngine),
               let queryURL = searchEngine.queryURL(text, Locale.current.identifier) {
                logger.log("search engine query URL: \(queryURL)")
                if let url = URL(string: queryURL) {
                    self.currentNavigator?.load(url: url)
                }
            }
        }
    }

    /// The home page URL — the user's custom `customHomeURL` setting if
    /// set (accepting either a fully-qualified URL or a bare host that
    /// we prepend `https://` to), otherwise the active search engine's
    /// home page.
    var homeURL: URL? {
        let trimmed = settings.customHomeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            if let parsed = URL(string: trimmed), parsed.scheme != nil {
                return parsed
            }
            if let prefixed = URL(string: "https://" + trimmed), prefixed.host != nil {
                return prefixed
            }
        }
        if let homePage = SearchEngine.lookup(id: settings.searchEngine)?.homeURL,
           let homePageURL = URL(string: homePage) {
            return homePageURL
        } else {
            return nil
        }
    }

    /// Returns the URL with its scheme rewritten from `http` to `https`
    /// when the setting is enabled and the host isn't a developer-style
    /// local target. Returns the input unchanged otherwise.
    static func maybeUpgradeToHTTPS(_ url: URL, enabled: Bool) -> URL {
        if !enabled { return url }
        if url.scheme != "http" { return url }
        guard let host = url.host, !isLocalOrIPHost(host) else { return url }
        let str = url.absoluteString
        if str.hasPrefix("http://") {
            let upgraded = "https://" + String(str.dropFirst("http://".count))
            if let result = URL(string: upgraded) {
                return result
            }
        }
        return url
    }

    /// Hosts that should *not* be auto-upgraded to HTTPS — the developer
    /// almost certainly meant to hit them in cleartext. Covers `localhost`
    /// (with any port), single-label hostnames (no dot), and IPv4 dotted
    /// quads where TLS cert validation typically fails.
    private static func isLocalOrIPHost(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".localhost") {
            return true
        }
        if !host.contains(".") {
            return true
        }
        // Crude IPv4 detection: all components numeric.
        let parts = host.split(separator: ".")
        if parts.count == 4, parts.allSatisfy({ Int($0) != nil }) {
            return true
        }
        return false
    }

    private func fieldToURL(_ string: String) -> URL? {
        if string.hasPrefix("https://")
            || string.hasPrefix("http://")
            || string.hasPrefix("file://") {
            return URL(string: string)
        } else if string.contains(" ") {
            // anything with spaces is probably a search term
            return nil
        } else if string.contains(".") {
            // anything with a dot might be a URL (TODO: check domain suffix?)
            // fall back to "https" as the protocol for a bare URL string like "appfair.net"
            let url = URL(string: string)
            if url?.scheme == nil {
                // a URL with no scheme should default to https
                return URL(string: "https://\(string)")
            } else {
                return url
            }
        } else {
            return nil
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

    func closeTabAction() {
        logger.info("closeTabAction")
        hapticFeedback()
        closeTabs([self.selectedTab])
    }

    func closeTabs(_ ids: Set<PageInfo.ID>) {
        // Capture each closing tab's URL before we remove it so the user
        // can reopen via the "Reopen Closed Tab" menu item. Blank tabs and
        // about:blank don't go onto the stack — there's nothing to restore.
        for id in ids {
            if let tab = tabs.first(where: { $0.id == id }) {
                // Resolve the URL through three fallbacks: live page
                // URL, the view-model's `savedURL` mirror, then the
                // persistent store. On iOS, background tabs' WebView
                // state can be reset to an empty string (so the live
                // and mirrored fields drop out), but `BrowserView`'s
                // `updatePageURL` writes the URL back to the store on
                // every navigation, so the store always has it.
                var url = tab.state.url?.absoluteString ?? ""
                if url.isEmpty {
                    url = tab.savedURL
                }
                if url.isEmpty {
                    if let storedPage = trying(operation: { try store.loadItems(type: .active, ids: [id]) })?.first,
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
            self.tabs.removeAll(where: { ids.contains($0.id) })
            // remove the pages from the tab list
            try? store.removeItems(type: .active, ids: ids)
            self.selectedTab = self.tabs.last?.id ?? self.selectedTab

            // always leave behind a single tab
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

    /// Fires `navigator.reload()` on every open tab. Useful after the
    /// network reconnects, a sign-in state changes, or a remote-config
    /// updates.
    /// Re-orders the `tabs` array alphabetically by each tab's host.
    /// Resolves each tab's URL through the same three-level fallback
    /// `closeTabs` uses (live page URL → savedURL mirror → persistent
    /// store) so iOS-backgrounded tabs whose WebView state has been
    /// reset still sort where they belong. Stable enough that two
    /// tabs on the same host keep their existing relative order.
    func sortTabsByDomainAction() {
        logger.info("sortTabsByDomainAction count=\(self.tabs.count)")
        hapticFeedback()
        // Resolve URLs once up front. Calling the trying/loadItems
        // path inside the sort closure would re-query the store on
        // every comparison.
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

    func reloadAllTabsAction() {
        logger.info("reloadAllTabsAction count=\(self.tabs.count)")
        hapticFeedback()
        for tab in self.tabs {
            tab.navigator.reload()
        }
    }

    /// Closes every tab except the currently selected one — the classic
    /// "tidy up" shortcut after research sessions leave a dozen background
    /// tabs behind. Closed URLs flow through `closeTabs`, so each one is
    /// pushed onto the recently-closed stack and can be reopened via the
    /// Tabs menu's "Reopen Closed Tab" item.
    func closeOtherTabsAction() {
        logger.info("closeOtherTabsAction count=\(self.tabs.count) selected=\(self.selectedTab)")
        hapticFeedback()
        // Exclude the selected tab AND every pinned tab. Pinned tabs
        // survive Close Other Tabs — the modern-browser contract for
        // user pins is that bulk-close actions spare them.
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
        // Spare pinned tabs — Close All Tabs deletes everything else.
        var allIDs: Set<PageInfo.ID> = []
        for tab in self.tabs {
            if tab.isPinned { continue }
            allIDs.insert(tab.id)
        }
        guard !allIDs.isEmpty else { return }
        closeTabs(allIDs)
    }

    func findOnPageAction() {
        logger.info("findOnPageAction")
        hapticFeedback()
        #if !SKIP
        if let interaction = currentWebView?.findInteraction {
            interaction.presentFindNavigator(showingReplace: false)
            return
        }
        #endif
        // Fallback: show the custom find bar (used on Android, or iOS without findInteraction)
        showPageZoom = false
        showFindBar = true
        findText = ""
    }

    func executeFindOnPage(_ text: String) {
        executeFindOnPage(text, backwards: false)
    }

    /// Advances the in-page selection to the next or previous match of
    /// `text`. The `window.find` JS API takes
    /// `(text, caseSensitive, backwards, wrapAround)` — passing
    /// `backwards: true` walks matches in reverse so consecutive taps step
    /// backward through the page, with wrap-around so the buttons keep
    /// working at either end.
    func executeFindOnPage(_ text: String, backwards: Bool) {
        guard !text.isEmpty else { return }
        if let engine = currentViewModel?.navigator.webEngine {
            let backwardsArg = backwards ? "true" : "false"
            Task {
                _ = try? await engine.evaluate(js: "window.find('\(text.replacingOccurrences(of: "'", with: "\\'"))', false, \(backwardsArg), true)")
            }
        }
    }

    func clearFindHighlights() {
        if let engine = currentViewModel?.navigator.webEngine {
            Task {
                _ = try? await engine.evaluate(js: "window.getSelection().removeAllRanges()")
            }
        }
    }

    /// Count case-insensitive occurrences of `text` in the page's
    /// rendered text and publish the result to `findMatchCount` for
    /// the find-bar's count label. Empty queries reset the count to
    /// zero so the label disappears.
    @MainActor
    func countFindMatches(_ text: String) async {
        guard !text.isEmpty else {
            findMatchCount = 0
            return
        }
        guard let engine = currentViewModel?.navigator.webEngine else { return }
        // Single-quote escape covers the only character that would
        // unbalance the JS string literal we're about to inject.
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let js = """
        (function() {
            var needle = '\(escaped)'.toLowerCase();
            if (!needle) return 0;
            var hay = (document.body && document.body.innerText) ? document.body.innerText.toLowerCase() : '';
            var count = 0;
            var pos = 0;
            while ((pos = hay.indexOf(needle, pos)) !== -1) {
                count++;
                pos += needle.length;
            }
            return count;
        })()
        """
        do {
            let result = try await engine.evaluate(js: js)
            if let value = result, let count = Int(value) {
                findMatchCount = count
            }
        } catch {
            // ignore — leave the previous count in place
        }
    }

    func newTabAction(url: String? = nil, inBackground: Bool = false) {
        logger.info("newTabAction url=\(url ?? "nil") inBackground=\(inBackground)")
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
            // chance to fire that `.onChange`. The snapshot below
            // also relies on the WebView still being attached, so we
            // tie everything to the same swap point: capture state
            // now, then let the snapshot Task pick up the pixels
            // before the view is torn down.
            if let pageURL = outgoing.state.url {
                outgoing.savedURL = pageURL.absoluteString
            }
            if let pageTitle = outgoing.state.pageTitle, !pageTitle.isEmpty {
                outgoing.savedTitle = pageTitle
            }
            Task { @MainActor in
                await outgoing.captureSnapshot()
            }
        }

        // If requesting a blank tab, reuse an existing blank tab instead of creating another
        if url == nil {
            for tab in tabs {
                if tab.state.url == nil || tab.state.url?.absoluteString == "about:blank" {
                    // Reused blank tab: arm its focus signal so
                    // `BrowserView` will pop the keyboard the moment it
                    // becomes visible — same UX as a freshly-created
                    // blank tab.
                    tab.shouldFocusURLBar = true
                    self.selectedTab = tab.id
                    logTabs()
                    return
                }
            }
        }

        let info = PageInfo(url: url)
        let vm = newViewModel(info)
        // Newly-created blank tabs auto-focus the URL bar so the user
        // can begin typing immediately. URL-having tabs don't, because
        // they have a real page to load.
        if url == nil {
            vm.shouldFocusURLBar = true
        }
        self.tabs.append(vm)
        // Stay on the current tab when explicitly opening in the
        // background. Blank tabs always foreground because the user just
        // asked for "a new tab" and expects to land on it.
        if !inBackground || url == nil {
            self.selectedTab = vm.id
        }
        logTabs()
    }

    func logTabs() {
        logger.info("selected=\(selectedTab) count=\(self.tabs.count)") //  tabs=\(self.tabs.flatMap(\.navigator.webEngine?.webView.url))")
    }

    func newPrivateTabAction() {
        logger.info("newPrivateTabAction")
        hapticFeedback()
        // TODO
    }

    func tabListAction() {
        logger.info("tabListAction")
        hapticFeedback()
        captureAllTabSnapshots()
        // Each opening of the tab overview starts with no filter applied.
        // Leaving stale search text would hide most tabs when the user
        // re-enters the sheet expecting to see everything.
        self.tabSearchText = ""
        self.showActiveTabs = true
    }

    func favoriteAction() {
        logger.info("favoriteAction isCurrentPageFavorited=\(isCurrentPageFavorited)")
        hapticFeedback()
        guard let url = self.currentURL else { return }
        if isCurrentPageFavorited {
            // Find the existing favorite row by URL and delete it.
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
    /// Called when the URL changes, when the menu opens, and right after
    /// the user toggles via `favoriteAction()` so the menu label flips
    /// without waiting for the next render trigger.
    func refreshFavoritedStatus() {
        guard let url = self.currentURL else {
            isCurrentPageFavorited = false
            return
        }
        let favorites = trying(operation: { try store.loadItems(type: .favorite, ids: []) }) ?? []
        isCurrentPageFavorited = favorites.contains(where: { $0.url == url })
    }

    func showHistoryFavoritesAction() {
        logger.info("showHistoryFavoritesAction")
        hapticFeedback()
        showHistoryFavorites = true
    }

    func historyAction() {
        logger.info("historyAction")
        hapticFeedback()
        showHistory = true
    }

    func favoritesAction() {
        logger.info("favoritesAction")
        hapticFeedback()
        showFavorites = true
    }

    func settingsAction() {
        logger.info("settingsAction")
        hapticFeedback()
        showSettings = true
    }

    func downloadsAction() {
        logger.info("downloadsAction")
        hapticFeedback()
        showDownloads = true
    }

    /// Clears every tab's web cache (disk + memory + offline application
    /// cache) but explicitly leaves cookies and local storage intact so
    /// the user remains signed in everywhere they were. iOS / Android
    /// share their data stores across `WKWebView` / `WebView` instances,
    /// so dispatching the removal on each tab's engine guarantees the
    /// platform store is touched at least once.
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

    /// Hands the current page URL to the system's default browser —
    /// the modern-browser escape hatch when a site doesn't render in
    /// this WebView (paywalled streaming, OAuth flows, plugin-required
    /// content). On iOS this lands in Safari (or whatever the user
    /// set as their default browser in iOS Settings). On Android we
    /// filter our own package out of the chooser so the user isn't
    /// offered a redundant "open in Net Skip" entry.
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
        // Build one explicit Intent per non-self handler so the chooser
        // shows only third-party browsers. If we're the only handler
        // installed, fall back to launching the base intent so the user
        // still gets a system response rather than a silent no-op.
        var targeted: [android.content.Intent] = []
        for info in resolveInfos {
            let pkg = info.activityInfo.packageName
            if pkg == selfPackage { continue }
            let explicit = android.content.Intent(android.content.Intent.ACTION_VIEW, android.net.Uri.parse(pageURL))
            explicit.setPackage(pkg)
            targeted.append(explicit)
        }
        if targeted.isEmpty {
            // No third-party browser installed — fall back to the
            // default chooser (will include us; the user can't avoid it).
            baseIntent.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
            ctx.startActivity(baseIntent)
        } else if targeted.count == 1 {
            // Exactly one non-self browser — launch directly, no
            // chooser needed (this is the case on most Android setups
            // where Chrome is the only other browser installed).
            let only = targeted[0]
            only.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
            ctx.startActivity(only)
        } else {
            // Multiple third-party browsers — show the system chooser.
            // We accept that self may appear in the chooser; building
            // a strict exclude-self chooser requires constructing a
            // Kotlin native array which Skip's transpilation doesn't
            // surface cleanly from Swift.
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
        // Reuse the URL bar's submit pipeline so the same heuristic (URL vs
        // search query) applies as if the user had typed it.
        submitURL(text: text)
    }

    func pageZoomAction() {
        logger.info("pageZoomAction")
        hapticFeedback()
        showFindBar = false
        showPageZoom = true
    }

    func toggleDesktopSiteAction() {
        logger.info("toggleDesktopSiteAction: \(!settings.requestDesktopSite)")
        hapticFeedback()
        settings.requestDesktopSite.toggle()
        currentNavigator?.reload()
    }

}

struct TitleView : View {
    var body: some View {
        Text("Net Skip", bundle: .module, comment: "title screen headline")
            .font(.system(size: 28, weight: .bold))
            .foregroundStyle(.primary)
    }
}



@Observable public class BrowserViewModel: Identifiable {
    /// The persistent ID of the page
    // SKIP INSERT: @Suppress("MUST_BE_INITIALIZED_OR_FINAL_OR_ABSTRACT") // var to workaround Kotlin to 2 error: "Property must be initialized, be final, or be abstract."
    public let id: PageInfo.ID
    let navigator: WebViewNavigator
    let configuration: WebEngineConfiguration
    let store: WebBrowserStore
    var state = WebViewState()
    var urlTextField: String = ""

    /// Saved metadata from the database, used as fallback before the page loads
    var savedTitle: String = ""
    var savedURL: String = ""

    /// User-pinned tab — shows a pin badge on its tab card and stays
    /// behind a "Closing a pinned tab" confirmation. Session-local for
    /// now; persistence across launches is a future iteration.
    var isPinned: Bool = false

    /// One-shot signal set by `newTabAction` when the user creates (or
    /// reuses) a blank tab — `BrowserView` honors it by focusing the
    /// URL bar so the keyboard comes up and the user can type their
    /// query immediately, then clears the flag. Cleared after first
    /// observation so subsequent appearances don't re-focus.
    var shouldFocusURLBar: Bool = false

    public init(id: PageInfo.ID, navigator: WebViewNavigator, configuration: WebEngineConfiguration, store: WebBrowserStore) {
        self.id = id
        self.navigator = navigator
        self.configuration = configuration
        self.store = store
    }

    /// PNG path on disk where this tab's grid-overview snapshot lives.
    /// Stored under the Caches directory so iOS / Android may evict it
    /// under storage pressure without breaking the app.
    public static func snapshotPath(for tabId: PageInfo.ID) -> URL {
        let dir = URL.cachesDirectory.appendingPathComponent("tab-snapshots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(tabId).png")
    }

    /// Capture a thumbnail of the currently-attached `WKWebView` /
    /// Android `WebView` and write it to `snapshotPath(for: id)`.
    /// Called from `BrowserView` on page-load completion so the snapshot
    /// is fresh when the user opens the tab grid — capturing on tab
    /// switch is too late on iOS, where the leaving tab's WKWebView is
    /// already detached and `takeSnapshot` returns blank pixels.
    @MainActor
    public func captureSnapshot() async {
        guard let webEngine = navigator.webEngine else { return }
        do {
            let config = SkipWebSnapshotConfiguration(snapshotWidth: 300)
            let snapshot = try await webEngine.takeSnapshot(configuration: config)
            try snapshot.pngData.write(to: Self.snapshotPath(for: id))
        } catch {
            // Best-effort — a missing snapshot just falls back to the
            // domain-letter avatar in the tab grid.
        }
    }
}

struct MiniAppLaunchItem: Identifiable {
    let appID: String
    var id: String { appID }
}

#endif

