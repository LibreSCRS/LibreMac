#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# SPDX-FileCopyrightText: 2026 hirashix0
#
# lm-soname.selftest.sh — drive Scripts/lm-soname.sh over built prefixes, and
# check that Scripts/bundle-agent.sh actually uses it.
#
# Fixtures are named the way CMake names the real thing: the REAL file carries
# the full version triple, the soname symlink carries SOVERSION alone, and the
# unversioned link points at the soname. Some fixtures give the triple and the
# soname integer DIFFERENT numbers, tracking different events -- an ABI layout
# change, not a release. Where the fixture gives them different numbers, a
# helper reading the integer off the real file answers the wrong one; that is
# what makes those cases measure the SONAME rather than the triple. Over a
# prefix where the two agree, such a helper would answer correctly and pass.
#
# Most of the cases are not about the helper at all. One is a perturbation: it
# breaks the helper on purpose and requires the suite to notice, because "5 of 5
# passed" would also be printed by a helper that always returns the first soname
# it sees. The rest are R3, and they are the reason this file is a gate rather
# than a demonstration: a suite that only exercises the helper stays green with
# bundle-agent.sh still globbing a hard-coded integer -- the defect -- since the
# helper it tests is then simply not called by anything.
#
# Threat model. This gate catches an honest regression: bundle-agent.sh going
# back to a hard-coded soname integer, in any spelling this repository's own
# staging block is written in today, or losing the call to lm-soname.sh that
# discovers it. R3 reads bundle-agent.sh as text; R4 and R5 run it, under
# stubs for the Apple tools it shells out to, and check what got STAGED. Of
# the stubs' recorded argv R5 reads the file each tool acted on (the LAST word
# of a call, recorded_targets() below), the ORDER of the calls, and one flag:
# every codesign call must carry `--options runtime`, and the last one must be
# the host .app, with no relink and no copy after it -- anything that touches
# the bundle after the host is signed breaks the host's seal. Nothing else
# before the file is read. Known door, measured on a git-archive
# copy: an install_name_tool -change that rewrites a shipped executable's
# LC_LOAD_DYLIB entry to a WRONG soname -- stale, or fetched at runtime from
# the wrong place rather than typed as a literal integer R3a can see -- passes
# as long as the call still names the executable this suite already expects
# install_name_tool to touch. The bundle this suite inspects is a set of
# staged FILES, not the bytes any tool wrote inside them; a real Apple host's
# `otool -L` on the output is the only thing that reads those bytes today.
set -uo pipefail
export LC_ALL=C

HELPER="${1:-$(cd "$(dirname "$0")/../.." && pwd)/Scripts/lm-soname.sh}"
[ -x "$HELPER" ] || { echo "FATAL: helper not executable: $HELPER" >&2; exit 2; }

WORK="$(mktemp -d /var/tmp/lm-soname-selftest.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
# red-proved: a verdict site where the helper, the staging block or the whole
# run had to come back non-zero over a perturbed input. Every recorded verdict
# is one case, so the case count is pass + fail.
red=0

