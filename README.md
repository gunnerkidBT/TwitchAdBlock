# TwitchAdBlock (Unofficial Fork)

> **This isn't my original project.** TwitchAdBlock was created by
> [level3tjg](https://github.com/level3tjg/TwitchAdBlock) — all credit for the
> original idea and work goes to them. This fork just keeps it working on newer
> versions of Twitch and iOS, and adds a few extra options. Please **don't**
> report issues with this fork to the original author.
>
> The changes here were made with the help of Claude (Anthropic AI); I'm not an
> iOS developer.

In the app, this shows up as **"TwitchMods"** — open it from the row in your
account menu, where every feature below has its own on/off switch.

---

## What it does

A modified Twitch iOS app that blocks ads and adds some handy extras.

### Blocks ads
- Skips the unskippable pre-roll ads before **live streams** and **recorded
  videos (VODs)** by routing through an ad-free-country proxy.
- Clears ad banners and prompts out of the feeds — brand offers, the "buy Bits"
  prompt, sponsor spots, and the **"Go Ad-Free"** / **"Try Ad-Free"** Turbo
  buttons (Following tab and your profile).
- Works out of the box with several built-in servers in different countries:
  it checks them in the background, spreads streams across the ones that work
  and switches automatically if one goes down. Pick a country yourself if you
  like, or add your own proxies.
- The server list updates by itself, so broken or slow servers can be swapped
  out without an app update.
- **Block Tracking** — stops Twitch's usage tracking, crash reports and ad
  measurement from being sent.
- Skips the proxy automatically if you already have a subscription or Turbo —
  you're already ad-free, and it keeps your account details private. You can
  also pick channels to always skip it for.

### Chat emotes
- Shows **7TV**, **BetterTTV**, and **FrankerFaceZ** emotes right in chat, both
  global and per-channel, animated ones included. A channel's own emote wins
  over a global one with the same name, like the 7TV browser extension.
- **Fast:** each channel's emote list is remembered between launches, and
  emotes download in a small format, so they show up almost instantly even in
  busy chats.
- **Wide emotes at full size** — wide emotes keep their shape and show as tall
  as normal ones, and the chat line makes room for them so nothing overlaps.
- **Send them too:** type an emote's name, pick it from Twitch's own emote
  picker (third-party emotes get their own sections there), or use the **7TV**
  bar above the keyboard (or press and hold Twitch's emote button) for a
  searchable list. Your own messages show the emotes right away, and the chat
  box previews them while you type.
- A **Reload Emotes** button to refresh them if a streamer adds new ones while
  you're watching.

### Chat
- **Emote Size** and **Chat Text Size** — make emotes and chat messages bigger
  (Default, Large, Extra Large) without changing the rest of the app.
- **Keep Deleted Messages** — see messages a moderator removed, with an
  optional highlighted note.
- **Auto-Claim Bonus Points** — collects the channel points bonus for you.

### Make the app yours
- **Keep Live Feed Playing** — stops the Live feed cutting a stream off and
  forcing you to tap Watch or Follow.
- **Pick your launch screen** — open straight to Following, Live, Clips, Browse,
  and more, instead of Twitch's default.
- **Declutter** — hide the things you don't use: Stories, "From Channels You
  Follow", the leaderboard, Subscribe/Bits/Clip/Extensions buttons, the channel
  bar, the "+" (Create) tab, and banners above chat (pinned messages, hype
  trains, predictions, polls, sub goals, Drops).
- Clearer settings — a short description under each option, grouped under
  headings.

### Extras
- **Back up & restore** all your settings to a file (handy when you reinstall).
- **Diagnostics** screen — a quick green/red check that everything still works
  after a Twitch update.

For a plain-language list of everything that's changed, see
[CHANGELOG.md](CHANGELOG.md).

---

## Get it

### Add the source (get update notifications)

Add this source in **AltStore**, **SideStore** or **Feather** to install
TwitchMods and be told when a new version comes out:

```
https://raw.githubusercontent.com/gunnerkidBT/TwitchAdBlock/master/apps.json
```

- **AltStore / SideStore:** Sources tab → **+** → paste the link → install
  **TwitchMods** from the source.
- **Feather:** Sources → **+** → paste the link.

The source installs the full app. If you're on a free Apple ID and run out of
App IDs, AltStore offers to remove the app extensions for you. You can also use
the `-noplugins` IPA from Releases instead.

### Or download the IPA

Grab it from the [Releases](https://github.com/gunnerkidBT/TwitchAdBlock/releases)
page and install it with AltStore / SideStore (drag in the IPA) or TrollStore
(tap **+**, pick the IPA).

### Jailbroken?

Each release also has a `.deb`: `iphoneos-arm` for rootful jailbreaks
(unc0ver, checkra1n) and `iphoneos-arm64` for rootless ones (Dopamine,
palera1n). Install it with your package manager.

---

## Why this fork exists

The original stopped working on recent Twitch and iOS versions when sideloaded
(no jailbreak). This fork fixes that, keeps it up to date with new Twitch
releases, and adds the extras above.

---

## Building it yourself

You only need this if you want to compile from source. Otherwise grab a
prebuilt IPA from the [Releases](https://github.com/gunnerkidBT/TwitchAdBlock/releases)
page and jump to **Install**.

**You'll need**

- Windows with WSL (Ubuntu), or any Linux/macOS machine
- [Theos](https://theos.dev/docs/installation) installed at `~/theos`
- A **decrypted** Twitch IPA (the App Store version is encrypted and can't be
  patched)
- Python 3

**Steps**

1. Install Theos (first time only):

   ```bash
   bash -c "$(curl -fsSL https://raw.githubusercontent.com/theos/theos/master/bin/install-theos)"
   ```

2. Clone and build:

   ```bash
   git clone https://github.com/gunnerkidBT/TwitchAdBlock.git
   cd TwitchAdBlock
   git submodule update --init --recursive
   export THEOS=~/theos
   make SIDELOADED=1
   ```

3. Inject the built tweak into your decrypted IPA:

   ```bash
   python3 inject_ipa.py /path/to/Twitch-decrypted.ipa \
       .theos/obj/debug/TwitchAdBlock.dylib \
       Twitch-patched.ipa
   ```

   (This drops the tweak into the app and lets it load plain-HTTP proxy traffic.)
   Add `--no-plugins` to strip the app extensions (fewer App IDs on a free
   Apple ID).

**Building the jailbreak debs**

```bash
make package FINALPACKAGE=1                               # rootful (iphoneos-arm)
make clean
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless # rootless (iphoneos-arm64)
```

On WSL, build from a copy of the repo inside your Linux home folder: files on
the Windows drive show up with permissions `dpkg-deb` refuses ("control
directory has bad permissions 777").

**Publishing a release (maintainer)**

1. Bump `Version:` in `control` and `PACKAGE_VERSION` in the `Makefile`, and
   add a `## vX.Y.Z` section to CHANGELOG.md.
2. Inject with `--mod-version`, so each mod release gets its own build number.
   That's how AltStore knows there's an update when only the mod changed. Build
   the `--no-plugins` IPA and both debs as well:

   ```bash
   python3 inject_ipa.py Twitch-decrypted.ipa .theos/obj/debug/TwitchAdBlock.dylib \
       tv.twitch-32.1-TwitchAdBlock-0.1.24.ipa --mod-version 0.1.24
   ```

3. Upload the IPAs and debs to a GitHub release tagged like `v32.1-0.1.24`.
4. Add the release to the source and commit `apps.json`:

   ```bash
   python3 make_source.py tv.twitch-32.1-TwitchAdBlock-0.1.24.ipa --tag v32.1-0.1.24
   ```

   The "What's New" text comes from the matching `## v0.1.24` section of
   CHANGELOG.md. For a Twitch-only rebuild, pass e.g. `--heading "Twitch 32.2"`.
   Every version in `apps.json` needs a unique build number, or AltStore
   rejects the whole source.

**Changing the default servers (maintainer)**

Apps download `proxies.json` from this repo at launch, so servers can be
added, removed or swapped without a new release:

1. Edit `proxies.local.txt` (not committed), one server per line:
   `Name | user:pass@host:port`, adding `| backup` for servers that should
   only be used when the others are down.
2. Run `python make_proxies.py` (needs `pip install cryptography`). It
   writes `proxies.json` and `Secrets.h` (the list built into the app). `--show` prints what's in `proxies.json`, and
   `--builtin` sends apps back to their built-in list.
3. Commit and push `proxies.json`. Apps pick it up next time they open, or
   when they come back after a few hours. Rebuild at release time so the
   built-in list matches.

`proxies.key` (created on first run), `Secrets.h` and `proxies.local.txt`
are never committed. Keep `proxies.key`: released apps can only read lists
made with it. Building without `Secrets.h` works, but the app then has no
default servers (Custom Proxy only).

If the file is missing or invalid, apps keep the last list they had, or the
built-in one.

**Install**

| Method | Steps |
|--------|-------|
| **TrollStore** | Open TrollStore → tap `+` → pick the patched IPA |
| **AltStore / SideStore** | Drag the patched IPA into the app to install and sign |

---

## Community

Join the Telegram group for updates, help, and discussion:
**https://t.me/+gj-e1h1I6d1lYjhh**

---

## Credits & license

- Original project by [level3tjg](https://github.com/level3tjg) —
  <https://github.com/level3tjg/TwitchAdBlock>
- Released under the MIT license, same as the original. See [LICENSE](LICENSE).
