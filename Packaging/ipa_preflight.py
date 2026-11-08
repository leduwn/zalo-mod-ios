#!/usr/bin/env python3
"""Read-only IPA preflight for ZLMod: metadata, Mach-O encryption, compatibility, and injection inventory."""

from __future__ import annotations

import argparse
import hashlib
import json
import plistlib
import re
import struct
import sys
import zipfile
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = SCRIPT_DIR.parent
COMPATIBILITY_MANIFEST = PROJECT_ROOT / "Resources" / "compatibility.json"

LOAD_DYLIB_COMMANDS = {
    0x0C,  # LC_LOAD_DYLIB
    0x18,  # LC_LOAD_WEAK_DYLIB (LC_REQ_DYLD masked)
    0x1F,  # LC_REEXPORT_DYLIB
    0x23,  # LC_LOAD_UPWARD_DYLIB
}


def load_compatibility_targets(manifest_path: Path = COMPATIBILITY_MANIFEST) -> list[dict[str, object]]:
    payload = json.loads(Path(manifest_path).read_text(encoding="utf-8"))
    return payload.get("targets", [])


def evaluate_compatibility(
    bundle_id: str | None,
    version: str | None,
    build: str | None,
    manifest_path: Path = COMPATIBILITY_MANIFEST,
) -> tuple[bool, str]:
    targets = load_compatibility_targets(manifest_path)
    version_build_known = False
    for target in targets:
        if version == target.get("version") and build == target.get("build"):
            version_build_known = True
            if bundle_id in target.get("bundleIdentifiers", []):
                return True, "supported exact target"
    if version_build_known:
        return False, f"unsupported bundle {bundle_id}"
    return False, f"unsupported version/build {version}/{build}"


