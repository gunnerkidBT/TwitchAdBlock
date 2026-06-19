#!/usr/bin/env python3
"""
inject_ipa.py
Extracts the Twitch IPA, copies the compiled dylib into Frameworks/,
injects an LC_LOAD_DYLIB load command into the Twitch Mach-O binary,
and repacks into a new IPA ready for sideloading.

Usage:
    python3 inject_ipa.py <input.ipa> <TwitchTTVLOL.dylib> [output.ipa] [--no-plugins]

Options:
    --no-plugins   Strip Payload/<App>.app/PlugIns (all app extensions) before
                   repacking. Each extension is a separate bundle ID that
                   consumes an App ID slot when sideloading; removing them lets
                   free Apple ID accounts (10 App IDs / 7 days) install the app.
"""

import struct
import sys
import zipfile
import shutil
import os
import tempfile
import plistlib

# Mach-O constants
MH_MAGIC_64          = 0xFEEDFACF
MH_CIGAM_64          = 0xCFFAEDFE
LC_LOAD_DYLIB        = 0x0000000C
LC_ENCRYPTION_INFO   = 0x00000021  # 32-bit
LC_ENCRYPTION_INFO_64 = 0x0000002C # 64-bit
DYLIB_INSTALL_NAME   = None  # set at runtime from dylib filename


def align_up(n, align):
    return (n + align - 1) & ~(align - 1)


def clear_cryptid(binary: bytes) -> bytes:
    """Zero out cryptid in LC_ENCRYPTION_INFO / LC_ENCRYPTION_INFO_64 so dyld doesn't re-decrypt."""
    magic = struct.unpack_from("<I", binary)[0]
    if magic != MH_MAGIC_64:
        return binary

    hdr_fmt  = "<8I"
    hdr_size = struct.calcsize(hdr_fmt)
    _, _, _, _, ncmds, _, _, _ = struct.unpack_from(hdr_fmt, binary)

    out = bytearray(binary)
    pos = hdr_size
    patched = 0
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", binary, pos)
        if cmd in (LC_ENCRYPTION_INFO, LC_ENCRYPTION_INFO_64):
            # encryption_info_command: cmd(4) cmdsize(4) cryptoff(4) cryptsize(4) cryptid(4)
            cryptid_offset = pos + 16
            cryptid = struct.unpack_from("<I", binary, cryptid_offset)[0]
            if cryptid != 0:
                struct.pack_into("<I", out, cryptid_offset, 0)
                print(f"  Cleared cryptid ({cryptid} -> 0) in load command at offset {pos:#x}")
                patched += 1
            else:
                print(f"  cryptid already 0 at offset {pos:#x} — no change needed")
        pos += size

    if patched == 0 and not any(
        struct.unpack_from("<II", binary, p)[0] in (LC_ENCRYPTION_INFO, LC_ENCRYPTION_INFO_64)
        for p in _cmd_offsets(binary, ncmds, hdr_size)
    ):
        print("  No LC_ENCRYPTION_INFO found — binary may already be fully decrypted")

    return bytes(out)


def _cmd_offsets(binary, ncmds, start):
    pos = start
    for _ in range(ncmds):
        yield pos
        size = struct.unpack_from("<I", binary, pos + 4)[0]
        pos += size


