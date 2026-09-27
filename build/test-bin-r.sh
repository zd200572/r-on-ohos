#!/usr/bin/env bash
set -e
export OHOS_ARCH=x86_64
export OHOS_NDK=~/ohos-sdk
cd ~/r-on-ohos/build && source ./env.sh

SRC="$OUT_DIR/src/R-4.5.1-ohos"
cd "$SRC"

echo "=== 替换前 bin/R 行数 ==="
wc -l bin/R

# 替换 bin/R
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

echo "=== 替换后 bin/R 行数 ==="
wc -l bin/R
head -3 bin/R

echo "=== 运行 make (只做 library/tools 的 sysdata 目标) ==="
make -j$(nproc) 2>&1 | tail -30

echo "=== make 后 bin/R 行数 ==="
wc -l bin/R
head -3 bin/R