mkprefix() { # <dir> <soname>...   real file's triple differs from the soname
    local d="$1"; shift; mkdir -p "$d" "$d/pkcs11"
    local c s
    for c in Auth Card Plugin Trust; do
        : > "$d/libLibreSCRS_$c.4.2.0.dylib"
        for s in "$@"; do ln -sf "libLibreSCRS_$c.4.2.0.dylib" "$d/libLibreSCRS_$c.$s.dylib"; done
        ln -sf "libLibreSCRS_$c.$1.dylib" "$d/libLibreSCRS_$c.dylib"
    done
    # The PKCS#11 module is versioned the same way (VERSION + SOVERSION), one
    # real file per soname here, each SAYING which soname it is, so a case can
    # tell which one was staged: every copy is `cp -L`, and an empty file is the
    # same bytes whichever link it came through.
    for s in "$@"; do
        printf 'pkcs11 soname %s\n' "$s" > "$d/pkcs11/librescrs-pkcs11.$s.0.0.dylib"
        ln -sf "librescrs-pkcs11.$s.0.0.dylib" "$d/pkcs11/librescrs-pkcs11.$s.dylib"
    done
    ln -sf "librescrs-pkcs11.$1.dylib" "$d/pkcs11/librescrs-pkcs11.dylib"
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

# R3 -- the consumer. Everything above passes with bundle-agent.sh untouched,
# i.e. with the defect still shipped, so without this the helper would be a fix
# nothing measures.
#
# Three sub-rules, because each of the two before it passed vacuously:
#
#   R3a  no dylib name in the file carries a literal soname integer, in ANY
#        spelling of the component: `libLibreSCRS_Auth.4.dylib` is the same
#        hard-coded integer as the star glob the defect happened to be written
#        as, and a rule matching `libLibreSCRS_*.` only would print
#        "hard-codes none" over it. Comments are searched too, even though
#        prose about the defect is not the defect: the layout this script
#        stages is DOCUMENTED in the header comment, and an exemption there
#        would let the documented layout go on naming an integer the staging
#        no longer uses, with nothing to notice. The lines here spell the
#        integer as "$lm_soname" or <soname>, so none of them match.
#
#   R3b  exactly one line assigns lm_soname, and that line calls lm-soname.sh.
#        A rule that only asks whether the helper is CALLED somewhere is green
#        on a script that calls it and then overwrites the answer on the next
#        line (`lm_soname=4  # pin the ABI we shipped with`) -- the integer is
#        then hard-coded nowhere R3a can see it, because it never appears
#        inside a dylib name. Inlining the call instead of binding it to
#        lm_soname is a legitimate shape this rule refuses; change the rule
#        deliberately, having read this, rather than working around it.
#
#   R3c  every line that names a libLibreSCRS_ dylib outside a comment also
#        names lm_soname. Dropping the soname from the glob altogether
#        (`libLibreSCRS_*.dylib`) hard-codes nothing and calls the helper, so
#        R3a and R3b are both green -- and over a prefix carrying two releases
#        it stages three files where one is wanted, which is the failure the
#        helper exists to prevent.
#
#
# What lies OUTSIDE the block is bounded by R5 below, not by a fourth sub-rule
# grepping for the lib prefix being globbed after the END marker. Such a grep
# is a list of spellings, and R5 carries four perturbations that stage
# hard-coded `.4` names into Contents/Frameworks in spellings no such list
# names: the prefix bound with braces (`lm_src="${LM_LIB_PREFIX}"`), bound with
# a trailing slash, walked with `ls | grep`, and reached through
# `/librescrs/..`, which a path-anchored rule excludes outright. R5 runs the
# whole script and asserts what lands in the bundle, which is a property no
# spelling can talk its way past.
# The staged block's first and last line in a given file, or 0 0 when the
# markers are not both there. A missing marker is not a pass: the block can then
# be neither run nor bounded, and everything below says so.
block_bounds() {  # block_bounds <bundle-agent.sh> -> "<begin> <end>"
    local ba="$1" b e
    b=$(grep -n '^# BEGIN LM dylib staging$' "$ba" | head -1 | cut -d: -f1)
    e=$(grep -n '^# END LM dylib staging$' "$ba" | head -1 | cut -d: -f1)
    if [ -z "$b" ] || [ -z "$e" ] || [ "$e" -le "$b" ]; then echo "0 0"; else echo "$b $e"; fi
}

r3_verdict() {  # r3_verdict <bundle-agent.sh> -> 0 ok, 1 broken (reason on stdout)
    local ba="$1" assigns bl el line
    if [ ! -f "$ba" ]; then
        echo "no bundle-agent.sh at $ba -- cannot judge the consumer"; return 1
    fi
    read -r bl el < <(block_bounds "$ba")
    if [ "$bl" = 0 ]; then
        echo "bundle-agent.sh carries no delimited staging block, so it can be neither run nor bounded"; return 1
    fi
    if grep -nE 'libLibreSCRS_[A-Za-z0-9_*]*\.[0-9]+\.dylib' "$ba"; then
        echo "bundle-agent.sh still hard-codes a soname integer"; return 1
    fi
    # A read loop, not mapfile: bash 3.2 (the macOS /bin/bash) has no mapfile,
    # and an empty array under `set -u` must be expanded with the `+` guard.
    assigns=()
    while IFS= read -r line; do assigns+=("$line"); done < <(grep -nE '^[[:space:]]*lm_soname=' "$ba")
    if [ "${#assigns[@]}" -ne 1 ]; then
        printf '%s\n' ${assigns[@]+"${assigns[@]}"}
        echo "bundle-agent.sh assigns lm_soname ${#assigns[@]} time(s); the soname comes from the helper and from nowhere else"
        return 1
    fi
    if ! printf '%s\n' "${assigns[0]}" | grep -q 'lm-soname\.sh'; then
        printf '%s\n' "${assigns[0]}"
        echo "the one assignment to lm_soname is not the lm-soname.sh call"; return 1
    fi
    # Trailing comments cut off first: this rule asks that something BE there,
    # and a rule of that shape is satisfied by prose. (R3a asks that something
    # NOT be there, so it reads comments and everything else.)
    if grep -nE 'libLibreSCRS_' "$ba" | grep -v ':[[:space:]]*#' | sed 's/[[:space:]]#.*$//' | grep -v 'lm_soname'; then
        echo "these name a libLibreSCRS_ dylib without the discovered soname"; return 1
    fi
    # awk exits 0 whether or not it printed anything, so the verdict is the
    # OUTPUT, not the pipeline's status.
    local stray
    stray="$(grep -nE 'lm_soname' "$ba" | awk -F: -v b="$bl" -v e="$el" '$1 + 0 < b + 0 || $1 + 0 > e + 0')"
    if [ -n "$stray" ]; then
        printf '%s\n' "$stray"
        echo "these mention lm_soname outside the staged block; what is outside it is not what R4 runs"; return 1
    fi
    return 0
}

BA="$(cd "$(dirname "$0")/../.." && pwd)/Scripts/bundle-agent.sh"
if why="$(r3_verdict "$BA")"; then
    echo "  ok    R3: bundle-agent.sh discovers the soname, hard-codes none"; pass=$((pass+1))
else
    echo "  FAIL  R3: $why"; fail=$((fail+1))
fi

# R3 the other way round: every sub-rule must be shown to fail on its own, or
# "R3 ok" is a line that cannot go red.
#
# HOW a perturbation is written matters as much as what it says. These were
# `sed '/marker/a text'` one-liners and `s|...|text\n&|` replacements -- both
# GNU spellings. BSD sed, which is the sed on the platform this bundler ships
# to, rejects `a text` written on one line, exits 1 and writes NOTHING, and does
# not read `\n` in a replacement as a newline either. The guard was `cmp -s`,
# which asks whether the copy DIFFERS -- and an empty file differs. Measured
# under a sed reproducing that one difference, the R5 perturbations below
# reported themselves caught having perturbed nothing, and the suite
# printed its full count with every guard vacuous.
#
# So: the splice is head/printf/tail, which is POSIX, substitutions carry no
# newline, and every perturbation names a fragment that MUST be present in the
# copy afterwards. "It edited something" is not "it applied".
apply_edit() {  # apply_edit <src> <dst> subst|after|before <selector> [<text>]
    local src="$1" dst="$2" mode="$3" sel="$4" text="${5-}" n
    case "$mode" in
        subst)
            sed "$sel" "$src" > "$dst" ;;
        after|before)
            n=$(grep -n -- "$sel" "$src" | head -1 | cut -d: -f1)
            [ -n "$n" ] || return 1
            [ "$mode" = before ] && n=$((n - 1))
            { if [ "$n" -gt 0 ]; then head -n "$n" "$src"; fi
              printf '%s\n' "$text"
              tail -n "+$((n + 1))" "$src"
            } > "$dst" ;;
        *) return 1 ;;
    esac
}
edit_landed() {  # edit_landed <label> <rule> <copy> <fragment>
    local label="$1" rule="$2" copy="$3" frag="$4"
    if cmp -s "$BA" "$copy"; then
        echo "  FAIL  $rule perturbation ($label) edited nothing"; fail=$((fail+1)); return 1
    fi
    if ! grep -Fq -- "$frag" "$copy"; then
        echo "  FAIL  $rule perturbation ($label) did not apply -- '$frag' is not in the copy"
        fail=$((fail+1)); return 1
    fi
    return 0
}
# Sets PCOPY to the perturbed copy, or counts a failure and returns 1. The
# copy's path comes back in a variable rather than on stdout on purpose: a
# command substitution runs in a subshell, and the failure counter incremented
# there would be discarded with it.
PCOPY=""
perturbed_copy() {  # perturbed_copy <label> <rule> <fragment> <mode> <selector> [<text>]
    local label="$1" rule="$2" frag="$3" copy
    shift 3
    # BSD mktemp only substitutes X's that TRAIL the template: given
    # `ba.XXXXXX.sh` it creates that literal name, so the second call dies with
    # "File exists" and every later case fails. Keep the X's last, add the
    # suffix afterwards.
    copy=$(mktemp "$WORK/ba.XXXXXX") && mv "$copy" "$copy.sh" && copy="$copy.sh"
    if ! apply_edit "$BA" "$copy" "$@"; then
        echo "  FAIL  $rule perturbation ($label) could not be applied -- the selector no longer matches"
        fail=$((fail+1)); return 1
    fi
    edit_landed "$label" "$rule" "$copy" "$frag" || return 1
    PCOPY="$copy"
}
r3_perturbation() {  # r3_perturbation <label> <fragment> <mode> <selector> [<text>]
    local label="$1" copy
    perturbed_copy "$label" R3 "${@:2}" || return
    copy="$PCOPY"
    red=$((red + 1))
    if r3_verdict "$copy" > /dev/null; then
        echo "  FAIL  R3 perturbation ($label) still passes -- R3 does not measure what it claims"; fail=$((fail+1))
    else
        echo "  ok    R3 perturbation ($label) is caught"; pass=$((pass+1))
    fi
}
# The three lines the repair touched, each put back on its own: the glob, the
# message that names what the glob did not find, and the header comment that
# documents the staged layout.
r3_perturbation "a literal soname back in the glob" 'libLibreSCRS_*.5.dylib' \
    subst 's/libLibreSCRS_\*\."\$lm_soname"\.dylib/libLibreSCRS_*.5.dylib/'
r3_perturbation "the failure message names a soname again" 'no libLibreSCRS_*.4.dylib' \
    subst 's/no libLibreSCRS_\*\.\$lm_soname\.dylib/no libLibreSCRS_*.4.dylib/'
r3_perturbation "the documented layout names a soname again" 'LM_LIB_PREFIX/libLibreSCRS_*.4.dylib' \
    subst 's|LM_LIB_PREFIX/libLibreSCRS_\*\.<soname>\.dylib|LM_LIB_PREFIX/libLibreSCRS_*.4.dylib|'
