#!/usr/bin/env bash
# Copyright 2026 wearable-recorder contributors
# SPDX-License-Identifier: Apache-2.0

set -eu
bash_source_dir="$(realpath "$(dirname "${BASH_SOURCE[0]}")")"
test_dir="$(realpath "$bash_source_dir/..")"

source "${bash_source_dir}/_env.sh"

# Build under the test source dir so prj.conf is picked up automatically.
cd "$test_dir"
west build -b "${BOARD}" -d build_smoke -p always

# zephyr.exe is the native_simulator runner; .elf fallback for older NSI revs.
if [ -f build_smoke/zephyr/zephyr.exe ]; then
  cp build_smoke/zephyr/zephyr.exe "${test_exe}"
elif [ -f build_smoke/zephyr/zephyr.elf ]; then
  cp build_smoke/zephyr/zephyr.elf "${test_exe}"
else
  echo "::error::neither zephyr.exe nor zephyr.elf produced under build_smoke/zephyr/"
  exit 1
fi
echo "wr_smoke binary: ${test_exe}"
