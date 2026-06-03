// SPDX-License-Identifier: GPL-2.0-or-later
//
// The per-page text-zoom adjustment bar. Triggered from the favicon
// menu's Page Zoom entry; lives as a bottom overlay alongside the
// find bar.

import SwiftUI

#if SKIP || os(iOS)

extension BrowserTabView {
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
                bottomOverlay = nil
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

    func pageZoomAction() {
        logger.info("pageZoomAction")
        hapticFeedback()
        bottomOverlay = .pageZoom
    }
}

#endif
