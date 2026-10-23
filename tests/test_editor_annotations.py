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
                str(root / "Stackboard" / "EditorAnnotationGeometry.swift"),
                str(root / "Stackboard" / "ScreenshotExport.swift"),
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
            capture_output=True, text=True, timeout=90,
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

    def test_text_reopening_reversible_pending_edits_and_clearing(self):
        self.run_scenario("text-editing")

    def test_cyrillic_multiline_layout_matches_export_ink_and_bounds(self):
        self.run_scenario("text-layout-export")

    def test_text_move_and_width_handle_preserve_pointer_offsets(self):
        self.run_scenario("text-move-resize")

    def test_text_native_point_size_and_near_edge_input(self):
        self.run_scenario("text-retina-edges")

    def test_visual_creation_and_eraser_actions_roundtrip_payloads_and_pixels(self):
        self.run_scenario("creation-history")

    def test_many_move_and_resize_events_form_single_reversible_edits(self):
        self.run_scenario("object-move-resize-history")

    def test_arrow_endpoint_handles_and_degenerate_paths_remain_editable(self):
        self.run_scenario("arrow-endpoints-degenerate")

    def test_ink_hit_testing_and_eraser_order_match_visible_objects(self):
        self.run_scenario("ink-hit-mask-order")

    def test_selected_style_sliders_and_native_text_sessions_group_history(self):
        self.run_scenario("selected-style-history")

    def test_duplicate_and_delete_restore_ids_order_selection_and_export(self):
        self.run_scenario("duplicate-delete-history")

    def test_noops_and_cancel_preserve_redo_and_editors_have_independent_history(self):
        self.run_scenario("redo-boundaries-isolation")

    def test_png_and_jpeg_preserve_retina_composites_alpha_and_quality(self):
        self.run_scenario("file-export")

    def test_crop_preserves_native_retina_pixels_and_point_scale(self):
        self.run_scenario("crop-retina-pixels")

    def test_crop_preserves_partial_annotations_wrapping_blur_and_mask_order(self):
        self.run_scenario("crop-annotations-masks")

    def test_repeated_crops_and_subsequent_edits_share_reversible_history(self):
        self.run_scenario("crop-interleaved-history")

    def test_crop_drafts_finish_sessions_cancel_gestures_and_preserve_redo(self):
        self.run_scenario("crop-draft-boundaries")

    def test_crop_rejects_invalid_bounds_and_keeps_tiny_fractional_regions(self):
        self.run_scenario("crop-draft-bounds")

    def test_crop_pixels_survive_1x_and_2x_graphics_contexts(self):
        self.run_scenario("crop-native-contexts")


if __name__ == "__main__":
    unittest.main()
