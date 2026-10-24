#!/usr/bin/env python3
"""
make_source.py
Adds a release to apps.json, the AltStore / SideStore / Feather source for
TwitchMods. Everything AltStore checks against the download (version, build,
minimum iOS, entitlements, privacy prompts, size) is read from the IPA itself,
so the source can't drift from the file people install.

Usage:
    python3 make_source.py <release.ipa> --tag v30.7-0.1.14
                           [--heading "v0.1.14"] [--date 2026-10-24T12:00:00Z]

    <release.ipa>  The exact full IPA uploaded to the GitHub release (not the
                   -noplugins one; the source lists one IPA per app).
    --tag          The GitHub release tag. The IPA's download link is
                   releases/download/<tag>/<ipa file name>.
    --heading      Which CHANGELOG.md section becomes the "What's New" text:
                   the first "## " heading containing this text. Defaults to
                   "v<mod version>" from the tag (e.g. "v0.1.14"). For Twitch
                   compatibility rebuilds use e.g. --heading "Twitch 30.2".
    --date         Release date (ISO 8601). Defaults to now (UTC).

Re-running with the same tag replaces that entry, so it's safe to redo.
Build the IPA with `inject_ipa.py ... --mod-version X.Y.Z` so each mod
release has its own build number — that's what lets AltStore offer an update
when only the mod changed (same Twitch version).
"""

import argparse
import datetime
import json
import os
import plistlib
import re
import struct
import sys
import zipfile

REPO = "gunnerkidBT/TwitchAdBlock"
HERE = os.path.dirname(os.path.abspath(__file__))
SOURCE_PATH = os.path.join(HERE, "apps.json")
CHANGELOG_PATH = os.path.join(HERE, "CHANGELOG.md")
RAW = f"https://raw.githubusercontent.com/{REPO}/master"
TINT = "9146FF"  # Twitch purple

APP_DESCRIPTION = (
    "A modified Twitch app that blocks ads and adds some handy extras.\n\n"
    "• Blocks pre-roll ads on live streams and VODs, plus feed banners, sponsor "
    "spots and the \"Go Ad-Free\" button\n"
    "• Shows 7TV, BetterTTV and FrankerFaceZ emotes in chat — and lets you send them\n"
    "• Keeps the Live feed playing, hides Stories, picks your launch screen\n\n"
    "Open TwitchMods from your account menu to switch each feature on or off.\n\n"
    "Unofficial fork of level3tjg's TwitchAdBlock. Not affiliated with Twitch."
)


def base_source():
    return {
        "name": "TwitchMods",
        "identifier": "com.gunnerkidbt.twitchmods",
        "subtitle": "Ad-free Twitch with 7TV, BTTV & FFZ emotes",
        "description": APP_DESCRIPTION,
        "iconURL": f"{RAW}/assets/icon.png",
        "website": f"https://github.com/{REPO}",
        "tintColor": TINT,
        "featuredApps": ["tv.twitch"],
        "apps": [{
            "name": "TwitchMods",
            "bundleIdentifier": "tv.twitch",
            "developerName": "gunnerkidBT",
            "subtitle": "Ad-free Twitch with 7TV, BTTV & FFZ emotes",
            "localizedDescription": APP_DESCRIPTION,
            "iconURL": f"{RAW}/assets/icon.png",
            "tintColor": TINT,
            "category": "entertainment",
            "versions": [],
        }],
        "news": [],
    }


# ─── IPA inspection ──────────────────────────────────────────────────────────

def read_entitlements(macho: bytes) -> dict:
    """Entitlements plist embedded in the Mach-O code signature, or {}."""
    magic = struct.unpack_from("<I", macho, 0)[0]
    if magic == 0xBEBAFECA:  # FAT (big-endian header): use the arm64 slice
        nfat = struct.unpack_from(">I", macho, 4)[0]
        for i in range(nfat):
            cputype, _, offset, size, _ = struct.unpack_from(">IIIII", macho, 8 + i * 20)
            if cputype == 0x0100000C:
                return read_entitlements(macho[offset:offset + size])
        return {}
    if magic != 0xFEEDFACF:
        return {}
    ncmds = struct.unpack_from("<I", macho, 16)[0]
    off = 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", macho, off)
        if cmd == 0x1D:  # LC_CODE_SIGNATURE
            dataoff, datasize = struct.unpack_from("<II", macho, off + 8)
            blob = macho[dataoff:dataoff + datasize]
            sb_magic, _, count = struct.unpack_from(">III", blob, 0)
            if sb_magic != 0xFADE0CC0:
                return {}
            for j in range(count):
                _, boff = struct.unpack_from(">II", blob, 12 + j * 8)
                bmagic, blen = struct.unpack_from(">II", blob, boff)
                if bmagic == 0xFADE7171:  # entitlements (XML plist)
                    return plistlib.loads(blob[boff + 8:boff + blen])
            return {}
        off += cmdsize
    return {}


