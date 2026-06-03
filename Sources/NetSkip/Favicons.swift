// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import Foundation
import OSLog
import SkipWeb

#if SKIP || os(iOS)

private let faviconLogger = Logger(subsystem: "org.appfair.app.netskip", category: "Favicons")

/// Per-process favicon cache. Backed by an in-memory map and a disk
/// cache under `Caches/favicons/`. Resolution strategy (in order):
///
/// 1. Memory or disk hit — instant return.
/// 2. JS-discovered URLs (`discoverHighResIcon` called from
///    `BrowserView` after page load) — high-quality
///    `apple-touch-icon`/`<link rel="icon">` PNG from the site's
///    own HTML.
/// 3. Direct `https://<host>/apple-touch-icon.png` — most modern
///    sites serve a 180×180 PNG here.
/// 4. Direct `https://<host>/favicon.ico` — universal fallback. ICO
///    is decoded by `UIImage(data:)` on iOS; on Android `BitmapFactory`
///    rejects ICO so this is a no-op there, and the JS-discovered
///    path handles non-Apple sites instead.
///
/// No third-party service is in the loop — every byte is fetched
/// from the page's own host, matching the user's privacy posture.
@MainActor public final class FaviconCache {
    public static let shared = FaviconCache()

    /// In-memory map: domain → PNG bytes. Bytes (not images) so the
    /// store is platform-agnostic; the view decodes lazily.
    private var memoryCache: [String: Data] = [:]
    /// Domains where the network fetch failed or returned no usable
    /// icon — short-circuits repeated retries within a session.
    private var negativeCache: Set<String> = []
    /// In-flight fetches keyed by domain so concurrent requests
    /// coalesce instead of each spinning their own URLSession task.
    private var inFlight: [String: Task<Data?, Never>] = [:]

    private init() {}

