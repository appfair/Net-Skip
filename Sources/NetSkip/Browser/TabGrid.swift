// SPDX-License-Identifier: GPL-2.0-or-later
//
// The tab-grid sheet (`activeTabsView`) and its supporting helpers —
// search filter, tab cards, mini-app cards, domain colors, pin/copy
// actions. The actual snapshot capture lives on the view-model; this
// file just renders the saved pixels.

import SwiftUI
import SkipWeb
import NetSkipModel
import NetSkipMiniApp

#if SKIP || os(iOS)

extension BrowserTabView {
    /// Navigation-bar title for the tabs sheet.
    ///
    /// Pluralisation is done by Swift-side dispatch into separate
    /// xcstrings keys rather than xcstrings `variations.plural.{one,
    /// other}` — Skip Lite's Kotlin `String.format` chokes on the
    /// `%lld` format specifier inside plural variations and crashes
    /// the navigation bar render. By formatting through
    /// `String(format:)` here and handing the result to
    /// `Text(verbatim:)`, the runtime never sees an unformatted
    /// `%lld` string at SwiftUI evaluation time on either platform.
    @MainActor
    var tabsSheetTitle: Text {
        if tabsSegment != 1 && settings.enableMiniApps {
            return Text("Mini Apps", bundle: .module, comment: "tabs sheet title when on the Mini Apps segment")
        }
        if tabs.count == 1 {
            return Text("1 Tab", bundle: .module, comment: "tabs sheet navigation title when exactly one tab is open")
        }
        let format = NSLocalizedString("%lld Tabs", bundle: .module, comment: "tabs sheet navigation title when more than one tab is open; argument is the count")
        return Text(verbatim: String(format: format, tabs.count))
    }

