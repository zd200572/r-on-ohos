#!/usr/bin/env bash
# WSL 链 C：交叉编译 R 本体 → 打包（依赖链 A、B 完成）
set -euo pipefail
export OHOS_ARCH="${OHOS_ARCH:-x86_64}"
export OHOS_NDK="${OHOS_NDK:-$HOME/ohos-sdk}"
cd "$(dirname "$0")"
./30-build-r.sh
./40-pack.sh
echo "CHAIN_C_DONE"
