#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# check-test-floor.sh -- the Xcode test action must have run the tests.
#
# Why: `xcodebuild test` prints `Executed 0 tests` and `** TEST SUCCEEDED **`
# on every healthy run of this scheme, because its tests are Swift Testing and
# that line is XCTest's counter. A bundle that ran nothing -- a target dropped
# from the scheme, a test file no longer in `sources:`, a filter left behind --
# exits 0 with exactly the same output. So the step was green whatever ran.
#
# Property: the result bundle's own count. `xcresulttool get test-results
# summary` (Xcode 16 and later; `get test-report` does not exist on 26.5) is
# read, and the run passes only when
#
#     failedTests == 0  and  skippedTests == 0  and  expectedFailures == 0
#     and  totalTestCount >= the floor in ci/test-floor.macos.txt
#
# A skip counts against the run: this scheme has no environment-gated tests,
# and a skip that appears is a test that stopped running while staying green.
#
# The floor may only rise, unless a commit names the lowering. The floor file
# at HEAD is compared with the one at the BASE of the change -- --base <sha>,
# which CI sets to the push's `before` or the pull request's base, so a
# lowering anywhere in a multi-commit push is seen, not only one in its last
# commit. A lower floor passes only when a commit in <base>..HEAD carries the
# trailer
#
#     Test-Floor-Lowered: <reason>
#
# with a non-empty reason; deleting tests on purpose is then a decision the
# history records, not an edit to this script.
#
#   --base 000...0   (a push that created the branch) -> the merge-base of HEAD
#                    and --default-ref (default origin/main); none is rc=2
#   --base ''        (CI could not name one)          -> rc=2
#   --base <sha> this checkout cannot reach           -> rc=2
#   no --base        (a local run)                    -> HEAD~1; a shallow
#                    checkout without it is rc=2, a full-history root commit
#                    has no previous floor
#
# A base without the floor file has no previous floor (the file is new).
#
# Fallback, only when the summary cannot be obtained or read: the xcodebuild
# log given with --log. Swift Testing's `Test run with N tests` lines plus
# XCTest's `Executed N tests` line under `Test Suite 'All tests'`; a failed
# run, a failing XCTest count or a `Test ... skipped` line is red, and a log
# with no count line at all is rc=2. It warns that it was used.
#
# Usage:
#   check-test-floor.sh (--xcresult <bundle> | --summary <json>) [--log <file>]
#                       [--base <sha> [--default-ref <ref>]]
#
# Run from inside the repository. Exit: 0 pass, 1 judged and failed,
# 2 cannot judge (never a pass).
#
# bash 3.2 on purpose (a macOS runner's /bin/bash): no mapfile, no
# associative arrays. JSON is read with python3.
set -u

usage() {
    echo "usage: check-test-floor.sh (--xcresult <bundle> | --summary <json>) [--log <file>] [--base <sha> [--default-ref <ref>]]" >&2
    exit 2
}
cannot() { echo "::error::check-test-floor: cannot judge -- $*" >&2; exit 2; }
fail=0
bad() { echo "::error::check-test-floor: $*" >&2; fail=1; }

xcresult=""; summary=""; log=""; floor_path="ci/test-floor.macos.txt"
base=""; base_given=0; default_ref="origin/main"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --xcresult) [ "$#" -ge 2 ] || usage; xcresult=$2; shift 2 ;;
        --summary)  [ "$#" -ge 2 ] || usage; summary=$2;  shift 2 ;;
        --log)      [ "$#" -ge 2 ] || usage; log=$2;      shift 2 ;;
        --base)     [ "$#" -ge 2 ] || usage; base=$2; base_given=1; shift 2 ;;
        --default-ref) [ "$#" -ge 2 ] || usage; default_ref=$2; shift 2 ;;
        *) usage ;;
    esac
done
[ -n "$xcresult" ] || [ -n "$summary" ] || usage
[ -n "$xcresult" ] && [ -n "$summary" ] && usage

command -v python3 >/dev/null 2>&1 || cannot "python3 is not on PATH"
top=$(git rev-parse --show-toplevel 2>/dev/null) || cannot "not inside a git checkout"

