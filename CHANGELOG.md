# Changelog

All notable changes from the original [level3tjg/TwitchAdBlock](https://github.com/level3tjg/TwitchAdBlock) to this fork.

---

## [Fork] — 2026-05-16

### Added — Launch screen picker (Home / Browse sub-tab support)

New "Launch Screen" dropdown in the TwitchMods settings, replacing the previous flat row list. Tapping the row opens an action sheet with eight options:

- Default (use Twitch's own initial tab)
- Home → Following, Home → Live, Home → Clips
- Browse → Categories, Browse → Live Channels
- Activity, Profile

The chosen tab is applied on launch via a hook on `Twitch.TabBarController.viewDidAppear:` (`dispatch_once` so subsequent appearances don't override manual user navigation). Home sub-tabs are driven by setting the `PagedContainerScrollView.contentOffset` directly on `Twitch.DiscoveryFeedTabViewController.viewDidLayoutSubviews` — `selectViewControllerAtIndex:` on the inherited `Twitch.PagedContainerViewController` updates internal state but doesn't scroll the visible page, so we drive the scroll view ourselves and write the `selectedContentViewControllerIndex` ivar for state consistency. Browse sub-tab works via the public `Twitch.BrowseViewController.selectViewControllerAtIndex:animated:` which behaves normally. Retries on subsequent layout passes (capped) handle late-arriving scroll-view size.

### Added — Hide Twitch Stories toggle

Optional removal of the horizontal Stories strip at the top of the Home tab. Toggle is in TwitchMods settings, key `TWHideStories`. When on, `Twitch.DiscoveryFeedShelfContainerViewController.viewDidLayoutSubviews` walks its child view controllers and subview tree for any view whose class name contains `StoryViewerListCollapsibleView` (the SwiftUI `_UIHostingView` generic instantiation), removes the host from its parent, and adds a required `heightAnchor == 0` constraint on the host's superview so the empty slot collapses. Retries on each layout pass plus delayed sweeps at 0.5/1.5/3/5 seconds handle the host's lazy attachment. Toggling off requires an app relaunch.

### Added — Default proxy reachability indicator in settings

New row under the proxy switches: "Default proxy" / "Custom proxy" with live status (`● Online` / `● Offline` / `Checking…`). Status is determined by a raw TCP `connect()` to the proxy host:port with a 10-second timeout — no auth handshake, no TLS, no upstream test, just whether the port accepts connections. Probe runs on settings open, on the proxy switch toggling on, on the custom-proxy switch flipping, and on the address field losing focus.

### Added — Bits / brand-offer banner blocking

New GraphQL `__typename` blocklist entries with two strip semantics (`twab_arrayAdTypenames` for array elements & edge nodes, `twab_fieldAdTypenames` for top-level dict fields):

- `OfferPromotion` — McDonalds-style brand offer banners
- `PromotionDisplay` — wrapper around the above
- `BitsProductPromotion` — the in-app "buy Bits" prompt
- `FeedAd` — Following-feed ad cards (array-only, would break legitimate metadata fields on Stream/Clip if treated as field-strippable)

Strip is now also edge-aware: removes the whole edge from `feedItems.edges` when `edge.node.__typename` matches, matching the original `filteredArrayUsingPredicate:` semantics. Previously the recursive strip removed only the `node` key from the edge, leaving orphaned edges that broke the Live / Clips renderers.

### Added — Recursive ad-typename diagnostic scan

Every `gql.twitch.tv/gql` response is recursively scanned for any `__typename` containing `Ad` / `Promot` / `Sponsor` / `Headliner`. Each unique `(operationName, typename)` pair is logged once via `[TWAB-Ad] suspect typename=… op=… filtered=N`, surfacing new ad surfaces (e.g., banners introduced in future Twitch versions) so they can be added to the blocklist without code archaeology.

### Added — Subdomain-aware ad host matching

`twab_isAdHost` now splits into an `exact` set and a `suffixes` array. Suffix matches block the bare domain plus any subdomain (`aax-eu.amazon-adsystem.com`, `c.amazon-adsystem.com`, etc.) under one entry. Previously only the exact hosts in the original list were blocked.

### Added — User-facing rebrand to "TwitchMods"

Three display strings updated: the entry row label in Twitch's account menu, the settings screen title, and the version footer. Internal symbols (file/class names, NSUserDefaults keys, dylib filename, repo name) keep the `TwitchAdBlock` naming to preserve existing user preferences and not break the inject toolchain.

### Added — Ad-block proxy on by default

`TWAdBlockProxyEnabled` now defaults to `YES` for fresh installs. Existing installs keep their stored preference.

### Added — Typed settings keys

New `SettingsKeys.h` / `.m` exposing `extern NSString *const TWABKey...` constants for every `NSUserDefaults` key, replacing scattered `@"..."` literals across `Tweak.x`, `Settings.x`, `TWABSettingsVC.m`, `Emotes.x`, and `TWAdBlockAssetResourceLoaderDelegate.m`. Typos become compile errors instead of silent NO/nil reads.

### Added — Hook-target missing diagnostic

`twab_warnIfClassMissing()` runs at `%ctor` for every Swift class we `%hook` (account menu, following VC, headliner ad manager, URL-session client, app update prompt, tab bar controller, browse VC, discovery feed tab VC, discovery feed shelf container). When Twitch renames a class between versions the corresponding feature silently fails — this surfaces missing classes via `[TWAB] missing hook target: …` at launch.

### Changed — IRC emote position math is now grapheme-cluster counted

`emotes=` tag positions are derived from `enumerateSubstringsInRange:options:NSStringEnumerationByComposedCharacterSequences` instead of `NSString.length` (UTF-16 code units). Emoji and other non-BMP characters before an emote no longer shift the rendered emote range.

### Changed — WebSocket handler idempotent + non-IRC early return

`twab_wrapHandler` now uses `objc_setAssociatedObject` to mark already-wrapped handlers so the public `NSURLSessionWebSocketTask` and the private `__NSURLSessionWebSocketTask` hooks can't double-wrap each other's blocks. Also short-circuits when the first character of a frame isn't `@`, `:`, or `P` (non-IRC traffic) before doing any CRLF splitting / per-line work.

### Changed — Emote registry LRU eviction

The byWord / byFakeId dictionaries grew monotonically with each visited channel. Now each emote is tagged with its source room; the loaded-room set is bounded to `TWAB_MAX_ROOMS` (50, globals exempt); when crossed, the oldest room's entries are removed from all indices.

### Changed — Synthetic emote ID generator

Switched from a `dispatch_queue_t` + `dispatch_sync` block to a single `atomic_fetch_add` on a `_Atomic uint64_t` counter. One less queue hop per emote registration.

### Changed — `%@` + `UTF8String` → `%{public}@` for NSString logging

Every `os_log` site in `Emotes.x` that was formatting an `NSString` via `%{public}s` + `.UTF8String` now uses `%{public}@` directly. Avoids the per-call UTF-8 conversion and is the idiomatic OSLog form.

### Changed — NSURLSession ad-data filter hooks deduped

`_TtC9TwitchKit18TKURLSessionClient.URLSession:dataTask:didReceiveData:` and `_TtC6Apollo16URLSessionClient.URLSession:dataTask:didReceiveData:` previously had identical one-line bodies. Factored into `twab_filteredFeedData()` so future client class additions only need a one-line hook block.

### Changed — Effective proxy address helper

The `[tweakDefaults boolForKey:TWABKeyAdBlockCustomProxyEnabled] ? [tweakDefaults stringForKey:TWABKeyAdBlockProxy] : PROXY_ADDR` ternary was duplicated 5 times across Tweak.x and TWAdBlockAssetResourceLoaderDelegate.m. Extracted to `twab_effectiveProxyAddress()` in `SettingsKeys.m`.

### Changed — Settings text fields save on every keystroke

The proxy address `UITextField` previously persisted to `NSUserDefaults` only in `textFieldDidEndEditing:`. If the user typed and backgrounded the app without explicitly dismissing the keyboard, the value sometimes wasn't saved. Added an `UIControlEventEditingChanged` target that writes on every change, plus `keyboardDismissMode = OnDrag` so any table scroll dismisses the keyboard (and triggers status re-probe).

### Changed — Settings cells use `dequeueReusableCellWithIdentifier:`

Switch cells now properly dequeue and reset state on reuse instead of allocating fresh `UITableViewCell` instances each `cellForRowAtIndexPath:`. The proxy address text-field cell uses a tagged-view lookup so its `UITextField` isn't reattached on reuse.

### Changed — Deprecated `[tweakDefaults synchronize]` calls removed

Apple deprecated `synchronize` in iOS 12; `setBool:forKey:` and friends already persist on their own. Five call sites in `TWABSettingsVC.m` deleted.

### Fixed — Live and Clips tabs failed to populate

A recursive `__typename` strip introduced in the previous release was removing the `node` key from edges in `feedItems.edges` (matching `FeedAd`), leaving the edges in place with no `node` — the Live/Clips renderers handled this by showing nothing. Restored the original `filteredArrayUsingPredicate:` behavior by detecting edge-shape array elements (`{__typename: Edge, node: {__typename: FeedAd}}`) and removing the whole edge. Also added a "dirty" flag so responses with no strips are returned byte-for-byte unchanged, since Apollo's cache normalization is sensitive to re-serialization differences.

### Fixed — Speculative ad typenames blanking content surfaces

`AdProperties`, `PromotedContent`, `SponsoredContent`, `HeadlinerAd`, `DisplayAd`, `BannerAd`, `FeedAds`, `AdCard` removed from the blocklist — they were defensive guesses never confirmed via diagnostic logs, and several were appearing as metadata fields on legitimate `Stream` / `Clip` / promotional content objects whose renderers expected them. The blocklist is now curated to typenames the user has observed in chat or feed logs.

---

## [Fork] — 2026-05-15

### Added — Third-party emote rendering (7TV / BTTV / FrankerFaceZ)

Emotes from 7TV, BetterTTV, and FrankerFaceZ now render inline alongside native Twitch emotes in chat. Implementation in `Emotes.x`:

1. **IRC tag injection** — `NSURLSessionWebSocketTask.receiveMessageWithCompletionHandler:` is hooked (both `NSURLSessionWebSocketTask` and the private `__NSURLSessionWebSocketTask`). Each incoming IRC frame is parsed for PRIVMSG, the message body is scanned for known emote words, and synthetic numeric emote IDs (≥ `9_000_000_000` so they never collide with real Twitch IDs) are appended to the IRC `emotes=` tag. Twitch's Kotlin Multiplatform parser in `KMPMobileChat.framework` then produces normal `EmoteToken` objects from the tag — no need to construct Kotlin/Native objects from ObjC.

2. **URL redirect** — `__NSURLSessionLocal.dataTaskWithRequest:` is hooked to detect outgoing requests for `static-cdn.jtvnw.net/emoticons/v2/{syntheticId}/...` and rewrite the URL to the real provider CDN:
   - 7TV → `cdn.7tv.app/emote/{id}/2x.webp`
   - BTTV → `cdn.betterttv.net/emote/{id}/2x`
   - FFZ → `cdn.frankerfacez.com/emote/{id}/2`

3. **Per-channel emote loading** — when a new `room-id=` is seen in a PRIVMSG, the channel's 7TV, BTTV, and FFZ emote sets are fetched asynchronously from the providers' public APIs. Global emote sets are fetched once at dylib load. All registry operations go through a concurrent dispatch queue with barrier writes.

4. **Settings toggle** — new "3rd-Party Emotes" switch in the TwitchAdBlock settings (defaults ON, key `TWEmotesEnabled`). Both hooks are gated by this preference for instant on/off.

### Changed — Deployment target bumped to iOS 13.0

`NSURLSessionWebSocketTask` is iOS 13+ only. The Twitch app itself requires iOS 14+, so this is a no-op for end users.

### Known limitations

- **Animated emotes render as a static first frame.** Twitch decides static vs animated via `MessageStringImageData.isAnimated`, but the rendering pipeline does not call `initWithStaticURL:animatedURL:isAnimated:isAvatar:` for emotes whose IDs aren't in Twitch's emote catalog — verified by swizzling the init and observing it is never invoked. The actual hook target for forcing animation has not yet been identified.
- **Your own outgoing messages don't get emote rendering.** Twitch tokenizes the local user's own messages locally before the IRC echo arrives, so our `emotes=` injection on the echo is ignored. Emotes still render for everyone else watching, including your messages on their screens.

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

### Note — Default proxy is currently unreachable

Default `proxy` times out as of 2026-05-07. The address is retained in `Config.h` as the default and will resume working if the service comes back online. Use a custom proxy in the meantime.

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