def inject_load_dylib(binary: bytes, install_name: bytes) -> bytes:
    """Add LC_LOAD_DYLIB for the given install name to a single-arch arm64 Mach-O."""
    magic = struct.unpack_from("<I", binary)[0]
    if magic != MH_MAGIC_64:
        raise ValueError(f"Not a 64-bit little-endian Mach-O (magic={magic:#010x})")

    # Parse header
    # struct mach_header_64: magic cputype cpusubtype filetype ncmds sizeofcmds flags reserved
    hdr_fmt  = "<8I"
    hdr_size = struct.calcsize(hdr_fmt)  # 32 bytes
    magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, reserved = \
        struct.unpack_from(hdr_fmt, binary)

    load_cmds_start = hdr_size
    load_cmds_end   = load_cmds_start + sizeofcmds

    # Build new LC_LOAD_DYLIB command
    name_bytes = install_name
    name_padded = name_bytes + b"\x00" * (align_up(len(name_bytes), 8) - len(name_bytes))
    # dylib_command header: cmd(4) + cmdsize(4) + name.offset(4) + timestamp(4)
    #                        + current_version(4) + compatibility_version(4) = 24 bytes
    dylib_hdr_size = 24
    cmd_size = dylib_hdr_size + len(name_padded)
    cmd_size = align_up(cmd_size, 8)

    new_cmd = struct.pack("<IIIII",
        LC_LOAD_DYLIB,
        cmd_size,
        dylib_hdr_size,  # name offset from start of command
        0,               # timestamp
        0x00010000,      # current_version (1.0)
    )
    new_cmd += struct.pack("<I", 0x00010000)  # compatibility_version
    new_cmd += name_padded
    # Pad to cmd_size
    new_cmd += b"\x00" * (cmd_size - len(new_cmd))
    assert len(new_cmd) == cmd_size

    # Free space = gap between end of load commands and start of the first section's
    # actual file content. On iOS MH_EXECUTE binaries the __TEXT segment fileoff is 0
    # (load commands live inside it), so we must look at section offsets, not segment offsets.
    first_section_fileoff = None
    pos = load_cmds_start
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", binary, pos)
        if cmd == 0x19:  # LC_SEGMENT_64 — header is 72 bytes, then nsects * 80-byte section_64
            nsects = struct.unpack_from("<I", binary, pos + 64)[0]
            for i in range(nsects):
                # section_64.offset is a uint32_t at byte 48 within section_64
                sect_base = pos + 72 + i * 80
                sect_off  = struct.unpack_from("<I", binary, sect_base + 48)[0]
                if sect_off > 0:
                    if first_section_fileoff is None or sect_off < first_section_fileoff:
                        first_section_fileoff = sect_off
        pos += size

    if first_section_fileoff is None:
        raise ValueError("Could not find any section file offsets")

    free_space = first_section_fileoff - load_cmds_end
    print(f"  Load commands end at offset  {load_cmds_end:#x}")
    print(f"  First section content at     {first_section_fileoff:#x}")
    print(f"  Free space available:       {free_space} bytes")
    print(f"  New LC_LOAD_DYLIB size:     {cmd_size} bytes")

    if free_space < cmd_size:
        raise RuntimeError(
            f"Not enough free space ({free_space}B) to inject {cmd_size}B load command. "
            "This binary is too tightly packed — try a different Twitch version."
        )

    # Check the dylib isn't already injected
    existing = binary[load_cmds_start:load_cmds_end]
    dylib_name_short = install_name.rstrip(b"\x00").split(b"/")[-1]
    if dylib_name_short in existing:
        print(f"  {dylib_name_short.decode(errors='replace')} already present — skipping injection.")
        return binary

    # Patch: insert new command right after existing load commands, update header
    out = bytearray(binary)

    # Write new command into the free space
    out[load_cmds_end:load_cmds_end + cmd_size] = new_cmd

    # Update ncmds and sizeofcmds in the header
    new_ncmds      = ncmds + 1
    new_sizeofcmds = sizeofcmds + cmd_size
    struct.pack_into("<I", out, 16, new_ncmds)
    struct.pack_into("<I", out, 20, new_sizeofcmds)

    print(f"  Injected LC_LOAD_DYLIB (ncmds {ncmds} -> {new_ncmds}, "
          f"sizeofcmds {sizeofcmds} -> {new_sizeofcmds})")
    return bytes(out)


