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

## Building from source

You have two paths: **CI build** (easier, no local setup) or **local build** (faster iteration).

### Option A: CI build (recommended)

GitHub Actions builds the IPA automatically when you push a `v*` tag. A draft release is created on the repo with the IPA attached.

```bash
# bump PACKAGE_VERSION in Makefile, update CHANGELOG.md, then:
git tag v0.1.11
git push origin master
git push origin v0.1.11
```

The workflow at [.github/workflows/build.yml](.github/workflows/build.yml) builds rootless + rootful debs and a sideloaded IPA injected into the official Twitch app via theos-jailed. Requires the `DECRYPTEDAPPSTORE_SESSION_TOKEN` secret to be set in the repo so it can pull a decrypted IPA. Branch pushes (no tag) build only the debs as a smoke test.

### Option B: Local build (for fast iteration)

**Requirements:**

- Windows 10/11 with WSL (Ubuntu) — or any Linux/macOS machine
- [Theos](https://theos.dev/docs/installation) installed in WSL at `~/theos`
- A **decrypted** Twitch IPA (the App Store IPA is encrypted and cannot be patched)
- Python 3

#### 1. Install Theos (first time only)

Open WSL and run:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/theos/theos/master/bin/install-theos)"
```

#### 2. Clone this repo

```bash
git clone https://github.com/gunnerkidBT/TwitchAdBlock.git
cd TwitchAdBlock
git submodule update --init --recursive
```

#### 3. Build the dylib

```bash
export THEOS=~/theos
export PATH=$THEOS/bin:$PATH
make SIDELOADED=1
```

The compiled dylib will be at `.theos/obj/debug/TwitchAdBlock.dylib`.

#### 4. Inject into the IPA

```bash
python3 inject_ipa.py /path/to/Twitch-decrypted.ipa \
    .theos/obj/debug/TwitchAdBlock.dylib \
    Twitch-patched.ipa
```

> `inject_ipa.py` is located one directory above this repo at `../inject_ipa.py` if you cloned into the same layout used during development. It does three things: copies the dylib into `Payload/Twitch.app/Frameworks/`, injects an `LC_LOAD_DYLIB` load command into the Twitch Mach-O binary, and patches `NSAppTransportSecurity.NSAllowsArbitraryLoads = true` into `Info.plist` so plain-HTTP proxy traffic isn't blocked by iOS ATS.

### Install the IPA

| Method | Steps |
|--------|-------|
| **TrollStore** | Open TrollStore → tap `+` → select the patched IPA |
| **AltStore / SideStore** | Drag the patched IPA into the app to sideload and sign |

---

## Original project

- **Author:** [level3tjg](https://github.com/level3tjg)
- **Source:** https://github.com/level3tjg/TwitchAdBlock
- **License:** MIT

This fork is also released under the MIT license in keeping with the original. See [LICENSE](LICENSE).
