#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# SPDX-FileCopyrightText: 2026 hirashix0
#
# Stages librescrs-agent + librescrs-prompter + the agent PKCS#11 module (built
# by the LibreDarwin repo) plus the LibreMiddleware dylib/pkcs11/plugin closure
# into a built LibreMac host .app. It signs nothing: Scripts/sign-bundle.sh
# signs the result. This is packaging glue only -- it does NOT build LibreMac or
# LibreDarwin; run generate-project.sh + xcodebuild (or the release pipeline)
# first, then point this script at the resulting .app.
#
# Layout staged:
#   Contents/Resources/certificates/ <- LM_LIB_PREFIX/../share/librescrs/certificates
#   Contents/MacOS/librescrs-agent           <- LIBREDARWIN_PREFIX/agent/librescrs-agent
#   Contents/MacOS/librescrs-prompter        <- LIBREDARWIN_PREFIX/prompter/librescrs-prompter
#   Contents/Frameworks/libLibreSCRS_*.dylib <- LM_LIB_PREFIX/libLibreSCRS_*.<soname>.dylib
#   Contents/Frameworks/librescrs-pkcs11.dylib <- LM_LIB_PREFIX/pkcs11/librescrs-pkcs11.<soname>.dylib
#   Contents/Frameworks/librescrs-pkcs11-agent.dylib <- LIBREDARWIN_PREFIX/pkcs11-module/librescrs-pkcs11-agent.dylib
#   Contents/PlugIns/librescrs/*.dylib       <- LM_LIB_PREFIX/librescrs/plugins/*.dylib
#   Contents/Library/LaunchAgents/org.librescrs.{agent,prompter}.plist <- Packaging/
#   Contents/Resources/librescrs-agent.version <- stamped from the LibreDarwin build tree
#
# Not staged here: Contents/PlugIns/LibreMacToken.appex is nested into the host
# .app by the Xcode build itself (LibreMacToken is a `dependencies:` entry of
# the host target in project.yml). Nothing here writes inside it.
#
# *** DEV-AGENT LABEL COLLISION ***
# packaging/install-dev.sh (LibreDarwin) bootstraps a LaunchAgent with the
# SAME label (org.librescrs.agent) pointed at the dev build tree. Testing a
# bundled agent while the dev agent is still loaded is undefined (whichever
# registered second wins, or launchd rejects the duplicate label) — run
# `packaging/install-dev.sh unload` in LibreDarwin FIRST and confirm with
# `launchctl print gui/$UID/org.librescrs.agent` that it is gone before
# approving the bundled Login Item.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_PATH="${1:?usage: bundle-agent.sh <path-to-LibreMac.app> [LIBREDARWIN_PREFIX] [LM_LIB_PREFIX]}"
LIBREDARWIN_PREFIX="${2:-${LIBREDARWIN_PREFIX:-$REPO_ROOT/../LibreDarwin/build-release}}"
LM_LIB_PREFIX="${3:-${LM_LIB_PREFIX:-$REPO_ROOT/../LibreMiddleware/build/_install/lib}}"

[ -d "$APP_PATH" ] || { echo "bundle-agent: no such app bundle: $APP_PATH" >&2; exit 1; }
[ -d "$APP_PATH/Contents/PlugIns/LibreMacToken.appex" ] || {
    echo "bundle-agent: LibreMacToken.appex not nested under Contents/PlugIns (regenerate + build the host target first -- it embeds LibreMacToken via project.yml)" >&2
    exit 1
}
[ -x "$LIBREDARWIN_PREFIX/agent/librescrs-agent" ] || {
    echo "bundle-agent: librescrs-agent not found under $LIBREDARWIN_PREFIX (build LibreDarwin first)" >&2
    exit 1
}
[ -x "$LIBREDARWIN_PREFIX/prompter/librescrs-prompter" ] || {
    echo "bundle-agent: librescrs-prompter not found under $LIBREDARWIN_PREFIX (build LibreDarwin first)" >&2
    exit 1
}
[ -f "$LIBREDARWIN_PREFIX/pkcs11-module/librescrs-pkcs11-agent.dylib" ] || {
    echo "bundle-agent: librescrs-pkcs11-agent.dylib not found under $LIBREDARWIN_PREFIX (build LibreDarwin first)" >&2
    exit 1
}
[ -d "$LM_LIB_PREFIX" ] || {
    echo "bundle-agent: LibreMiddleware lib prefix not found: $LM_LIB_PREFIX" >&2
    exit 1
}

