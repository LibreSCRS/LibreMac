#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# SPDX-FileCopyrightText: 2026 hirashix0
#
# Selects the Xcode named in .xcode-version -- the one place the version is
# stated -- and its macOS SDK, explicitly. Left to the defaults, xcrun can pick
# the Command Line Tools SDK of a newer macOS, whose .tbd files that Xcode's
# linker cannot parse; and a runner image changes its default Xcode on its own
# schedule. In Actions it writes DEVELOPER_DIR and SDKROOT to $GITHUB_ENV;
# elsewhere it prints them for `eval "$(Scripts/select-xcode.sh)"`.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
want="$(tr -d '[:space:]' < "$root/.xcode-version")"
[ -n "$want" ] || { echo "select-xcode: .xcode-version is empty" >&2; exit 1; }

found=""
seen=""
for app in /Applications/Xcode_"$want".app /Applications/Xcode.app /Applications/Xcode*.app; do
    [ -d "$app/Contents/Developer" ] || continue
    v="$(DEVELOPER_DIR="$app/Contents/Developer" xcodebuild -version 2>/dev/null | sed -n 's/^Xcode //p')" || v=""
    seen="$seen $app=$v"
    if [ "$v" = "$want" ]; then found="$app/Contents/Developer"; break; fi
done
[ -n "$found" ] || { echo "select-xcode: no Xcode $want installed (found:$seen)" >&2; exit 1; }

sdk="$(DEVELOPER_DIR="$found" xcrun --sdk macosx --show-sdk-path)"
case "$sdk" in "$found"/*) ;; *) echo "select-xcode: the SDK $sdk is not inside $found" >&2; exit 1 ;; esac

if [ -n "${GITHUB_ENV:-}" ]; then
    { echo "DEVELOPER_DIR=$found"; echo "SDKROOT=$sdk"; } >> "$GITHUB_ENV"
else
    printf 'export DEVELOPER_DIR=%q\nexport SDKROOT=%q\n' "$found" "$sdk"
fi
echo "select-xcode: Xcode $want at $found, SDK $sdk" >&2
