"""Exercise the production Gradle release gate without Android or Flutter plugins."""

import base64
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[3]
GATE = ROOT / "mobile/android/ota-release.gradle"
APP_BUILD = ROOT / "mobile/android/app/build.gradle.kts"
TEST_DIR = Path(__file__).resolve().parent
URL = "https://updates.test.example/lifeos"
KEY = "fixture-key=with-equals"


def defines(**values):
    return ",".join(base64.b64encode(f"{name}={value}".encode()).decode()
                    for name, value in values.items())


class OtaReleaseWiringTest(unittest.TestCase):
    def test_app_uses_non_kotlin_release_gate(self):
        self.assertTrue(GATE.is_file(), f"Missing applied release gate: {GATE}")
        build = APP_BUILD.read_text()
        self.assertIn('apply(from = "../ota-release.gradle")', build)
        self.assertNotIn("ota-release.gradle.kts", build)


class OtaReleaseBuildTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.gradle = os.environ.get("LIFEOS_TEST_GRADLE")
        if not cls.gradle:
            raise unittest.SkipTest("Gradle fixture not run: set LIFEOS_TEST_GRADLE; CI supplies it")

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=TEST_DIR)
        self.addCleanup(self.temp.cleanup)
        self.project = Path(self.temp.name)
        (self.project / "settings.gradle.kts").write_text('include(":app")\n')
        app = self.project / "app"
        app.mkdir()
        (self.project / "markers").mkdir()
        # The same script app/build.gradle.kts applies in the real project.
        script = f'apply(from = file("{GATE}"))\n'
        for task in ("compileFlutterBuildRelease", "assembleRelease", "bundleRelease",
                     "assembleDebug", "assembleSecurityProbe"):
            script += (f'tasks.register("{task}") {{ doLast {{ '
                       f'file("../markers/{task}").writeText("executed") }} }}\n')
        script += ('tasks.register("allOutputs") { dependsOn("assembleDebug", '
                   '"compileFlutterBuildRelease") }\n')
        (app / "build.gradle.kts").write_text(script)

    def run_gradle(self, *tasks, encoded=None):
        args = [self.gradle, "--offline", "--no-daemon", "--max-workers=2",
                "--console=plain", "-p", str(self.project)]
        if encoded is not None:
            args.append("-Pdart-defines=" + encoded)
        args.extend(":app:" + task for task in tasks)
        result = subprocess.run(args, text=True, capture_output=True, check=False,
                                timeout=90, env={**os.environ, "GRADLE_USER_HOME":
                                                   str(self.project / ".gradle-home")})
        return result

    def assert_rejected(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(list((self.project / "markers").iterdir()), [], result.stdout)
        self.assertNotIn(URL, result.stdout + result.stderr)
        self.assertNotIn(KEY, result.stdout + result.stderr)

    def test_release_missing_or_wrong_defines(self):
        cases = (("compileFlutterBuildRelease", None),
                 ("assembleRelease", None), ("bundleRelease", None),
                 ("compileFlutterBuildRelease", defines(UPDATE_BASE_URL=URL)),
                 ("compileFlutterBuildRelease", defines(UPDATE_ACCESS_KEY=KEY)),
                 ("compileFlutterBuildRelease", defines(UPDATE_BASE_URL="", UPDATE_ACCESS_KEY=KEY)),
                 ("compileFlutterBuildRelease", defines(UPDATE_BASE_URL="http://wrong.test.example",
                                                         UPDATE_ACCESS_KEY=KEY)),
                 ("compileFlutterBuildRelease", defines(UPDATE_BASE_URL=URL, UPDATE_ACCESS_KEY="")),
                 ("compileFlutterBuildRelease", defines(UPDATE_BASE_URL=URL,
                                                         UPDATE_ACCESS_KEY="PLACEHOLDER")))
        for task, encoded in cases:
            with self.subTest(task=task, encoded=encoded):
                self.assert_rejected(self.run_gradle(task, encoded=encoded))

    def test_invalid_encoding_duplicates_and_url_forms(self):
        valid = defines(UPDATE_BASE_URL=URL, UPDATE_ACCESS_KEY=KEY)
        invalid = ("!not-base64!", base64.b64encode(b"not-a-pair").decode(),
                   valid + "," + defines(UPDATE_ACCESS_KEY="another-key"),
                   base64.b64encode(b"\xff=bad").decode(),
                   *(defines(UPDATE_BASE_URL=url, UPDATE_ACCESS_KEY=KEY) for url in (
                       "https://", "https://user@updates.test.example/x",
                       "https://updates.test.example/x?key=1",
                       "https://updates.test.example/x#fragment",
                       "https://bad host/x", "https://updates.PLACEHOLDER.example/x")))
        for encoded in invalid:
            with self.subTest(encoded=encoded):
                self.assert_rejected(self.run_gradle("compileFlutterBuildRelease", encoded=encoded))

    def test_release_url_port_bounds_and_controls(self):
        for url in ("https://updates.test.example:0/lifeos",
                    "https://updates.test.example:65536/lifeos",
                    "https://updates.test.example:99999/lifeos",
                    URL + "\x00", URL + "\x01", URL + "\x7f"):
            with self.subTest(url=repr(url)):
                result = self.run_gradle("compileFlutterBuildRelease", encoded=defines(
                    UPDATE_BASE_URL=url, UPDATE_ACCESS_KEY=KEY))
                self.assert_rejected(result)
                self.assertNotIn(url, result.stdout + result.stderr)

        result = self.run_gradle("compileFlutterBuildRelease", encoded=defines(
            UPDATE_BASE_URL="https://updates.test.example:65535/lifeos",
            UPDATE_ACCESS_KEY=KEY))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.project / "markers/compileFlutterBuildRelease").exists())

    def test_release_key_rejects_ascii_controls_and_del(self):
        for code in (0, 1, 127):
            key = f"test-key{chr(code)}suffix"
            with self.subTest(code=code):
                result = self.run_gradle("compileFlutterBuildRelease", encoded=defines(
                    UPDATE_BASE_URL=URL, UPDATE_ACCESS_KEY=key))
                self.assert_rejected(result)
                self.assertNotIn(key, result.stdout + result.stderr)

    def test_valid_release_and_aggregate(self):
        valid = defines(UPDATE_BASE_URL=URL, UPDATE_ACCESS_KEY=KEY)
        result = self.run_gradle("compileFlutterBuildRelease", encoded=valid)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.project / "markers/compileFlutterBuildRelease").exists())
        # A debug task must not start if a release dependency is invalid.
        (self.project / "markers/compileFlutterBuildRelease").unlink()
        self.assert_rejected(self.run_gradle("allOutputs"))

    def test_debug_and_probe_without_defines(self):
        for task in ("assembleDebug", "assembleSecurityProbe"):
            with self.subTest(task=task):
                result = self.run_gradle(task)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue((self.project / "markers" / task).exists())


if __name__ == "__main__":
    unittest.main()