echo "bundle-agent: app=$APP_PATH"
echo "bundle-agent: LIBREDARWIN_PREFIX=$LIBREDARWIN_PREFIX"
echo "bundle-agent: LM_LIB_PREFIX=$LM_LIB_PREFIX"

MACOS="$APP_PATH/Contents/MacOS"
FRAMEWORKS="$APP_PATH/Contents/Frameworks"
PLUGINS="$APP_PATH/Contents/PlugIns/librescrs"
LAUNCHAGENTS="$APP_PATH/Contents/Library/LaunchAgents"
RESOURCES="$APP_PATH/Contents/Resources"
mkdir -p "$MACOS" "$FRAMEWORKS" "$PLUGINS" "$LAUNCHAGENTS" "$RESOURCES"

# ---------------------------------------------------------------- stage trust anchors
# Trust anchors for the card plugins, from the same LibreMiddleware prefix the
# dylibs come from. The provider inside the Trust library looks for
# lib/../Resources/certificates relative to where it was loaded from, which in
# this layout is exactly Contents/Resources/certificates. Cleared before it is
# filled: a copy that merges into a directory surviving an incremental rebuild
# keeps an anchor the prefix has since retired, and signs it again.
CERTS_SRC="$LM_LIB_PREFIX/../share/librescrs/certificates"
[ -d "$CERTS_SRC" ] || {
    echo "bundle-agent: no trust anchors under $CERTS_SRC (install LibreMiddleware with its share/ tree)" >&2
    exit 1
}
rm -rf "$RESOURCES/certificates"
mkdir -p "$RESOURCES/certificates"
cp -R "$CERTS_SRC"/. "$RESOURCES/certificates/"

# ---------------------------------------------------------------- stage binaries
cp "$LIBREDARWIN_PREFIX/agent/librescrs-agent" "$MACOS/librescrs-agent"
cp "$LIBREDARWIN_PREFIX/prompter/librescrs-prompter" "$MACOS/librescrs-prompter"
chmod u+w "$MACOS/librescrs-agent" "$MACOS/librescrs-prompter"
# The PKCS#11 module other applications load to reach the agent. Not to be
# confused with librescrs-pkcs11.dylib below, which drives the card directly
# and is the agent's own.
cp "$LIBREDARWIN_PREFIX/pkcs11-module/librescrs-pkcs11-agent.dylib" "$FRAMEWORKS/librescrs-pkcs11-agent.dylib"
chmod u+w "$FRAMEWORKS/librescrs-pkcs11-agent.dylib"

# ---------------------------------------------------------------- stage LM dylibs
# Dereference the soname symlinks -> the real versioned file: a symlinked
# dylib copied as a symlink into the bundle would dangle once the
# LibreMiddleware build tree it points at is gone.
#
# The soname integer is LIBRESCRS_ABI_SOVERSION, not the release version, and it
# was hard-coded here as 4 until LibreMiddleware moved to 5 -- see
# Scripts/lm-soname.sh for why neither a literal nor PROJECT_VERSION is right.
#
# The PKCS#11 module is versioned with the same soname, and a prefix reused
# across an ABI bump carries both, so the soname picks the module as well.
shopt -s nullglob
lm_soname="$("$SCRIPT_DIR/lm-soname.sh" "$LM_LIB_PREFIX")" || exit 1
lm_dylibs=("$LM_LIB_PREFIX"/libLibreSCRS_*."$lm_soname".dylib)
[ "${#lm_dylibs[@]}" -gt 0 ] || { echo "bundle-agent: no libLibreSCRS_*.$lm_soname.dylib under $LM_LIB_PREFIX" >&2; exit 1; }
echo "bundle-agent: LibreMiddleware soname=$lm_soname (${#lm_dylibs[@]} dylibs)"
for lib in "${lm_dylibs[@]}"; do
    cp -L "$lib" "$FRAMEWORKS/$(basename "$lib")"
    chmod u+w "$FRAMEWORKS/$(basename "$lib")"
