#!/usr/bin/env bash
#
# Compiles Erlang OTP and Elixir from source with identical flags.
# Used by both the Docker toolchain image and GitHub Actions CI to ensure
# the same BEAM runtime in every build environment.
#
# Env vars (with defaults):
#   OTP_VERSION     (default: 28.3.1)
#   ELIXIR_VERSION  (default: 1.18.4)
#
# Prerequisites on PATH: wget (or curl), make, gcc
# Prerequisites installed: libssl-dev, libncurses-dev
#
# Installs to /usr/local — caller must have write access (root in Docker,
# sudo in CI).
#
set -euo pipefail

OTP_VERSION="${OTP_VERSION:-28.3.1}"
ELIXIR_VERSION="${ELIXIR_VERSION:-1.18.4}"

log() { echo "==> [setup-erlang-elixir] $*"; }

# ---------------------------------------------------------------------------
# Erlang OTP
# ---------------------------------------------------------------------------
log "Compiling Erlang OTP ${OTP_VERSION}..."

cd /tmp
wget -q "https://github.com/erlang/otp/releases/download/OTP-${OTP_VERSION}/otp_src_${OTP_VERSION}.tar.gz"
tar xzf "otp_src_${OTP_VERSION}.tar.gz"
cd "otp_src_${OTP_VERSION}"

# When cross-compiling under emulation (e.g. x86_64 Docker on ARM Mac via
# Rosetta/QEMU), the JIT's W^X memory pages conflict with the binary
# translator, causing prim_tty NIF and bootstrap beam to crash. Callers
# set DISABLE_JIT=true to work around this (see Dockerfile.desktop-build).
EXTRA_CONFIGURE=""
if [ "${DISABLE_JIT:-}" = "true" ]; then
    EXTRA_CONFIGURE="--disable-jit"
    log "JIT disabled (cross-platform or emulated build)"
fi

./configure \
    --prefix=/usr/local \
    --without-javac \
    --without-wx \
    --without-debugger \
    --without-observer \
    --without-et \
    --without-megaco \
    --disable-dynamic-ssl-lib \
    $EXTRA_CONFIGURE

make -j"$(nproc)"
make install

cd /
rm -rf /tmp/otp_src_* /tmp/otp_src_*.tar.gz

log "Erlang OTP ${OTP_VERSION} installed"

# ---------------------------------------------------------------------------
# Elixir
# ---------------------------------------------------------------------------
log "Compiling Elixir ${ELIXIR_VERSION}..."

cd /tmp
wget -q "https://github.com/elixir-lang/elixir/archive/refs/tags/v${ELIXIR_VERSION}.tar.gz"
tar xzf "v${ELIXIR_VERSION}.tar.gz"
cd "elixir-${ELIXIR_VERSION}"

make -j"$(nproc)"
make install PREFIX=/usr/local

cd /
rm -rf /tmp/elixir-* /tmp/v${ELIXIR_VERSION}.tar.gz

log "Elixir ${ELIXIR_VERSION} installed"

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
log "Verifying installation..."
erl -eval 'io:format("Erlang/OTP ~s~n", [erlang:system_info(otp_release)]), halt().' -noshell
elixir --version

log "Done!"
