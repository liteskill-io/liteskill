#!/usr/bin/env bash
#
# Verifies that Windows NIF binaries are present in the Burrito release.
# Run AFTER `mix release desktop --overwrite` to catch missing NIFs early.
#
# Usage:
#   bash scripts/verify-windows-nifs.sh
#
set -euo pipefail

log() { echo "==> [verify-windows-nifs] $*"; }

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RELEASE_DIR="$PROJECT_ROOT/_build/prod/rel/desktop"
ERRORS=0

check_nif() {
  local dep_name="$1"
  local pattern="$2"
  local found

  found=$(find "$RELEASE_DIR" -name "$pattern" 2>/dev/null | head -1)
  if [ -n "$found" ]; then
    log "OK: $dep_name NIF found: $(basename "$found")"
  else
    log "MISSING: $dep_name NIF (pattern: $pattern)"
    # Show what's actually there
    log "  Contents of ${dep_name} priv:"
    find "$RELEASE_DIR" -path "*/${dep_name}*/priv/*" -type f 2>/dev/null | while read -r f; do
      log "    $(basename "$f")"
    done
    ERRORS=$((ERRORS + 1))
  fi
}

if [ ! -d "$RELEASE_DIR" ]; then
  echo "ERROR: Release directory not found at $RELEASE_DIR" >&2
  echo "Run 'mix release desktop --overwrite' first" >&2
  exit 1
fi

log "Checking NIFs in release: $RELEASE_DIR"
check_nif "mdex" "*.dll"
check_nif "argon2_elixir" "argon2_nif.dll"

if [ "$ERRORS" -gt 0 ]; then
  log "FAILED: $ERRORS NIF(s) missing"
  exit 1
fi

log "All Windows NIFs verified"
