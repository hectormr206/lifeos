"""Offline regressions for the framed OTA config publication contract."""

import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[3]
TOOLS = ROOT / "mobile/tools"
GUARD = TOOLS / "lib/baked-config-guard.sh"
TEST_DIR = Path(__file__).resolve().parent
URL = "https://updates.test.example/lifeos"
KEY = "fake-update-key-0123456789"


def resolve_aot_runtime(dart):
    """Find the runtime for a standalone Dart SDK or a Flutter bin/dart wrapper."""
    executable = shutil.which(dart)
    if executable is None:
        raise AssertionError("Dart executable not found for AOT probe")
    dart_path = Path(executable).resolve()
    candidates = (dart_path.with_name("dartaotruntime"),
                  dart_path.parent / "cache/dart-sdk/bin/dartaotruntime")
    for candidate in candidates:
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    raise AssertionError("Dart AOT runtime not found next to SDK or Flutter wrapper")


def expected_newline_compile_rejection(result, key, aot):
    """Dart 3.12.2 rejects newline defines before emitting an AOT snapshot."""
    return (key is not None and "\n" in key and result.returncode == 64
            and "Missing Dart entry point" in result.stderr + result.stdout
            and not aot.exists())


def frame(url=URL, key=KEY):
    return f"LIFEOS_OTA_CONFIG_V1\n{url}\n{key}\nEND_LIFEOS_OTA_CONFIG_V1".encode("ascii")


def elf(machine=62, *, bits=64):
    """Minimal ELF header for gate tests; not an executable binary."""
    header = bytearray(64 if bits == 64 else 52)
    header[:7] = b"\x7fELF" + bytes((2 if bits == 64 else 1, 1, 1))
    struct.pack_into("<HHI", header, 16, 3, machine, 1)
    struct.pack_into("<H", header, 52 if bits == 64 else 40, len(header))
    return bytes(header)


class BakedConfigGuardTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=TEST_DIR)
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name)

    def artifact(self, data, *, apk=False, other=None):
        path = self.path / ("app.apk" if apk else "libapp.so")
        if apk:
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr("lib/arm64-v8a/libapp.so", data)
                if other is not None:
                    archive.writestr("lib/x86_64/libapp.so", other)
        else:
            path.write_bytes(data)
        return path

    def run_guard(self, artifact, *, url=URL, key=KEY):
        return subprocess.run(
            ["bash", "-c", 'source "$1"; lifeos_guard_baked_config "$2" "$3"',
             "guard", str(GUARD), str(artifact), url],
            env=dict(os.environ, UPDATE_ACCESS_KEY=key), text=True,
            capture_output=True, check=False,
        )

    def good_bytes(self, url=URL, key=KEY, *, machine=62, bits=64):
        return elf(machine, bits=bits) + b"\0" * 32 + frame(url, key)

    def assert_rejected(self, result, *secrets):
        self.assertNotEqual(result.returncode, 0, result.stdout)
        for secret in secrets:
            self.assertNotIn(secret, result.stdout + result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def test_framed_raw_linux_and_every_apk_abi(self):
        for machine, bits in ((62, 64), (183, 64), (40, 32)):
            with self.subTest(machine=machine):
                self.assertEqual(self.run_guard(self.artifact(
                    self.good_bytes(machine=machine, bits=bits))).returncode, 0)
        apk = self.artifact(self.good_bytes(machine=183), apk=True,
                            other=self.good_bytes(machine=62))
        self.assertEqual(self.run_guard(apk).returncode, 0)
        arm32 = self.path / "arm32.apk"
        with zipfile.ZipFile(arm32, "w") as archive:
            archive.writestr("lib/arm64-v8a/libapp.so", self.good_bytes(machine=183))
            archive.writestr("lib/armeabi-v7a/libapp.so", self.good_bytes(machine=40, bits=32))
        self.assertEqual(self.run_guard(arm32).returncode, 0)

    def test_trailing_slash_url_supported(self):
        self.assertEqual(self.run_guard(self.artifact(self.good_bytes(URL + "/")),
                                        url=URL + "/").returncode, 0)
        self.assertEqual(self.run_guard(self.artifact(self.good_bytes(key="fake=key")),
                                        key="fake=key").returncode, 0)

    def test_missing_wrong_placeholder_and_unframed_values_rejected(self):
        for binary, url, key in (
            (self.good_bytes("https://other.test.example/lifeos"), URL, KEY),
            (self.good_bytes(URL + "/embed"), URL, KEY),
            (self.good_bytes(URL, "wrong-key"), URL, KEY),
            (self.good_bytes(URL, ""), URL, KEY),
            (self.good_bytes(), "", KEY),
            (self.good_bytes(), "https://updates.PLACEHOLDER.example/lifeos", KEY),
            (self.good_bytes(), URL, ""),
            (self.good_bytes(), URL, "PLACEHOLDER"),
            (elf() + URL.encode() + b"\0" + KEY.encode(), URL, KEY),
            (elf() + b"prefix" + frame()[:-len(b"END_LIFEOS_OTA_CONFIG_V1")], URL, KEY),
        ):
            with self.subTest(url=url, key=key):
                self.assert_rejected(self.run_guard(self.artifact(binary), url=url, key=key),
                                     KEY, "wrong-key")

    def test_invalid_inputs_and_binary_placeholders_do_not_leak(self):
        for url in ("http://updates.test.example/lifeos", "https://", URL + "?q=1",
                    URL + "#frag", URL + "\nnoise", URL + "\x01", URL + "\x7f",
                    "https://bad host/a"):
            with self.subTest(url=url):
                self.assert_rejected(self.run_guard(self.artifact(self.good_bytes(url)), url=url),
                                     KEY, url)
        for key in ("line\nbreak", "\t", "\x01", "\x7f", "your-access-key", "replace_me"):
            with self.subTest(key=key):
                self.assert_rejected(self.run_guard(self.artifact(self.good_bytes(key=key)), key=key),
                                     KEY, key)
        for bad in (b"https://updates.PLACEHOLDER.example/lifeos",
                    b"PLACEHOLDER_UPDATE_ACCESS_KEY"):
            self.assert_rejected(self.run_guard(self.artifact(self.good_bytes() + bad)), KEY)
        self.assertEqual(self.run_guard(self.artifact(
            self.good_bytes() + b"Flutter Placeholder widget replace me")).returncode, 0)

    def test_all_abis_must_match_and_unsupported_rejected(self):
        for other in (self.good_bytes(key="wrong-key"), self.good_bytes(machine=243),
                      self.good_bytes() + b"PLACEHOLDER_UPDATE_ACCESS_KEY"):
            self.assert_rejected(self.run_guard(self.artifact(
                self.good_bytes(machine=183), apk=True, other=other)), KEY)
        apk = self.path / "unknown.apk"
        with zipfile.ZipFile(apk, "w") as archive:
            archive.writestr("lib/arm64-v8a/libapp.so", self.good_bytes(machine=183))
            archive.writestr("lib/mips/libapp.so", self.good_bytes())
        self.assert_rejected(self.run_guard(apk), KEY)

    def test_missing_corrupt_empty_and_absent_arm64_controlled(self):
        empty = self.path / "empty.so"
        empty.write_bytes(b"")
        corrupt = self.path / "corrupt.apk"
        corrupt.write_bytes(b"not a zip")
        no_arm = self.path / "no-arm.apk"
        with zipfile.ZipFile(no_arm, "w") as archive:
            archive.writestr("lib/x86_64/libapp.so", self.good_bytes())
        invalid = self.artifact(self.good_bytes().replace(b"\x7fELF", b"TEXT"))
        for path in (self.path / "absent.apk", empty, corrupt, no_arm, invalid):
            with self.subTest(path=path):
                self.assert_rejected(self.run_guard(path), KEY)

    def test_corrupt_deflate_stream_controlled(self):
        artifact = self.path / "bad-deflate.apk"
        with zipfile.ZipFile(artifact, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("lib/arm64-v8a/libapp.so", self.good_bytes(machine=183))
        with zipfile.ZipFile(artifact) as archive:
            offset = archive.getinfo("lib/arm64-v8a/libapp.so").header_offset
        raw = bytearray(artifact.read_bytes())
        name_length, extra_length = struct.unpack_from("<HH", raw, offset + 26)
        raw[offset + 30 + name_length + extra_length] = 0x06
        artifact.write_bytes(raw)
        self.assert_rejected(self.run_guard(artifact), KEY)

    def test_publishers_forward_both_defines_to_flutter(self):
        for name in ("publish-to-vps.sh", "publish-linux-to-vps.sh"):
            with self.subTest(publisher=name):
                source = (TOOLS / name).read_text()
                start = source.index("flutter build ")
                end = source.index('  --dart-define=LIFEOS_SEARCH_KEY=', start)
                build = source[start:source.index("\n", end)]
                result = subprocess.run(
                    ["bash", "-c", """set -euo pipefail
BUILD_NUMBER=42
flutter() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "$@"; }
""" + build], env=dict(os.environ, UPDATE_BASE_URL=URL,
                                    UPDATE_ACCESS_KEY=KEY),
                    text=True, capture_output=True, check=False,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                args = json.loads(result.stdout)
                self.assertIn("--dart-define=UPDATE_BASE_URL=" + URL, args)
                self.assertIn("--dart-define=UPDATE_ACCESS_KEY=" + KEY, args)

    def test_publishers_abort_before_upload_on_guard_failure(self):
        for name in ("publish-to-vps.sh", "publish-linux-to-vps.sh"):
            with self.subTest(publisher=name):
                source = (TOOLS / name).read_text()
                start = source.index("# shellcheck source=lib/baked-config-guard.sh")
                block = source[start:source.index("# ── ", start)]
                self.assertLess(start, source.index('ota_put "$'))
                artifact = self.artifact(self.good_bytes(key="wrong-key"),
                                         apk=name == "publish-to-vps.sh")
                marker = self.path / "upload-invoked"
                setup = ("set -euo pipefail\n"
                         f'MOBILE_DIR="{ROOT / "mobile"}"\n'
                         f'UPDATE_BASE_URL="{URL}"\n'
                         f'UPDATE_ACCESS_KEY="{KEY}"\n'
                         f'APK="{artifact}"\nBUNDLE="{self.path}"\n'
                         'ota_put() { touch "$MARKER"; }\n')
                if name == "publish-linux-to-vps.sh":
                    bundle = self.path / "bundle"
                    (bundle / "lib").mkdir(parents=True, exist_ok=True)
                    (bundle / "lib/libapp.so").write_bytes(self.good_bytes(key="wrong-key"))
                    setup += f'BUNDLE="{bundle}"\n'
                result = subprocess.run(
                    ["bash", "-c", setup + block + '\nota_put "payload" "public"\n'],
                    env=dict(os.environ, MARKER=str(marker)), text=True,
                    capture_output=True, check=False,
                )
                self.assert_rejected(result, KEY)
                self.assertFalse(marker.exists())
                self.assertIn('--dart-define=UPDATE_BASE_URL="$UPDATE_BASE_URL"', source)
                self.assertIn('--dart-define=UPDATE_ACCESS_KEY="$UPDATE_ACCESS_KEY"', source)

    def test_aot_runtime_discovery_for_flutter_wrapper_and_sdk(self):
        flutter_bin = self.path / "flutter/bin"
        sdk_bin = flutter_bin / "cache/dart-sdk/bin"
        sdk_bin.mkdir(parents=True)
        wrapper = flutter_bin / "dart"
        wrapper.write_text("#!/bin/sh\n")
        wrapper.chmod(0o755)
        flutter_runtime = sdk_bin / "dartaotruntime"
        flutter_runtime.write_text("#!/bin/sh\n")
        flutter_runtime.chmod(0o755)
        self.assertEqual(resolve_aot_runtime(str(wrapper)), str(flutter_runtime))

        standalone = self.path / "dart-sdk/bin"
        standalone.mkdir(parents=True)
        dart = standalone / "dart"
        dart.write_text("#!/bin/sh\n")
        dart.chmod(0o755)
        runtime = standalone / "dartaotruntime"
        runtime.write_text("#!/bin/sh\n")
        runtime.chmod(0o755)
        self.assertEqual(resolve_aot_runtime(str(dart)), str(runtime))
        missing_bin = self.path / "missing-sdk/bin"
        missing_bin.mkdir(parents=True)
        missing_dart = missing_bin / "dart"
        missing_dart.write_text("#!/bin/sh\n")
        missing_dart.chmod(0o755)
        with self.assertRaisesRegex(AssertionError, "Dart AOT runtime not found"):
            resolve_aot_runtime(str(missing_dart))

    def test_only_newline_compiler_rejection_without_output_is_expected(self):
        aot = self.path / "newline.aot"
        rejected = subprocess.CompletedProcess([], 64, "", "Missing Dart entry point")
        self.assertTrue(expected_newline_compile_rejection(rejected, "bad\nkey", aot))
        self.assertFalse(expected_newline_compile_rejection(rejected, "valid-key", aot))
        self.assertFalse(expected_newline_compile_rejection(
            subprocess.CompletedProcess([], 65, "", "Missing Dart entry point"),
            "bad\nkey", aot))
        self.assertFalse(expected_newline_compile_rejection(
            subprocess.CompletedProcess([], 64, "", "other compiler failure"),
            "bad\nkey", aot))
        aot.write_bytes(b"stale output")
        self.assertFalse(expected_newline_compile_rejection(rejected, "bad\nkey", aot))

    @unittest.skipUnless(os.environ.get("LIFEOS_TEST_DART"), "set LIFEOS_TEST_DART for AOT probe")
    def test_production_dart_config_aot_probe(self):
        dart = os.environ["LIFEOS_TEST_DART"]
        probe = TEST_DIR / "ota_config_probe.dart"
        cases = ((URL, KEY, True), (URL, "wrong-key", False),
                 ("https://other.test.example/lifeos", KEY, False),
                 (URL, "bad\x7fkey", False), (URL, "bad\nkey", False),
                 (None, None, False))
        for index, (url, key, should_pass) in enumerate(cases):
            with self.subTest(defined=url is not None, correct=should_pass):
                # A distinct path per case prevents a prior good output from
                # being mistaken for this case's compilation result.
                aot = self.path / f"probe-{index}.aot"
                self.assertFalse(aot.exists())
                defines = ([] if url is None else
                           [f"-DUPDATE_BASE_URL={url}", f"-DUPDATE_ACCESS_KEY={key}"])
                compile_result = subprocess.run(
                    [dart, "compile", "aot-snapshot", *defines, "-o", str(aot), str(probe)],
                    text=True, capture_output=True, check=False,
                )
                if expected_newline_compile_rejection(compile_result, key, aot):
                    continue
                self.assertEqual(compile_result.returncode, 0, compile_result.stderr)
                self.assertTrue(aot.is_file(), "Dart compile produced no AOT artifact")
                result = self.run_guard(aot)
                if should_pass:
                    self.assertEqual(result.returncode, 0, result.stderr)
                else:
                    self.assert_rejected(result, *(value for value in (KEY, key) if value))
                # Execute the actual AOT getters; stdout is a boolean marker.
                runtime = resolve_aot_runtime(dart)
                executed = subprocess.run([runtime, str(aot)], text=True,
                                          capture_output=True, check=False)
                if url is not None and key is not None and all(
                        0x21 <= ord(c) <= 0x7e for c in url + key):
                    self.assertEqual(executed.returncode, 0, executed.stderr)
                    self.assertEqual(executed.stdout.strip(), "OTA_CONFIG_OK")
                else:
                    self.assertNotEqual(executed.returncode, 0)
                self.assertNotIn(key or KEY, executed.stderr + executed.stdout)


if __name__ == "__main__":
    unittest.main()
