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
enum NetSkipContentBlockingKey {
    static let blockAds = "blockAds"
    static let blockTrackers = "blockTrackers"
    static let blockCookieBanners = "blockCookieBanners"
    /// Newline-separated list of whitelisted host patterns.
    static let whitelistedDomains = "contentBlockingWhitelistedDomains"
    /// Newline-separated list of custom URL substrings to block.
    static let customBlockedPatterns = "contentBlockingCustomBlockedPatterns"
}

/// Splits a newline-separated settings value into a trimmed, non-empty list.
func netSkipParseLineList(_ raw: String) -> [String] {
    raw
        .split(separator: "\n", omittingEmptySubsequences: true)
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}

/// Default category state: ON when the corresponding key has never been set.
func netSkipContentBlockingDefault(_ key: String) -> Bool {
    let defaults = UserDefaults.standard
    if defaults.object(forKey: key) == nil {
        return true
    }
    return defaults.bool(forKey: key)
}

/// Categorized Android content-blocking provider for Net-Skip.
///
/// The provider reads category toggles and custom patterns from `UserDefaults`
/// on each request, so changes made via the settings UI take effect on the next
/// resource load without recreating the engine. Domain whitelisting is handled
/// by SkipWeb via `WebContentBlockerConfiguration.whitelistedDomains` rather
/// than here, so this provider only deals with category-level pattern matching.
final class NetSkipAdBlockProvider: AndroidContentBlockingProvider {
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

    var persistentCosmeticRules: [AndroidCosmeticRule] { [] }

    func requestDecision(for request: AndroidBlockableRequest) -> AndroidRequestBlockDecision {
        // Don't block main frame navigations so users can always reach the page.
        if request.isForMainFrame {
            return .allow
        }

        let urlString = request.url.absoluteString

        if netSkipContentBlockingDefault(NetSkipContentBlockingKey.blockAds) {
            for pattern in Self.adPatterns where urlString.contains(pattern) {
                return .block
            }
        }

        if netSkipContentBlockingDefault(NetSkipContentBlockingKey.blockTrackers) {
            for pattern in Self.trackerPatterns where urlString.contains(pattern) {
                return .block
            }
        }

        if netSkipContentBlockingDefault(NetSkipContentBlockingKey.blockCookieBanners) {
            for pattern in Self.cookieBannerPatterns where urlString.contains(pattern) {
                return .block
            }
        }

        let customRaw = UserDefaults.standard.string(forKey: NetSkipContentBlockingKey.customBlockedPatterns) ?? ""
        if !customRaw.isEmpty {
            for pattern in netSkipParseLineList(customRaw) where urlString.contains(pattern) {
                return .block
            }
        }

        return .allow
    }

    func navigationCosmeticRules(for page: AndroidPageContext) -> [AndroidCosmeticRule] {
        return []
    }
}

/// Names of the iOS rule list JSON files bundled with Net-Skip, by category.
enum NetSkipIOSRuleList {
    static let ads = "block-ads"
    static let cookieBanners = "block-cookies"
}

/// Builds the list of iOS rule list JSON paths to install based on current toggles.
func netSkipIOSRuleListPaths() -> [String] {
    var paths: [String] = []
    let bundle = Bundle.module
    if netSkipContentBlockingDefault(NetSkipContentBlockingKey.blockAds) {
        if let path = bundle.url(forResource: NetSkipIOSRuleList.ads, withExtension: "json")?.path {
            paths.append(path)
        }
    }
    if netSkipContentBlockingDefault(NetSkipContentBlockingKey.blockCookieBanners) {
        if let path = bundle.url(forResource: NetSkipIOSRuleList.cookieBanners, withExtension: "json")?.path {
            paths.append(path)
        }
    }
    return paths
}

/// Builds a `WebContentBlockerConfiguration` from the current settings.
func netSkipMakeContentBlockerConfiguration(provider: NetSkipAdBlockProvider) -> WebContentBlockerConfiguration {
    let whitelistRaw = UserDefaults.standard.string(forKey: NetSkipContentBlockingKey.whitelistedDomains) ?? ""
    let whitelisted = netSkipParseLineList(whitelistRaw)
    return WebContentBlockerConfiguration(
        iOSRuleListPaths: netSkipIOSRuleListPaths(),
        whitelistedDomains: whitelisted,
        androidMode: .custom(provider)
    )
}

/// A small list editor backed by a newline-separated string.
///
/// Used by the Net-Skip settings UI for both the whitelisted-sites list and the
/// custom blocked-patterns list. Entries are trimmed and de-duplicated on save,
/// and an inline TextField lets users add new entries without leaving the screen.
struct NetSkipDomainListEditor: View {
    let title: Text
    let descriptionText: Text
    let prompt: Text
    let emptyMessage: Text
    @Binding var rawText: String

    @State private var newEntry: String = ""

    private var entries: [String] {
        netSkipParseLineList(rawText)
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
