#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# SPDX-FileCopyrightText: 2026 hirashix0
set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: adhoc-sign.sh <path-to-.app>" >&2
    exit 1
fi

APP="$1"
codesign --force --deep --sign - --options runtime --timestamp=none "$APP"
codesign --verify --verbose=2 "$APP"
