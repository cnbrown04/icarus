# CI screenshots

How to get the iOS and web screenshots that CI produces (PLAN.md §16.3 to §16.5).

## When they run

| Workflow | Runs when |
|---|---|
| `ios-screenshots.yml` | Push to `main` or `claude/**` that touches `ios/**`; a pull request gets the `screenshots` label; manual dispatch |
| `web.yml` | Every PR and push to `main` or `claude/**` that touches `web/**`. Playwright writes the web screenshots on each run |

Manual dispatch of `ios-screenshots.yml` has a `quick` input. With `quick` on, only iPhone 17 Pro in light appearance runs.

The iOS matrix is 3 devices by 2 appearances: iPhone 17 Pro, iPhone 17 Pro Max and iPhone 17e, each in light and dark. Runs use the highest installed iOS 26.x runtime on the `macos-26` image.

## Committed screenshots

The latest screenshots are committed to the repo, so they can be read on GitHub without downloading anything. The artifacts described below are the backup.

| Folder | Contents | Committed when |
|---|---|---|
| `screenshots/phase-N/ios/` | One PNG per screen (iPhone 17 Pro Max, light), `contact-sheet.png` and `index.md` | Every iOS screenshot run that finishes, on push to `main` or `claude/**` and on same-repo PRs with the label |
| `screenshots/phase-N/web/` | Playwright PNGs at 1920x1080, light, and `index.md` | Push to `main` or `claude/**` after the web tests pass. Not on PRs |

Each commit replaces the whole folder, so it holds only the latest set. `index.md` records the commit SHA and the run URL. Commit messages are `screenshots: ios <sha7> [skip ci]` and `screenshots: web <sha7> [skip ci]`, and the commits are made by `github-actions[bot]`. Forks cannot get the iOS commit, because their pull requests have no write token.

## Where to find them

1. Browse `screenshots/phase-N/ios/` or `screenshots/phase-N/web/` on the branch. Open `index.md` for the list.
2. Open the workflow run in the Actions tab for the logs and the artifacts.
3. Download the artifacts from the bottom of the run page, or with the CLI:

   ```bash
   gh run download <run-id> -n screenshots-<sha7>-all
   ```

4. On a pull request with the `screenshots` label, a comment links the run and names the aggregate artifact.

## Artifact names

| Artifact | Contents | Retention |
|---|---|---|
| `screenshots-<sha7>-<device>-<appearance>` | Per-job PNGs in `final/` and the per-job contact sheet | 14 days |
| `screenshots-<sha7>-all` | Every PNG in `screens/`, `contact-sheet-all.png` and `index.md` | 14 days |
| `xcresult-<sha7>-<device>-<appearance>` | `.xcresult` bundle, uploaded only when the job fails | 7 days |
| `xcresult-<sha7>-unit` | Unit test `.xcresult`, uploaded only when `ios.yml` fails | 7 days |
| `web-screenshots-<sha7>` | Playwright screenshots at 1440x900 and 390x844, light and dark | 14 days |

`<sha7>` is the first seven characters of the commit SHA. `<device>` is lowercase without spaces, for example `iphone17pro`. `<appearance>` is `light` or `dark`.

## File names

Each screenshot is named `NN-<screen>-<device>-<appearance>.png`, for example `07-today-iphone17pro-dark.png`. `NN` is the screen number from PLAN.md §14, so files sort in navigation order. The screen names come from the XCUITest attachment names: `01-welcome`, `07-today`, `11-trends`, `12-alarms`, `15-device` and `17-settings`.

## Reading the aggregate

`index.md` lists every screenshot with its screen, device, appearance and file. `contact-sheet-all.png` shows all of them in one grid, four tiles wide, with each file name under its tile.

## Regenerating locally

The iOS screenshots need macOS and Xcode 26.6. Outside CI, run the same steps as the `screenshots` job in `ios-screenshots.yml`. The rename and contact sheet scripts run on any machine with Python 3.13:

```bash
python3 -m pip install -r ci/requirements.txt
python3 ci/rename_screenshots.py out/raw/manifest.json out/final iphone17pro dark
python3 ci/contact_sheet.py out/final out/contact-sheet-iphone17pro-dark.png
```

`out/raw/manifest.json` comes from `xcrun xcresulttool export attachments --path <bundle>.xcresult --output-path out/raw`.

`N` comes from the head commit subject of the push (`phase-N: ...`). A push whose subject has no phase prefix does not get a committed set.
