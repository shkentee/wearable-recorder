"""Unit tests for decode-dump.py.

The decoder script has a hyphen in its filename so we load it via
importlib rather than a normal `import`. This keeps the module name
consistent with the CLI invocation while letting pytest collect tests
in the usual way.
"""
from __future__ import annotations

import importlib.util
import json
import logging
import struct
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "decode_dump", HERE / "decode-dump.py"
)
assert SPEC is not None and SPEC.loader is not None
decode_dump = importlib.util.module_from_spec(SPEC)
# Register in sys.modules *before* exec so @dataclass can resolve the
# module's own globals during class creation.
sys.modules["decode_dump"] = decode_dump
SPEC.loader.exec_module(decode_dump)


def make_packet(packet_id: int, frame_id: int, payload: bytes) -> bytes:
    """Helper: build a single notify (3-byte header + payload)."""
    return struct.pack("<HB", packet_id, frame_id) + payload


def test_parse_three_packets_in_order(tmp_path: Path) -> None:
    """Three sequential packets should round-trip cleanly."""
    blob = (
        make_packet(0, 0, b"AB")
        + make_packet(1, 0, b"CD")
        + make_packet(2, 0, b"EF")
    )
    packets = decode_dump.parse_dump(blob)

    assert len(packets) == 3
    assert [p.packet_id for p in packets] == [0, 1, 2]
    assert [p.frame_id for p in packets] == [0, 0, 0]
    assert [bytes.fromhex(p.payload_hex) for p in packets] == [
        b"AB",
        b"CD",
        b"EF",
    ]
    # Offsets should mark the start of each header.
    assert [p.offset_in_file for p in packets] == [0, 5, 10]


def test_write_outputs_creates_json_and_opus(tmp_path: Path) -> None:
    """The JSON manifest and concatenated Opus stream should match
    what we fed in."""
    blob = (
        make_packet(10, 0, b"\x01\x02\x03")
        + make_packet(11, 0, b"\x04\x05")
    )
    packets = decode_dump.parse_dump(blob)
    prefix = tmp_path / "rec"
    json_path, opus_path = decode_dump.write_outputs(packets, blob, prefix)

    assert json_path.exists()
    assert opus_path.exists()

    manifest = json.loads(json_path.read_text(encoding="utf-8"))
    assert len(manifest) == 2
    assert manifest[0]["packet_id"] == 10
    assert manifest[1]["packet_id"] == 11

    # Opus stream is the payloads concatenated in arrival order.
    assert opus_path.read_bytes() == b"\x01\x02\x03\x04\x05"


def test_short_trailer_warns_by_default(
    tmp_path: Path,
    caplog: pytest.LogCaptureFixture,
) -> None:
    """A 1-byte trailer shouldn't crash; it should just warn."""
    # Two valid packets followed by 1 dangling byte that can't form
    # a header. The 1-byte trailer attaches to the last packet's
    # payload because the parser walks until EOF, so we instead use
    # a buffer where the dangling bytes are *before* any complete
    # header — i.e. a single-byte file.
    blob = b"\x42"
    with caplog.at_level(logging.WARNING):
        packets = decode_dump.parse_dump(blob)
    assert packets == []
    assert any(
        "too short" in rec.message for rec in caplog.records
    ), f"expected warning, got: {[r.message for r in caplog.records]}"


def test_short_trailer_strict_raises() -> None:
    """In strict mode, a sub-header trailer should raise."""
    blob = b"\x42"
    with pytest.raises(ValueError):
        decode_dump.parse_dump(blob, strict=True)


def test_packet_id_jump_logged(caplog: pytest.LogCaptureFixture) -> None:
    """A non-monotonic packet_id sequence should produce an INFO log."""
    blob = (
        make_packet(0, 0, b"AA")
        + make_packet(5, 0, b"BB")  # jump from 0 -> 5 (expected 1)
        + make_packet(6, 0, b"CC")
    )
    packets = decode_dump.parse_dump(blob)
    assert [p.packet_id for p in packets] == [0, 5, 6]

    with caplog.at_level(logging.INFO, logger="decode-dump"):
        decode_dump.log_continuity(packets)

    jump_logs = [r for r in caplog.records if "packet_id jump" in r.message]
    assert len(jump_logs) == 1
    assert "0 -> 5" in jump_logs[0].message


def test_empty_file_returns_empty_list() -> None:
    """An empty dump should produce no packets and no errors."""
    assert decode_dump.parse_dump(b"") == []


def test_multi_frame_within_packet_id() -> None:
    """packet_id stays the same while frame_id advances — both
    frames should be recovered as separate packets."""
    blob = (
        make_packet(7, 0, b"XY")
        + make_packet(7, 1, b"ZW")
        + make_packet(8, 0, b"PQ")
    )
    packets = decode_dump.parse_dump(blob)
    assert [(p.packet_id, p.frame_id) for p in packets] == [
        (7, 0),
        (7, 1),
        (8, 0),
    ]
    assert [bytes.fromhex(p.payload_hex) for p in packets] == [
        b"XY",
        b"ZW",
        b"PQ",
    ]
