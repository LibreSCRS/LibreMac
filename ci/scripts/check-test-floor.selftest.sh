#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Selftest for check-test-floor.sh.
#
# The shape this exists for: xcodebuild printed `Executed 0 tests` and
# `** TEST SUCCEEDED **`, and the step was green. The Xcode scheme's tests are
# Swift Testing, which XCTest's own counter never sees, so that line reads 0 on
# every healthy run too -- a test bundle that ran nothing looked exactly like
# one that ran everything.
#
# Every case runs the gate inside a throwaway git repository, because the
# "the floor may only rise" rule reads the previous commit. The summary
# fixture is a real `xcresulttool get test-results summary` output (device id
# blanked); every red variant is derived from it here, so a field rename in the
# fixture breaks the green case rather than silently greening the red ones.
#
# Portable on purpose: BSD and GNU tools, bash 3.2 -- no `sed -i`, no mapfile,
# no associative arrays. It runs on the ubuntu lint job and on a Mac.
set -u

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
subject="$here/check-test-floor.sh"
fixtures="$here/../fixtures/test-floor"
[ -f "$subject" ] || { echo "missing subject: $subject" >&2; exit 2; }
[ -f "$fixtures/summary.json" ] || { echo "missing fixture: $fixtures/summary.json" >&2; exit 2; }
[ -f "$fixtures/xcodebuild-test.log" ] || { echo "missing fixture: $fixtures/xcodebuild-test.log" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is not on PATH -- cannot build the fixtures" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "git is not on PATH -- cannot build the fixtures" >&2; exit 2; }

work=$(mktemp -d "${TMPDIR:-/var/tmp}/check-test-floor.XXXXXX") || exit 2
trap 'rm -rf "$work"' EXIT

g() { git -c user.name=selftest -c user.email=selftest@invalid -c commit.gpgsign=false \
        -c init.defaultBranch=main "$@"; }

floor_text() {  # floor_text <n>: a floor file as the repository writes it
    printf '# measured floor\n%s\n' "$1"
}

# repo <dir> <floor-at-HEAD~1 | none | absent> <floor-at-HEAD>
#   none   -- HEAD is a root commit (no parent at all)
#   absent -- HEAD~1 exists but carries no floor file
repo() {
    r=$1; prev=$2; cur=$3
    mkdir -p "$r/ci" && g init -q "$r" || return 1
    if [ "$prev" != none ]; then
        if [ "$prev" = absent ]; then
            printf 'x\n' > "$r/README"
            g -C "$r" add README
        else
            floor_text "$prev" > "$r/ci/test-floor.macos.txt"
            g -C "$r" add ci/test-floor.macos.txt
        fi
        g -C "$r" commit -q -m previous || return 1
    fi
    floor_text "$cur" > "$r/ci/test-floor.macos.txt"
    g -C "$r" add ci/test-floor.macos.txt
    g -C "$r" commit -q --allow-empty -m current || return 1
}

# summary <out> <python statements over d>: derive a summary from the fixture
summary() {
    python3 - "$fixtures/summary.json" "$1" "$2" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
exec(sys.argv[3])
open(sys.argv[2], "w").write(json.dumps(d))
EOF
}

fails=0
cases=0
red=0
run() {   # run <name> <expected-rc> <dir> [args...]
    name=$1; want=$2; dir=$3; shift 3
    cases=$((cases + 1))
    # red-proved: a case in which the gate returned non-zero on a perturbed input.
    if [ "$want" != 0 ]; then red=$((red + 1)); fi
    ( cd "$dir" && bash "$subject" "$@" ) > "$work/out" 2>&1
    got=$?
    if [ "$got" -eq "$want" ]; then
        printf '  ok    %-60s rc=%s\n' "$name" "$got"
    else
        printf '  FAIL  %-60s rc=%s want=%s\n' "$name" "$got" "$want"
        sed 's/^/          /' "$work/out"
        fails=$((fails + 1))
    fi
}

S="$work/s"; mkdir -p "$S"
cp "$fixtures/summary.json" "$S/real.json"
summary "$S/zero.json"     'd["totalTestCount"]=0; d["passedTests"]=0'
summary "$S/skipped.json"  'd["skippedTests"]=1; d["passedTests"]-=1'
summary "$S/failed.json"   'd["failedTests"]=1; d["passedTests"]-=1; d["result"]="Failed"'
summary "$S/below.json"    'd["totalTestCount"]-=1; d["passedTests"]-=1'
summary "$S/noskip.json"   'del d["skippedTests"]'
summary "$S/nototal.json"  'del d["totalTestCount"]'
summary "$S/strtotal.json" 'd["totalTestCount"]=str(d["totalTestCount"])'
summary "$S/incons.json"   'd["totalTestCount"]+=5'
summary "$S/expfail.json"  'd["expectedFailures"]=1; d["passedTests"]-=1'
printf 'not json\n' > "$S/garbage.json"
N=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["totalTestCount"])' "$fixtures/summary.json")
[ "$N" -gt 1 ] 2>/dev/null || { echo "fixture total is '$N' -- cannot build the cases" >&2; exit 2; }

