// SPDX-License-Identifier: GPL-2.0-or-later
//
// The two sheet builders (history and favorites) and the combined
// segment-picker that hosts them. All three wrap a `PageInfoListView`
// with handlers that route taps back through `openURL` /
// `newTabAction`.

import SwiftUI
import NetSkipModel

#if SKIP || os(iOS)

extension BrowserTabView {
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
                    presentedSheet = nil
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
                    presentedSheet = nil
                } label: {
                    Text("Done", bundle: .module, comment: "done button title")
                        .bold()
                }
            }
        })
    }
}

#endif
