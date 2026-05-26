// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
#if SKIP || os(iOS)
import SkipWeb
#endif
import NetSkipModel

#if SKIP
// Compose dp extension, used below to compact the Android bottom toolbar
// via the Material 3 BottomAppBar env override.
import androidx.compose.ui.unit.dp
#endif

public struct ContentView: View {
    #if SKIP || os(iOS)
    /// Shared Android blocker that reads category toggles and custom patterns
    /// from `UserDefaults` on every request, so settings changes take effect
    /// on the next resource load.
    static let adBlockProvider = NetSkipAdBlockProvider()

    let config: WebEngineConfiguration = {
        return WebEngineConfiguration(
            javaScriptEnabled: true,
            contentBlockers: netSkipMakeContentBlockerConfiguration(provider: ContentView.adBlockProvider)
        )
    }()
    #endif
    let store = try! NetSkipWebBrowserStore(url: URL.documentsDirectory.appendingPathComponent("netskip.sqlite"))

    public init() {
    }

    public var body: some View {
        navigationContent
    }

    @ViewBuilder
    private var navigationContent: some View {
        let stack = NavigationStack {
            #if SKIP || os(iOS)
            BrowserTabView(configuration: config, store: store)
                #if SKIP
                .toolbar(.hidden, for: .navigationBar)
                #endif
            #else
            Text("Net Skip requires iOS")
            #endif
        }
        #if SKIP
        // Shrink the Material 3 BottomAppBar's inner Row to the iOS UIToolbar height (44pt),
        // so the URL bar sitting just above the toolbar is visually flush with the icons
        // instead of separated by ~22dp of dead space from Material 3's 80dp default.
        // Applied OUTSIDE the NavigationStack so the env reaches the Scaffold's bottomBar slot
        // (env applied on the navigation content only flows into the content slot, not siblings).
        stack.material3BottomAppBar { options in
            options.copy(containerHeight: 44.dp)
        }
        #else
        stack
        #endif
    }
}

