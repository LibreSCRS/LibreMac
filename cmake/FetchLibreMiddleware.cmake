# SPDX-License-Identifier: LGPL-2.1-or-later
# SPDX-FileCopyrightText: 2026 hirashix0

# FetchContent-based consumer of LibreMiddleware. Either points at a local
# checkout (default during development) or pulls a specific tag from the
# remote (CI / release builds).

include(FetchContent)

set(LIBREMAC_LM_LOCAL_DIR "/Users/nhirsl/Development/NetSeT/git/LibreSCRS/LibreMiddleware"
    CACHE PATH "Local LibreMiddleware checkout (overrides Git fetch)")
set(LIBREMAC_LM_GIT_REPOSITORY "https://github.com/LibreSCRS/LibreMiddleware.git"
    CACHE STRING "")
set(LIBREMAC_LM_GIT_TAG "feature/api-boundary-hardening"
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

# LM toggles signing on by default. The bridge does not need it; flip the
# default off so the LibreMac configure stage does not pull the libresign
# dependency tree on a fresh build. FORCE is intentionally NOT used: a user
# who passes -DBUILD_SIGNING=ON explicitly retains that override (e.g. for
# end-to-end signing-flow tests against a real LM tree).
if(NOT DEFINED BUILD_SIGNING)
    set(BUILD_SIGNING OFF CACHE BOOL "Build LM digital signing support")
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
