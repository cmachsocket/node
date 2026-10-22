# 为 Android 构建 libnode.so

本文档说明如何在本仓库（`cmachsocket/node` 的 fork）里把 Node.js 交叉编译成
Android 用的 `libnode.so`，以及构建过程中对上游做的本地改动、已知限制和排错方式。

> 这是 fork 私有的构建说明，不是提交给 nodejs/node 上游的文档。Android 在上游属于
> "self-serve / unsupported" 平台，这些改动不会也无需合回上游。

---

## 1. 产物

| 文件 | 说明 |
| --- | --- |
| `out/Release/libnode.so` | 主要产物，AArch64 ELF 共享库，SONAME `libnode.so`，约 150 MB |
| `out/Release/node` | 几 KB 的可执行文件，用于在设备 shell 里跑 `node` 调试（可选） |

`libnode.so` 的 DT_NEEDED：

```
libm.so  libdl.so  liblog.so  libc++_shared.so  libc.so
```

`libc++_shared.so` **必须由 App 一起打包**（从 NDK 的
`toolchains/llvm/prebuilt/<host>/sysroot/usr/lib/<triple>/libc++_shared.so` 取），
否则加载时会报找不到 C++ 运行时。

`android_getCpuFeatures()` 已经静态编进 `libnode.so`，**不需要再单独打包
`libcpufeatures.so`**（这就是原来 `dlopen` 报
`cannot locate symbol "android_getCpuFeatures"` 的根因）。

---

## 2. 环境要求

| 项目 | 值（本机已验证） |
| --- | --- |
| Android NDK | r30 / `30.0.16248370`，路径 `/opt/android-ndk` |
| NDK clang | 21.0.0 |
| Android API level | `24`（`android_configure.py` 强制 >= 24），产物可跑在 Android 7.0+ |
| Python | 3.10 – 3.15（本机 3.14.8） |
| Rust | **不需要**（前提是加了 `--v8-disable-temporal-support`，见第 5 节） |
| 磁盘 | `out/` 约 1.6 GB，建议留 5 GB 以上 |
| 内存 | 24 核 / 11 GB 可用内存时用 `-j8` 曾出现编译进程被终止（疑似内存不足），建议 `-j6` |

NDK 路径可以通过环境变量确认：

```bash
echo "$ANDROID_NDK_ROOT"   # 例如 /opt/android-ndk
```

---

## 3. 构建

```bash
./android-configure /opt/android-ndk 24 arm64 --v8-disable-temporal-support
make -j6
```

- 第一个参数是 NDK 路径，第二个是 API level，第三个是目标架构
  （`arm` / `arm64` / `x86` / `x86_64`），之后的所有参数会原样透传给 `configure`。
- `android-configure` 会自动应用 `android-patches/` 下的补丁（幂等，重复执行会跳过），
  然后调用 `./configure --dest-cpu=... --dest-os=android --openssl-no-asm
  --cross-compiling --shared`。
- `configure` 失败会直接以非 0 退出，不会像以前那样被 `os.system` 吞掉。
- 从零开始大约 40–60 分钟（24 核，`-j6`）。

只构建 `libnode` 目标（增量构建，其依赖仍会被构建，包括 host 的 `mksnapshot`）：

```bash
make -C out -j6 BUILDTYPE=Release "$PWD/out/Release/libnode.so"
```

---

## 4. 校验产物

```bash
TOOL=$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin

$TOOL/llvm-readelf -h out/Release/libnode.so | grep -E "Class|Machine|Type"
#   Class:   ELF64
#   Type:    DYN (Shared object file)
#   Machine: AArch64

$TOOL/llvm-readelf -d out/Release/libnode.so | grep -E "SONAME|NEEDED"
#   SONAME: libnode.so

# android_getCpuFeatures 已被定义（不是 UND）
$TOOL/llvm-nm -D out/Release/libnode.so | grep android_getCpuFeatures

# 未定义符号应当只剩 bionic / libc++_shared 提供的
$TOOL/llvm-nm -D -u out/Release/libnode.so
```

发版前建议 strip（156 MB → 约 122 MB）：

```bash
$TOOL/llvm-strip out/Release/libnode.so
```

