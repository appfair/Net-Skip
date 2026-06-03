// SPDX-License-Identifier: GPL-2.0-or-later
//
// URL-bar submit pipeline. Handles the parse-as-URL / fall-back-to-
// search heuristic, the bare-host normalization, the HTTPS upgrade,
// and the local-host exclusion list.

import SwiftUI
import NetSkipModel

#if SKIP || os(iOS)

extension BrowserTabView {
    @MainActor func submitURL(text: String) {
        logger.log("URLBar submit")
        if let parsedURL = fieldToURL(text),
            ["http", "https", "file", "ftp", "netskip"].contains(parsedURL.scheme ?? "") {
            // HTTPS upgrade — when the user typed/pasted a bare `http://`
            // URL and the setting is on, rewrite it to `https://` before
            // dispatching. Localhost and IP literals are left alone since
            // those are typically explicitly chosen by developers.
            let finalURL: URL = Self.maybeUpgradeToHTTPS(parsedURL, enabled: settings.upgradeToHTTPS)
            logger.log("loading url: \(finalURL)")
            self.currentNavigator?.load(url: finalURL)
        } else {
            logger.log("URL search bar entry: \(text)")
            if let searchEngine = SearchEngine.lookup(id: settings.searchEngine),
               let queryURL = searchEngine.queryURL(text, Locale.current.identifier) {
                logger.log("search engine query URL: \(queryURL)")
                if let url = URL(string: queryURL) {
                    self.currentNavigator?.load(url: url)
                }
            }
        }
    }

    /// The home page URL — the user's custom `customHomeURL` setting
    /// if set (accepting either a fully-qualified URL or a bare host
    /// that we prepend `https://` to), otherwise the active search
    /// engine's home page.
    var homeURL: URL? {
        let trimmed = settings.customHomeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            if let parsed = URL(string: trimmed), parsed.scheme != nil {
                return parsed
            }
            if let prefixed = URL(string: "https://" + trimmed), prefixed.host != nil {
                return prefixed
            }
        }
        if let homePage = SearchEngine.lookup(id: settings.searchEngine)?.homeURL,
           let homePageURL = URL(string: homePage) {
            return homePageURL
        } else {
            return nil
        }
    }

    /// Returns the URL with its scheme rewritten from `http` to `https`
    /// when the setting is enabled and the host isn't a developer-style
    /// local target. Returns the input unchanged otherwise.
    static func maybeUpgradeToHTTPS(_ url: URL, enabled: Bool) -> URL {
        if !enabled { return url }
        if url.scheme != "http" { return url }
        guard let host = url.host, !isLocalOrIPHost(host) else { return url }
        let str = url.absoluteString
        if str.hasPrefix("http://") {
            let upgraded = "https://" + String(str.dropFirst("http://".count))
            if let result = URL(string: upgraded) {
                return result
            }
        }
        return url
    }

    /// Hosts that should *not* be auto-upgraded to HTTPS — the
    /// developer almost certainly meant to hit them in cleartext.
    /// Covers `localhost` (with any port), single-label hostnames
    /// (no dot), and IPv4 dotted quads where TLS cert validation
    /// typically fails.
    static func isLocalOrIPHost(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".localhost") {
            return true
        }
        if !host.contains(".") {
            return true
        }
        // Crude IPv4 detection: all components numeric.
        let parts = host.split(separator: ".")
        if parts.count == 4, parts.allSatisfy({ Int($0) != nil }) {
            return true
        }
        return false
    }

    func fieldToURL(_ string: String) -> URL? {
        if string.hasPrefix("https://")
            || string.hasPrefix("http://")
            || string.hasPrefix("file://") {
            return URL(string: string)
        } else if string.contains(" ") {
            // anything with spaces is probably a search term
            return nil
        } else if string.contains(".") {
            // anything with a dot might be a URL — fall back to "https"
            // as the protocol for a bare URL string like "appfair.net"
            let url = URL(string: string)
            if url?.scheme == nil {
                return URL(string: "https://\(string)")
            } else {
                return url
            }
        } else {
            return nil
        }
    }
}

#endif
