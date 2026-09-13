#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# SPDX-FileCopyrightText: 2026 hirashix0
#
# lm-soname.sh <lm-lib-prefix>
#
# Print the LibreMiddleware soname integer present in an install prefix.
#
# The number is LIBRESCRS_ABI_SOVERSION, which LibreMiddleware bumps when its
# ABI layout check reports a non-additive change and NOT when a release is
# declared (its own comment: "4 = 4.0-4.2; 5 = 5.0 onward"). So it cannot be
# derived from the release version -- one integer spans three releases there --
# and hard-coding it is what broke bundle-agent.sh: the glob named the integer
# of the ABI the bundler had been written against, and LibreMiddleware bumped
# past it. A number taken from PROJECT_VERSION is wrong a third way: the real
# file is named with the full version triple and the soname symlink with this
# integer alone, so the two are different names answering different questions.
#
# Hence: discover it from the prefix, and insist on exactly one. install()
# overwrites but never deletes, so installing into a prefix across an ABI bump
# adds the new real file and its soname symlink BESIDE the previous pair and
# overwrites only the unversioned development link. The prefix then offers two
# sonames, the stale one still resolving to the superseded library. Picking
# between them with head -1 can stage that library, under a name the agent's
# LC_LOAD_DYLIB never asks for: a dyld failure at launch, discovered after
# signing and notarisation. A prefix carrying two sonames is therefore an error
# naming its cause, not a choice.
#
# Exit codes:
#   0  exactly one soname found; it is on stdout
#   1  none, or more than one; the cause is on stderr
#   2  usage
set -uo pipefail
export LC_ALL=C

if [ "$#" -lt 1 ]; then
    echo "usage: lm-soname.sh <lm-lib-prefix>" >&2
    exit 2
fi
PREFIX="$1"
[ -d "$PREFIX" ] || { echo "lm-soname: no such prefix: $PREFIX" >&2; exit 1; }

# Matches libLibreSCRS_<Component>.<N>.dylib and nothing else: the real file
# libLibreSCRS_Auth.4.2.0.dylib has more components after the integer and the
# development link libLibreSCRS_Auth.dylib has none, so neither can be mistaken
# for a soname.
found="$(ls "$PREFIX" 2>/dev/null \
    | sed -n 's/^libLibreSCRS_[A-Za-z0-9]\{1,\}\.\([0-9]\{1,\}\)\.dylib$/\1/p' \
    | sort -un)"
n="$(printf '%s' "$found" | grep -c .)"

if [ "$n" -eq 0 ]; then
    echo "lm-soname: no libLibreSCRS_<component>.<soname>.dylib under $PREFIX -- build and install LibreMiddleware first" >&2
    exit 1
fi
if [ "$n" -gt 1 ]; then
    echo "lm-soname: $PREFIX carries $n LibreMiddleware sonames ($(echo $found | tr '\n' ' ')) -- install() overwrites but never deletes, so this prefix was reused across an ABI bump. Remove it and install once." >&2
    exit 1
fi
printf '%s\n' "$found"
