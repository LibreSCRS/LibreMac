// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
//
// Internal C++ definition of lm_registry_s. The bridge.h public header
// forward-declares the struct as opaque; this internal header provides
// the layout shared between bridge_registry.cpp (defines factories /
// destructor) and bridge_session.cpp (consumes the registry to find the
// right plugin per session).

#ifndef LIBREMAC_BRIDGE_REGISTRY_HANDLE_H
#define LIBREMAC_BRIDGE_REGISTRY_HANDLE_H

#include <LibreSCRS/Plugin/CardPluginService.h>

#include <filesystem>
#include <utility>

struct lm_registry_s {
    LibreSCRS::Plugin::CardPluginService registry;

    explicit lm_registry_s(std::filesystem::path dir)
        : registry(std::move(dir))
    {}
};

#endif // LIBREMAC_BRIDGE_REGISTRY_HANDLE_H
