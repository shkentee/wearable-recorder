# tools/

PC-side helpers for working with raw artifacts produced by the
wearable-recorder firmware and mobile app. Lives outside `app/`,
`app_mobile/`, and `tests/` so it can iterate independently and
ship with its own minimal CI.

## decode-dump.py

Decodes a binary dump file produced by the mobile app's
[`WrPacketSink`](../app_mobile/lib/services/wr_packet_sink.dart) into
a structured manifest plus the raw Opus payload stream.

### Background

The mobile app appends every BLE notify it receives from the device
to a single binary file, **verbatim**. There is no length prefix
between notifies. Each notify starts with the 3-byte omi packet
header:

| byte | field         | type   |
|------|---------------|--------|
| 0    | `packet_id` low  | uint8 |
| 1    | `packet_id` high | uint8 (LE pair with byte 0 → uint16) |
| 2    | `frame_id`       | uint8 |
| 3+   | Opus payload     | bytes |

So a dump file is just `header | payload | header | payload | ...`
with no separator. Boundary recovery relies on the fact that
`packet_id` increments by 1 per notify and `frame_id` resets to 0
on each new packet. See `_is_expected_successor` in
`decode-dump.py` for the exact heuristic.

### Usage

```bash
python decode-dump.py path/to/dump.bin -o /tmp/recording
# -> /tmp/recording.json
# -> /tmp/recording.opus
```

Options:

| flag | effect |
|------|--------|
| `-o, --output-prefix PATH` | output prefix (default: input file's stem in cwd) |
| `--strict` | error on malformed trailer bytes (default: warn + skip) |
| `--wav` | also emit `<prefix>.wav` if `pyogg` is importable (no-op otherwise) |
| `-v, --verbose` | enable INFO-level continuity logging |

### Outputs

- `<prefix>.json` — list of objects:
  ```json
  [
    {
      "packet_id": 0,
      "frame_id": 0,
      "payload_hex": "abcd...",
      "offset_in_file": 0,
      "payload_len": 80
    },
    ...
  ]
  ```
- `<prefix>.opus` — concatenation of every packet's payload bytes
  (header bytes stripped) in arrival order. **This is raw Opus
  frames, not an Ogg-Opus container** — see "Decoding to WAV" below.

### Opus decode (`--wav`)

`--wav` decodes the per-packet Opus payloads to a 16-bit signed PCM,
mono WAV at 16 kHz (the omi firmware default). Because the parser
already knows each notify's payload boundaries from the dump file,
each packet's payload is fed to the Opus decoder as a single frame —
**no Ogg container is required** when `opuslib` is used.

Required dependency (either one is fine; `opuslib` is preferred):

```bash
pip install opuslib    # raw frame decode using packet boundaries
# or
pip install pyogg      # only works on a pre-wrapped Ogg-Opus container
```

Then:

```bash
python decode-dump.py dump.bin -o rec --wav
# -> rec.json  rec.opus  rec.wav
```

Format produced:

| field        | value                |
|--------------|----------------------|
| sample width | 16-bit signed PCM    |
| channels     | mono                 |
| sample rate  | 16000 Hz (default)   |

If your firmware build runs the PDM mic at a different sampling rate,
override it with `--rate`:

```bash
python decode-dump.py dump.bin -o rec --wav --rate 24000
```

When neither `opuslib` nor `pyogg` is importable, `--wav` warns and
exits 0 (raw `<prefix>.opus` is still produced for offline conversion).
This is what keeps the CI image deps-free.

### Continuity logging

Run with `-v` to surface anomalies that often indicate BLE issues:

- `packet_id jump` — non-sequential packet ids (likely a reconnect
  or a dropped notify on the air).
- `frame_id jump within packet_id` — multi-frame packets where one
  sub-frame is missing.

## test_decode_dump.py

Pytest suite for the decoder. Run with:

```bash
cd tools
pip install pytest
pytest -v
```

The same test runs on every PR that touches `tools/**` via
`.github/workflows/tools.yml`.

## power-predict.py

Predicts average current draw and battery life from per-subsystem mA /
duty assumptions. Pre-Phase 5 (no PPK2 hardware yet) this is the
reference for whether the spec section 14.2 estimate of
**3.2-3.7mA / 200mAh -> 54-63h** still holds as we iterate on firmware.

Pure stdlib (`argparse`, `json`, `dataclasses`, `math`) — no third-party
deps, runs in the same minimal CI image as `decode-dump.py`.

### Model

```
avg = (pdm_active_ma + codec_active_ma + ble_tx_avg_ma) * record_duty
    + sd_active_ma * sd_write_duty
    + led_avg_ma
    + mcu_idle_ma * (1 - record_duty)
hours = battery_mah / max(avg - charging_ma, 0)
```

The PDM mic, Opus encoder, and BLE radio share `record_duty` because
the firmware gates them as one pipeline (when recording is paused, all
three sleep together). SD writes have their own `sd_write_duty` knob.

### Usage

```bash
# Spec defaults (200mAh, always-on record, 5% SD duty)
python tools/power-predict.py

# What-if: 150mAh cell, 80% record duty, +0.5mA BLE overhead
python tools/power-predict.py \
    --battery-mah 150 --record-duty 0.8 --ble-tx-avg-ma 1.7

# Machine-readable output for downstream tooling
python tools/power-predict.py --json

# CI guard mode: exit 1 if predicted runtime is below the target
python tools/power-predict.py --fail-under-target --target-hours 20
```

### Defaults

| knob | default | source |
|------|---------|--------|
| `battery-mah`     | 200    | spec D5 (採用) |
| `pdm-active-ma`   | 1.5    | DK1 baseline split |
| `codec-active-ma` | 0.8    | DK1 baseline split |
| `ble-tx-avg-ma`   | 1.2    | DK1 baseline split |
| `sd-active-ma`    | 4.0    | SanDisk Ultra burst |
| `sd-write-duty`   | 0.05   | Plan B 5% bursts |
| `mcu-idle-ma`     | 0.005  | nRF52 sleep mode |
| `record-duty`     | 1.0    | always recording |
| `led-avg-ma`      | 0.01   | heartbeat 1% duty |
| `charging-ma`     | 0.0    | unplugged |

With those defaults the script reports **3.71 mA average / ~53.9 h /
2.25 days**, well above the 20h project target — the same ballpark as
spec section 14.2's hand calculation.

### Output

Two formats:

- Human-readable (default): aligned table with per-subsystem mA, the
  percentage each contributes, predicted hours/days, and a `PASS`/`FAIL`
  verdict against `--target-hours` (default `20`, from spec 14.3).
- JSON (`--json`): nested object with `inputs` and `prediction`. Use
  this from other scripts so the human format can evolve freely.

### Phase 5 plan

Once the PPK2 (or Joulescope) measurements arrive, the per-subsystem
`*_ma` defaults get re-tuned in this file and the spec section 14.2
table updated to match. The pytest suite (`test_power_predict.py`)
asserts on the *shape* of the model (linearity, duty scaling, no
divide-by-zero) so retuning numbers won't break CI as long as the
algebra is intact.

## test_power_predict.py

Pytest suite for the predictor. Same `pytest -v` invocation picks it
up. Covers default-case agreement with spec 14.2, linear scaling vs
battery capacity / record duty, the SD duty stress case, the
all-zero divide-by-zero guard, and the `--fail-under-target` CI
exit-code contract.
