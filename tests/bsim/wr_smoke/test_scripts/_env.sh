#!/usr/bin/env bash
# Copyright 2026 wearable-recorder contributors
# SPDX-License-Identifier: Apache-2.0

set -eu
bash_source_dir="$(realpath "$(dirname "${BASH_SOURCE[0]}")")"

test_name="$(basename "$(realpath "$bash_source_dir/..")")"
bsim_bin="${BSIM_OUT_PATH}/bin"
BOARD="${BOARD:-nrf52_bsim}"

# bsim's compile.sh sanitizes the source path under tests/bsim/ into the
# binary name. For tests/bsim/wr_smoke with prj.conf, the convention is:
#   bs_<board>_tests_bsim_<sanitized_path>_prj_conf
test_exe="${bsim_bin}/bs_${BOARD}_tests_bsim_wr_smoke_prj_conf"
