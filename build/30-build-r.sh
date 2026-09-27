#!/usr/bin/env bash
# 交叉编译目标架构（aarch64-ohos）的 R 本体。
# 前置: 00-host-r.sh / 10-deps.sh / 20-f2c.sh 均已完成。
set -euo pipefail
cd "$(dirname "$0")" && source ./env.sh

[ -x "$HOST_R_HOME/bin/R" ]   || { echo "缺 host R，先跑 00-host-r.sh"; exit 1; }
[ -f "$DEPS_PREFIX/lib/libf2c.a" ] || { echo "缺 libf2c，先跑 20-f2c.sh"; exit 1; }

SRC="$OUT_DIR/src/R-$R_VERSION-ohos"
TARBALL="$DOWNLOAD_DIR/R-$R_VERSION.tar.gz"
if [ ! -f "$TARBALL" ]; then
  for base in "https://mirrors.tuna.tsinghua.edu.cn/CRAN" "https://cran.r-project.org"; do
    curl -fL --retry 3 --progress-bar -o "$TARBALL" \
      "$base/src/base/R-${R_VERSION%%.*}/R-$R_VERSION.tar.gz" && break
  done
fi
[ -f "$TARBALL" ] || { echo "缺 $TARBALL，请手动下载"; exit 1; }

BUILD_NET="${BUILD_NET:-1}"
# 依依赖库实际产物决定开关（10-deps.sh 可能按条件跳过 jpeg/curl）
IMG_FLAGS="--without-libpng --without-jpeglib"
[ -f "$DEPS_PREFIX/include/png.h" ]     && IMG_FLAGS="--with-libpng --without-jpeglib"
[ -f "$DEPS_PREFIX/include/jpeglib.h" ] && IMG_FLAGS="--with-libpng --with-jpeglib"
# libcurl 由 configure 自动探测（无 --with-libcurl 选项），curl 头文件在则启用

rm -rf "$SRC"; mkdir -p "$OUT_DIR/src"
tar xf "$TARBALL" -C "$OUT_DIR/src"; mv "$OUT_DIR/src/R-$R_VERSION" "$SRC"
cd "$SRC"
# f2c 兼容性补丁（src/appl/dqrdc2.f 等），详见 build/f90fix.py
python3 "$BUILD_DIR/f90fix.py" "$SRC"

# 修补 makebasedb.R：交叉编译时 .Library 指向 host R，host R 的 base/R/base 是
# 小文件（lazy-load loader），触发 "may already be using lazy loading on base" 检查。
# 跳过此检查——我们用 host R 的 baseenv() 生成 base.rdb，版本相同所以安全。
python3 "$BUILD_DIR/patch-makebasedb.py" "$SRC/src/library/base/makebasedb.R"

# ---- 1) configure ----
# 注意: --host 用 musl 三元组（GNU config.sub 不识别 ohos，见 env.sh 说明），
#       实际目标由 CC 的 --target=$OHOS_TRIPLE 决定。
CONFIG_SITE="$BUILD_DIR/config.site.ohos" ./configure \
  --build=x86_64-pc-linux-gnu \
  --host="$OHOS_HOSTTRIPLE" \
  --prefix="$R_PREFIX" \
  --enable-R-shlib \
  --without-x --without-tcltk --without-libtiff \
  --with-recommended-packages=no \
  --with-readline \
  --with-blas="-lf2cblas -lopenblas" \
  --with-lapack="-lclapack -lopenblas -lf2c" \
  $IMG_FLAGS \
  --with-internal-tzcode \
  --disable-nls \
  CC="$CC" CXX="$CXX" CFLAGS="$CFLAGS" CXXFLAGS="$CXXFLAGS" \
  CPPFLAGS="-I$DEPS_PREFIX/include" \
  LDFLAGS="$LDFLAGS" \
  F77="$BUILD_DIR/f77" FC="$BUILD_DIR/f77" FFLAGS="-O2" FPICFLAGS="-fPIC"

# ---- 3) 构建期脚本用 host R：替换 bin/R / bin/Rscript ----
# bin/R 在 configure 后不存在，先创建目录和占位脚本，make 过程中会用它
mkdir -p bin
cat > bin/R <<EOF
#!/bin/sh
# 交叉编译期占位：把 R 脚本调用转发给 host R（见 docs/03）
export R_HOME="$HOST_R_HOME/lib/R"
exec "$HOST_R_HOME/lib/R/bin/exec/R" "\$@"
EOF
chmod +x bin/R
cat > bin/Rscript <<EOF
#!/bin/sh
export R_HOME="$HOST_R_HOME/lib/R"
exec "$HOST_R_HOME/bin/Rscript" "\$@"
EOF
chmod +x bin/Rscript

# 禁用 docs 目标（交叉编译时 help2man 无法运行目标 Rscript）
python3 "$BUILD_DIR/patch-makefile.py" .

# ---- 4) make / install ----
# make 会在构建过程中重新生成 bin/R（覆盖上面的占位脚本），导致 sysdata 等步骤
# 尝试运行目标架构 R 而失败。策略：先 make 到失败，重新替换 bin/R 为 host R 转发，
# touch src/scripts/R 阻止 make 再次重生成 bin/R，再继续 make。
make -j"$(nproc)" || true

# 重新替换 bin/R / bin/Rscript 为 host R 转发（make 已覆盖它们为目标架构脚本）
cat > bin/R <<EOF
#!/bin/sh
export R_HOME="$HOST_R_HOME/lib/R"
exec "$HOST_R_HOME/lib/R/bin/exec/R" "\$@"
EOF
chmod +x bin/R
cat > bin/Rscript <<EOF
#!/bin/sh
export R_HOME="$HOST_R_HOME/lib/R"
exec "$HOST_R_HOME/bin/Rscript" "\$@"
EOF
chmod +x bin/Rscript
# 阻止 src/scripts/Makefile 的 R 目标再次覆盖 bin/R
touch src/scripts/R

# 清理第一次 make 残留的 base 包 lazy-loading 产物（否则字节编译报 "already using lazy loading"）
rm -rf library/base/R library/base/libs
# 构建目标 R（docs 已在 configure 后禁用）
make -j"$(nproc)"
make install

# ---- 5) 精简安装树 ----
find "$R_PREFIX" -name "*.so" -o -type f -path "*bin/exec/R" | while read -r f; do
  $STRIP "$f" 2>/dev/null || true
done
rm -rf "$R_PREFIX/lib/R/doc" "$R_PREFIX/lib/R/tests" "$R_PREFIX/lib/R/demo" \
       "$R_PREFIX/lib/R/share/locale" "$R_PREFIX"/lib/R/library/*/po \
       "$R_PREFIX/lib/R/modules"/*.html "$R_PREFIX"/share/man

# ---- 6) 设备端默认配置 ----
cat > "$R_PREFIX/lib/R/etc/Rprofile.site" <<'EOF'
local({
  options(repos = c(CRAN = "https://mirrors.tuna.tsinghua.edu.cn/CRAN"),
          pager = "cat", editor = "", stringsAsFactors = FALSE)
})
EOF
cat > "$R_PREFIX/lib/R/etc/Renviron.site" <<EOF
R_LIBS_USER=\${R_USER}/rlibs
EOF

echo "== 完成: $R_PREFIX/lib/R =="
"$R_PREFIX/lib/R/bin/exec/R" --version 2>/dev/null || echo "（目标 R 无法在 host 运行，属正常；交给真机验证）"