    func activeTabsView() -> some View {
        // `preferredColorScheme(.dark)` forces dark Material / iOS chrome
        // for the whole sheet — including the top app bar background and
        // icon colors — so the navigation strip stops being a
        // light-on-dark island sitting above the dark tabs grid. iOS
        // already pinned this via `.toolbarBackground(...)` /
        // `toolbarColorScheme(...)` below, but those are iOS-only
        // modifiers; this works on both.
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
            // search-bar placeholder dark-grey on dark-grey.
            .environment(\.colorScheme, .dark)
            #endif
            // Pluralization via Swift dispatch rather than xcstrings
            // `variations.plural.{one,other}`. Skip-Lite's runtime
            // chokes on `%lld` format-specifier strings inside plural
            // variations (`MissingFormatArgumentException` out of
            // Kotlin's `String.format`), so the cleanest cross-platform
            // answer is to pick the right singular / plural source
            // string ourselves; each variant lives as a standalone
            // entry in Localizable.xcstrings with its own translations.
            .navigationTitle(tabsSheetTitle)
            #if !SKIP
            .navigationBarTitleDisplayMode(.inline)
            // The tab grid below has a hard-coded dark background
            // (Color(white: 0.12)) regardless of system appearance,
            // so the navigation bar must match.
            .toolbarBackground(Color(white: 0.12), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if tabsSegment == 1 || !settings.enableMiniApps {
                        Button(action: {
                            newTabAction()
                            presentedSheet = nil
                        }) {
                            Image("plus", bundle: .module)
                        }
                        .accessibilityIdentifier("button.tabs.new")
                        .accessibilityLabel(Text("New Tab", bundle: .module, comment: "accessibility label for the new-tab toolbar button in the tab overview"))
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        presentedSheet = nil
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

    /// Subset of `tabs` matching the current `tabSearchText`. Empty
    /// search passes everything through unchanged. Match is
    /// case-insensitive and uses the same live → saved* fallback as
    /// the tab card so a backgrounded tab whose WKWebView reported
    /// `about:blank` doesn't disappear from the filter.
    var filteredTabs: [BrowserViewModel] {
        let query = tabSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if query.isEmpty { return tabs }
        return tabs.filter { tab in
            let titleSource = Self.effectiveTitle(for: tab)
            let urlSource = Self.effectiveURL(for: tab)
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
        let storageDir = miniAppStorageBaseDirectory.appendingPathComponent(id)
        try? FileManager.default.removeItem(at: storageDir)
        let snapshotFile = miniAppSnapshotPath(for: id)
        try? FileManager.default.removeItem(at: snapshotFile)
    }

    @ViewBuilder func tabCardView(tab: BrowserViewModel) -> some View {
        let isActive = tab.id == selectedTab
        let title = Self.effectiveTitle(for: tab)
        let urlString = Self.effectiveURL(for: tab)
        let domain = tabDomainFromURL(urlString)
        let snapshotImage = loadSnapshotImage(for: tab.id)

        Button {
            // Mirror the outgoing tab's live state onto its saved
            // fields and capture a fresh snapshot before the swap, for
            // the same reason `newTabAction` does — once SwiftUI tears
            // down the leaving BrowserView's WebView, neither state nor
            // pixels are recoverable.
            if let outgoing = currentViewModel, outgoing.id != tab.id {
                if let pageURL = outgoing.state.url, pageURL.absoluteString != "about:blank" {
                    outgoing.savedURL = pageURL.absoluteString
                }
                if let pageTitle = outgoing.state.pageTitle, !pageTitle.isEmpty {
                    outgoing.savedTitle = pageTitle
                }
                // Skip snapshotting private tabs — see TabSnapshots.
                if !outgoing.isPrivate {
                    Task { @MainActor in
                        await outgoing.captureSnapshot()
                    }
                }
            }
            // iOS: switch tabs without the PageTabViewStyle slide.
            // The slide across N tabs drags in offscreen BrowserViews
            // and feels janky; the user already saw the grid and
            // picked where they're going, so a snap-cut is faster
            // and visually cleaner. Sheet dismissal animates on its
            // own via SwiftUI's sheet machinery so we don't need
            // `withAnimation` around it. Android's Compose Pager
            // doesn't have the same slide-jank issue, so keep the
            // original `withAnimation` path there.
            #if !SKIP
            var noSlide = Transaction()
            noSlide.disablesAnimations = true
            withTransaction(noSlide) {
                self.selectedTab = tab.id
            }
            self.presentedSheet = nil
            #else
            withAnimation {
                self.selectedTab = tab.id
                self.presentedSheet = nil
            }
            #endif
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                // Title bar — sized up so the title text is readable at
                // a glance and the close button is a fingertip target.
                HStack(spacing: 6) {
                    if tab.isPrivate {
                        Image("lock", bundle: .module)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Color.white)
                            .accessibilityIdentifier("indicator.tab.private")
                    }
                    if tab.isPinned {
                        Image("push_pin", bundle: .module)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Color.white)
                            .accessibilityIdentifier("indicator.tab.pinned")
                    }
                    Text(title.isEmpty ? (domain.isEmpty ? (tab.isPrivate ? "Private Tab" : "New Tab") : domain) : title)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.white)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    // Reserve trailing space inside the header for the
                    // close button that's rendered as a sibling overlay
                    // below. We can't put the actual Button here
                    // because it's inside the outer card Button's
                    // label, and on iOS the outer Button consumes the
                    // tap before the nested Button sees it.
                    Color.clear
                        .frame(width: 32, height: 32)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(
                    // Private tabs ALWAYS get the indigo header,
                    // even when not selected — so they're obvious
                    // in the grid regardless of where the focus is.
                    tab.isPrivate
                        ? Color(red: 0.21, green: 0.16, blue: 0.36)
                        : (isActive
                            ? Color.accentColor
                            : (domain.isEmpty ? Color(white: 0.28) : domainAvatarColor(for: domain).opacity(0.85)))
                )

                // Snapshot preview area
                ZStack(alignment: .topLeading) {
                    Color(white: 0.95)
                    if let snapshotImage = snapshotImage {
                        Image(uiImage: snapshotImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else if !domain.isEmpty {
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
                // Favicon overlay — sits above the snapshot preview via
                // `.overlay(alignment:)` rather than as a ZStack
                // sibling. On iOS the ZStack-sibling layout was being
                // covered by the aspect-fill snapshot Image, even
                // though the favicon was declared later in code.
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
        // Close button rendered as a SIBLING overlay outside the outer
        // Button's label — iOS's button hit-testing consumes every tap
        // inside the parent label first, so a nested close Button never
        // gets the gesture. As an overlay on the tab card itself it
        // owns its taps cleanly on both platforms.
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
            .disabled(Self.effectiveURL(for: tab).isEmpty)

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
        // pin survives app relaunches.
        if var pageInfo = trying(operation: { try store.loadItems(type: .active, ids: [tab.id]) })?.first {
            pageInfo.pinned = tab.isPinned
            _ = trying { try store.saveItems(type: .active, items: [pageInfo]) }
        }
        withAnimation {
            self.tabs.sort(by: { lhs, rhs in
                if lhs.isPinned != rhs.isPinned {
                    return lhs.isPinned && !rhs.isPinned
                }
                return false
            })
        }
    }

    /// Copies the URL of a specific tab to the system clipboard.
    /// Mirrors `copyURLAction` but acts on the passed-in tab rather
    /// than the currently selected one — needed for the tab-card
    /// context menu, where the user might right-click a background
    /// tab.
    func copyURLForTab(_ tab: BrowserViewModel) {
        let url = Self.effectiveURL(for: tab)
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

    /// Single-character label for a domain-letter tab-card avatar.
    func domainAvatarLetter(for domain: String) -> String {
        guard let first = domain.first else { return "?" }
        return String(first).uppercased()
    }

    /// Deterministic background color for a domain-letter avatar. Same
    /// domain always produces the same hue so the user can recognize a
    /// site by its colour across tabs, history, and reopen-closed
    /// surfaces.
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
}

#endif