# ---- the floor ---------------------------------------------------------------
parse_floor() {  # stdin: a floor file -> stdout: its one number, or nothing
    # Exactly one non-comment, non-blank line, and it is a positive integer.
    awk '/^[[:space:]]*(#|$)/ { next }
         { n++; v = $0 }
         END { gsub(/[[:space:]]/, "", v)
               if (n == 1 && v ~ /^[0-9]+$/ && v + 0 > 0) print v + 0 }'
}
[ -f "$top/$floor_path" ] || cannot "no floor file at $floor_path"
floor=$(parse_floor < "$top/$floor_path")
[ -n "$floor" ] || cannot "$floor_path must hold exactly one positive integer"

if [ "$base_given" = 1 ]; then
    [ -n "$base" ] || cannot "--base is empty: the workflow did not name the commit this change is measured against"
    if printf '%s\n' "$base" | grep -Eq '^0+$'; then
        mb=$(git -C "$top" merge-base HEAD "$default_ref" 2>/dev/null) \
            || cannot "--base is all zeros (a new branch) and HEAD has no merge-base with $default_ref"
        echo "  -> --base is all zeros: measuring against the merge-base $mb with $default_ref"
        base=$mb
    fi
    git -C "$top" rev-parse --verify -q "$base^{commit}" >/dev/null \
        || cannot "--base $base is not a commit this checkout can reach, so a lowered floor could not be seen"
    base=$(git -C "$top" rev-parse --verify -q "$base^{commit}")
elif git -C "$top" rev-parse --verify -q 'HEAD~1^{commit}' >/dev/null; then
    base=$(git -C "$top" rev-parse --verify -q 'HEAD~1^{commit}')
elif [ "$(git -C "$top" rev-parse --is-shallow-repository)" != false ]; then
    cannot "HEAD~1 is not reachable in this shallow checkout, so a lowered floor could not be seen"
else
    echo "  -> HEAD is a root commit: no previous floor to compare"
fi

if [ -n "$base" ]; then
    if git -C "$top" cat-file -e "$base:$floor_path" 2>/dev/null; then
        prev=$(git -C "$top" show "$base:$floor_path" | parse_floor)
        [ -n "$prev" ] || cannot "$floor_path at $base does not hold one positive integer"
        if [ "$floor" -lt "$prev" ]; then
            # Every commit the change brings, not only the last: the trailer
            # may sit on the commit that deleted the tests.
            reasons=$(git -C "$top" log --format='%(trailers:key=Test-Floor-Lowered,valueonly)' \
                        "$base..HEAD") \
                || cannot "git log $base..HEAD failed -- cannot look for the commit naming the lowering"
            # A git too old for the placeholder prints it back verbatim, which
            # would read as a reason.
            case "$reasons" in *'%(trailers'*) cannot "this git does not expand %(trailers:...)";; esac
            reasons=$(printf '%s\n' "$reasons" | grep '[^[:space:]]')
            if [ -n "$reasons" ]; then
                echo "  -> $floor_path lowers the floor from $prev to $floor, named in $base..HEAD:"
                printf '%s\n' "$reasons" | sed 's/^/       Test-Floor-Lowered: /'
            else
                bad "$floor_path lowers the floor from $prev to $floor since $base, and no commit in that range carries a 'Test-Floor-Lowered: <reason>' trailer (an empty reason does not count)"
            fi
        else
            echo "  -> floor $floor, was $prev at $base"
        fi
    else
        echo "  -> $floor_path does not exist at $base: no previous floor to compare"
    fi
fi

# ---- the count ---------------------------------------------------------------
tmp=$(mktemp -d "${TMPDIR:-/var/tmp}/check-test-floor.XXXXXX") || cannot "no temporary directory"
trap 'rm -rf "$tmp"' EXIT

if [ -n "$xcresult" ]; then
    [ -d "$xcresult" ] || cannot "no result bundle at $xcresult"
    summary="$tmp/summary.json"
    if ! xcrun xcresulttool get test-results summary --path "$xcresult" --format json \
            > "$summary" 2> "$tmp/xcrun.err"; then
        echo "::warning::check-test-floor: xcresulttool could not read $xcresult:" >&2
        sed 's/^/    /' "$tmp/xcrun.err" >&2
        summary="$tmp/absent.json"
    fi
