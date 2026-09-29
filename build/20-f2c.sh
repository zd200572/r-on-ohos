#!/usr/bin/env bash
# f2c 工具链（无需 sudo）：
#   1) host f2c 转换器 —— 复用 00-host-r.sh 自建的 $OUT_DIR/host-tools/bin/f2c
#   2) 目标架构 libf2c.a（f2c 生成 C 代码所需的运行库，纯 C，用 OHOS clang 交叉编译）
set -euo pipefail
cd "$(dirname "$0")" && source ./env.sh

F2C="$OUT_DIR/host-tools/bin/f2c"
[ -x "$F2C" ] || { echo "缺 host f2c，先跑 00-host-r.sh"; exit 1; }
export F2C_BIN="$F2C"

# ---- 目标架构 libf2c.a（交叉：makefile.u 正规构建，arith.h 由 host 预生成）----
# aarch64/x86_64 同为 IEEE 小端，host 跑 arithchk 的结果与目标一致，make 因 arith.h
# 较新而跳过目标机执行；f2c.h 的 ftnlen 改为 long（8 字节 = size_t，与 R 探测到的
# 隐藏字符长度一致），integer 保持 4 字节与 R 的 C 调用约定一致。
[ -f "$DEPS_PREFIX/lib/libf2cblas.a" ] && { echo "libf2c 已存在"; exit 0; }
Z="$DOWNLOAD_DIR/libf2c.zip"
[ -f "$Z" ] || curl -fL --retry 3 -o "$Z" "https://www.netlib.org/f2c/libf2c.zip"
LIBF2C="$OUT_DIR/src/libf2c-target"
rm -rf "$LIBF2C"; mkdir -p "$LIBF2C"; cd "$LIBF2C"
if command -v unzip >/dev/null 2>&1; then unzip -oq "$Z"
else python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$Z" .; fi
cp sysdep1.h0 sysdep1.h
cp signal1.h0 signal1.h
# 使用仓库内验证过的 f2c.h：integer=4字节（int）、ftnlen=8字节（long/size_t，与 R 探测一致）
cp "$BUILD_DIR/f2c.h" f2c.h
grep -q '^typedef int integer;' f2c.h || { echo "f2c.h 异常: integer 非 4 字节"; exit 1; }
# uninit.c 依赖 glibc 的 fpu_control.h（musl 无），从默认对象列表摘除
sed -i 's/ uninit\.o//' makefile.u
gcc -O2 -o arithchk-host arithchk.c && ./arithchk-host > arith.h
# arith.h 必须严格新于 arithchk.c（unzip 恢复的 mtime 同秒会导致 make 重跑目标机编译）
touch -d '2000-01-01' arithchk.c sysdep1.h signal1.h f2c.h && touch arith.h
# Use OHOS SDK ld.lld for cross-compile (host ld can't handle aarch64 objects)
mkdir -p /tmp/ohos-ld-wrap && ln -sf "$OHOS_NDK/native/llvm/bin/ld.lld" /tmp/ohos-ld-wrap/ld
PATH="/tmp/ohos-ld-wrap:$PATH" make -f makefile.u CC="$CC" CFLAGS="$CFLAGS" AR="$AR" RANLIB="$RANLIB" libf2c.a
install -m644 f2c.h    "$DEPS_PREFIX/include/f2c.h"
install -m644 libf2c.a "$DEPS_PREFIX/lib/libf2c.a"
# 复数点积的 f2c 约定兼容层（遮蔽 OpenBLAS 的寄存器返回版本），链接顺序须在 -lopenblas 前
$CC $CFLAGS -I"$DEPS_PREFIX/include" -c "$BUILD_DIR/zdot_compat.c" -o zdot_compat.o
$AR cr "$DEPS_PREFIX/lib/libf2cblas.a" zdot_compat.o
$RANLIB "$DEPS_PREFIX/lib/libf2cblas.a"
grep -n "typedef.*ftnlen" "$DEPS_PREFIX/include/f2c.h"
echo "OK: $DEPS_PREFIX/lib/libf2c.a + libf2cblas.a"
