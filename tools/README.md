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

### Decoding to WAV

`--wav` will try `pyogg` first. Because the dump is raw concatenated
Opus frames *without* OggS framing, pure `opuslib` is not enough on
its own — you'd need to know each frame's length to feed it
correctly. For now the recommended path is:

```bash
pip install pyogg
python decode-dump.py dump.bin -o rec --wav
```

If you only need to inspect frame structure (e.g., debug BLE
reliability), the JSON manifest is usually enough.

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
