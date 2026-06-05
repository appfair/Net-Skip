// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import NetSkipModel

#if SKIP || os(iOS)
import SkipWeb

struct PageInfoListView<ToolbarItems : ToolbarContent> : View {
    let type: PageInfo.PageType
    let store: WebBrowserStore
    let onSelect: (PageInfo) -> ()
    let onDelete: ([PageInfo]) -> ()
    let onOpenInNewTab: (PageInfo) -> ()
    /// Optional bulk action — when non-nil, an "Open All in Tabs" button is
    /// rendered at the top of the list. Used by the Favorites view to let
    /// the user fire off every saved bookmark as separate tabs in one
    /// gesture. History intentionally omits this since it would create
    /// hundreds of tabs.
    let onOpenAllInTabs: (([PageInfo]) -> ())?
    let toolbarItems: () -> ToolbarItems
    @State var items: [PageInfo] = []
    @State var searchText: String = ""
    @Environment(\.dismiss) var dismiss

    /// Case-insensitive substring filter over title + URL. Empty query
    /// returns all items so search becomes the no-op pass-through.
    var filteredItems: [PageInfo] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return items
        }
        let needle = trimmed.lowercased()
        return items.filter { item in
            if let title = item.title, title.lowercased().contains(needle) {
                return true
            }
            if let url = item.url, url.lowercased().contains(needle) {
                return true
            }
            return false
        }
    }

    func loadPageInfoItems() {
        let items = trying {
            try store.loadItems(type: type, ids: [])
        }
        if let items = items {
            self.items = items
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !items.isEmpty {
                searchField
                if onOpenAllInTabs != nil {
                    openAllButton
                }
            }
            if items.isEmpty {
                // Friendlier empty state — icon + title + hint —
                // instead of a bare "No Items" label. Matches Safari
                // / Chrome empty-list treatments.
                VStack(spacing: 14) {
                    Spacer()
                    Image(type == .favorite ? "star" : "history", bundle: .module)
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text(type == .favorite ? "No Favorites Yet" : "No History Yet", bundle: .module, comment: "title shown in the History or Favorites sheet when there are zero entries")
                        .font(.title2)
                        .foregroundStyle(.primary)
                    Text(type == .favorite ? "Tap the star in the More menu to favorite the page you're on." : "Pages you visit will appear here.", bundle: .module, comment: "supporting copy below the empty-state title in the History or Favorites sheet")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredItems.isEmpty {
                Text("No matches", bundle: .module, comment: "shown in the History/Favorites list when the active search filter has zero results")
                    .font(.title3)
                    .opacity(0.7)
                    .frame(maxHeight: .infinity)
            } else {
                itemsListView
            }
        }
        .onAppear {
            loadPageInfoItems()
        }
        .onChange(of: type) {
            loadPageInfoItems()
        }
        .toolbar {
            #if !SKIP
            // Skip is unable to match this API call to determine whether it results in a View. Consider adding additional type information
            self.toolbarItems()
            #else
            ToolbarItem(placement: .bottomBar) {
                Button {
                    logger.log("clearing \(type.tableName)")
                    trying {
                        try store.removeItems(type: type, ids: [])
                        onDelete(items)
                        loadPageInfoItems()
                    }
                    dismiss()
                } label: {
                    type.clearTitle.bold()
                }
                .buttonStyle(.plain)
                .disabled(items.isEmpty)
            }
            #endif
        }
        .navigationTitle(type.navigationTitle)
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    @ViewBuilder
    var openAllButton: some View {
        Button {
            let action = onOpenAllInTabs
            let toOpen = filteredItems
            dismiss()
            action?(toOpen)
        } label: {
            HStack(spacing: 8) {
                Image("plus.square.on.square", bundle: .module)
                Text("Open All in Tabs", bundle: .module, comment: "button label that opens every filtered Favorites row in a separate tab")
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(Color.accentColor.opacity(0.12))
            .foregroundStyle(Color.accentColor)
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .accessibilityIdentifier("button.pageInfo.openAllInTabs")
    }

    @ViewBuilder
    var searchField: some View {
        HStack(spacing: 8) {
            Image("magnifyingglass", bundle: .module)
                .foregroundStyle(.secondary)
                .font(.system(size: 14))
            TextField(text: $searchText, prompt: Text("Search", bundle: .module, comment: "placeholder text for the History / Favorites filter field")) {
                Text("Search", bundle: .module, comment: "accessibility label for the History / Favorites filter field")
            }
            .textFieldStyle(.plain)
            .font(.system(size: 15))
            #if !SKIP
            .autocorrectionDisabled(true)
            .textInputAutocapitalization(.never)
            #endif
            .accessibilityIdentifier("field.pageInfo.search")

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image("xmark.circle.fill", bundle: .module)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("button.pageInfo.search.clear")
                .accessibilityLabel(Text("Clear search", bundle: .module, comment: "accessibility label for the clear-search button in the History/Favorites list"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.gray.opacity(0.12))
        .cornerRadius(10)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    var itemsListView: some View {
        List {
            if type == PageInfo.PageType.history {
                ForEach(groupedHistoryItems, id: \.bucket) { group in
                    Section {
                        ForEach(group.items) { item in
                            itemRow(item: item)
                        }
                        .onDelete { offsets in
                            deleteItems(group.items.enumerated().compactMap { offsets.contains($0.offset) ? $0.element : nil })
                        }
                    } header: {
                        historyBucketHeader(for: group.bucket)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                            #if !SKIP
                            .textCase(nil)
                            #endif
                    }
                }
            } else {
                ForEach(filteredItems) { item in
                    itemRow(item: item)
                }
                .onDelete { offsets in
                    // Index into the visible (filtered) list — otherwise a
                    // swipe-to-delete on a filtered row would delete the
                    // wrong entry from the underlying store.
                    let visible = filteredItems
                    deleteItems(offsets.map({ visible[$0] }))
                }
            }
        }
    }

    @ViewBuilder
    func itemRow(item: PageInfo) -> some View {
        Button(action: {
            dismiss()
            onSelect(item)
        }, label: {
            HStack(spacing: 12) {
                // Favicon for the page's domain on the leading edge,
                // matching the URL bar's identity treatment. Falls
                // back to the captive_portal placeholder while the
                // network fetch resolves.
                FaviconView(urlString: item.url, size: 20.0, cornerRadius: 4.0)
                VStack(alignment: .leading) {
                    itemTitle(item: item)
                        .font(.body)
                        .lineLimit(1)
                    Text(item.url ?? "")
                        .font(.caption)
                        .foregroundStyle(Color.gray)
                        .lineLimit(1)
                        #if !SKIP
                        .truncationMode(.middle)
                        #endif
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            #if !SKIP
            .contentShape(Rectangle()) // needed to make the tap target fill the area
            #endif
        })
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                dismiss()
                onOpenInNewTab(item)
            } label: {
                Label {
                    Text("Open in New Tab", bundle: .module, comment: "context menu label on a History/Favorites row that opens the URL in a fresh background tab")
                } icon: {
                    Image("plus.square.on.square", bundle: .module)
                }
            }
            .accessibilityIdentifier("menu.pageInfo.openInNewTab")
        }
    }

    func deleteItems(_ pageInfos: [PageInfo]) {
        let ids = pageInfos.map(\.id)
        logger.log("deleting \(type.tableName) items: \(ids)")
        trying {
            try store.removeItems(type: type, ids: Set(ids))
        }
        onDelete(pageInfos)
        loadPageInfoItems()
    }

    /// Bucket index 0–3 for a history entry: 0=Today, 1=Yesterday,
    /// 2=Last 7 Days, 3=Older. Same buckets every desktop browser uses
    /// in its History panel.
    func historyBucketIndex(for date: Date) -> Int {
        // Compute days-since by normalizing both sides to midnight via
        // `Calendar.startOfDay(for:)`. Skip's Calendar doesn't yet
        // bridge `isDateInYesterday`/`isDateInToday`, so this manual
        // form is the cross-platform-safe path.
        let cal = Calendar.current
        let nowStart = cal.startOfDay(for: Date())
        let itemStart = cal.startOfDay(for: date)
        let interval = nowStart.timeIntervalSince(itemStart)
        let days = Int(interval / 86400.0)
        if days <= 0 { return 0 }
        if days == 1 { return 1 }
        if days <= 7 { return 2 }
        return 3
    }

    /// Localized section-header `Text` for a history date bucket.
    /// One literal `Text(_:bundle:comment:)` per branch so the String
    /// Catalog extractor sees each header key.
    @ViewBuilder
    func historyBucketHeader(for bucket: Int) -> some View {
        switch bucket {
        case 0:
            Text("Today", bundle: .module, comment: "history list date-section header for pages visited today")
        case 1:
            Text("Yesterday", bundle: .module, comment: "history list date-section header for pages visited yesterday")
        case 2:
            Text("Last 7 Days", bundle: .module, comment: "history list date-section header for pages visited in the past week")
        default:
            Text("Older", bundle: .module, comment: "history list date-section header for pages older than a week")
        }
    }

    /// `filteredItems` partitioned into the four history buckets,
    /// dropping any empty bucket so the list doesn't carry a stranded
    /// "Older" header when the user only has fresh history. Items
    /// inside each bucket are sorted newest-first.
    var groupedHistoryItems: [(bucket: Int, items: [PageInfo])] {
        var buckets: [Int: [PageInfo]] = [:]
        for item in filteredItems {
            let key = historyBucketIndex(for: item.date)
            if buckets[key] == nil {
                buckets[key] = []
            }
            buckets[key]?.append(item)
        }
        var result: [(bucket: Int, items: [PageInfo])] = []
        for key in 0...3 {
            if let items = buckets[key], !items.isEmpty {
                let sorted = items.sorted(by: { $0.date > $1.date })
                result.append((bucket: key, items: sorted))
            }
        }
        return result
    }

    func itemTitle(item: PageInfo) -> some View {
        if let title = item.title {
            return Text(title)
        } else {
            return Text("Empty Page", bundle: .module, comment: "item list title for a page with no title")
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

#endif
