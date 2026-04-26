#!/usr/bin/env python3
"""Decode a wearable-recorder mobile-side BLE notify dump file.

The mobile app (`app_mobile/lib/services/wr_packet_sink.dart`) appends
raw BLE notify packets verbatim to a single binary file. Each notify
starts with the 3-byte omi packet header:

    byte 0: packet_id_lo
    byte 1: packet_id_hi   (uint16 little-endian)
    byte 2: frame_id       (uint8)
    byte 3+: Opus frame bytes

There is **no length prefix and no delimiter** between packets — packets
are concatenated as-is. This decoder recovers packet boundaries by
walking the file forward and treating every byte between two
consecutive headers as the payload of the earlier packet.

Outputs:
    <prefix>.json   list of {packet_id, frame_id, payload_hex,
                    offset_in_file, payload_len}
    <prefix>.opus   raw Opus payload bytes concatenated
                    (header bytes stripped, frames in arrival order)

Optional:
    --wav           also decode <prefix>.opus -> <prefix>.wav using
                    opuslib (preferred — works on raw concatenated
                    frames) or pyogg (Ogg-Opus container fallback).
                    Skipped with a warning when neither is importable
                    so CI runs that don't install Opus deps still
                    succeed (raw .opus is always written).
    --rate HZ       PCM sample rate fed to the Opus decoder
                    (default 16000Hz, omi firmware default).

The decoder is pure-stdlib; only the `--wav` path needs an external
package and the user is expected to `pip install opuslib` (or
`pyogg`) themselves.
"""
from __future__ import annotations

import argparse
import json
import logging
import struct
import sys
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Iterable, List, Optional

HEADER_SIZE = 3

logger = logging.getLogger("decode-dump")


@dataclass
class Packet:
    """One decoded notify packet from the dump file."""

    packet_id: int
    frame_id: int
    payload_hex: str
    offset_in_file: int
    payload_len: int


def _parse_header(buf: bytes, offset: int) -> tuple[int, int]:
    """Return (packet_id, frame_id) for the 3-byte header at ``offset``.

    Caller guarantees ``offset + HEADER_SIZE <= len(buf)``.
    """
    packet_id = struct.unpack_from("<H", buf, offset)[0]
    frame_id = buf[offset + 2]
    return packet_id, frame_id


def _is_expected_successor(
    cand_pid: int,
    cand_fid: int,
    cur_pid: int,
    cur_fid: int,
) -> bool:
    """Return True if (cand_pid, cand_fid) is a plausible immediate
    successor of (cur_pid, cur_fid).

    The omi firmware increments ``packet_id`` by 1 per BLE notify and
    resets ``frame_id`` to 0 on each new ``packet_id``. Within the
    same ``packet_id`` (multi-frame packets), ``frame_id`` increments
    by 1. A uint16 wraparound from 0xFFFF back to 0 is also accepted.

    Restricting to *exact* successors (rather than any monotonically
    larger value) makes the boundary scan robust against false
    positives where a payload byte pair happens to look like a valid
    header.
    """
    expected_next_pid = (cur_pid + 1) & 0xFFFF
    if cand_pid == expected_next_pid and cand_fid == 0:
        return True
    if cand_pid == cur_pid and cand_fid == cur_fid + 1:
        return True
    return False


def parse_dump(data: bytes, *, strict: bool = False) -> List[Packet]:
    """Walk ``data`` and return one :class:`Packet` per notify.

    The dump is a concatenation of variable-length notifies with no
    length prefix or delimiter. We recover boundaries by scanning
    forward from each header for the next offset whose decoded header
    is the *exact* successor of the current packet (see
    :func:`_is_expected_successor`). The remainder of the file after
    the last detected boundary is the last packet's payload.

    Args:
        data: full contents of the dump file.
        strict: if True, malformed trailing bytes (< 3 bytes left
            over after the last detected header) raise
            :class:`ValueError`. Otherwise they produce a warning.

    Returns:
        list of :class:`Packet` in arrival order.
    """
    packets: List[Packet] = []
    n = len(data)
    if n == 0:
        return packets
    if n < HEADER_SIZE:
        msg = f"dump file too short for any header: {n} byte(s)"
        if strict:
            raise ValueError(msg)
        logger.warning(msg)
        return packets

    # Generous upper bound on notify size (BLE MTU after ATT overhead
    # is typically <= 244 bytes; we allow more for safety).
    MAX_NOTIFY_SIZE = 512
    offset = 0
    while offset + HEADER_SIZE <= n:
        packet_id, frame_id = _parse_header(data, offset)
        search_start = offset + HEADER_SIZE
        search_end = min(n, offset + MAX_NOTIFY_SIZE)
        next_offset: Optional[int] = None
        # Pass 1: look for the exact expected successor — this is the
        # least ambiguous boundary signal and rules out almost all
        # false positives where payload bytes happen to look like a
        # header.
        for cand in range(search_start, search_end - HEADER_SIZE + 1):
            cand_pid, cand_fid = _parse_header(data, cand)
            if _is_expected_successor(
                cand_pid, cand_fid, packet_id, frame_id
            ):
                next_offset = cand
                break
        # Pass 2: if no exact successor exists in the window (e.g.
        # because of a BLE reconnect / dropped notify), fall back to
        # the nearest header whose packet_id is plausibly later than
        # the current one with frame_id == 0 *and* within a bounded
        # jump distance. Bounding the jump avoids splitting on
        # header-shaped payload bytes that just happen to have a
        # zero in the third byte position.
        MAX_JUMP = 1024
        if next_offset is None:
            for cand in range(search_start, search_end - HEADER_SIZE + 1):
                cand_pid, cand_fid = _parse_header(data, cand)
                if cand_fid != 0:
                    continue
                # Forward jump within MAX_JUMP packet ids.
                if packet_id < cand_pid <= packet_id + MAX_JUMP:
                    next_offset = cand
                    break
                # uint16 wraparound.
                if packet_id >= 0xFF00 and cand_pid < 0x0100:
                    next_offset = cand
                    break
        end = next_offset if next_offset is not None else n
        payload = data[offset + HEADER_SIZE : end]
        packets.append(
            Packet(
                packet_id=packet_id,
                frame_id=frame_id,
                payload_hex=payload.hex(),
                offset_in_file=offset,
                payload_len=len(payload),
            )
        )
        if next_offset is None:
            offset = n
        else:
            offset = next_offset

    if offset < n:
        leftover = n - offset
        msg = f"malformed trailer: {leftover} byte(s) after offset {offset}"
        if strict:
            raise ValueError(msg)
        logger.warning(msg)

    return packets


