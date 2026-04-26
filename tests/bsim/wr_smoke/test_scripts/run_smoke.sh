#!/usr/bin/env bash
# Copyright 2026 wearable-recorder contributors
# SPDX-License-Identifier: Apache-2.0
#
# wr_smoke run script: launches phy_2G4_v1 + a single peripheral that
# advertises the omi audio service for ~3 seconds, then exits cleanly.
# Both processes return 0 on success.

set -eu
bash_source_dir="$(realpath "$(dirname "${BASH_SOURCE[0]}")")"
source "${bash_source_dir}/_env.sh"

simulation_id="wr_smoke"
verbosity_level=2

cd "${BSIM_OUT_PATH}/bin"

# Background the device + the phy daemon, capture pids so we can wait
# on each individually and return non-zero if either crashes. We run
# the simulation for 5 s of simulated time (sim_length is in usec) —
# main.c sleeps for 3 s before bt_le_adv_stop + return 0.
"${test_exe}" -v=${verbosity_level} -s=${simulation_id} -d=0 \
              -RealEncryption=0 &
device_pid=$!

./bs_2G4_phy_v1 -v=${verbosity_level} -s=${simulation_id} \
                -D=1 -sim_length=5e6 &
phy_pid=$!

device_rc=0
phy_rc=0
wait "${device_pid}" || device_rc=$?
wait "${phy_pid}"    || phy_rc=$?

echo "device exit=${device_rc} phy exit=${phy_rc}"
if [ "${device_rc}" -ne 0 ] || [ "${phy_rc}" -ne 0 ]; then
  echo "::error::wr_smoke run failed (device=${device_rc}, phy=${phy_rc})"
  exit 1
fi
echo "wr_smoke run: PASSED"
