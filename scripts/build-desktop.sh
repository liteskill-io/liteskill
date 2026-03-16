#!/usr/bin/env bash
#
# Shared desktop build script used by both Docker and GitHub Actions CI.
# Handles everything after system dependencies + toolchains are installed:
#   ERTS packaging → Elixir build → Burrito → Tauri → post-process
#
# Usage:
#   MIX_ENV=prod bash scripts/build-desktop.sh <target-triple>
#
# Requires on PATH: erl, elixir, node, npm, cargo, cargo-tauri, zig
# Linux also requires: patchelf
#
# Supported triples:
#   x86_64-unknown-linux-gnu
#   aarch64-apple-darwin
#   x86_64-apple-darwin
#
# For Windows, use scripts/build-tauri-windows.sh with a cross-compiled
# sidecar (Burrito cross-compiles from Linux with Zig).
#
set -euo pipefail

TRIPLE="${1:?Usage: $0 <target-triple>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

log() { echo "==> [build-desktop] $*"; }

# ---------------------------------------------------------------------------
# Phase 0: Validate environment & resolve target
# ---------------------------------------------------------------------------
if [ "${MIX_ENV:-}" != "prod" ]; then
  echo "ERROR: MIX_ENV must be set to 'prod'" >&2
  exit 1
fi

case "$TRIPLE" in
  x86_64-unknown-linux-gnu)
    BURRITO_TARGET="linux_x86_64"
    ;;
  aarch64-apple-darwin)
    BURRITO_TARGET="macos_aarch64"
    ;;
  x86_64-apple-darwin)
    BURRITO_TARGET="macos_x86_64"
    ;;
  *)
    echo "ERROR: Unsupported target triple: $TRIPLE" >&2
    echo "Supported: x86_64-unknown-linux-gnu, aarch64-apple-darwin, x86_64-apple-darwin" >&2
    echo "For Windows, use scripts/build-tauri-windows.sh" >&2
    exit 1
    ;;
esac

log "Target triple: $TRIPLE"
log "Burrito target: $BURRITO_TARGET"

# ---------------------------------------------------------------------------
# Phase 1: Package glibc ERTS for Burrito (Linux only)
# ---------------------------------------------------------------------------
# Burrito's default is musl-linked ERTS, which conflicts with glibc NIFs
# (MDEx, argon2). Tar up the glibc-linked ERTS and tell Burrito to use it.
# On macOS, Burrito downloads a universal precompiled ERTS — no custom ERTS needed.
case "$TRIPLE" in
  *-linux-*)
    log "Packaging glibc ERTS for Burrito..."

    ERTS_DIR="$(dirname "$(dirname "$(which erl)")")/lib/erlang"
    if [ ! -d "$ERTS_DIR" ]; then
      echo "ERROR: ERTS directory not found at $ERTS_DIR" >&2
      exit 1
    fi

    # Bundle OpenSSL libs alongside crypto.so when they're dynamically linked.
    # Both Docker and CI compile Erlang with --disable-dynamic-ssl-lib (static SSL)
    # via setup-erlang-elixir.sh, so ldd won't find libssl/libcrypto and the copy
    # loop below is a no-op. Kept for safety in case a future environment uses
    # a dynamically-linked Erlang.
    CRYPTO_SO="$(find "$ERTS_DIR" -name crypto.so -print -quit)"
    if [ -n "$CRYPTO_SO" ]; then
      CRYPTO_DIR="$(dirname "$CRYPTO_SO")"
      ldd "$CRYPTO_SO" | grep -oP '/\S+lib(ssl|crypto)\.so\S*' | while read -r lib; do
        cp -L "$lib" "$CRYPTO_DIR/"
        log "Bundled $(basename "$lib") into ERTS"
      done || true  # grep returns 1 when no matches (static SSL) — not an error
      # Only patch rpath if we actually copied libs
      if ldd "$CRYPTO_SO" | grep -q 'libssl\.so'; then
        patchelf --set-rpath '$ORIGIN' "$CRYPTO_SO"
        log "Patched crypto.so rpath to \$ORIGIN"
      fi
    fi

    tar czf /tmp/glibc_erts.tar.gz -C "$ERTS_DIR" .
    export BURRITO_CUSTOM_ERTS=/tmp/glibc_erts.tar.gz
    log "Packaged glibc ERTS from $ERTS_DIR"
    ;;
  *)
    log "Skipping ERTS packaging (not needed for $TRIPLE)"
    ;;
esac

