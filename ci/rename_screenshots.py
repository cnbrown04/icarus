#!/usr/bin/env python3
"""Copy xcresulttool attachment exports to NN-<screen>-<device>-<appearance>.png names.

Usage: rename_screenshots.py <manifest.json> <out_dir> <device_slug> <appearance>

The manifest is the list written by `xcrun xcresulttool export attachments`. Each attachment
maps exportedFileName (a file next to the manifest) to suggestedHumanReadableName, which
looks like "07-today_0_<UUID>.png". Only attachments named NN-<screen>.png are kept.
"""

import json
import os
import re
import shutil
import sys

APPEARANCES = ("light", "dark")
DEVICE_SLUG = re.compile(r"^[a-z0-9]+$")
# xcresulttool appends "_<index>_<UUID>" before the extension.
UUID_SUFFIX = re.compile(
    r"_\d+_[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}(?=\.[A-Za-z0-9]+$)"
)
SCREENSHOT_NAME = re.compile(r"^(\d{2})-(.+)\.png$")


class ScreenshotError(Exception):
    pass


def strip_suffix(name):
    return UUID_SUFFIX.sub("", name)


def iter_attachments(entries):
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        for attachment in entry.get("attachments") or []:
            if isinstance(attachment, dict):
                yield attachment
        yield from iter_attachments(entry.get("subtests") or [])


def collect(manifest_path, device_slug, appearance):
    """Return {output_name: source_path}. A later attachment with the same name wins."""
    source_dir = os.path.dirname(os.path.abspath(manifest_path))
    with open(manifest_path, encoding="utf-8") as f:
        entries = json.load(f)
    if not isinstance(entries, list):
        raise ScreenshotError("manifest must be a JSON list of test entries")

    found = {}
    for attachment in iter_attachments(entries):
        base = strip_suffix(attachment.get("suggestedHumanReadableName") or "")
        match = SCREENSHOT_NAME.match(base)
        if not match:
            continue
        exported = attachment.get("exportedFileName")
        if not exported:
            raise ScreenshotError(f"attachment {base} has no exportedFileName")
        output = f"{match.group(1)}-{match.group(2)}-{device_slug}-{appearance}.png"
        if output in found:
            print(f"warning: {output} exported twice, keeping the later attachment", file=sys.stderr)
        found[output] = os.path.join(source_dir, exported)

    if not found:
        raise ScreenshotError("no screenshots found in manifest")
    for path in found.values():
        if not os.path.isfile(path):
            raise ScreenshotError(f"exported file is missing: {path}")
    return found


def rename(manifest_path, out_dir, device_slug, appearance):
    """Copy screenshots into out_dir under their final names. Returns the sorted names."""
    if not DEVICE_SLUG.match(device_slug):
        raise ScreenshotError(f"invalid device slug: {device_slug!r}")
    if appearance not in APPEARANCES:
        raise ScreenshotError(f"appearance must be one of {APPEARANCES}, got {appearance!r}")

    found = collect(manifest_path, device_slug, appearance)
    os.makedirs(out_dir, exist_ok=True)
    for name in sorted(found):
        shutil.copyfile(found[name], os.path.join(out_dir, name))
    return sorted(found)


def main(argv):
    if len(argv) != 5:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    try:
        names = rename(argv[1], argv[2], argv[3], argv[4])
    except (ScreenshotError, json.JSONDecodeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print(f"wrote {len(names)} screenshots to {argv[2]}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
