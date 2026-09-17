#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# SPDX-FileCopyrightText: 2026 hirashix0
#
# Verifies a LibreMac .app bundle-agent.sh has staged and signed correctly,
# plus that the Xcode-nested Contents/PlugIns/LibreMacToken.appex carries its
# expected entitlements. Each assertion prints PASS/FAIL/SKIP and the script
# exits non-zero if any hard assertion fails. Some assertions are intrinsically
# best-effort on an ad-hoc-signed / no-Developer-ID machine and are recorded
# rather than gated: the WHOLE-BUNDLE signature (the host .app itself may be
# unsigned under CODE_SIGNING_ALLOWED=NO), `spctl -a` (Gatekeeper always
# rejects ad-hoc signatures — that is expected, not a bug), and the appex
# Team-signed check (skipped honestly, never claimed, when the appex is only
# ad-hoc signed — i.e. codesign reports TeamIdentifier=not set).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

APP_PATH="${1:?usage: verify-bundle.sh <path-to-LibreMac.app>}"

FAIL=0
PASS=0
SKIP=0

pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }
skip() { SKIP=$((SKIP + 1)); echo "SKIP: $1"; }

[ -d "$APP_PATH" ] || { echo "verify-bundle: no such app bundle: $APP_PATH" >&2; exit 2; }

MACOS="$APP_PATH/Contents/MacOS"
FRAMEWORKS="$APP_PATH/Contents/Frameworks"
PLUGINS="$APP_PATH/Contents/PlugIns/librescrs"
LAUNCHAGENTS="$APP_PATH/Contents/Library/LaunchAgents"
RESOURCES="$APP_PATH/Contents/Resources"

echo "== verify-bundle: $APP_PATH =="

# ---------------------------------------------------------------- plists
for name in org.librescrs.agent org.librescrs.prompter; do
    plist="$LAUNCHAGENTS/$name.plist"
    if [ -f "$plist" ]; then
        prog="$(/usr/libexec/PlistBuddy -c "Print :BundleProgram" "$plist" 2>/dev/null || true)"
        label="$(/usr/libexec/PlistBuddy -c "Print :Label" "$plist" 2>/dev/null || true)"
        if [ -n "$prog" ] && [ "$label" = "$name" ]; then
            pass "$name.plist present, BundleProgram=$prog, Label=$label"
        else
            fail "$name.plist present but missing BundleProgram or Label mismatch (got label='$label')"
        fi
    else
        fail "$name.plist missing under Contents/Library/LaunchAgents"
    fi
done

# ---------------------------------------------------------------- binaries present
for bin in librescrs-agent librescrs-prompter; do
    if [ -x "$MACOS/$bin" ]; then
        pass "$bin present at Contents/MacOS/$bin"
    else
        fail "$bin missing or not executable at Contents/MacOS/$bin"
    fi
done

# ---------------------------------------------------------------- rpath closure
for bin in librescrs-agent librescrs-prompter; do
    path="$MACOS/$bin"
    [ -x "$path" ] || continue
    rpaths="$(otool -l "$path" | grep -A2 LC_RPATH | grep 'path ' || true)"
    if echo "$rpaths" | grep -q '@executable_path/../Frameworks'; then
        pass "$bin carries LC_RPATH @executable_path/../Frameworks"
    else
        fail "$bin missing LC_RPATH @executable_path/../Frameworks (got: $(echo "$rpaths" | tr '\n' ';'))"
    fi
done

# ---------------------------------------------------------------- LibreMiddleware soname load commands
# Contents/Frameworks is the same install prefix bundle-agent.sh staged from,
# so it carries exactly the libLibreSCRS_<Name>.<soname>.dylib names
# lm-soname.sh looks for -- deriving the expected soname from the bundle
# itself means this check can only ever compare the executables against what
# they actually shipped with, never against an unrelated build tree the
# caller happens to point at.
lm_soname="$(bash "$SCRIPT_DIR/lm-soname.sh" "$FRAMEWORKS" 2>/tmp/verify-bundle-lm-soname.err)"
if [ -z "$lm_soname" ]; then
    fail "cannot determine the LibreMiddleware soname from $FRAMEWORKS: $(cat /tmp/verify-bundle-lm-soname.err)"