# The one the star-glob spelling missed: the helper is still called and its
# result still used, and one line names a library outright. Nothing in the
# shape of the repair objects to it -- only the rule does.
r3_perturbation "a component named outright, no glob" 'libLibreSCRS_Auth.4.dylib' \
    subst 's|^lm_dylibs=("\$LM_LIB_PREFIX"/libLibreSCRS_\*\."\$lm_soname"\.dylib)$|lm_dylibs=("$LM_LIB_PREFIX"/libLibreSCRS_Auth.4.dylib)|'
# And the three shapes in which no dylib name carries an integer at all.
r3_perturbation "the helper call replaced by a constant" 'lm_soname=5' \
    subst 's|^lm_soname="\$("\$SCRIPT_DIR/lm-soname\.sh".*|lm_soname=5|'
r3_perturbation "the helper called, then its answer overwritten" 'lm_soname=4' \
    before '^lm_dylibs=' 'lm_soname=4'
r3_perturbation "the glob drops the soname altogether" 'libLibreSCRS_*.dylib)' \
    subst 's|libLibreSCRS_\*\."\$lm_soname"\.dylib|libLibreSCRS_*.dylib|'
# R4 -- the consumer RUN, not read. Every rule above judges how the staging
# block is spelled, and spelling is the wrong axis: a bundler that calls the
# helper and then writes `export lm_soname=4` on the next line satisfies R3a
# (no name carries an integer), R3b (one line matching `^lm_soname=`, and it is
# the call) and R3c (every dylib line names lm_soname) -- and then globs .4
# against a 5.0 prefix and exits 1 with every rule above still green.
# `declare`, `local`, `readonly` and `read -r lm_soname <<< 4` pass the same
# way, and enumerating those four spellings would leave the fifth.
#
# So lift the block out and stage with it, over the same prefixes the helper
# cases above already build. What is asserted is the outcome: which names land
# in the destination, and how many.
lm_stage() {  # lm_stage <bundle-agent.sh> <lm-lib-prefix> <dest> -> rc; stdout = the block's
    local ba="$1" prefix="$2" dest="$3" bl el runner
    read -r bl el < <(block_bounds "$ba")
    [ "$bl" = 0 ] && return 3
    runner=$(mktemp "$WORK/stage.XXXXXX") && mv "$runner" "$runner.sh" && runner="$runner.sh"
    { echo '#!/usr/bin/env bash'
      # The options the block ships under. Under `set -u` alone a failing cp
      # would let the loop carry on and the case could still land the whole
      # expected name list; measured with errexit off, the block is not the
      # block that runs.
      echo 'set -euo pipefail'
      echo "SCRIPT_DIR=$(printf '%q' "$(cd "$(dirname "$HELPER")" && pwd)")"
      echo "LM_LIB_PREFIX=$(printf '%q' "$prefix")"
      echo "FRAMEWORKS=$(printf '%q' "$dest")"
      sed -n "${bl},${el}p" "$ba"
    } > "$runner"
    mkdir -p "$dest"
    bash "$runner" 2>&1
}
staged_names() {  # staged_names <dir> -> sorted basenames, one per line
    ( cd "$1" 2>/dev/null && ls ) | sort
}
r4_case() {  # r4_case <label> <bundle-agent.sh> <prefix> <want-rc> <want-staged-listing>
    local label="$1" ba="$2" prefix="$3" wrc="$4" want="$5" dest out rc got
    dest=$(mktemp -d "$WORK/staged.XXXXXX")
    out="$(lm_stage "$ba" "$prefix" "$dest")"; rc=$?
    got="$(staged_names "$dest" | tr '\n' ' ')"; got="${got% }"
    if [ "$rc" = "$wrc" ] && [ "$got" = "$want" ]; then
        echo "  ok    $label (rc=$rc staged='$got')"; pass=$((pass+1))
    else
        echo "  FAIL  $label: want rc=$wrc staged='$want', got rc=$rc staged='$got'"
        printf '%s\n' "$out" | sed 's/^/          /'
        fail=$((fail+1))
    fi
}

# The PKCS#11 module is staged by the block too, under the one name LM's module
# lookup accepts; which soname it was taken from is asserted by R5.
FOUR="libLibreSCRS_Auth.4.dylib libLibreSCRS_Card.4.dylib libLibreSCRS_Plugin.4.dylib libLibreSCRS_Trust.4.dylib librescrs-pkcs11.dylib"
FIVE="libLibreSCRS_Auth.5.dylib libLibreSCRS_Card.5.dylib libLibreSCRS_Plugin.5.dylib libLibreSCRS_Trust.5.dylib librescrs-pkcs11.dylib"
r4_case "R4: the block over a 5.0 prefix stages the .5 names" "$BA" "$WORK/five"  0 "$FIVE"
r4_case "R4: the block over a 4.x prefix stages the .4 names" "$BA" "$WORK/four"  0 "$FOUR"
r4_case "R4: the block over a prefix reused across a bump stages nothing" "$BA" "$WORK/dirty" 1 ""


# And R4 the other way round. Each of these leaves every rule above green (the
# first four were measured doing exactly that) and each changes what the block
# actually stages. The splice is the POSIX one and each names the fragment that
# has to be in the copy.
r4_perturbation() {  # r4_perturbation <label> <prefix> <want-rc> <want-staged> <fragment> <mode> <selector> [<text>]
    local label="$1" prefix="$2" wrc="$3" want="$4" copy dest out rc got
    shift 4
    perturbed_copy "$label" R4 "$@" || return
    copy="$PCOPY"
    red=$((red + 1))
    dest=$(mktemp -d "$WORK/staged4.XXXXXX")
    out="$(lm_stage "$copy" "$prefix" "$dest")"; rc=$?
    got="$(staged_names "$dest" | tr '\n' ' ')"; got="${got% }"
    if [ "$rc" = "$wrc" ] && [ "$got" = "$want" ]; then
        echo "  ok    R4 perturbation ($label) is caught (rc=$rc staged='$got')"; pass=$((pass+1))
    else
        echo "  FAIL  R4 perturbation ($label) staged what a working block stages: rc=$rc staged='$got'"
        fail=$((fail+1))
    fi
}
# The four spellings that overwrite the helper's answer on the next line. Over a
# 5.0 prefix the glob then finds nothing and the block exits 1 with nothing
# staged -- which is the failure the bundler reported from a real prefix.
r4_perturbation "export overwrites the answer"   "$WORK/five" 1 "" 'export lm_soname=4' \
    before '^lm_dylibs=' 'export lm_soname=4'
r4_perturbation "readonly overwrites the answer" "$WORK/five" 1 "" 'readonly lm_soname=4' \
    before '^lm_dylibs=' 'readonly lm_soname=4'
r4_perturbation "declare overwrites the answer"  "$WORK/five" 1 "" 'declare lm_soname=4' \
    before '^lm_dylibs=' 'declare lm_soname=4'
r4_perturbation "read overwrites the answer"     "$WORK/five" 1 "" 'read -r lm_soname <<< 4' \
    before '^lm_dylibs=' 'read -r lm_soname <<< 4'
# The integer written straight into the glob, between the markers -- the shape
# the bundler actually shipped before the helper existed.
r4_perturbation "the soname hard-coded inside the block" "$WORK/five" 1 "" 'libLibreSCRS_*.4.dylib)' \
    subst 's|libLibreSCRS_\*\."\$lm_soname"\.dylib|libLibreSCRS_*.4.dylib|'