def log_continuity(packets: Iterable[Packet]) -> None:
    """Log packet_id / frame_id continuity anomalies.

    Notes:
        * packet_id is expected to increase by 1 per BLE notify.
        * frame_id resets to 0 on a new packet_id and increases by 1
          for sub-frames within the same packet_id (rare in current
          firmware, but the protocol supports it).
        * A jump in packet_id usually means a BLE reconnect or a
          dropped notify — useful to surface.
    """
    prev: Optional[Packet] = None
    for pkt in packets:
        if prev is not None:
            if pkt.packet_id == prev.packet_id:
                if pkt.frame_id != prev.frame_id + 1:
                    logger.info(
                        "frame_id jump within packet_id=%d: %d -> %d "
                        "(offset=%d)",
                        pkt.packet_id,
                        prev.frame_id,
                        pkt.frame_id,
                        pkt.offset_in_file,
                    )
            else:
                expected = (prev.packet_id + 1) & 0xFFFF
                if pkt.packet_id != expected:
                    logger.info(
                        "packet_id jump: %d -> %d (expected %d) at "
                        "offset=%d — possible BLE reconnect or drop",
                        prev.packet_id,
                        pkt.packet_id,
                        expected,
                        pkt.offset_in_file,
                    )
        prev = pkt


def write_outputs(
    packets: List[Packet],
    src: bytes,
    prefix: Path,
) -> tuple[Path, Path]:
    """Write the JSON manifest and concatenated Opus payload."""
    json_path = prefix.with_suffix(".json")
    opus_path = prefix.with_suffix(".opus")
    json_path.write_text(
        json.dumps([asdict(p) for p in packets], indent=2),
        encoding="utf-8",
    )
    with opus_path.open("wb") as f:
        for pkt in packets:
            start = pkt.offset_in_file + HEADER_SIZE
            end = start + pkt.payload_len
            f.write(src[start:end])
    return json_path, opus_path


DEFAULT_SAMPLE_RATE = 16000


