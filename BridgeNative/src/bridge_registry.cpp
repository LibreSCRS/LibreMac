// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
//
// CardPluginRegistry construction across the C ABI. LM 4.0 (ABI v6) makes
// the registry's plugin set immutable post-construction; the bridge owns one
// CardPluginRegistry per lm_registry_t handle.

#include "bridge.h"
#include "registry_handle.h"

#include <new>

extern "C" {

lm_registry_t lm_registry_create(const char* plugins_dir)
{
    if (plugins_dir == nullptr) {
        return nullptr;
    }
    try {
        return new (std::nothrow) lm_registry_s(std::filesystem::path{plugins_dir});
    } catch (...) {
        // CardPluginRegistry construction documents that it does not throw
        // on bad plugin files (those land in loadReport). The only failure
        // mode is internal allocation; the C ABI must absorb anything
        // anyway so the Swift side never sees an unwound exception.
        return nullptr;
    }
}

void lm_registry_destroy(lm_registry_t r)
{
    delete r;
}

int lm_registry_plugin_count(lm_registry_t r)
{
    if (r == nullptr) {
        return -1;
    }
    return static_cast<int>(r->registry.size());
}

} // extern "C"
