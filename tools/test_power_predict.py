"""Pytest suite for ``tools/power-predict.py``.

The module under test has a hyphen in its filename (matches the sibling
``decode-dump.py`` style) so we load it via importlib instead of a
plain ``import``. Keeps the tool itself runnable as a script while
letting pytest exercise its internals.
"""
from __future__ import annotations

import importlib.util
import io
import json
import math
import sys
from contextlib import redirect_stdout
from pathlib import Path

import pytest

# --- module-under-test loader -------------------------------------------------

_MOD_PATH = Path(__file__).parent / "power-predict.py"


def _load_module():
    """Import ``power-predict.py`` as ``power_predict``.

    Cached on ``sys.modules`` so multiple tests don't re-exec the file
    (also makes dataclass identity checks work as expected).
    """
    name = "power_predict"
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, _MOD_PATH)
    assert spec and spec.loader, f"could not load {_MOD_PATH}"
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


pp = _load_module()


# --- helpers ------------------------------------------------------------------

def _defaults():
    """Fresh PowerInputs with the canonical defaults.

    Returned per-call so individual tests can mutate without bleeding
    state into siblings.
    """
    return pp.PowerInputs()


# --- core formula tests -------------------------------------------------------

def test_defaults_match_spec_section_14_2():
    """Defaults should land in spec section 14.2's 3.2-3.7mA window
    and beat the 20h project goal with ~230% margin.

    Hand calculation:
        record = (1.5 + 0.8 + 1.2) * 1.0 = 3.5
        sd     = 4.0 * 0.05            = 0.2
        led    = 0.01
        mcu    = 0.005 * (1 - 1.0)     = 0.0
        avg    = 3.71 mA
        hours  = 250 / 3.71 ~= 67.4 h
    """
    pred = pp.predict_power(_defaults())
    # avg current is the load-bearing claim of section 14.2.
    assert pred.avg_ma == pytest.approx(3.71, abs=0.01)
    # ~57h is the spec midpoint; we accept anything in [40, 80] to
    # leave headroom if defaults shift slightly in future tweaks.
    assert pred.hours is not None
    assert 40.0 <= pred.hours <= 80.0
    # 20h is the headline target -- defaults must beat it.
    assert pred.meets_target is True
    # Sanity: contributions sum to avg.
    total = sum(pred.contributions_ma.values())
    assert total == pytest.approx(pred.avg_ma, rel=1e-9)
    # And percentages add to 100.
    assert sum(pred.contributions_pct.values()) == pytest.approx(100.0)


def test_defaults_cli_output_is_around_67_hours():
    """End-to-end CLI smoke test on defaults via ``main([])``.

    Asserts on the JSON form so we don't tie the test to the exact
    wording of the human-readable report.
    """
    buf = io.StringIO()
    with redirect_stdout(buf):
        rc = pp.main(["--json"])
    assert rc == 0
    payload = json.loads(buf.getvalue())
    hours = payload["prediction"]["hours"]
    assert hours == pytest.approx(67.4, abs=2.0)
    assert payload["prediction"]["meets_target"] is True


def test_half_battery_halves_runtime():
    """Linear scaling sanity: capacity is the only thing that changes."""
    base = pp.predict_power(_defaults())
    inp = _defaults()
    inp.battery_mah = 100.0
    half = pp.predict_power(inp)
    assert half.hours == pytest.approx(base.hours / 2.0, rel=1e-9)


def test_record_duty_half_doubles_runtime():
    """Cutting the record pipeline duty in half should roughly double
    runtime, *but* SD writes and LED keep going (they are gated by
    their own duty knobs), so the speedup is less than exactly 2x.

    With defaults:
        avg(d=1.0) = 3.71
        avg(d=0.5) = (3.5 * 0.5) + 0.2 + 0.01 + 0.005 * 0.5
                   = 1.75 + 0.2 + 0.01 + 0.0025
                   = 1.9625
        ratio      = 3.71 / 1.9625 ~= 1.89
    """
    base = pp.predict_power(_defaults())
    inp = _defaults()
    inp.record_duty = 0.5
    half = pp.predict_power(inp)
    ratio = half.hours / base.hours
    # Anchor on the analytical 1.89 with a comfortable tolerance so
    # rounding tweaks in the formula don't cause a flap.
    assert ratio == pytest.approx(1.89, abs=0.05)
    # Direction sanity: must definitely be *longer*, not shorter.
    assert half.hours > base.hours