def _write_wav_header_only(wav_path: Path, rate: int) -> None:
    """Write a 16-bit mono PCM WAV with zero audio frames.

    Used when --wav was requested but there is no payload to decode
    (or no decoder importable + no packets). Keeps downstream tooling
    that expects the file to exist happy.
    """
    import wave

    with wave.open(str(wav_path), "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)  # 16-bit PCM
        wf.setframerate(rate)
        wf.writeframes(b"")


def _decode_with_opuslib(
    packets: List[Packet],
    src: bytes,
    wav_path: Path,
    rate: int,
) -> bool:
    """Decode each packet's Opus payload as a single Opus frame and
    splat the PCM into a 16-bit mono WAV.

    omi firmware emits one Opus frame per BLE notify, so per-packet
    payload boundaries (from the manifest) are exactly what
    ``opuslib.Decoder.decode`` needs — no Ogg framing required.
    Returns True on success (decoder importable + WAV written),
    False if opuslib is not importable.
    """
    try:
        import opuslib  # type: ignore
    except ImportError:
        return False

    import wave

    # 60ms is the largest standard Opus frame; at 48kHz that's 2880
    # samples. We use that as a generous decode buffer regardless of
    # the configured rate.
    max_frame_samples = max(int(rate * 0.06), 960)
    try:
        decoder = opuslib.Decoder(rate, 1)
    except Exception as exc:  # pragma: no cover - depends on env
        logger.warning(
            "opuslib.Decoder init failed (rate=%d): %s", rate, exc
        )
        return False

    pcm_chunks: List[bytes] = []
    decoded = 0
    skipped = 0
    for pkt in packets:
        start = pkt.offset_in_file + HEADER_SIZE
        end = start + pkt.payload_len
        frame = src[start:end]
        if not frame:
            continue
        try:
            pcm = decoder.decode(bytes(frame), max_frame_samples)
        except Exception as exc:
            logger.info(
                "opuslib decode failed for packet_id=%d frame_id=%d: %s",
                pkt.packet_id,
                pkt.frame_id,
                exc,
            )
            skipped += 1
            continue
        pcm_chunks.append(pcm)
        decoded += 1

    with wave.open(str(wav_path), "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(rate)
        for chunk in pcm_chunks:
            wf.writeframes(chunk)

    logger.info(
        "wrote %s via opuslib (decoded=%d, skipped=%d, rate=%dHz)",
        wav_path,
        decoded,
        skipped,
        rate,
    )
    return True


def _decode_with_pyogg(opus_path: Path, wav_path: Path) -> bool:
    """Decode via pyogg's OpusFile (expects Ogg-Opus framing).

    The raw concatenated .opus we write is *not* OggS-framed, so this
    path mostly succeeds when the user pre-wrapped the file. Returns
    True on success.
    """
    try:
        import pyogg  # type: ignore
    except ImportError:
        return False
    try:
        opus_file = pyogg.OpusFile(str(opus_path))
    except Exception as exc:  # pragma: no cover - depends on env
        logger.info("pyogg could not open %s: %s", opus_path, exc)
        return False

    import wave

    try:
        with wave.open(str(wav_path), "wb") as wf:
            wf.setnchannels(opus_file.channels)
            wf.setsampwidth(2)  # 16-bit PCM
            wf.setframerate(opus_file.frequency)
            wf.writeframes(bytes(opus_file.as_array()))
    except Exception as exc:  # pragma: no cover - depends on env
        logger.warning("pyogg failed to write WAV %s: %s", wav_path, exc)
        return False

    logger.info("wrote %s via pyogg", wav_path)
    return True


def try_write_wav(
    packets: List[Packet],
    src: bytes,
    opus_path: Path,
    wav_path: Path,
    rate: int = DEFAULT_SAMPLE_RATE,
) -> bool:
    """Best-effort Opus -> WAV conversion.

    Tries opuslib first because we have per-frame payload boundaries
    in ``packets`` and the dump is raw frames. Falls back to pyogg
    (Ogg-Opus container). When no decoder is importable:

    * if ``packets`` is empty, write a header-only WAV and return
      True (the file exists at the expected path);
    * otherwise log a warning and return False without writing
      anything (raw .opus is still on disk for offline conversion).
    """
    if _decode_with_opuslib(packets, src, wav_path, rate):
        return True
    if _decode_with_pyogg(opus_path, wav_path):
        return True

    if not packets:
        _write_wav_header_only(wav_path, rate)
        logger.info(
            "wrote header-only %s (no packets to decode)", wav_path
        )
        return True

    logger.warning(
        "no usable Opus decoder found; install opuslib "
        "(`pip install opuslib`) or pyogg (`pip install pyogg`) "
        "to enable --wav output"
    )
    return False


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Decode a wearable-recorder mobile-side BLE notify dump "
            "into a JSON manifest and a concatenated Opus payload."
        )
    )
    parser.add_argument(
        "input",
        type=Path,
        help="path to the .bin dump produced by WrPacketSink",
    )
    parser.add_argument(
        "-o",
        "--output-prefix",
        type=Path,
        default=None,
        help="output path prefix (default: input file's stem in cwd)",
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help="treat malformed trailing bytes as a fatal error",
    )
    parser.add_argument(
        "--wav",
        action="store_true",
        help=(
            "also write <prefix>.wav (requires opuslib or pyogg; "
            "no-op with warning if neither is importable)"
        ),
    )
    parser.add_argument(
        "--rate",
        type=int,
        default=DEFAULT_SAMPLE_RATE,
        help=(
            "PCM sample rate for the Opus decoder in Hz "
            f"(default: {DEFAULT_SAMPLE_RATE})"
        ),
    )
    parser.add_argument(
        "-v",
        "--verbose",
        action="store_true",
        help="enable INFO-level logging",
    )
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=logging.INFO if args.verbose else logging.WARNING,
        format="%(levelname)s %(name)s: %(message)s",
    )

    if not args.input.exists():
        parser.error(f"input file not found: {args.input}")

    data = args.input.read_bytes()
    prefix = args.output_prefix or Path(args.input.stem)

    packets = parse_dump(data, strict=args.strict)
    log_continuity(packets)
    json_path, opus_path = write_outputs(packets, data, prefix)

    print(
        f"decoded {len(packets)} packet(s) from {args.input} "
        f"-> {json_path}, {opus_path}"
    )

    if args.wav:
        wav_path = prefix.with_suffix(".wav")
        try_write_wav(packets, data, opus_path, wav_path, rate=args.rate)

    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
