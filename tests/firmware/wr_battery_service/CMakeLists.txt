cmake_minimum_required(VERSION 3.20.0)
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(wr_battery_service)

set(WR_APP_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/../../../app)

target_sources(app PRIVATE
    src/main.c
    ${WR_APP_ROOT}/src/wr_battery.c
)
target_include_directories(app PRIVATE
    ${WR_APP_ROOT}/include
)
