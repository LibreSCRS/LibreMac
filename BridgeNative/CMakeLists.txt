# SPDX-License-Identifier: LGPL-2.1-or-later
# SPDX-FileCopyrightText: 2026 hirashix0

add_library(BridgeNative STATIC
    src/bridge_types.cpp
    src/bridge_registry.cpp
    src/bridge_session.cpp
)

target_include_directories(BridgeNative PUBLIC
    "${CMAKE_CURRENT_SOURCE_DIR}/include"
)

target_link_libraries(BridgeNative PUBLIC
    LibreSCRS::Plugin
    LibreSCRS::SmartCard
    LibreSCRS::Auth
    LibreSCRS::Secure
    # CardPlugin_Impl is the LibreMiddleware ABI v6 key-function archive
    # (Itanium C++ ABI §5.1) that anchors the CardPlugin vtable + typeinfo
    # into a single TU. Without explicit linkage the bridge sees an
    # undefined ~CardPlugin() at link time even though LibreSCRS::Plugin
    # is already in the link line.
    CardPlugin_Impl
)

set_target_properties(BridgeNative PROPERTIES
    POSITION_INDEPENDENT_CODE ON
    OSX_ARCHITECTURES "${CMAKE_OSX_ARCHITECTURES}"
)
