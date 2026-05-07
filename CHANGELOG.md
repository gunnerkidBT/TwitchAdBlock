# Changelog

All notable changes from the original [level3tjg/TwitchAdBlock](https://github.com/level3tjg/TwitchAdBlock) to this fork.

---

## [Fork] — 2026-05-07 (continued)

### Fixed — Proxy silently ignored for standard HTTP proxies

`twab_URLWithProxyURL:` pings `<proxy>/ping` to detect Luminous-style reverse proxies. Standard HTTP proxies (including authenticated `user:pass@host:port` proxies) return non-200, causing the method to return the original URL unchanged — leaving no proxy applied at all. Fixed: if the URL is not rewritten (not a Luminous proxy), both the `NSURLSession` hooks and the `AVURLAsset` hook now fall back to `connectionProxyDictionary` via `twab_proxySessionWithAddress:`. Luminous-style proxies (where `/ping` returns 200) continue to use URL rewriting as before.

### Fixed — `playlist.ttvnw.net` not intercepted for proxy routing

Twitch 29.x issues HLS playlist requests to both `usher.ttvnw.net` and `playlist.ttvnw.net`. The proxy host check only matched `usher.ttvnw.net`, so any request to `playlist.ttvnw.net` bypassed proxy routing entirely. Both hosts are now matched in a shared `twab_isPlaylistHost()` helper used by all three hook sites (`dataTaskWithRequest:`, `uploadTaskWithRequest:`, `AVURLAsset initWithURL:`).

### Added — Network-level ad domain blocking

Requests to known Twitch ad-serving domains are now failed immediately at the `NSURLSession` hook level, independent of the proxy setting. Blocked hosts sourced from TCDB (Twitch CDN Debugger) config observed on Twitch 29.2:

- `edge.ads.twitch.tv`
- `amazon-adsystem.com` / `s.amazon-adsystem.com` / `c.amazon-adsystem.com`
- `spade.twitch.tv`
- `secure-sts-prod.imrworldwide.com`

### Note — Default proxy (`proxy.level3tjg.me`) is currently unreachable

`proxy.level3tjg.me:6375` times out as of 2026-05-07. The address is retained in `Config.h` as the default and will resume working if the service comes back online. Use a custom proxy in the meantime.

---

## [Fork] — 2026-05-07

### Fixed — Settings screen crash on iOS 26 / sideloaded dylibs

The settings screen crashed immediately on tap with `PC=0` because `@available(iOS 13, *)` compiles to a call to `___isOSVersionAtLeast`, a symbol that resolves to `NULL` in sideloaded dylibs (no Substrate/OS runtime to resolve it). Replaced all `@available` guards with `[NSProcessInfo.processInfo isOperatingSystemAtLeastVersion:]` at runtime, and suppressed the resulting compiler warning with `#pragma clang diagnostic ignored "-Wunguarded-availability-new"`.

### Fixed — Settings toggle labels invisible on iOS 26

`UITableViewCell.textLabel` is silently ignored on iOS 14+; iOS 26 renders nothing. Switched to `UIListContentConfiguration` (detected at runtime via `respondsToSelector:`) with a `textLabel` fallback for older OS versions.

### Fixed — `LOC()` macro returning nil when bundle is absent

The `LOC(key, default)` macro called `[tweakBundle localizedStringForKey:key value:default table:nil]` unconditionally. When `tweakBundle` is `nil` (bundle not present in a sideloaded IPA), UIKit received `nil` label text. Fixed to `(tweakBundle ? [tweakBundle localizedStringForKey:key value:default table:nil] : (default))`.

### Fixed — Custom proxy address field invisible and untappable

`proxyAddressCell` created a `UITextField` with `initWithFrame:CGRectMake(16, 0, cell.bounds.size.width - 32, 44)`. At cell creation time `cell.bounds.size.width` is `0`, giving an effective width of `-32 pt`. Replaced with Auto Layout constraints (leading/trailing anchors + `centerYAnchor`) so the field fills the cell correctly at any screen width. Updated placeholder to `user:pass@host:port` to document the accepted format.

### Fixed — Ad blocking broken against Twitch 29.x

Twitch 29.x changed its GraphQL API in two ways that made the platform-spoof silently fail:

1. **Operation rename** — `StreamAccessToken` was replaced by `PlaybackAccessToken` and `PlaybackAccessToken_Template`. The old code only checked for `StreamAccessToken` so new requests were not spoofed.
2. **Field rename** — The platform field moved from `variables.params.platform` to `variables.playerType` (flat, top-level of variables). The old code only patched the nested `params.platform` path.
3. **Batched requests** — Twitch 29.x uses Apollo batching: requests arrive as a JSON **array** of operation objects rather than a single object. The old code only handled `NSMutableDictionary`, so batched requests fell through unmodified.

Rewrote `NSData+TwitchAdBlock.m` with a `twab_applyPlatformSpoof()` helper that handles all known operation names and both field paths, and dispatches correctly over both single-object and array payloads.

### Added — Apollo URLSessionClient hook for feed ad filtering (Twitch 29.x)

Twitch 29.x replaced `_TtC9TwitchKit18TKURLSessionClient` with `_TtC6Apollo16URLSessionClient`. Added a parallel `%hook` for the Apollo class so `FeedAd` nodes are stripped from Following-tab feed responses on both old and new Twitch builds. Both hooks coexist safely — Logos silently skips hooks for classes that don't exist at runtime.

### Added — HTTP proxy authentication support

The original proxy implementation only supported open proxies. Added `TWABProxyAuthDelegate` — an `NSURLSessionDelegate` wrapper that responds to `NSURLAuthenticationMethodHTTPProxy` challenges with stored credentials and forwards all other challenges to the original delegate. Added `TWABParseProxyAddress()` to parse the `user:pass@host:port` format (with or without an `http://` scheme prefix) into host, port, user, and password components.

### Refactored — Settings view controller (Logos `%subclass` → plain ObjC)

The original `TWAdBlockSettingsViewController` was implemented as a Logos `%subclass` on `UITableViewController`. This approach is fragile in sideloaded dylibs because `%subclass` relies on Substrate/runtime hooks that may not be present, and it was causing silent registration failures on Twitch 29.x + iOS 26. Replaced with `TWABSettingsVC`, a plain Objective-C `UITableViewController` subclass compiled as a standard `.m` file. The three old Logos files (`TWAdBlockSettingsViewController.x`, `TWAdBlockSettingsTextField.x`, `TWAdBlockSettingsTextFieldTableViewCell.x`) are retained as stubs for build compatibility but contain no code.

### Changed — `Settings.x` navigation to use `TWABSettingsVC` directly

Removed the `objc_getClass()` lookup for the old Logos-generated class name. `TWABSettingsVC` is now instantiated directly via `[TWABSettingsVC settingsVC]`, which is safe because it is a statically compiled ObjC class in the same dylib.
