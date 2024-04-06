// This is free software: you can redistribute and/or modify it
// under the terms of the GNU General Public License 3.0
// as published by the Free Software Foundation https://fsf.org
import SwiftUI
import SkipWeb
import NetSkipModel

#if SKIP || os(iOS)

let fallbackURL = URL(string: "file:///tmp/SENTINEL_URL")!

/// The list of tabs that holds a BrowserView
@MainActor public struct BrowserTabView : View {
    let configuration: WebEngineConfiguration
    let store: WebBrowserStore

    @State var tabs: [BrowserViewModel] = []
    @State var selectedTab: PageInfo.ID = PageInfo.ID(0)

    @State var showActiveTabs = false
    @State var showSettings = false
    @State var showHistory = false

    @State var triggerImpact = false
    @State var triggerWarning = false
    @State var triggerError = false
    @State var triggerStart = false
    @State var triggerStop = false

    @AppStorage("appearance") var appearance: String = "" // system
    @AppStorage("buttonHaptics") var buttonHaptics: Bool = true
    @AppStorage("pageLoadHaptics") var pageLoadHaptics: Bool = false
    @AppStorage("searchEngine") var searchEngine: SearchEngine.ID = ""
    @AppStorage("searchSuggestions") var searchSuggestions: Bool = true
    @AppStorage("userAgent") var userAgent: String = ""
    @AppStorage("blockAds") var blockAds: Bool = false
    @AppStorage("enableJavaScript") var enableJavaScript: Bool = true

    public init(configuration: WebEngineConfiguration, store: WebBrowserStore) {
        self.configuration = configuration
        self.store = store
    }

