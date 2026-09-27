#!/usr/bin/env bash
# WSL 链 A：下载 SDK → 交叉编译依赖 → 目标 libf2c（默认面向模拟器 x86_64）
set -euo pipefail
export OHOS_ARCH="${OHOS_ARCH:-x86_64}"
export OHOS_NDK="${OHOS_NDK:-$HOME/ohos-sdk}"
cd "$(dirname "$0")"
./05-get-ohos-sdk.sh
./10-deps.sh
./20-f2c.sh
echo "CHAIN_A_DONE"