# And the glob that hard-codes nothing at all: over a prefix carrying one
# release it stages the real file and the development link beside the soname,
# three names where one was wanted.
r4_perturbation "the glob drops the soname" "$WORK/five" 0 \
    "libLibreSCRS_Auth.4.2.0.dylib libLibreSCRS_Auth.5.dylib libLibreSCRS_Auth.dylib libLibreSCRS_Card.4.2.0.dylib libLibreSCRS_Card.5.dylib libLibreSCRS_Card.dylib libLibreSCRS_Plugin.4.2.0.dylib libLibreSCRS_Plugin.5.dylib libLibreSCRS_Plugin.dylib libLibreSCRS_Trust.4.2.0.dylib libLibreSCRS_Trust.5.dylib libLibreSCRS_Trust.dylib librescrs-pkcs11.dylib" \
    'libLibreSCRS_*.dylib)' subst 's|libLibreSCRS_\*\."\$lm_soname"\.dylib|libLibreSCRS_*.dylib|'

# R5 -- the WHOLE script, run, under every host identity it ships to. R4 runs
# the delimited block and only the block, so a second staging pass written after
# the END marker is measured by nothing there. A grep over the lines outside the
# block does not bound it either: a grep is a list of spellings, and four of the
# perturbations below stage hard-coded `.4` names into Contents/Frameworks in
# spellings such a list does not name.
#
# Running the script closes that -- for the lines that RUN. A second staging
# pass wrapped in
#
#     if [ "$(uname)" = "Darwin" ]; then ... fi
#
# leaves a single-identity run green on this host while staging both canaries
# on a Mac: the job that runs this suite is a Linux job, so the single most
# natural guard in a macOS bundler is the one branch such a run can never
# execute. So the script is run TWICE, once as this host and once with `uname`
# answering Darwin, and both runs must leave the same bundle.
#
# The identities answer THREE platform probes, named here rather than described
# in general, because "the platform test" reaches only one of them while reading
# as though it reached all three: `uname` (a stub on PATH), `$OSTYPE` (a bash
# variable, handed in through the environment) and `sw_vers` (a stub present
# only in the Darwin identity, so a script that merely asks whether it EXISTS is
# answered too). The middle one is no formality: `[[ "$OSTYPE" == darwin* ]]`
# around a stale staging pass is invisible to a run that stubs `uname` alone.
#
# What this does NOT measure, said plainly rather than left to be discovered: a
# staging pass guarded on some OTHER condition the fixture does not satisfy --
# a directory that does not exist, an environment variable nobody sets -- is not
# executed by any run and is judged by nothing here. Closing that needs branch
# coverage of the bundler rather than another identity. R3 still refuses a
# hard-coded soname integer anywhere in the file, whatever guards it.
#
# The comparison is over the WHOLE of Contents/, not over the dylibs alone: the
# rule is that nothing the bundler leaves behind may depend on the host. A
# legitimately host-conditional artefact is therefore a change to this suite as
# well -- give it a case of its own, deliberately, having read this.
#
# The prefix the script is pointed at carries three CANARIES: files a correctly
# bounded staging never touches, and that a glob of the prefix top level picks
# up in whatever spelling it is written. None of them is a soname to
# lm-soname.sh -- `libStale.4.dylib` and `libStale.5.dylib` have no
# libLibreSCRS_ prefix, and the component in `libLibreSCRS_Legacy_Old.4.dylib`
# carries an underscore, which the helper's own pattern excludes. Two of them
# carry the PREVIOUS soname and one the CURRENT one, because a second pass that
# hard-codes the integer the prefix happens to be at stages exactly the expected
# names otherwise, and the listing cannot see it. Should any of the three ever
# become a soname, the helper reports two and every case fails loudly.
#
# The Apple tools the script signs and relinks with are stubbed -- this host has
# none of them -- and the stubs RECORD their argv, so what was signed and what
# was relinked is asserted PER TOOL alongside what was staged. Per tool because
# comparing the union of all three would be satisfied by whichever tool is most
# talkative: `otool` is invoked on every staged dylib anyway, so a union
# assertion holds over a bundler whose signing loop has been deleted outright.
# Everything else -- the helper, the glob, the copies, the version stamp -- is
# the shipped script.
make_stubs() {  # make_stubs <dir> <host-name>
    local d="$1" host="$2" tool
    mkdir -p "$d"
    for tool in codesign install_name_tool otool; do
        { echo '#!/bin/sh'
          echo 'printf "%s" "${0##*/}" >> "$LM_SELFTEST_CALLS"'
          echo 'for a in "$@"; do printf " %s" "$a" >> "$LM_SELFTEST_CALLS"; done'
          echo 'printf "\n" >> "$LM_SELFTEST_CALLS"'
          # The team a real `codesign -dv` reports for what it signed; R6 sets
          # it, every other case leaves it empty and the stub says nothing.
          [ "$tool" != codesign ] || \
              echo '[ -z "${LM_SELFTEST_SIGNED_TEAM-}" ] || echo "TeamIdentifier=$LM_SELFTEST_SIGNED_TEAM" >&2'
          echo 'exit 0'
        } > "$d/$tool"
        chmod +x "$d/$tool"
    done
    # The team the built Info.plists name (LibreSCRSTeamID). Empty unless R6
    # sets one; absent altogether when R6 asks for a bundle built without it.
    { echo '#!/bin/sh'
      echo '[ -z "${LM_SELFTEST_NO_TEAM_KEY-}" ] || exit 1'
      echo 'printf "%s\n" "${LM_SELFTEST_TEAM-}"'
    } > "$d/plutil"
    chmod +x "$d/plutil"
    # cp is recorded and then really run: the staging needs its copies, and the
    # ORDER needs to see one that lands after the host was signed.
    { echo '#!/bin/sh'
      echo 'printf "cp" >> "$LM_SELFTEST_CALLS"'
      echo 'for a in "$@"; do printf " %s" "$a" >> "$LM_SELFTEST_CALLS"; done'
      echo 'printf "\n" >> "$LM_SELFTEST_CALLS"'
      echo "exec $(printf '%q' "$REAL_CP") \"\$@\""
    } > "$d/cp"
    chmod +x "$d/cp"
    if [ -n "$host" ]; then
        { echo '#!/bin/sh'
          echo "case \"\${1-}\" in -m) echo arm64 ;; -r) echo 24.0.0 ;; *) echo $host ;; esac"
        } > "$d/uname"
        chmod +x "$d/uname"
        # The third spelling of the same question. `uname` is the one a bundler
        # usually asks and `$OSTYPE` the one a bash script asks without spawning
        # anything; `sw_vers` is asked when the answer wanted is the OS version,
        # and it exists on no other platform, so its mere presence is a probe.
        { echo '#!/bin/sh'
          echo 'case "${1-}" in -productVersion) echo 15.0 ;; -buildVersion) echo 24A335 ;; *) echo "ProductName:\tmacOS" ;; esac'
        } > "$d/sw_vers"
        chmod +x "$d/sw_vers"
    fi
}
REAL_CP="$(command -v cp)"
[ -n "$REAL_CP" ] || { echo "FATAL: no cp on PATH -- cannot run the bundler" >&2; exit 2; }
STUBS="$WORK/stubs"                 ; make_stubs "$STUBS" ""
STUBS_DARWIN="$WORK/stubs-darwin"   ; make_stubs "$STUBS_DARWIN" Darwin

