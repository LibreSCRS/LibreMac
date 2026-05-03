#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# SPDX-FileCopyrightText: 2026 hirashix0
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate --spec project.yml --use-cache
echo "Generated $(pwd)/LibreMac.xcodeproj"
