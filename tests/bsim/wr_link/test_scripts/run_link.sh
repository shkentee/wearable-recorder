#!/usr/bin/env bash
# Copyright 2026 wearable-recorder contributors
# SPDX-License-Identifier: Apache-2.0
#
# wr_link run script: launches the same test binary twice (once as
# peripheral, once as central) plus a 2-device phy_2G4_v1 simulation,
# verdicts on the bs_tests Pass/Fail of each device.

set -eu
bash_source_dir="$(realpath "$(dirname "${BASH_SOURCE[0]}")")"
source "${bash_source_dir}/_env.sh"

simulation_id="wr_link"
verbosity_level=2

cd "${BSIM_OUT_PATH}/bin"

"${test_exe}" -v=${verbosity_level} -s=${simulation_id} -d=0 \
              -RealEncryption=0 -testid=peripheral &
peripheral_pid=$!

"${test_exe}" -v=${verbosity_level} -s=${simulation_id} -d=1 \
              -RealEncryption=0 -testid=central &
central_pid=$!

./bs_2G4_phy_v1 -v=${verbosity_level} -s=${simulation_id} \
                -D=2 -sim_length=15e6 &
phy_pid=$!

p_rc=0; c_rc=0; ph_rc=0
wait "${peripheral_pid}" || p_rc=$?
wait "${central_pid}"    || c_rc=$?
wait "${phy_pid}"        || ph_rc=$?

echo "peripheral=${p_rc} central=${c_rc} phy=${ph_rc}"
if [ "${p_rc}" -ne 0 ] || [ "${c_rc}" -ne 0 ] || [ "${ph_rc}" -ne 0 ]; then
  echo "::error::wr_link run failed"
  exit 1
fi
echo "wr_link run: PASSED"
