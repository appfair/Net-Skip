# Readability.js — update notes

`Resources/Readability.js` is a vendored copy of
[Mozilla Readability](https://github.com/mozilla/readability) (Apache
License 2.0). It powers the browser's Reader View — when the user
taps **Reader View** in the favicon menu, the app injects this
script into the live WebView, calls `new Readability(...).parse()`
against a clone of the page's DOM, and rewrites the document with
the extracted article.

The reader-mode glue lives in `Sources/NetSkip/Browser/ReaderMode.swift`.

## Currently bundled

| Field             | Value                                             |
| ----------------- | ------------------------------------------------- |
| Upstream version  | `0.6.0` (from `package.json` on `main`)           |
| Upstream commit   | `08be6b4bdb20` (2025-11-15)                       |
| Local path        | `Sources/NetSkip/Resources/Readability.js`        |

## How to update

1. **Fetch the latest** straight from the canonical source — there's no
   transformation, just a verbatim drop-in:

   ```bash
   cd Sources/NetSkip/Resources
   curl -fsSL -o Readability.js \
       https://raw.githubusercontent.com/mozilla/readability/main/Readability.js
   ```

2. **Capture the new version metadata** so this table stays honest:

   ```bash
   curl -fsSL https://raw.githubusercontent.com/mozilla/readability/main/package.json \
     | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])'
   curl -fsSL https://api.github.com/repos/mozilla/readability/commits/main \
     | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["sha"][:12], d["commit"]["author"]["date"])'
   ```

   Update the table above with the new version, commit, and date.

3. **Verify the LICENSE** still says Apache-2.0 (it has since 2010, but
   sanity-check before shipping).

4. **Run the reader-mode Maestro tests** on both platforms — they
   visit a known article-shaped page and assert the reader view
   renders:

   ```bash
   skip app launch
   maestro --device <ios-uuid>      test .maestro/reader-mode-ios.yaml
   maestro --device emulator-5554   test .maestro/reader-mode-android.yaml
   ```

5. **Spot-check three real pages** in the running app — a mid-length
   news article, a Wikipedia page, and a blog post — to verify
   Readability still detects them and the styling reads cleanly. Pay
   attention to: code blocks, blockquotes, embedded images, captions.

## Pitfalls to watch for

- **Don't minify locally.** The vendored file ships unminified so
  diffs against `main` stay readable. Skip's transpiler doesn't
  process it (it's a `.js` resource bundled via `process(Resources)`,
  not Swift source), so file size doesn't affect Kotlin output.

- **The injection payload concatenates the source as raw text** inside
  a `(function() { … })()` IIFE in
  `ReaderMode.swift::readerModeInjectionJS(...)`. Upstream
  occasionally tweaks how it exports, but as long as `new Readability(doc).parse()` keeps
  returning `{ title, byline, siteName, content, length }`, the
  wrapper stays compatible.

- **Performance.** The file is ~95 KB, parsed on every reader-mode
  activation. The source is cached on Swift side
  (`BrowserTabView.loadReadabilitySource()` reads once and memoises),
  but the JS engine still has to compile/run it each toggle. If
  upstream balloons past ~300 KB, consider preloading once per tab
  rather than on each activation.
