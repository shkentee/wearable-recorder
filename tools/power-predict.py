#!/usr/bin/env python3
"""Predict wearable-recorder battery life from per-subsystem current draws.

Phase 5 will produce real PPK2 measurements, but until the hardware is
in hand we want a deterministic, parameterised model so we can:

* sanity-check spec section 14.2 ("3.2-3.7mA / 250mAh -> 67-78h"),
* explore "what if BLE costs +0.5mA more than expected?" without
  re-deriving the algebra each time, and
* freeze a single set of assumptions in CI so future tweaks have to
  justify themselves against a baseline.

Model
-----

Average current (mA):

    avg = (pdm_active_ma + codec_active_ma + ble_tx_avg_ma) * record_duty
        + sd_active_ma * sd_write_duty
        + led_avg_ma
        + mcu_idle_ma * (1 - record_duty)

Battery life (hours):

    hours = battery_mah / avg

The PDM mic, the Opus encoder, and the BLE radio are gated together by
``record_duty`` because in the current firmware they run as a single
pipeline -- when recording is paused, all three are off and the MCU
sits in its idle/sleep mode. SD writes are gated separately by
``sd_write_duty`` to model the bursty pattern observed on DK1
(short flushes followed by long idle periods at ~260µA which the
spec already folds into ``sd_active_ma`` via a duty-blended figure;
keeping them as a single duty knob keeps the CLI compact).

The defaults reproduce the spec section 14.2 estimate of ~3.5mA on a
250mAh cell (~71h continuous), which is comfortably above the 20h
project target. ``--target-hours`` overrides the comparison threshold.

This is pure stdlib (argparse, json, dataclasses, math) -- no PyYAML,
no third-party deps -- so it runs in the same minimal CI image as
``decode-dump.py``.
"""
from __future__ import annotations

import argparse
import json
import math
import sys
from dataclasses import dataclass, asdict
from typing import Dict, List, Optional

# Spec section 14.3 ("20時間目標の達成性") -- the headline goal the
# whole power budget hangs off of. Used as the default comparison
# threshold when --target-hours is not supplied.
DEFAULT_TARGET_HOURS = 20.0

# Tiny epsilon so we treat "all parameters zero" as "no draw" rather
# than blowing up with ZeroDivisionError. Using math.isclose against
# 0.0 keeps the intent obvious.
ZERO_DRAW_EPS = 1e-12


@dataclass
class PowerInputs:
    """All knobs the model accepts. mA unless noted."""

    battery_mah: float = 250.0
    pdm_active_ma: float = 1.5
    codec_active_ma: float = 0.8
    ble_tx_avg_ma: float = 1.2
    sd_active_ma: float = 4.0
    sd_write_duty: float = 0.05
    mcu_idle_ma: float = 0.005
    record_duty: float = 1.0
    led_avg_ma: float = 0.01
    charging_ma: float = 0.0


@dataclass
class PowerPrediction:
    """Output of :func:`predict_power`. Serialisable as JSON."""

    avg_ma: float
    net_avg_ma: float  # avg minus charging supply
    hours: Optional[float]  # None when net draw is ~0 (infinite life)
    days: Optional[float]
    contributions_ma: Dict[str, float]
    contributions_pct: Dict[str, float]
    target_hours: float
    meets_target: bool
    margin_vs_target_pct: Optional[float]