def inspect_ipa(path: str) -> dict:
    with zipfile.ZipFile(path) as z:
        app = next(n.split("/")[1] for n in z.namelist()
                   if n.startswith("Payload/") and n.split("/")[1].endswith(".app"))
        info = plistlib.loads(z.read(f"Payload/{app}/Info.plist"))
        binary = z.read(f"Payload/{app}/{info['CFBundleExecutable']}")
    privacy = {k: v for k, v in info.items()
               if k.startswith("NS") and k.endswith("UsageDescription")}
    return {
        "bundleIdentifier": info["CFBundleIdentifier"],
        "version": info["CFBundleShortVersionString"],
        "buildVersion": str(info["CFBundleVersion"]),
        "minOSVersion": info.get("MinimumOSVersion"),
        "entitlements": sorted(read_entitlements(binary).keys()),
        "privacy": dict(sorted(privacy.items())),
        "size": os.path.getsize(path),
    }


# ─── Release notes ───────────────────────────────────────────────────────────

def changelog_section(heading: str) -> str:
    with open(CHANGELOG_PATH, encoding="utf-8") as f:
        text = f.read()
    sections = re.split(r"^## ", text, flags=re.M)[1:]
    for sec in sections:
        title, _, body = sec.partition("\n")
        if heading in title:
            body = body.split("\n---")[0].strip()
            # AltStore shows this as plain-ish text; unwrap hard line breaks
            # inside paragraphs so it reflows on a phone.
            # List items ("- ", "* ", "• ") keep their own lines.
            is_list = lambda p: re.match(r"\s*[-*•]\s", p) is not None
            paras = [p if is_list(p) else " ".join(l.strip() for l in p.splitlines())
                     for p in re.split(r"\n\s*\n", body.replace("\r\n", "\n"))]
            return "\n\n".join(paras)
    sys.exit(f'No "## " heading in CHANGELOG.md contains "{heading}" — pass --heading.')


# ─── Main ────────────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("ipa")
    ap.add_argument("--tag", required=True)
    ap.add_argument("--heading")
    ap.add_argument("--date")
    args = ap.parse_args()

    m = re.fullmatch(r"v[\d.]+-(\d+\.\d+\.\d+)", args.tag)
    if not m:
        sys.exit(f"--tag should look like v30.7-0.1.14, got {args.tag}")
    mod_version = m.group(1)
    meta = inspect_ipa(args.ipa)
    if meta["bundleIdentifier"] != "tv.twitch":
        sys.exit(f"Unexpected bundle ID {meta['bundleIdentifier']}")
    date = args.date or datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    notes = changelog_section(args.heading or f"v{mod_version}")
    filename = os.path.basename(args.ipa)

    entry = {
        "version": meta["version"],
        "buildVersion": meta["buildVersion"],
        "date": date,
        "localizedDescription": f"TwitchMods {mod_version} for Twitch {meta['version']}\n\n{notes}",
        "downloadURL": f"https://github.com/{REPO}/releases/download/{args.tag}/{filename}",
        "size": meta["size"],
        "minOSVersion": meta["minOSVersion"],
    }

    if os.path.exists(SOURCE_PATH):
        with open(SOURCE_PATH, encoding="utf-8") as f:
            source = json.load(f)
    else:
        source = base_source()
    app = source["apps"][0]
    versions = [v for v in app["versions"]
                if not v["downloadURL"].split("/download/")[1].startswith(args.tag + "/")]
    versions.append(entry)
    versions.sort(key=lambda v: v["date"], reverse=True)
    app["versions"] = versions

    # Newest release drives the app-level fields: AltStore 2 permissions, plus
    # the legacy single-version fields older AltStore / Feather / ESign read.
    latest = versions[0]
    if latest is entry:
        app["appPermissions"] = {"entitlements": meta["entitlements"], "privacy": meta["privacy"]}
    for key in ("version", "downloadURL", "size"):
        app[key] = latest[key]
    app["versionDate"] = latest["date"]
    app["versionDescription"] = latest["localizedDescription"]

    with open(SOURCE_PATH, "w", encoding="utf-8", newline="\n") as f:
        json.dump(source, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print(f"apps.json: {args.tag} -> Twitch {meta['version']} build {meta['buildVersion']}, "
          f"{meta['size']:,} bytes, {len(meta['entitlements'])} entitlements"
          f"{' (latest)' if latest is entry else ''}")


if __name__ == "__main__":
    main()
