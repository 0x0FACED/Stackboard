import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

from scripts.update_homebrew import UpdateError, update_cask


# Exact current public cask; never read or write an installed Homebrew tap.
CURRENT_SHA = "5470c0aaff82a1c269f45a9e572eeedace2a2e2845b815874896c3ea0d602dd2"
NEXT_SHA = "b" * 64
CURRENT_CASK = '''cask "stackboard" do
  version "1.0.0"
  sha256 "5470c0aaff82a1c269f45a9e572eeedace2a2e2845b815874896c3ea0d602dd2"

  url "https://github.com/0x0FACED/stackboard/releases/download/v#{version}/Stackboard.zip"
  name "Stackboard"
  desc "Menu bar screenshot editor with clipboard history"
  homepage "https://github.com/0x0FACED/stackboard"

  app "Stackboard.app"
end
'''


class UpdateHomebrewTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.cask = Path(self.temporary.name) / "stackboard.rb"
        self.cask.write_bytes(CURRENT_CASK.encode("utf-8"))

    def update(self, **overrides):
        values = {
            "version": "1.0.1",
            "sha256": NEXT_SHA,
            "minimum_macos": "13.5",
        }
        values.update(overrides)
        return update_cask(self.cask, **values)

    def assert_rejected_unchanged(self, **overrides):
        original = self.cask.read_bytes()
        permissions = stat.S_IMODE(self.cask.stat().st_mode)
        with self.assertRaises(UpdateError):
            self.update(**overrides)
        self.assertEqual(self.cask.read_bytes(), original)
        self.assertEqual(stat.S_IMODE(self.cask.stat().st_mode), permissions)
        self.assertEqual(set(self.cask.parent.iterdir()), {self.cask})

    def test_current_public_cask_upgrades_and_reruns_without_another_write(self):
        self.assertTrue(self.update(version="v1.0.1"))
        expected = CURRENT_CASK.replace('version "1.0.0"', 'version "1.0.1"')
        expected = expected.replace(CURRENT_SHA, NEXT_SHA)
        expected = expected.replace(
            '  app "Stackboard.app"',
            '  depends_on macos: :ventura\n  app "Stackboard.app"',
        )
        self.assertEqual(self.cask.read_bytes(), expected.encode("utf-8"))
        before = self.cask.stat()
        self.assertFalse(self.update())
        after = self.cask.stat()
        self.assertEqual((after.st_ino, after.st_mtime_ns), (before.st_ino, before.st_mtime_ns))

    def test_downgrade_leaves_cask_unchanged(self):
        self.cask.write_text(CURRENT_CASK.replace('version "1.0.0"', 'version "2.0.0"'))
        self.assert_rejected_unchanged(version="1.999.999")

    def test_same_version_cannot_replace_immutable_zip(self):
        self.assert_rejected_unchanged(version="1.0.0", sha256=NEXT_SHA)

    def test_version_order_is_numeric_in_both_directions(self):
        self.cask.write_text(CURRENT_CASK.replace('version "1.0.0"', 'version "1.9.0"'))
        self.assertTrue(self.update(version="1.10.0"))
        self.assertIn('version "1.10.0"', self.cask.read_text())
        self.assert_rejected_unchanged(version="1.9.99")

    def test_same_artifact_can_acquire_minimum_macos_metadata(self):
        self.assertTrue(self.update(version="1.0.0", sha256=CURRENT_SHA.upper()))
        result = self.cask.read_text()
        self.assertIn(f'sha256 "{CURRENT_SHA}"', result)
        self.assertIn('depends_on macos: :ventura\n  app "Stackboard.app"', result)
        self.assertFalse(self.update(version="1.0.0", sha256=CURRENT_SHA))

    def test_minor_and_patch_changes_within_known_macos_major_are_idempotent(self):
        cases = (
            ("13.0", "13.6.1", "ventura"),
            ("14.1", "14.5.2", "sonoma"),
            ("15.0", "15.2.1", "sequoia"),
            ("26.0", "26.1.2", "tahoe"),
        )
        for first, later, symbol in cases:
            with self.subTest(symbol=symbol):
                self.cask.write_text(CURRENT_CASK)
                self.assertTrue(self.update(version="1.0.0", sha256=CURRENT_SHA, minimum_macos=first))
                self.assertIn(f"depends_on macos: :{symbol}", self.cask.read_text())
                original = self.cask.read_bytes()
                inode = self.cask.stat().st_ino
                self.assertFalse(self.update(version="1.0.0", sha256=CURRENT_SHA, minimum_macos=later))
                self.assertEqual(self.cask.read_bytes(), original)
                self.assertEqual(self.cask.stat().st_ino, inode)

    def test_unknown_numeric_macos_release_is_rejected_without_modifying_file(self):
        for value in ("16.0", "25.1", "99.0.1"):
            with self.subTest(minimum_macos=value):
                original = self.cask.read_bytes()
                with self.assertRaisesRegex(UpdateError, "unsupported minimum macOS release"):
                    self.update(minimum_macos=value)
                self.assertEqual(self.cask.read_bytes(), original)
                self.assertEqual(set(self.cask.parent.iterdir()), {self.cask})

    def test_minimum_macos_updates_preserve_caveats_zap_and_other_dependencies(self):
        unrelated = '''  depends_on formula: "some-formula"
  caveats <<~EOS
    version "999.0.0"
    sha256 "these are instructions, not metadata"
    cask "another-app" do
    Keep the user's capture directory.
  EOS
  caveats do
    puts "Run Stackboard from Applications."
  end
  zap trash: [
    "~/Library/Preferences/dev.0xfaced.Stackboard.plist",
    "~/Library/Application Support/Stackboard",
  ]
'''
        original = CURRENT_CASK.replace(
            '  app "Stackboard.app"',
            '  depends_on macos: :ventura # Keep the OS floor.\n'
            '  app "Stackboard.app"',
        )
        original = original.rsplit("end\n", 1)[0] + unrelated + "end\n"
        self.cask.write_text(original)
        self.assertTrue(self.update(version="1.0.0", sha256=CURRENT_SHA, minimum_macos="14.5.1"))
        self.assertEqual(
            self.cask.read_text(),
            original.replace("macos: :ventura", "macos: :sonoma"),
        )
        self.assertFalse(self.update(version="1.0.0", sha256=CURRENT_SHA, minimum_macos="14.5.1"))

    def test_existing_minimum_macos_is_moved_before_app_without_losing_its_comment(self):
        original = CURRENT_CASK.replace(
            '  app "Stackboard.app"\n',
            '  app "Stackboard.app"\n  depends_on macos: :ventura # OS floor\n',
        )
        self.cask.write_text(original)
        self.assertTrue(self.update(version="1.0.0", sha256=CURRENT_SHA))
        self.assertEqual(
            self.cask.read_text(),
            CURRENT_CASK.replace(
                '  app "Stackboard.app"',
                '  depends_on macos: :ventura # OS floor\n  app "Stackboard.app"',
            ),
        )


    def test_invalid_release_inputs_do_not_touch_file(self):
        cases = [
            {"version": value}
            for value in ("1.0", "01.0.1", "1.0.1-rc.1", "1.0.1+build.2", " 1.0.1", "vv1.0.1", "1.0.1\n")
        ]
        cases += [{"sha256": value} for value in ("", "a" * 63, "a" * 65, "g" * 64, "a" * 64 + "\n")]
        cases += [
            {"minimum_macos": value}
            for value in ("ventura", ">= 13.5", "13.x", "13..5", "13.05", "0.1", "13.5.1.2", "13.5\n")
        ]
        for values in cases:
            with self.subTest(values=values):
                self.assert_rejected_unchanged(**values)

    def test_ambiguous_and_malformed_owned_stanzas_are_not_rewritten(self):
        versions = '  version "1.0.0"\n'
        hashes = f'  sha256 "{CURRENT_SHA}"\n'
        variants = {
            "missing version": CURRENT_CASK.replace(versions, ""),
            "duplicate version": CURRENT_CASK.replace(versions, versions * 2),
            "missing sha": CURRENT_CASK.replace(hashes, ""),
            "duplicate sha": CURRENT_CASK.replace(hashes, hashes * 2),
            "dynamic version": CURRENT_CASK.replace(versions, '  version ENV.fetch("VERSION")\n'),
            "noncanonical version": CURRENT_CASK.replace(versions, '  version "01.0.0"\n'),
            "unterminated version": CURRENT_CASK.replace(versions, '  version "1.0.0\n'),
            "malformed sha": CURRENT_CASK.replace(hashes, '  sha256 :no_check\n'),
            "bad sha literal": CURRENT_CASK.replace(CURRENT_SHA, "f" * 63),
            "multiple declarations on one line": CURRENT_CASK.replace(versions, '  version "1.0.0"; version "2.0.0"\n'),
            "conditional version": CURRENT_CASK.replace(versions, '  if true\n    version "1.0.0"\n  end\n'),
            "conditional app": CURRENT_CASK.replace('  app "Stackboard.app"\n', '  on_arm do\n    app "Stackboard.app"\n  end\n'),
            "duplicate macos": CURRENT_CASK.replace('  app "Stackboard.app"', '  depends_on macos: :ventura\n  depends_on macos: :sonoma\n  app "Stackboard.app"'),
            "unknown macos symbol": CURRENT_CASK.replace('  app "Stackboard.app"', '  depends_on macos: :unknown_release\n  app "Stackboard.app"'),
            "numeric macos comparison": CURRENT_CASK.replace('  app "Stackboard.app"', '  depends_on macos: ">= 13.5"\n  app "Stackboard.app"'),
            "legacy macos syntax": CURRENT_CASK.replace('  app "Stackboard.app"', '  depends_on :macos => :ventura\n  app "Stackboard.app"'),
            "unterminated cask": CURRENT_CASK.removesuffix("end\n"),
            "second cask": CURRENT_CASK + CURRENT_CASK,
            "unterminated heredoc": CURRENT_CASK.replace('  app "Stackboard.app"', '  caveats <<~EOS\n  app "Stackboard.app"'),
            "unbalanced zap": CURRENT_CASK.replace('  app "Stackboard.app"', '  app "Stackboard.app"\n  zap trash: ["~/Library/Stackboard"'),
        }
        for label, contents in variants.items():
            with self.subTest(label=label):
                self.cask.write_text(contents)
                self.assert_rejected_unchanged()

    def test_wrong_identity_app_or_source_is_not_rewritten(self):
        url = 'https://github.com/0x0FACED/stackboard/releases/download/v#{version}/Stackboard.zip'
        variants = {
            "other cask": CURRENT_CASK.replace('cask "stackboard"', 'cask "other-app"'),
            "other app": CURRENT_CASK.replace('app "Stackboard.app"', 'app "Other.app"'),
            "missing app": CURRENT_CASK.replace('  app "Stackboard.app"\n', ""),
            "duplicate app": CURRENT_CASK.replace('  app "Stackboard.app"\n', '  app "Stackboard.app"\n  app "Other.app"\n'),
            "other publisher": CURRENT_CASK.replace("/0x0FACED/stackboard/releases/", "/someone/stackboard/releases/"),
            "unversioned URL": CURRENT_CASK.replace("/v#{version}/", "/latest/"),
            "other archive": CURRENT_CASK.replace("/Stackboard.zip", "/Other.zip"),
            "missing URL": CURRENT_CASK.replace(f'  url "{url}"\n', ""),
            "duplicate URL": CURRENT_CASK.replace(f'  url "{url}"\n', f'  url "{url}"\n  url "{url}"\n'),
            "noninterpolating URL": CURRENT_CASK.replace(f'url "{url}"', f"url '{url}'"),
        }
        for label, contents in variants.items():
            with self.subTest(label=label):
                self.cask.write_text(contents)
                self.assert_rejected_unchanged()

    def test_atomic_replacement_retains_permissions(self):
        os.chmod(self.cask, 0o640)
        self.assertTrue(self.update())
        self.assertEqual(stat.S_IMODE(self.cask.stat().st_mode), 0o640)
        self.assertEqual(set(self.cask.parent.iterdir()), {self.cask})

    def test_failed_atomic_replacement_leaves_original_and_no_temporary_file(self):
        original = self.cask.read_bytes()
        with mock.patch("scripts.update_homebrew.os.replace", side_effect=OSError("replacement denied")):
            with self.assertRaisesRegex(OSError, "replacement denied"):
                self.update()
        self.assertEqual(self.cask.read_bytes(), original)
        self.assertEqual(set(self.cask.parent.iterdir()), {self.cask})

    def test_cli_reports_immutable_artifact_failure_without_modification(self):
        original = self.cask.read_bytes()
        result = subprocess.run(
            [
                sys.executable,
                str(Path(__file__).resolve().parents[1] / "scripts" / "update_homebrew.py"),
                str(self.cask),
                "--version", "1.0.0",
                "--sha256", NEXT_SHA,
                "--minimum-macos", "13.5",
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("immutable", result.stderr)
        self.assertNotIn("Traceback", result.stderr)
        self.assertEqual(self.cask.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
