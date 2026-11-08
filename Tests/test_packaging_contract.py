import importlib.util
import plistlib
import struct
import tempfile
import unittest
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PACKAGER = ROOT / "Packaging" / "package_ipa.py"
INJECTOR = ROOT / "Packaging" / "macho_injector.py"
PREFLIGHT = ROOT / "Packaging" / "ipa_preflight.py"


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"unable to load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def make_synthetic_macho64(filetype: int = 2, include_code_sig: bool = True) -> bytes:
    if filetype == 6:  # MH_DYLIB minimal image
        hdr = struct.pack("<IIIIIIII", 0xFEEDFACF, 0x0100000C, 0, filetype, 0, 0, 0, 0)
        return hdr + b"\x00" * 32

    sec_offset = 0x1000
    seg_cmd = struct.pack(
        "<II16sQQQQIIII",
        0x19,  # LC_SEGMENT_64
        152,
        b"__TEXT".ljust(16, b"\x00"),
        0,
        0x4000,
        0,
        0x4000,
        7,
        5,
        1,
        0,
    )
    sect = struct.pack(
        "<16s16sQQIIIIIIII",
        b"__text".ljust(16, b"\x00"),
        b"__TEXT".ljust(16, b"\x00"),
        sec_offset,
        16,
        sec_offset,
        2,
        0,
        0,
        0,
        0,
        0,
        0,
    )
    cmds = seg_cmd + sect
    ncmds = 1
    if include_code_sig:
        cmds += struct.pack("<IIII", 0x1D, 16, sec_offset + 16, 0)
        ncmds += 1
    hdr = struct.pack(
        "<IIIIIIII",
        0xFEEDFACF,
        0x0100000C,
        0,
        filetype,
        ncmds,
        len(cmds),
        0,
        0,
    )
    buf = bytearray(sec_offset + 32)
    buf[:32] = hdr
    buf[32 : 32 + len(cmds)] = cmds
    return bytes(buf)


