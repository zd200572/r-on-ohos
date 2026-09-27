#!/usr/bin/env bash
# 一键全量构建（在 WSL Ubuntu 中运行）
set -euo pipefail
cd "$(dirname "$0")"

./05-get-ohos-sdk.sh
./00-host-r.sh
./10-deps.sh
./20-f2c.sh
./30-build-r.sh
./40-pack.sh

echo
echo "=============================================================="
echo " 全部完成。产物:"
echo "   $R_TARBALL（若已 source env.sh）或 build/out/rhome-*.tar"
echo " 下一步:"
echo "   真机直跑:  ./50-install-device.sh"
echo "   HAP 应用:  DevEco Studio 打开 ../hap/ 并 Run（docs/04）"
echo "=============================================================="
