#!/usr/bin/env python3
"""Copy target IDs from the generated Icarus.xcodeproj into the .xctestplan files.

XcodeGen creates the project in CI, so the target IDs in the test plans cannot be
known ahead of time. Run this after `xcodegen generate`, from ios/.
"""
import json
import pathlib
import re
import sys

root = pathlib.Path(__file__).resolve().parent.parent
pbxproj = (root / "Icarus.xcodeproj" / "project.pbxproj").read_text()

target_ids = {
    name: object_id
    for object_id, name in re.findall(
        r"^\s*([0-9A-F]{24}) /\* (\S+) \*/ = \{\s*isa = PBXNativeTarget;", pbxproj, re.M
    )
}
if not target_ids:
    sys.exit("no PBXNativeTarget entries found in project.pbxproj")

for plan_path in sorted(root.glob("*.xctestplan")):
    plan = json.loads(plan_path.read_text())
    for entry in plan.get("testTargets", []):
        target = entry["target"]
        if target["name"] not in target_ids:
            sys.exit(f"{plan_path.name}: target {target['name']} not in project")
        target["identifier"] = target_ids[target["name"]]
    plan_path.write_text(json.dumps(plan, indent=2) + "\n")
    print(f"{plan_path.name}: synced {[t['target']['name'] for t in plan['testTargets']]}")