# ---------------------------------------------------------------------------
# Phase 2: Elixir build
# ---------------------------------------------------------------------------
log "Building Elixir release..."
cd "$PROJECT_ROOT"

# Ensure HOME is set so mix local.hex/rebar can write to ~/.mix
export HOME="${HOME:-/root}"

mix local.hex --force
mix local.rebar --force
mix deps.get --only prod

# Force-recompile deps for the current platform. When running in Docker with
# a mounted host project, _build may contain deps compiled on macOS with
# host-specific absolute paths baked into BEAM files (Burrito stores its
# source path for git metadata). Force-recompiling ensures all deps use
# container-local paths.
mix deps.compile --force

npm install --prefix assets
mix compile
mix assets.deploy

# ---------------------------------------------------------------------------
# Phase 3: Burrito release
# ---------------------------------------------------------------------------
log "Building Burrito release..."
export BURRITO_TARGET="$BURRITO_TARGET"
mix release desktop --overwrite
log "Burrito output:" && ls -la burrito_out/

# ---------------------------------------------------------------------------
# Phase 4: Rename Burrito output for Tauri sidecar naming
# ---------------------------------------------------------------------------
# Burrito outputs: burrito_out/desktop_<burrito_target>
# Tauri expects:   burrito_out/desktop-<target-triple>
BURRITO_OUT="burrito_out/desktop_${BURRITO_TARGET}"
SIDECAR_NAME="burrito_out/desktop-${TRIPLE}"

if [ -f "$BURRITO_OUT" ]; then
  mv "$BURRITO_OUT" "$SIDECAR_NAME"
  log "Renamed sidecar: $BURRITO_OUT -> $SIDECAR_NAME"
else
  echo "ERROR: Burrito output not found at $BURRITO_OUT" >&2
  ls -la burrito_out/
  exit 1
fi

# ---------------------------------------------------------------------------
# Phase 5: Build Tauri app
# ---------------------------------------------------------------------------
log "Building Tauri app..."

# Sync Tauri version from the project VERSION file
APP_VERSION="$(cat "$PROJECT_ROOT/VERSION" | tr -d '[:space:]')"
log "Setting Tauri version to $APP_VERSION"
# sed -i behaves differently on macOS (BSD) vs Linux (GNU).
# Using .bak suffix works on both, then remove the backup.
sed -i.bak "s/\"version\": \".*\"/\"version\": \"$APP_VERSION\"/" "$PROJECT_ROOT/src-tauri/tauri.conf.json"
rm -f "$PROJECT_ROOT/src-tauri/tauri.conf.json.bak"

# linuxdeploy (used by Tauri's AppImage bundler) is itself an AppImage.
# Inside Docker there's no FUSE, so tell AppImage tools to extract-and-run.
export APPIMAGE_EXTRACT_AND_RUN=1

cd "$PROJECT_ROOT/src-tauri"
case "$TRIPLE" in
  *-linux-*)
    # Skip AppImage bundling — Tauri's built-in AppImage bundler uses
    # linuxdeploy with --plugin gtk, which calls linuxdeploy back as a
    # subprocess. Under Rosetta/QEMU emulation, the linuxdeploy AppImage
    # binary can't be re-executed by bash (ELF ABI version corrupted by
    # AppImage magic bytes, rejected by glibc's dynamic linker). We build
    # deb+rpm here and create the AppImage manually in Phase 6.
    cargo tauri build --bundles deb,rpm
    ;;
  *)
    cargo tauri build
    ;;
esac
cd "$PROJECT_ROOT"

