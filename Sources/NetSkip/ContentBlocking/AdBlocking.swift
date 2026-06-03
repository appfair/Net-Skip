// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import SwiftUI
#if SKIP || os(iOS)
import SkipWeb
#endif

#if SKIP || os(iOS)

/// UserDefaults keys for content blocking settings.
///
/// Keep in sync with the `@AppStorage` keys used in `BrowserTabView` and `SettingsView`.
enum ContentBlockingKey {
    static let blockAds = "blockAds"
    static let blockTrackers = "blockTrackers"
    static let blockCookieBanners = "blockCookieBanners"
    /// Newline-separated list of whitelisted host patterns.
    static let whitelistedDomains = "contentBlockingWhitelistedDomains"
    /// Newline-separated list of custom URL substrings to block.
    static let customBlockedPatterns = "contentBlockingCustomBlockedPatterns"
}

/// Splits a newline-separated settings value into a trimmed, non-empty list.
func parseLineList(_ raw: String) -> [String] {
    raw
        .split(separator: "\n", omittingEmptySubsequences: true)
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}

/// Default category state: ON when the corresponding key has never been set.
func contentBlockingDefault(_ key: String) -> Bool {
    let defaults = UserDefaults.standard
    if defaults.object(forKey: key) == nil {
        return true
    }
    return defaults.bool(forKey: key)
}

/// Categorized Android content-blocking provider.
///
/// The provider reads category toggles and custom patterns from `UserDefaults`
/// on each request, so changes made via the settings UI take effect on the next
/// resource load without recreating the engine. Domain whitelisting is handled
/// by SkipWeb via `WebContentBlockerConfiguration.whitelistedDomains` rather
/// than here, so this provider only deals with category-level pattern matching.
final class AdBlockProvider: AndroidContentBlockingProvider {
    /// Ad-network and ad-serving domain substrings.
    static let adPatterns: [String] = [
        "doubleclick.net",
        "googlesyndication.com",
        "googleadservices.com",
        "pagead2.googlesyndication",
        "adservice.",
        "ads.pubmatic.com",
        "amazon-adsystem.com",
        "adnxs.com",
        "adsrvr.org",
        "criteo.com",
        "rubiconproject.com",
        "moatads.com",
        "serving-sys.com",
        "adhigh.net",
        "admob.com",
        "adcolony.com",
    ]

    /// Analytics, tracking, and behavioral fingerprinting substrings.
    static let trackerPatterns: [String] = [
        "google-analytics.com",
        "googletagmanager.com",
        "facebook.com/tr",
        "facebook.net/en_US/fbevents",
        "connect.facebook.net",
        "analytics.",
        "scorecardresearch.com",
        "quantserve.com",
        "bluekai.com",
        "exelator.com",
        "turn.com",
        "chartbeat.com",
        "hotjar.com",
        "cdn.taboola.com",
        "cdn.outbrain.com",
    ]

    /// Known cookie consent banner and CMP (consent management platform) substrings.
    static let cookieBannerPatterns: [String] = [
        "cookielaw.org",
        "cookiebot.com",
        "onetrust.com",
        "cdn-cookieyes.com",
        "consent.cookiebot.com",
        "consentmanager.net",
        "trustarc.com",
        "termly.io",
    ]

    /// Substring patterns extracted from the bundled WebKit content-rule
    /// list (`block-ads.json`). The iOS WebView compiles the JSON
    /// directly; on Android we extract the literal segments from each
    /// rule's `url-filter` regex so the on-device check is a quick set
    /// of `String.contains` lookups rather than a full regex engine.
    ///
    /// Loaded lazily on a background queue the first time the provider
    /// is consulted — a synchronous parse of the bundled JSON (5800+
    /// rules) blocks the Android main thread long enough to trip the
    /// startup activity-launch watchdog, so the first few requests
    /// fall back to the hard-coded `adPatterns` list above while the
    /// background task warms the cache.
    nonisolated(unsafe) private static var extractedAdSubstrings: [String] = []
    nonisolated(unsafe) private static var extractedCookieBannerSubstrings: [String] = []
    nonisolated(unsafe) private static var didStartExtractionLoad = false

    var persistentCosmeticRules: [AndroidCosmeticRule] { [] }

