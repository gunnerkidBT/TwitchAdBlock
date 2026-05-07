# TwitchAdBlock (Unofficial Fork)

> **This is not my project.** The original TwitchAdBlock was created by [level3tjg](https://github.com/level3tjg/TwitchAdBlock). All credit for the original concept, architecture, and implementation goes to them. This fork exists solely to maintain compatibility with newer versions of Twitch and iOS.

> **The modifications in this fork were made with the assistance of Claude (Anthropic AI).** I am not an iOS developer. Do not report issues in this fork to the original author.

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

## Original project

- **Author:** [level3tjg](https://github.com/level3tjg)
- **Source:** https://github.com/level3tjg/TwitchAdBlock
- **License:** MIT

This fork is also released under the MIT license in keeping with the original. See [LICENSE](LICENSE).
