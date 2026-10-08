"""Pre-extraction failures: these ZIP inputs are not executable app fixtures."""

from contextlib import redirect_stdout
import hashlib
from io import StringIO
from pathlib import Path
import stat
import tempfile
import unittest
import zipfile

from scripts.verify_release import verify_archive


class ArchiveSafetyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.archive = self.root / "Stackboard.zip"
        self.checksum = self.root / "SHA256SUMS"

    def write_archive(self, extras=()):
        with zipfile.ZipFile(self.archive, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("Stackboard.app/Contents/Info.plist", b"<plist><dict/></plist>")
            archive.writestr("Stackboard.app/Contents/MacOS/Stackboard", b"archive-path-fixture")
            for name, content, symlink in extras:
                info = zipfile.ZipInfo(name)
                info.create_system = 3
                info.external_attr = ((stat.S_IFLNK | 0o777) if symlink else (stat.S_IFREG | 0o644)) << 16
                archive.writestr(info, content)
        self.write_checksum()

    def write_checksum(self):
        value = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        self.checksum.write_text(f"{value}  Stackboard.zip\n", encoding="ascii")

    def assert_rejected(self):
        with redirect_stdout(StringIO()):
            with self.assertRaises((ValueError, zipfile.BadZipFile)):
                verify_archive(str(self.archive), str(self.checksum))

    def test_corrupt_download_is_rejected_before_extraction(self):
        self.write_archive()
        self.archive.write_bytes(self.archive.read_bytes() + b"changed download")
        self.assert_rejected()

    def test_correct_checksum_cannot_authorize_escaping_member_paths(self):
        for name in ("../outside", "Stackboard.app/Contents/../../outside", "/tmp/outside", "Other.app/Contents/file"):
            with self.subTest(name=name):
                self.write_archive([(name, b"outside", False)])
                self.assert_rejected()

    def test_symlink_chain_cannot_escape_app_through_parent_resolution(self):
        self.write_archive([
            ("Stackboard.app/Contents/root-link", b"..", True),
            ("Stackboard.app/Contents/escape-link", b"root-link/../outside", True),
        ])
        self.assert_rejected()

    def test_symlink_cycles_fail_instead_of_hanging_verification(self):
        self.write_archive([
            ("Stackboard.app/Contents/link-a", b"link-b", True),
            ("Stackboard.app/Contents/link-b", b"link-a", True),
        ])
        self.assert_rejected()

    def test_zip_cannot_write_members_beneath_a_symlink(self):
        self.write_archive([
            ("Stackboard.app/Contents/redirect", b"MacOS", True),
            ("Stackboard.app/Contents/redirect/extra", b"redirected write", False),
        ])
        self.assert_rejected()

    def test_mac_case_and_unicode_collisions_cannot_alias_different_files(self):
        for pair in (("Config", "config"), ("caf\u00e9", "cafe\u0301")):
            with self.subTest(pair=pair):
                self.write_archive([(f"Stackboard.app/Contents/{name}", b"different", False) for name in pair])
                self.assert_rejected()

    def test_streaming_zip_header_cannot_disagree_with_validated_directory(self):
        self.write_archive()
        content = bytearray(self.archive.read_bytes())
        content[30] = ord("X")
        self.archive.write_bytes(content)
        self.write_checksum()
        self.assert_rejected()


if __name__ == "__main__":
    unittest.main()