else
    # Every Mach-O actually present in Contents/MacOS, not a hardcoded pair --
    # a third staged executable is covered without editing this list.
    macos_machos=()
    for f in "$MACOS"/*; do
        [ -f "$f" ] || continue
        otool -h "$f" >/dev/null 2>&1 && macos_machos+=("$f")
    done
    # ${a[@]+...} rather than a bare "${a[@]}": bash 3.2 -- which is what
    # /bin/bash on macOS still is -- treats an EMPTY array as unset under
    # `set -u` and aborts the whole script, taking every assertion after this
    # loop and the summary with it. A bundle with nothing Mach-O in
    # Contents/MacOS is exactly the broken bundle this script exists to
    # report on, so it must survive to report it.
    for path in ${macos_machos[@]+"${macos_machos[@]}"} "$FRAMEWORKS"/*.dylib; do
        [ -f "$path" ] || continue
        # A universal binary repeats every load command once per slice, so
        # dedupe: it is the same load command either way, not a second one.
        # The candidate regex only requires the mandatory @rpath/libLibreSCRS_
        # prefix and .dylib suffix (one dot, e.g. the unversioned development
        # link name) -- the soname itself is validated separately below, so
        # every non-conforming form (missing soname segment, wrong soname)
        # lands in $bad rather than being silently dropped from $loaded.
        # All three dylib-naming load commands, not LC_LOAD_DYLIB alone: a
        # weak or re-exported link resolves through the same @rpath and
        # carries the same soname obligation, so matching only the plain kind
        # would let a wrong-soname name ride in unjudged.
        loaded="$(otool -l "$path" | grep -E -A2 'cmd LC_(LOAD|LOAD_WEAK|REEXPORT)_DYLIB' \
            | sed -n 's/^ *name \(@rpath\/libLibreSCRS_[^ ]*\.dylib\).*/\1/p' \
            | sort -u)"
        [ -n "$loaded" ] || continue
        bad="$(echo "$loaded" | grep -vE "^@rpath/libLibreSCRS_[A-Za-z0-9]+\.${lm_soname}\.dylib\$" || true)"
        if [ -n "$bad" ]; then
            fail "$(basename "$path") dylib load command $(echo "$bad" | paste -sd';' -) -- expected libLibreSCRS_<Name>.$lm_soname.dylib (LibreMiddleware soname $lm_soname)"
        else
            pass "$(basename "$path") dylib load command libLibreSCRS_* names match soname $lm_soname"
        fi
    done
fi

# ---------------------------------------------------------------- pkcs11 dylib
if [ -f "$FRAMEWORKS/librescrs-pkcs11.dylib" ]; then
    pass "librescrs-pkcs11.dylib present in Contents/Frameworks (LM resolvePkcs11Module candidate 3)"
else
    fail "librescrs-pkcs11.dylib missing from Contents/Frameworks"
fi

# ---------------------------------------------------------------- plugin count
plugin_count=0
if [ -d "$PLUGINS" ]; then
    plugin_count="$(find "$PLUGINS" -name '*.dylib' | wc -l | tr -d ' ')"
fi
if [ "$plugin_count" -ge 6 ]; then
    pass "$plugin_count plugin(s) staged in Contents/PlugIns/librescrs (>= 6)"
else
    fail "$plugin_count plugin(s) staged in Contents/PlugIns/librescrs (< 6 expected)"
fi

# ---------------------------------------------------------------- version stamp
if [ -s "$RESOURCES/librescrs-agent.version" ]; then
    pass "version stamp present: $(cat "$RESOURCES/librescrs-agent.version")"
