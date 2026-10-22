"""Consumer-visible annotation behavior exercised against the real Swift document."""

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


@unittest.skipUnless(sys.platform == "darwin", "The editor uses macOS AppKit")
class EditorAnnotationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="stackboard-editor-tests-")
        cls.addClassCleanup(cls.temporary.cleanup)
        root = Path(__file__).resolve().parents[1]
        output = Path(cls.temporary.name)
        cls.executable = output / "editor-annotation-tests"
        result = subprocess.run(
            [
                "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
                "-default-isolation", "MainActor",
                "-module-cache-path", str(output / "module-cache"),
                str(root / "Stackboard" / "EditorDocument.swift"),
                str(root / "tests" / "EditorAnnotationTests.swift"),
                "-o", str(cls.executable),
            ],
            capture_output=True, text=True, timeout=120,
        )
        if result.returncode:
            raise RuntimeError(result.stdout + result.stderr)

    def run_scenario(self, scenario):
        result = subprocess.run(
            [str(self.executable), scenario],
            capture_output=True, text=True, timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_erasing_preserves_source_pixels_and_transparency(self):
        self.run_scenario("background")

    def test_partial_erase_interpolates_between_pointer_events(self):
        self.run_scenario("partial")

    def test_erase_order_and_undo_restore_previous_composites(self):
        self.run_scenario("ordering")

    def test_active_erase_cancellation_and_click_brush(self):
        self.run_scenario("cancellation")

    def test_every_annotation_type_can_be_partially_erased(self):
        self.run_scenario("annotation-types")

    def test_outside_motion_does_not_erase_along_image_edge(self):
        self.run_scenario("outside-path")

    def test_text_reopening_replacement_cancellation_and_clearing(self):
        self.run_scenario("text-editing")

    def test_cyrillic_multiline_layout_matches_export_ink_and_bounds(self):
        self.run_scenario("text-layout-export")

    def test_text_move_and_width_handle_preserve_pointer_offsets(self):
        self.run_scenario("text-move-resize")

    def test_text_native_point_size_and_near_edge_input(self):
        self.run_scenario("text-retina-edges")


if __name__ == "__main__":
    unittest.main()
