// SPDX-License-Identifier: GPL-2.0-or-later
//
// Find-on-page UI + JavaScript bridge. On iOS we prefer the native
// `WKWebView.findInteraction` when available; the in-app `findBar`
// view is the cross-platform fallback (always used on Android).

import SwiftUI
#if !SKIP
import UIKit
#endif

#if SKIP || os(iOS)

extension BrowserTabView {
    @ViewBuilder func findBar() -> some View {
        HStack(spacing: 8) {
            // The `TextField("…", text:)` shorthand resolves the
            // placeholder against the main bundle, so our module's
            // xcstrings translations for "Find on page" were never
            // picked up. The `text:prompt:label:` form lets us pass
            // an explicit bundle-aware `Text` so non-English locales
            // get the translated placeholder; the label doubles as
            // the VoiceOver / TalkBack name for the field.
            TextField(text: $findText, prompt: Text("Find on page", bundle: .module, comment: "placeholder text inside the find-on-page text field")) {
                Text("Find on page", bundle: .module, comment: "accessibility name for the find-on-page text field")
            }
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                #if !SKIP
                .autocorrectionDisabled(true)
                #endif
                .onSubmit {
                    executeFindOnPage(findText)
                }
                .onChange(of: findText, initial: false) { _, newValue in
                    Task { @MainActor in
                        await countFindMatches(newValue)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.gray.opacity(0.15))
                .cornerRadius(8)
                .accessibilityIdentifier("field.findOnPage")

            if !findText.isEmpty {
                Text(findMatchCount == 0 ? "No matches" : "\(findMatchCount)", bundle: .module, comment: "find-on-page match-count label: number of matches or the literal 'No matches' phrase")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(findMatchCount == 0 ? Color.red : Color.secondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("label.findOnPage.count")
            }

            Button(action: {
                executeFindOnPage(findText, backwards: true)
            }) {
                Image("arrow_back_ios_new", bundle: .module)
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(findText.isEmpty || findMatchCount == 0)
            .accessibilityIdentifier("button.findOnPage.previous")
            .accessibilityLabel(Text("Previous match", bundle: .module, comment: "accessibility label for the find-on-page Previous-match button"))

            Button(action: {
                executeFindOnPage(findText, backwards: false)
            }) {
                Image("arrow_forward_ios", bundle: .module)
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(findText.isEmpty || findMatchCount == 0)
            .accessibilityIdentifier("button.findOnPage.next")
            .accessibilityLabel(Text("Next match", bundle: .module, comment: "accessibility label for the find-on-page Next-match button"))

            Button(action: {
                clearFindHighlights()
                bottomOverlay = nil
                findText = ""
            }) {
                Image("xmark", bundle: .module)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("button.findOnPage.close")
            .accessibilityLabel(Text("Close find on page", bundle: .module, comment: "accessibility label for the find-on-page close button"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        // Explicit height matches the bottom toolbar — Compose's
        // VStack on Android otherwise hands all available space to
        // `browserTabView()`'s `.frame(maxHeight: .infinity)` and the
        // find bar collapses to zero pixels.
        .frame(height: 48.0)
        .background(Color(white: 0.95))
    }

    func findOnPageAction() {
        logger.info("findOnPageAction")
        hapticFeedback()
        #if !SKIP
        if let interaction = currentWebView?.findInteraction {
            interaction.presentFindNavigator(showingReplace: false)
            return
        }
        #endif
        // Fallback: show the custom find bar (used on Android, or
        // iOS without findInteraction).
        bottomOverlay = .findBar
        findText = ""
    }

    func executeFindOnPage(_ text: String) {
        executeFindOnPage(text, backwards: false)
    }

    /// Advances the in-page selection to the next or previous match of
    /// `text`. The `window.find` JS API takes
    /// `(text, caseSensitive, backwards, wrapAround)` — passing
    /// `backwards: true` walks matches in reverse so consecutive taps
    /// step backward through the page, with wrap-around so the buttons
    /// keep working at either end.
    func executeFindOnPage(_ text: String, backwards: Bool) {
        guard !text.isEmpty else { return }
        if let engine = currentViewModel?.navigator.webEngine {
            let backwardsArg = backwards ? "true" : "false"
            Task {
                _ = try? await engine.evaluate(js: "window.find('\(text.replacingOccurrences(of: "'", with: "\\'"))', false, \(backwardsArg), true)")
            }
        }
    }

    func clearFindHighlights() {
        if let engine = currentViewModel?.navigator.webEngine {
            Task {
                _ = try? await engine.evaluate(js: "window.getSelection().removeAllRanges()")
            }
        }
    }

    /// Count case-insensitive occurrences of `text` in the page's
    /// rendered text and publish the result to `findMatchCount` for
    /// the find-bar's count label. Empty queries reset the count to
    /// zero so the label disappears.
    @MainActor
    func countFindMatches(_ text: String) async {
        guard !text.isEmpty else {
            findMatchCount = 0
            return
        }
        guard let engine = currentViewModel?.navigator.webEngine else { return }
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let js = """
        (function() {
            var needle = '\(escaped)'.toLowerCase();
            if (!needle) return 0;
            var hay = (document.body && document.body.innerText) ? document.body.innerText.toLowerCase() : '';
            var count = 0;
            var pos = 0;
            while ((pos = hay.indexOf(needle, pos)) !== -1) {
                count++;
                pos += needle.length;
            }
            return count;
        })()
        """
        do {
            let result = try await engine.evaluate(js: js)
            if let value = result, let count = Int(value) {
                findMatchCount = count
            }
        } catch {
            // ignore — leave the previous count in place
        }
    }
}

#endif