L="$work/l"; mkdir -p "$L"
cp "$fixtures/xcodebuild-test.log" "$L/real.log"
# The classic false green, verbatim shape: XCTest's counter and the success banner.
printf "Test Suite 'All tests' started at 2026-01-01 00:00:00.000.\nTest Suite 'All tests' passed at 2026-01-01 00:00:00.001.\n\t Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.001) seconds\n\n** TEST SUCCEEDED **\n" > "$L/zero.log"
printf '** TEST SUCCEEDED **\n' > "$L/nocount.log"
# Line shapes measured from `swift test` with a disabled and a failing test.
{ cat "$L/real.log"; printf '\xe2\x9e\x9c Test skippedOne() skipped: "no hw"\n'; } > "$L/skipped.log"
{ cat "$L/real.log"; printf '\xe2\x9e\x9c Test skippedTwo() skipped.\n'; } > "$L/skipped-noreason.log"
sed 's/Test run with \([0-9]*\) tests in \([0-9]*\) suites passed after 0.593 seconds\./Test run with \1 tests in \2 suites failed after 0.593 seconds with 1 issue./' \
    "$L/real.log" > "$L/failed.log"
grep -q 'suites failed after' "$L/failed.log" || { echo "could not derive the failed log" >&2; exit 2; }
# An XCTest bundle with a real count, next to the Swift Testing run.
{ printf "Test Suite 'All tests' passed at 2026-01-01 00:00:00.001.\n\t Executed 3 tests, with 0 failures (0 unexpected) in 0.000 (0.001) seconds\n"; \
  sed "s/Test run with $N tests/Test run with $((N - 3)) tests/" "$L/real.log"; } > "$L/mixed.log"
# XCTest prints the same count once per nesting level; only the 'All tests'
# line is the run. Counted three times, N-1 would read as N+5 and pass.
{ printf "Test Suite 'FooTests' passed at 2026-01-01 00:00:00.001.\n\t Executed 3 tests, with 0 failures (0 unexpected) in 0.000 (0.001) seconds\n"; \
  printf "Test Suite 'LibreMacTests.xctest' passed at 2026-01-01 00:00:00.001.\n\t Executed 3 tests, with 0 failures (0 unexpected) in 0.000 (0.001) seconds\n"; \
  printf "Test Suite 'All tests' passed at 2026-01-01 00:00:00.001.\n\t Executed 3 tests, with 0 failures (0 unexpected) in 0.000 (0.001) seconds\n"; \
  sed "s/Test run with $N tests/Test run with $((N - 4)) tests/" "$L/real.log"; } > "$L/nested.log"
{ printf "Test Suite 'All tests' failed at 2026-01-01 00:00:00.001.\n\t Executed 3 tests, with 1 failure (1 unexpected) in 0.000 (0.001) seconds\n"; \
  cat "$L/real.log"; } > "$L/xctest-failed.log"

