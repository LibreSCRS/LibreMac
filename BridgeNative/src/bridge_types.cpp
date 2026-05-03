// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
//
// extern "C" memory-hygiene helpers — the only legitimate way the Swift /
// Obj-C++ side hands ownership back across the bridge.

#include "bridge.h"

#include <cstdint>
#include <cstdlib>

extern "C" {

void lm_string_free(char* s)
{
    std::free(s);
}

void lm_buffer_free(std::uint8_t* p)
{
    std::free(p);
}

void lm_buffer_array_free(lm_buffer_t* arr, std::size_t count)
{
    if (arr == nullptr) {
        return;
    }
    for (std::size_t i = 0; i < count; ++i) {
        std::free(arr[i].data);
    }
    std::free(arr);
}

} // extern "C"