# ---------------------------------------------------------------------------
# Phase 6: Platform-specific post-processing
# ---------------------------------------------------------------------------
case "$TRIPLE" in
  *-linux-*)
    # Create AppImage manually using linuxdeploy (without GTK plugin).
    #
    # Why not use Tauri's built-in AppImage bundler?
    # Tauri's bundler runs linuxdeploy with --plugin gtk. The GTK plugin
    # calls linuxdeploy back as a subprocess. Under Rosetta/QEMU emulation
    # (ARM Mac building x86_64 via Docker), the linuxdeploy AppImage binary
    # has AppImage magic bytes (AI\x02) at ELF offset 8 that corrupt the
    # ABI version field. The glibc dynamic linker rejects this invalid ABI
    # version, so bash can't re-exec the binary. The first invocation works
    # because Tauri passes --appimage-extract-and-run as a CLI flag, but the
    # GTK plugin's callback doesn't, causing "subprocess failed (exit code 2)".
    #
    # linuxdeploy without the GTK plugin handles library bundling perfectly
    # via ldd analysis — the GTK plugin just adds optional schema/hook files.
    log "Creating AppImage with linuxdeploy..."

    APPIMAGE_DIR="src-tauri/target/release/bundle/appimage"
    APPDIR="$APPIMAGE_DIR/Liteskill.AppDir"
    TOOLS_DIR="/tmp/appimage-tools"
    mkdir -p "$TOOLS_DIR" "$APPIMAGE_DIR"

    # Download linuxdeploy
    wget -q -O "$TOOLS_DIR/linuxdeploy.AppImage" \
      https://github.com/tauri-apps/binary-releases/releases/download/linuxdeploy/linuxdeploy-x86_64.AppImage
    chmod +x "$TOOLS_DIR/linuxdeploy.AppImage"

    # Fix AppImage magic bytes for Rosetta compatibility: zero bytes 8-10
    # to restore valid ELF ABI version (AppImage overwrites these with AI\x02).
    dd if=/dev/zero bs=1 count=3 seek=8 conv=notrunc of="$TOOLS_DIR/linuxdeploy.AppImage" 2>/dev/null

    # Find the .desktop file and icon from the deb bundle.
    # The .desktop file uses Icon=liteskill, so the icon must be named liteskill.png
    # for linuxdeploy to match them.
    DESKTOP_FILE=$(find src-tauri/target/release/bundle -name '*.desktop' -print -quit)
    ICON_FILE="/tmp/liteskill.png"
    cp src-tauri/icons/icon.png "$ICON_FILE"

    if [ -z "$DESKTOP_FILE" ]; then
      echo "ERROR: No .desktop file found in deb bundle" >&2
      exit 1
    fi

    log "Using desktop file: $DESKTOP_FILE"

    # Step 1: Run linuxdeploy to create AppDir with all shared libraries.
    # Skipping --plugin gtk avoids the subprocess callback issue.
    # linuxdeploy's built-in ldd analysis bundles all needed libraries.
    "$TOOLS_DIR/linuxdeploy.AppImage" \
      --appimage-extract-and-run \
      --appdir "$APPDIR" \
      --executable src-tauri/target/release/liteskill \
      --desktop-file "$DESKTOP_FILE" \
      --icon-file "$ICON_FILE"

    # Step 2: Add sidecar and extra libs to AppDir before packing.
    cp burrito_out/desktop-"$TRIPLE" "$APPDIR/usr/bin/desktop"
    chmod +x "$APPDIR/usr/bin/desktop"

    # Copy libayatana-appindicator (system tray support, not caught by ldd)
    APPINDICATOR=$(find /usr/lib -name 'libayatana-appindicator3.so.1' -print -quit 2>/dev/null || true)
    if [ -n "$APPINDICATOR" ]; then
      cp -L "$APPINDICATOR" "$APPDIR/usr/lib/"
      log "Bundled libayatana-appindicator3"
    fi

    # Step 3: Bundle WebKitGTK runtime dependencies NOT caught by ldd.
    #
    # linuxdeploy's ldd analysis bundles libwebkit2gtk-4.1.so and its
    # transitive .so dependencies, but WebKitGTK also requires:
    #   - Subprocess executables (WebKitWebProcess, WebKitNetworkProcess)
    #   - GSettings schemas (compiled .xml for GTK, WebKit, GLib)
    #   - GDK pixbuf loaders (image format decoders)
    #   - GIO modules (dconf, etc.)
    # Without these the AppImage fails on distros that don't ship the
    # exact same WebKitGTK version (e.g. Fedora, Arch, openSUSE).
    log "Bundling WebKitGTK runtime dependencies..."

    # 3a: WebKit subprocess executables — spawned at runtime by the library.
    WEBKIT_EXEC_DIR=$(find /usr/lib* -type d -name 'webkit2gtk-4.1' 2>/dev/null | head -1)
    if [ -z "$WEBKIT_EXEC_DIR" ]; then
      # Fedora/Arch path variant
      WEBKIT_EXEC_DIR=$(find /usr/libexec -type d -name 'webkit2gtk-4.1' 2>/dev/null | head -1)
    fi
    if [ -n "$WEBKIT_EXEC_DIR" ]; then
      mkdir -p "$APPDIR/usr/lib/webkit2gtk-4.1"
      for proc in WebKitWebProcess WebKitNetworkProcess; do
        PROC_BIN=$(find "$WEBKIT_EXEC_DIR" -name "$proc" -print -quit 2>/dev/null || true)
        if [ -n "$PROC_BIN" ]; then
          cp -L "$PROC_BIN" "$APPDIR/usr/lib/webkit2gtk-4.1/"
          chmod +x "$APPDIR/usr/lib/webkit2gtk-4.1/$proc"
          # Bundle any .so deps the subprocess needs that aren't already in AppDir
          ldd "$PROC_BIN" 2>/dev/null | grep '=> /' | awk '{print $3}' | while read -r dep; do
            dep_name=$(basename "$dep")
            if [ ! -f "$APPDIR/usr/lib/$dep_name" ]; then
              cp -L "$dep" "$APPDIR/usr/lib/" 2>/dev/null || true
            fi
          done
          log "Bundled $proc"
        fi
      done
      # Also bundle injected-bundle .so if present (used by web extensions)
      find "$WEBKIT_EXEC_DIR" -name '*.so' -exec cp -L {} "$APPDIR/usr/lib/webkit2gtk-4.1/" \; 2>/dev/null || true
    else
      log "WARNING: WebKit exec dir not found — WebKitWebProcess won't be bundled"
    fi

    # 3b: GSettings schemas — GTK, WebKit, GLib all need compiled schemas.
    SCHEMAS_DIR="$APPDIR/usr/share/glib-2.0/schemas"
    mkdir -p "$SCHEMAS_DIR"
    for schema_dir in /usr/share/glib-2.0/schemas; do
      if [ -d "$schema_dir" ]; then
        cp -n "$schema_dir"/*.xml "$SCHEMAS_DIR/" 2>/dev/null || true
        cp -n "$schema_dir"/*.override "$SCHEMAS_DIR/" 2>/dev/null || true
      fi
    done
    # Compile schemas in the AppDir (requires glib-compile-schemas on build host)
    if command -v glib-compile-schemas &>/dev/null; then
      glib-compile-schemas "$SCHEMAS_DIR" 2>/dev/null || true
      log "Compiled GSettings schemas"
    fi

    # 3c: GDK pixbuf loaders — needed for image rendering in WebKitGTK.
    GDK_PIXBUF_QUERY=$(command -v gdk-pixbuf-query-loaders 2>/dev/null || true)
    if [ -n "$GDK_PIXBUF_QUERY" ]; then
      GDK_PIXBUF_MODULEDIR=$("$GDK_PIXBUF_QUERY" 2>/dev/null | grep -oP '"/[^"]+/loaders"' | tr -d '"' | head -1 || true)
      if [ -n "$GDK_PIXBUF_MODULEDIR" ] && [ -d "$GDK_PIXBUF_MODULEDIR" ]; then
        APPDIR_LOADERS="$APPDIR/usr/lib/gdk-pixbuf-2.0/2.10.0/loaders"
        mkdir -p "$APPDIR_LOADERS"
        cp -L "$GDK_PIXBUF_MODULEDIR"/*.so "$APPDIR_LOADERS/" 2>/dev/null || true
        # Generate loaders.cache pointing to the bundled loaders
        GDK_PIXBUF_MODULE_FILE="$APPDIR/usr/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache"
        "$GDK_PIXBUF_QUERY" "$APPDIR_LOADERS"/*.so 2>/dev/null > "$GDK_PIXBUF_MODULE_FILE" || true
        log "Bundled GDK pixbuf loaders"
      fi
    fi

    # 3d: GIO modules (dconf backend, etc.)
    GIO_MODULE_DIR=$(pkg-config --variable=giomoduledir gio-2.0 2>/dev/null || echo "/usr/lib/x86_64-linux-gnu/gio/modules")
    if [ -d "$GIO_MODULE_DIR" ]; then
      mkdir -p "$APPDIR/usr/lib/gio/modules"
      cp -L "$GIO_MODULE_DIR"/*.so "$APPDIR/usr/lib/gio/modules/" 2>/dev/null || true
      # Compile GIO module cache
      if command -v gio-querymodules &>/dev/null; then
        gio-querymodules "$APPDIR/usr/lib/gio/modules" 2>/dev/null || true
      fi
      log "Bundled GIO modules"
    fi

    # Step 4: Strip Wayland libs BEFORE packing. linuxdeploy bundles
    # libwayland-*.so from the build host. These conflict with the host
    # system's Wayland/EGL stack at runtime, causing WebKitGTK to crash
    # with "Could not create default EGL display: EGL_BAD_PARAMETER".
    WAYLAND_COUNT=$(find "$APPDIR/usr/lib" -name '*wayland*so*' 2>/dev/null | wc -l)
    if [ "$WAYLAND_COUNT" -gt 0 ]; then
      rm -f "$APPDIR"/usr/lib/*wayland*so*
      log "Stripped $WAYLAND_COUNT Wayland libs from AppDir"
    fi

    # Step 5: Install custom AppRun that sets WebKitGTK environment vars.
    # linuxdeploy's default AppRun sets LD_LIBRARY_PATH but not the GTK/
    # WebKit-specific paths needed for bundled schemas, loaders, and
    # subprocess executables.
    cat > "$APPDIR/AppRun" << 'APPRUN_EOF'
#!/bin/bash
HERE="$(dirname "$(readlink -f "$0")")"

export LD_LIBRARY_PATH="$HERE/usr/lib:${LD_LIBRARY_PATH}"

# WebKitGTK subprocess executables (WebKitWebProcess, WebKitNetworkProcess)
export WEBKIT2_EXEC_PATH="$HERE/usr/lib/webkit2gtk-4.1"

# GSettings schemas (GTK, WebKit, GLib)
export GSETTINGS_SCHEMA_DIR="$HERE/usr/share/glib-2.0/schemas:${GSETTINGS_SCHEMA_DIR}"
export XDG_DATA_DIRS="$HERE/usr/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"

# GDK pixbuf loaders
if [ -f "$HERE/usr/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache" ]; then
  export GDK_PIXBUF_MODULE_FILE="$HERE/usr/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache"
  export GDK_PIXBUF_MODULEDIR="$HERE/usr/lib/gdk-pixbuf-2.0/2.10.0/loaders"
fi

# GIO modules
if [ -d "$HERE/usr/lib/gio/modules" ]; then
  export GIO_MODULE_DIR="$HERE/usr/lib/gio/modules"
fi

# Disable DMA-BUF renderer (fallback; also set in Rust main.rs)
export WEBKIT_DISABLE_DMABUF_RENDERER="${WEBKIT_DISABLE_DMABUF_RENDERER:-1}"

exec "$HERE/usr/bin/liteskill" "$@"
APPRUN_EOF
    chmod +x "$APPDIR/AppRun"
    log "Installed custom AppRun with WebKitGTK env vars"

    # Step 6: Pack AppDir into AppImage using linuxdeploy's built-in
    # appimagetool (via --output appimage on the populated AppDir).
    APP_VERSION="$(cat VERSION | tr -d '[:space:]')"
    FINAL_NAME="Liteskill_${APP_VERSION}_amd64.AppImage"
    export OUTPUT="$APPIMAGE_DIR/$FINAL_NAME"
    "$TOOLS_DIR/linuxdeploy.AppImage" \
      --appimage-extract-and-run \
      --appdir "$APPDIR" \
      --output appimage

    rm -rf "$TOOLS_DIR"
    log "AppImage created: $APPIMAGE_DIR/$FINAL_NAME"
    ;;
  *-apple-darwin)
    APP_BUNDLE=$(find src-tauri/target/release/bundle/macos -name '*.app' -print -quit 2>/dev/null || true)
    if [ -n "$APP_BUNDLE" ]; then
      # Ad-hoc sign the entire bundle (Tauri only linker-signs the binary;
      # Finder requires a proper codesign signature to launch apps).
      log "Signing app bundle..."
      codesign --force --deep --sign - "$APP_BUNDLE"

      # Create DMG for distribution
      APP_NAME="$(basename "$APP_BUNDLE" .app)"
      VERSION="$(cat VERSION | tr -d '[:space:]')"
      ARCH="${TRIPLE%%-*}"
      DMG_NAME="${APP_NAME}_${VERSION}_${ARCH}.dmg"
      DMG_DIR="$(dirname "$APP_BUNDLE")"

      log "Creating DMG: $DMG_NAME"
      hdiutil create \
        -volname "$APP_NAME" \
        -srcfolder "$APP_BUNDLE" \
        -ov -format UDZO \
        "$DMG_DIR/$DMG_NAME"
      log "DMG created at $DMG_DIR/$DMG_NAME"
    else
      log "WARNING: No .app bundle found, skipping sign+DMG"
    fi
    ;;
esac

# ---------------------------------------------------------------------------
# Phase 7: Verify artifacts
# ---------------------------------------------------------------------------
log "=== Build artifacts ==="
find src-tauri/target/release/bundle -type f \( \
  -name "*.AppImage" -o -name "*.deb" -o -name "*.rpm" \
  -o -name "*.dmg" -o -name "*.app" \
  -o -name "*.msi" -o -name "*-setup.exe" \
\) -exec ls -lh {} \; 2>/dev/null || true
log "=== BUILD SUCCESS ==="