    public var body: some View {
        ZStack {
            if tabs.isEmpty {
                TitleView()
            } else {
                browserTabs
            }
        }
        .task {
            restoreActiveTabs()
        }
        .toolbar {
            #if os(macOS)
            let toolbarPlacement = ToolbarItemPlacement.automatic
            #else
            let toolbarPlacement = ToolbarItemPlacement.bottomBar
            #endif

            ToolbarItemGroup(placement: toolbarPlacement) {
                toolbarButton1()
                Spacer()
                toolbarButton2()
                Spacer()
                moreButton()
                Spacer()
                toolbarButton3()
                Spacer()
                toolbarButton4()
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(configuration: configuration, appearance: $appearance, buttonHaptics: $buttonHaptics, pageLoadHaptics: $pageLoadHaptics, searchEngine: $searchEngine, searchSuggestions: $searchSuggestions, userAgent: $userAgent, blockAds: $blockAds, enableJavaScript: $enableJavaScript)
                #if !SKIP
                .environment(\.openURL, openURLAction(newTab: true))
                #endif
        }
        .sheet(isPresented: $showHistory) {
            PageInfoList(type: PageInfo.PageType.history, store: store, onSelect: { pageInfo in
                logger.info("select history: \(pageInfo.url)")
            }, onDelete: { pageInfos in
                logger.info("delete histories: \(pageInfos.map(\.url))")
            })
        }
        .sheet(isPresented: $showActiveTabs) {
            PageInfoList(type: PageInfo.PageType.active, store: store, onSelect: { pageInfo in
                logger.info("select tab: \(pageInfo.url)")
            }, onDelete: { pageInfos in
                logger.info("delete tabs: \(pageInfos.map(\.url))")
                closeTabs(Set(pageInfos.map(\.id)))
            })
        }
        .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
    }

    var browserTabs: some View {
        /// We need to wrap a separate BrowserView because @AppStorage does not trigger `onChange` events, which we need to synchronize between the browser state and the preferences
        TabView(selection: $selectedTab) {
            ForEach($tabs) { tab in
                BrowserView(configuration: configuration, store: store, submitURL: { self.submitURL(text: $0) }, viewModel: tab, searchEngine: $searchEngine, searchSuggestions: $searchSuggestions, userAgent: $userAgent, blockAds: $blockAds, enableJavaScript: $enableJavaScript)
            }
        }
        #if !SKIP
        .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
        .indexViewStyle(PageIndexViewStyle(backgroundDisplayMode: .automatic))
        .onOpenURL { url in
            openURL(url: url, newTab: true)
        }
        .sensoryFeedback(.start, trigger: triggerStart)
        .sensoryFeedback(.stop, trigger: triggerStop)
        .sensoryFeedback(.impact, trigger: triggerImpact)
        .sensoryFeedback(.warning, trigger: triggerWarning)
        .sensoryFeedback(.error, trigger: triggerError)
        #endif
    }

    func restoreActiveTabs() {
        // restore the saved tabs
        let activeTabs = trying { try store.loadItems(type: PageInfo.PageType.active, ids: []) }

        for activeTab in activeTabs ?? [] {
            logger.log("restoring tab \(activeTab.id): \(activeTab.url) title=\(activeTab.title ?? "")")
            let viewModel = newViewModel(activeTab)
            self.tabs.append(viewModel)
        }
    }

    func newViewModel(_ pageInfo: PageInfo) -> BrowserViewModel {
        let newID = (try? store.saveItems(type: .active, items: [pageInfo]).first) ?? PageInfo.ID(0)
        return BrowserViewModel(id: newID, navigator: WebViewNavigator(initialURL: pageInfo.url), configuration: configuration, store: store)
    }

    #if !SKIP
    func openURLAction(newTab: Bool) -> OpenURLAction {
        OpenURLAction(handler: { url in
            openURL(url: url, newTab: newTab)
            // TODO: reject unsupported URLs
            return OpenURLAction.Result.handled
        })
    }
    #endif

    func openURL(url: URL, newTab: Bool) {
        logger.log("openURL: \(url) newTab=\(newTab)")
        if self.currentViewModel == nil || newTab == true {
            newTabAction() // this will set the current tab
        }
        var newURL = url
        // if the scheme netskip:// then change it to https://
        if url.scheme == "netskip" {
            newURL = URL(string: url.absoluteString.replacingOccurrences(of: "netskip://", with: "https://")) ?? url
        }
        currentNavigator?.load(url: newURL)
    }

    var currentViewModel: BrowserViewModel? {
        tabs.first(where: { $0.id == self.selectedTab })
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

    func toolbarButton1() -> some View {
        backButton()
    }

    func toolbarButton2() -> some View {
        tabListButton()
    }

    func toolbarButton3() -> some View {
        newTabButton()
    }

    func toolbarButton4() -> some View {
        forwardButton()
    }

    @ViewBuilder func backButton() -> some View {
        let enabled = currentState?.canGoBack == true
        let backLabel = Label {
            Text("Back", bundle: .module, comment: "back button label")
        } icon: {
            Image(systemName: "chevron.left")
        }

        if isSkip || !enabled {
            // TODO: SkipUI does not support Menu with primaryAction in toolbar
            Button {
                backAction()
            } label: {
                backLabel
            }
            .disabled(!enabled)
        } else {
            Menu {
                backHistoryMenu()
            } label: {
                backLabel
            } primaryAction: {
                backAction()
            }
            .disabled(!enabled)
            .accessibilityIdentifier("button.back")
        }
    }

    @ViewBuilder func forwardButton() -> some View {
        let enabled = currentState?.canGoForward == true
        let forwardLabel = Label {
            Text("Forward", bundle: .module, comment: "forward button label")
        } icon: {
            Image(systemName: "chevron.right")
        }


        if isSkip || !enabled {
            // TODO: SkipUI does not support Menu with primaryAction in toolbar
            Button {
                forwardAction()
            } label: {
                forwardLabel
            }
            .disabled(!enabled)
        } else {
            Menu {
                forwardHistoryMenu()
            } label: {
                forwardLabel
            } primaryAction: {
                forwardAction()
            }
            .disabled(!enabled)
            .accessibilityIdentifier("button.forward")
        }
    }

    @ViewBuilder func tabListButton() -> some View {
        Menu {
            tabListMenu()
        } label: {
            Label {
                Text("Tab List", bundle: .module, comment: "tab list action label")
            } icon: {
                Image(systemName: "square.on.square")
            }
        } primaryAction: {
            tabListAction()
        }
        .accessibilityIdentifier("button.tablist")
    }

    @ViewBuilder func newTabButton() -> some View {
        Menu {
            Button(action: newPrivateTabAction) {
                Label {
                    Text("New Private Tab", bundle: .module, comment: "more button string for creating a new private tab")
                } icon: {
                    Image(systemName: "plus.square.fill.on.square.fill")
                }
            }
            .accessibilityIdentifier("menu.button.newprivatetab")

            Button(action: newTabAction) {
                Label {
                    Text("New Tab", bundle: .module, comment: "more button string for creating a new tab")
                } icon: {
                    Image(systemName: "plus.square.on.square")
                }
            }
            .accessibilityIdentifier("menu.button.newtab")
        } label: {
            Label {
                Text("New Tab", bundle: .module, comment: "new tab action label")
            } icon: {
                Image(systemName: "plus.square.on.square")
            }
        } primaryAction: {
            newTabAction()
        }
        .accessibilityIdentifier("button.newtab")
    }

    @ViewBuilder func newTabMenu() -> some View {
        // TODO
    }

    @ViewBuilder func tabListMenu() -> some View {
        // TODO
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

    @ViewBuilder func historyItem(item: BackForwardListItem) -> some View {
        Button(item.title?.isEmpty == false ? (item.title ?? "") : item.url.absoluteString) {
            currentViewModel?.navigator.go(item)
        }
    }

    @MainActor func submitURL(text: String) {
        logger.log("URLBar submit")
        if let url = fieldToURL(text),
            ["http", "https", "file", "ftp", "netskip"].contains(url.scheme ?? "") {
            logger.log("loading url: \(url)")
            self.currentNavigator?.load(url: url)
        } else {
            logger.log("URL search bar entry: \(text)")
            if let searchEngine = self.currentSearchEngine,
               let queryURL = searchEngine.queryURL(text, Locale.current.identifier) {
                logger.log("search engine query URL: \(queryURL)")
                if let url = URL(string: queryURL) {
                    self.currentNavigator?.load(url: url)
                }
            }
        }
    }

    /// The currently-selected search engine, or the first search engine in the list if it is unselected
    var currentSearchEngine: SearchEngine? {
        configuration.searchEngines.first { engine in
            engine.id == self.searchEngine
        } ?? configuration.searchEngines.first
    }

    /// The home page URL, which default to the current search engine's home page
    var homeURL: URL? {
        if let homePage = URL(string: currentSearchEngine?.homeURL ?? "https://example.org") {
            return homePage
        } else {
            return nil
        }
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
        if buttonHaptics {
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
        withAnimation {
            self.tabs.removeAll(where: { ids.contains($0.id) })
            // remove the pages from the tab list
            try? store.removeItems(type: .active, ids: ids)
            self.selectedTab = self.tabs.last?.id ?? self.selectedTab
        }
        logTabs()
    }

    func findOnPageAction() {
        logger.info("findOnPageAction")
        hapticFeedback()
        #if !SKIP
        if let interaction = currentWebView?.findInteraction {
            interaction.presentFindNavigator(showingReplace: false)
        }
        #endif
    }

    func newTabAction() {
        logger.info("newTabAction")
        hapticFeedback()
        self.tabs.append(newViewModel(PageInfo(url: homeURL ?? fallbackURL)))
        self.selectedTab = self.tabs.last?.id ?? self.selectedTab
        logTabs()
    }

    func logTabs() {
        #if !SKIP
        logger.info("selected=\(selectedTab) count=\(self.tabs.count) tabs=\(self.tabs.map(\.navigator.webEngine?.webView.url))")
        #else
        logger.info("selected=\(selectedTab) count=\(self.tabs.count)") // cannot traverse nullable key path
        #endif
    }

    func newPrivateTabAction() {
        logger.info("newPrivateTabAction")
        hapticFeedback()
        // TODO
    }

    func tabListAction() {
        logger.info("tabListAction")
        hapticFeedback()
        self.showActiveTabs = true
    }

    func favoriteAction() {
        logger.info("favoriteAction")
        hapticFeedback()
        if let url = currentState?.pageURL, let title = currentState?.pageTitle {
            logger.info("addPageToFavorite: \(title) \(url.absoluteString)")
            trying {
                _ = try store.saveItems(type: .favorite, items: [PageInfo(url: url, title: title)])
            }
        }
    }

    func historyAction() {
        logger.info("historyAction")
        hapticFeedback()
        showHistory = true
    }

    func settingsAction() {
        logger.info("settingsAction")
        hapticFeedback()
        showSettings = true
    }

    func moreButton() -> some View {
        Menu {
            Button(action: newTabAction) {
                Label {
                    Text("New Tab", bundle: .module, comment: "more button string for creating a new tab")
                } icon: {
                    Image(systemName: "plus.square.on.square")
                }
            }
            .accessibilityIdentifier("button.new")

            Button(action: closeTabAction) {
                Label {
                    Text("Close Tab", bundle: .module, comment: "more button string for closing a tab")
                } icon: {
                    Image(systemName: "xmark")
                }
            }
            .accessibilityIdentifier("button.close")

            Divider()

            Button(action: reloadAction) {
                Label {
                    Text("Reload", bundle: .module, comment: "more button string for reloading the current page")
                } icon: {
                    Image(systemName: "arrow.clockwise.circle")
                }
            }
            .accessibilityIdentifier("button.reload")
            Button(action: homeAction) {
                Label(title: {
                    Text("Home", bundle: .module, comment: "home button label")
                }, icon: {
                    Image(systemName: "house")
                })
            }
            .accessibilityIdentifier("button.home")

            Divider()

            Button {
                logger.log("find on page button tapped")
                findOnPageAction()
            } label: {
                Label(title: {
                    Text("Find on Page", bundle: .module, comment: "more button string for finding on the current page")
                }, icon: {
                    Image(systemName: "magnifyingglass")
                })
            }

//            Button {
//                logger.log("text zoom button tapped")
//            } label: {
//                Text("Text Zoom", bundle: .module, comment: "more button string for text zoom")
//            }

//            Button {
//                logger.log("disable blocker button tapped")
//            } label: {
//                Text("Disable Blocker", bundle: .module, comment: "more button string for disabling the blocker")
//            }

            // share button
            ShareLink(item: currentState?.pageURL ?? fallbackURL)
                .disabled(currentState?.pageURL == nil)

            Button(action: favoriteAction) {
                Label {
                    Text("Favorite", bundle: .module, comment: "more button string for adding a favorite")
                } icon: {
                    Image(systemName: "star")
                }
            }
            .accessibilityIdentifier("button.favorite")

            Divider()

            Button(action: historyAction) {
                Label {
                    Text("History", bundle: .module, comment: "more button string for opening the history")
                } icon: {
                    Image(systemName: "calendar")
                }
            }
            .accessibilityIdentifier("button.history")

            Button(action: settingsAction) {
                Label {
                    Text("Settings", bundle: .module, comment: "more button string for opening the settings")
                } icon: {
                    Image(systemName: "gearshape")
                }
            }
            .accessibilityIdentifier("button.settings")
        } label: {
            Label {
                Text("More", bundle: .module, comment: "more button label")
            } icon: {
                Image(systemName: "ellipsis")
            }
            .accessibilityIdentifier("button.more")
        }
    }
}

struct TitleView : View {
    @State var isBeating = false

    var body: some View {
        VStack(alignment: .center, spacing: 25.0) {
            VStack {
                Text("Net Skip", bundle: .module, comment: "title screen headline")
                    .font(Font.system(size: 50, weight: .bold))
                    .lineLimit(1)
                    .foregroundStyle(LinearGradient(colors: [.red, .blue, .green, .yellow], startPoint: .leading, endPoint: .trailing))
//                Text("(a humane web browser)", bundle: .module, comment: "title screen sub-headline")
//                    .font(Font.subheadline.bold())
            }
//            Image(systemName: "heart.fill")
//                .font(.largeTitle)
//                .foregroundStyle(.red)
//                .scaleEffect(isBeating ? 1.5 : 1.0)
//                .animation(.easeInOut(duration: 1).repeatForever(), value: isBeating)
//                .onAppear { isBeating = true }
        }
    }
}

@MainActor struct BrowserView: View {
    let configuration: WebEngineConfiguration
    let store: WebBrowserStore
    let submitURL: (String) -> ()
    @Binding var viewModel: BrowserViewModel

    @Binding var searchEngine: SearchEngine.ID
    @Binding var searchSuggestions: Bool
    @Binding var userAgent: String
    @Binding var blockAds: Bool
    @Binding var enableJavaScript: Bool

    /// Whether content rules are currently enabled
    @State var contentRulesEnabled: Bool = false

    var state: WebViewState {
        self.viewModel.state
    }

    /// Returns the current browser's webview
    var webView: PlatformWebView? {
        self.viewModel.navigator.webEngine?.webView
    }

    var body: some View {
        VStack(spacing: 0.0) {
            WebView(configuration: configuration, navigator: viewModel.navigator, state: $viewModel.state)
                .frame(maxHeight: .infinity)
            URLBar()
            ProgressView(value: state.estimatedProgress ?? 0.0)
                .progressViewStyle(.linear)
                .frame(height: 0.5) // thin progress bar
            //.tint(state.isLoading ? Color.accentColor : Color.clear)
            //.opacity(state.isLoading ? 1.0 : 0.5)
                .opacity(state.estimatedProgress == 0.0 ? 0.0 : (1.0 - (state.estimatedProgress ?? 0.0)))
        }
        .onAppear {
            // synchronize web view with preferences
            updateWebView()
        }
        .onChange(of: enableJavaScript, initial: false, { _, _ in self.updateWebView() })
        .onChange(of: blockAds, initial: false, { _, _ in self.updateWebView() })
        #if !SKIP
        .onReceive(NotificationCenter.default.publisher(for: .webContentRulesLoaded).receive(on: DispatchQueue.main)) { _ in
            logger.log("reveived webContentRulesLoaded")
            // wen content rules are loaded asynchonously, so refresh them when they are loaded
            updateWebView()
        }
        #endif
    }

    /// Synchronize settings with the current platform web view
    private func updateWebView() {
        #if !SKIP
        guard let webView = self.webView else {
            logger.warning("updateWebView: no web view")
            return
        }

        webView.configuration.defaultWebpagePreferences.allowsContentJavaScript = enableJavaScript

        if blockAds == true && self.contentRulesEnabled == false {
            WebContentRuleListStore.default().getAvailableContentRuleListIdentifiers { contentRuleIDs in
                guard let contentRuleID = contentRuleIDs?.first else {
                    logger.log("updateWebView: content rules: no identifiers found")
                    return
                }
                logger.log("updateWebView: content rules: enabling \(contentRuleID)")
                WebContentRuleListStore.default().lookUpContentRuleList(forIdentifier: contentRuleID) { contentRuleList, error in
                    logger.log("updateWebView: lookup content rule \(contentRuleID) \(contentRuleList) \(error)")
                    if let contentRuleList = contentRuleList {
                        DispatchQueue.main.async {
                            logger.log("updateWebView: activating contentRuleList: \(contentRuleList)")
                            webView.configuration.userContentController.add(contentRuleList)
                            self.contentRulesEnabled = true
                        }
                    }
                }
            }
        } else if blockAds == false && self.contentRulesEnabled == true {
            logger.log("updateWebView: content rules: disabling content rules")
            self.contentRulesEnabled = false
            webView.configuration.userContentController.removeAllContentRuleLists()
        }
        #endif
    }

    func updatePageURL(_ oldURL: URL?, _ newURL: URL?) {
        if let newURL = newURL {
            logger.log("changed pageURL to: \(newURL)")
            viewModel.urlTextField = newURL.absoluteString
            if var pageInfo = trying(operation: { try store.loadItems(type: .active, ids: [viewModel.id]) })?.first {
                pageInfo.url = newURL
                _ = trying { try store.saveItems(type: .active, items: [pageInfo]) }
            }
        }
    }

    func updatePageTitle(_ oldTitle: String?, _ newTitle: String?) {
        if let newTitle = newTitle {
            logger.log("loaded page title: \(newTitle)")
            addPageToHistory()
            if var pageInfo = trying(operation: { try store.loadItems(type: .active, ids: [viewModel.id]) })?.first {
                pageInfo.title = newTitle
                _ = trying { try store.saveItems(type: .active, items: [pageInfo]) }
            }
        }
    }

    func URLBar() -> some View {
        URLBarComponent()
            #if !SKIP
            .onChange(of: state.pageURL, updatePageURL)
            .onChange(of: state.pageTitle, updatePageTitle)
            #else
            // workaround onChange() expects an Equatable, which Optional does not conform to
            // https://github.com/skiptools/skip-ui/issues/27
            .onChange(of: state.pageURL ?? fallbackURL) {
                updatePageURL($0, $1)
            }
            .onChange(of: state.pageTitle ?? "SENTINEL_TITLE") {
                updatePageTitle($0, $1)
            }
            #endif
    }

    @ViewBuilder func URLBarComponent() -> some View {
        ZStack {
            TextField(text: $viewModel.urlTextField) {
                Text("URL or search", bundle: .module, comment: "placeholder string for URL bar")
            }
            .textFieldStyle(.roundedBorder)
            //.font(Font.body)
            #if !SKIP
            #if os(iOS)
            .keyboardType(.webSearch)
            .textContentType(.URL)
            .autocorrectionDisabled(true)
            .textInputAutocapitalization(.never)
            //.toolbar {
            //    ToolbarItemGroup(placement: .keyboard) {
            //        Button("Custom Search…") {
            //            logger.log("Clicked Custom Search…")
            //        }
            //    }
            //}
            //.textScale(Text.Scale.secondary, isEnabled: true)
            .onReceive(NotificationCenter.default.publisher(for: UITextField.textDidBeginEditingNotification)) { obj in
                logger.log("received textDidBeginEditingNotification: \(obj.object as? NSObject)")
                if let textField = obj.object as? UITextField {
                    textField.selectAll(nil)
                }
            }
            #endif
            #endif
            .onSubmit(of: .text) {
                self.submitURL(viewModel.urlTextField)
            }
            .padding(6.0)
        }
        #if !SKIP
        // same as the bottom bar background color
        .background(Color(UIColor.systemGroupedBackground))
        #endif
    }

    func addPageToHistory() {
        if let url = state.pageURL, let title = state.pageTitle {
            logger.info("addPageToHistory: \(title) \(url.absoluteString)")
            trying {
                _ = try store.saveItems(type: .history, items: [PageInfo(url: url, title: title)])
            }
        }
    }
}

struct SettingsView : View {
    @ObservedObject var configuration: WebEngineConfiguration

    @Binding var appearance: String
    @Binding var buttonHaptics: Bool
    @Binding var pageLoadHaptics: Bool
    @Binding var searchEngine: SearchEngine.ID
    @Binding var searchSuggestions: Bool
    @Binding var userAgent: String
    @Binding var blockAds: Bool
    @Binding var enableJavaScript: Bool

    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(selection: $appearance) {
                        Text("System", bundle: .module, comment: "settings appearance system label").tag("")
                        Text("Light", bundle: .module, comment: "settings appearance system label").tag("light")
                        Text("Dark", bundle: .module, comment: "settings appearance system label").tag("dark")
                    } label: {
                        Text("Appearance", bundle: .module, comment: "settings appearance picker label").tag("")
                    }

                    Toggle(isOn: $buttonHaptics, label: {
                        Text("Haptic Feedback", bundle: .module, comment: "settings toggle label for button haptic feedback")
                    })
                }

                Section {
                    Picker(selection: $searchEngine) {
                        ForEach(configuration.searchEngines, id: \.id) { engine in
                            Text(verbatim: engine.name())
                                .tag(engine.id)
                        }
                    } label: {
                        Text("Search Engine", bundle: .module, comment: "settings picker label for the default search engine")
                    }

                    Toggle(isOn: $searchSuggestions, label: {
                        Text("Search Suggestions", bundle: .module, comment: "settings toggle label for previewing search suggestions")
                    })
                    // disable when there is no URL available for search suggestions
                    //.disabled(SearchEngine.find(id: searchEngine)?.suggestionURL("", "") == nil)
                }

                Section {
                    Toggle(isOn: $enableJavaScript, label: {
                        Text("Enable JavaScript", bundle: .module, comment: "settings toggle label for enabling JavaScript")
                    })
                    Toggle(isOn: $blockAds, label: {
                        Text("Block Ads", bundle: .module, comment: "settings toggle label for blocking ads")
                    })
                }

                Section {
                    // FIXME: should not need to explicitly specify Base.lproj; it should load as a fallback language automatically
                    let aboutURL = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "about")
                    if let aboutPage = aboutURL {
                        #if !SKIP
                        // FIXME: need Skip support for localizedInfoDictionary / infoDictionary
                        let dict = Bundle.main.localizedInfoDictionary ?? Bundle.main.infoDictionary
                        let appName = dict?["CFBundleDisplayName"] as? String ?? "App"
                        #else
                        let appName = "App"
                        #endif
                        NavigationLink {
                            // Cannot local local resource paths on Android
                            // https://github.com/skiptools/skip-web/issues/1
                            //WebView(url: aboutPage)
                            VStack(spacing: 0.0) {
                                TitleView()
                                WebView(html: (try? String(contentsOf: aboutPage)) ?? "error loading local content")
                            }
                        } label: {
                            Text("About \(appName)", bundle: .module, comment: "settings title menu for about app")
                        }
                    }
                }
            }
            .navigationTitle(Text("Settings", bundle: .module, comment: "settings sheet title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button {
                        self.dismiss()
                    } label: {
                        Text("Done", bundle: .module, comment: "done button title")
                            .bold()
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct PageInfoList : View {
    let type: PageInfo.PageType
    let store: WebBrowserStore
    let onSelect: (PageInfo) -> ()
    let onDelete: ([PageInfo]) -> ()
    @State var items: [PageInfo] = []
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(items) { item in
                    Button(action: {
                        dismiss()
                        onSelect(item)
                    }, label: {
                        VStack(alignment: .leading) {
                            Text(item.title ?? "")
                                .font(.title2)
                                .lineLimit(1)
                            #if !SKIP
                            // SKIP TODO: formatted
                            Text(item.date.formatted())
                                .font(.body)
                                .lineLimit(1)
                            #endif
                            Text(item.url.absoluteString)
                                .font(.caption)
                                .foregroundStyle(Color.gray)
                                .lineLimit(1)
                                #if !SKIP
                                .truncationMode(.middle)
                                #endif
                        }
                    })
                    .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    let deleteItems = offsets.map({
                        items[$0]
                    })
                    let ids = deleteItems.map(\.id)
                    logger.log("deleting \(type.tableName) items: \(ids)")
                    trying {
                        try store.removeItems(type: type, ids: Set(ids))
                    }
                    onDelete(deleteItems)
                    reloadPageInfo()
                }
            }
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button {
                        self.dismiss()
                    } label: {
                        Text("Done", bundle: .module, comment: "done button title")
                            .bold()
                    }
                    .buttonStyle(.plain)
                }
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        logger.log("clearing \(type.tableName)")
                        trying {
                            try store.removeItems(type: type, ids: [])
                            onDelete(items)
                            reloadPageInfo()
                        }
                        dismiss()
                    } label: {
                        type.clearTitle.bold()
                    }
                    .buttonStyle(.plain)
                    .disabled(items.isEmpty)
                }
            }
            .navigationTitle(type.navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            reloadPageInfo()
        }
    }

    func reloadPageInfo() {
        let items = trying {
            try store.loadItems(type: type, ids: [])
        }
        if let items = items {
            self.items = items
        }
    }
}

