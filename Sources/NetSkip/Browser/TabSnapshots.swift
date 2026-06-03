// SPDX-License-Identifier: GPL-2.0-or-later
//
// Per-tab snapshot helpers (write/load/remove). The actual capture
// runs on `BrowserViewModel.captureSnapshot()` so we get pixels
// from the live WKWebView before SwiftUI dismantles it.

import SwiftUI
import NetSkipModel

#if SKIP || os(iOS)

extension BrowserTabView {
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
}

#endif
