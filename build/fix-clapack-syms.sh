#!/usr/bin/env bash
set -e
export OHOS_ARCH=x86_64
export OHOS_NDK=~/ohos-sdk
cd ~/r-on-ohos/build && source ./env.sh

DEPS_PREFIX="$OUT_DIR/deps-x86_64"
echo "DEPS_PREFIX=$DEPS_PREFIX"
echo "NM=$NM"
echo "OBJCOPY=$OBJCOPY"

$NM "$DEPS_PREFIX/lib/libclapack.a" 2>/dev/null | grep ' U f2c_' | sed 's/.*U f2c_//' | sort -u > /tmp/f2c_names.txt
echo "f2c_ 符号数: $(wc -l < /tmp/f2c_names.txt)"

REDEFS=""
while IFS= read -r name; do
  REDEFS="$REDEFS --redefine-sym f2c_${name}=${name}_"
done < /tmp/f2c_names.txt

echo "开始重命名..."
$OBJCOPY $REDEFS "$DEPS_PREFIX/lib/libclapack.a"

echo "=== 重命名后剩余的 f2c_ 符号 ==="
$NM "$DEPS_PREFIX/lib/libclapack.a" 2>/dev/null | grep ' U f2c_' | head -5
echo "=== (应该为空) ==="
echo "=== 完成 ==="