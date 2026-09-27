#!/usr/bin/env bash
# 生成 f2c BLAS 桥接库：用 GNU as 的 .globl + .set 创建别名符号
# f2c_X → X_（OpenBLAS 提供的标准 BLAS 名）
set -e
export OHOS_ARCH=x86_64
export OHOS_NDK=~/ohos-sdk
cd ~/r-on-ohos/build && source ./env.sh

nm "$DEPS_PREFIX/lib/libclapack.a" 2>/dev/null | grep ' U f2c_' | sed 's/.*U f2c_//' | sort -u > /tmp/f2c_names.txt

cat > /tmp/f2c_bridge.s <<'ASMEOF'
.text
ASMEOF

while IFS= read -r name; do
  echo ".globl f2c_${name}" >> /tmp/f2c_bridge.s
  echo ".set f2c_${name}, ${name}_" >> /tmp/f2c_bridge.s
done < /tmp/f2c_names.txt

echo "=== 汇编文件前10行 ==="
head -10 /tmp/f2c_bridge.s
echo "=== 总行数 ==="
wc -l /tmp/f2c_bridge.s

# 用系统 as 汇编（x86_64 和 host 同架构，系统 as 可用）
as --64 -o /tmp/f2c_bridge.o /tmp/f2c_bridge.s
echo "=== as 成功 ==="

# 用 OHOS SDK 的 ar 打包（保持目标格式一致）
$AR cr "$DEPS_PREFIX/lib/libf2cblasbridge.a" /tmp/f2c_bridge.o
$RANLIB "$DEPS_PREFIX/lib/libf2cblasbridge.a"
echo "=== 桥接库创建成功 ==="
ls -la "$DEPS_PREFIX/lib/libf2cblasbridge.a"

# 验证符号
nm "$DEPS_PREFIX/lib/libf2cblasbridge.a" | head -20
echo "=== 验证完毕 ==="