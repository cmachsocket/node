/*
 * Stub implementation of android_getCpuFeatures() for Android builds.
 *
 * zlib's cpu_features.c calls android_getCpuFeatures() when ARMV8_OS_ANDROID
 * is defined (see deps/zlib/zlib.gyp) in order to decide whether it may use
 * the ARMv8 CRC32 and PMULL instructions. That symbol lives in the NDK's
 * libcpufeatures, which recent NDKs no longer ship as a prebuilt archive, so
 * it has to be provided by whoever links zlib.
 *
 * Returning 0 is safe: zlib just falls back to its portable CRC32 code. It
 * only disables the ARMv8 hardware acceleration for zlib compression and
 * decompression, it does not change correctness.
 */

#include <stdint.h>

uint64_t android_getCpuFeatures(void) {
  return 0;
}