# A stub xcrun that answers only the exact subcommand the gate is meant to
# use, so the case proves the gate asks for `get test-results summary`.
B="$work/bin"; mkdir -p "$B"
cat > "$B/xcrun" <<'EOF'
#!/bin/sh
[ "$1 $2 $3 $4 $5" = "xcresulttool get test-results summary --path" ] || { echo "stub: unexpected: $*" >&2; exit 64; }
[ "$7 $8" = "--format json" ] || { echo "stub: unexpected: $*" >&2; exit 64; }
[ -n "${STUB_SUMMARY:-}" ] || { echo "stub: no summary" >&2; exit 1; }
cat "$STUB_SUMMARY"
EOF
chmod +x "$B/xcrun"
mkdir -p "$work/bundle.xcresult"

# ---- the count, from the summary ---------------------------------------------
d=$work/r_eq; repo "$d" "$N" "$N"
run "c01 real summary at the floor"                              0 "$d" --summary "$S/real.json"
run "c02 zero tests executed"                                    1 "$d" --summary "$S/zero.json"
run "c03 one test skipped"                                       1 "$d" --summary "$S/skipped.json"
run "c04 one test failed"                                        1 "$d" --summary "$S/failed.json"
run "c05 one test below the floor"                               1 "$d" --summary "$S/below.json"
run "c06 an expected failure is not an executed pass"            1 "$d" --summary "$S/expfail.json"

# ---- a summary that cannot be judged is rc=2, never a pass -------------------
run "c07 summary file missing, no log"                           2 "$d" --summary "$S/nope.json"
run "c08 summary not JSON, no log"                               2 "$d" --summary "$S/garbage.json"
run "c09 summary without skippedTests"                           2 "$d" --summary "$S/noskip.json"
run "c10 summary without totalTestCount"                         2 "$d" --summary "$S/nototal.json"
run "c11 totalTestCount is a string"                             2 "$d" --summary "$S/strtotal.json"
run "c12 counts do not add up to the total"                      2 "$d" --summary "$S/incons.json"
run "c13 no arguments"                                           2 "$d"

# ---- the floor file ----------------------------------------------------------
d=$work/r_nofloor; mkdir -p "$d"; g init -q "$d"; printf 'x\n' > "$d/README"; g -C "$d" add README; g -C "$d" commit -q -m one
run "c14 floor file missing"                                     2 "$d" --summary "$S/real.json"
d=$work/r_badfloor; repo "$d" "$N" "lots"
run "c15 floor file is not a number"                             2 "$d" --summary "$S/real.json"
d=$work/r_zerofloor; repo "$d" 0 0
run "c16 a floor of zero measures nothing"                       2 "$d" --summary "$S/real.json"
d=$work/r_twofloor; repo "$d" "$N" "$N"; printf '%s\n' "$N" >> "$d/ci/test-floor.macos.txt"
run "c17 floor file with two numbers"                            2 "$d" --summary "$S/real.json"

# ---- the floor may only rise -------------------------------------------------
d=$work/r_lowered; repo "$d" "$N" $((N - 10))
run "c18 floor lowered against HEAD~1"                           1 "$d" --summary "$S/real.json"
d=$work/r_raised; repo "$d" $((N - 10)) "$N"
run "c19 floor raised against HEAD~1"                            0 "$d" --summary "$S/real.json"
d=$work/r_absent; repo "$d" absent "$N"
run "c20 HEAD~1 carries no floor file (it is being introduced)"  0 "$d" --summary "$S/real.json"
d=$work/r_root; repo "$d" none "$N"
run "c21 root commit, full history: nothing to compare"          0 "$d" --summary "$S/real.json"
d=$work/r_prevbad; repo "$d" "junk" "$N"
run "c22 HEAD~1's floor file is unreadable"                      2 "$d" --summary "$S/real.json"
src=$work/r_shallow_src; repo "$src" "$N" "$N"
d=$work/r_shallow; git clone -q --depth 1 "file://$src" "$d" 2>/dev/null
[ "$(git -C "$d" rev-parse --is-shallow-repository)" = true ] || { echo "could not build a shallow clone" >&2; exit 2; }
run "c23 depth-1 checkout: HEAD~1 unreachable"                   2 "$d" --summary "$S/real.json"
d=$work/r_shallow2; git clone -q --depth 2 "file://$src" "$d" 2>/dev/null
run "c24 depth-2 checkout (what CI fetches): judged"             0 "$d" --summary "$S/real.json"
d=$work/r_shallow3; repo "$work/r_shallow3_src" "$N" $((N - 1)); git clone -q --depth 2 "file://$work/r_shallow3_src" "$d" 2>/dev/null
run "c25 depth-2 checkout, floor lowered"                        1 "$d" --summary "$S/real.json"

