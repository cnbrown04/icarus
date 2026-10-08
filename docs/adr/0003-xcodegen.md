# 0003. Generate the Xcode project with XcodeGen

Status: Proposed (PLAN.md draft, 2026-10-07)

## Context

The project has no Mac and no one can open Xcode by hand. The Xcode project file must still be produced and built on GitHub-hosted macOS runners (PLAN.md §16). A `.xcodeproj` is a binary-heavy, merge-hostile file, and a reviewable text spec is easier to check in pull requests (PLAN.md §4.3).

## Decision

Use XcodeGen. `ios/project.yml` is the reviewed spec. The `.xcodeproj` is generated in CI with `xcodegen generate` and is not committed (PLAN.md §4.2, §16.3). Tuist is the fallback if XcodeGen falls short (PLAN.md §4.3).

## Consequences

- Target, scheme and test plan changes are reviewed as YAML diffs.
- Every CI job that builds iOS runs `xcodegen generate` first. The CI install is currently an unpinned `brew install xcodegen`. Pinning the version is open (PLAN.md §16.3).
- Developers who do have a Mac need XcodeGen installed locally to open the project.
- CI runs the `Unit` and `Screenshots` test plans by name (PLAN.md §16.3, §17.1), so `project.yml` must define both.
