#!/usr/bin/env bash
# WSL 链 B：host R（不依赖 OHOS SDK，可与链 A 并行）
set -euo pipefail
export OHOS_ARCH="${OHOS_ARCH:-x86_64}"
cd "$(dirname "$0")"
./00-host-r.sh
echo "CHAIN_B_DONE"