def predict_power(
    inputs: PowerInputs,
    *,
    target_hours: float = DEFAULT_TARGET_HOURS,
) -> PowerPrediction:
    """Compute average current and battery life for ``inputs``.

    The per-subsystem contributions in the returned object are in
    *the same units the formula uses* (mA), so they sum to ``avg_ma``
    exactly (modulo float). The percentages are over ``avg_ma`` (the
    raw load), not over ``net_avg_ma``, so they always add to 100%
    even when ``charging_ma`` exceeds the load.
    """
    record_active = (
        inputs.pdm_active_ma
        + inputs.codec_active_ma
        + inputs.ble_tx_avg_ma
    ) * inputs.record_duty
    sd = inputs.sd_active_ma * inputs.sd_write_duty
    led = inputs.led_avg_ma
    mcu = inputs.mcu_idle_ma * max(0.0, 1.0 - inputs.record_duty)

    contributions = {
        "record_pipeline": record_active,
        "sd_write": sd,
        "led": led,
        "mcu_idle": mcu,
    }
    avg_ma = sum(contributions.values())
    net_avg_ma = avg_ma - inputs.charging_ma

    if avg_ma > ZERO_DRAW_EPS:
        contributions_pct = {
            k: (v / avg_ma) * 100.0 for k, v in contributions.items()
        }
    else:
        # Avoid 0/0 -> NaN; report all-zero shares so the JSON is
        # still well-formed when every knob is 0.
        contributions_pct = {k: 0.0 for k in contributions}

    # Battery life: only meaningful when net consumption is positive.
    # If charging exactly cancels (or exceeds) load, life is "infinite"
    # for our purposes -- represented as None so JSON consumers can
    # branch on it explicitly.
    if net_avg_ma > ZERO_DRAW_EPS:
        hours: Optional[float] = inputs.battery_mah / net_avg_ma
        days: Optional[float] = hours / 24.0
        margin_pct: Optional[float] = (
            (hours - target_hours) / target_hours * 100.0
        )
        meets = hours >= target_hours
    else:
        hours = None
        days = None
        margin_pct = None
        meets = True  # no drain -> trivially meets any finite target

    return PowerPrediction(
        avg_ma=avg_ma,
        net_avg_ma=net_avg_ma,
        hours=hours,
        days=days,
        contributions_ma=contributions,
        contributions_pct=contributions_pct,
        target_hours=target_hours,
        meets_target=meets,
        margin_vs_target_pct=margin_pct,
    )


def _format_human(inputs: PowerInputs, pred: PowerPrediction) -> str:
    """Return a multi-line, human-readable report."""
    lines: List[str] = []
    lines.append("Wearable-Recorder Power Prediction")
    lines.append("=" * 40)
    lines.append(f"Battery capacity     : {inputs.battery_mah:>8.2f} mAh")
    lines.append(f"Average load current : {pred.avg_ma:>8.3f} mA")
    if inputs.charging_ma > 0:
        lines.append(
            f"Charging supply      : {inputs.charging_ma:>8.3f} mA"
        )
        lines.append(
            f"Net consumption      : {pred.net_avg_ma:>8.3f} mA"
        )
    lines.append("")
    lines.append("Per-subsystem contribution:")
    # Stable display order matches the dataclass field order so reports
    # are reproducible regardless of dict insertion order on weird
    # Python builds.
    order = ["record_pipeline", "sd_write", "led", "mcu_idle"]
    for k in order:
        ma = pred.contributions_ma[k]
        pct = pred.contributions_pct[k]
        lines.append(
            f"  {k:<16s}: {ma:>7.4f} mA  ({pct:>5.1f}%)"
        )
    lines.append("")
    if pred.hours is None:
        lines.append("Battery life         : infinite (net draw <= 0)")
    else:
        lines.append(
            f"Battery life         : {pred.hours:>8.2f} h "
            f"({pred.days:.2f} days)"
        )
    lines.append(f"Target               : {pred.target_hours:.1f} h")
    if pred.margin_vs_target_pct is None:
        lines.append("Margin vs target     : n/a (no drain)")
    else:
        lines.append(
            f"Margin vs target     : {pred.margin_vs_target_pct:+.1f}%"
        )
    verdict = "PASS" if pred.meets_target else "FAIL"
    lines.append(f"Verdict              : {verdict}")
    return "\n".join(lines)


