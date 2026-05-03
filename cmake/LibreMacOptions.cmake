# SPDX-License-Identifier: LGPL-2.1-or-later
# SPDX-FileCopyrightText: 2026 hirashix0

# LibreMac CMake configuration.
# Sourced from the root CMakeLists.txt; centralises platform / language flags.

if(NOT APPLE)
    message(FATAL_ERROR "LibreMac is macOS-only.")
endif()

set(CMAKE_OSX_DEPLOYMENT_TARGET 15.0   CACHE STRING "" FORCE)
set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64" CACHE STRING "" FORCE)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Apple Clang ships std::stop_token / std::stop_source behind
# -fexperimental-library; LibreMiddleware uses both. Per
# feedback_apple_clang_experimental.md (LM 2026-04-15), use the standard
# library plus the flag — never re-implement.
if(CMAKE_CXX_COMPILER_ID STREQUAL "AppleClang")
    add_compile_options(-fexperimental-library)
    add_link_options(-fexperimental-library)
endif()

# Diagnostics: warnings as errors on the bridge code.
add_compile_options(
    $<$<COMPILE_LANGUAGE:CXX>:-Wall>
    $<$<COMPILE_LANGUAGE:CXX>:-Wextra>
    $<$<COMPILE_LANGUAGE:CXX>:-Wpedantic>
    $<$<COMPILE_LANGUAGE:CXX>:-Werror>
)
