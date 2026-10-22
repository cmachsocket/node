import platform
import sys
import os

# TODO: In next version, it will be a JSON file listing all the patches, and then it will iterate through to apply them.
def patch_android():
    print("- Patches List -")
    print("[1] [deps/v8/src/trap-handler/trap-handler.h] related to https://github.com/nodejs/node/issues/36287")
    target = './deps/v8/src/trap-handler/trap-handler.h'
    marker = '#define V8_TRAP_HANDLER_SUPPORTED false'
    if os.path.exists(target):
        with open(target) as f:
            if marker in f.read():
                print("\033[92mInfo: \033[0mAlready applied, skipping.")
                return
    if platform.system() == "Linux":
        ret = os.system('patch -f -N ' + target + ' < ./android-patches/trap-handler.h.patch')
        if ret != 0:
            print("\033[91mError: \033[0mFailed to apply android-patches/trap-handler.h.patch")
            sys.exit(1)
    print("\033[92mInfo: \033[0m" + "Tried to patch.")

if platform.system() != "Linux" and platform.system() != "Darwin":
    print("android-configure is currently only supported on Linux and Darwin.")
    sys.exit(1)

if len(sys.argv) == 2 and sys.argv[1] == "patch":
    patch_android()
    sys.exit(0)

if len(sys.argv) < 4:
    print("Usage: ./android-configure [patch] <path to the Android NDK> <Android SDK version> <target architecture> [configure options]")
    sys.exit(1)

if not os.path.exists(sys.argv[1]) or not os.listdir(sys.argv[1]):
    print("\033[91mError: \033[0m" + "Invalid path to the Android NDK")
    sys.exit(1)

if int(sys.argv[2]) < 24:
    print("\033[91mError: \033[0m" + "Android SDK version must be at least 24 (Android 7.0)")
    sys.exit(1)

android_ndk_path = sys.argv[1]
android_sdk_version = sys.argv[2]
arch = sys.argv[3]

if arch == "arm":
    DEST_CPU = "arm"
    TOOLCHAIN_PREFIX = "armv7a-linux-androideabi"
elif arch in ("aarch64", "arm64"):
    DEST_CPU = "arm64"
    TOOLCHAIN_PREFIX = "aarch64-linux-android"
    arch = "arm64"
elif arch == "x86":
    DEST_CPU = "ia32"
    TOOLCHAIN_PREFIX = "i686-linux-android"
elif arch == "x86_64":
    DEST_CPU = "x64"
    TOOLCHAIN_PREFIX = "x86_64-linux-android"
    arch = "x64"
else:
    print("\033[91mError: \033[0m" + "Invalid target architecture, must be one of: arm, arm64, aarch64, x86, x86_64")
    sys.exit(1)

print("\033[92mInfo: \033[0m" + "Configuring for " + DEST_CPU + "...")

if platform.system() == "Darwin":
    host_os = "darwin"
    toolchain_path = android_ndk_path + "/toolchains/llvm/prebuilt/darwin-x86_64"

elif platform.system() == "Linux":
    host_os = "linux"
    toolchain_path = android_ndk_path + "/toolchains/llvm/prebuilt/linux-x86_64"

os.environ['PATH'] += os.pathsep + toolchain_path + "/bin"
os.environ['CC'] = toolchain_path + "/bin/" + TOOLCHAIN_PREFIX + android_sdk_version + "-" +  "clang"
os.environ['CXX'] = toolchain_path + "/bin/" + TOOLCHAIN_PREFIX + android_sdk_version + "-" + "clang++"

# nodejs-mobile patch: add host CC and CXX.
#
# When cross-compiling, node/gyp builds a separate "host" toolset (the tools
# that have to run on the build machine). If CC/CXX are left pointing at the
# NDK cross compiler, gyp uses those for the host toolset as well, and the
# host objects end up being Android binaries. That breaks in two ways:
#
#   1. configure.py derives host_arch from CC_host, so it would wrongly report
#      "arm64" instead of the build machine's architecture.
#   2. V8's host build compiles src/base/debug/stack_trace_posix.cc, which
#      includes <execinfo.h>. Bionic only declares backtrace()/backtrace_symbols()
#      when __ANDROID_MIN_SDK_VERSION__ >= 33, so the host build fails to
#      compile unless the SDK level is bumped to 33+ (which would then require
#      every consumer device to run Android 13+).
#
# Pointing the host toolset at the native compiler avoids both problems: the
# host tools are built for the build machine with glibc's execinfo.h, while the
# target toolset uses V8's stack_trace_android.cc, which does not need
# execinfo.h at all.
def find_host_compiler(candidates):
    for candidate in candidates:
        path = os.popen('command -v ' + candidate).read().strip()
        if path:
            return path
    return None

if 'CC_host' not in os.environ:
    host_cc = find_host_compiler(['cc', 'gcc', 'clang'])
    if host_cc:
        os.environ['CC_host'] = host_cc
if 'CXX_host' not in os.environ:
    host_cxx = find_host_compiler(['c++', 'g++', 'clang++'])
    if host_cxx:
        os.environ['CXX_host'] = host_cxx

GYP_DEFINES = "target_arch=" + arch
GYP_DEFINES += " v8_target_arch=" + arch
GYP_DEFINES += " android_target_arch=" + arch
GYP_DEFINES += " host_os=" + host_os + " OS=android"
GYP_DEFINES += " android_ndk_path=" + android_ndk_path
os.environ['GYP_DEFINES'] = GYP_DEFINES

# The Android build needs the trap handler disabled in V8; without this the
# host toolset ends up with a V8_TRAP_HANDLER_SUPPORTED mismatch and linking
# mksnapshot fails with undefined trap_handler symbols.
patch_android()

if os.path.exists("./configure"):
    configure_cmd = ("./configure --dest-cpu=" + DEST_CPU +
                     " --dest-os=android --openssl-no-asm --cross-compiling --shared")
    # Forward any extra arguments to configure, e.g.
    # ./android-configure <ndk> 24 arm64 --v8-disable-temporal-support
    for extra in sys.argv[4:]:
        configure_cmd += " " + extra
    print("\033[92mInfo: \033[0mRunning: " + configure_cmd)
    ret = os.system(configure_cmd)
    if ret != 0:
        print("\033[91mError: \033[0mconfigure failed with exit code " + str(ret))
        sys.exit(1)
