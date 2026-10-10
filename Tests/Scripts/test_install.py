import unittest
from test_uninstall import ScriptFixture


class InstallTests(ScriptFixture, unittest.TestCase):
    def test_installs_only_mistary_and_recycles_previous_bundle(self):
        result, state, calls, files = self.scenario("install.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(files["app"] and files["trash_app"] and files["data"])
        self.assertEqual(state["settings"], {"pinyinEnabled": True})
        self.assertTrue(any(call[0] == "ditto" and call[-1].endswith("/new/Mistary.app") for call in calls))
        self.assertEqual(files["payload"], "new")
        self.assertTrue(any(call[0] == "open" and call[-1].endswith("/Mistary.app") for call in calls))
        self.assertFalse(any(call[0] == "defaults" for call in calls))

    def test_process_errors_stop_before_replacement(self):
        for mode in ("query-fail", "quit-fail", "stuck"):
            with self.subTest(mode=mode):
                result, state, calls, files = self.scenario("install.sh", mode=mode)
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue(files["app"])
                self.assertFalse(files["trash_app"])
                self.assertEqual(files["payload"], "previous")
                self.assertFalse(any(call[0] in ("mv", "open") for call in calls))

    def test_same_name_or_symlink_destination_is_not_touched(self):
        for options in ({"destination_id": "org.other.mistary"}, {"linked": True}):
            with self.subTest(options=options):
                result, state, calls, files = self.scenario("install.sh", **options)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(calls, [])
                self.assertTrue(files["app"])

    def test_invalid_source_does_not_quit_or_replace_apps(self):
        result, state, calls, files = self.scenario("install.sh", source_id="com.oiloil.find")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(call[0] in ("osascript", "ditto", "open") for call in calls))
        self.assertTrue(files["app"])

    def test_invalid_signature_does_not_quit_or_replace_apps(self):
        result, state, calls, files = self.scenario("install.sh", mode="sign-fail")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(call[0] in ("osascript", "ditto", "open") for call in calls))
        self.assertTrue(files["app"])

    def test_trash_failure_preserves_previous_bundle_in_staging(self):
        result, state, calls, files = self.scenario("install.sh", mode="trash-fail")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(files["app"] and files["staged_backup"])
        self.assertIn("Installation files preserved", result.stderr)

    def test_copy_failure_keeps_previous_bundle_in_place(self):
        result, state, calls, files = self.scenario("install.sh", mode="copy-fail")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(files["app"] and files["data"])
        self.assertEqual(files["payload"], "previous")
        self.assertFalse(any(call[0] in ("mv", "open") for call in calls))

    def test_swap_failure_restores_previous_bundle(self):
        result, state, calls, files = self.scenario("install.sh", mode="swap-fail")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(files["payload"], "previous")
        self.assertFalse(any(call[0] == "open" for call in calls))

    def test_failed_rollback_preserves_previous_bundle_and_reports_path(self):
        result, state, calls, files = self.scenario("install.sh", mode="rollback-fail")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(files["staged_backup"])
        self.assertIn("Previous app preserved", result.stderr)
        self.assertFalse(any(call[0] == "open" for call in calls))

    def test_interrupt_between_moves_restores_previous_bundle(self):
        result, state, calls, files = self.scenario("install.sh", mode="interrupt-after-backup")
        self.assertEqual(result.returncode, 143, result.stderr)
        self.assertEqual(files["payload"], "previous")
        self.assertFalse(any(call[0] == "open" for call in calls))

    def test_interrupted_failed_recovery_keeps_backup_and_reports_path(self):
        result, state, calls, files = self.scenario("install.sh", mode="interrupt-and-rollback-fail")
        self.assertEqual(result.returncode, 143, result.stderr)
        self.assertTrue(files["staged_backup"])
        self.assertIn("Previous app preserved", result.stderr)
        self.assertFalse(any(call[0] == "open" for call in calls))

    def test_open_failure_is_reported_after_five_attempts(self):
        result, state, calls, files = self.scenario("install.sh", mode="open-fail")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(sum(call[0] == "open" for call in calls), 5)
        self.assertTrue(files["app"])

    def test_invalid_arguments_do_not_build(self):
        result, state, calls, files = self.scenario("install.sh", ("--unexpected",))
        self.assertEqual(result.returncode, 2)
        self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
