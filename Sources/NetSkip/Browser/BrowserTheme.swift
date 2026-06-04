// SPDX-License-Identifier: GPL-2.0-or-later
//
// Shared chrome helpers used by the URL bar, toolbar, and tab
// management code — the platform-neutral fallback URL and the two
// color resolvers that drive the toolbar surround and the URL-bar
// "search pill" fill.

import SwiftUI

#if SKIP || os(iOS)

/// The URL we treat as "no page" — a fresh blank tab, a brand-new
/// view-model, or a `ShareLink` that has nothing real to share.
let fallbackURL = "about:blank"

/// Opaque chrome background — used by the bottom toolbar and the
/// surround of the URL bar capsule. Adapts to the active colour
/// scheme so dark mode doesn't leave a hard-coded light grey strip
/// floating under the toolbar buttons. Call as a function with the
/// environment colour scheme so the same shade resolves on both
/// platforms (Skip's Compose translation doesn't track
/// `UIColor.secondarySystemBackground` semantics).
func urlBarBackground(for scheme: ColorScheme, isPrivate: Bool = false) -> Color {
    if isPrivate {
        // Deep indigo — matches Firefox / DuckDuckGo's private-mode
        // chrome and is distinct from anything the default toolbar
        // ever resolves to, so a glance at the bottom of the screen
        // is enough to tell whether the current tab is private.
        return scheme == .dark ? Color(red: 0.13, green: 0.10, blue: 0.22) : Color(red: 0.21, green: 0.16, blue: 0.36)
    }
    return scheme == .dark ? Color(white: 0.16) : Color(white: 0.92)
}

/// Inner fill of the rounded-rectangle "search pill" inside the URL
/// bar. White in light mode for high text contrast; a slightly
/// elevated dark grey in dark mode to stay readable against the
/// darker toolbar surround without flashing pure white.
func urlBarPillFill(for scheme: ColorScheme, isPrivate: Bool = false) -> Color {
    if isPrivate {
        // Slightly lighter than the private chrome surround so the
        // pill still reads as the input field, but still distinctly
        // purple-tinted so the privacy state is unmistakable.
        return scheme == .dark ? Color(red: 0.22, green: 0.18, blue: 0.32) : Color(red: 0.33, green: 0.27, blue: 0.50)
    }
    return scheme == .dark ? Color(white: 0.24) : Color.white
}

/// Foreground colour for chrome glyphs / text that sit on top of the
/// `urlBarBackground` / `urlBarPillFill`. The private-mode chrome is
/// dark by design, so the foreground stays light regardless of the
/// active `ColorScheme`.
func urlBarForeground(for scheme: ColorScheme, isPrivate: Bool = false) -> Color {
    if isPrivate {
        return Color.white
    }
    return Color.primary
}

#endif
