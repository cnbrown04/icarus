# Fixtures

`resting_day.ndjson` is a synthetic 15-minute band session used by the iOS app under `-IcarusUITest 1 -IcarusFixture resting_day` and by BandKit tests.

- Starts 2026-10-07T14:15:00Z (unix 1791382500), 900 frames at 1 Hz.
- Each line is `{"t": <unix seconds>, "char": "2a37", "hex": "<payload>"}`, a Heart Rate Measurement payload with flags `0x16` (UINT8 HR, contact detected, R-R present). HR 58 to 66 bpm.
- Generated, not recorded. No device identifiers or serials are included.

Regenerate with `python3 ios/scripts/generate_fixture.py`. The output is byte-identical on every run (fixed seed, in-script PRNG). Commit the regenerated file if the script changes.
