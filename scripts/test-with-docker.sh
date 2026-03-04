#!/usr/bin/env bash
set -euo pipefail

# SQLite is file-based — no database container needed.
# Uses a temp directory for test databases, cleaned up on exit.

TMPDIR=$(mktemp -d)
cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

export DATABASE_PATH="$TMPDIR/liteskill_test.db"
export MIX_ENV=test

mix "${@:-test}"