LDPREFIX="$WORK/ld-prefix"
mkdir -p "$LDPREFIX/agent" "$LDPREFIX/prompter"
printf '#!/bin/sh\n' > "$LDPREFIX/agent/librescrs-agent"
printf '#!/bin/sh\n' > "$LDPREFIX/prompter/librescrs-prompter"
chmod +x "$LDPREFIX/agent/librescrs-agent" "$LDPREFIX/prompter/librescrs-prompter"
# A version the script can stamp without asking git, so the case does not depend
# on what this checkout is called.
echo 'CMAKE_PROJECT_VERSION:STATIC=5.0.0' > "$LDPREFIX/CMakeCache.txt"

mkprefix "$WORK/whole" 5
mkdir -p "$WORK/whole/librescrs/plugins"
# The previous release's module beside the current one: install() overwrites
# but never deletes, so a prefix that has seen an ABI bump carries both, and a
# bundler that takes the first match stages the one whose libraries it did not
# ship. Sorted, the stale one comes first.
printf 'pkcs11 soname 4\n' > "$WORK/whole/pkcs11/librescrs-pkcs11.4.0.0.dylib"
ln -sf librescrs-pkcs11.4.0.0.dylib "$WORK/whole/pkcs11/librescrs-pkcs11.4.dylib"
: > "$WORK/whole/librescrs/plugins/librescrs-eid.dylib"
: > "$WORK/whole/librescrs/plugins/librescrs-emrtd.dylib"
: > "$WORK/whole/libStale.4.dylib"
: > "$WORK/whole/libLibreSCRS_Legacy_Old.4.dylib"
: > "$WORK/whole/libStale.5.dylib"
# Trust anchors, a sibling of the lib/ prefix (LM_LIB_PREFIX/../share/librescrs/
# certificates) exactly as a real LibreMiddleware install lays it out. Without
# this the bundler's own hard check refuses the prefix before staging anything.
mkdir -p "$WORK/share/librescrs/certificates"
: > "$WORK/share/librescrs/certificates/x.pem"

# The calls log is created by the CALLER and handed in: whole_run is used inside
# a command substitution, so anything it assigns dies with the subshell.
APPEX_FIXTURE='<key>keychain-access-groups</key><array><string>ABCDE12345.org.librescrs.LibreMac</string></array>'
whole_run() {  # whole_run <bundle-agent.sh> <lm-lib-prefix> <app> <stub-dir> <calls-log> [<ostype>] -> rc; stdout = the script's
    local ba="$1" prefix="$2" app="$3" stubs="$4" calls="$5" ostype="${6-}" root
    root=$(mktemp -d "$WORK/root.XXXXXX")
    mkdir -p "$root/Scripts" "$root/Packaging" "$root/LibreMac/LibreMacToken"
    cp "$ba" "$root/Scripts/bundle-agent.sh"
    cp "$HELPER" "$root/Scripts/lm-soname.sh"
    chmod +x "$root/Scripts/bundle-agent.sh" "$root/Scripts/lm-soname.sh"
    : > "$root/Packaging/org.librescrs.agent.plist"
    : > "$root/Packaging/org.librescrs.prompter.plist"
    : > "$root/LibreMac/LibreMacToken/LibreMacToken.entitlements"
    : > "$root/LibreMac/LibreMac.entitlements"
    # What Xcode leaves: the extension already signed, its keychain group
    # EXPANDED from $(AppIdentifierPrefix). codesign does not expand that
    # variable, so a re-sign from the source .entitlements would ship the
    # literal; the bundler must leave these bytes alone.
    mkdir -p "$app/Contents/PlugIns/LibreMacToken.appex/Contents"
    printf '%s\n' "$APPEX_FIXTURE" > "$app/Contents/PlugIns/LibreMacToken.appex/Contents/entitlements.xcent"
    if [ -n "$ostype" ]; then
        PATH="$stubs:$PATH" LM_SELFTEST_CALLS="$calls" OSTYPE="$ostype" \
            "$root/Scripts/bundle-agent.sh" "$app" "$LDPREFIX" "$prefix" 2>&1
    else
        PATH="$stubs:$PATH" LM_SELFTEST_CALLS="$calls" \
            "$root/Scripts/bundle-agent.sh" "$app" "$LDPREFIX" "$prefix" 2>&1
    fi
}
bundled_files() {  # bundled_files <app> -> the staged files under Contents/, sorted
    local out
    out="$( ( cd "$1/Contents" 2>/dev/null && find . -type f | sed 's|^\./||' ) | sort | tr '\n' ' ')"
    printf '%s' "${out% }"
}
# What ONE tool was handed, by the name it was handed it under: the last
# argument of each of its recorded lines, which is the file every one of these
# tools acts on. A union across all three stubs is satisfied by whichever tool
# is most talkative: `otool` alone re-enumerates the staged set, so a union
# assertion holds while nothing is signed at all. The perturbations below delete
# the whole dylib signing loop and narrow it to one library in seven, and both
# are caught only because each tool is asserted on its own.
recorded_targets() {  # recorded_targets <tool> <calls.log> -> sorted unique basenames
    local out
    out="$(awk -v t="$1" '$1 == t { print $NF }' "$2" 2>/dev/null \
        | sed 's|.*/||' | sort -u | tr '\n' ' ')"
    printf '%s' "${out% }"
}
WHOLE="Frameworks/libLibreSCRS_Auth.5.dylib Frameworks/libLibreSCRS_Card.5.dylib Frameworks/libLibreSCRS_Plugin.5.dylib Frameworks/libLibreSCRS_Trust.5.dylib Frameworks/librescrs-pkcs11.dylib Library/LaunchAgents/org.librescrs.agent.plist Library/LaunchAgents/org.librescrs.prompter.plist MacOS/librescrs-agent MacOS/librescrs-prompter PlugIns/LibreMacToken.appex/Contents/entitlements.xcent PlugIns/librescrs/librescrs-eid.dylib PlugIns/librescrs/librescrs-emrtd.dylib Resources/certificates/x.pem Resources/librescrs-agent.version"
# What each tool must have been handed, per tool. CODESIGNED is the inside-out
# signing pass in full -- every staged dylib, both executables and the host
# .app, and NOT the token extension, which keeps the signature Xcode gave it --
# and RELINKED is the rpath fixup, which is the part of the relink work this
# host can run at all.
#
# The bundler's Homebrew dependency closure is NOT exercised here and is not
# claimed to be: it acts only on a dependency whose install name begins
# /opt/homebrew/, a path this host cannot create, and the `cp -L` that follows
# would have to find a real dylib there. That half stays the Apple host's, and
# it is written down rather than left to be discovered as a finding.
CODESIGNED="LibreMac.app libLibreSCRS_Auth.5.dylib libLibreSCRS_Card.5.dylib libLibreSCRS_Plugin.5.dylib libLibreSCRS_Trust.5.dylib librescrs-agent librescrs-eid.dylib librescrs-emrtd.dylib librescrs-pkcs11.dylib librescrs-prompter"
RELINKED="librescrs-agent librescrs-prompter"
# Every recorded call, whole and in the order it was made: the sequence is the
# evidence for "the host is signed last", which a sorted set cannot carry.
recorded_calls_in_order() {  # recorded_calls_in_order <calls.log> -> one call per line
    cat "$1" 2>/dev/null
}
# 0 when every tool was invoked on exactly the files it must have been handed
# -- which FILE each stub's last argument names -- and the signing pass has the
# shape a sealed bundle needs: every codesign carries the hardened runtime, the
# last one is the host .app, and nothing relinks or copies after it. Beyond
# that one flag, what an argument told the real tool to do is not read (see
# the threat model at the top).
tools_agree() {  # tools_agree <calls.log> -> prints the first mismatch
    local got calls last_sign n
    got="$(recorded_targets codesign "$1")"
    [ "$got" = "$CODESIGNED" ] || { printf 'codesign\n  want: %s\n  got:  %s' "$CODESIGNED" "$got"; return 1; }
    got="$(recorded_targets install_name_tool "$1")"
    [ "$got" = "$RELINKED" ] || { printf 'install_name_tool\n  want: %s\n  got:  %s' "$RELINKED" "$got"; return 1; }
    calls="$(recorded_calls_in_order "$1")"
    got="$(printf '%s\n' "$calls" | awk '$1 == "codesign"' | grep -v -- ' --options runtime ' || true)"
    [ -z "$got" ] || { printf 'codesign without the hardened runtime:\n%s' "$got"; return 1; }
    last_sign="$(printf '%s\n' "$calls" | awk '$1 == "codesign" { n = NR } END { print n + 0 }')"
    got="$(printf '%s\n' "$calls" | awk -v n="$last_sign" 'NR == n { print $NF }' | sed 's|.*/||')"
    [ "$got" = "LibreMac.app" ] || { printf 'the last codesign is not the host .app\n  got: %s' "$got"; return 1; }
    got="$(printf '%s\n' "$calls" | awk -v n="$last_sign" 'NR > n && ($1 == "install_name_tool" || $1 == "cp")')"
    [ -z "$got" ] || { printf 'the bundle was touched after the host was signed:\n%s' "$got"; return 1; }
    return 0
}
# 0 when the bundle carries the token extension exactly as Xcode left it, and
# the PKCS#11 module of the soname the libraries were staged at.
bundle_contents_agree() {  # bundle_contents_agree <app> -> prints the first mismatch
    local got
    got="$(cat "$1/Contents/PlugIns/LibreMacToken.appex/Contents/entitlements.xcent" 2>/dev/null)"
    [ "$got" = "$APPEX_FIXTURE" ] || { printf 'the token extension was altered\n  want: %s\n  got:  %s' "$APPEX_FIXTURE" "$got"; return 1; }
    got="$(cat "$1/Contents/Frameworks/librescrs-pkcs11.dylib" 2>/dev/null)"
    [ "$got" = "pkcs11 soname 5" ] || { printf 'the PKCS#11 module is not the soname-5 one\n  got: %s' "$got"; return 1; }
    return 0
}

