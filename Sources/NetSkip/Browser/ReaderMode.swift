// SPDX-License-Identifier: GPL-2.0-or-later
//
// Reader Mode — strips clutter from the current page using Mozilla
// Readability.js (Apache 2.0, bundled at
// `Resources/Readability.js`) and replaces the live DOM with a
// reader-friendly article view.
//
// Toggling reader mode runs entirely inside the WebView via a JS
// evaluate(); no native UI replaces the WebView, so reader mode is
// invisible to the rest of the app and behaves identically on iOS
// (WKWebView) and Android.
//
// **Updating Readability.js** — see `Resources/Readability.update.md`.

import SwiftUI
import SkipWeb

#if SKIP || os(iOS)

extension BrowserTabView {
    /// Toggle reader mode for the currently-selected tab. Activating
    /// extracts the article via Readability.js and rewrites the DOM
    /// in place; deactivating just reloads the original URL so the
    /// page returns from its own cache.
    func toggleReaderModeAction() {
        guard let vm = currentViewModel else { return }
        logger.info("toggleReaderModeAction wasInReaderMode=\(vm.inReaderMode)")
        hapticFeedback()
        if vm.inReaderMode {
            vm.inReaderMode = false
            isCurrentPageInReaderMode = false
            vm.navigator.reload()
            return
        }
        // Optimistically flip both the per-view-model flag and the
        // parent's `@State` mirror so the menu label updates
        // immediately; if the JS injection later reports it couldn't
        // find an article we flip both back.
        vm.inReaderMode = true
        isCurrentPageInReaderMode = true
        Task { @MainActor in
            let ok = await Self.applyReaderMode(to: vm)
            if !ok {
                vm.inReaderMode = false
                isCurrentPageInReaderMode = false
            }
        }
    }

    /// Inject Readability.js into the live page, run it against a
    /// clone of the document, and replace `<head>`/`<body>` with the
    /// extracted article wrapped in a clean reader stylesheet.
    ///
    /// Returns `true` on success, `false` when Readability couldn't
    /// find a recognisable article (so the caller can revert the
    /// reader-mode flag and leave the live page visible).
    @MainActor
    static func applyReaderMode(to vm: BrowserViewModel) async -> Bool {
        guard let engine = vm.navigator.webEngine else { return false }
        let readabilitySource = loadReadabilitySource()
        guard !readabilitySource.isEmpty else {
            logger.warning("applyReaderMode: Readability.js source is empty — bundle resource missing?")
            return false
        }
        let payload = readerModeInjectionJS(readabilitySource: readabilitySource)
        do {
            let result = try await engine.evaluate(js: payload)
            // The injected wrapper returns the literal string `OK` on
            // success and an error tag (`EMPTY`, `FAILED:...`) when
            // Readability didn't find an article. WKWebView's
            // `evaluateJavaScript` JSON-encodes string returns, so the
            // value comes back wrapped in surrounding `"` characters
            // on iOS; Android's WebView returns the bare string.
            // Normalise both shapes before comparing.
            var token = result ?? ""
            if token.hasPrefix("\"") && token.hasSuffix("\"") && token.count >= 2 {
                token = String(token.dropFirst().dropLast())
            }
            if token == "OK" {
                return true
            }
            logger.info("applyReaderMode: Readability returned \(token); leaving live page in place")
            return false
        } catch {
            logger.warning("applyReaderMode: evaluate failed: \(error)")
            return false
        }
    }

    /// Read the bundled `Readability.js` once and cache the result —
    /// the file is ~95 KB and re-reading on every toggle is wasteful.
    static func loadReadabilitySource() -> String {
        if let cached = readabilityCache {
            return cached
        }
        guard let url = Bundle.module.url(forResource: "Readability", withExtension: "js"),
              let data = try? Data(contentsOf: url),
              let source = String(data: data, encoding: .utf8) else {
            return ""
        }
        readabilityCache = source
        return source
    }

