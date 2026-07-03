# SPDX-License-Identifier: LGPL-2.1-or-later
# SPDX-FileCopyrightText: 2026 hirashix0

# FetchContent-based consumer of LibreMiddleware. Either points at a local
# checkout (default during development) or pulls a specific tag from the
# remote (CI / release builds).

include(FetchContent)

# Default to a sibling-checkout layout: <multi-repo root>/LibreMiddleware
# next to <multi-repo root>/LibreMac. This matches the project's
# documented multi-repo layout (LibreSCRS/LibreMiddleware,
# LibreSCRS/LibreCelik, LibreSCRS/LibreMac side-by-side).
#
# Override with one of, in priority order:
#   -DLIBREMAC_LM_LOCAL_DIR=/path/to/LibreMiddleware  (CMake cache override)
#   $LIBRESCRS_ROOT environment variable (multi-repo root)
# When neither resolves to an existing checkout, the FetchContent block
# below falls back to a Git fetch of LIBREMAC_LM_GIT_TAG.
if(DEFINED ENV{LIBRESCRS_ROOT} AND NOT DEFINED LIBREMAC_LM_LOCAL_DIR)
    set(_lm_default "$ENV{LIBRESCRS_ROOT}/LibreMiddleware")
else()
    set(_lm_default "${CMAKE_CURRENT_LIST_DIR}/../../LibreMiddleware")
endif()
set(LIBREMAC_LM_LOCAL_DIR "${_lm_default}"
    CACHE PATH "Local LibreMiddleware checkout (overrides Git fetch)")
set(LIBREMAC_LM_GIT_REPOSITORY "https://github.com/LibreSCRS/LibreMiddleware.git"
    CACHE STRING "")
set(LIBREMAC_LM_GIT_TAG "4.2.0"
    CACHE STRING "Branch / tag to fetch when LIBREMAC_LM_LOCAL_DIR is empty")

if(EXISTS "${LIBREMAC_LM_LOCAL_DIR}/CMakeLists.txt")
    message(STATUS "Using local LibreMiddleware at ${LIBREMAC_LM_LOCAL_DIR}")
    FetchContent_Declare(libremiddleware
        SOURCE_DIR "${LIBREMAC_LM_LOCAL_DIR}"
    )
else()
    message(STATUS "Fetching LibreMiddleware from ${LIBREMAC_LM_GIT_REPOSITORY} @ ${LIBREMAC_LM_GIT_TAG}")
    FetchContent_Declare(libremiddleware
        GIT_REPOSITORY "${LIBREMAC_LM_GIT_REPOSITORY}"
        GIT_TAG        "${LIBREMAC_LM_GIT_TAG}"
        GIT_SHALLOW    TRUE
    )
endif()

# LM's Trust subsystem (TrustStoreService eager trusted-list fetch/verify)
# PRIVATE-links LibreSign, so a BUILD_SIGNING=OFF tree cannot link any
# consumer that pulls Trust — and the bridge links LibreSCRS::SmartCard,
# which pulls Trust transitively. Signing must therefore be ON. The native
# backend is JVM-free and carries the TL helpers Trust needs (it is also the
# CI-canonical backend). FORCE is intentionally NOT used: a caller may still
# override the backend explicitly (e.g. -DSIGNING_BACKEND=both for DSS).
if(NOT DEFINED BUILD_SIGNING)
    set(BUILD_SIGNING ON CACHE BOOL "Build LM digital signing support")
endif()
if(NOT DEFINED SIGNING_BACKEND)
    set(SIGNING_BACKEND native CACHE STRING "LM signing backend (native|dss|both)")
endif()
if(NOT DEFINED BUILD_TESTING)
    set(BUILD_TESTING OFF CACHE BOOL "Build LM test suite")
endif()

FetchContent_MakeAvailable(libremiddleware)

# Sanity check: every alias the bridge needs.
foreach(_lib LibreSCRS::Plugin LibreSCRS::SmartCard LibreSCRS::Auth LibreSCRS::Secure)
    if(NOT TARGET ${_lib})
        message(FATAL_ERROR "Expected target ${_lib} from LibreMiddleware not found")
    endif()
endforeach()
