#!/usr/bin/env bash
#
# Patches NIF binaries in _build for a Windows Burrito release.
#
# Burrito's NIF detection (`nif_sniff`) only finds `:elixir_make` NIFs, missing
# Rustler-based NIFs like MDEx. Additionally, Burrito's Zig cross-compilation
# uses hardcoded Unix linker flags (-Wl,-undefined=dynamic_lookup) that break
# on Windows targets. So we set `skip_nifs: true` for Windows in mix.exs and
# provide the correct Windows NIF binaries manually.
#
# This script:
#   1. Downloads the Windows precompiled MDEx NIF from GitHub releases
#   2. Cross-compiles argon2 NIF for Windows using Zig
#   3. Places both in _build so Burrito packages them
#
# Usage:
#   bash scripts/patch-windows-nifs.sh
#
# Must be run AFTER `mix compile` and BEFORE `mix release desktop`.
# Requires: curl, zig
#
set -euo pipefail

log() { echo "==> [patch-windows-nifs] $*"; }

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# ============================================================================
# MDEx (Rustler precompiled NIF)
# ============================================================================
# MDEx uses rustler_precompiled — downloads a host-platform binary at compile
# time. We replace the Linux .so with the Windows .dll from GitHub releases.

MDEX_VERSION=$(grep '@version' "$PROJECT_ROOT/deps/mdex/mix.exs" | head -1 | grep -oP '"[^"]+"' | tr -d '"')
if [ -z "$MDEX_VERSION" ]; then
  echo "ERROR: Could not determine MDEx version" >&2
  exit 1
fi
log "MDEx version: $MDEX_VERSION"

NIF_VERSION="2.15"
WINDOWS_TARGET="x86_64-pc-windows-msvc"
WINDOWS_NIF_NAME="libcomrak_nif-v${MDEX_VERSION}-nif-${NIF_VERSION}-${WINDOWS_TARGET}.dll"
DOWNLOAD_URL="https://github.com/leandrocp/mdex/releases/download/v${MDEX_VERSION}/${WINDOWS_NIF_NAME}.tar.gz"

log "Downloading Windows MDEx NIF..."
curl -fsSL "$DOWNLOAD_URL" -o "$TMPDIR/mdex-windows.tar.gz"
tar xzf "$TMPDIR/mdex-windows.tar.gz" -C "$TMPDIR"

# Find the extracted DLL (may be at root or in a subdirectory)
WINDOWS_DLL=$(find "$TMPDIR" -name "*.dll" -print -quit)
if [ -z "$WINDOWS_DLL" ]; then
  echo "ERROR: Windows DLL not found in downloaded archive" >&2
  ls -laR "$TMPDIR"
  exit 1
fi

MDEX_PRIV="$PROJECT_ROOT/_build/prod/lib/mdex/priv/native"
if [ ! -d "$MDEX_PRIV" ]; then
  echo "ERROR: MDEx priv directory not found at $MDEX_PRIV" >&2
  echo "Run 'MIX_ENV=prod mix compile' first" >&2
  exit 1
fi

rm -f "$MDEX_PRIV"/*.so
cp "$WINDOWS_DLL" "$MDEX_PRIV/$WINDOWS_NIF_NAME"
log "Patched MDEx NIF: -> $WINDOWS_NIF_NAME"

# ============================================================================
# argon2_elixir (C NIF via elixir_make)
# ============================================================================
# Cross-compile argon2 NIF for Windows using Zig.
# We do this manually (outside Burrito) because Burrito's RecompileNIFs step
# hardcodes -Wl,-undefined=dynamic_lookup in CC, which is invalid for MSVC.

ARGON2_SRC="$PROJECT_ROOT/deps/argon2_elixir"
ARGON2_PRIV="$PROJECT_ROOT/_build/prod/lib/argon2_elixir/priv"

if [ ! -d "$ARGON2_SRC" ]; then
  echo "ERROR: argon2_elixir source not found at $ARGON2_SRC" >&2
  exit 1
fi

log "Cross-compiling argon2 NIF for Windows..."

# Locate ERTS headers for NIF compilation
ERTS_INCLUDE=$(find /usr/local/lib/erlang/erts-* -name erl_nif.h -printf '%h\n' 2>/dev/null | head -1)
if [ -z "$ERTS_INCLUDE" ]; then
  ERTS_INCLUDE=$(find "$(dirname "$(dirname "$(which erl)")")"/lib/erlang/erts-* -name erl_nif.h -printf '%h\n' 2>/dev/null | head -1)
fi
if [ -z "$ERTS_INCLUDE" ]; then
  echo "ERROR: Could not find ERTS include directory (erl_nif.h)" >&2
  exit 1
fi

EI_INCLUDE=$(find /usr/local/lib/erlang -path '*/usr/include/ei.h' -printf '%h\n' 2>/dev/null | head -1)
if [ -z "$EI_INCLUDE" ]; then
  EI_INCLUDE=$(find "$(dirname "$(dirname "$(which erl)")")"/lib/erlang -path '*/usr/include/ei.h' -printf '%h\n' 2>/dev/null | head -1)
fi

ZIG_TARGET="x86_64-windows-gnu"
ARGON2_BUILD="$TMPDIR/argon2_build"
mkdir -p "$ARGON2_BUILD"

# Compile argon2 source files
ARGON2_SRCS=(
  "$ARGON2_SRC/argon2/src/argon2.c"
  "$ARGON2_SRC/argon2/src/core.c"
  "$ARGON2_SRC/argon2/src/blake2/blake2b.c"
  "$ARGON2_SRC/argon2/src/thread.c"
  "$ARGON2_SRC/argon2/src/encoding.c"
  "$ARGON2_SRC/argon2/src/ref.c"
  "$ARGON2_SRC/c_src/argon2_nif.c"
)

INCLUDE_FLAGS=(
  "-I$ARGON2_SRC/argon2/include"
  "-I$ARGON2_SRC/argon2/src"
  "-I$ERTS_INCLUDE"
)
if [ -n "${EI_INCLUDE:-}" ]; then
  INCLUDE_FLAGS+=("-I$EI_INCLUDE")
fi

# Compile each .c to .o
OBJECTS=()
for src in "${ARGON2_SRCS[@]}"; do
  obj="$ARGON2_BUILD/$(basename "${src%.c}.o")"
  zig cc -target "$ZIG_TARGET" -O2 -DARGON2_NO_THREADS -c "$src" "${INCLUDE_FLAGS[@]}" -o "$obj"
  OBJECTS+=("$obj")
done

# Link into DLL
zig cc -target "$ZIG_TARGET" -shared -o "$ARGON2_BUILD/argon2_nif.dll" "${OBJECTS[@]}"

mkdir -p "$ARGON2_PRIV"
rm -f "$ARGON2_PRIV/argon2_nif.so"
cp "$ARGON2_BUILD/argon2_nif.dll" "$ARGON2_PRIV/argon2_nif.dll"
log "Patched argon2 NIF: -> argon2_nif.dll"

log "All Windows NIFs patched successfully"
