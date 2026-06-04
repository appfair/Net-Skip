// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
#if SKIP || os(iOS)
import SkipWeb
#endif
import NetSkipModel

public struct ContentView: View {
    #if SKIP || os(iOS)
    /// Shared Android blocker that reads category toggles and custom patterns
    /// from `UserDefaults` on every request, so settings changes take effect
    /// on the next resource load.
    static let adBlockProvider = AdBlockProvider()

    let config: WebEngineConfiguration = {
        return WebEngineConfiguration(
            javaScriptEnabled: true,
            contentBlockers: makeContentBlockerConfiguration(provider: ContentView.adBlockProvider)
        )
    }()

    /// Shared configuration for every private tab. `profile: .ephemeral`
    /// hands each web view a fresh `WKWebsiteDataStore.nonPersistent()`
    /// on iOS (or an in-memory Android WebView profile when supported),
    /// so cookies / local storage / cache set during private browsing
    /// never touch disk and never bleed into the regular session.
    let privateConfig: WebEngineConfiguration = {
        return WebEngineConfiguration(
            javaScriptEnabled: true,
            profile: .ephemeral,
            contentBlockers: makeContentBlockerConfiguration(provider: ContentView.adBlockProvider)
        )
    }()
    #endif
    let store = try! SQLBrowserStore(url: URL.documentsDirectory.appendingPathComponent("netskip.sqlite"))

    @State private var settings = BrowserSettings()

    public init() {
    }

    public var body: some View {
        #if SKIP || os(iOS)
        BrowserTabView(configuration: config, privateConfiguration: privateConfig, store: store)
            .environment(settings)
        #else
        Text("Browser requires iOS")
            .environment(settings)
        #endif
    }
}