    /// Extract the registrable host from a URL string. Strips the
    /// `www.` prefix so example.com and www.example.com share a
    /// cache entry. Returns nil for non-HTTP URLs (about:blank,
    /// data:, etc.).
    public static func domain(from urlString: String?) -> String? {
        guard let urlString, !urlString.isEmpty else { return nil }
        guard let url = URL(string: urlString) else { return nil }
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        guard var host = url.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") {
            host = String(host.dropFirst(4))
        }
        return host
    }

    /// Synchronous cache lookup — returns nil if the favicon hasn't
    /// been fetched yet. `FaviconView` uses this to render
    /// immediately during a recomposition before the async fetch
    /// resolves on first appearance.
    public func cachedData(for urlString: String?) -> Data? {
        guard let domain = Self.domain(from: urlString) else { return nil }
        return memoryCache[domain]
    }

    /// Asynchronously resolve the favicon for `urlString`. Returns
    /// PNG bytes when one is available (in memory, on disk, or
    /// fetched from the network) and nil when no favicon can be
    /// obtained — the caller is then expected to render the
    /// `captive_portal` placeholder.
    public func data(for urlString: String?) async -> Data? {
        guard let domain = Self.domain(from: urlString) else { return nil }
        if let cached = memoryCache[domain] { return cached }
        if negativeCache.contains(domain) { return nil }

        // Coalesce concurrent fetches for the same domain.
        if let pending = inFlight[domain] {
            return await pending.value
        }

        let task = Task<Data?, Never> { [weak self] in
            return await self?.loadFromDiskOrNetwork(domain: domain)
        }
        inFlight[domain] = task
        let result = await task.value
        inFlight[domain] = nil
        if let result {
            memoryCache[domain] = result
        } else {
            negativeCache.insert(domain)
        }
        return result
    }

    /// Disk → network path. Tries the site's own apple-touch-icon
    /// (PNG, ~180×180, universally decodable) first, then falls
    /// back to /favicon.ico (ICO is iOS-decodable; on Android the
    /// JS-discovered path handles cases this misses). Disk cache is
    /// keyed by domain.
    private func loadFromDiskOrNetwork(domain: String) async -> Data? {
        let path = Self.diskPath(for: domain)
        if let onDisk = try? Data(contentsOf: path), !onDisk.isEmpty {
            faviconLogger.log("favicon disk hit: \(domain)")
            return onDisk
        }
        // Probe candidates in order: highest-quality first. Each is
        // a single GET to the page's own host — no third-party
        // service in the loop.
        let candidates: [String] = [
            "https://\(domain)/apple-touch-icon.png",
            "https://\(domain)/apple-touch-icon-precomposed.png",
            "https://\(domain)/favicon.ico",
        ]
        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            if let data = await fetch(url: url, label: "\(domain) <- \(candidate)") {
                try? Self.faviconDirectory().createParents()
                try? data.write(to: path)
                return data
            }
        }
        faviconLogger.log("favicon: all direct candidates failed for \(domain)")
        return nil
    }

    /// Fetch the URL and validate the response. Returns nil for
    /// non-200, empty bodies, or anything we wouldn't be able to
    /// render. Used both by the on-demand cache-miss path and by
    /// `discoverHighResIcon` after JS picks a higher-quality URL.
    private func fetch(url: URL, label: String) async -> Data? {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            #if !SKIP
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                faviconLogger.log("favicon fetch non-200 (\(http.statusCode)) for \(label)")
                return nil
            }
            #endif
            if data.count < 32 {
                faviconLogger.log("favicon fetch too-small payload for \(label): \(data.count) bytes")
                return nil
            }
            faviconLogger.log("favicon fetched: \(label) (\(data.count) bytes)")
            return data
        } catch {
            faviconLogger.log("favicon fetch failed for \(label): \(error.localizedDescription)")
            return nil
        }
    }

    /// JS-driven icon discovery. After a page finishes loading,
    /// `BrowserView` calls this with the live WebEngine and the
    /// current page URL. We inject a small script that enumerates
    /// the page's `<link rel="…icon…">` and `<meta property="og:image">`
    /// tags, picks the largest one, and — if we find a higher-quality
    /// URL than what's currently cached — fetches and stores it.
    /// The cache then carries that better icon for every subsequent
    /// FaviconView lookup of the same domain.
    public func discoverHighResIcon(in engine: WebEngine, pageURL: URL?) async {
        guard let domain = Self.domain(from: pageURL?.absoluteString) else { return }
        do {
            let script = Self.iconDiscoveryScript
            guard let raw = try await engine.evaluate(js: script), !raw.isEmpty, raw != "null" else {
                return
            }
            // `evaluate` returns JSON. Strip outer quotes if the
            // result was a top-level string literal, then decode.
            let json = Self.unwrapJSONString(raw)
            guard let iconURL = Self.bestIconURL(fromJSON: json, pageURL: pageURL?.absoluteString) else {
                return
            }
            // Skip the fetch if the URL is the same as what we'd hit
            // through the direct-favicon path (saves a redundant
            // round trip).
            if iconURL == "https://\(domain)/favicon.ico" { return }
            guard let url = URL(string: iconURL) else { return }
            faviconLogger.log("favicon: JS-discovered \(iconURL) for \(domain)")
            if let data = await fetch(url: url, label: "discovered:\(iconURL)") {
                memoryCache[domain] = data
                negativeCache.remove(domain)
                let path = Self.diskPath(for: domain)
                try? Self.faviconDirectory().createParents()
                try? data.write(to: path)
            }
        } catch {
            faviconLogger.log("favicon: JS discovery failed for \(domain): \(error.localizedDescription)")
        }
    }

    /// JS that runs in the page context, returns a JSON object with
    /// the page's declared icon URLs. Resilient to malformed HTML —
    /// the worst case is an empty array. Touch-icons, rel=icon,
    /// rel=mask-icon, and og:image are all candidates; the chooser
    /// downstream picks the best by declared size + format.
    private static let iconDiscoveryScript: String = """
    (function() {
      try {
        var seen = {};
        var icons = [];
        function push(rel, href, sizes) {
          if (!href) return;
          if (seen[href]) return;
          seen[href] = true;
          icons.push({rel: rel, href: href, sizes: sizes || ''});
        }
        var links = document.querySelectorAll('link[rel]');
        for (var i = 0; i < links.length; i++) {
          var rel = (links[i].getAttribute('rel') || '').toLowerCase();
          if (rel.indexOf('icon') === -1 && rel.indexOf('mask-icon') === -1) continue;
          push(rel, links[i].href, links[i].getAttribute('sizes'));
        }
        var ogs = document.querySelectorAll('meta[property="og:image"], meta[name="og:image"], meta[property="twitter:image"]');
        for (var j = 0; j < ogs.length; j++) {
          push('og:image', ogs[j].getAttribute('content'), '');
        }
        return JSON.stringify(icons);
      } catch (e) {
        return '[]';
      }
    })();
    """

    /// `WebEngine.evaluate` wraps top-level JS strings in JSON
    /// quotes; this strips them. Numbers / arrays / objects pass
    /// through unchanged.
    private static func unwrapJSONString(_ raw: String) -> String {
        var s = raw
        if s.hasPrefix("\""), s.hasSuffix("\""), s.count >= 2 {
            s = String(s.dropFirst().dropLast())
            // Unescape the obvious cases — the embedded JSON only
            // contains string and number values, so quotes,
            // backslashes, and forward slashes are what matter.
            s = s.replacingOccurrences(of: "\\\"", with: "\"")
            s = s.replacingOccurrences(of: "\\\\", with: "\\")
            s = s.replacingOccurrences(of: "\\/", with: "/")
        }
        return s
    }

    /// Pick the best icon URL from the JSON the JS returned. Scoring
    /// preference (high → low): apple-touch-icon, rel=icon with the
    /// largest declared size, og:image, mask-icon. PNG / SVG beat
    /// ICO because Android can't decode ICO.
    private static func bestIconURL(fromJSON json: String, pageURL: String?) -> String? {
        guard let data = json.data(using: .utf8) else { return nil }
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        if arr.isEmpty { return nil }

        var best: (score: Int, href: String)? = nil
        for entry in arr {
            guard let href = entry["href"] as? String, !href.isEmpty else { continue }
            let rel = ((entry["rel"] as? String) ?? "").lowercased()
            let sizes = ((entry["sizes"] as? String) ?? "").lowercased()
            let lowerHref = href.lowercased()

            var score = 0
            if rel.contains("apple-touch-icon") { score += 200 }
            else if rel == "og:image" { score += 100 }
            else if rel.contains("mask-icon") { score += 50 }
            else if rel.contains("icon") { score += 80 }

            // Format preference: PNG/SVG/JPEG are universally
            // decodable; ICO works on iOS but not Android.
            if lowerHref.hasSuffix(".png") { score += 30 }
            else if lowerHref.hasSuffix(".svg") { score += 20 }
            else if lowerHref.hasSuffix(".jpg") || lowerHref.hasSuffix(".jpeg") { score += 20 }
            else if lowerHref.hasSuffix(".ico") { score += 5 }

            // Size: parse "180x180" or "any" — bigger is better
            // up to a sensible cap.
            if sizes == "any" { score += 25 }
            else if let dim = sizes.split(separator: "x").first, let n = Int(dim) {
                score += min(n / 4, 60)
            }

            if best == nil || score > best!.score {
                best = (score, href)
            }
        }
        return best?.href
    }

    static func diskPath(for domain: String) -> URL {
        return faviconDirectory().appendingPathComponent("\(domain).png")
    }

    static func faviconDirectory() -> URL {
        return URL.cachesDirectory.appendingPathComponent("favicons")
    }
}