done
# pkcs11 module: LM's resolvePkcs11Module candidate 3 is
# exe/../Frameworks/librescrs-pkcs11.dylib — the target NAME must be exactly
# that (not the versioned basename) or the candidate lookup misses.
pkcs11_src="$LM_LIB_PREFIX/pkcs11/librescrs-pkcs11.$lm_soname.dylib"
[ -e "$pkcs11_src" ] || { echo "bundle-agent: no librescrs-pkcs11.$lm_soname.dylib under $LM_LIB_PREFIX/pkcs11" >&2; exit 1; }
cp -L "$pkcs11_src" "$FRAMEWORKS/librescrs-pkcs11.dylib"
chmod u+w "$FRAMEWORKS/librescrs-pkcs11.dylib"

# plugins
plugin_srcs=("$LM_LIB_PREFIX"/librescrs/plugins/*.dylib)
[ "${#plugin_srcs[@]}" -gt 0 ] || { echo "bundle-agent: no plugins under $LM_LIB_PREFIX/librescrs/plugins" >&2; exit 1; }
for p in "${plugin_srcs[@]}"; do
    cp -L "$p" "$PLUGINS/$(basename "$p")"
    chmod u+w "$PLUGINS/$(basename "$p")"
done
shopt -u nullglob
echo "bundle-agent: staged ${#lm_dylibs[@]} LM dylib(s), pkcs11 module, ${#plugin_srcs[@]} plugin(s)"

# ---------------------------------------------------------------- stage plists
cp "$REPO_ROOT/Packaging/org.librescrs.agent.plist" "$LAUNCHAGENTS/org.librescrs.agent.plist"
cp "$REPO_ROOT/Packaging/org.librescrs.prompter.plist" "$LAUNCHAGENTS/org.librescrs.prompter.plist"

# ---------------------------------------------------------------- version stamp
ld_version=""
if [ -f "$LIBREDARWIN_PREFIX/CMakeCache.txt" ]; then
    ld_version="$(sed -n 's/^CMAKE_PROJECT_VERSION:STATIC=//p' "$LIBREDARWIN_PREFIX/CMakeCache.txt" | head -1)"
fi
if [ -z "$ld_version" ]; then
    ld_repo="$(cd "$LIBREDARWIN_PREFIX/.." && pwd)"
    ld_version="$(git -C "$ld_repo" describe --tags --always 2>/dev/null || true)"
fi
[ -n "$ld_version" ] || ld_version="unknown"
echo "$ld_version" > "$RESOURCES/librescrs-agent.version"
echo "bundle-agent: stamped version $ld_version"

# ---------------------------------------------------------------- rpath fixup
# INSTALL_RPATH already baked @executable_path/../Frameworks into both
# binaries at LibreDarwin build time; this is a defensive re-assert plus
# removal of any stray absolute build-tree rpath the LM dylibs carry.
for bin in "$MACOS/librescrs-agent" "$MACOS/librescrs-prompter"; do
    install_name_tool -delete_rpath "$LM_LIB_PREFIX" "$bin" 2>/dev/null || true
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$bin" 2>/dev/null || true
done

# ---------------------------------------------------------------- homebrew dependency closure
# Any /opt/homebrew-linked dylib pulled in transitively (LM's crypto/XML deps)
# is copied into Frameworks and every referencing binary is rewritten to
# @rpath — never left pointing at the build machine's absolute Homebrew path.
# Iterates to a fixed point (a copied-in dylib can itself depend on another
# Homebrew dylib not yet staged).
fix_homebrew() {
    local pass=0
    while :; do
        pass=$((pass + 1))
        local changed=0
        for bin in "$MACOS/librescrs-agent" "$MACOS/librescrs-prompter" "$FRAMEWORKS"/*.dylib "$PLUGINS"/*.dylib; do
            [ -f "$bin" ] || continue
            while IFS= read -r dep; do
                dep="$(echo "$dep" | awk '{print $1}')"
                case "$dep" in /opt/homebrew/*) ;; *) continue ;; esac
                local base
                base="$(basename "$dep")"
                if [ ! -f "$FRAMEWORKS/$base" ]; then
                    cp -L "$dep" "$FRAMEWORKS/$base"
                    chmod u+w "$FRAMEWORKS/$base"
                    install_name_tool -id "@rpath/$base" "$FRAMEWORKS/$base"
                fi
                install_name_tool -change "$dep" "@rpath/$base" "$bin"
                changed=1
            done < <(otool -L "$bin" | tail -n +2)
        done
        [ "$changed" = 0 ] && break
        [ "$pass" -gt 5 ] && { echo "bundle-agent: homebrew dependency fixup did not converge" >&2; exit 1; }
    done
}
fix_homebrew

echo "bundle-agent: done -> $APP_PATH"
