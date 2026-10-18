import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from PIL import Image  # noqa: E402

import contact_sheet  # noqa: E402
from helpers import write_png  # noqa: E402


class ContactSheetTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = self._tmp.name
        self.in_dir = os.path.join(self.root, "in")
        os.makedirs(self.in_dir)
        self.out_png = os.path.join(self.root, "sheet.png")

    def tearDown(self):
        self._tmp.cleanup()

    def add_images(self, count, size=(100, 200)):
        for i in range(count):
            write_png(os.path.join(self.in_dir, f"0{i + 1}-screen-iphone17pro-dark.png"), size, (i * 40, 0, 0))

    def test_uses_at_most_four_columns(self):
        self.add_images(5)

        columns, rows = contact_sheet.build_sheet(self.in_dir, self.out_png)

        self.assertEqual((columns, rows), (4, 2))
        with Image.open(self.out_png) as sheet:
            # 4 tiles of 390 px, 3 gutters of 16 px, and 16 px margins on both sides.
            self.assertEqual(sheet.width, 4 * 390 + 3 * 16 + 2 * 16)

    def test_fewer_images_than_columns(self):
        self.add_images(2)

        columns, rows = contact_sheet.build_sheet(self.in_dir, self.out_png)

        self.assertEqual((columns, rows), (2, 1))
        with Image.open(self.out_png) as sheet:
            self.assertEqual(sheet.width, 2 * 390 + 16 + 2 * 16)

    def test_scales_tiles_to_390_wide(self):
        self.add_images(1, size=(100, 300))

        contact_sheet.build_sheet(self.in_dir, self.out_png)

        with Image.open(self.out_png) as sheet:
            # One tile: 390 wide, 1170 tall (scaled), plus label band and margins.
            self.assertGreaterEqual(sheet.height, 1170 + 16 * 2)

    def test_ignores_non_png_files(self):
        self.add_images(1)
        with open(os.path.join(self.in_dir, "notes.txt"), "w", encoding="utf-8") as f:
            f.write("not an image")

        columns, rows = contact_sheet.build_sheet(self.in_dir, self.out_png)

        self.assertEqual((columns, rows), (1, 1))

    def test_fails_on_empty_directory(self):
        with self.assertRaises(contact_sheet.ContactSheetError):
            contact_sheet.build_sheet(self.in_dir, self.out_png)


if __name__ == "__main__":
    unittest.main()
