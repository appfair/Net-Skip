// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
#if SKIP || os(iOS)
import SkipWeb
#endif
import NetSkipModel
import AppFairUI

struct SettingsView : View {
    #if SKIP || os(iOS)
    var configuration: WebEngineConfiguration
    #endif
    var store: WebBrowserStore?
    var onClearCache: (() -> Void)? = nil

    @Environment(BrowserSettings.self) var settings

    @State var confirmClearHistory: Bool = false
    @State var confirmClearFavorites: Bool = false
    @State var confirmClearCache: Bool = false
    @State var confirmClearAll: Bool = false

    /// Re-snapshot the default-browser status whenever the Settings
    /// sheet (re)renders. On Android, coming back from the
    /// `RoleManager` picker flips `isRoleHeld` immediately and the
    /// row should reflect that without needing to close + reopen
    /// Settings. On iOS we can't query the status, so this stays
    /// `.eligibleButNotDefault` and the row is always visible.
    @State var defaultBrowserStatus: DefaultBrowserStatus = .eligibleButNotDefault

    @Environment(\.dismiss) var dismiss
    @Environment(\.scenePhase) var scenePhase

    var body: some View {
        // `@Bindable` projects two-way bindings off the @Observable settings
        // instance so individual Toggle/Picker/TextField controls can write
        // back through `$settings.x`. Must be declared and used inline in
        // `body`; passing a plain `BrowserSettings` parameter to a helper
        // would lose the projected-value subscript.
        @Bindable var settings = settings
        return AppFairSettings(bundle: .module) {
            Section {
                Picker(selection: $settings.appearance) {
                    Text("System", bundle: .module, comment: "settings appearance system label").tag("")
                    Text("Light", bundle: .module, comment: "settings appearance system label").tag("light")
                    Text("Dark", bundle: .module, comment: "settings appearance system label").tag("dark")
                } label: {
                    Label {
                        Text("Appearance", bundle: .module, comment: "settings appearance picker label")
                    } icon: {
                        Image("palette", bundle: .module)
                    }
                }
                .accessibilityIdentifier("picker.appearance")

                Toggle(isOn: $settings.buttonHaptics, label: {
                    Label {
                        Text("Haptic Feedback", bundle: .module, comment: "settings toggle label for button haptic feedback")
                    } icon: {
                        Image("vibration", bundle: .module)
                    }
                })
                .accessibilityIdentifier("toggle.haptics")
                Toggle(isOn: $settings.pageLoadHaptics, label: {
                    Label {
                        Text("Page Load Haptics", bundle: .module, comment: "settings toggle label for page load haptic feedback")
                    } icon: {
                        Image("notifications_active", bundle: .module)
                    }
                })
                .accessibilityIdentifier("toggle.pageLoadHaptics")
            }

            Section {
                Picker(selection: $settings.searchEngine) {
                    ForEach(SearchEngine.defaultSearchEngines, id: \.id) { engine in
                        Text(verbatim: engine.name())
                            .tag(engine.id)
                    }
                } label: {
                    Label {
                        Text("Search Engine", bundle: .module, comment: "settings picker label for the default search engine")
                    } icon: {
                        Image("travel_explore", bundle: .module)
                    }
                }
                .accessibilityIdentifier("picker.searchEngine")

                Toggle(isOn: $settings.searchSuggestions, label: {
                    Label {
                        Text("Search Suggestions", bundle: .module, comment: "settings toggle label for previewing search suggestions")
                    } icon: {
                        Image("lightbulb", bundle: .module)
                    }
                })
                .accessibilityIdentifier("toggle.searchSuggestions")

                HStack {
                    Image("house", bundle: .module)
                        .foregroundStyle(.secondary)
                    TextField(text: $settings.customHomeURL, prompt: Text("Home Page URL", bundle: .module, comment: "placeholder text for the custom home-page-URL field")) {
                        Text("Home Page URL", bundle: .module, comment: "accessibility label for the custom home-page-URL field")
                    }
                    #if !SKIP
                    .autocorrectionDisabled(true)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                    .accessibilityIdentifier("field.customHomeURL")
                }
            }

            // Cross-platform "Set as default browser" affordance.
            // Android: RoleManager prompt on API 29+ (falls back to
            // the system Default Apps screen on older releases).
            // iOS: deep-link to the app's Settings entry, where
            // iOS 14+ shows "Default Browser App" (subject to
            // Apple's entitlement approval). The row is hidden only
            // when we can prove Net-Skip already holds the role,
            // which we can only do on Android; iOS shows it
            // unconditionally because there's no isHeld API.
            if defaultBrowserStatus != .held {
                Section {
                    Button {
                        DefaultBrowser.requestRole()
                    } label: {
                        Label {
                            Text("Set Net Skip as Default Browser", bundle: .module, comment: "settings row that takes the user to the system flow for making this app the default web browser")
                        } icon: {
                            Image("public", bundle: .module)
                        }
                    }
                    .accessibilityIdentifier("button.setDefaultBrowser")
                } footer: {
                    #if SKIP
                    if defaultBrowserStatus == .roleUnavailable {
                        Text("Your device doesn't expose a Default Browser picker; you'll be taken to the system Default Apps settings.", bundle: .module, comment: "footer shown beneath the default-browser row on pre-Android-10 devices")
                    } else {
                        Text("Picking Net Skip as the default opens links from other apps in this browser.", bundle: .module, comment: "footer shown beneath the default-browser row when the role is available but not held")
                    }
                    #else
                    Text("Opens Settings → Net Skip, where you can choose Net Skip under Default Browser App.", bundle: .module, comment: "footer shown beneath the default-browser row on iOS, explaining where the system Default Browser App row lives")
                    #endif
                }
            }

            Section("Display") {
                Toggle(isOn: $settings.hideStatusBar, label: {
                    Label {
                        Text("Hide Status Bar", bundle: .module, comment: "settings toggle label for hiding the system status bar so web pages render edge-to-edge")
                    } icon: {
                        Image("fullscreen", bundle: .module)
                    }
                })
                .accessibilityIdentifier("toggle.hideStatusBar")
            }

            Section("Privacy") {
                Toggle(isOn: $settings.enableJavaScript, label: {
                    Label {
                        Text("Enable JavaScript", bundle: .module, comment: "settings toggle label for enabling JavaScript")
                    } icon: {
                        Image("code", bundle: .module)
                    }
                })
                .accessibilityIdentifier("toggle.javascript")
                Toggle(isOn: $settings.upgradeToHTTPS, label: {
                    Label {
                        Text("Upgrade to HTTPS", bundle: .module, comment: "settings toggle label for auto-upgrading plain HTTP requests to HTTPS")
                    } icon: {
                        Image("https", bundle: .module)
                    }
                })
                .accessibilityIdentifier("toggle.upgradeToHTTPS")
            }

            Section("Downloads") {
                Toggle(isOn: $settings.promptForDownloads, label: {
                    Label {
                        Text("Prompt for File Downloads", bundle: .module, comment: "settings toggle label for confirming each download before it starts")
                    } icon: {
                        Image("download", bundle: .module)
                    }
                })
                .accessibilityIdentifier("toggle.promptForDownloads")
            }

            Section("Tabs") {
                Toggle(isOn: $settings.openLinksInBackground, label: {
                    Label {
                        Text("Open Links in Background", bundle: .module, comment: "settings toggle label that keeps the current tab focused when opening links in new tabs")
                    } icon: {
                        Image("tab", bundle: .module)
                    }
                })
                .accessibilityIdentifier("toggle.openLinksInBackground")
            }

            Section {
                Toggle(isOn: $settings.blockAds, label: {
                    Label {
                        Text("Block Ads", bundle: .module, comment: "settings toggle label for blocking ads")
                    } icon: {
                        Image("shield", bundle: .module)
                    }
                })
                .accessibilityIdentifier("toggle.blockAds")
                Toggle(isOn: $settings.blockTrackers, label: {
                    Label {
                        Text("Block Trackers", bundle: .module, comment: "settings toggle label for blocking trackers")
                    } icon: {
                        Image("block", bundle: .module)
                    }
                })
                .accessibilityIdentifier("toggle.blockTrackers")
                Toggle(isOn: $settings.blockCookieBanners, label: {
                    Label {
                        Text("Block Cookie Banners", bundle: .module, comment: "settings toggle label for blocking cookie consent banners")
                    } icon: {
                        Image("cookie", bundle: .module)
                    }
                })
                .accessibilityIdentifier("toggle.blockCookieBanners")

                NavigationLink {
                    DomainListEditor(
                        title: Text("Allowed Sites", bundle: .module, comment: "title for the whitelisted sites editor"),
                        descriptionText: Text("Sites listed here bypass content blocking. Use bare domains like example.com or wildcards like *.example.com.", bundle: .module, comment: "description for whitelisted sites editor"),
                        prompt: Text("example.com", bundle: .module, comment: "placeholder for entering a whitelisted domain"),
                        emptyMessage: Text("No allowed sites yet.", bundle: .module, comment: "empty state for the whitelisted sites editor"),
                        rawText: $settings.contentBlockingWhitelistedDomains
                    )
                } label: {
                    Label {
                        Text("Allowed Sites", bundle: .module, comment: "settings row label for the whitelisted sites editor")
                    } icon: {
                        Image("public", bundle: .module)
                    }
                }
                .accessibilityIdentifier("link.allowedSites")

                NavigationLink {
                    DomainListEditor(
                        title: Text("Custom Block Rules", bundle: .module, comment: "title for the custom blocked patterns editor"),
                        descriptionText: Text("Block any request whose URL contains one of these substrings. Example: tracker.example.com or /analytics/.", bundle: .module, comment: "description for custom blocked patterns editor"),
                        prompt: Text("tracker.example.com", bundle: .module, comment: "placeholder for entering a custom blocked pattern"),
                        emptyMessage: Text("No custom rules yet.", bundle: .module, comment: "empty state for the custom blocked patterns editor"),
                        rawText: $settings.contentBlockingCustomBlockedPatterns
                    )
                } label: {
                    Label {
                        Text("Custom Block Rules", bundle: .module, comment: "settings row label for the custom blocked patterns editor")
                    } icon: {
                        Image("rule", bundle: .module)
                    }
                }
                .accessibilityIdentifier("link.customBlockRules")
            } header: {
                Text("Content Blocking", bundle: .module, comment: "settings header for content blocking customization")
            } footer: {
                Text("Changes to content blocking apply on the next page load.", bundle: .module, comment: "settings footer explaining when content blocking changes take effect")
            }

            Section("Experimental") {
                Toggle(isOn: $settings.enableMiniApps, label: {
                    Label {
                        Text("MiniApps", bundle: .module, comment: "settings toggle label for enabling miniapps experimental feature")
                    } icon: {
                        Image("widgets", bundle: .module)
                    }
                })
                .accessibilityIdentifier("toggle.miniApps")
            }

            Section("Data") {
                Button(role: .destructive) {
                    confirmClearHistory = true
                } label: {
                    Label {
                        Text("Clear History", bundle: .module, comment: "settings button to clear browsing history")
                    } icon: {
                        Image("history", bundle: .module)
                    }
                }
                .accessibilityIdentifier("button.clearHistory")
                .confirmationDialog("Clear all browsing history?", isPresented: $confirmClearHistory) {
                    Button("Clear History", role: .destructive) {
                        trying { try store?.removeItems(type: .history, ids: []) }
                    }
                }

                Button(role: .destructive) {
                    confirmClearFavorites = true
                } label: {
                    Label {
                        Text("Clear Favorites", bundle: .module, comment: "settings button to clear favorites")
                    } icon: {
                        Image("star", bundle: .module)
                    }
                }
                .accessibilityIdentifier("button.clearFavorites")
                .confirmationDialog("Clear all favorites?", isPresented: $confirmClearFavorites) {
                    Button("Clear Favorites", role: .destructive) {
                        trying { try store?.removeItems(type: .favorite, ids: []) }
                    }
                }

                Button(role: .destructive) {
                    confirmClearCache = true
                } label: {
                    Label {
                        Text("Clear Cache", bundle: .module, comment: "settings button to clear the web cache without touching cookies or saved bookmarks")
                    } icon: {
                        Image("cached", bundle: .module)
                    }
                }
                .accessibilityIdentifier("button.clearCache")
                .confirmationDialog(
                    Text("Clear web cache?", bundle: .module, comment: "title of the clear-cache confirmation dialog"),
                    isPresented: $confirmClearCache,
                    titleVisibility: .visible
                ) {
                    Button(role: .destructive) {
                        onClearCache?()
                    } label: {
                        Text("Clear Cache", bundle: .module, comment: "destructive confirm button in the Clear Cache dialog")
                    }
                    .accessibilityIdentifier("button.clearCache.confirm")
                }

                Button(role: .destructive) {
                    confirmClearAll = true
                } label: {
                    Label {
                        Text("Clear All Browsing Data", bundle: .module, comment: "settings button to clear all data")
                    } icon: {
                        Image("delete_forever", bundle: .module)
                    }
                }
                .accessibilityIdentifier("button.clearAllData")
                .confirmationDialog("Clear all browsing data including history, favorites, and open tabs?", isPresented: $confirmClearAll) {
                    Button("Clear All Data", role: .destructive) {
                        trying {
                            try store?.removeItems(type: .history, ids: [])
                            try store?.removeItems(type: .favorite, ids: [])
                        }
                    }
                }
            }

            Section {
                // FIXME: should not need to explicitly specify Base.lproj; it should load as a fallback language automatically
                let aboutURL = Bundle.module.url(forResource: "about", withExtension: "html")
                if let aboutPage = aboutURL {
                    #if !SKIP
                    // FIXME: need Skip support for localizedInfoDictionary / infoDictionary
                    let dict = Bundle.main.localizedInfoDictionary ?? Bundle.main.infoDictionary
                    let appName = dict?["CFBundleDisplayName"] as? String ?? "App"
                    let appVersion = dict?["CFBundleShortVersionString"] as? String ?? "0.0.0"
                    #else
                    let appName = "App"
                    let appVersion = "0.0.0"
                    #endif
                    NavigationLink {
                        // Cannot local local resource paths on Android
                        // https://github.com/skiptools/skip-web/issues/1
                        //WebView(url: aboutPage)
                        #if !os(macOS)
                        VStack(spacing: 0.0) {
                            Text(verbatim: appName)
                                .font(.system(size: 28, weight: .bold))
                                .foregroundStyle(.primary)
                            let aboutHTML = ((try? String(contentsOf: aboutPage)) ?? "error loading local content")
                                .replacingOccurrences(of: "APP_VERSION", with: appVersion)
                            WebView(html: aboutHTML)
                        }
                        #endif
                    } label: {
                        Label {
                            Text("About \(appName) \(appVersion)", bundle: .module, comment: "settings title menu for about app in the form ”About APP_NAME APP_VERSION”")
                        } icon: {
                            Image("info", bundle: .module)
                        }
                    }
                    .accessibilityIdentifier("link.about")
                }
            }
        }
        // Refresh the default-browser status when the sheet first
        // appears AND again when the app is foregrounded — coming
        // back from the Android RoleManager picker or the iOS
        // Settings app should re-read the status (Android: real
        // change; iOS: still .eligibleButNotDefault but the
        // listener is cheap).
        .onAppear {
            defaultBrowserStatus = DefaultBrowser.currentStatus()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                defaultBrowserStatus = DefaultBrowser.currentStatus()
            }
        }
        .navigationTitle(Text("Settings", bundle: .module, comment: "settings sheet title"))
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    self.dismiss()
                } label: {
                    Text("Done", bundle: .module, comment: "done button title")
                        .bold()
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("button.settings.done")
            }
        }
    }
}
