#!/usr/bin/env sh
# SPDX-License-Identifier: LGPL-2.1-or-later
# Selftest for Scripts/check-sync-error-consumers.py.
#
# The perturbations live inside the gate itself (`--self-test`): each writes a
# throwaway copy of the tree, applies one regression, and requires the gate to
# go red with a named message. A perturbation whose edit changed nothing is
# itself reported as a failure, so the harness cannot pass by no-op, and the
# whole run refuses to start against an already-red tree.
#
# This wrapper exists so the selftest carries the name every other check here
# carries: a sweep that looks for `*.selftest.sh` finds it, rather than having
# to know that one gate hides its harness behind a flag. rc=2 means it could
# not measure — never a pass.
set -u

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
subject="$here/../../Scripts/check-sync-error-consumers.py"
[ -f "$subject" ] || { echo "missing subject: $subject" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "no python3 to run $subject" >&2; exit 2; }

exec python3 "$subject" --self-test
