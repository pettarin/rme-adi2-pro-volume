cmake_minimum_required(VERSION 3.16)
project(rme-adi2-ctl C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

# Find ALSA
find_package(PkgConfig REQUIRED)
pkg_check_modules(ALSA REQUIRED alsa)

# Main executable
add_executable(rme-adi2-ctl rme-adi2-ctl.c)

target_include_directories(rme-adi2-ctl PRIVATE ${ALSA_INCLUDE_DIRS})
target_link_libraries(rme-adi2-ctl ${ALSA_LIBRARIES})
target_compile_options(rme-adi2-ctl PRIVATE -Wall -Wextra)

# Install
install(TARGETS rme-adi2-ctl DESTINATION bin)