fi

# Prints "total passed failed skipped expected" or exits non-zero when the
# summary is missing, not JSON, lacks a field, carries a non-integer, or its
# parts do not add up to its total -- each of which is "cannot judge".
counts=$(python3 - "$summary" 2>"$tmp/py.err" <<'EOF'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    sys.exit("unreadable summary: %s" % e)
keys = ["totalTestCount", "passedTests", "failedTests", "skippedTests", "expectedFailures"]
v = []
for k in keys:
    x = d.get(k) if isinstance(d, dict) else None
    if type(x) is not int or x < 0:
        sys.exit("summary field %s is %r, not a count" % (k, x))
    v.append(x)
if sum(v[1:]) != v[0]:
    sys.exit("summary parts %r do not add up to totalTestCount %d" % (v[1:], v[0]))
print(" ".join(str(x) for x in v))
EOF
) || counts=""

if [ -n "$counts" ]; then
    set -- $counts
    total=$1; failed=$3; skipped=$4; expected=$5
    echo "  -> result bundle: $total tests ($2 passed, $failed failed, $skipped skipped, $expected expected failures); floor $floor"
elif [ -n "$log" ]; then
    echo "::warning::check-test-floor: summary unusable ($(tr '\n' ' ' < "$tmp/py.err")); falling back to the xcodebuild log" >&2
    [ -f "$log" ] || cannot "no summary and no log at $log"
    counts=$(awk '
        # Swift Testing: one line per run, e.g.
        #   ✔ Test run with 134 tests in 16 suites passed after 0.593 seconds.
        #   ✘ Test run with 3 tests in 0 suites failed after 0.001 seconds with 1 issue.
        /Test run with [0-9]+ tests? / {
            s = $0; sub(/.*Test run with /, "", s); split(s, a, " ")
            total += a[1]; seen = 1
            if ($0 ~ / failed after /) failed++
            next
        }
        # Swift Testing skip: "➜ Test name() skipped." / "... skipped: \"reason\"".
        # Anchored at the end so a test whose NAME says "skipped" is not one.
        /Test .* skipped(\.|: .*)$/ && $0 !~ / (started|passed after .*)\.$/ { skipped++; next }
        # XCTest: the count that follows the top-level suite line.
        /^Test Suite .All tests. (passed|failed) at / { alltests = 1; next }
        alltests && /Executed [0-9]+ tests?, with / {
            s = $0; sub(/.*Executed /, "", s); split(s, a, " "); total += a[1]; seen = 1
            if (s ~ / with [0-9]+ tests? skipped/) {
                t = s; sub(/.* with /, "", t); split(t, b, " "); skipped += b[1]
            }
            f = s; sub(/.*tests?(, with [0-9]+ tests? skipped and|, with) /, "", f); split(f, c, " ")
            if (c[1] + 0 > 0) failed++
            alltests = 0; next
        }
        END { if (seen) printf "%d %d %d\n", total, failed + 0, skipped + 0 }
    ' "$log")
    [ -n "$counts" ] || cannot "no summary, and $log holds no test-count line"
    set -- $counts
    total=$1; failed=$2; skipped=$3; expected=0
    echo "  -> xcodebuild log: $total tests ($failed failed runs, $skipped skipped); floor $floor"
else
    cannot "$(tr '\n' ' ' < "$tmp/py.err")"
fi

[ "$failed" -eq 0 ]   || bad "$failed test(s) or run(s) failed"
[ "$skipped" -eq 0 ]  || bad "$skipped test(s) skipped -- a skipped test is one that stopped running"
[ "$expected" -eq 0 ] || bad "$expected expected failure(s) -- a known failure is not an executed pass"
if [ "$total" -lt "$floor" ]; then
    bad "the test action executed $total tests, below the floor of $floor in $floor_path"
fi

[ "$fail" -eq 0 ] && echo "  -> OK: $total tests executed, none failed or skipped, floor $floor"
exit "$fail"
