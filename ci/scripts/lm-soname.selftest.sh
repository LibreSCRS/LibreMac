#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# SPDX-FileCopyrightText: 2026 hirashix0
#
# lm-soname.selftest.sh -- drive Scripts/lm-soname.sh over built prefixes.
#
# Fixtures are named the way CMake names the real thing: the REAL file carries
# the full version triple, the soname symlink carries SOVERSION alone, and the
# unversioned link points at the soname. The triple and the soname integer are
# DIFFERENT numbers here, tracking different events -- an ABI layout change,
# not a release -- so a helper reading the integer off the real file answers
# the wrong one. One case perturbs the helper on purpose and requires the
# suite to notice.
#
# Whether bundle-agent.sh USES the helper is measured where it runs: the
# release workflow runs it over the real LibreMiddleware prefix (on every push
# that touches it), and verify-bundle.sh checks what landed in the bundle.
set -uo pipefail
export LC_ALL=C

HELPER="${1:-$(cd "$(dirname "$0")/../.." && pwd)/Scripts/lm-soname.sh}"
[ -x "$HELPER" ] || { echo "FATAL: helper not executable: $HELPER" >&2; exit 2; }

WORK="$(mktemp -d /var/tmp/lm-soname-selftest.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
# red-proved: a verdict site where the helper had to come back non-zero over a
# perturbed input. Every recorded verdict is one case: pass + fail.
red=0

mkprefix() { # <dir> <soname>...   real file's triple differs from the soname
    local d="$1"; shift; mkdir -p "$d"
    local c s
    for c in Auth Card Plugin Trust; do
        : > "$d/libLibreSCRS_$c.4.2.0.dylib"
        for s in "$@"; do ln -sf "libLibreSCRS_$c.4.2.0.dylib" "$d/libLibreSCRS_$c.$s.dylib"; done
        ln -sf "libLibreSCRS_$c.$1.dylib" "$d/libLibreSCRS_$c.dylib"
    done
}
check() { # <label> <want-rc> <want-stdout> <helper> <prefix>
    local label="$1" wrc="$2" wout="$3" h="$4" p="$5" out rc
    if [ "$wrc" != 0 ]; then red=$((red + 1)); fi
    out="$("$h" "$p" 2>/dev/null)"; rc=$?
    if [ "$rc" = "$wrc" ] && [ "$out" = "$wout" ]; then
        echo "  ok    $label (rc=$rc out='$out')"; pass=$((pass+1))
    else
        echo "  FAIL  $label: want rc=$wrc out='$wout', got rc=$rc out='$out'"; fail=$((fail+1))
    fi
}

mkprefix "$WORK/five" 5   ; check "5.0 prefix -> 5"            0 5  "$HELPER" "$WORK/five"
mkprefix "$WORK/four" 4   ; check "4.x prefix -> 4 (no rot)"   0 4  "$HELPER" "$WORK/four"
mkdir -p "$WORK/empty"    ; check "empty prefix -> error"      1 "" "$HELPER" "$WORK/empty"
mkprefix "$WORK/dirty" 4 5; check "prefix reused across bump"  1 "" "$HELPER" "$WORK/dirty"
check "missing prefix -> error" 1 "" "$HELPER" "$WORK/nope"

# No argument at all is a usage error (2), not a measurement (1): a caller that
# forgot the prefix has not been told anything about a prefix.
out="$("$HELPER" 2>/dev/null)"; rc=$?
red=$((red + 1))
if [ "$rc" = 2 ] && [ -z "$out" ]; then
    echo "  ok    no argument -> usage (rc=$rc)"; pass=$((pass+1))
else
    echo "  FAIL  no argument: want rc=2 out='', got rc=$rc out='$out'"; fail=$((fail+1))
fi

# Perturbation: make the helper pick one soname instead of refusing. The dirty
# case MUST stop passing; if it still passes, this suite proves nothing.
sed 's/| sort -un)"/| sort -un | head -1)"/' "$HELPER" > "$WORK/blunt.sh"
chmod +x "$WORK/blunt.sh"
if ! cmp -s "$HELPER" "$WORK/blunt.sh"; then
    out="$("$WORK/blunt.sh" "$WORK/dirty" 2>/dev/null)"; rc=$?
    if [ "$rc" = 0 ]; then
        echo "  ok    perturbation: a head -1 helper accepts the reused prefix (rc=0 out='$out'), so the case above is real"
        pass=$((pass+1))
    else
        echo "  FAIL  perturbation had no effect — the dirty case does not test what it claims"
        fail=$((fail+1))
    fi
else
    echo "  FAIL  perturbation edited nothing — the sed no longer matches the helper"
    fail=$((fail+1))
fi

echo "lm-soname.selftest: $pass passed, $fail failed"
printf 'selftest: %s cases, %s red-proved\n' "$((pass + fail))" "$red"
[ "$fail" -eq 0 ]
