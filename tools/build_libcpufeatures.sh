#!/bin/bash
# Copyright (c) 2026, cmachsocket contributors.
#
# Build a prebuilt libcpufeatures.so stub for ONE Android ABI, the way
# ncm_api_enhanced (and nodejs-mobile consumers in general) ship it.
#
# Background
# ----------
# libnode.so (nodejs-mobile / node-android) imports `android_getCpuFeatures`
# from NDK's libcpufeatures, but NDK only ships that as a static archive
# (`libcpufeatures.a`). No Android system .so exports the symbol, so
# `dlopen(libnode.so)` fails with:
#
#     cannot locate symbol "android_getCpuFeatures"
#
# unless the consumer provides its own `libcpufeatures.so`. This script
# builds a tiny stub .so (returning 0 from android_getCpuFeatures — V8 only
# reads the value to pick CPU-specialized code paths, 0 just means
# portable fallback) for ONE ABI at a time.
#
# Usage
# -----
#   ./tools/build_libcpufeatures.sh <NDK_PATH> <API_LEVEL> <ABI>
#
# Examples
# --------
#   ./tools/build_libcpufeatures.sh /opt/android-ndk 24 arm64-v8a
#   ./tools/build_libcpufeatures.sh /opt/android-ndk 24 armeabi-v7a
#   ./tools/build_libcpufeatures.sh /opt/android-ndk 24 x86_64
#
# Output
# ------
#   out/Release/libcpufeatures.so
#
# This single file IS the ABI the caller asked for; it MUST be uploaded
# to the cmachsocket/node release under the same tag as the matching
# libnode.so. (libnode.so and libcpufeatures.so are NOT ABI-interchangeable,
# so one ABI == one upload. Run the script once per ABI you ship, and
# upload the artifact BEFORE re-running with another ABI — each run
# overwrites the canonical path.)
#
# This script is intentionally self-contained: it does NOT depend on
# android_configure.py having been run first. It reuses the same NDK
# clang toolchain that android_configure.py uses (see
# `<NDK>/toolchains/llvm/prebuilt/<host>/bin/<triple>-clang`).

set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "Usage: $0 <ANDROID_NDK_PATH> <API_LEVEL> <ABI>" >&2
  echo "  ANDROID_NDK_PATH: path to your Android NDK (e.g. /opt/android-ndk)" >&2
  echo "  API_LEVEL:        minimum Android API level (e.g. 24)" >&2
  echo "  ABI:              arm64-v8a (default), armeabi-v7a, x86_64" >&2
  exit 1
fi

NDK_PATH="$1"
SDK_API="$2"
ABI="$3"

# ---------------------------------------------------------------------
# Toolchain discovery
# ---------------------------------------------------------------------

case "$(uname -s)" in
  Linux)  HOST_OS=linux ;;
  Darwin) HOST_OS=darwin ;;
  *)
    echo "Error: unsupported host OS: $(uname -s)" >&2
    exit 1
    ;;
esac

TOOLCHAIN_BIN="$NDK_PATH/toolchains/llvm/prebuilt/$HOST_OS-x86_64/bin"
SYSROOT="$NDK_PATH/toolchains/llvm/prebuilt/$HOST_OS-x86_64/sysroot"

if [ ! -d "$TOOLCHAIN_BIN" ]; then
  echo "Error: NDK toolchain not found at $TOOLCHAIN_BIN" >&2
  echo "       Set ANDROID_NDK_PATH to a valid NDK installation." >&2
  exit 1
fi

# ---------------------------------------------------------------------
# Output directory
# ---------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="$REPO_ROOT/out/Release"
mkdir -p "$OUT_DIR"

# ---------------------------------------------------------------------
# Stub source
# ---------------------------------------------------------------------
#
# We deliberately write this into a per-invocation temp directory rather
# than committing a .c file alongside the script. The stub is tiny (one
# function, two lines) so this keeps the diff minimal.
# ---------------------------------------------------------------------

STUB_SRC="$(mktemp -t cpufeatures_stub.XXXXXX.c)"
trap 'rm -f "$STUB_SRC"' EXIT

cat > "$STUB_SRC" <<'EOF'
/* Stub libcpufeatures for nodejs-mobile.
 *
 * Returns 0 (no optional CPU features advertised). nodejs-mobile only
 * consults this value to pick V8 code paths; a 0 return is safe and
 * triggers portable fallbacks on every ABI.
 *
 * This is NOT a complete libcpufeatures replacement — it only provides
 * the single symbol that nodejs-mobile's libnode.so actually imports.
 * Do not link other libraries against this stub without adding their
 * required symbols too.
 */
#include <stdint.h>

uint64_t android_getCpuFeatures(void) {
    return 0;
}
EOF

# ---------------------------------------------------------------------
# Build for the requested ABI
# ---------------------------------------------------------------------

case "$ABI" in
  arm64-v8a)     TRIPLE="aarch64-linux-android${SDK_API}" ;;
  armeabi-v7a)   TRIPLE="armv7a-linux-androideabi${SDK_API}" ;;
  x86_64)        TRIPLE="x86_64-linux-android${SDK_API}" ;;
  *)
    echo "Error: unsupported ABI '$ABI'" >&2
    echo "       supported: arm64-v8a, armeabi-v7a, x86_64" >&2
    exit 1
    ;;
esac

CLANG="$TOOLCHAIN_BIN/${TRIPLE}-clang"
if [ ! -x "$CLANG" ]; then
  echo "Error: clang not found or not executable: $CLANG" >&2
  exit 1
fi

OUT="$OUT_DIR/libcpufeatures.so"

echo "Building libcpufeatures.so:"
echo "  NDK       = $NDK_PATH"
echo "  API level = $SDK_API"
echo "  ABI       = $ABI"
echo "  Triple    = $TRIPLE"
echo "  Output    = $OUT"
echo

"$CLANG" \
    --target="$TRIPLE" \
    --sysroot="$SYSROOT" \
    -shared \
    -fPIC \
    -O2 \
    -fvisibility=default \
    -Wl,-soname,libcpufeatures.so \
    -o "$OUT" \
    "$STUB_SRC"

# Sanity-check the output. Use NDK's llvm-readobj so we don't depend
# on the host's readelf (which on some distros localizes its output —
# e.g. Chinese on zh_CN.UTF-8 systems — and would then not match our
# regex).
READOBJ="$TOOLCHAIN_BIN/llvm-readobj"
if [ -x "$READOBJ" ] \
     && "$READOBJ" --dyn-symbols "$OUT" 2>/dev/null \
        | grep -q 'android_getCpuFeatures'; then
  VERIFIED=ndk-readobj
elif command -v readelf >/dev/null 2>&1 \
     && readelf --dyn-syms "$OUT" 2>/dev/null \
        | grep -q 'android_getCpuFeatures'; then
  VERIFIED=host-readelf
else
  echo "Error: built $OUT but it does not export android_getCpuFeatures" >&2
  exit 1
fi

echo "Done (verified with $VERIFIED)."
echo "  $OUT"
echo
echo "Upload this file as libcpufeatures.so alongside the matching"
echo "libnode.so for $ABI on the cmachsocket/node release."
echo "IMPORTANT: re-running this script with a different ABI will"
echo "overwrite this file. Upload before re-running."