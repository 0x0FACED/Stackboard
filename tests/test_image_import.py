"""Consumer-visible image import behavior exercised against the real Swift editor."""

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


@unittest.skipUnless(sys.platform == "darwin", "Image import uses macOS AppKit")
class ImageImportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="stackboard-image-import-tests-")
        cls.addClassCleanup(cls.temporary.cleanup)
        root = Path(__file__).resolve().parents[1]
        output = Path(cls.temporary.name)
        cls.executable = output / "image-import-tests"
        result = subprocess.run(
            [
                "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
                "-default-isolation", "MainActor",
                "-module-cache-path", str(output / "module-cache"),
                str(root / "Stackboard" / "EditorImageImport.swift"),
                str(root / "Stackboard" / "EditorDocument.swift"),
                str(root / "Stackboard" / "EditorAnnotationGeometry.swift"),
                str(root / "Stackboard" / "ScreenshotExport.swift"),
                str(root / "tests" / "ImageImportTests.swift"),
                "-o", str(cls.executable),
            ],
            capture_output=True, text=True, timeout=120,
        )
        if result.returncode:
            raise RuntimeError(result.stdout + result.stderr)

    def run_scenario(self, scenario):
        result = subprocess.run(
            [str(self.executable), scenario],
            capture_output=True, text=True, timeout=90,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_file_png_keeps_native_pixels_alpha_and_source(self):
        self.run_scenario("file-png")

    def test_named_clipboard_prefers_full_png_and_remains_untouched(self):
        self.run_scenario("clipboard-png")

    def test_exif_jpeg_is_rotated_to_upright_native_pixels(self):
        self.run_scenario("jpeg-orientation")

    def test_retina_tiff_clipboard_keeps_pixels_and_logical_point_size(self):
        self.run_scenario("clipboard-retina-tiff")

    def test_invalid_files_and_non_image_clipboards_are_rejected(self):
        self.run_scenario("import-errors")

    def test_imported_documents_have_independent_edits_crop_history_and_export(self):
        self.run_scenario("document-isolation")


if __name__ == "__main__":
    unittest.main()