# ---- the base of the change and the named lowering ---------------------------
# step <repo> <floor|-> <message>: one commit; `-` touches only README.
step() {
    if [ "$2" = - ]; then printf '%s\n' "$3" >> "$1/README"; g -C "$1" add README
    else floor_text "$2" > "$1/ci/test-floor.macos.txt"; g -C "$1" add ci/test-floor.macos.txt; fi
    g -C "$1" commit -q -m "$3" || return 1
}
chain() {  # chain <repo>: main at floor N, the base every case below measures from
    mkdir -p "$1/ci" && g init -q "$1" && step "$1" "$N" "base" && g -C "$1" tag base
}
TR='Test-Floor-Lowered'

# Three commits after the base; the MIDDLE one lowers, the last touches nothing.
d=$work/b_mid; chain "$d"; step "$d" - one; step "$d" $((N - 10)) "drop tests"; step "$d" - three
run "c42 lowered mid-push, later commit untouched, --base: red"  1 "$d" --summary "$S/real.json" --base "$(g -C "$d" rev-parse base)"
# Without --base (a local run) the base is HEAD~1, which already carries the
# lowered number -- green, and exactly why CI always passes --base.
run "c43 same tree, no --base: HEAD~1 is the base (local mode)"  0 "$d" --summary "$S/real.json"

d=$work/b_named; chain "$d"; step "$d" - one
step "$d" $((N - 10)) "$(printf 'drop tests\n\n%s: the legacy reader and its tests are gone' "$TR")"; step "$d" - three
run "c44 lowered, a commit in the range names it: green"         0 "$d" --summary "$S/below.json" --base "$(g -C "$d" rev-parse base)"
d=$work/b_empty; chain "$d"; step "$d" $((N - 10)) "$(printf 'drop tests\n\n%s:' "$TR")"
run "c45 lowered, trailer with an empty reason: red"             1 "$d" --summary "$S/real.json" --base "$(g -C "$d" rev-parse base)"
d=$work/b_body; chain "$d"; step "$d" $((N - 10)) "$(printf 'drop tests\n\n%s: in the body\n\nnot a trailer paragraph' "$TR")"
run "c46 lowered, the key only in the body, not a trailer: red"  1 "$d" --summary "$S/real.json" --base "$(g -C "$d" rev-parse base)"
# A trailer on a commit BEFORE the base belongs to an earlier lowering.
d=$work/b_before; mkdir -p "$d/ci"; g init -q "$d"; step "$d" $((N + 10)) "$(printf 'old\n\n%s: an earlier decision' "$TR")"
step "$d" "$N" "$(printf 'lower once\n\n%s: an earlier decision' "$TR")"; g -C "$d" tag base; step "$d" $((N - 10)) "drop tests"
run "c47 a trailer before the base does not excuse this range"  1 "$d" --summary "$S/real.json" --base "$(g -C "$d" rev-parse base)"
d=$work/b_raise; chain "$d"; step "$d" - one; step "$d" - two
run "c48 --base, floor unchanged: green"                         0 "$d" --summary "$S/real.json" --base "$(g -C "$d" rev-parse base)"

