#!/usr/bin/env python3
"""Combine per-job screenshot artifacts into one folder.

Usage: aggregate.py <artifacts_dir> <out_dir>

Walks artifacts_dir for NN-<screen>-<device>-<appearance>.png files and writes:
  out_dir/screens/           every screenshot
  out_dir/contact-sheet-all.png
  out_dir/index.md           table of screen, device, appearance and file
"""

import os
import re
import shutil
import sys

from contact_sheet import build_sheet

SCREENSHOT_NAME = re.compile(r"^(\d{2})-(.+)-([a-z0-9]+)-(light|dark)\.png$")


class AggregateError(Exception):
    pass


def find_screenshots(artifacts_dir):
    """Return a sorted list of (file_name, source_path, (number, screen, device, appearance))."""
    found = {}
    for root, _dirs, files in os.walk(artifacts_dir):
        for file_name in files:
            if file_name.startswith("contact-") or not file_name.endswith(".png"):
                continue
            match = SCREENSHOT_NAME.match(file_name)
            if not match:
                print(f"warning: skipping unexpected file name {file_name}", file=sys.stderr)
                continue
            if file_name in found:
                raise AggregateError(f"screenshot {file_name} appears in more than one artifact")
            found[file_name] = (os.path.join(root, file_name), match.groups())
    if not found:
        raise AggregateError(f"no screenshots found under {artifacts_dir}")
    return [(name, *found[name]) for name in sorted(found)]


def write_index(out_dir, entries):
    lines = [
        "# iOS screenshots",
        "",
        "Contact sheet: [contact-sheet-all.png](contact-sheet-all.png)",
        "",
        "| Screen | Device | Appearance | File |",
        "| --- | --- | --- | --- |",
    ]
    for file_name, _source, (number, screen, device, appearance) in entries:
        lines.append(
            f"| {number} {screen} | {device} | {appearance} | [{file_name}](screens/{file_name}) |"
        )
    with open(os.path.join(out_dir, "index.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


def aggregate(artifacts_dir, out_dir):
    entries = find_screenshots(artifacts_dir)
    screens_dir = os.path.join(out_dir, "screens")
    os.makedirs(screens_dir, exist_ok=True)
    for file_name, source, _parts in entries:
        shutil.copyfile(source, os.path.join(screens_dir, file_name))
    build_sheet(screens_dir, os.path.join(out_dir, "contact-sheet-all.png"))
    write_index(out_dir, entries)
    return len(entries)


def main(argv):
    if len(argv) != 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    try:
        count = aggregate(argv[1], argv[2])
    except AggregateError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print(f"combined {count} screenshots into {argv[2]}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