    /// Kick off the background extraction once. Reads here are
    /// best-effort — a duplicated extraction is harmless because the
    /// final assignment is just a single Array reference swap, which
    /// is atomic for `String` arrays via copy-on-write. We don't take
    /// a lock so this stays callable from the WebView's worker thread
    /// without dragging the Swift-6 actor isolation requirements onto
    /// every call site.
    private static func warmExtractedPatternsIfNeeded() {
        if didStartExtractionLoad { return }
        didStartExtractionLoad = true
        Task.detached(priority: .utility) {
            let ads = AdBlockProvider.loadExtractedPatterns(resource: IOSRuleList.ads)
            let cookies = AdBlockProvider.loadExtractedPatterns(resource: IOSRuleList.cookieBanners)
            extractedAdSubstrings = ads
            extractedCookieBannerSubstrings = cookies
        }
    }

    private static func snapshotExtractedPatterns() -> (ads: [String], cookies: [String]) {
        return (extractedAdSubstrings, extractedCookieBannerSubstrings)
    }

    func requestDecision(for request: AndroidBlockableRequest) -> AndroidRequestBlockDecision {
        // Don't block main frame navigations so users can always reach the page.
        if request.isForMainFrame {
            return .allow
        }

        // First request kicks off the background JSON parse; subsequent
        // requests see a non-empty `extractedAd/CookieBannerSubstrings`
        // and benefit from the wider rule set.
        Self.warmExtractedPatternsIfNeeded()
        let extracted = Self.snapshotExtractedPatterns()
        let urlString = request.url.absoluteString

        if contentBlockingDefault(ContentBlockingKey.blockAds) {
            for pattern in Self.adPatterns where urlString.contains(pattern) {
                return .block
            }
            for pattern in extracted.ads where urlString.contains(pattern) {
                return .block
            }
        }

        if contentBlockingDefault(ContentBlockingKey.blockTrackers) {
            for pattern in Self.trackerPatterns where urlString.contains(pattern) {
                return .block
            }
        }

        if contentBlockingDefault(ContentBlockingKey.blockCookieBanners) {
            for pattern in Self.cookieBannerPatterns where urlString.contains(pattern) {
                return .block
            }
            for pattern in extracted.cookies where urlString.contains(pattern) {
                return .block
            }
        }

        let customRaw = UserDefaults.standard.string(forKey: ContentBlockingKey.customBlockedPatterns) ?? ""
        if !customRaw.isEmpty {
            for pattern in parseLineList(customRaw) where urlString.contains(pattern) {
                return .block
            }
        }

        return .allow
    }

    func navigationCosmeticRules(for page: AndroidPageContext) -> [AndroidCosmeticRule] {
        return []
    }

    /// Read a WebKit content-rule JSON file and extract the substring
    /// portion of every `block` rule whose `url-filter` is a simple
    /// regex (no `* + ? [ ] ( ) |`, after stripping the standard
    /// `^https?://` anchor and unescaping `\.` / `\/` / `\-`). The
    /// remaining metacharacter-bearing rules are skipped — Android
    /// users get the union of these extracted substrings plus the
    /// hard-coded supplementary lists above.
    private static func loadExtractedPatterns(resource: String) -> [String] {
        guard let url = Bundle.module.url(forResource: resource, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data),
              let rules = root as? [[String: Any]] else {
            return []
        }
        var seen: Set<String> = []
        var patterns: [String] = []
        for rule in rules {
            guard let action = rule["action"] as? [String: Any],
                  (action["type"] as? String) == "block" else { continue }
            guard let trigger = rule["trigger"] as? [String: Any] else { continue }
            // Skip conditional rules — load-type / domain conditions
            // need an evaluator we don't ship on Android.
            if trigger["unless-domain"] != nil { continue }
            if trigger["if-domain"] != nil { continue }
            if trigger["load-type"] != nil { continue }
            guard let urlFilter = trigger["url-filter"] as? String else { continue }
            guard let extracted = extractLiteralSubstring(from: urlFilter), extracted.count >= 4 else { continue }
            if seen.insert(extracted).inserted {
                patterns.append(extracted)
            }
        }
        return patterns
    }

