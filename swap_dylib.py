#!/usr/bin/env python3
import zipfile, shutil, os, tempfile

base_ipa  = "/mnt/c/Users/Brian/twitch/TwitchAdBlock_23.4-base.ipa"
new_dylib = "/mnt/c/Users/Brian/twitch/TwitchAdBlock/.theos/obj/debug/TwitchAdBlock.dylib"
out_ipa   = "/mnt/c/Users/Brian/twitch/TwitchAdBlock_23.4-patched.ipa"
dylib_arc = "Payload/Twitch.app/Frameworks/TwitchAdBlock.dylib"

tmpdir = tempfile.mkdtemp(prefix="twab_")
try:
    print(f"Extracting {base_ipa}...")
    with zipfile.ZipFile(base_ipa, "r") as z:
        z.extractall(tmpdir)

    dest = os.path.join(tmpdir, dylib_arc)
    shutil.copy2(new_dylib, dest)
    print(f"Replaced dylib ({os.path.getsize(new_dylib)} bytes)")

    print(f"Repacking -> {out_ipa}")
    with zipfile.ZipFile(out_ipa, "w", zipfile.ZIP_DEFLATED) as zout:
        for root, dirs, files in os.walk(tmpdir):
            for f in files:
                fpath = os.path.join(root, f)
                arcname = os.path.relpath(fpath, tmpdir)
                zout.write(fpath, arcname)

    print(f"Done: {out_ipa}")
finally:
    shutil.rmtree(tmpdir, ignore_errors=True)
