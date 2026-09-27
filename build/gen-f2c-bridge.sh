#!/usr/bin/env bash
# 生成 f2c BLAS 桥接库
set -e
NM_FILE="${1:-/tmp/clapack_nm.txt}"
OUT_DIR="${2:-/home/zd200572/r-on-ohos/build/out/host-deps}"

ASM_FILE="/tmp/f2c_blas_aliases.s"
OBJ_FILE="/tmp/f2c_blas_bridge.o"

# 从 nm 输出中提取 f2c_ 前缀符号名
grep ' U f2c_' "$NM_FILE" | sed 's/.*U f2c_//' | sort -u > /tmp/f2c_names.txt
COUNT=$(wc -l < /tmp/f2c_names.txt)
echo "需要桥接的 BLAS 函数数量: $COUNT"

# 生成汇编跳转桩文件
{
  echo ".text"
  while IFS= read -r name; do
    echo ".globl f2c_${name}"
    echo ".type f2c_${name}, @function"
    echo "f2c_${name}:"
    echo "    jmp ${name}_"
  done < /tmp/f2c_names.txt
} > "$ASM_FILE"

echo "汇编文件已生成: $ASM_FILE"

# 编译为静态库
gcc -c "$ASM_FILE" -o "$OBJ_FILE"
ar cr "$OUT_DIR/lib/libf2cblasbridge.a" "$OBJ_FILE"
ranlib "$OUT_DIR/lib/libf2cblasbridge.a"

echo "桥接库已创建: $OUT_DIR/lib/libf2cblasbridge.a"

# 验证
nm "$OUT_DIR/lib/libf2cblasbridge.a" | grep ' T f2c_' | wc -l | xargs echo "已定义别名数量:"
