# Golden fixtures

Shared test vectors for the Swift packages (`ios/Packages/BandProtocol`, `ios/Packages/Metrics`)
and the Rust core (`icarus-core`). Any formula or envelope change must update these files and both
implementations together. Both files are plain JSON and are read by path relative to the repo root.

## frames.json

WHOOP 4.0 frames, one object per frame:

```json
[{"name": "hr_broadcast_off_seq07", "hex": "aa0800a823070e00c7e40f08", "source": "S8 bWanShiTong README"}]
```

- `hex`: lowercase, no separators, the complete frame on the wire, including the sync byte and both checksums.
- Envelope (PLAN.md 5.3.3): `[0xAA][len u16 LE][crc8 over the 2 len bytes, poly 0x07, init 0]`
  `[type][seq][cmd][payload][crc32 LE]`. `len` = 3 + payload length + 4, so the frame is `len + 4` bytes.
  `crc32` is zlib CRC-32 over `[type][seq][cmd][payload]`.
- Every frame here was recomputed against both checksums before it was added. The 80 frames are:
  30 COMMAND (0x23), 17 realtime data (0x28), 21 event (0x30), 4 metadata (0x31), 8 historical (0x2F).
- The 8 historical frames are 96 bytes. The source publishes each as a 31-byte head row and a
  65-byte tail row. They are joined here by checksum (each joined frame passes CRC-32).
- Round-trip rules: a COMMAND frame whose `cmd` is in `SafeCommand` must re-encode byte for byte.
  Other frames are decode-only. Those are opcodes 25 and 29 (both denied, PLAN.md 5.3.5), plus 69, 115 and 116,
  which are not in the whitelist.
- Denied opcodes appear only as decode-only fixtures (`erase_device_*`, `reboot_device_*`). Never send them.

## metrics_v1.json

Inputs and expected outputs for `Metrics` (PLAN.md 8.2 to 8.4). Expected values come from the formulas
in PLAN.md, not from the Swift code, and the first cases were checked by hand.

Top-level keys:

| Key | Meaning |
|---|---|
| `format` | Always `"icarus-golden-metrics"`. |
| `format_version` | `1`. Bump when the layout changes. |
| `algo_version` | `{hr, hrv, stress, kcal}`. Must equal the code's `AlgoVersion` (PLAN.md 8.5). |
| `tolerance` | Absolute tolerance for floats (`0.000001`). Integers and booleans compare exactly. |
| `rr_cases` | R-R cleaning and HRV. |
| `kcal_cases` | Energy per minute for one profile. |

`rr_cases[]`:

- `name`: string.
- `rr_ms`: input R-R intervals in milliseconds.
- `expected.rr_accepted`: one boolean per input (PLAN.md 8.2 steps 1-2).
- `expected.rmssd`, `expected.sdnn`, `expected.ln_rmssd`: computed over the accepted intervals only.
  Each is a number, or `null` when fewer than 2 accepted intervals remain (`ln_rmssd` is also `null` when RMSSD is 0).

`kcal_cases[]`:

- `name`: string.
- `profile`: `{sex: "male" | "female", age_years, height_cm, weight_kg}`. `sex` is the formula sex.
- `resting_hr`, `max_hr`: bpm.
- `hr_bpm`: one value per minute. `null` means no heart-rate sample.
- `expected.hr_flex`: `max(90, RHR + 0.30 * (HRmax - RHR))`.
- `expected.bmr_kcal_min`: Mifflin-St Jeor per minute (`/ 1440`).
- `expected.kcal_min[i]`, `expected.active_kcal_min[i]`, `expected.estimated[i]`: per-minute result for `hr_bpm[i]`.
  `estimated` is `true` only when the HR is `null`.

Units: R-R in ms, energy in kcal (Keytel kJ is divided by 4.184), HR in bpm, weight in kg, height in cm.
