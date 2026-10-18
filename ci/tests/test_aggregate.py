import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

import aggregate  # noqa: E402
from helpers import write_png  # noqa: E402


class AggregateTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = self._tmp.name
        self.artifacts = os.path.join(self.root, "artifacts")
        self.out = os.path.join(self.root, "out")

    def tearDown(self):
        self._tmp.cleanup()

    def add_artifact(self, name, files):
        """Create artifacts/<name>/final/<file> for each file name, like download-artifact does."""
        folder = os.path.join(self.artifacts, name, "final")
        os.makedirs(folder, exist_ok=True)
        for file_name in files:
            write_png(os.path.join(folder, file_name), (6, 12), (10, 20, 30))

    def test_combines_artifacts_into_sheet_index_and_screens(self):
        self.add_artifact(
            "screenshots-abc1234-iphone17pro-dark",
            ["07-today-iphone17pro-dark.png", "11-trends-iphone17pro-dark.png"],
        )
        self.add_artifact(
            "screenshots-abc1234-iphone17e-light",
            ["07-today-iphone17e-light.png"],
        )

        count = aggregate.aggregate(self.artifacts, self.out)

        self.assertEqual(count, 3)
        self.assertTrue(os.path.isfile(os.path.join(self.out, "contact-sheet-all.png")))
        self.assertTrue(os.path.isfile(os.path.join(self.out, "screens", "07-today-iphone17e-light.png")))
        with open(os.path.join(self.out, "index.md"), encoding="utf-8") as f:
            index = f.read()
        self.assertIn("| 07 today | iphone17pro | dark | [07-today-iphone17pro-dark.png](screens/07-today-iphone17pro-dark.png) |", index)
        self.assertIn("| 11 trends | iphone17pro | dark |", index)
        self.assertIn("| 07 today | iphone17e | light |", index)

    def test_skips_contact_sheets_and_unexpected_names(self):
        self.add_artifact(
            "screenshots-abc1234-iphone17pro-dark",
            ["07-today-iphone17pro-dark.png", "contact-sheet-iphone17pro-dark.png", "random.png"],
        )

        count = aggregate.aggregate(self.artifacts, self.out)

        self.assertEqual(count, 1)
        self.assertEqual(os.listdir(os.path.join(self.out, "screens")), ["07-today-iphone17pro-dark.png"])

    def test_fails_when_no_screenshots(self):
        os.makedirs(self.artifacts)

        with self.assertRaises(aggregate.AggregateError):
            aggregate.aggregate(self.artifacts, self.out)

    def test_fails_on_duplicate_name_across_artifacts(self):
        self.add_artifact("a", ["07-today-iphone17pro-dark.png"])
        self.add_artifact("b", ["07-today-iphone17pro-dark.png"])

        with self.assertRaises(aggregate.AggregateError):
            aggregate.aggregate(self.artifacts, self.out)


if __name__ == "__main__":
    unittest.main()