# The two identities the bundler is run under. The second one answers Darwin to
# every platform probe a shell script has: `uname` (stubbed above), `$OSTYPE`
# (a bash variable, and bash takes it from the environment when one is handed
# in -- measured) and `sw_vers` (stubbed, and absent from the first identity's
# PATH entirely, which is how a script that merely LOOKS for it tells the two
# apart). All three are answered because covering one leaves the others open: a
# stale staging pass behind `[[ "$OSTYPE" == darwin* ]]` is invisible to stubs
# on PATH alone. The shipped script asks none of the three, which is the point
# -- a run that differs between the identities is a run that took a platform
# branch.
IDENT_NAMES=(this-host Darwin)
IDENT_STUBS=("$STUBS" "$STUBS_DARWIN")
IDENT_OSTYPE=("" darwin24)

r5_case() {  # r5_case <label> <bundle-agent.sh> <want-rc> <want-listing>
    local label="$1" ba="$2" wrc="$3" want="$4" i id app calls out rc got
    local -a listings=()
    for i in "${!IDENT_NAMES[@]}"; do
        id="${IDENT_NAMES[$i]}"
        app="$(mktemp -d "$WORK/app.XXXXXX")/LibreMac.app"
        calls=$(mktemp "$WORK/calls.XXXXXX")
        out="$(whole_run "$ba" "$WORK/whole" "$app" "${IDENT_STUBS[$i]}" "$calls" "${IDENT_OSTYPE[$i]}")"; rc=$?
        got="$(bundled_files "$app")"
        listings+=("$got")
        if [ "$rc" = "$wrc" ] && [ "$got" = "$want" ]; then
            echo "  ok    $label [host=$id] (rc=$rc)"; pass=$((pass+1))
        else
            echo "  FAIL  $label [host=$id]: rc=$rc (want $wrc), and Contents/ does not hold exactly what the block staged"
            echo "          want: $want"
            echo "          got:  $got"
            printf '%s\n' "$out" | sed 's/^/          /'
            fail=$((fail+1))
        fi
        if got="$(tools_agree "$calls")"; then
            echo "  ok    codesign and install_name_tool were each handed exactly the staged files, the host signed last with the hardened runtime [host=$id]"
            pass=$((pass+1))
        else
            echo "  FAIL  a tool was handed something other than the staged files, or the signing pass is out of shape [host=$id]"
            printf '%s\n' "$got" | sed 's/^/          /'
            fail=$((fail+1))
        fi
        if got="$(bundle_contents_agree "$app")"; then
            echo "  ok    the token extension is untouched and the PKCS#11 module is the soname-5 one [host=$id]"
            pass=$((pass+1))
        else
            echo "  FAIL  the bundle holds the right names with the wrong contents [host=$id]"
            printf '%s\n' "$got" | sed 's/^/          /'
            fail=$((fail+1))
        fi
    done
    # And the two against EACH OTHER, named as its own case. Reported through
    # the cases above alone, a host-conditional bundler is described as a
    # staging block that staged the wrong thing -- which is the one line that is
    # certainly innocent. This says what actually happened.
    identities_agree "$label" "${listings[@]}"
}
# 0 when every identity left the same Contents/, 1 otherwise, with the
# difference printed. The bundle is compared WHOLE: the rule is that nothing in
# Contents/ may depend on the host, not that no dylib may. A legitimately
# host-conditional artefact -- a helper only a Mac can run, a file derived from
# entitlements -- is a case of its own here, deliberately, having read this.
identities_agree() {  # identities_agree <label> <listing>...
    local label="$1" first="$2" i ok=0
    shift
    for i in "$@"; do [ "$i" = "$first" ] || ok=1; done
    if [ "$ok" = 0 ]; then
        echo "  ok    every host identity leaves the same Contents/ ($label)"; pass=$((pass+1))
        return 0
    fi
    echo "  FAIL  the host identities leave DIFFERENT bundles ($label) -- the bundler took a platform branch, and what it stages is not the same on a Mac as it is here"
    i=0
    for first in "$@"; do
        echo "          [host=${IDENT_NAMES[$i]}] $first"
        i=$((i + 1))
    done
    fail=$((fail+1))
    return 1
}
r5_case "R5: the whole script stages the soname it discovered, and nothing else" "$BA" 0 "$WHOLE"

