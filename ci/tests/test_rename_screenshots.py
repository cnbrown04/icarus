import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

import rename_screenshots  # noqa: E402
from helpers import write_png  # noqa: E402

UUID_A = "7B1C0E2A-1F3D-4C5B-8A9E-0D1C2B3A4F5E"
UUID_B = "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D"


class RenameScreenshotsTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = self._tmp.name
        self.raw = os.path.join(self.root, "raw")
        self.out = os.path.join(self.root, "final")
        os.makedirs(self.raw)

    def tearDown(self):
        self._tmp.cleanup()

    def write_manifest(self, entries, files):
        for exported, color in files.items():
            write_png(os.path.join(self.raw, exported), (4, 8), color)
        path = os.path.join(self.raw, "manifest.json")
        with open(path, "w", encoding="utf-8") as f:
            json.dump(entries, f)
        return path

    def test_strip_suffix_removes_index_and_uuid(self):
        self.assertEqual(
            rename_screenshots.strip_suffix(f"07-today_0_{UUID_A}.png"), "07-today.png"
        )

    def test_strip_suffix_leaves_plain_names_alone(self):
        self.assertEqual(rename_screenshots.strip_suffix("07-today.png"), "07-today.png")

    def test_maps_attachments_to_final_names(self):
        manifest = self.write_manifest(
            [
                {
                    "testIdentifier": "ScreenshotTests/testScreens()",
                    "attachments": [
                        {
                            "exportedFileName": "a.png",
                            "suggestedHumanReadableName": f"07-today_0_{UUID_A}.png",
                        },
                        {
                            "exportedFileName": "b.png",
                            "suggestedHumanReadableName": f"11-trends_1_{UUID_B}.png",
                        },
                    ],
                }
            ],
            {"a.png": (255, 0, 0), "b.png": (0, 255, 0)},
        )

        names = rename_screenshots.rename(manifest, self.out, "iphone17pro", "dark")

        self.assertEqual(
            names, ["07-today-iphone17pro-dark.png", "11-trends-iphone17pro-dark.png"]
        )
        self.assertEqual(sorted(os.listdir(self.out)), names)

    def test_skips_names_without_a_two_digit_prefix_and_non_png(self):
        manifest = self.write_manifest(
            [
                {
                    "attachments": [
                        {
                            "exportedFileName": "launch.png",
                            "suggestedHumanReadableName": f"Launch screen_0_{UUID_A}.png",
                        },
                        {
                            "exportedFileName": "log.txt",
                            "suggestedHumanReadableName": f"01-welcome_0_{UUID_A}.txt",
                        },
                        {
                            "exportedFileName": "w.png",
                            "suggestedHumanReadableName": f"01-welcome_0_{UUID_B}.png",
                        },
                    ]
                }
            ],
            {"launch.png": (0, 0, 0), "w.png": (1, 1, 1)},
        )
        with open(os.path.join(self.raw, "log.txt"), "w", encoding="utf-8") as f:
            f.write("log")

        names = rename_screenshots.rename(manifest, self.out, "iphone17e", "light")

        self.assertEqual(names, ["01-welcome-iphone17e-light.png"])

    def test_reads_nested_subtests(self):
        manifest = self.write_manifest(
            [
                {
                    "subtests": [
                        {
                            "attachments": [
                                {
                                    "exportedFileName": "n.png",
                                    "suggestedHumanReadableName": f"12-alarms_0_{UUID_A}.png",
                                }
                            ]
                        }
                    ]
                }
            ],
            {"n.png": (9, 9, 9)},
        )

        names = rename_screenshots.rename(manifest, self.out, "iphone17pro", "light")

        self.assertEqual(names, ["12-alarms-iphone17pro-light.png"])

    def test_fails_when_no_screenshots_found(self):
        manifest = self.write_manifest(
            [{"attachments": [{"exportedFileName": "x.png", "suggestedHumanReadableName": "Other_0_x.png"}]}],
            {"x.png": (0, 0, 0)},
        )

        with self.assertRaises(rename_screenshots.ScreenshotError):
            rename_screenshots.rename(manifest, self.out, "iphone17pro", "dark")

    def test_rejects_unknown_appearance(self):
        manifest = self.write_manifest([], {})

        with self.assertRaises(rename_screenshots.ScreenshotError):
            rename_screenshots.rename(manifest, self.out, "iphone17pro", "sepia")

    def test_rejects_device_slug_with_spaces(self):
        manifest = self.write_manifest([], {})

        with self.assertRaises(rename_screenshots.ScreenshotError):
            rename_screenshots.rename(manifest, self.out, "iPhone 17 Pro", "dark")

    def test_main_returns_nonzero_when_empty(self):
        manifest = self.write_manifest([], {})

        self.assertEqual(rename_screenshots.main(["x", manifest, self.out, "iphone17pro", "dark"]), 1)


if __name__ == "__main__":
    unittest.main()
