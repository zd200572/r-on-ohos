#!/usr/bin/env bash
# 交叉编译 R 的依赖库到 $DEPS_PREFIX（静态库，随 R 一起链接）。
# sysroot 自带 zlib/iconv；pcre2/bzip2/xz/ncurses/readline/libpng 必编；
# openssl+curl 默认编（BUILD_NET=0 跳过）；libjpeg-turbo 需 cmake，缺则跳过。
# 下载层：多镜像回退 + 完整性校验（github 直连不稳，优先 deb.debian.org/gnu/官方站）。
set -euo pipefail
cd "$(dirname "$0")" && source ./env.sh

SRC="$OUT_DIR/src"; mkdir -p "$SRC"
BUILD_NET="${BUILD_NET:-1}"
DEB=https://mirrors.tuna.tsinghua.edu.cn/debian/pool/main
DEB2=https://deb.debian.org/debian/pool/main

validate_tar() {
  case "$1" in
    *.tar.gz|*.tgz) tar tzf "$1" >/dev/null 2>&1 ;;
    *.tar.xz)       tar -I /usr/bin/xz -tf "$1" >/dev/null 2>&1 ;;
    *.zip)          unzip -tqq "$1" >/dev/null 2>&1 ;;
    *)              true ;;
  esac
}
fetch_multi() { # fetch_multi <文件名> <url...>
  local f="$DOWNLOAD_DIR/$1"; shift
  if [ -f "$f" ]; then validate_tar "$f" && { echo "$f"; return 0; } ; rm -f "$f"; fi
  local u
  for u in "$@"; do
    echo ">> 下载 $u" >&2
    if curl -fL --retry 2 --connect-timeout 10 --speed-limit 1024 --speed-time 30 -o "$f" "$u" >&2 && validate_tar "$f"; then
      echo "$f"; return 0
    fi
    rm -f "$f"
  done
  echo "所有镜像均失败: $1" >&2; return 1
}
untar() { # untar <文件名> [缓存名] -> echo 源目录（顶层目录名自动探测）
  local f="$DOWNLOAD_DIR/$1"
  local d="$SRC/oh-${2:-$(basename "$1" | sed 's/\.tar\.[a-z]*$//')}"
  [ -d "$d" ] && { echo "$d"; return 0; }
  rm -rf "$d"
  local before after top
  before=$(ls "$SRC" | sort)
  case "$f" in *.tar.xz) tar -I /usr/bin/xz -xf "$f" -C "$SRC" ;; *) tar xf "$f" -C "$SRC" ;; esac
  after=$(ls "$SRC" | sort)
  top=$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | head -1)
  [ -n "$top" ] && [ -d "$SRC/$top" ] || { echo "解包异常: $1" >&2; return 1; }
  mv "$SRC/$top" "$d"
  echo "$d"
}
auto_dep() { # auto_dep <文件名> <解压目录名> <url...> -- <额外configure参数...>
  local fn="$1" dn="$2"; shift 2
  local urls=() extra=()
  while [ $# -gt 0 ]; do [ "$1" = "--" ] && shift && break; urls+=("$1"); shift; done
  extra=("$@")
  if [ -f "$DEPS_PREFIX/lib/.done-$fn" ]; then echo "ok(缓存): $fn"; return 0; fi
  fetch_multi "$fn" "${urls[@]}" >/dev/null || return 1
  local d; d=$(untar "$fn" "$dn")
  ( cd "$d" && ./configure --host="$OHOS_HOSTTRIPLE" --prefix="$DEPS_PREFIX" \
      --disable-shared --enable-static "${extra[@]}" >/dev/null \
    && { make -j"$(nproc)" -k || true; make install -k || true; } >/dev/null 2>&1 )
  touch "$DEPS_PREFIX/lib/.done-$fn"
  echo "ok: $fn"
}

# ---- pcre2（R 必需）----
auto_dep pcre2-10.48.tar.gz pcre2-10.48 \
  "$DEB/p/pcre2/pcre2_10.48.orig.tar.gz" \
  "$DEB2/p/pcre2/pcre2_10.48.orig.tar.gz" \
  --
# ---- bzip2（无 configure，直接 make 静态库）----
if [ ! -f "$DEPS_PREFIX/lib/libbz2.a" ]; then
  f=$(fetch_multi bzip2-1.0.8.tar.gz https://sourceware.org/pub/bzip2/bzip2-1.0.8.tar.gz)
  d=$(untar bzip2-1.0.8.tar.gz bzip2-1.0.8)
  ( cd "$d" && make CC="$CC" AR="$AR" RANLIB="$RANLIB" libbz2.a >/dev/null
    install -m644 libbz2.a "$DEPS_PREFIX/lib/"; install -m644 bzlib.h "$DEPS_PREFIX/include/" )
  echo "ok: bzip2"
fi
# ---- xz / lzma ----
auto_dep xz-5.8.4.tar.xz xz-5.8.4 \
  "$DEB/x/xz-utils/xz-utils_5.8.4.orig.tar.xz" \
  "$DEB2/x/xz-utils/xz-utils_5.8.4.orig.tar.xz" \
  -- --disable-scripts --disable-nls
# ---- ncurses（交叉编译需 host gcc 构建生成工具）----
if [ ! -f "$DEPS_PREFIX/lib/libncursesw.a" ]; then
  f=$(fetch_multi ncurses-6.5.tar.gz https://ftp.gnu.org/pub/gnu/ncurses/ncurses-6.5.tar.gz)
  d=$(untar ncurses-6.5.tar.gz ncurses-6.5)
  ( cd "$d" && ./configure --host="$OHOS_HOSTTRIPLE" --prefix="$DEPS_PREFIX" \
      --without-cxx --without-cxx-binding --without-ada --without-tests --without-manpages \
      --with-build-cc=gcc --enable-widec --disable-shared --enable-static >/dev/null \
    && { make -j"$(nproc)" >/dev/null || true; make install >/dev/null || true; } )
  for l in ncurses tinfo; do
    [ -f "$DEPS_PREFIX/lib/lib$l.a" ] || cp "$DEPS_PREFIX/lib/libncursesw.a" "$DEPS_PREFIX/lib/lib$l.a"
  done
  echo "ok: ncurses"
fi
# ---- readline ----
auto_dep readline-8.2.tar.gz readline-8.2 \
  https://mirrors.tuna.tsinghua.edu.cn/gnu/readline/readline-8.2.tar.gz \
  https://ftp.gnu.org/pub/gnu/readline/readline-8.2.tar.gz \
  -- bash_cv_func_sigsetjmp=yes
# ---- libpng ----
auto_dep libpng-1.6.58.tar.gz libpng-1.6.58 \
  "$DEB/libp/libpng1.6/libpng1.6_1.6.58.orig.tar.gz" \
  "$DEB2/libp/libpng1.6/libpng1.6_1.6.58.orig.tar.gz" \
  --

# ---- openssl + curl（https 下载能力；体积大，可 BUILD_NET=0 跳过）----
if [ "$BUILD_NET" = 1 ]; then
  if [ ! -f "$DEPS_PREFIX/lib/libssl.a" ]; then
    f=$(fetch_multi openssl-3.6.4.tar.gz "$DEB/o/openssl/openssl_3.6.4.orig.tar.gz" "$DEB2/o/openssl/openssl_3.6.4.orig.tar.gz")
    d=$(untar openssl-3.6.4.tar.gz openssl-3.6.4)
    ( cd "$d" && ./Configure "linux-$OHOS_ARCH" no-asm no-shared no-tests \
        --prefix="$DEPS_PREFIX" --libdir=lib --cross-compile-prefix="" \
        CC="$CC" CFLAGS="$CFLAGS" AR="$AR" RANLIB="$RANLIB" >/dev/null \
      && { make -j"$(nproc)" >/dev/null || true; make install_sw >/dev/null || true; } )
    echo "ok: openssl"
  fi
  auto_dep curl-8.10.1.tar.gz curl-8.10.1 \
    https://curl.se/download/curl-8.10.1.tar.gz \
    -- --with-openssl="$DEPS_PREFIX" --without-libpsl --without-libidn2 --without-brotli \
       --without-zstd --without-nghttp2 --without-librtmp --disable-manual --disable-verbose
fi

# ---- OpenBLAS（外部 BLAS：纯 C/GENERIC，NOFORTRAN=1 绕开 R 自带 f90 BLAS；内部 LAPACK 仍为 f77 走 f2c）----
if [ ! -f "$DEPS_PREFIX/lib/libopenblas.a" ]; then
  f=$(fetch_multi openblas-0.3.29.tar.xz \
      "$DEB/o/openblas/openblas_0.3.29+ds.orig.tar.xz" \
      "$DEB2/o/openblas/openblas_0.3.29+ds.orig.tar.xz")
  d=$(untar openblas-0.3.29.tar.xz OpenBLAS)
  ( cd "$d" && make -j"$(nproc)" libs NOFORTRAN=1 NO_SHARED=1 USE_THREAD=0 USE_OPENMP=0 \
      TARGET=GENERIC BINARY=64 CC="$CC" AR="$AR" RANLIB="$RANLIB" HOSTCC=gcc >/dev/null \
    && install -m644 libopenblas.a "$DEPS_PREFIX/lib/" )
  echo "ok: openblas"
fi

# ---- CLAPACK（netlib 官方 f2c 转版 LAPACK，纯 C）----
# R 4.5 自带的 LAPACK 源码用了 CYCLE/EXIT 等 f2c 不支持的构造，改用外部 CLAPACK
# 后 src/modules/lapack 完全不编。用我们验证过的 f2c.h（integer=4B/ftnlen=8B）。
if [ ! -f "$DEPS_PREFIX/lib/libclapack.a" ]; then
  f=$(fetch_multi clapack-3.2.1.tar.gz https://www.netlib.org/clapack/clapack.tgz)
  d=$(untar clapack-3.2.1.tar.gz CLAPACK)
  ( cd "$d"
    cp "$DEPS_PREFIX/include/f2c.h" INCLUDE/f2c.h
    cp make.inc.example make.inc
    sed -i -e "s|^CC        = gcc|CC        = $CC|" \
           -e "s|^LOADER    = gcc|LOADER    = $CC|" \
           -e "s|^ARCH     = ar|ARCH     = $AR|" \
           -e "s|^RANLIB   = ranlib|RANLIB   = $RANLIB|" \
           -e "s|^CFLAGS    = |CFLAGS    = -fPIC |" make.inc
    make lapacklib -j"$(nproc)" > build.log 2>&1 || true
    # lapacklib 依赖 lapack_install（要跑原生自测程序），交叉场景直接进 SRC 编译
    ( cd SRC && make -j"$(nproc)" > ../build.log 2>&1 ) || { tail -30 build.log; exit 1; }
    install -m644 "$(find . -name 'lapack_LINUX.a' | head -1)" "$DEPS_PREFIX/lib/libclapack.a" )
  echo "ok: clapack"
fi

# ---- CLAPACK f2c_ 符号重命名：CLAPACK 引用 f2c_dswap 等，OpenBLAS 提供 dswap_ ----
# 用 llvm-objcopy --redefine-sym 直接在 libclapack.a 中把 f2c_X 重命名为 X_，
# 这样 CLAPACK 直接引用 OpenBLAS 的标准 BLAS 名，无需桥接库。
if $NM "$DEPS_PREFIX/lib/libclapack.a" 2>/dev/null | grep -q ' U f2c_'; then
  echo ">> CLAPACK f2c_ 符号重命名"
  $NM "$DEPS_PREFIX/lib/libclapack.a" 2>/dev/null | grep ' U f2c_' | sed 's/.*U f2c_//' | sort -u > /tmp/f2c_names_$$.txt
  REDEFS=""
  while IFS= read -r name; do
    REDEFS="$REDEFS --redefine-sym f2c_${name}=${name}_"
  done < /tmp/f2c_names_$$.txt
  $OBJCOPY $REDEFS "$DEPS_PREFIX/lib/libclapack.a"
  rm -f /tmp/f2c_names_$$.txt
  echo "ok: clapack f2c_ → X_ 重命名"
fi

echo "== 依赖完成: $DEPS_PREFIX =="
ls "$DEPS_PREFIX/lib"