# And R5 the other way round: a second staging pass, in the spellings that left
# every rule above green. Each is judged by what reached the bundle and by what
# the Apple-tool stubs were handed, under BOTH identities: a perturbation is
# caught when either run departs from the expected bundle. A pass that only a
# Mac would take is therefore caught here, on Linux.
r5_perturbation() {  # r5_perturbation <label> <fragment> <mode> <selector> [<text>]
    local label="$1" copy i app calls out rc got caught=0
    perturbed_copy "$label" R5 "${@:2}" || return
    copy="$PCOPY"
    for i in "${!IDENT_NAMES[@]}"; do
        app="$(mktemp -d "$WORK/app5.XXXXXX")/LibreMac.app"
        calls=$(mktemp "$WORK/calls5.XXXXXX")
        out="$(whole_run "$copy" "$WORK/whole" "$app" "${IDENT_STUBS[$i]}" "$calls" "${IDENT_OSTYPE[$i]}")"; rc=$?
        got="$(bundled_files "$app")"
        if [ "$rc" != 0 ] || [ "$got" != "$WHOLE" ] || ! tools_agree "$calls" > /dev/null \
            || ! bundle_contents_agree "$app" > /dev/null; then
            caught=1
        fi
    done
    red=$((red + 1))
    if [ "$caught" = 1 ]; then
        echo "  ok    R5 perturbation ($label) is caught"; pass=$((pass+1))
    else
        echo "  FAIL  R5 perturbation ($label) left the bundle unchanged under every identity -- R5 does not measure what it claims"
        fail=$((fail+1))
    fi
}
r5_perturbation "a second staging pass after the block" 'for stale in "$LM_LIB_PREFIX"/*.4.dylib' \
    after '^# END LM dylib staging$' \
    'for stale in "$LM_LIB_PREFIX"/*.4.dylib; do cp -L "$stale" "$FRAMEWORKS/$(basename "$stale")"; done'
r5_perturbation "the prefix bound with braces, globbed on the next line" 'lm_src="${LM_LIB_PREFIX}"' \
    after '^# END LM dylib staging$' \
    'lm_src="${LM_LIB_PREFIX}"