---

## 5. 已知限制

### Temporal 被关闭

当前构建带 `--v8-disable-temporal-support`，因此 JS 里**没有 `Temporal` 全局**。

原因：Temporal 由 Rust crates（`deps/crates`）实现。交叉编译时 host toolset
（x86_64，用来产 `mksnapshot`）和 target toolset（aarch64）各需要一份
`libnode_crates.a`，而 `cargo_rust_target` 是 gyp 的单一全局变量，两边的输出路径
和 `--target` 参数无法区分，于是 host `mksnapshot` 会去链接 aarch64 的 `.a`：

```
ld.lld: error: .../libnode_crates.a(...) is incompatible with aarch64linux
```

如果确实需要 Temporal，要把 `deps/crates/crates.gyp` 改成按 toolset 拆成两个
target（每个 target 自己的 `cargo_build_flags` / `node_crates_libpath`），或者想别的
办法给 host 单独出产物。注意 gyp 的 `target_conditions` 里**访问不到文件级变量**，
直接在里面写 `cargo_rust_target!=""` 会报 `name 'cargo_rust_target' is not defined`。

### zlib 的 ARMv8 加速被关掉

`deps/zlib/cpufeatures_stub.c` 里的 `android_getCpuFeatures()` 直接返回 0，
所以 zlib 不会启用 ARMv8 的 CRC32 / PMULL 指令，压缩解压走可移植实现。
只影响性能，不影响正确性，也不影响 V8（V8 不用这个符号）。

### 体积

默认是全量 ICU（`--with-intl` 未指定）。如果包体敏感，可以加
`--with-intl=small-icu`（保留 Intl API，仅英文数据）或 `--with-intl=none`
（nodejs-mobile 的选择），能显著减小 `libnode.so`。

---

## 6. 本地改动清单

相对上游 `nodejs/main`，为了让 Android 交叉编译跑通，做了以下改动。合并上游后
请检查这些点是否还在。

| 文件 | 改动 | 原因 |
| --- | --- | --- |
| `android_configure.py` | 设置 `CC_host` / `CXX_host` 为本机编译器 | **最关键**。不设的话 gyp 的 host toolset 也用 NDK 交叉编译器，`host_arch` 会被识别成 arm64，且 host 侧编译 `stack_trace_posix.cc` 时撞上 Bionic `execinfo.h` 的 `__ANDROID_MIN_SDK_VERSION__ >= 33` 门控，报 `use of undeclared identifier 'backtrace_symbols'` |
| `android_configure.py` | 自动调用 `patch_android()`、透传额外参数、检查 configure 退出码 | 少一步就编不过；失败要能立刻看到 |
| `android_configure.py` | configure 追加 `--shared` | 产出 `libnode.so` 而不是 `node` 可执行文件 |
| `android-patches/trap-handler.h.patch` | 按当前 V8 版本重做 | 原补丁 hunk 对不上；不应用会导致 host `mksnapshot` 链接报 `undefined reference to v8::internal::trap_handler::*` 和 `v8_internal_simulator_ProbeMemory` |
| `deps/v8/src/trap-handler/trap-handler.h` | 上一条补丁的应用结果（强制 `V8_TRAP_HANDLER_SUPPORTED false`） | Android 上 V8 trap handler 本来就不该启用 |
| `deps/zlib/cpufeatures_stub.c` | 新增：`android_getCpuFeatures()` 返回 0 | 新 NDK 不再提供预编译的 `libcpufeatures.a`，zlib 的 `cpu_features.c` 在 `ARMV8_OS_ANDROID` 下会引用该符号 |
| `deps/zlib/zlib.gyp` | Android 时把上面的 stub 编进 zlib | 让符号静态解析掉，避免再单独发 `libcpufeatures.so` |
| `configure.py` | `--dest-os=android` 时设置 `cargo_rust_target` | 否则 cargo 按本机架构编 Rust crates |
| `.github/workflows/build-android-libraries.yml` | 加 `--v8-disable-temporal-support`；去掉 `libcpufeatures.so` 相关步骤 | CI 与本地一致 |

