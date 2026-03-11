#!/usr/bin/env bash
#
# Windows-only: Build the Tauri shell around a pre-built Burrito sidecar.
#
# The Burrito sidecar (.exe) is cross-compiled from Linux (Zig handles NIF
# cross-compilation). This script only builds the Tauri Rust wrapper and
# produces NSIS/MSI installers.
#
# Usage:
#   bash scripts/build-tauri-windows.sh <path-to-sidecar.exe>
#
# Requires on PATH: cargo, cargo-tauri
#
set -euo pipefail

SIDECAR_PATH="${1:?Usage: $0 <path-to-sidecar.exe>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TRIPLE="x86_64-pc-windows-msvc"

log() { echo "==> [build-tauri-windows] $*"; }

if [ ! -f "$SIDECAR_PATH" ]; then
  echo "ERROR: Sidecar not found at $SIDECAR_PATH" >&2
  exit 1
fi

# Place sidecar where Tauri expects it
mkdir -p "$PROJECT_ROOT/burrito_out"
cp "$SIDECAR_PATH" "$PROJECT_ROOT/burrito_out/desktop-${TRIPLE}.exe"
log "Sidecar installed: burrito_out/desktop-${TRIPLE}.exe ($(du -h "$SIDECAR_PATH" | cut -f1))"

# Sync Tauri version from the project VERSION file
APP_VERSION="$(cat "$PROJECT_ROOT/VERSION" | tr -d '[:space:]')"
log "Setting Tauri version to $APP_VERSION"
sed -i.bak "s/\"version\": \".*\"/\"version\": \"$APP_VERSION\"/" "$PROJECT_ROOT/src-tauri/tauri.conf.json"
rm -f "$PROJECT_ROOT/src-tauri/tauri.conf.json.bak"

# Build Tauri NSIS + MSI installers
log "Building Tauri app..."
cd "$PROJECT_ROOT/src-tauri"
cargo tauri build --bundles nsis,msi
cd "$PROJECT_ROOT"

# Verify artifacts
log "=== Build artifacts ==="
find src-tauri/target/release/bundle -type f \( \
  -name "*.msi" -o -name "*-setup.exe" -o -name "*.nsis*" \
\) -exec ls -lh {} \; 2>/dev/null || true
log "=== BUILD SUCCESS ==="
