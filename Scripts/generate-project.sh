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
# The team the release is signed by; the App Group is named after it. Empty is
# a build for CI and tests -- one that runs on macOS 27 needs a team.
LIBRESCRS_TEAM_ID="${LIBRESCRS_TEAM_ID:-}"
if [ -n "$LIBRESCRS_TEAM_ID" ] && ! [[ "$LIBRESCRS_TEAM_ID" =~ ^[A-Z0-9]+$ ]]; then
    echo "error: LIBRESCRS_TEAM_ID must be upper-case letters and digits, got '$LIBRESCRS_TEAM_ID'" >&2
    exit 1
fi
export LIBRESCRS_TEAM_ID
xcodegen generate --spec project.yml --use-cache
echo "Generated $(pwd)/LibreMac.xcodeproj"
