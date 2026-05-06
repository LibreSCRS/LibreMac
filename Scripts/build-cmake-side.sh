#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# SPDX-FileCopyrightText: 2026 hirashix0
#
# Builds the BridgeNative static archive from the CMake side and stages it
# where the Xcode build expects it. Called from the LibreMac target's
# pre-build phase; can also be invoked manually for development.
set -euo pipefail

CONFIG="${1:-Debug}"
STAGE_DIR="${2:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/$CONFIG"

case "$CONFIG" in
    Debug)   CMAKE_BUILD_TYPE=Debug ;;
    Release) CMAKE_BUILD_TYPE=Release ;;
    *)       CMAKE_BUILD_TYPE=Debug ;;
esac

# Generator: prefer Ninja if available, but only on first configure. Subsequent
# runs reuse whatever generator the build tree was created with — switching
# breaks CMake (cache "generator does not match" error).
GENERATOR_FLAG=""
if [ ! -d "$BUILD" ]; then
    if command -v ninja >/dev/null 2>&1; then
        GENERATOR_FLAG="-G Ninja"
    fi
fi

# shellcheck disable=SC2086  # GENERATOR_FLAG is intentionally word-split
cmake -S "$ROOT" -B "$BUILD" $GENERATOR_FLAG -DCMAKE_BUILD_TYPE="$CMAKE_BUILD_TYPE"
cmake --build "$BUILD" --target BridgeNative

ARCHIVE="$BUILD/BridgeNative/libBridgeNative.a"

# Stage BridgeNative + every LibreSCRS::* static archive so the Xcode linker
# can resolve them with `-L$BUILT_PRODUCTS_DIR -lBridgeNative -lLibreSCRS_* ...`.
# A single -L resolution path keeps the OTHER_LDFLAGS list short and avoids
# encoding CMake's _deps/ layout in project.yml.
#
# `libcrypto.a` is also staged because LibreSCRS_Auth has a PUBLIC link
# dependency on the bundled OpenSSL 3.5.5 static archive (see
# LibreMiddleware/thirdparty/CMakeLists.txt). The static archive's
# dependencies do NOT propagate when consumers link a CMake-built archive
# through a non-CMake (XcodeGen) consumer; the host link line must therefore
# spell out -lcrypto explicitly. Per Stroustrup A Tour of C++ §15: a stable
# C ABI surface keeps the host independent of CMake's transitive dep graph.
if [ -n "$STAGE_DIR" ]; then
    mkdir -p "$STAGE_DIR"
    cp "$ARCHIVE" "$STAGE_DIR/"
    # Parentheses around the OR group are essential — without them, -print0
    # binds only to the last -name predicate.
    while IFS= read -r -d '' lib; do
        cp "$lib" "$STAGE_DIR/"
    done < <(find "$BUILD/_deps" -maxdepth 6 \
        \( -name 'libLibreSCRS_*.a' -o -name 'libCardPlugin_Impl.a' -o -name 'libSmartCard_Impl.a' \) \
        -print0 2>/dev/null)
    # Bundled OpenSSL 3.5.5 static archive (LM ships its own to pin the
    # crypto version). Resolve through the FetchContent source dir.
    LM_SRC=$(find "$BUILD/_deps" -maxdepth 3 -type d -name 'libremiddleware-src' 2>/dev/null | head -n1)
    # Fallback to a sibling-checkout layout when LM was provided via
    # LIBREMAC_LM_LOCAL_DIR rather than fetched (FetchContent stages no
    # `_deps/libremiddleware-src/` symlink in that case). Override priority:
    #   $LIBREMAC_LM_LOCAL_DIR  (explicit, matches the CMake cache var)
    #   $LIBRESCRS_ROOT/LibreMiddleware  (multi-repo root)
    #   <SRCROOT>/../LibreMiddleware  (sibling-checkout default)
    if [ -z "$LM_SRC" ]; then
        if [ -n "$LIBREMAC_LM_LOCAL_DIR" ] && [ -d "$LIBREMAC_LM_LOCAL_DIR" ]; then
            LM_SRC="$LIBREMAC_LM_LOCAL_DIR"
        elif [ -n "$LIBRESCRS_ROOT" ] && [ -d "$LIBRESCRS_ROOT/LibreMiddleware" ]; then
            LM_SRC="$LIBRESCRS_ROOT/LibreMiddleware"
        elif [ -n "$SRCROOT" ] && [ -d "$SRCROOT/../LibreMiddleware" ]; then
            LM_SRC="$SRCROOT/../LibreMiddleware"
        fi
    fi
    if [ -n "$LM_SRC" ] && [ -f "$LM_SRC/thirdparty/openssl-3.5.5/macosx/lib/libcrypto.a" ]; then
        cp "$LM_SRC/thirdparty/openssl-3.5.5/macosx/lib/libcrypto.a" "$STAGE_DIR/"
    else
        echo "warning: bundled libcrypto.a not found under $LM_SRC; relying on system OpenSSL" >&2
    fi
fi

echo "BridgeNative built: $ARCHIVE"