    /// Convert a WebKit `url-filter` regex into a plain substring when
    /// the regex is just an anchored escaped substring. Returns nil
    /// for anything that still contains regex metacharacters after the
    /// standard transformations.
    static func extractLiteralSubstring(from regex: String) -> String? {
        var s = regex
        // Strip the conventional anchor prefixes used in
        // safari-content-blocker rule lists.
        let anchorPrefixes = [
            "^https?:\\/\\/[^\\/]*",
            "^https?:\\/\\/",
            "^https://",
            "^http://",
            "^",
        ]
        for prefix in anchorPrefixes where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
            break
        }
        // Strip a trailing `$` anchor.
        if s.hasSuffix("$") {
            s = String(s.dropLast())
        }
        // Unescape the common punctuation escapes that appear in
        // roughly 90% of the bundled rules.
        s = s.replacingOccurrences(of: "\\.", with: ".")
        s = s.replacingOccurrences(of: "\\/", with: "/")
        s = s.replacingOccurrences(of: "\\-", with: "-")
        s = s.replacingOccurrences(of: "\\_", with: "_")
        s = s.replacingOccurrences(of: "\\?", with: "?")
        s = s.replacingOccurrences(of: "\\=", with: "=")
        // Any remaining regex metacharacter disqualifies the pattern.
        // `+` is a quantifier; `*` matches anything; `[`/`(`/`|` are
        // grouping; `\` left over means there's an escape we didn't
        // handle. `?` and `=` are fine — they're legal URL bytes once
        // unescaped.
        for ch in s {
            if "*+[](){}|^$\\".contains(ch) {
                return nil
            }
        }
        return s.isEmpty ? nil : s
    }
}

/// Names of the iOS rule list JSON files bundled with the app, by category.
enum IOSRuleList {
    static let ads = "block-ads"
    static let cookieBanners = "block-cookies"
}

/// Builds the list of iOS rule list JSON paths to install based on current toggles.
func currentIOSRuleListPaths() -> [String] {
    var paths: [String] = []
    let bundle = Bundle.module
    if contentBlockingDefault(ContentBlockingKey.blockAds) {
        if let path = bundle.url(forResource: IOSRuleList.ads, withExtension: "json")?.path {
            paths.append(path)
        }
    }
    if contentBlockingDefault(ContentBlockingKey.blockCookieBanners) {
        if let path = bundle.url(forResource: IOSRuleList.cookieBanners, withExtension: "json")?.path {
            paths.append(path)
        }
    }
    return paths
}

/// Builds a `WebContentBlockerConfiguration` from the current settings.
func makeContentBlockerConfiguration(provider: AdBlockProvider) -> WebContentBlockerConfiguration {
    let whitelistRaw = UserDefaults.standard.string(forKey: ContentBlockingKey.whitelistedDomains) ?? ""
    let whitelisted = parseLineList(whitelistRaw)
    return WebContentBlockerConfiguration(
        iOSRuleListPaths: currentIOSRuleListPaths(),
        whitelistedDomains: whitelisted,
        androidMode: .custom(provider)
    )
}

/// A small list editor backed by a newline-separated string.
///
/// Used by the settings UI for both the whitelisted-sites list and the
/// custom blocked-patterns list. Entries are trimmed and de-duplicated on save,
/// and an inline TextField lets users add new entries without leaving the screen.
struct DomainListEditor: View {
    let title: Text
    let descriptionText: Text
    let prompt: Text
    let emptyMessage: Text
    @Binding var rawText: String

    @State private var newEntry: String = ""

    private var entries: [String] {
        parseLineList(rawText)
    }

    var body: some View {
        Form {
            Section {
                descriptionText
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack(spacing: 8) {
                    TextField(text: $newEntry, prompt: prompt) {
                        Text("New Entry", bundle: .module, comment: "accessibility label for the new content-blocking entry field")
                    }
                    #if !SKIP
                    .autocorrectionDisabled(true)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.done)
                    #endif
                    .onSubmit {
                        addEntry()
                    }

                    Button(action: addEntry) {
                        Image("plus", bundle: .module)
                    }
                    .buttonStyle(.plain)
                    .disabled(newEntry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } header: {
                Text("Add", bundle: .module, comment: "section header for adding a new content-blocking entry")
            }

            Section {
                if entries.isEmpty {
                    emptyMessage
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(entries.enumerated()), id: \.0) { index, entry in
                        HStack {
                            Text(verbatim: entry)
                            Spacer()
                            Button {
                                removeEntry(at: index)
                            } label: {
                                Image("xmark.circle.fill", bundle: .module)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } header: {
                Text("Entries", bundle: .module, comment: "section header for the list of content-blocking entries")
            }
        }
        .navigationTitle(title)
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func addEntry() {
        let trimmed = newEntry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        var current = entries
        if !current.contains(trimmed) {
            current.append(trimmed)
        }
        rawText = current.joined(separator: "\n")
        newEntry = ""
    }

    private func removeEntry(at index: Int) {
        var current = entries
        guard index >= 0 && index < current.count else {
            return
        }
        current.remove(at: index)
        rawText = current.joined(separator: "\n")
    }
}

#endif