`tools/build_libcpufeatures.sh` 是早期方案留下的脚本（单独产一个 stub
`libcpufeatures.so`），现在已经被 `deps/zlib/cpufeatures_stub.c` 取代，保留但不再使用。

### 上游同步后的注意事项

1. `deps/v8/src/trap-handler/trap-handler.h` 每次 `deps: update V8` 都会被整体替换，
   而 `android-patches/trap-handler.h.patch` 大概率对不上新版本 —— `android_configure.py`
   会以 `Failed to apply android-patches/trap-handler.h.patch` 明确报错。处理方式：
   重新生成该补丁（把 header 里那一整段 `#if/#elif/#else` 的探测替换成
   `#define V8_TRAP_HANDLER_SUPPORTED false`）。
2. `deps/zlib/zlib.gyp`（node 自己的 zlib 副本，不随 V8 更新）冲突风险较低，但
   upstream 改动该文件时可能冲突，保留 `cpufeatures_stub.c` 的 source 追加即可。
3. `configure.py` / `android_configure.py` 是上游文件，随时可能冲突。

---

## 7. 常见错误排查

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| `use of undeclared identifier 'backtrace_symbols'` | host toolset 用了 NDK 交叉编译器 | 确认 `android_configure.py` 里的 `CC_host`/`CXX_host` 逻辑还在；确认 `out/Makefile` 里 `CC.host` 指向 `/usr/bin/cc` 而不是 NDK clang |
| `undefined symbol: android_getCpuFeatures` | zlib 定义了 `ARMV8_OS_ANDROID` 但没有实现 | 确认 `deps/zlib/zlib.gyp` 在 Android 下加了 `cpufeatures_stub.c` |
| `undefined reference to v8::internal::trap_handler::*` / `v8_internal_simulator_ProbeMemory` | android trap-handler 补丁没应用或已过期 | 跑 `./android-configure patch` 看报错，必要时重新生成补丁 |
| `libnode_crates.a ... is incompatible with aarch64linux` | Temporal Rust crates 被编成 host 架构 | 加 `--v8-disable-temporal-support` |
| `gyp: name 'cargo_rust_target' is not defined` | 在 `target_conditions` 里引用了文件级变量 | 见第 5 节，需要改 `crates.gyp` 的结构 |
| `gyp: Undefined variable android_ndk_path` | 直接跑了 `./configure` 而没经过 `./android-configure` | 用 `./android-configure` |
| `no rule to make target .../obj.target/zlib//opt/android-ndk/...` | 在 gyp 的 `sources` 里写了仓库外的绝对路径 | gyp 只支持仓库内相对路径，把文件放进仓库 |
| `make: *** ... 已终止` / `Killed` | 并行度过高导致内存不足 | 降低 `-j`，例如 `make -j6` |
| `cannot locate symbol "..."`（运行时 dlopen） | 缺依赖库 | 检查是否需要一起打包 `libc++_shared.so` |

---

## 8. 在 Android App 里使用

```
app/libnode/bin/arm64-v8a/libnode.so
app/libnode/bin/arm64-v8a/libc++_shared.so
```

CMake 里：

```cmake
add_library(libnode SHARED IMPORTED)
set_target_properties(libnode PROPERTIES IMPORTED_LOCATION
  ${CMAKE_SOURCE_DIR}/libnode/bin/${ANDROID_ABI}/libnode.so)

target_link_libraries(native-lib libnode ${log-lib})
```

Java 侧加载顺序（先 C++ 运行时，再 node）：

```java
System.loadLibrary("c++_shared");
System.loadLibrary("node");
```

---

## 9. CI

`.github/workflows/build-android-libraries.yml` 在推送 tag 时触发，构建
`arm64-v8a` 并把 `out/Release/libnode.so` 作为 artifact 上传。

多 ABI 时把 `jobs.build` 改成 matrix 即可：

```yaml
strategy:
  matrix:
    include:
      - { arch: arm64, abi: arm64-v8a }
      - { arch: arm,   abi: armeabi-v7a }
      - { arch: x86_64, abi: x86_64 }
```

并把 `./android-configure ... "${{ matrix.arch }}"`、artifact 名和 `LLVM` 校验
里的架构一起参数化。目前只验证过 `arm64`。