def patch_ats(plist_path: str) -> None:
    """Set NSAppTransportSecurity.NSAllowsArbitraryLoads = True so the tweak
    can route playlist requests through plain-HTTP proxies. iOS otherwise
    blocks any non-HTTPS NSURLSession traffic and the proxy ping fails with
    a -1 ATS error."""
    with open(plist_path, "rb") as f:
        data = f.read()
    fmt = plistlib.FMT_BINARY if data.startswith(b"bplist") else plistlib.FMT_XML
    plist = plistlib.loads(data)
    ats = plist.get("NSAppTransportSecurity", {})
    if ats.get("NSAllowsArbitraryLoads") is True:
        print("  NSAllowsArbitraryLoads already True — no change")
        return
    ats["NSAllowsArbitraryLoads"] = True
    plist["NSAppTransportSecurity"] = ats
    with open(plist_path, "wb") as f:
        plistlib.dump(plist, f, fmt=fmt)
    print(f"  Set NSAppTransportSecurity.NSAllowsArbitraryLoads = True")


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)

    args        = sys.argv[1:]
    no_plugins  = "--no-plugins" in args
    args        = [a for a in args if a != "--no-plugins"]

    ipa_path  = args[0]
    dylib_src = args[1]
    out_path  = args[2] if len(args) > 2 else ipa_path.replace(".ipa", "-patched.ipa")

    print(f"[1/5] Reading IPA: {ipa_path}")
    with zipfile.ZipFile(ipa_path, "r") as z:
        names = z.namelist()

    # Find app bundle name — entries look like "Payload/Twitch.app/somefile"
    app_name = None
    for n in names:
        parts = n.split("/")
        if len(parts) >= 2 and parts[0] == "Payload" and parts[1].endswith(".app"):
            app_name = parts[1]  # e.g. "Twitch.app"
            break
    if not app_name:
        raise RuntimeError("Could not find .app bundle in IPA")

    binary_name  = app_name.replace(".app", "")  # e.g. "Twitch"
    dylib_fname  = os.path.basename(dylib_src)   # e.g. "TwitchAdBlock.dylib"
    install_name = f"@executable_path/Frameworks/{dylib_fname}".encode() + b"\x00"

    binary_zip_path = f"Payload/{app_name}/{binary_name}"
    dylib_zip_path  = f"Payload/{app_name}/Frameworks/{dylib_fname}"

    print(f"  App bundle  : {app_name}")
    print(f"  Binary path : {binary_zip_path}")
    print(f"  Dylib name  : {dylib_fname}")

    print(f"[2/5] Extracting IPA to temp dir...")
    tmpdir = tempfile.mkdtemp(prefix="ttvlol_")
    try:
        with zipfile.ZipFile(ipa_path, "r") as z:
            z.extractall(tmpdir)

        if no_plugins:
            plugins_dir = os.path.join(tmpdir, f"Payload/{app_name}/PlugIns")
            if os.path.isdir(plugins_dir):
                removed = sorted(
                    d for d in os.listdir(plugins_dir)
                    if d.endswith(".appex")
                )
                shutil.rmtree(plugins_dir)
                print(f"  Stripped PlugIns/ — removed {len(removed)} app extension(s):")
                for d in removed:
                    print(f"      - {d}")
            else:
                print("  --no-plugins set but no PlugIns/ directory found — nothing to strip")

        binary_path = os.path.join(tmpdir, binary_zip_path)
        frameworks_dir = os.path.join(tmpdir, f"Payload/{app_name}/Frameworks")
        dylib_dest = os.path.join(frameworks_dir, dylib_fname)

        print(f"[3/5] Copying dylib -> {dylib_zip_path}")
        os.makedirs(frameworks_dir, exist_ok=True)
        shutil.copy2(dylib_src, dylib_dest)

        print(f"[4/6] Patching Mach-O binary...")
        with open(binary_path, "rb") as f:
            binary_data = f.read()

        binary_data = clear_cryptid(binary_data)
        patched = inject_load_dylib(binary_data, install_name)

        with open(binary_path, "wb") as f:
            f.write(patched)

        print(f"[5/6] Patching Info.plist (ATS bypass for plain-HTTP proxy)...")
        info_plist = os.path.join(tmpdir, f"Payload/{app_name}/Info.plist")
        if os.path.exists(info_plist):
            patch_ats(info_plist)
        else:
            print(f"  WARNING: {info_plist} not found — proxy routing will fail with ATS errors")

        print(f"[6/6] Repacking IPA -> {out_path}")
        payload_dir = os.path.join(tmpdir, "Payload")
        with zipfile.ZipFile(out_path, "w", zipfile.ZIP_DEFLATED) as zout:
            # Preserve iTunesArtwork / iTunesMetadata if present
            for extra in ["iTunesArtwork", "iTunesMetadata.plist"]:
                ep = os.path.join(tmpdir, extra)
                if os.path.exists(ep):
                    zout.write(ep, extra)

            for root, dirs, files in os.walk(payload_dir):
                for file in files:
                    fpath = os.path.join(root, file)
                    arcname = "Payload/" + os.path.relpath(fpath, payload_dir)
                    zout.write(fpath, arcname)

        print(f"\nDone! Patched IPA: {out_path}")
        print("\nNext steps:")
        print("  AltStore / SideStore : drag the IPA into AltStore to install & sign")
        print("  TrollStore           : run  ldid -S  on the binary inside, then install")

    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


if __name__ == "__main__":
    main()
