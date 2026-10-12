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
#
# Also the App Group: a fixture whose Info.plist names a team and whose agent
# is signed into another group must fail verify-bundle.sh's group line naming
# both groups, and sign-bundle.sh, copied next to fixture entitlements, must
# write the one group into every component.
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
cat > "$work/main4.c" <<'C'
int librescrs_fixture(void);
int main(int argc, char **argv) { (void)argc; (void)argv; return librescrs_fixture() + 4; }
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

# app_groups_plist <file> <group>... -- entitlements: DLV plus these App Groups
app_groups_plist() {
    local f="$1" g
    shift
    cp "$work/dlv.plist" "$f"
    /usr/libexec/PlistBuddy -c "Add :com.apple.security.application-groups array" "$f" >/dev/null
    for g in "$@"; do
        /usr/libexec/PlistBuddy -c "Add :com.apple.security.application-groups: string $g" "$f" >/dev/null
    done
}
app_groups_plist "$work/in-group.plist" group.org.librescrs.LibreMac
app_groups_plist "$work/in-team.plist" ABCDE12345.org.librescrs.LibreMac
app_groups_plist "$work/in-two.plist" group.org.librescrs.LibreMac other.example

# make_app <name> <main.c> <entitlements|-> [team] -> $work/<name>.app; a team
# (possibly empty) writes Contents/Info.plist with LibreSCRSTeamID.
make_app() {
    local app="$work/$1.app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks"
    if [ "$#" -ge 4 ]; then
        plutil -create xml1 "$app/Contents/Info.plist"
        plutil -insert LibreSCRSTeamID -string "$4" "$app/Contents/Info.plist"
    fi
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

# judged_line <verify script> <app> <line prefix after PASS:/FAIL:>
judged_line() { bash "$1" "$2" 2>&1 | grep -E "^(PASS|FAIL): $3" | head -1; }
smoke_line() { judged_line "$1" "$2" 'librescrs-agent smoke'; }
group_line() { judged_line "$1" "$2" 'librescrs-agent App Group'; }

# verdict <label> <PASS|FAIL> <regex> <red?> <line>
verdict() {
    if [[ "$5" == "$2:"* ]] && echo "$5" | grep -qE "$3"; then
        echo "  ok    $1: $5"; pass=$((pass+1)); [ "$4" = red ] && red=$((red+1))
    else
        echo "  FAIL  $1: wanted $2 matching /$3/, got '$5'"; fail=$((fail+1))
    fi
}

# expect <name> <PASS|FAIL> <regex> <red?> <verify script>
expect() { verdict "$1" "$2" "$3" "$4" "$(smoke_line "$5" "$work/$1.app")"; }
# expect_group <name> <PASS|FAIL> <regex> <red?> <verify script>
expect_group() { verdict "$1 (App Group)" "$2" "$3" "$4" "$(group_line "$5" "$work/$1.app")"; }

# perturbed <name> <sed expression> <script> -> $work/<name>, or "" if the sed edited nothing
perturbed() {
    sed "$2" "$3" >"$work/$1"
    if cmp -s "$3" "$work/$1"; then
        echo "  FAIL  perturbation $1 edited nothing -- the sed no longer matches $(basename "$3")"; fail=$((fail+1))
        return 1
    fi
}

make_app nodlv main2.c - || { echo "cannot build the fixture"; exit 2; }
make_app dlv main2.c "$work/dlv.plist" || exit 2
make_app exit1 main1.c "$work/dlv.plist" || exit 2
make_app exit4 main4.c "$work/dlv.plist" || exit 2
mkdir -p "$work/noagent.app/Contents/MacOS"
make_app teamgroup main2.c "$work/in-group.plist" ABCDE12345 || exit 2
make_app teamteam main2.c "$work/in-team.plist" ABCDE12345 || exit 2
make_app noteam main2.c "$work/in-group.plist" || exit 2
make_app noteamteam main2.c "$work/in-team.plist" "" || exit 2
make_app twogroups main2.c "$work/in-two.plist" || exit 2

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
expect exit4 FAIL 'exit 4 -- the agent refused to start.*subsystem == "rs\.librescrs\.agent"' red "$verify"

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

# ---------------------------------------------------------------- App Group in verify-bundle.sh
expect_group teamgroup FAIL 'in App Group group\.org\.librescrs\.LibreMac, the team names ABCDE12345\.org\.librescrs\.LibreMac' red "$verify"
expect_group teamteam PASS 'ABCDE12345\.org\.librescrs\.LibreMac' green "$verify"
# No Info.plist at all, as every fixture above: no team, so "group.".
expect_group noteam PASS 'group\.org\.librescrs\.LibreMac' green "$verify"
expect_group noteamteam FAIL 'in App Group ABCDE12345\.org\.librescrs\.LibreMac, the team names group\.org\.librescrs\.LibreMac' red "$verify"
expect_group twogroups FAIL 'more than one' red "$verify"
expect_group dlv FAIL 'names none' red "$verify"

# Perturbations: each restores one defect, and the case that judges it must
# turn green -- a group expected regardless of the team, and a group check
# that reads only the first entry.
if perturbed verify-anyteam.sh 's/want_group="\$team\.org/want_group="group.org/' "$verify"; then
    verdict "perturbation: the team ignored" PASS '' green "$(group_line "$work/verify-anyteam.sh" "$work/teamgroup.app")"
fi
if perturbed verify-firstonly.sh 's/groups_key:1" "\$ents_plist"/groups_key:9" "$ents_plist"/' "$verify"; then
    verdict "perturbation: only the first group read" PASS '' green "$(group_line "$work/verify-firstonly.sh" "$work/twogroups.app")"
fi

# ---------------------------------------------------------------- App Group in sign-bundle.sh
# A bundle sign-bundle.sh accepts: host and token extension with executables
# and Info.plists naming no team, agent and prompter under Contents/MacOS. The
# script runs from a copy whose Packaging/entitlements/ hold fixture templates.
# make_signable <name> -> $work/<name>.app
make_signable() {
    local app="$work/$1.app" appex
    make_app "$1" main2.c - "" || return 1
    cc -o "$app/Contents/MacOS/librescrs-prompter" "$work/main2.c" -L"$work" -lfix -Wl,-rpath,@executable_path/../Frameworks || return 1
    cc -o "$app/Contents/MacOS/LibreMac" "$work/main1.c" -L"$work" -lfix -Wl,-rpath,@executable_path/../Frameworks || return 1
    plutil -insert CFBundleExecutable -string LibreMac "$app/Contents/Info.plist"
    plutil -insert CFBundleIdentifier -string org.librescrs.selftest "$app/Contents/Info.plist"
    appex="$app/Contents/PlugIns/LibreMacToken.appex"
    mkdir -p "$appex/Contents/MacOS"
    cp "$app/Contents/MacOS/LibreMac" "$appex/Contents/MacOS/LibreMacToken"
    cp "$app/Contents/Info.plist" "$appex/Contents/Info.plist"
    plutil -replace CFBundleExecutable -string LibreMacToken "$appex/Contents/Info.plist"
    plutil -replace CFBundleIdentifier -string org.librescrs.selftest.token "$appex/Contents/Info.plist"
}
# signer <name> -> $work/<name>/Scripts/sign-bundle.sh next to the real templates
signer() {
    mkdir -p "$work/$1/Scripts" "$work/$1/Packaging"
    cp "$here/sign-bundle.sh" "$work/$1/Scripts/"
    cp -R "$here/../Packaging/entitlements" "$work/$1/Packaging/"
}
ents_of() { echo "$work/$1/Packaging/entitlements"; }
signs_out="$work/sign.out"

# Green: templates whose group is a placeholder; all four components come out
# in "group." -- so the group is written, not merely carried over.
signer sign-ok
for f in "$(ents_of sign-ok)"/*.plist; do
    /usr/libexec/PlistBuddy -c "Set :com.apple.security.application-groups:0 placeholder.example" "$f"
done
make_signable signed-ok || exit 2
if bash "$work/sign-ok/Scripts/sign-bundle.sh" "$work/signed-ok.app" >"$signs_out" 2>&1; then
    lines="$(bash "$verify" "$work/signed-ok.app" 2>&1 | grep -E '^(PASS|FAIL): [^ ]+ App Group')"
    if [ "$(echo "$lines" | grep -c '^PASS: .*group\.org\.librescrs\.LibreMac')" -eq 4 ] && ! echo "$lines" | grep -q '^FAIL'; then
        echo "  ok    sign-bundle writes group.org.librescrs.LibreMac into agent, prompter, token extension and host"; pass=$((pass+1))
    else
        echo "  FAIL  sign-bundle over placeholder templates: $(echo "$lines" | tr '
' ';')"; fail=$((fail+1))
    fi
else
    echo "  FAIL  sign-bundle refused a good bundle: $(tr '
' ' ' <"$signs_out")"; fail=$((fail+1))
fi

echo "verify-bundle.selftest: $pass passed, $fail failed"
printf 'selftest: %s cases, %s red-proved\n' "$((pass + fail))" "$red"
[ "$fail" -eq 0 ]