class PackagingContractTests(unittest.TestCase):
    def test_supported_bundle_ids_come_from_shared_manifest(self):
        packager = load_module("zlmod_packager", PACKAGER)
        self.assertEqual(
            {"vn.com.vng.zingalo", "vn.com.vng.zingalo2"},
            packager.load_supported_bundle_ids(),
        )

    def test_unknown_bundle_id_is_rejected(self):
        packager = load_module("zlmod_packager", PACKAGER)
        with self.assertRaisesRegex(ValueError, "unsupported bundle identifier"):
            packager.validate_bundle_id("example.invalid.zalo")

    def test_cli_requires_input_output_and_bundle_id(self):
        packager = load_module("zlmod_packager", PACKAGER)
        parser = packager.build_parser()
        with self.assertRaises(SystemExit):
            parser.parse_args([])

    def test_load_command_matches_built_dylib(self):
        packager = load_module("zlmod_packager", PACKAGER)
        self.assertEqual("@rpath/libZLMod.dylib", packager.ZLMOD_LOAD_COMMAND)

    def test_extension_bundle_remap_requires_identifier_boundary(self):
        packager = load_module("zlmod_packager", PACKAGER)
        self.assertEqual(
            "vn.com.vng.zingalo2.ShareExtension",
            packager.remap_child_bundle_id(
                "vn.com.vng.zingalo.ShareExtension",
                "vn.com.vng.zingalo",
                "vn.com.vng.zingalo2",
            ),
        )
        with self.assertRaisesRegex(ValueError, "not a child"):
            packager.remap_child_bundle_id(
                "vn.com.vng.zingaloMalicious.Extension",
                "vn.com.vng.zingalo",
                "vn.com.vng.zingalo2",
            )

    def test_existing_explicit_staging_directory_is_rejected(self):
        packager = load_module("zlmod_packager", PACKAGER)
        with tempfile.TemporaryDirectory() as tmp:
            existing = Path(tmp) / "existing"
            existing.mkdir()
            with self.assertRaises(FileExistsError):
                packager.create_owned_work_dir(Path(tmp), existing)

    def test_macho_injector_is_idempotent_and_preserves_code_signature(self):
        injector = load_module("zlmod_injector", INJECTOR)
        original = make_synthetic_macho64(filetype=2, include_code_sig=True)
        once = injector.inject_load_dylib(original, "@rpath/libZLMod.dylib")
        twice = injector.inject_load_dylib(once, "@rpath/libZLMod.dylib")

        self.assertEqual(once, twice)
        self.assertEqual(["@rpath/libZLMod.dylib"], injector.get_load_dylibs(twice))

        hdr = injector.inspect_macho_header(twice)
        self.assertEqual(3, hdr["ncmds"])
        offset = 32
        cmds = []
        for _ in range(hdr["ncmds"]):
            cmd, size = struct.unpack("<II", twice[offset : offset + 8])
            cmds.append(cmd)
            offset += size
        self.assertEqual(0x1D, cmds[-1])
        self.assertEqual(32 + hdr["sizeofcmds"], offset)

    def test_repackage_end_to_end_and_preflight(self):
        packager = load_module("zlmod_packager", PACKAGER)
        preflight = load_module("zlmod_preflight", PREFLIGHT)
        with tempfile.TemporaryDirectory() as tmp:
            tmp_dir = Path(tmp)
            input_ipa = tmp_dir / "input.ipa"
            output_ipa = tmp_dir / "output.ipa"
            dylib_path = tmp_dir / "libZLMod.dylib"
            dylib_path.write_bytes(make_synthetic_macho64(filetype=6, include_code_sig=False))

            main_plist = plistlib.dumps(
                {
                    "CFBundleIdentifier": "vn.com.vng.zingalo",
                    "CFBundleDisplayName": "Zalo",
                    "CFBundleExecutable": "Zalo",
                    "CFBundleShortVersionString": "261002",
                    "CFBundleVersion": "261002802",
                    "MinimumOSVersion": "15.1",
                }
            )
            ext_plist = plistlib.dumps(
                {
                    "CFBundleIdentifier": "vn.com.vng.zingalo.ShareExtension",
                    "CFBundleExecutable": "ShareExtension",
                }
            )
            with zipfile.ZipFile(input_ipa, "w") as zf:
                zf.writestr("Payload/Zalo.app/Info.plist", main_plist)
                zi_bin = zipfile.ZipInfo("Payload/Zalo.app/Zalo")
                zi_bin.create_system = 3
                zi_bin.external_attr = 0o100755 << 16
                zf.writestr(zi_bin, make_synthetic_macho64(filetype=2, include_code_sig=True))
                zf.writestr("Payload/Zalo.app/PlugIns/ShareExtension.appex/Info.plist", ext_plist)

            result = packager.repackage(
                input_ipa=input_ipa,
                output_ipa=output_ipa,
                mod_dylib=dylib_path,
                bundle_id="vn.com.vng.zingalo2",
                display_name="Zalo ZLMod",
            )
            self.assertEqual(output_ipa, result)
            self.assertTrue(output_ipa.is_file())
            leftovers = [p for p in tmp_dir.iterdir() if p.name.startswith("zlmod-package-")]
            self.assertEqual([], leftovers)

            with zipfile.ZipFile(output_ipa, "r") as zf:
                out_ext = plistlib.loads(zf.read("Payload/Zalo.app/PlugIns/ShareExtension.appex/Info.plist"))
                self.assertEqual("vn.com.vng.zingalo2.ShareExtension", out_ext["CFBundleIdentifier"])
                self.assertEqual(0o100755, zf.getinfo("Payload/Zalo.app/Zalo").external_attr >> 16)
                self.assertEqual(
                    0o100755,
                    zf.getinfo("Payload/Zalo.app/Frameworks/libZLMod.dylib").external_attr >> 16,
                )

            report = preflight.inspect(output_ipa)
            self.assertTrue(report["zlmod_supported"])
            self.assertEqual("supported exact target", report["zlmod_support_reason"])
            self.assertIn("@rpath/libZLMod.dylib", report["main_executable"]["load_dylibs"])
            self.assertIn(
                "Payload/Zalo.app/Frameworks/libZLMod.dylib",
                report["embedded_dylibs_and_mod_files"],
            )

    def test_repackage_rejects_wrong_dylib_filename(self):
        packager = load_module("zlmod_packager", PACKAGER)
        with tempfile.TemporaryDirectory() as tmp:
            tmp_dir = Path(tmp)
            bad_dylib = tmp_dir / "libWrong.dylib"
            bad_dylib.write_bytes(b"stub")
            with self.assertRaisesRegex(ValueError, "libZLMod.dylib"):
                packager.repackage(
                    input_ipa=tmp_dir / "missing.ipa",
                    output_ipa=tmp_dir / "out.ipa",
                    mod_dylib=bad_dylib,
                    bundle_id="vn.com.vng.zingalo2",
                )


if __name__ == "__main__":
    unittest.main()
