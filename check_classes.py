#!/usr/bin/env python3
import zipfile

with zipfile.ZipFile("/mnt/c/Users/Brian/twitch/tv.twitch-29.3-Decrypted.ipa") as z:
    with z.open("Payload/Twitch.app/Twitch") as f:
        data = f.read()

names = [
    "TWBaseTableViewController",
    "_TtC12TwitchCoreUI23BaseTableViewController",
    "_TtC6Twitch27SettingsSwitchTableViewCell",
    "_TtC6Twitch12VersionLabel",
    "initWithTableViewStyle:themeManager:",
    "$__lazy_storage_$_switchView",
    "switchView",
    "delegate",
]
for name in names:
    found = name.encode("latin-1") in data
    print(f"{'FOUND  ' if found else 'MISSING'}: {name}")
