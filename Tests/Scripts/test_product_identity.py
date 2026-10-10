import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ProductIdentityTests(unittest.TestCase):
    def test_bundle_metadata_matches_app_identity(self):
        source = (ROOT / "Sources/OilFindApp/ProductIdentity.swift").read_text()
        identity = dict(re.findall(r'static let (displayName|bundleIdentifier|urlScheme) = "([^"]+)"', source))
        with (ROOT / "Resources/Info.plist").open("rb") as file:
            info = plistlib.load(file)
        self.assertEqual(info["CFBundleIdentifier"], identity["bundleIdentifier"])
        self.assertEqual(info["CFBundleName"], identity["displayName"])
        self.assertEqual(info["CFBundleExecutable"], identity["displayName"])
        self.assertEqual(info["CFBundleURLTypes"][0]["CFBundleURLName"], identity["bundleIdentifier"])
        self.assertEqual(info["CFBundleURLTypes"][0]["CFBundleURLSchemes"], [identity["urlScheme"]])

    def test_default_manifest_and_entry_only_assemble_public_targets(self):
        env = dict(os.environ)
        env.pop("OILFIND_FREE", None)
        manifest = json.loads(subprocess.check_output(["swift", "package", "dump-package"], cwd=ROOT, env=env))
        self.assertEqual({target["name"] for target in manifest["targets"]},
                         {"COilFind", "OilFindCore", "OilFindApp", "OilFind", "oilfind-cli", "OilFindCoreTests", "OilFindUITests"})
        app = next(target for target in manifest["targets"] if target["name"] == "OilFindApp")
        self.assertIn("UpdateExercise.swift", app["exclude"])
        self.assertEqual((ROOT / "Sources/OilFind/main.swift").read_text(), "import OilFindApp\nApplication.run()\n")

    def test_production_entry_points_cannot_call_old_update_or_cleanup(self):
        for name in ("Application.swift", "AppDelegate.swift", "UpdateManager.swift"):
            source = (ROOT / "Sources/OilFindApp" / name).read_text()
            for forbidden in ("LegacyAuthorizationCleanup.run", "SystemUpdateFiles()", "UpdateClient(",
                              "UpdateInstaller(", "UpdateRelauncher(", "UpdateExercise.start"):
                self.assertNotIn(forbidden, source, name)
        snapshot = (ROOT / "Sources/OilFindApp/Snapshot.swift").read_text()
        self.assertNotIn("Library/Caches/Oil Find", snapshot)
        self.assertNotIn('state.hasPrefix("update-")', snapshot)
        self.assertNotIn("update-available", snapshot)

    def test_signing_certificate_has_independent_name_and_backup(self):
        source = (ROOT / "scripts/create-signing-cert.sh").read_text()
        self.assertIn('NAME="Mistary Self-Signed"', source)
        self.assertIn('Documents/Mistary Signing', source)
        self.assertIn('mistary-signing.p12', source)
        self.assertNotIn('Oil Find', source)

    def test_build_script_maps_executable_and_ignores_upstream_signing_override(self):
        for configuration, identity in (("debug", ""), ("release", "Mistary Test Identity"), ("release", ""),
                                        ("release", "-"), ("debug", "Oil Find Self-Signed")):
            with self.subTest(configuration=configuration), tempfile.TemporaryDirectory(prefix="mistary-build-test-") as directory:
                root = Path(directory)
                (root / "scripts").mkdir()
                (root / "Resources").mkdir()
                shutil.copy2(ROOT / "scripts/build-app.sh", root / "scripts/build-app.sh")
                shutil.copy2(ROOT / "Resources/Info.plist", root / "Resources/Info.plist")
                binary = root / "swift-bin"
                binary.mkdir()
                (binary / "OilFind").write_text("fixture executable")
                commands = root / "commands"
                commands.mkdir()
                log = root / "calls.jsonl"
                stub = commands / "stub"
                stub.write_text(r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
name, args = Path(sys.argv[0]).name, sys.argv[1:]
with open(os.environ['MISTARY_TEST_LOG'], 'a') as log:
    log.write(json.dumps([name, *args]) + '\n')
if name == 'swift':
    assert os.environ['OILFIND_FREE'] == '1'
    if '--show-bin-path' in args: print(os.environ['MISTARY_TEST_BINARY'])
''')
                stub.chmod(0o755)
                for name in ("swift", "codesign", "security", "strip"):
                    (commands / name).symlink_to(stub)
                env = dict(os.environ, PATH=str(commands) + os.pathsep + os.environ["PATH"],
                           MISTARY_TEST_LOG=str(log), MISTARY_TEST_BINARY=str(binary),
                           MISTARY_SIGN_IDENTITY=identity, OILFIND_SIGN_IDENTITY="Never use upstream identity")
                arguments = ["--debug"] if configuration == "debug" else []
                result = subprocess.run(["bash", str(root / "scripts/build-app.sh"), *arguments], env=env,
                                        capture_output=True, text=True)
                if identity in ("-", "Oil Find Self-Signed"):
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("Refusing an upstream or ad-hoc release", result.stderr)
                    self.assertFalse(log.exists())
                    continue
                if configuration == "release" and not identity:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("Release requires MISTARY_SIGN_IDENTITY", result.stderr)
                    calls = [json.loads(line) for line in log.read_text().splitlines()]
                    self.assertFalse(any(call[0] == "codesign" for call in calls))
                    continue
                self.assertEqual(result.returncode, 0, result.stderr)
                app = root / "build" / ("debug/Mistary.app" if configuration == "debug" else "Mistary.app")
                self.assertEqual((app / "Contents/MacOS/Mistary").read_text(), "fixture executable")
                self.assertFalse((app / "Contents/MacOS/OilFind").exists())
                calls = [json.loads(line) for line in log.read_text().splitlines()]
                signed = next(call for call in calls if call[0] == "codesign")
                self.assertEqual(signed[signed.index("--identifier") + 1], "me.caph.mistary")
                self.assertEqual(signed[signed.index("--sign") + 1], identity or "-")


if __name__ == "__main__":
    unittest.main()
