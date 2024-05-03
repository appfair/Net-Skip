// This is free software: you can redistribute and/or modify it
// under the terms of the GNU General Public License 3.0
// as published by the Free Software Foundation https://fsf.org

import SwiftUI
import SkipWeb
import NetSkipModel

public struct ContentView: View {
    let config = WebEngineConfiguration(javaScriptEnabled: true)
    let store = try! NetSkipWebBrowserStore(url: URL.documentsDirectory.appendingPathComponent("netskip.sqlite"))

    public init() {
    }

    public var body: some View {
        NavigationStack {
            #if SKIP || os(iOS)
            BrowserTabView(configuration: config, store: store)
                #if SKIP
                // eliminate blank space on Android: https://github.com/skiptools/skip/issues/99#issuecomment-2010650774
                .toolbar(.hidden, for: .navigationBar)
                #endif
            #endif
        }
        .task {
            await loadContentBlockerRules()
        }
    }

    @MainActor func loadContentBlockerRules() async {
        #if !SKIP
        // Content blocker from a source like:
        // https://github.com/brave/brave-core/blob/master/ios/brave-ios/Sources/Brave/WebFilters/ContentBlocker/Lists/block-ads.json
        guard let ruleListStore = WebContentRuleListStore.default() else { return }

        for blockerID in [
            "block-ads",
            // "block-cookies", // TODO: add block cookies preference
        ] {
            if let blockerURL = Bundle.module.url(forResource: blockerID, withExtension: "json") {
                logger.info("loading content blocker rules from: \(blockerURL)")
                do {
                    let blockerContents = try String(contentsOf: blockerURL)
                    let ruleList = try await ruleListStore.compileContentRuleList(forIdentifier: blockerID, encodedContentRuleList: blockerContents)
                    let ids = await ruleListStore.availableIdentifiers()
                    logger.info("loaded content blocker rule list: \(ruleList) ids=\(ids ?? [])")
                    NotificationCenter.default.post(name: .webContentRulesLoaded, object: blockerID)
                } catch {
                    logger.error("error loading content blocker rules from \(blockerURL): \(error)")
                }
            }
        }
        #endif
    }
}
