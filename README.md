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
  prompt, sponsor spots, and the Following-tab **"Go Ad-Free"** Turbo button.
- Works out of the box with a built-in proxy, or you can add your own (including
  a list of backups it tries in order).
- Skips the proxy automatically if you already have a subscription or Turbo —
  you're already ad-free, and it keeps your account details private.

### Chat emotes
- Shows **7TV**, **BetterTTV**, and **FrankerFaceZ** emotes right in chat, both
  global and per-channel.
- A **Reload Emotes** button to refresh them if a streamer adds new ones while
  you're watching.

### Make the app yours
- **Keep Live Feed Playing** — stops the Live feed cutting a stream off and
  forcing you to tap Watch or Follow.
- **Pick your launch screen** — open straight to Following, Live, Clips, Browse,
  and more, instead of Twitch's default.
- **Hide Twitch Stories** — removes the Stories bar at the top of the Home tab.
- Clearer settings — a short description under each option, grouped under
  headings.

### Extras
- **Back up & restore** all your settings to a file (handy when you reinstall).
- **Diagnostics** screen — a quick green/red check that everything still works
  after a Twitch update.

For a plain-language list of everything that's changed, see
[CHANGELOG.md](CHANGELOG.md).

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

**Install**

| Method | Steps |
|--------|-------|
| **TrollStore** | Open TrollStore → tap `+` → pick the patched IPA |
| **AltStore / SideStore** | Drag the patched IPA into the app to install and sign |

---

## Credits & license

- Original project by [level3tjg](https://github.com/level3tjg) —
  <https://github.com/level3tjg/TwitchAdBlock>
- Released under the MIT license, same as the original. See [LICENSE](LICENSE).