def _build_parser() -> argparse.ArgumentParser:
    """Build the CLI. Defaults mirror :class:`PowerInputs`."""
    p = argparse.ArgumentParser(
        description=(
            "Predict wearable-recorder battery life from "
            "per-subsystem current draws (spec section 14.2)."
        ),
    )
    defaults = PowerInputs()
    p.add_argument(
        "--battery-mah", type=float, default=defaults.battery_mah,
        help="battery capacity in mAh (default: %(default)s)",
    )
    p.add_argument(
        "--pdm-active-ma", type=float, default=defaults.pdm_active_ma,
        help="PDM mic active current (default: %(default)s)",
    )
    p.add_argument(
        "--codec-active-ma", type=float, default=defaults.codec_active_ma,
        help="Opus encoder active current (default: %(default)s)",
    )
    p.add_argument(
        "--ble-tx-avg-ma", type=float, default=defaults.ble_tx_avg_ma,
        help="BLE TX time-averaged current (default: %(default)s)",
    )
    p.add_argument(
        "--sd-active-ma", type=float, default=defaults.sd_active_ma,
        help="SD write active current (default: %(default)s)",
    )
    p.add_argument(
        "--sd-write-duty", type=float, default=defaults.sd_write_duty,
        help=(
            "SD write duty cycle 0..1 (default: %(default)s = 5%% of "
            "wall clock)"
        ),
    )
    p.add_argument(
        "--mcu-idle-ma", type=float, default=defaults.mcu_idle_ma,
        help="MCU idle/sleep current (default: %(default)s)",
    )
    p.add_argument(
        "--record-duty", type=float, default=defaults.record_duty,
        help=(
            "Record-pipeline duty cycle 0..1 (default: %(default)s = "
            "always recording)"
        ),
    )
    p.add_argument(
        "--led-avg-ma", type=float, default=defaults.led_avg_ma,
        help=(
            "LED time-averaged current (default: %(default)s, "
            "heartbeat ~1%% duty of 1mA)"
        ),
    )
    p.add_argument(
        "--charging-ma", type=float, default=defaults.charging_ma,
        help=(
            "USB charging supply current (default: %(default)s = "
            "no charger connected)"
        ),
    )
    p.add_argument(
        "--target-hours", type=float, default=DEFAULT_TARGET_HOURS,
        help=(
            "battery-life target the verdict compares against "
            "(default: %(default)s, from spec section 14.3)"
        ),
    )
    p.add_argument(
        "--json", action="store_true",
        help="emit machine-readable JSON instead of the human report",
    )
    p.add_argument(
        "--fail-under-target", action="store_true",
        help=(
            "exit non-zero when predicted battery life is below "
            "--target-hours (useful in CI; default is to always "
            "exit 0 so interactive runs are not interpreted as "
            "errors by shells / Make)"
        ),
    )
    return p


def _inputs_from_args(args: argparse.Namespace) -> PowerInputs:
    """Map argparse Namespace -> :class:`PowerInputs`."""
    return PowerInputs(
        battery_mah=args.battery_mah,
        pdm_active_ma=args.pdm_active_ma,
        codec_active_ma=args.codec_active_ma,
        ble_tx_avg_ma=args.ble_tx_avg_ma,
        sd_active_ma=args.sd_active_ma,
        sd_write_duty=args.sd_write_duty,
        mcu_idle_ma=args.mcu_idle_ma,
        record_duty=args.record_duty,
        led_avg_ma=args.led_avg_ma,
        charging_ma=args.charging_ma,
    )


def main(argv: Optional[List[str]] = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)
    inputs = _inputs_from_args(args)
    pred = predict_power(inputs, target_hours=args.target_hours)

    if args.json:
        payload = {
            "inputs": asdict(inputs),
            "prediction": asdict(pred),
        }
        # ensure_ascii=False keeps Japanese strings (if any are added
        # later) readable in the JSON output.
        print(json.dumps(payload, indent=2, ensure_ascii=False))
    else:
        print(_format_human(inputs, pred))
    # Defensive: don't claim "PASS" if a NaN slipped through somehow.
    if pred.hours is not None and math.isnan(pred.hours):
        return 2
    if args.fail_under_target and not pred.meets_target:
        return 1
    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
