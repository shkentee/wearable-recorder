cmake_minimum_required(VERSION 3.20.0)

# Pin pure-Zephyr LL controller before find_package; this is what lets
# the test build under NCS without nrfxlib's SoftDevice Controller
# (which CMake-rejects the nrf52_bsim SoC + float ABI combo).
set(EXTRA_CONF_FILE "")

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(wr_bsim_smoke)

target_sources(app PRIVATE src/main.c)
