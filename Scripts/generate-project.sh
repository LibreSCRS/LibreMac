#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# SPDX-FileCopyrightText: 2026 hirashix0
set -euo pipefail
cd "$(dirname "$0")/.."
# project.yml takes MARKETING_VERSION from this environment variable, so the
# generated project stamps the number in VERSION instead of a second hand-typed
# copy of it. xcodegen substitutes ${VAR} in the spec at generate time.
LIBREMAC_VERSION="$(head -1 VERSION | tr -d '[:space:]')"
if [ -z "$LIBREMAC_VERSION" ]; then
    echo "error: VERSION is empty or missing -- refusing to generate a project with no marketing version" >&2
    exit 1
fi
export LIBREMAC_VERSION
xcodegen generate --spec project.yml --use-cache
echo "Generated $(pwd)/LibreMac.xcodeproj"