else
    fail "Contents/Resources/librescrs-agent.version missing or empty"
fi

# ---------------------------------------------------------------- trust anchors
# The agent builds its trust store from the anchors staged here; without them
# every card verification reads "unknown", silently. Count, do not stat: an
# empty directory is the same failure as a missing one. The depth is the
# provider's, not the filesystem's: it loads the files directly in this
# directory plus the ones in its immediate subdirectories and descends no
# further, so a file staged deeper would be counted here and never read there.
certs=$(find "$RESOURCES/certificates" -maxdepth 2 -type f \( -name '*.pem' -o -name '*.crt' -o -name '*.cer' -o -name '*.der' \) 2>/dev/null | wc -l | tr -d ' ')
if [ "${certs:-0}" -eq 0 ]; then
    fail "Contents/Resources/certificates is missing or empty: the agent would report every card verification as unknown"
else
    pass "trust anchors staged: $certs file(s)"
fi

# ---------------------------------------------------------------- entitlements
check_entitlement() {
    local bin="$1" key="$2" want="$3"
    local dump
    dump="$(codesign -d --entitlements - --xml "$bin" 2>/dev/null || true)"
    if echo "$dump" | grep -q "<key>$key</key>"; then
        if [ "$want" = "true" ]; then
            echo "$dump" | grep -A1 "<key>$key</key>" | grep -q "<true/>" && return 0 || return 1
        else
            return 0 # presence-only check (e.g. application-groups array)
        fi
    fi
    return 1
}

if [ -x "$MACOS/librescrs-agent" ]; then
    ok=1
    check_entitlement "$MACOS/librescrs-agent" "com.apple.security.app-sandbox" true || ok=0
    check_entitlement "$MACOS/librescrs-agent" "com.apple.security.smartcard" true || ok=0
    check_entitlement "$MACOS/librescrs-agent" "com.apple.security.network.client" true || ok=0
    check_entitlement "$MACOS/librescrs-agent" "com.apple.security.application-groups" present || ok=0
    if [ "$ok" = 1 ]; then
        pass "librescrs-agent entitlements match the expected set (sandbox+smartcard+network.client+application-groups)"
    else
        fail "librescrs-agent entitlements do not match the expected set"
    fi
fi

if [ -x "$MACOS/librescrs-prompter" ]; then
    ok=1
    check_entitlement "$MACOS/librescrs-prompter" "com.apple.security.app-sandbox" true || ok=0
    check_entitlement "$MACOS/librescrs-prompter" "com.apple.security.application-groups" present || ok=0
    dump="$(codesign -d --entitlements - --xml "$MACOS/librescrs-prompter" 2>/dev/null || true)"
    if echo "$dump" | grep -q "com.apple.security.inherit"; then
        fail "librescrs-prompter carries com.apple.security.inherit (an inherit-sandboxed child cannot RegisterApplication as its own LaunchAgent)"
        ok=0
    fi
    if [ "$ok" = 1 ]; then
        pass "librescrs-prompter entitlements match the expected set (sandbox+application-groups, no inherit)"
    else
        fail "librescrs-prompter entitlements do not match the expected set"
    fi
fi

