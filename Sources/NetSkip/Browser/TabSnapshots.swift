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
        // Private tabs are never snapshotted. `captureSnapshot()`
        // writes a PNG of the live WebView to `Caches/tab-snapshots/`,
        // and we don't want any private-mode pixels reaching disk
        // — the OS can delete cache files at any time, but they
        // sit there for the meantime and would be readable to anyone
        // with file-system access.
        if tab.isPrivate { return }
        Task { @MainActor in
            await tab.captureSnapshot()
        }
    }

    func captureAllTabSnapshots() {
        for tab in tabs {
            if tab.isPrivate { continue }
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
