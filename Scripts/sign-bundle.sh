#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# SPDX-FileCopyrightText: 2026 hirashix0
#
# Signs a LibreMac .app that Xcode built unsigned and Scripts/bundle-agent.sh
# staged: inside-out, never --deep, each component with its own identifier and
# its entitlements from Packaging/entitlements/ (the one source -- project.yml
# names none, so Xcode cannot sign a second, different set). Order: staged
# dylibs and plugins -> prompter -> agent -> code nested in the token
# extension -> the token extension -> the host, last. Nothing may touch the
# bundle afterwards.
#
# Xcode builds unsigned because Xcode 26 refuses an ad hoc build that carries
# application-groups or keychain-access-groups ("requires a provisioning
# profile"); codesign has no such rule.
#
# CODESIGN_IDENTITY (env, default "-" = ad hoc). Every signature carries the
# hardened runtime. An ad hoc signature carries no timestamp; any other
# identity gets Apple's secure timestamp, which notarization requires.
# Signing with such an identity therefore needs Apple's timestamp server
# (network access).
#
# Library validation: the hardened runtime makes dyld accept only libraries
# signed by the executable's own team. An ad hoc signature has no team, so the
# agent gets com.apple.security.cs.disable-library-validation exactly when the
# bundle names no team. A team-signed bundle validates and does not get it.
#
# App Group: every component is signed into the one group named after the team
# (see below); the group in Packaging/entitlements/ is a placeholder replaced
# on a copy, so the files hold no team.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENTS="$REPO_ROOT/Packaging/entitlements"

APP_PATH="${1:?usage: sign-bundle.sh <path-to-LibreMac.app>}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
[ -d "$APP_PATH" ] || { echo "sign-bundle: no such app bundle: $APP_PATH" >&2; exit 1; }

MACOS="$APP_PATH/Contents/MacOS"
FRAMEWORKS="$APP_PATH/Contents/Frameworks"
PLUGINS="$APP_PATH/Contents/PlugIns/librescrs"
TOKEN_APPEX="$APP_PATH/Contents/PlugIns/LibreMacToken.appex"
for f in "$MACOS/librescrs-agent" "$MACOS/librescrs-prompter"; do
    [ -x "$f" ] || { echo "sign-bundle: $f missing -- run Scripts/bundle-agent.sh first" >&2; exit 1; }
done
[ -d "$TOKEN_APPEX" ] || { echo "sign-bundle: LibreMacToken.appex not nested under Contents/PlugIns (build the host target first)" >&2; exit 1; }

# ---------------------------------------------------------------- team id
# The host and the token extension hold the agent to the designated requirement
# of the team LIBRESCRS_TEAM_ID names (set in the environment of
# Scripts/generate-project.sh; Xcode writes it into both Info.plists as
# LibreSCRSTeamID). Read from the built bundle, because that is
# the value the clients enforce. The identity signing here must be that team:
# ad hoc with a team named ships clients that refuse their own agent, and a
# team identity with no team named ships clients that never check who signed
# the agent.
read_team_id() {  # read_team_id <Info.plist> <what>
    plutil -extract LibreSCRSTeamID raw -o - "$1" 2>/dev/null || {
        echo "sign-bundle: the $2 Info.plist carries no LibreSCRSTeamID ($1) -- regenerate the project (Scripts/generate-project.sh) and rebuild" >&2
        return 1
    }
}
team_host="$(read_team_id "$APP_PATH/Contents/Info.plist" host)" || exit 1
team_appex="$(read_team_id "$TOKEN_APPEX/Contents/Info.plist" "token extension")" || exit 1
[ "$team_host" = "$team_appex" ] || {
    echo "sign-bundle: the host names team '$team_host' and the token extension '$team_appex' -- rebuild both from one project.yml" >&2
    exit 1
}
LIBRESCRS_TEAM_ID="$team_host"
if [ "$CODESIGN_IDENTITY" = "-" ] && [ -n "$LIBRESCRS_TEAM_ID" ]; then
    echo "sign-bundle: LIBRESCRS_TEAM_ID is '$LIBRESCRS_TEAM_ID' but CODESIGN_IDENTITY is ad hoc: the clients would require that team's signature on an agent that has none -- set CODESIGN_IDENTITY to that team's identity, or clear LIBRESCRS_TEAM_ID in the environment of Scripts/generate-project.sh and rebuild" >&2
    exit 1
fi

# ---------------------------------------------------------------- App Group
# The group is named after the team: macOS 27 refuses an unprovisioned
# "group." container to a sandboxed process, and a group prefixed with the
# signing team's ID needs no profile. Without a team (CI, tests) it stays
# "group.". The clients and the agent derive it by the same rule from the same
# team, so a component signed into any other group cannot reach the socket.
if [ -n "$LIBRESCRS_TEAM_ID" ]; then
    app_group="$LIBRESCRS_TEAM_ID.org.librescrs.LibreMac"
else
    app_group="group.org.librescrs.LibreMac"
fi

# Every entitlement is signed from a copy here, never from the source file,
# and all four are written before anything is signed.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
for part in agent prompter token host; do
    cp "$ENTS/$part.plist" "$work/$part.plist"
    /usr/libexec/PlistBuddy -c "Set :com.apple.security.application-groups:0 $app_group" "$work/$part.plist"
done
echo "sign-bundle: App Group $app_group"

timestamp=--timestamp=none
[ "$CODESIGN_IDENTITY" = "-" ] || timestamp=--timestamp
sign() { codesign --force -s "$CODESIGN_IDENTITY" --options runtime "$timestamp" "$@"; }

shopt -s nullglob
for lib in "$FRAMEWORKS"/*.dylib "$PLUGINS"/*.dylib; do
    sign "$lib"
done

if [ -z "$LIBRESCRS_TEAM_ID" ]; then
    /usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.disable-library-validation bool true" "$work/agent.plist"
    echo "sign-bundle: no team named -- the agent carries disable-library-validation"
fi

sign --identifier org.librescrs.prompter --entitlements "$work/prompter.plist" "$MACOS/librescrs-prompter"
sign --identifier org.librescrs.agent --entitlements "$work/agent.plist" "$MACOS/librescrs-agent"
if [ "$CODESIGN_IDENTITY" != "-" ]; then
    signed_team="$(codesign -dv "$MACOS/librescrs-agent" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
    if [ "$signed_team" != "$LIBRESCRS_TEAM_ID" ]; then
        consequence="refuse this agent"
        [ -n "$LIBRESCRS_TEAM_ID" ] || consequence="never check who signed the agent"
        echo "sign-bundle: the agent was signed by team '$signed_team' but LIBRESCRS_TEAM_ID is '$LIBRESCRS_TEAM_ID': the clients would $consequence -- set LIBRESCRS_TEAM_ID in the environment of Scripts/generate-project.sh to the signing team and rebuild" >&2
        exit 1
    fi
fi

for nested in "$TOKEN_APPEX/Contents/Frameworks"/*; do
    sign "$nested"
done
shopt -u nullglob
sign --entitlements "$work/token.plist" "$TOKEN_APPEX"

# The host LAST.
sign --entitlements "$work/host.plist" "$APP_PATH"

id_label="ad-hoc"
[ "$CODESIGN_IDENTITY" = "-" ] || id_label="identity=$CODESIGN_IDENTITY"
echo "sign-bundle: signed dylibs + plugins + prompter + agent + token extension + host ($id_label, inside-out, hardened runtime)"