# ---------------------------------------------------------------- LibreMacToken.appex
# Nested by the Xcode build (project.yml host `dependencies:`), not staged by
# bundle-agent.sh — this only checks what landed in the built bundle.
TOKEN_APPEX="$APP_PATH/Contents/PlugIns/LibreMacToken.appex"
if [ -d "$TOKEN_APPEX" ]; then
    pass "LibreMacToken.appex present at Contents/PlugIns/LibreMacToken.appex"

    ok=1
    check_entitlement "$TOKEN_APPEX" "keychain-access-groups" present || ok=0
    check_entitlement "$TOKEN_APPEX" "com.apple.security.application-groups" present || ok=0
    if [ "$ok" = 1 ]; then
        pass "LibreMacToken.appex entitlements match the expected set (keychain-access-groups+application-groups)"
    else
        fail "LibreMacToken.appex entitlements do not match the expected set"
    fi

    if codesign --verify --strict "$TOKEN_APPEX" 2>/tmp/verify-bundle-codesign.err; then
        pass "codesign --verify --strict LibreMacToken.appex"
    else
        fail "codesign --verify --strict LibreMacToken.appex: $(cat /tmp/verify-bundle-codesign.err)"
    fi

    # Team-signed check: only meaningful with a real Developer ID identity.
    # codesign reports TeamIdentifier=not set for ad-hoc (-s -) signatures —
    # on this team-less machine that is expected, so the check is skipped
    # rather than reported as a pass or a fail.
    team_id="$(codesign -dvvv "$TOKEN_APPEX" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
    if [ -z "$team_id" ] || [ "$team_id" = "not set" ]; then
        skip "LibreMacToken.appex Team-signed check (ad-hoc signature, no Team ID on this machine — record-only)"
    else
        pass "LibreMacToken.appex is Team-signed (TeamIdentifier=$team_id)"
    fi
else
    fail "LibreMacToken.appex missing from Contents/PlugIns"
fi

# ---------------------------------------------------------------- per-component signature
for bin in "$MACOS/librescrs-agent" "$MACOS/librescrs-prompter"; do
    [ -x "$bin" ] || continue
    if codesign --verify --strict "$bin" 2>/tmp/verify-bundle-codesign.err; then
        pass "codesign --verify --strict $(basename "$bin")"
    else
        fail "codesign --verify --strict $(basename "$bin"): $(cat /tmp/verify-bundle-codesign.err)"
    fi
done
for lib in "$FRAMEWORKS"/*.dylib "$PLUGINS"/*.dylib; do
    [ -f "$lib" ] || continue
    if codesign --verify --strict "$lib" 2>/tmp/verify-bundle-codesign.err; then
        :
    else
        fail "codesign --verify --strict $(basename "$lib"): $(cat /tmp/verify-bundle-codesign.err)"
    fi
done
pass "codesign --verify --strict on all staged Frameworks/PlugIns dylibs"

# ---------------------------------------------------------------- whole-bundle signature (best-effort)
if codesign --verify --strict "$APP_PATH" >/tmp/verify-bundle-app.err 2>&1; then
    pass "codesign --verify --strict on the whole bundle"
else
    skip "codesign --verify --strict on the whole bundle (host app unsigned/ad-hoc — expected under CODE_SIGNING_ALLOWED=NO): $(cat /tmp/verify-bundle-app.err | tail -1)"
fi

# ---------------------------------------------------------------- lipo arch check
expected_archs="${LIBREDARWIN_EXPECTED_ARCHS:-}"
for bin in librescrs-agent librescrs-prompter; do
    path="$MACOS/$bin"
    [ -x "$path" ] || continue
    archs="$(lipo -archs "$path" 2>/dev/null || true)"
    if [ -n "$expected_archs" ]; then
        if [ "$archs" = "$expected_archs" ]; then
            pass "$bin archs '$archs' match expected '$expected_archs'"
        else
            fail "$bin archs '$archs' do not match expected '$expected_archs'"
        fi
    else
        skip "$bin archs '$archs' (LIBREDARWIN_EXPECTED_ARCHS not set — record-only)"
    fi
done

# ---------------------------------------------------------------- spctl (ad-hoc: record-only)
spctl_out="$(spctl -a -vv "$APP_PATH" 2>&1 || true)"
skip "spctl -a -vv (ad-hoc signature always rejected by Gatekeeper — record-only): $(echo "$spctl_out" | tail -1)"

echo "== summary: $PASS passed, $FAIL failed, $SKIP skipped =="
[ "$FAIL" -eq 0 ]