    /// Wraps the bundled Readability.js source in an IIFE that
    /// extracts the article, paints a minimal reader stylesheet, and
    /// rewrites `<head>` / `<body>` in place. We do the HTML assembly
    /// inside JS rather than on the Swift side so we don't have to
    /// escape user-controlled article content twice.
    static func readerModeInjectionJS(readabilitySource: String) -> String {
        return """
        (function() {
            \(readabilitySource)
            function escapeHTML(s) {
                return String(s == null ? '' : s)
                    .replace(/&/g, '&amp;')
                    .replace(/</g, '&lt;')
                    .replace(/>/g, '&gt;')
                    .replace(/"/g, '&quot;');
            }
            var article;
            try {
                var clone = document.cloneNode(true);
                article = new Readability(clone).parse();
            } catch (e) {
                return 'FAILED:' + (e && e.message ? e.message : 'unknown');
            }
            if (!article || !article.content) {
                return 'EMPTY';
            }
            var title = escapeHTML(article.title || document.title || '');
            var byline = article.byline ? '<p class="byline">' + escapeHTML(article.byline) + '</p>' : '';
            var siteName = article.siteName ? '<p class="site">' + escapeHTML(article.siteName) + '</p>' : '';
            var bodyHTML =
                '<article class="reader">' +
                '<header><h1>' + title + '</h1>' + siteName + byline + '</header>' +
                article.content +
                '</article>';
            var styleHTML =
                '<style>' +
                ':root { color-scheme: light dark; }' +
                'html, body { margin: 0; padding: 0; }' +
                'body { font-family: -apple-system, system-ui, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; ' +
                '       line-height: 1.6; font-size: 17px; color: #222; background: #fafafa; ' +
                '       max-width: 36em; padding: 1.5em 1em 4em; margin: 0 auto; }' +
                'article.reader h1 { font-size: 1.7em; line-height: 1.25; margin: 0 0 0.4em; }' +
                'article.reader .site { font-size: 0.85em; color: #888; margin: 0 0 0.2em; text-transform: uppercase; letter-spacing: 0.04em; }' +
                'article.reader .byline { font-size: 0.95em; color: #666; margin: 0 0 1.4em; }' +
                'article.reader p { margin: 1em 0; }' +
                'article.reader img, article.reader video { max-width: 100%; height: auto; display: block; margin: 1em auto; }' +
                'article.reader a { color: #0a58ca; text-decoration: none; border-bottom: 1px solid rgba(10,88,202,0.35); }' +
                'article.reader blockquote { border-left: 3px solid #cfd6e4; margin: 1em 0; padding: 0.1em 1em; color: #555; }' +
                'article.reader pre, article.reader code { font-family: ui-monospace, "SF Mono", Menlo, Consolas, monospace; background: #eef0f4; border-radius: 4px; }' +
                'article.reader pre { padding: 0.8em 1em; overflow-x: auto; font-size: 0.9em; }' +
                'article.reader code { padding: 0.1em 0.3em; font-size: 0.92em; }' +
                'article.reader figure { margin: 1.4em 0; }' +
                'article.reader figcaption { font-size: 0.85em; color: #777; text-align: center; margin-top: 0.4em; }' +
                '@media (prefers-color-scheme: dark) {' +
                '  body { color: #e7e7e7; background: #161616; }' +
                '  article.reader .site { color: #888; }' +
                '  article.reader .byline { color: #aaa; }' +
                '  article.reader a { color: #6ea8ff; border-bottom-color: rgba(110,168,255,0.35); }' +
                '  article.reader blockquote { border-left-color: #3a3f4d; color: #ccc; }' +
                '  article.reader pre, article.reader code { background: #23262b; }' +
                '}' +
                '</style>';
            document.head.innerHTML = styleHTML + '<title>' + title + '</title><meta name="viewport" content="width=device-width, initial-scale=1.0">';
            document.body.innerHTML = bodyHTML;
            document.documentElement.setAttribute('data-reader-mode', 'on');
            return 'OK';
        })()
        """
    }

    /// Shared cache of the Readability.js source. `nonisolated(unsafe)`
    /// is safe here: the cache is read on the main actor (every
    /// toggle is dispatched there) and the initial fill is racy only
    /// in the harmless way — two parallel fills produce the same
    /// string.
    nonisolated(unsafe) private static var readabilityCache: String? = nil
}

#endif
