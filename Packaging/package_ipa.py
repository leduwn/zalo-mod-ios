#!/usr/bin/env python3
"""Package a decrypted Zalo IPA with libZLMod.dylib.

Handles:
1. Extraction of a decrypted Zalo IPA (cryptid=0).
2. Bundle ID validation against Resources/compatibility.json and remapping for
   the main app and all embedded app extensions.
3. Display name customization (default: 'Zalo ZLMod').
4. Injection of libZLMod.dylib into Payload/<App>.app/Frameworks/.
5. LC_LOAD_DYLIB '@rpath/libZLMod.dylib' injection into the main Mach-O.
6. Repacking into an unsigned IPA while preserving Unix executable modes.
7. Verification and preflight forensics (cryptid=0, embedded dylib, load command).
"""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import re
import shutil
import struct
import sys
import tempfile
import zipfile
from pathlib import Path

# Local import
SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = SCRIPT_DIR.parent
sys.path.insert(0, str(SCRIPT_DIR))
from macho_injector import get_load_dylibs, inject_load_dylib

COMPATIBILITY_MANIFEST = PROJECT_ROOT / "Resources" / "compatibility.json"
DEFAULT_DYLIB = PROJECT_ROOT / "build" / "libZLMod.dylib"
ZLMOD_LOAD_COMMAND = "@rpath/libZLMod.dylib"
MACHO_MAGICS = (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xfe\xed\xfa\xce")


def load_supported_bundle_ids(manifest_path: Path = COMPATIBILITY_MANIFEST) -> set[str]:
    payload = json.loads(Path(manifest_path).read_text(encoding="utf-8"))
    return {
        bundle_id
        for target in payload["targets"]
        for bundle_id in target["bundleIdentifiers"]
    }


def validate_bundle_id(bundle_id: str) -> None:
    if bundle_id not in load_supported_bundle_ids():
        raise ValueError(f"unsupported bundle identifier: {bundle_id}")


def remap_child_bundle_id(child_bundle_id: str, original_bundle_id: str, target_bundle_id: str) -> str:
    if child_bundle_id == original_bundle_id:
        return target_bundle_id
    child_prefix = original_bundle_id + "."
    if not child_bundle_id.startswith(child_prefix):
        raise ValueError(f"extension bundle identifier is not a child of {original_bundle_id}: {child_bundle_id}")
    return target_bundle_id + child_bundle_id[len(original_bundle_id):]


def create_owned_work_dir(output_parent: Path, requested: Path | None = None) -> Path:
    output_parent = Path(output_parent).resolve()
    output_parent.mkdir(parents=True, exist_ok=True)
    if requested is None:
        return Path(tempfile.mkdtemp(prefix="zlmod-package-", dir=output_parent))
    requested = Path(requested).resolve()
    if requested.exists():
        raise FileExistsError(f"staging directory already exists: {requested}")
    requested.mkdir(parents=True)
    return requested


def check_macho_cryptid(data: bytes) -> int:
    """Read cryptid from Mach-O binary bytes (0 if unencrypted/decrypted, 1/2 if encrypted)."""
    if len(data) < 32:
        return -1
    magic = struct.unpack("<I", data[:4])[0]
    if magic not in (0xFEEDFACF, 0xFEEDFACE):
        return -1
    is64 = magic == 0xFEEDFACF
    ncmds = struct.unpack("<I", data[16:20])[0]
    offset = 32 if is64 else 28

    for _ in range(ncmds):
        if offset + 8 > len(data):
            break
        cmd, cmdsize = struct.unpack("<II", data[offset : offset + 8])
        if cmdsize < 8:
            break
        if cmd in (0x21, 0x2C):  # LC_ENCRYPTION_INFO, LC_ENCRYPTION_INFO_64
            cryptid = struct.unpack("<I", data[offset + 16 : offset + 20])[0]
            return cryptid
        offset += cmdsize
    return 0  # No encryption command means cryptid=0


def _is_macho_file(path: Path) -> bool:
    try:
        with open(path, "rb") as f:
            return f.read(4) in MACHO_MAGICS
    except OSError:
        return False


def repackage(
    input_ipa: Path,
    output_ipa: Path,
    mod_dylib: Path,
    bundle_id: str = "vn.com.vng.zingalo2",
    display_name: str = "Zalo ZLMod",
    work_dir: Path | None = None,
) -> Path:
    validate_bundle_id(bundle_id)
    if mod_dylib.name != "libZLMod.dylib":
        raise ValueError("dylib must be named libZLMod.dylib")
    print("\n================================================================================")
    print(f"[*] Repackaging ZLMod IPA: {input_ipa.name} -> {output_ipa.name}")
    print(f"    Target Bundle ID:    {bundle_id}")
    print(f"    Display Name:        {display_name}")
    print(f"    Injected Mod Dylib:  {mod_dylib}")
    print("================================================================================")

    if not input_ipa.exists():
        raise FileNotFoundError(f"Input IPA not found: {input_ipa}")
    if not mod_dylib.exists():
        raise FileNotFoundError(f"Mod dylib not found: {mod_dylib}")

    work_dir = create_owned_work_dir(output_ipa.parent, work_dir)
    temp_zip = work_dir.parent / f"{output_ipa.stem}_temp.zip"
    if temp_zip.exists():
        temp_zip.unlink()

    try:
        # 1. Extract IPA and record original Unix permissions
        print(f"[*] Extracting {input_ipa.name}...")
        entry_modes: dict[str, int] = {}
        with zipfile.ZipFile(input_ipa, "r") as zf:
            for info in zf.infolist():
                if not info.is_dir() and (info.external_attr >> 16) != 0:
                    entry_modes[info.filename] = info.external_attr
            zf.extractall(work_dir)

        payload_dir = work_dir / "Payload"
        if not payload_dir.exists():
            raise RuntimeError("Malformed IPA: 'Payload/' directory missing.")

        app_dirs = list(payload_dir.glob("*.app"))
        if len(app_dirs) != 1:
            raise RuntimeError(f"Malformed IPA: Expected 1 .app directory in Payload/, found {len(app_dirs)}")
        app_dir = app_dirs[0]
        print(f"[+] Found app bundle: {app_dir.name}")

        # 2. Modify Main Info.plist
        main_plist_path = app_dir / "Info.plist"
        if not main_plist_path.exists():
            raise RuntimeError(f"Info.plist missing in {app_dir.name}")

        with open(main_plist_path, "rb") as f:
            main_plist = plistlib.load(f)

        orig_bundle_id = main_plist.get("CFBundleIdentifier", "vn.com.vng.zingalo")
        orig_display_name = main_plist.get("CFBundleDisplayName", "Zalo")
        exec_name = main_plist.get("CFBundleExecutable", "Zalo")
        print(f"[*] Original Bundle ID:   {orig_bundle_id}")
        print(f"[*] Original Display Name: {orig_display_name}")

        main_plist["CFBundleIdentifier"] = bundle_id
        main_plist["CFBundleDisplayName"] = display_name
        print(f"[+] Updated Bundle ID:    {bundle_id}")
        print(f"[+] Updated Display Name: {display_name}")

        with open(main_plist_path, "wb") as f:
            plistlib.dump(main_plist, f)

        # 3. Modify Extension Info.plists
        print("[*] Remapping App Extension bundle identifiers...")
        ext_plists = sorted(app_dir.glob("PlugIns/*.appex/Info.plist"))
        if not ext_plists:
            print(" [-] No app extensions found under PlugIns/")
        for ext_plist_path in ext_plists:
            with open(ext_plist_path, "rb") as f:
                ext_plist = plistlib.load(f)
            ext_id = ext_plist.get("CFBundleIdentifier", "")
            try:
                new_ext_id = remap_child_bundle_id(ext_id, orig_bundle_id, bundle_id)
                print(f" [+] Extension {ext_plist_path.parent.name}: {ext_id} -> {new_ext_id}")
                ext_plist["CFBundleIdentifier"] = new_ext_id
                with open(ext_plist_path, "wb") as f:
                    plistlib.dump(ext_plist, f)
            except ValueError:
                print(f" [!] Extension {ext_plist_path.parent.name} has non-matching prefix: {ext_id}")

        # 4. Copy Mod Dylib into Frameworks
        frameworks_dir = app_dir / "Frameworks"
        frameworks_dir.mkdir(parents=True, exist_ok=True)
        dest_dylib = frameworks_dir / mod_dylib.name
        shutil.copy2(mod_dylib, dest_dylib)
        print(f"[+] Copied dylib to: {dest_dylib} ({dest_dylib.stat().st_size:,} bytes)")

        # 5. Inject LC_LOAD_DYLIB into Main Executable
        main_binary = app_dir / exec_name
        if not main_binary.exists():
            raise RuntimeError(f"Main executable missing: {main_binary}")
        with open(main_binary, "rb") as f:
            binary_bytes = f.read()

        patched_binary_bytes = inject_load_dylib(binary_bytes, ZLMOD_LOAD_COMMAND)

        with open(main_binary, "wb") as f:
            f.write(patched_binary_bytes)
        print(f"[+] Injected load command '{ZLMOD_LOAD_COMMAND}' into {main_binary}")

        # 6. Repack into new IPA preserving POSIX permissions
        output_ipa.parent.mkdir(parents=True, exist_ok=True)
        print(f"[*] Compressing repacked IPA: {output_ipa}...")
        with zipfile.ZipFile(temp_zip, "w", zipfile.ZIP_DEFLATED) as zf_out:
            for root, _dirs, files in os.walk(work_dir):
                for file in sorted(files):
                    abs_file = Path(root) / file
                    rel_posix = abs_file.relative_to(work_dir).as_posix()
                    zi = zipfile.ZipInfo.from_file(abs_file, rel_posix)
                    zi.compress_type = zipfile.ZIP_DEFLATED
                    zi.create_system = 3
                    if rel_posix in entry_modes:
                        zi.external_attr = entry_modes[rel_posix]
                    elif _is_macho_file(abs_file):
                        zi.external_attr = 0o100755 << 16
                    else:
                        zi.external_attr = 0o100644 << 16
                    with zf_out.open(zi, "w") as dst, open(abs_file, "rb") as src:
                        shutil.copyfileobj(src, dst, 1024 * 1024)

        if output_ipa.exists():
            output_ipa.unlink()
        shutil.move(temp_zip, output_ipa)
    finally:
        if temp_zip.exists():
            temp_zip.unlink()
        if work_dir.exists():
            shutil.rmtree(work_dir, ignore_errors=True)

    size_mb = output_ipa.stat().st_size / (1024 * 1024)
    print(f"[OK] Repackaging complete! Created {output_ipa} ({size_mb:.2f} MB)")

    # 7. Preflight Forensics Validation
    print("\n================================================================================")
    print("[*] Validating Preflight Forensics on Repacked IPA...")
    print("================================================================================")
    validate_ipa(output_ipa, mod_dylib.name, bundle_id, display_name)

    return output_ipa


def validate_ipa(ipa_path: Path, dylib_name: str, expected_bundle_id: str, expected_display_name: str) -> None:
    """Forensic validation of repacked IPA."""
    with zipfile.ZipFile(ipa_path, "r") as zf:
        namelist = zf.namelist()

        # 1. Info.plist checks
        candidates = [name for name in namelist if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", name)]
        assert len(candidates) == 1, f"Expected one top-level app Info.plist, found {len(candidates)}"
        info_plist_path = candidates[0]
        app_root = info_plist_path.rsplit("/", 1)[0]
        plist_data = plistlib.loads(zf.read(info_plist_path))
        actual_bid = plist_data.get("CFBundleIdentifier")
        actual_name = plist_data.get("CFBundleDisplayName")
        exec_name = plist_data.get("CFBundleExecutable", "Zalo")
        main_bin_path = f"{app_root}/{exec_name}"
        print(f"[Forensics] CFBundleIdentifier:  {actual_bid} (Match: {actual_bid == expected_bundle_id})")
        print(f"[Forensics] CFBundleDisplayName: {actual_name} (Match: {actual_name == expected_display_name})")
        assert actual_bid == expected_bundle_id, f"Bundle ID mismatch: {actual_bid} != {expected_bundle_id}"
        assert actual_name == expected_display_name, f"Display name mismatch: {actual_name} != {expected_display_name}"

        # 2. Injected Dylib presence
        dylib_in_ipa = f"{app_root}/Frameworks/{dylib_name}"
        assert dylib_in_ipa in namelist, f"{dylib_in_ipa} not found in IPA archive!"
        print(f"[Forensics] Embedded dylib verified: {dylib_in_ipa} ({zf.getinfo(dylib_in_ipa).file_size:,} bytes)")

        # 3. Main executable load command check
        assert main_bin_path in namelist, f"Main executable missing: {main_bin_path}"
        main_bin_data = zf.read(main_bin_path)
        load_dylibs = get_load_dylibs(main_bin_data)
        expected_load = f"@rpath/{dylib_name}"
        assert expected_load in load_dylibs, f"Load command '{expected_load}' not found in {exec_name} executable!"
        print(f"[Forensics] Load command verified in {exec_name}: {expected_load}")

        # 4. Mach-O Cryptid check across all binaries (main app + extensions + frameworks + dylib)
        macho_count = 0
        encrypted_count = 0
        for name in namelist:
            if name.endswith("/") or name.endswith((".plist", ".json", ".png", ".nib", ".storyboardc")):
                continue
            if (
                name == main_bin_path
                or name.startswith(f"{app_root}/Frameworks/")
                or name.startswith(f"{app_root}/PlugIns/")
            ):
                data = zf.read(name)
                if len(data) >= 4 and data[:4] in MACHO_MAGICS:
                    cryptid = check_macho_cryptid(data)
                    macho_count += 1
                    if cryptid != 0:
                        print(f" [!] Encrypted Mach-O found: {name} (cryptid={cryptid})")
                        encrypted_count += 1

        print(f"[Forensics] Total Mach-O binaries audited: {macho_count}")
        print(f"[Forensics] Unencrypted Mach-Os (cryptid=0): {macho_count - encrypted_count}/{macho_count}")
        assert encrypted_count == 0, f"Found {encrypted_count} encrypted Mach-O binaries!"
        assert macho_count > 1, "Expected the app executable and injected dylib"
        print(f"[OK] Forensics validation passed: all {macho_count} Mach-Os cryptid=0, dylib and load command verified!")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Package a decrypted Zalo IPA with ZLMod")
    parser.add_argument("--input", required=True, help="Input decrypted IPA")
    parser.add_argument("--output", required=True, help="Output unsigned IPA")
    parser.add_argument("--bundle-id", required=True, help="Target bundle identifier from compatibility.json")
    parser.add_argument("--display-name", default="Zalo ZLMod", help="Target display name")
    parser.add_argument("--dylib", default=str(DEFAULT_DYLIB), help="Path to libZLMod.dylib")
    return parser


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)
    input_path = Path(args.input).resolve()
    output_path = Path(args.output).resolve()
    dylib_path = Path(args.dylib).resolve()

    repackage(input_path, output_path, dylib_path, args.bundle_id, args.display_name)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
