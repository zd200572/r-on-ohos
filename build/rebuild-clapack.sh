#!/usr/bin/env bash
set -e
export OHOS_ARCH=x86_64
export OHOS_NDK=~/ohos-sdk
cd ~/r-on-ohos/build && source ./env.sh

nm "$DEPS_PREFIX/lib/libclapack.a" 2>/dev/null | grep ' U f2c_' | sed 's/.*U f2c_//' | sort -u > /tmp/f2c_names.txt
echo "f2c_ 符号数: $(wc -l < /tmp/f2c_names.txt)"

REDEFS=""
while IFS= read -r name; do
  REDEFS="$REDEFS --redefine-sym f2c_${name}=${name}_"
done < /tmp/f2c_names.txt

echo "开始重命名..."
cp "$DEPS_PREFIX/lib/libclapack.a" "$DEPS_PREFIX/lib/libclapack.a.bak"
$OBJCOPY $REDEFS "$DEPS_PREFIX/lib/libclapack.a"

echo "=== 重命名后剩余的 f2c_ 符号 ==="
nm "$DEPS_PREFIX/lib/libclapack.a" 2>/dev/null | grep " U f2c_" | head -5
echo "=== (应该为空) ==="

rm -f "$DEPS_PREFIX/lib/libf2cblasbridge.a"
echo "=== 完成 ==="
