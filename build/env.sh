#!/usr/bin/env bash
# ============ R on OpenHarmony 交叉编译环境（被所有脚本 source）============
# 用法: 在 WSL Ubuntu 中:  export OHOS_NDK=/opt/ohos-sdk && source ./env.sh

# ---- 版本 ----
export R_VERSION="${R_VERSION:-4.5.1}"

# ---- OHOS SDK（Linux 版，含 native/llvm 与 sysroot）----
export OHOS_NDK="${OHOS_NDK:-/opt/ohos-sdk}"

# ---- 目标架构：aarch64（鸿蒙 PC / 手机）| x86_64（开源鸿蒙 PC / 模拟器）----
export OHOS_ARCH="${OHOS_ARCH:-aarch64}"
case "$OHOS_ARCH" in
  aarch64) export OHOS_TRIPLE=aarch64-unknown-linux-ohos; export OHOS_LIBDIR=aarch64-linux-ohos; export OHOS_ABI=arm64-v8a ;;
  x86_64)  export OHOS_TRIPLE=x86_64-unknown-linux-ohos;  export OHOS_LIBDIR=x86_64-linux-ohos;  export OHOS_ABI=x86_64 ;;
  *) echo "env.sh: 未知 OHOS_ARCH=$OHOS_ARCH" >&2; return 1 ;;
esac
# autotools 的 --host 用 musl 三元组（GNU config.sub 不识别 ohos；musl 与 ohos libc 同源，
# 平台假设一致）；实际目标由 clang --target=$OHOS_TRIPLE 决定，两者不冲突。
export OHOS_HOSTTRIPLE="${OHOS_TRIPLE/-ohos/-musl}"

# ---- 路径 ----
export ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export BUILD_DIR="$ROOT_DIR/build"
export OUT_DIR="$BUILD_DIR/out"
export DOWNLOAD_DIR="$BUILD_DIR/downloads"
export DEPS_PREFIX="$OUT_DIR/deps-$OHOS_ARCH"
export HOST_R_HOME="$OUT_DIR/host-r"
export R_PREFIX="$OUT_DIR/r-ohos-$OHOS_ARCH"        # 目标 R 安装树（prefix）
export R_TARBALL="$OUT_DIR/rhome-$OHOS_ARCH.tar"
export F2C_BIN="${F2C_BIN:-$OUT_DIR/host-tools/bin/f2c}"   # host f2c 由 00-host-r.sh 自建

# ---- 工具链 ----
export SYSROOT="$OHOS_NDK/native/sysroot"
export TOOLCHAIN_BIN="$OHOS_NDK/native/llvm/bin"
[ -x "$TOOLCHAIN_BIN/clang" ] || [ -x "$TOOLCHAIN_BIN/clang.exe" ] || {
  echo "env.sh: 找不到 $TOOLCHAIN_BIN/clang —— 请先安装 Linux 版 OHOS SDK（docs/02）" >&2; return 1; }

export CC="$TOOLCHAIN_BIN/clang --target=$OHOS_TRIPLE --sysroot=$SYSROOT -D__MUSL__"
export CXX="$TOOLCHAIN_BIN/clang++ --target=$OHOS_TRIPLE --sysroot=$SYSROOT -D__MUSL__"
export AR="$TOOLCHAIN_BIN/llvm-ar"
export RANLIB="$TOOLCHAIN_BIN/llvm-ranlib"
export STRIP="$TOOLCHAIN_BIN/llvm-strip"
export LD="$TOOLCHAIN_BIN/ld.lld"
export NM="$TOOLCHAIN_BIN/llvm-nm"
export OBJCOPY="$TOOLCHAIN_BIN/llvm-objcopy"

# Fortran：由 build/f77（f2c 包装）伪装，需先跑 00-host-r.sh / 20-f2c.sh。
# F77_CC 是包装器内部真正调用的 C 编译器（host 构建=gcc；目标构建=ohos clang）。
export F77="$BUILD_DIR/f77"
export FC="$BUILD_DIR/f77"
export F77_CC="$CC"

export CFLAGS="-O2 -fPIC -I$DEPS_PREFIX/include"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-L$DEPS_PREFIX/lib"
export PKG_CONFIG_PATH="$DEPS_PREFIX/lib/pkgconfig"
export PATH="$DEPS_PREFIX/bin:$PATH"

mkdir -p "$OUT_DIR" "$DOWNLOAD_DIR"
export LC_ALL=C.UTF-8
echo "env.sh: target=$OHOS_TRIPLE  sdk=$OHOS_NDK  R=$R_VERSION"
