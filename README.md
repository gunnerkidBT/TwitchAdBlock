# TwitchAdBlock (Unofficial Fork)

> **This is not my project.** The original TwitchAdBlock was created by [level3tjg](https://github.com/level3tjg/TwitchAdBlock). All credit for the original concept, architecture, and implementation goes to them. This fork exists solely to maintain compatibility with newer versions of Twitch and iOS.

> **The modifications in this fork were made with the assistance of Claude (Anthropic AI).** I am not an iOS developer. Do not report issues in this fork to the original author.

---

## Features

### Ad blocking
- **Live stream preroll ad blocking** via proxy — either V2 / ttv-lol-pro–compatible (URL rewrite + Basic auth) or standard HTTP CONNECT tunneling
- **VOD preroll ad blocking** via the same proxy path
- **GraphQL-level ad stripping** — removes `OfferPromotion` (McDonald's-style brand banners), `PromotionDisplay`, `BitsProductPromotion` ("buy Bits" prompt), and `FeedAd` (Following-feed ad cards)
- **Recursive ad-typename diagnostic** — surfaces unknown `Ad` / `Promot` / `Sponsor` / `Headliner` typenames so new ad surfaces can be added to the blocklist quickly
- **Ad-host hard block** — `edge.ads.twitch.tv`, `spade.twitch.tv`, `*.amazon-adsystem.com`, and Nielsen domains return nil tasks immediately
- **Bundled default proxy** — works out of the box without configuration (V1-compatible)
- **Custom proxy support** — `user:pass@host:port` format with Basic auth automatically injected
- **Multi-proxy fallback list** — reorderable list of proxies tried in order; first to ping/200 wins for V2 rewrite, first parseable used for CONNECT fallback
- **Subscriber / Turbo bypass** — token-aware skip when the user is ad-exempt (avoids exposing their auth token to the proxy)
- **Live proxy reachability status** — `● Online` / `● Offline` indicator with raw TCP probe
- **Per-proxy ping verdict cache** — multi-proxy lists don't re-ping every entry on every request

### Chat
- **7TV emote rendering** in chat — globals + per-channel sets
- **BetterTTV emote rendering** in chat — globals + per-channel sets
- **FrankerFaceZ emote rendering** in chat — globals + per-channel sets
- **LRU emote cache** — bounded to 50 rooms; oldest emotes evicted, globals never expire
- **Grapheme-cluster–accurate emote position math** for IRC `emotes=` tag offsets

### App customization
- **Launch Screen picker** — choose what tab Twitch opens to (Home → Following / Live / Clips, Browse → Categories / Live Channels, Activity, Profile, or Twitch's default)
- **Hide Twitch Stories** — removes the horizontal Stories strip at the top of the Home tab
- **TwitchMods account-menu entry** — bold themed cell with leading icon, opens the settings screen

### Compatibility
- **Twitch 29.x** — handles renamed GraphQL operations + Apollo batched-array request shape
- **iOS 26** — works around `___isOSVersionAtLeast` resolution failure and `UIListContentConfiguration` requirements
- **Sideloaded / no jailbreak / no Substrate** — `inject_ipa.py` handles dylib injection + ATS bypass; settings VC built without Logos `%subclass`

---

## What changed

This fork fixes several issues that broke TwitchAdBlock on **Twitch 29.x** and **iOS 26** when sideloaded (no jailbreak / no Substrate):

- **Settings crash fixed** — The settings screen crashed on tap (`PC=0`) because `@available(iOS 13, *)` compiles to a runtime symbol (`___isOSVersionAtLeast`) that is unresolvable in sideloaded dylibs. Replaced with `NSProcessInfo` runtime checks.
- **Settings labels now visible** — iOS 26 ignores `UITableViewCell.textLabel`. Switched to `UIListContentConfiguration` with a fallback for older OS versions.
- **Proxy address field now visible** — The custom proxy text field had a broken frame-based layout (width calculated as 0 at cell creation time). Replaced with Auto Layout constraints.
- **Ad blocking fixed for Twitch 29.x** — Twitch renamed the GraphQL operation (`StreamAccessToken` → `PlaybackAccessToken`), moved the platform field (`variables.params.platform` → `variables.playerType`), and switched to Apollo batched requests (JSON arrays). Updated `NSData+TwitchAdBlock` to handle all of these.
- **Authenticated proxy support** — Added support for `user:pass@host:port` proxy format with proper HTTP proxy authentication via `NSURLAuthenticationMethodHTTPProxy`.
- **Settings refactored** — Replaced the Logos `%subclass` settings view controller with a plain Objective-C class (`TWABSettingsVC`) to avoid Logos registration failures in sideloaded dylibs.

See [CHANGELOG.md](CHANGELOG.md) for full details.

---

## Building from source

### Requirements

- Windows 10/11 with WSL (Ubuntu) — or any Linux/macOS machine
- [Theos](https://theos.dev/docs/installation) installed in WSL at `~/theos`
- A **decrypted** Twitch IPA (the App Store IPA is encrypted and cannot be patched)
- Python 3

### 1. Install Theos (first time only)

Open WSL and run:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/theos/theos/master/bin/install-theos)"
```

### 2. Clone this repo

```bash
git clone https://github.com/gunnerkidBT/TwitchAdBlock.git
cd TwitchAdBlock
git submodule update --init --recursive
```

### 3. Build the dylib

```bash
export THEOS=~/theos
export PATH=$THEOS/bin:$PATH
make SIDELOADED=1
```

The compiled dylib will be at `.theos/obj/debug/TwitchAdBlock.dylib`.

### 4. Inject into the IPA

```bash
python3 inject_ipa.py /path/to/Twitch-decrypted.ipa \
    .theos/obj/debug/TwitchAdBlock.dylib \
    Twitch-patched.ipa
```

> `inject_ipa.py` lives at the repo root. It does three things: copies the dylib into `Payload/Twitch.app/Frameworks/`, injects an `LC_LOAD_DYLIB` load command into the Twitch Mach-O binary, and patches `NSAppTransportSecurity.NSAllowsArbitraryLoads = true` into `Info.plist` so plain-HTTP proxy traffic isn't blocked by iOS ATS.

### 5. Install

| Method | Steps |
|--------|-------|
| **TrollStore** | Open TrollStore → tap `+` → select the patched IPA |
| **AltStore / SideStore** | Drag the patched IPA into the app to sideload and sign |

> **A note on CI builds**: The `.github/workflows/build.yml` workflow can in principle build an IPA via `workflow_dispatch` with `create_release=true`, but the IPA-download step depends on **decryptedappstore.com** which is currently unreachable. Until that's resolved, IPA builds are local-only.

---

## Original project

- **Author:** [level3tjg](https://github.com/level3tjg)
- **Source:** https://github.com/level3tjg/TwitchAdBlock
- **License:** MIT

This fork is also released under the MIT license in keeping with the original. See [LICENSE](LICENSE).