def macho_info(stream) -> dict[str, object] | None:
    header = stream.read(32)
    if len(header) < 4:
        return None
    if header[:4] == b"\xcf\xfa\xed\xfe":
        endian, is64 = "<", True
    elif header[:4] == b"\xce\xfa\xed\xfe":
        endian, is64 = "<", False
    elif header[:4] == b"\xfe\xed\xfa\xcf":
        endian, is64 = ">", True
    elif header[:4] == b"\xfe\xed\xfa\xce":
        endian, is64 = ">", False
    elif header[:4] in (b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"):
        return {"format": "fat_macho", "cryptid": "unknown", "load_dylibs": []}
    else:
        return None

    header_size = 32 if is64 else 28
    if len(header) < header_size:
        return {"format": "truncated_macho", "cryptid": "unknown", "load_dylibs": []}
    magic, cputype, _cpusubtype, filetype, ncmds, sizeofcmds, _flags = struct.unpack_from(
        endian + "IiiIIII", header
    )
    if ncmds > 10000 or sizeofcmds > 16 * 1024 * 1024:
        return {"format": "suspicious_macho", "cryptid": "unknown", "load_dylibs": []}
    cmds = header[header_size:] + stream.read(max(0, header_size + sizeofcmds - len(header)))
    info: dict[str, object] = {
        "format": "macho64" if is64 else "macho32",
        "cpu_type": cputype,
        "file_type": filetype,
        "cryptid": "not_present",
        "cryptsize": None,
        "load_dylibs": [],
        "rpaths": [],
    }
    cursor = 0
    for _ in range(ncmds):
        if cursor + 8 > len(cmds):
            info["parse_warning"] = "load_commands_truncated"
            break
        cmd, size = struct.unpack_from(endian + "II", cmds, cursor)
        if size < 8 or cursor + size > len(cmds):
            info["parse_warning"] = "invalid_load_command_size"
            break
        block = cmds[cursor : cursor + size]
        base_cmd = cmd & 0x7FFFFFFF
        if base_cmd in (0x21, 0x2C) and size >= (24 if base_cmd == 0x2C else 20):
            enc = struct.unpack_from(endian + "III", block, 8)
            info["cryptid"] = enc[2]
            info["cryptsize"] = enc[1]
        elif base_cmd in LOAD_DYLIB_COMMANDS or base_cmd == 0x0D:
            offset = struct.unpack_from(endian + "I", block, 8)[0] if size >= 12 else size
            if 0 <= offset < size:
                text = block[offset:].split(b"\0", 1)[0].decode("utf-8", errors="replace")
                if base_cmd == 0x0D:
                    info["id_dylib"] = text
                else:
                    info["load_dylibs"].append(text)
        elif base_cmd == 0x1C and size >= 12:
            offset = struct.unpack_from(endian + "I", block, 8)[0]
            if 0 <= offset < size:
                info["rpaths"].append(block[offset:].split(b"\0", 1)[0].decode("utf-8", errors="replace"))
        cursor += size
    return info


def is_executable_candidate(name: str, app_root: str, executable: str) -> bool:
    if name == f"{app_root}/{executable}":
        return True
    if not name.startswith(app_root + "/") or name.endswith("/"):
        return False
    if name.endswith(".dylib"):
        return True
    if ".framework/" in name or ".appex/" in name:
        return True
    return False


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as f:
        for data in iter(lambda: f.read(4 * 1024 * 1024), b""):
            digest.update(data)
    return digest.hexdigest()


def inspect(path: Path, manifest_path: Path = COMPATIBILITY_MANIFEST) -> dict[str, object]:
    with zipfile.ZipFile(path) as ipa:
        files = ipa.namelist()
        candidates = [name for name in files if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", name)]
        if len(candidates) != 1:
            raise ValueError(f"Expected one top-level app Info.plist; found {len(candidates)}")
        info_name = candidates[0]
        app_root = info_name.rsplit("/", 1)[0]
        info = plistlib.loads(ipa.read(info_name))
        executable = info.get("CFBundleExecutable", "")
        if not executable or f"{app_root}/{executable}" not in files:
            raise ValueError("Missing executable specified by CFBundleExecutable")
        binary_inventory = []
        for name in files:
            if is_executable_candidate(name, app_root, executable):
                with ipa.open(name) as stream:
                    data = macho_info(stream)
                if data:
                    binary_inventory.append({"path": name, **data})
        main_bin = next(v for v in binary_inventory if v["path"] == f"{app_root}/{executable}")
        injectables = [
            n
            for n in files
            if n.startswith(app_root + "/")
            and (n.endswith(".dylib") or "Substrate" in n or "ZLMod" in n)
        ]
        bundle_id = info.get("CFBundleIdentifier")
        version = info.get("CFBundleShortVersionString")
        build = info.get("CFBundleVersion")
        supported, support_reason = evaluate_compatibility(bundle_id, version, build, manifest_path)
        return {
            "file": str(path),
            "size_bytes": path.stat().st_size,
            "sha256": sha256_file(path),
            "app_name": info.get("CFBundleDisplayName") or info.get("CFBundleName"),
            "bundle_id": bundle_id,
            "version": version,
            "build": build,
            "minimum_os": info.get("MinimumOSVersion"),
            "zlmod_supported": supported,
            "zlmod_support_reason": support_reason,
            "main_executable": main_bin,
            "macho_inventory": binary_inventory,
            "encrypted_macho_paths": [
                v["path"]
                for v in binary_inventory
                if isinstance(v.get("cryptid"), int) and v["cryptid"] != 0
            ],
            "embedded_dylibs_and_mod_files": injectables,
            "extensions": [n for n in files if re.search(r"/PlugIns/[^/]+\.appex/Info\.plist$", n)],
            "has_codesign_resources": f"{app_root}/_CodeSignature/CodeResources" in files,
            "has_mobileprovision": f"{app_root}/embedded.mobileprovision" in files,
        }


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("ipa", type=Path, help="Path to IPA file, decrypted or packaged")
    ap.add_argument("--expect-bundle", help="Expected CFBundleIdentifier")
    ap.add_argument("--require-unencrypted-main", action="store_true")
    ap.add_argument("--require-compatible", action="store_true")
    ap.add_argument("--json-output", type=Path, help="Write JSON report to this file")
    return ap


def main(argv=None) -> int:
    ap = build_parser()
    args = ap.parse_args(argv)
    if not args.ipa.is_file():
        ap.error(f"IPA not found: {args.ipa}")
    try:
        result = inspect(args.ipa)
    except (OSError, zipfile.BadZipFile, plistlib.InvalidFileException, ValueError, KeyError) as ex:
        print(f"ERROR: {ex}", file=sys.stderr)
        return 2
    print(f"App: {result['app_name']} | {result['bundle_id']} | {result['version']} ({result['build']})")
    print(f"Compatibility: {result['zlmod_support_reason']} (supported={result['zlmod_supported']})")
    print(f"IPA bytes: {result['size_bytes']} | SHA256: {result['sha256']}")
    main_binary = result["main_executable"]
    print(
        f"Main Mach-O: {main_binary['format']} | cryptid: {main_binary['cryptid']} | cryptsize: {main_binary['cryptsize']}"
    )
    print(f"Mach-O entries: {len(result['macho_inventory'])}; encrypted: {len(result['encrypted_macho_paths'])}")
    print(f"Injected/candidate dylibs: {len(result['embedded_dylibs_and_mod_files'])}")
    for name in result["embedded_dylibs_and_mod_files"][:25]:
        print("  - " + name)
    print("Main binary mod/injection load commands:")
    for name in main_binary.get("load_dylibs", []):
        if any(token in name.lower() for token in ("zlmod", "zalo", "smoke", "substrate", "injection", "mod")):
            print("  - " + name)
    print(
        "Provisioning/signature metadata present:",
        result["has_mobileprovision"],
        result["has_codesign_resources"],
    )
    if args.json_output:
        args.json_output.parent.mkdir(parents=True, exist_ok=True)
        args.json_output.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
        print("Report:", args.json_output)

    fails = []
    if args.expect_bundle and result["bundle_id"] != args.expect_bundle:
        fails.append("Bundle ID mismatch")
    if args.require_unencrypted_main and main_binary["cryptid"] not in (0, "not_present"):
        fails.append("Main binary still encrypted or unrecognized")
    if args.require_compatible and not result["zlmod_supported"]:
        fails.append(f"Unsupported host target: {result['zlmod_support_reason']}")
    for msg in fails:
        print("FAIL:", msg, file=sys.stderr)
    return 1 if fails else 0


if __name__ == "__main__":
    raise SystemExit(main())