extension PageInfo.PageType {
    var navigationTitle: Text {
        switch self {
        case .history: return Text("History", bundle: .module, comment: "history page list sheet title")
        case .favorite: return Text("Favorites", bundle: .module, comment: "favorites page list sheet title")
        case .active: return Text("Tabs", bundle: .module, comment: "active tabs sheet title")
        }
    }

    var clearTitle: Text {
        switch self {
        case .history: return Text("Clear History", bundle: .module, comment: "history page remove all sheet title")
        case .favorite: return Text("Remove all Favorites", bundle: .module, comment: "favorites page remove all sheet title")
        case .active: return Text("Close All", bundle: .module, comment: "active tabs remove all title")
        }
    }
}

@Observable public class BrowserViewModel: Identifiable {
    /// The persistent ID of the page
    public let id: PageInfo.ID
    let navigator: WebViewNavigator
    let configuration: WebEngineConfiguration
    let store: WebBrowserStore
    var state = WebViewState()
    var urlTextField = ""

    public init(id: PageInfo.ID, navigator: WebViewNavigator, configuration: WebEngineConfiguration, store: WebBrowserStore) {
        self.id = id
        self.navigator = navigator
        self.configuration = configuration
        self.store = store
    }
}

func trying<T>(operation: () throws -> T) -> T? {
    do {
        return try operation()
    } catch {
        logger.error("error performing operation: \(error)")
        return nil
    }
}

var isSkip: Bool {
    #if SKIP
    true
    #else
    false
    #endif
}
#endif

