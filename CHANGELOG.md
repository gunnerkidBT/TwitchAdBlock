# What's New

A plain-language list of what's changed in TwitchMods — what each update
actually *does for you*, in normal words. Newest changes are at the top.

---

## v0.1.15 — October 24, 2026

**See what moderators delete.** Turn on **Keep Deleted Messages** in
Settings → Emotes. When a moderator deletes a message, or times out or bans
someone, their messages stay in chat instead of disappearing, and a short note
like "🛡 ronni was timed out for 10m" shows up so you know what happened. Want
the notes to stand out? Turn on **Highlight Notes**, which appears right under
it, to give them a highlighted background. Both are off by default. It only
works for things that happen while you're in chat.

**Hide the "From channels you follow" bar.** Turn on **Hide "From Channels
You Follow"** in Settings → Home to remove the row of clips and recaps above the
live channels on the Live page.

**The "Go Ad-Free" button on the Following tab is hidden again.** Twitch 31.7
rebuilt that tab, so the old way of hiding it stopped working.

---

## v0.1.14 — October 24, 2026

**Works with Twitch 31.7.** This is a big Twitch update: parts of the app are
now built differently under the hood. Ad-blocking, 3rd-party emotes, the
Following tab's ad cleanup, **Keep Live Feed Playing**, **Hide Twitch Stories**
and your **default launch screen** have all been updated to keep working with it.
Also fixed: the app crashing when you scrolled down to TwitchMods in Settings.

**You can now send 7TV, BetterTTV and FrankerFaceZ emotes, not just see them.**
When you tap into chat to type, a **7TV** bar appears just above the keyboard
(on older versions of Twitch's chat it's a 7TV button next to Twitch's own emote
button instead). Tap it to see all the emotes for the channel you're watching,
plus the global ones. Animated emotes move in the picker, just like in chat.
Search by name, tap one, and it's typed into your message. Your most recent
picks show up at the top. Anyone in chat who uses 7TV, BTTV or FFZ (or this mod)
sees the emote.

You can also **press and hold Twitch's own emote button** to open the same
picker. If you'd rather not have the bar, turn on **Hide 7TV Bar** in
Settings → Emotes. Press-and-hold keeps working. Turning off
**3rd-Party Emotes** removes both.

**Get updates automatically in AltStore, SideStore or Feather.** Add this
source and the app will tell you when a new TwitchMods version is out, even
when only the mod changed and the Twitch version stayed the same:
`https://raw.githubusercontent.com/gunnerkidBT/TwitchAdBlock/master/apps.json`

(Heads up: your *own* message still shows the emote as its name on your screen.
Twitch draws your messages itself, so the mod can't swap in the picture there.
Everyone else sees the picture.)

---

## v0.1.13 — August 13, 2026

**Casting and AirPlay to a TV now work with ad-blocking on.** Before, having the
ad-block proxy turned on could make casting to a Chromecast crash after a few
seconds, or make AirPlay to an Apple TV show "offline." Now the mod
automatically steps aside while you're actually casting or AirPlaying, so the
stream plays on the TV normally — and your phone goes right back to blocking ads
the moment you stop. (The stream playing *on the TV* still shows ads — that part
can't be blocked, since the TV fetches the video itself — but your phone stays
ad-free.)

---

## August 11, 2026 — Works with Twitch 30.7

Updated to run on the latest Twitch app (**30.7**). No feature changes — just
making sure everything keeps working after Twitch's update. (Same v0.1.12
features as below.)

---

## July 7, 2026 — Works with Twitch 30.2

Updated to run on the latest Twitch app (**30.2**). No feature changes — just
making sure everything keeps working after Twitch's update. (Same v0.1.12
features as below.)

---

## v0.1.12 — June 25, 2026

**The Live tab keeps playing now.** It used to stop the stream after a while
and force you to tap *Watch* or *Follow* to keep going. That's gone — live
streams just keep playing. (On by default. Toggle: Home & Playback → "Keep
Live Feed Playing".)

**Hid the "Go Ad-Free" button.** The Turbo upsell banner that shows up on the
Following tab is now hidden. (On by default. Toggle: Ad Blocking → Hide
"Go Ad-Free" Button.)

**Blocks a few more ads.** Added blocking for streamer-read sponsor ad spots,
and improved the behind-the-scenes detection so new kinds of ads are easier
to catch in the future.

**New "Reload Emotes" button.** If a streamer adds new 7TV/BTTV/FFZ emotes
while you're watching, you can now refresh them without restarting the app.
(Settings → Emotes → Reload Emotes.)

**Back up and restore your settings.** You can now export all your settings
(toggles + proxy list) to a file and import it back later — handy when you
have to reinstall. Export saves a dated file like
`TwitchMods-Settings-2026-06-25.json`; import lets you pick that file.
(Settings → Tools.)

**New Diagnostics screen.** Shows a quick green/red checklist of whether the
mod's features still work on your version of Twitch — useful for spotting
when a Twitch update breaks something. (Settings → Tools → Diagnostics.)

**Settings are easier to read.** Each option now has a short description right
underneath it, and everything is grouped under clear headings (Ad Blocking,
Proxy, Emotes, Home & Playback, Tools).

---

## June 12, 2026 — Works with the latest Twitch app

Updated to keep working with newer versions of the Twitch app (29.8, and now
29.9). No feature changes — just making sure everything keeps running after
Twitch's own updates.

---

## May 18, 2026

**Animated emotes actually move now.** 7TV / BTTV / FrankerFaceZ animated
emotes used to show as a frozen single frame — now they animate in chat.

**Fixed emotes being off for some people.** On certain installs the 3rd-party
emotes switch was stuck off even though it should be on by default. Fixed, and
it now turns itself on once so it sticks.

---

## May 17, 2026

**Use more than one proxy.** You can now add a list of proxies with up/down
buttons to set the order, instead of just one. If the first is down, it falls
back to the next. Swipe to delete.

**Ad blocking now works on recorded videos (VODs) too,** not just live streams.

---

## May 16, 2026

**Big proxy upgrade.** Ad-blocking proxies now work with a lot more proxy
services — including paid ones that need a username/password, and ones that
need a different connection method. Set it up once and it just works.

**Subscribers/Turbo users are left alone.** If you already pay for an ad-free
experience, the mod skips the proxy entirely (no point, and it keeps your
account info private).

**Pick which screen Twitch opens to.** New "Launch Screen" setting lets you
start on Following, Live, Clips, Browse, Activity, or your Profile instead of
Twitch's default.

**Hide the Stories bar** at the top of the Home tab, if you don't use it.

**Proxy status indicator.** Settings now shows whether your proxy is Online,
Offline, or still checking.

**Blocks more banners** — the "buy Bits" prompt and brand/sponsor offer
banners (like fast-food promos) in the feed.

**Renamed to "TwitchMods"** in the menus and settings.

**Ad-block proxy is on by default** for new installs.

---

## May 15, 2026

**Third-party emotes added!** 7TV, BetterTTV, and FrankerFaceZ emotes now show
up inline in chat right next to normal Twitch emotes. Channel emotes load
automatically when you open a stream. There's an on/off switch in settings.

*Heads up:* your own messages won't show these emotes on your screen (Twitch
handles your own messages differently), but everyone else watching sees them
fine.

---

## May 7, 2026

**Lots of fixes to get ad blocking working on the current Twitch app** and to
stop the settings screen from crashing. Also added support for proxies that
need a username and password, and immediate blocking of known ad-serving
sites.