for stale in "$lm_src"/*.4.dylib; do cp -L "$stale" "$FRAMEWORKS/$(basename "$stale")"; done'
r5_perturbation "the prefix bound with a trailing slash" 'lm_src="$LM_LIB_PREFIX/"' \
    after '^# END LM dylib staging$' \
    'lm_src="$LM_LIB_PREFIX/"
for stale in "$lm_src"*.4.dylib; do cp -L "$stale" "$FRAMEWORKS/$(basename "$stale")"; done'
r5_perturbation "the prefix walked with ls instead of globbed" 'ls "$LM_LIB_PREFIX" | grep 4.dylib' \
    after '^# END LM dylib staging$' \
    'for stale in $(ls "$LM_LIB_PREFIX" | grep 4.dylib); do cp -L "$LM_LIB_PREFIX/$stale" "$FRAMEWORKS/$stale"; done'
r5_perturbation "the prefix top level reached through a subdirectory" 'librescrs/../*.4.dylib' \
    after '^# END LM dylib staging$' \
    'for stale in "$LM_LIB_PREFIX"/librescrs/../*.4.dylib; do cp -L "$stale" "$FRAMEWORKS/$(basename "$stale")"; done'
# The two the single-identity run could not see. The first is the guard a macOS
# bundler naturally grows and the Linux job can never execute; the second
# hard-codes the soname the prefix is CURRENTLY at, so the expected names all
# land and only a canary at that same integer betrays it.
r5_perturbation "a second staging pass only a Mac would take" 'if [ "$(uname)" = "Darwin" ]' \
    after '^# END LM dylib staging$' \
    'if [ "$(uname)" = "Darwin" ]; then
    for stale in "$LM_LIB_PREFIX"/*.4.dylib; do cp -L "$stale" "$FRAMEWORKS/$(basename "$stale")"; done
fi'
r5_perturbation "a second staging pass hard-coding the soname the prefix is at" 'for stale in "$LM_LIB_PREFIX"/*.5.dylib' \
    after '^# END LM dylib staging$' \
    'for stale in "$LM_LIB_PREFIX"/*.5.dylib; do cp -L "$stale" "$FRAMEWORKS/$(basename "$stale")"; done'
# The other two spellings of "am I on a Mac". Covering `uname` alone leaves
# $OSTYPE open: the same stale staging pass behind `[[ "$OSTYPE" == darwin* ]]`
# runs on a Mac and stages both previous-soname canaries there, while a run
# that stubs only `uname` stays green. It is not an invented guard -- bash sets
# OSTYPE itself, so it is the platform test a bash script writes when it does
# not want to spawn `uname` -- and neither is looking for `sw_vers`, which
# exists on no other platform.
r5_perturbation "a second staging pass guarded on \$OSTYPE" 'if [[ "$OSTYPE" == darwin* ]]' \
    after '^# END LM dylib staging$' \
    'if [[ "$OSTYPE" == darwin* ]]; then
    for stale in "$LM_LIB_PREFIX"/*.4.dylib; do cp -L "$stale" "$FRAMEWORKS/$(basename "$stale")"; done
fi'
r5_perturbation "a second staging pass guarded on sw_vers being there" 'command -v sw_vers' \
    after '^# END LM dylib staging$' \
    'if command -v sw_vers > /dev/null 2>&1; then
    for stale in "$LM_LIB_PREFIX"/*.4.dylib; do cp -L "$stale" "$FRAMEWORKS/$(basename "$stale")"; done
fi'
# Three that stage exactly the right files and do the WORK wrong, which is what
# the per-tool assertion is for. Each shadows an Apple tool with a shell
# function, so the bundle is byte-identical under both identities and only the
# recorded argv differs. A union assertion passes all three: `otool` is invoked
# on every staged dylib anyway and satisfies the union on its own, so the
# signing pass could be deleted outright and the bundle would still be called
# correct.
r5_perturbation "nothing is signed at all" 'codesign() { :; }' \
    after '^# END LM dylib staging$' \
    'codesign() { :; }'
r5_perturbation "one library in seven is signed" 'command codesign "$@"' \
    after '^# END LM dylib staging$' \
    'codesign() { case "$*" in *pkcs11*|*.appex|*librescrs-agent|*librescrs-prompter) command codesign "$@" ;; *) : ;; esac; }'
r5_perturbation "the rpath fixup does nothing" 'install_name_tool() { :; }' \
    after '^# END LM dylib staging$' \
    'install_name_tool() { :; }'

# The signing pass put back the way it was, one piece at a time, and two ways
# to touch the bundle after its seal. Each stages the right files; only the
# per-tool set, the call ORDER, the one flag read out of the argv or the bytes
# of what was staged can tell them from the shipped script.
r5_perturbation "the token extension signed again from its source entitlements" \
    'LibreMacToken/LibreMacToken.entitlements" "$TOKEN_APPEX"' \
    before '^# The host LAST' \
    'codesign --force -s "$CODESIGN_IDENTITY" --options runtime --timestamp=none --entitlements "$REPO_ROOT/LibreMac/LibreMacToken/LibreMacToken.entitlements" "$TOKEN_APPEX"'
r5_perturbation "the host left unsigned" ': \' \
    subst 's|^codesign --force -s "\$CODESIGN_IDENTITY" --options runtime --timestamp=none \\$|: \\|'
r5_perturbation "a dylib signed without the hardened runtime" '-s "$CODESIGN_IDENTITY" --timestamp=none "$lib"' \
    subst 's|--options runtime --timestamp=none "\$lib"|--timestamp=none "$lib"|'
r5_perturbation "a copy into the bundle after the host is signed" '# after the seal' \
    after 'LibreMac/LibreMac.entitlements" "\$APP_PATH"$' \
    'cp "$REPO_ROOT/Packaging/org.librescrs.agent.plist" "$LAUNCHAGENTS/org.librescrs.agent.plist" # after the seal'
r5_perturbation "a relink after the host is signed" '2>/dev/null || true # after the seal' \
    after 'LibreMac/LibreMac.entitlements" "\$APP_PATH"$' \
    'install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS/librescrs-agent" 2>/dev/null || true # after the seal'
r5_perturbation "an executable signed again after the host" '"$MACOS/librescrs-agent" # after the seal' \
    after 'LibreMac/LibreMac.entitlements" "\$APP_PATH"$' \
    'codesign --force -s "$CODESIGN_IDENTITY" --options runtime --timestamp=none --identifier org.librescrs.agent --entitlements "$ENTS_DIR/agent.plist" "$MACOS/librescrs-agent" # after the seal'
r5_perturbation "the extension's entitlements overwritten from the source file" '"$TOKEN_APPEX/Contents/entitlements.xcent"' \
    before '^# The host LAST' \
    'cp "$REPO_ROOT/LibreMac/LibreMacToken/LibreMacToken.entitlements" "$TOKEN_APPEX/Contents/entitlements.xcent"'
r5_perturbation "the PKCS#11 module taken at the previous soname" 'librescrs-pkcs11.4.dylib"' \
    subst 's|librescrs-pkcs11\.\$lm_soname\.dylib"$|librescrs-pkcs11.4.dylib"|'

# And the control: an edit outside the block that stages nothing must leave both
# runs identical, or "caught" would mean nothing more than "the file changed".
r5_control() {  # r5_control <label> <fragment> <mode> <selector> [<text>]
    local label="$1" copy i app calls out rc got bad=0 diverged=0 prev=""
    perturbed_copy "$label" R5 "${@:2}" || return
    copy="$PCOPY"
    for i in "${!IDENT_NAMES[@]}"; do
        app="$(mktemp -d "$WORK/appc.XXXXXX")/LibreMac.app"
        calls=$(mktemp "$WORK/callsc.XXXXXX")
        out="$(whole_run "$copy" "$WORK/whole" "$app" "${IDENT_STUBS[$i]}" "$calls" "${IDENT_OSTYPE[$i]}")"; rc=$?
        got="$(bundled_files "$app")"
        [ "$i" = 0 ] || [ "$got" = "$prev" ] || diverged=1
        prev="$got"
        if [ "$rc" != 0 ] || [ "$got" != "$WHOLE" ] || ! tools_agree "$calls" > /dev/null \
            || ! bundle_contents_agree "$app" > /dev/null; then
            bad=1
            echo "          [host=${IDENT_NAMES[$i]}] rc=$rc got: $got"
        fi
    done
    if [ "$bad" = 0 ]; then
        echo "  ok    R5 control ($label) leaves the bundle exactly as it was"; pass=$((pass+1))
    elif [ "$diverged" = 1 ]; then
        # Which line is at fault matters here: an edit that stages nothing and
        # yet leaves two different bundles has taken a platform branch, and
        # saying "R5 reds on edits that stage nothing" would send the reader to
        # the staging block, which had no part in it.
        echo "  FAIL  R5 control ($label) left DIFFERENT bundles under different host identities -- the edit stages nothing and still took a platform branch"
        fail=$((fail+1))
    else
        echo "  FAIL  R5 control ($label) changed what the bundler leaves behind -- an edit that stages nothing must leave Contents/ exactly as it was"
        fail=$((fail+1))
    fi
}
r5_control "a line outside the block that stages nothing" 'bundle-agent: staging bounded' \
    after '^# END LM dylib staging$' 'echo "bundle-agent: staging bounded" >&2'

# R6 -- the signing identity against the team the clients enforce. The host and
# the token extension require the agent to meet the designated requirement of
# the team their Info.plists name (LibreSCRSTeamID, from LIBRESCRS_TEAM_ID in
# project.yml). A bundle whose signer is some other team ships clients that
# refuse their own agent; a team-signed bundle whose clients name no team ships
# clients that never check who signed the agent; an ad-hoc bundle that names a
# team can never pass. Each must stop the bundler before the host is sealed.
# The team `codesign -dv` reports and the one the Info.plists carry come from
# the stubs above.
r6_case() {  # r6_case <label> <identity> <plist-team|-absent-> <signed-team> <want-rc> <want-text>
    local label="$1" identity="$2" team="$3" signed="$4" wrc="$5" want="$6" app calls out rc nokey="" sealed
    [ "$team" != "-absent-" ] || { team=""; nokey=1; }
    app="$(mktemp -d "$WORK/app6.XXXXXX")/LibreMac.app"
    calls=$(mktemp "$WORK/calls6.XXXXXX")
    out="$(CODESIGN_IDENTITY="$identity" LM_SELFTEST_TEAM="$team" LM_SELFTEST_SIGNED_TEAM="$signed" \
        LM_SELFTEST_NO_TEAM_KEY="$nokey" whole_run "$BA" "$WORK/whole" "$app" "$STUBS" "$calls")"; rc=$?
    sealed=0
    awk '$1 == "codesign" { print $NF }' "$calls" | grep -q 'LibreMac\.app$' && sealed=1
    [ "$wrc" = 0 ] || red=$((red + 1))
    if [ "$rc" = "$wrc" ] && [ "$sealed" = "$((1 - (wrc != 0)))" ] && printf '%s\n' "$out" | grep -qF -- "$want"; then
        echo "  ok    R6: $label (rc=$rc)"; pass=$((pass+1))
    else
        echo "  FAIL  R6: $label: rc=$rc (want $wrc), host sealed=$sealed, want text: $want"
        printf '%s\n' "$out" | sed 's/^/          /'
        fail=$((fail+1))
    fi
}
TEAM_ID_A=ABCDE12345
TEAM_ID_B=ZYXWV98765
TEAM_IDENTITY="Developer ID Application: Example ($TEAM_ID_A)"
r6_case "ad hoc, no team named: bundles" - "" "" 0 "bundle-agent: done"
r6_case "team identity, the same team named: bundles" "$TEAM_IDENTITY" "$TEAM_ID_A" "$TEAM_ID_A" 0 "bundle-agent: done"
r6_case "team identity, another team named: refused" "$TEAM_IDENTITY" "$TEAM_ID_B" "$TEAM_ID_A" 1 \
    "the clients would refuse this agent"
r6_case "team identity, no team named: refused" "$TEAM_IDENTITY" "" "$TEAM_ID_A" 1 \
    "the clients would never check who signed the agent"
r6_case "ad hoc with a team named: refused" - "$TEAM_ID_A" "" 1 "CODESIGN_IDENTITY is ad hoc"
r6_case "a bundle whose Info.plist names no team at all: refused" - -absent- "" 1 "carries no LibreSCRSTeamID"

# A block that cannot be found is not a pass: without both markers there is
# nothing to lift out, and R4 would silently measure nothing.
nomarker="$WORK/ba-nomarker.sh"
sed '/^# BEGIN LM dylib staging$/d' "$BA" > "$nomarker"
if cmp -s "$BA" "$nomarker"; then
    echo "  FAIL  the marker perturbation edited nothing -- bundle-agent.sh no longer carries the BEGIN marker"; fail=$((fail+1))
else
    lm_stage "$nomarker" "$WORK/five" "$WORK/staged-nomarker" > /dev/null; rc=$?
    red=$((red + 1))
    if [ "$rc" = 3 ] && ! r3_verdict "$nomarker" > /dev/null; then
        echo "  ok    a bundle-agent.sh with no staging markers is refused, not measured"; pass=$((pass+1))
    else
        echo "  FAIL  a bundle-agent.sh with no staging markers was judged anyway (stage rc=$rc)"; fail=$((fail+1))
    fi
fi

echo "lm-soname.selftest: $pass passed, $fail failed"
printf 'selftest: %s cases, %s red-proved\n' "$((pass + fail))" "$red"
[ "$fail" -eq 0 ]
