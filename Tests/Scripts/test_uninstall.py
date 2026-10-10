import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
BUNDLE_ID = "me.caph.mistary"


class ScriptFixture:
    """All writes occur inside a temporary home; external side effects are stubbed."""
    def scenario(self, script, arguments=(), answer="y\n", mode="", destination_id=BUNDLE_ID,
                 linked=False, processes=True, source_id=BUNDLE_ID):
        with tempfile.TemporaryDirectory(prefix="mistary-script-test-") as directory:
            root = Path(directory)
            home, apps, source, commands = (root / name for name in ("home", "apps", "source/Mistary.app", "bin"))
            for path in (home, apps, commands):
                path.mkdir(parents=True)
            app = apps / "Mistary.app"
            for path, identity in ((app, destination_id), (source, source_id)):
                (path / "Contents").mkdir(parents=True)
                (path / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": identity}))
                (path / "Contents/payload").write_text("previous" if path == app else "new")
            if linked:
                app.rename(apps / "linked-target.app")
                app.symlink_to(apps / "linked-target.app")
            data = home / "Library/Application Support/Mistary"
            data.mkdir(parents=True)
            (data / "index.oilfind").write_text("personal")
            old_paths = [apps / "Oil Find.app", apps / "Sift.app",
                         home / "Library/Application Support/Oil Find",
                         home / "Library/Application Support/Sift", home / "Library/Caches/Oil Find",
                         home / "Library/Preferences/com.oiloil.find.plist"]
            for path in old_paths:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("upstream sentinel")
            state = root / "state.json"
            state.write_text(json.dumps({"running": processes, "settings": {"pinyinEnabled": True}, "other_pids": [777]}))
            log = root / "calls.jsonl"
            stub = commands / "stub"
            stub.write_text(r'''#!/usr/bin/env python3
import json, os, shutil, signal, sys
from pathlib import Path
name, args = Path(sys.argv[0]).name, sys.argv[1:]
with open(os.environ['MISTARY_TEST_LOG'], 'a') as log:
    log.write(json.dumps([name, *args]) + '\n')
state_path = Path(os.environ['MISTARY_TEST_STATE'])
state = json.loads(state_path.read_text())
mode = os.environ.get('MISTARY_TEST_MODE', '')
if name == 'osascript':
    code = args[args.index('-e') + 1]
    if 'runningApplicationsWithBundleIdentifier' in code:
        assert "'me.caph.mistary'" in code
        if args[-1] == 'list':
            if mode == 'query-fail': sys.exit(1)
            print('123 456' if state['running'] else '')
        else:
            if mode == 'quit-fail': sys.exit(1)
            if mode != 'stuck': state['running'] = False
    else:
        assert 'trashItemAtURLResultingItemURLError' in code
        if mode == 'trash-fail': sys.exit(1)
        target = Path(args[-1])
        home = Path(os.environ['HOME'])
        apps = Path(os.environ['MISTARY_APPLICATIONS_DIR'])
        assert target in (apps / 'Mistary.app', home / 'Library/Application Support/Mistary') or (target.parent == apps and target.name.startswith('.Mistary-install.'))
        trash = home / '.Trash'
        trash.mkdir(exist_ok=True)
        shutil.move(str(target), str(trash / target.name))
elif name == 'defaults':
    assert args[1] == 'me.caph.mistary'
    if args[0] == 'read':
        if not state['settings']: sys.exit(1)
        print(json.dumps(state['settings']))
    elif args[0] == 'export':
        if mode == 'export-fail': sys.exit(1)
        Path(args[2]).write_text(json.dumps(state['settings']))
    elif args[0] == 'delete':
        state['settings'] = {}
elif name == 'ditto':
    if mode == 'copy-fail': sys.exit(1)
    shutil.copytree(args[0], args[1], dirs_exist_ok=True)
elif name == 'mv':
    source, target = map(Path, args)
    if mode in ('swap-fail', 'rollback-fail') and source.parent.name == 'new': sys.exit(1)
    if mode in ('rollback-fail', 'interrupt-and-rollback-fail') and source.parent.name == 'previous': sys.exit(1)
    shutil.move(str(source), str(target))
    if mode in ('interrupt-after-backup', 'interrupt-and-rollback-fail') and target.parent.name == 'previous':
        os.kill(os.getppid(), signal.SIGTERM)
elif name == 'open':
    if mode == 'open-fail': sys.exit(1)
elif name == 'codesign':
    if mode == 'sign-fail': sys.exit(1)
elif name in ('security', 'rm', 'pgrep'):
    raise AssertionError('Forbidden external side effect: ' + name)
state_path.write_text(json.dumps(state))
''')
            stub.chmod(0o755)
            for name in ("osascript", "defaults", "ditto", "open", "codesign", "sleep", "build", "security", "rm", "pgrep", "mv"):
                (commands / name).symlink_to(stub)
            env = dict(os.environ, HOME=str(home), PATH=str(commands) + os.pathsep + os.environ["PATH"],
                       MISTARY_TEST_LOG=str(log), MISTARY_TEST_STATE=str(state), MISTARY_TEST_MODE=mode,
                       MISTARY_APPLICATIONS_DIR=str(apps), MISTARY_SOURCE_APP=str(source),
                       MISTARY_BUILD_SCRIPT=str(commands / "build"))
            result = subprocess.run(["/bin/bash", str(ROOT / "scripts" / script), *arguments], input=answer,
                                    capture_output=True, text=True, env=env, timeout=15)
            calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
            saved = json.loads(state.read_text())
            self.assertTrue(all(path.read_text() == "upstream sentinel" for path in old_paths))
            self.assertEqual(saved["other_pids"], [777])
            self.assertFalse(any(call[0] in ("security", "rm", "pgrep") for call in calls))
            return result, saved, calls, {
                "app": app.exists(), "data": data.exists(),
                "payload": (app / "Contents/payload").read_text() if app.exists() else None,
                "trash_app": (home / ".Trash/Mistary.app").exists() or bool(list((home / ".Trash").glob(".Mistary-install.*/previous/Mistary.app"))),
                "staged_backup": bool(list(apps.glob(".Mistary-install.*/previous/Mistary.app"))),
                "trash_data": (home / ".Trash/Mistary").exists(),
                "settings_backups": [path.read_text() for path in (home / ".Trash").glob("Mistary-settings.*/*.plist")],
            }


class UninstallTests(ScriptFixture, unittest.TestCase):
    def test_default_trashes_only_app_and_keeps_data_and_settings(self):
        result, state, calls, files = self.scenario("uninstall.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(files["app"])
        self.assertTrue(files["trash_app"])
        self.assertTrue(files["data"])
        self.assertEqual(state["settings"], {"pinyinEnabled": True})
        self.assertFalse(any(call[0] == "defaults" for call in calls))
        self.assertTrue(any(call[-1] == "quit" for call in calls))

    def test_with_data_keeps_recoverable_backup_and_trashes_index(self):
        result, state, calls, files = self.scenario("uninstall.sh", ("--with-data",))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(files["trash_app"])
        self.assertTrue(files["trash_data"])
        self.assertEqual(state["settings"], {})
        self.assertEqual([json.loads(value) for value in files["settings_backups"]], [{"pinyinEnabled": True}])
        operations = [call[1] for call in calls if call[0] == "defaults"]
        self.assertEqual(operations, ["read", "export", "delete"])

    def test_cancel_and_invalid_arguments_have_no_side_effects(self):
        for arguments, answer, status in [((), "n\n", 0), ((), "", 0), (("--purge",), "y\n", 2),
                                           (("--with-data", "extra"), "y\n", 2)]:
            with self.subTest(arguments=arguments, answer=answer):
                result, state, calls, files = self.scenario("uninstall.sh", arguments, answer)
                self.assertEqual(result.returncode, status, result.stderr)
                self.assertEqual(calls, [])
                self.assertTrue(files["app"] and files["data"])

    def test_process_query_quit_or_timeout_failure_prevents_all_moves(self):
        for mode in ("query-fail", "quit-fail", "stuck"):
            with self.subTest(mode=mode):
                result, state, calls, files = self.scenario("uninstall.sh", ("--with-data",), mode=mode)
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue(files["app"] and files["data"])
                self.assertEqual(state["settings"], {"pinyinEnabled": True})
                self.assertFalse(any(call[0] == "defaults" for call in calls))

    def test_same_name_different_identity_and_symlink_are_rejected(self):
        for options in ({"destination_id": "org.other.mistary"}, {"linked": True}):
            with self.subTest(options=options):
                result, state, calls, files = self.scenario("uninstall.sh", **options)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(calls, [])
                self.assertTrue(files["app"] and files["data"])

    def test_trash_failure_does_not_clear_data_or_preferences(self):
        result, state, calls, files = self.scenario("uninstall.sh", ("--with-data",), mode="trash-fail")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(files["app"] and files["data"])
        self.assertFalse(any(call[0] == "defaults" for call in calls))

    def test_export_failure_does_not_clear_preferences_or_data(self):
        result, state, calls, files = self.scenario("uninstall.sh", ("--with-data",), mode="export-fail")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(files["data"])
        self.assertEqual(state["settings"], {"pinyinEnabled": True})
        self.assertFalse(any(call[:2] == ["defaults", "delete"] for call in calls))

    def test_no_running_instances_does_not_request_quit(self):
        result, state, calls, files = self.scenario("uninstall.sh", processes=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(call[-1] == "quit" for call in calls))


if __name__ == "__main__":
    unittest.main()
