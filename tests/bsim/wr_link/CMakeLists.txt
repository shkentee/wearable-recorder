cmake_minimum_required(VERSION 3.20.0)
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(wr_bsim_link)

target_sources(app PRIVATE
    src/main.c
    src/wr_bs_utils.c
    src/peripheral.c
    src/central.c
)

# bs_tracing.h / bs_types.h live under BSIM_OUT_PATH's component dirs;
# these aren't on Zephyr's default include path, so wire them in
# explicitly. Mirrors Zephyr's own tests/bsim/bluetooth/host/* layout.
zephyr_include_directories(
  $ENV{BSIM_COMPONENTS_PATH}/libUtilv1/src/
  $ENV{BSIM_COMPONENTS_PATH}/libPhyComv1/src/
)