private extension URL {
    /// Helper that creates the directory at this URL (and any missing
    /// intermediates). Idempotent — succeeds silently if the path
    /// already exists.
    func createParents() throws {
        try FileManager.default.createDirectory(at: self, withIntermediateDirectories: true)
    }
}

/// Reusable SwiftUI view that renders the favicon for a given URL,
/// falling back to the `captive_portal` placeholder symbol while the
/// fetch is in flight or when no favicon is available. Used in the
/// URL bar leading edge, the tab card overlay, and the history /
/// favorites list rows so a consistent visual identity follows each
/// page everywhere it's referenced.
@MainActor public struct FaviconView: View {
    /// The page URL whose favicon we're displaying.
    let urlString: String?
    /// Rendered side length in points. The image is shaped to a
    /// rounded square; the caller decides the overall size.
    let size: CGFloat
    /// Corner radius applied to both the favicon image and the
    /// placeholder — keeps the two states visually consistent so
    /// nothing "jumps" when the fetch completes.
    let cornerRadius: CGFloat

    @State private var loadedData: Data?

    public init(urlString: String?, size: CGFloat = 18.0, cornerRadius: CGFloat = 4.0) {
        self.urlString = urlString
        self.size = size
        self.cornerRadius = cornerRadius
    }

    /// Single-character avatar label — first character of the
    /// domain, uppercased. Mirrors `BrowserTabView.domainAvatarLetter`
    /// so an icon and its tab-card snapshot fallback line up.
    static func avatarLetter(for domain: String) -> String {
        guard let first = domain.first else { return "?" }
        return String(first).uppercased()
    }

    /// Deterministic per-domain background color for the letter
    /// avatar. Same domain → same hue across surfaces. The ASCII
    /// byte-position weighted sum keeps Skip Lite happy (no
    /// BigInteger casts from `Character.unicodeScalars.value`).
    static func avatarColor(for domain: String) -> Color {
        var sum: Int = 0
        var position: Int = 0
        for ch in domain {
            if let ascii = ch.asciiValue {
                sum = sum + Int(ascii) * (position + 1)
                position = position + 1
            }
        }
        let hue = Double(sum % 360) / 360.0
        return Color(hue: hue, saturation: 0.55, brightness: 0.62)
    }

    public var body: some View {
        ZStack {
            if let data = loadedData, let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            } else if let domain = FaviconCache.domain(from: urlString) {
                // Per-domain letter avatar — same hash → same color
                // every time, so a site keeps its identity colour
                // across URL bar / history / bookmarks / tab cards
                // even when the network favicon isn't available.
                // Matches the tab-card snapshot fallback look.
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Self.avatarColor(for: domain))
                    Text(verbatim: Self.avatarLetter(for: domain))
                        .font(.system(size: size * 0.55, weight: .semibold))
                        .foregroundStyle(Color.white)
                }
                .frame(width: size, height: size)
            } else {
                // No URL at all (blank tab, edit suggestions, etc.) —
                // neutral globe glyph rather than a random colour.
                Image("captive_portal", bundle: .module)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(.secondary)
                    .frame(width: size, height: size)
            }
        }
        .task(id: urlString ?? "") {
            if let cached = FaviconCache.shared.cachedData(for: urlString) {
                self.loadedData = cached
                return
            }
            self.loadedData = nil
            let fetched = await FaviconCache.shared.data(for: urlString)
            if Task.isCancelled { return }
            self.loadedData = fetched
        }
    }
}

#endif
