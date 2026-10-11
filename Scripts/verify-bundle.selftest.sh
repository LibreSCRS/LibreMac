#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# selftest-platforms: darwin  (dyld library validation exists only on macOS)
# SPDX-FileCopyrightText: 2026 hirashix0
#
# Drives the agent smoke in verify-bundle.sh over a fixture bundle: a tiny
# executable named librescrs-agent that links one @rpath dylib from
# Contents/Frameworks and exits 2 on any argument, like the real agent on an
# unknown one. Signed ad hoc with the hardened runtime and no
# disable-library-validation, dyld refuses the dylib (no Team ID to match) and
# the process dies with 134 -- the defect a release image shipped. Only the
# smoke line is judged; the fixture fails every other assertion by design.
set -uo pipefail
export LC_ALL=C

here="$(cd "$(dirname "$0")" && pwd)"
verify="$here/verify-bundle.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

pass=0 fail=0 red=0

cat > "$work/fix.c" <<'C'
int librescrs_fixture(void) { return 0; }
C
cat > "$work/main2.c" <<'C'
int librescrs_fixture(void);
int main(int argc, char **argv) { (void)argv; return librescrs_fixture() + (argc > 1 ? 2 : 0); }
C
cat > "$work/main1.c" <<'C'
int librescrs_fixture(void);
int main(int argc, char **argv) { (void)argv; return librescrs_fixture() + (argc > 1 ? 1 : 0); }
C
cat > "$work/dlv.plist" <<'P'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.cs.disable-library-validation</key><true/>
</dict></plist>
P
# A Command Line Tools SDK can carry .tbd files the linker cannot parse
# ("unknown architecture arm64e.x1"); fall back to the full Xcode SDK then.
if ! echo 'int x;' | cc -x c -dynamiclib -o "$work/probe.dylib" - 2>/dev/null; then
    SDKROOT="$(DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun --sdk macosx --show-sdk-path 2>/dev/null)" && export SDKROOT
fi
cc -dynamiclib -o "$work/libfix.dylib" -install_name @rpath/libfix.dylib "$work/fix.c" || { echo "cannot build the fixture dylib"; exit 2; }

# make_app <name> <main.c> <entitlements|-> -> $work/<name>.app
make_app() {
    local app="$work/$1.app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks"
    cp "$work/libfix.dylib" "$app/Contents/Frameworks/"
    cc -o "$app/Contents/MacOS/librescrs-agent" "$work/$2" -L"$work" -lfix \
        -Wl,-rpath,@executable_path/../Frameworks || return 1
    codesign --force -s - --options runtime --timestamp=none "$app/Contents/Frameworks/libfix.dylib" || return 1
    if [ "$3" = - ]; then
        codesign --force -s - --options runtime --timestamp=none "$app/Contents/MacOS/librescrs-agent"
    else
        codesign --force -s - --options runtime --timestamp=none --entitlements "$3" "$app/Contents/MacOS/librescrs-agent"
    fi
}

smoke_line() { bash "$1" "$2" 2>&1 | grep -E '^(PASS|FAIL): librescrs-agent smoke' | head -1; }

# expect <name> <PASS|FAIL> <regex> <red?> <verify script>
expect() {
    local line
    line="$(smoke_line "$5" "$work/$1.app")"
    if [[ "$line" == "$2:"* ]] && echo "$line" | grep -qE "$3"; then
        echo "  ok    $1: $line"; pass=$((pass+1)); [ "$4" = red ] && red=$((red+1))
    else
        echo "  FAIL  $1: wanted $2 matching /$3/, got '$line'"; fail=$((fail+1))
    fi
}

make_app nodlv main2.c - || { echo "cannot build the fixture"; exit 2; }
make_app dlv main2.c "$work/dlv.plist" || exit 2
make_app exit1 main1.c "$work/dlv.plist" || exit 2
mkdir -p "$work/noagent.app/Contents/MacOS"

# Library validation is a kernel policy, and with System Integrity Protection
# off it is not enforced: the hosted macOS runners run with SIP disabled, and
# there the same fixture starts and exits 2. The defect cannot show on such a
# host, so the case is not judged there and says so; a Mac with SIP on judges it.
if csrutil status 2>/dev/null | grep -q 'status: enabled'; then
    expect nodlv FAIL 'exit 134.*different Team IDs' red "$verify"
else
    echo "  skip  nodlv: System Integrity Protection is not enabled here, so dyld does not enforce library validation"
fi
expect dlv PASS 'exited 2' green "$verify"
expect exit1 FAIL 'exit 1, wanted 2' red "$verify"
expect noagent FAIL 'not present' red "$verify"

# Perturbation: a smoke that accepts any exit must turn a wrong exit green, or
# the cases above are not testing the comparison. Over exit1, which is red on
# every host, SIP on or off.
sed 's/smoke_rc" -eq 2 \]/smoke_rc" -ge 0 ]/' "$verify" > "$work/verify-perturbed.sh"
if cmp -s "$verify" "$work/verify-perturbed.sh"; then
    echo "  FAIL  perturbation edited nothing -- the sed no longer matches verify-bundle.sh"; fail=$((fail+1))
else
    line="$(smoke_line "$work/verify-perturbed.sh" "$work/exit1.app")"
    if [[ "$line" == PASS:* ]]; then
        echo "  ok    perturbation: an any-exit smoke passes exit 1, so the comparison is what judges"; pass=$((pass+1))
    else
        echo "  FAIL  perturbation had no effect: '$line'"; fail=$((fail+1))
    fi
fi

echo "verify-bundle.selftest: $pass passed, $fail failed"
printf 'selftest: %s cases, %s red-proved\n' "$((pass + fail))" "$red"
[ "$fail" -eq 0 ]