def test_sd_write_duty_one_crashes_runtime():
    """Setting SD write duty to 100% massively increases the load and
    therefore tanks runtime. Confirms ``sd_write_duty`` is wired in.

    avg(sd_duty=1.0) = 3.5 + 4.0 + 0.01 = 7.51 mA
    hours            = 250 / 7.51       ~= 33.3 h
    """
    inp = _defaults()
    inp.sd_write_duty = 1.0
    pred = pp.predict_power(inp)
    assert pred.avg_ma == pytest.approx(7.51, abs=0.01)
    assert pred.hours == pytest.approx(33.3, abs=1.0)
    # Still beats the 20h target (barely) so meets_target stays True;
    # the load-side change is the real assertion.
    assert pred.hours < pp.predict_power(_defaults()).hours


def test_all_zero_does_not_divide_by_zero():
    """Zero-current corner case: every knob is 0 -> infinite battery
    life, no exception. This is the property we *really* care about
    -- divide-by-zero would crash the script in CI.
    """
    inp = pp.PowerInputs(
        battery_mah=0.0,
        pdm_active_ma=0.0,
        codec_active_ma=0.0,
        ble_tx_avg_ma=0.0,
        sd_active_ma=0.0,
        sd_write_duty=0.0,
        mcu_idle_ma=0.0,
        record_duty=0.0,
        led_avg_ma=0.0,
        charging_ma=0.0,
    )
    pred = pp.predict_power(inp)
    assert pred.avg_ma == 0.0
    # No drain -> hours/days are None (sentinel for "infinite").
    assert pred.hours is None
    assert pred.days is None
    # Trivially "meets" any finite target since nothing is consuming.
    assert pred.meets_target is True
    # Percentages must still be well-formed (no NaN) even when avg=0.
    for pct in pred.contributions_pct.values():
        assert not math.isnan(pct)
        assert pct == 0.0


# --- additional behaviour tests ----------------------------------------------

def test_charging_offsets_load():
    """If USB supplies more current than the load consumes, runtime
    should be reported as 'infinite' (None) rather than negative.
    """
    inp = _defaults()
    inp.charging_ma = 100.0  # well above the ~3.71mA load
    pred = pp.predict_power(inp)
    assert pred.net_avg_ma < 0
    assert pred.hours is None
    assert pred.meets_target is True


def test_main_human_output_contains_verdict():
    """Smoke test the human-readable report. We only assert on a few
    stable substrings so wording tweaks don't break the test.
    """
    buf = io.StringIO()
    with redirect_stdout(buf):
        rc = pp.main([])
    assert rc == 0
    out = buf.getvalue()
    assert "Average load current" in out
    assert "Verdict" in out
    assert "PASS" in out  # defaults must pass the 20h target


def test_fail_under_target_exits_nonzero_when_missed():
    """``--fail-under-target`` is the CI-guard mode: if the model
    predicts under 20h, the process exits 1 so a workflow can fail.
    """
    # Set a target so high that defaults can never meet it.
    buf = io.StringIO()
    with redirect_stdout(buf):
        rc = pp.main(["--fail-under-target", "--target-hours", "10000"])
    assert rc == 1


def test_fail_under_target_exits_zero_when_met():
    """Without the flag, even a missed target should still exit 0
    (interactive-friendly default)."""
    buf = io.StringIO()
    with redirect_stdout(buf):
        rc = pp.main(["--target-hours", "10000"])
    assert rc == 0
