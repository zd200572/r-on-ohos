#!/usr/bin/env bash
# host (x86_64 Linux) 版 R：交叉构建目标 R 时 make 要跑 R 脚本，必须有一份能运行的 R。
# 完全不依赖 sudo：无 gfortran 就用 f2c 方案；缺 dev 头文件就从源码装到 $OUT_DIR/host-deps。
set -euo pipefail
cd "$(dirname "$0")"
source ./env.sh 2>/dev/null || true   # host 构建不需要 OHOS SDK，允许 env.sh 检查失败
unset F77 FC FFLAGS FCFLAGS 2>/dev/null || true   # host 依赖不需要 Fortran；env.sh 的目标包装器会污染 libtool 探测

SRC="$OUT_DIR/src"
TARBALL="$DOWNLOAD_DIR/R-$R_VERSION.tar.gz"
HOSTDEPS="$OUT_DIR/host-deps"
mkdir -p "$HOSTDEPS/include" "$HOSTDEPS/lib" "$OUT_DIR/host-tools/bin" "$SRC" "$DOWNLOAD_DIR"

# ---- 下载层：多镜像回退 + 完整性校验（防截断缓存）----
fetch_multi() { # fetch_multi <文件名> <url...>
  local f="$DOWNLOAD_DIR/$1"; shift
  if [ -f "$f" ]; then validate_tar "$f" && return 0; rm -f "$f"; fi
  local u
  for u in "$@"; do
    echo ">> 下载 $u" >&2
    if curl -fL --retry 2 --connect-timeout 10 --speed-limit 1024 --speed-time 30 -o "$f" "$u" >&2 && validate_tar "$f"; then
      return 0
    fi
    rm -f "$f"
  done
  echo "所有镜像均失败: $1" >&2
  return 1
}
validate_tar() { # 下载/缓存通用完整性校验
  case "$1" in
    *.tar.gz|*.tgz) tar tzf "$1" >/dev/null 2>&1 ;;
    *.tar.xz)       tar tJf "$1" >/dev/null 2>&1 ;;
    *.zip)          unzip -tqq "$1" >/dev/null 2>&1 ;;
    *)              true ;;
  esac
}
fetch() { fetch_multi "$2" "$1"; }   # 兼容旧调用: fetch <url> <文件名>
unzip_to() { local z="$1" d="$2"; rm -rf "$d"; mkdir -p "$d"
  if command -v unzip >/dev/null 2>&1; then unzip -oq "$z" -d "$d"
  else python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$z" "$d"; fi }

# ---- 1) host f2c 转换器 ----
F2C="$OUT_DIR/host-tools/bin/f2c"
if [ ! -x "$F2C" ]; then
  if command -v f2c >/dev/null 2>&1; then
    F2C="$(command -v f2c)"
  else
    echo ">> 获取 host f2c（apt-get download + dpkg -x，无需 sudo）"
    mkdir -p "$DOWNLOAD_DIR/f2cdeb"
    DEB=""
    for cand in /tmp/apttest/f2c_*.deb "$DOWNLOAD_DIR"/f2cdeb/f2c_*.deb; do
      [ -f "$cand" ] && DEB="$cand" && break
    done
    if [ -z "$DEB" ]; then
      ( cd "$DOWNLOAD_DIR/f2cdeb" && apt-get download f2c ) || true
      for cand in "$DOWNLOAD_DIR"/f2cdeb/f2c_*.deb; do [ -f "$cand" ] && DEB="$cand"; done
    fi
    [ -n "$DEB" ] || { echo "无法获取 f2c 的 deb 包"; exit 1; }
    echo "使用: $DEB"
    dpkg -x "$DEB" "$DOWNLOAD_DIR/f2cdeb/root"
    install -m755 "$DOWNLOAD_DIR/f2cdeb/root/usr/bin/f2c" "$F2C"
  fi
fi
export F2C_BIN="$F2C"
echo "f2c: $F2C"

# ---- 2) host libf2c.a + f2c.h（host R 的 F77=f77 包装需要）----
# libf2c 正规构建：铺生成头（sysdep1/signal1），makefile.u 会自行跑 arithchk 生成 arith.h。
# netlib 现行 f2c.h 已是 4 字节 integer（typedef int integer），与 R 的 C 调用约定一致。
if [ ! -f "$HOSTDEPS/lib/libf2c.a" ]; then
  echo ">> host libf2c.a"
  fetch https://www.netlib.org/f2c/libf2c.zip libf2c.zip
  unzip_to "$DOWNLOAD_DIR/libf2c.zip" "$SRC/libf2c-host2"
  ( cd "$SRC/libf2c-host2"
    cp sysdep1.h0 sysdep1.h
    cp signal1.h0 signal1.h
    # 使用仓库内验证过的 f2c.h：integer=4字节、ftnlen=8字节(size_t)
    cp "$BUILD_DIR/f2c.h" f2c.h
    grep -q '^typedef int integer;' f2c.h || { echo "f2c.h 异常: integer 非 4 字节"; exit 1; }
    make -f makefile.u CC=gcc CFLAGS="-O2 -fPIC" libf2c.a )
  cp "$SRC/libf2c-host2/libf2c.a" "$HOSTDEPS/lib/"
  cp "$SRC/libf2c-host2/f2c.h"    "$HOSTDEPS/include/"
  # 复数点积 f2c 约定兼容层（遮蔽 OpenBLAS），host 版
  gcc -O2 -I"$HOSTDEPS/include" -c "$BUILD_DIR/zdot_compat.c" -o "$SRC/zdot_compat.o"
  ar cr "$HOSTDEPS/lib/libf2cblas.a" "$SRC/zdot_compat.o" && ranlib "$HOSTDEPS/lib/libf2cblas.a"
fi

# ---- 3) host 基础库（zlib/pcre2/bzip2/xz，R configure 必需）----
hosttar() { # hosttar <tar文件名> <缓存名> <url...> -> 解包并 echo 目录（顶层目录自动探测）
  local t="$1" dn="$2"; shift 2
  fetch_multi "$t" "$@" || return 1
  local d="$SRC/host-$dn"; rm -rf "$d"
  local before after top
  before=$(ls "$SRC" | sort)
  tar xf "$DOWNLOAD_DIR/$t" -C "$SRC"
  after=$(ls "$SRC" | sort)
  top=$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | head -1)
  [ -n "$top" ] && [ -d "$SRC/$top" ] || { echo "解包异常: $t" >&2; return 1; }
  mv "$SRC/$top" "$d"
  echo "$d"
}
if [ ! -f "$HOSTDEPS/lib/libz.a" ]; then
  echo ">> host zlib"; d=$(hosttar zlib-1.3.1.tar.gz zlib-1.3.1 https://zlib.net/fossils/zlib-1.3.1.tar.gz)
  ( cd "$d" && CFLAGS="-O2 -fPIC" ./configure --prefix="$HOSTDEPS" --static >/dev/null && make -j"$(nproc)" >/dev/null && make install >/dev/null )
fi
if [ ! -f "$HOSTDEPS/lib/libpcre2-8.a" ]; then
  echo ">> host pcre2"; d=$(hosttar pcre2-10.48.tar.gz pcre2-10.48 https://deb.debian.org/debian/pool/main/p/pcre2/pcre2_10.48.orig.tar.gz)
  ( cd "$d" && ./configure --prefix="$HOSTDEPS" --disable-shared --enable-static >/dev/null && make -j"$(nproc)" >/dev/null && make install >/dev/null )
fi
if [ ! -f "$HOSTDEPS/lib/libbz2.a" ]; then
  echo ">> host bzip2"; d=$(hosttar bzip2-1.0.8.tar.gz bzip2-1.0.8 https://sourceware.org/pub/bzip2/bzip2-1.0.8.tar.gz)
  ( cd "$d" && make CC=gcc libbz2.a >/dev/null 2>&1
    install -m644 libbz2.a "$HOSTDEPS/lib/"; install -m644 bzlib.h "$HOSTDEPS/include/" )
fi
if [ ! -f "$HOSTDEPS/lib/liblzma.a" ]; then
  echo ">> host xz"; d=$(hosttar xz-5.8.4.tar.xz xz-5.8.4 https://deb.debian.org/debian/pool/main/x/xz-utils/xz-utils_5.8.4.orig.tar.xz)
  ( cd "$d" && ./configure --prefix="$HOSTDEPS" --disable-shared --enable-static --disable-scripts --disable-nls >/dev/null && make -j"$(nproc)" >/dev/null && make install >/dev/null )
fi
# R 4.5 硬性要求 libcurl(https)；host 机没有 dev 包，从源码编进 HOSTDEPS
if [ ! -f "$HOSTDEPS/lib/libssl.a" ]; then
  echo ">> host openssl"; d=$(hosttar openssl-3.6.4.tar.gz openssl-3.6.4 https://deb.debian.org/debian/pool/main/o/openssl/openssl_3.6.4.orig.tar.gz)
  ( cd "$d" && ./Configure linux-x86_64 no-asm no-shared no-tests \
      --prefix="$HOSTDEPS" --libdir=lib >/dev/null && make -j"$(nproc)" >/dev/null && make install_sw >/dev/null )
fi
if [ ! -f "$HOSTDEPS/lib/libcurl.a" ]; then
  echo ">> host curl"; d=$(hosttar curl-8.10.1.tar.gz curl-8.10.1 https://curl.se/download/curl-8.10.1.tar.gz)
  ( cd "$d" && PKG_CONFIG_PATH="$HOSTDEPS/lib/pkgconfig" ./configure --prefix="$HOSTDEPS" \
      --with-openssl="$HOSTDEPS" --disable-shared --enable-static --without-libpsl --without-libidn2 \
      --without-brotli --without-zstd --without-nghttp2 --without-librtmp --disable-manual --disable-verbose >/dev/null \
    && make -j"$(nproc)" >/dev/null && make install >/dev/null )
  # R 要求 https 支持，构建后必须验证 SSL 已启用（版本串含 OpenSSL 后端）
  "$HOSTDEPS/bin/curl" --version 2>/dev/null | grep -qi openssl || { echo "host curl 未启用 SSL"; exit 1; }
fi
# host OpenBLAS（外部 BLAS，绕开 R 自带 f90 BLAS——本机没有 gfortran）
if [ ! -f "$HOSTDEPS/lib/libopenblas.a" ]; then
  echo ">> host openblas"
  d=$(hosttar openblas-0.3.29.tar.xz OpenBLAS https://mirrors.tuna.tsinghua.edu.cn/debian/pool/main/o/openblas/openblas_0.3.29+ds.orig.tar.xz)
  ( cd "$d" && make -j"$(nproc)" libs NOFORTRAN=1 NO_SHARED=1 USE_THREAD=0 USE_OPENMP=0 \
      TARGET=GENERIC BINARY=64 CC=gcc HOSTCC=gcc >/dev/null \
    && install -m644 libopenblas.a "$HOSTDEPS/lib/" )
fi
# host CLAPACK（外部 LAPACK，同 10-deps.sh 的理由：绕开 R 自带 f90 LAPACK）
if [ ! -f "$HOSTDEPS/lib/libclapack.a" ]; then
  echo ">> host clapack"
  d=$(hosttar clapack-3.2.1.tar.gz CLAPACK https://www.netlib.org/clapack/clapack.tgz)
  ( cd "$d"
    cp "$HOSTDEPS/include/f2c.h" INCLUDE/f2c.h
    cp make.inc.example make.inc
    sed -i -e "s|^CC        = gcc|CC        = gcc|" \
           -e "s|^LOADER    = gcc|LOADER    = gcc|" \
           -e "s|^CFLAGS    = |CFLAGS    = -fPIC |" make.inc
    make lapacklib -j"$(nproc)" > build.log 2>&1 || true
    # lapacklib 依赖 lapack_install（要跑原生自测程序），交叉/无依赖场景直接进 SRC 编译
    ( cd SRC && make -j"$(nproc)" > ../build.log 2>&1 ) || { tail -30 build.log; exit 1; }
    install -m644 "$(find . -name 'lapack_LINUX.a' | head -1)" "$HOSTDEPS/lib/libclapack.a" )
fi
# f2c BLAS 桥接库：CLAPACK 引用 f2c_dswap 等名称，OpenBLAS 提供 dswap_，需要别名桥接
if [ ! -f "$HOSTDEPS/lib/libf2cblasbridge.a" ]; then#  echo ">> f2c BLAS bridge"
  nm "$HOSTDEPS/lib/libclapack.a" > /tmp/clapack_nm_$$.txt 2>/dev/null
  grep ' U f2c_' /tmp/clapack_nm_$$.txt | sed 's/.*U f2c_//' | sort -u > /tmp/f2c_names_$$.txt
  DEFSYMS=""
  while IFS= read -r name; do
    DEFSYMS="$DEFSYMS --defsym f2c_${name}=${name}_"
  done < /tmp/f2c_names_$$.txt
  echo "" | gcc -x c -c - -o /tmp/f2c_empty_$$.o
  ld -r $DEFSYMS /tmp/f2c_empty_$$.o -o /tmp/f2c_blas_bridge_$$.o
  ar cr "$HOSTDEPS/lib/libf2cblasbridge.a" /tmp/f2c_blas_bridge_$$.o
  ranlib "$HOSTDEPS/lib/libf2cblasbridge.a"
  rm -f /tmp/clapack_nm_$$.txt /tmp/f2c_names_$$.txt /tmp/f2c_empty_$$.o /tmp/f2c_blas_bridge_$$.o
fi
export PATH="$HOSTDEPS/bin:$PATH"   # 让 R 的 configure 找到 host curl-config

# ---- 4) host R 本体 ----
[ -x "$HOST_R_HOME/bin/R" ] && { echo "host R 已存在: $HOST_R_HOME"; exit 0; }
fetch "https://mirrors.tuna.tsinghua.edu.cn/CRAN/src/base/R-${R_VERSION%%.*}/R-$R_VERSION.tar.gz" "R-$R_VERSION.tar.gz" \
  || fetch "https://cran.r-project.org/src/base/R-${R_VERSION%%.*}/R-$R_VERSION.tar.gz" "R-$R_VERSION.tar.gz"
rm -rf "$SRC/R-$R_VERSION-host"; tar xf "$TARBALL" -C "$SRC"
mv "$SRC/R-$R_VERSION" "$SRC/R-$R_VERSION-host"
cd "$SRC/R-$R_VERSION-host"
# f2c 兼容性补丁：dqrdc2.f 等文件里的 f90 构造（裸 DO/EXIT/CYCLE）→ f77（f2c 不支持）
python3 "$BUILD_DIR/f90fix.py" "$SRC/R-$R_VERSION-host"

export CC=gcc CXX=g++
export CFLAGS="-O2" CXXFLAGS="-O2"
export CPPFLAGS="-I$HOSTDEPS/include"          # host-deps 头文件（zlib/pcre2/bzlib/lzma）
export LDFLAGS="-L$HOSTDEPS/lib"
export DEPS_PREFIX="$HOSTDEPS"     # build/f77 用它找 f2c.h / libf2c.a
export F77_CC="gcc"                # f77 包装器的真实 C 编译器（勿用 CC，防 libtool 递归）
./configure --prefix="$HOST_R_HOME" \
  --without-x --without-tcltk --without-libtiff \
  --with-recommended-packages=no --disable-nls \
  --without-readline \
  --with-blas="-lf2cblas -lopenblas" \
  --with-lapack="-lclapack -lf2cblasbridge -lopenblas -lf2c" \
  CC="$CC" CXX="$CXX" CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" \
  F77="$BUILD_DIR/f77" FC="$BUILD_DIR/f77" FFLAGS="-O2" FPICFLAGS="-fPIC"
make -j"$(nproc)"
make install
"$HOST_R_HOME/bin/R" --version | head -2