# All-zeros base: a push that created the branch -> the merge-base with the
# default ref.
Z=0000000000000000000000000000000000000000
d=$work/b_zero; chain "$d"; g -C "$d" checkout -q -b feature; step "$d" - one; step "$d" $((N - 10)) "drop tests"
run "c49 zeros base, merge-base with main sees the lowering"     1 "$d" --summary "$S/real.json" --base "$Z" --default-ref main
d=$work/b_zero_ok; chain "$d"; g -C "$d" checkout -q -b feature; step "$d" - one
run "c50 zeros base, merge-base with main, floor kept: green"    0 "$d" --summary "$S/real.json" --base "$Z" --default-ref main
run "c51 zeros base, default ref does not resolve"               2 "$d" --summary "$S/real.json" --base "$Z" --default-ref origin/nope
d=$work/b_orphan; chain "$d"; g -C "$d" checkout -q --orphan other; step "$d" "$N" orphan
run "c52 zeros base, no merge-base with the default ref"         2 "$d" --summary "$S/real.json" --base "$Z" --default-ref main
d=$work/b_named
run "c53 base this checkout cannot reach"                        2 "$d" --summary "$S/real.json" --base 1234567890abcdef1234567890abcdef12345678
run "c54 base given but empty"                                   2 "$d" --summary "$S/real.json" --base ""
# A shallow clone that cannot reach the pushed-over commit is rc=2, not a pass.
d=$work/b_shallow; git clone -q --depth 1 "file://$work/b_mid" "$d" 2>/dev/null
run "c55 depth-1 checkout, --base is the unfetched before"       2 "$d" --summary "$S/real.json" --base "$(g -C "$work/b_mid" rev-parse base)"

# ---- the fallback: the xcodebuild log ----------------------------------------
d=$work/r_eq
run "c26 real log: Test run with N tests, Executed 0 is noise"   0 "$d" --summary "$S/nope.json" --log "$L/real.log"
run "c27 log with only Executed 0 tests + TEST SUCCEEDED"        1 "$d" --summary "$S/nope.json" --log "$L/zero.log"
run "c28 log with no count at all"                               2 "$d" --summary "$S/nope.json" --log "$L/nocount.log"
run "c29 log: a skipped test with a reason"                      1 "$d" --summary "$S/nope.json" --log "$L/skipped.log"
run "c30 log: a skipped test without a reason"                   1 "$d" --summary "$S/nope.json" --log "$L/skipped-noreason.log"
run "c31 log: the Swift Testing run failed"                      1 "$d" --summary "$S/nope.json" --log "$L/failed.log"
run "c32 log: XCTest and Swift Testing counts add up"            0 "$d" --summary "$S/nope.json" --log "$L/mixed.log"
run "c33 log: an XCTest failure"                                 1 "$d" --summary "$S/nope.json" --log "$L/xctest-failed.log"
run "c34 log file missing"                                     2 "$d" --summary "$S/nope.json" --log "$L/nope.log"
# The summary wins when it is readable: a good log does not rescue a bad count.
run "c35 readable zero summary is not overridden by a good log"  1 "$d" --summary "$S/zero.json" --log "$L/real.log"
run "c41 log: nested XCTest suite counts are not summed"         1 "$d" --summary "$S/nope.json" --log "$L/nested.log"

# ---- --xcresult: the gate asks xcresulttool itself ---------------------------
# Run with the stub first on PATH; STUB_SUMMARY picks what it answers, and an
# empty one makes it fail the way a missing or corrupt bundle does.
stub_run() {  # stub_run <name> <expected-rc> <summary-or-empty> [args...]
    n=$1; w=$2; STUB_SUMMARY=$3; export STUB_SUMMARY; shift 3
    PATH="$B:$PATH" run "$n" "$w" "$d" "$@"
    unset STUB_SUMMARY
}
stub_run "c36 xcresult via xcresulttool, real summary"   0 "$S/real.json" --xcresult "$work/bundle.xcresult"
stub_run "c37 xcresult via xcresulttool, zero tests"     1 "$S/zero.json" --xcresult "$work/bundle.xcresult"
stub_run "c38 xcresulttool fails, log fallback green"    0 ""             --xcresult "$work/bundle.xcresult" --log "$L/real.log"
stub_run "c39 xcresulttool fails, no log"                2 ""             --xcresult "$work/bundle.xcresult"
stub_run "c40 xcresult bundle does not exist"            2 "$S/real.json" --xcresult "$work/none.xcresult"

if [ "$fails" -eq 0 ]; then
    echo "check-test-floor selftest: all cases passed"
    printf 'selftest: %s cases, %s red-proved\n' "$cases" "$red"
    exit 0
fi
echo "check-test-floor selftest: $fails case(s) failed"
printf 'selftest: %s cases, %s red-proved\n' "$cases" "$red"
exit 1
