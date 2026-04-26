#!/usr/bin/env bash
# Copyright 2026 wearable-recorder contributors
# SPDX-License-Identifier: Apache-2.0

set -eu
bash_source_dir="$(realpath "$(dirname "${BASH_SOURCE[0]}")")"
test_dir="$(realpath "$bash_source_dir/..")"

source "${bash_source_dir}/_env.sh"

cd "$test_dir"
west build -b "${BOARD}" -d build_link -p always

if [ -f build_link/zephyr/zephyr.exe ]; then
  cp build_link/zephyr/zephyr.exe "${test_exe}"
elif [ -f build_link/zephyr/zephyr.elf ]; then
  cp build_link/zephyr/zephyr.elf "${test_exe}"
else
  echo "::error::neither zephyr.exe nor zephyr.elf produced under build_link/zephyr/"
  exit 1
fi
echo "wr_link binary: ${test_exe}"
