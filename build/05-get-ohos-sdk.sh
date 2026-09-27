#!/usr/bin/env bash
# 下载 Linux 版 OpenHarmony SDK（开源版，免登录），解出 native 到 $OHOS_NDK。
# 若你已有 SDK 或走官网下载，跳过本脚本。
set -euo pipefail
cd "$(dirname "$0")"
source ./env.sh 2>/dev/null || true   # 首次运行时 SDK 尚不存在，env.sh 允许失败
export OHOS_NDK="${OHOS_NDK:-$HOME/ohos-sdk}"

[ -x "$OHOS_NDK/native/llvm/bin/clang" ] && { echo "SDK 已就绪: $OHOS_NDK"; exit 0; }

VER="${OHOS_SDK_VER:-5.0.3-Release}"
URL="https://repo.huaweicloud.com/openharmony/os/$VER/ohos-sdk-windows_linux-public.tar.gz"
TGZ="$DOWNLOAD_DIR/ohos-sdk-$VER.tar.gz"
mkdir -p "$DOWNLOAD_DIR"

echo "下载 $URL （约 2-3 GB，版本不存在则去 https://repo.huaweicloud.com/openharmony/os/ 挑目录名）"
curl -fL --retry 3 --progress-bar -o "$TGZ" "$URL" || {
  echo "下载失败。手动方案: 1) 浏览器打开 https://repo.huaweicloud.com/openharmony/os/" ; \
  echo "2) 选版本下 ohos-sdk-windows_linux-public.tar.gz；3) tar xf 后取 linux/native* 解到 $OHOS_NDK/native"; exit 1; }

TMP="$OUT_DIR/sdk-extract"; rm -rf "$TMP"; mkdir -p "$TMP" "$OHOS_NDK"
tar xf "$TGZ" -C "$TMP"
# 发布包结构: ohos-sdk/linux/native-linux-x64-<ver>.zip（组件为 zip）
NATIVE_ZIP=$(find "$TMP" -path "*linux*" -name "native-linux-x64-*.zip" | head -1)
[ -n "$NATIVE_ZIP" ] || { echo "找不到 native-linux-x64-*.zip，实际结构:"; find "$TMP" -maxdepth 3 | head -20; exit 1; }
unzip -oq "$NATIVE_ZIP" -d "$TMP/native-extract"
NATDIR=$(find "$TMP/native-extract" -maxdepth 2 -type d -name native | head -1)
[ -n "$NATDIR" ] || { echo "zip 内找不到 native 目录"; find "$TMP/native-extract" -maxdepth 2 | head; exit 1; }
mv "$NATDIR" "$OHOS_NDK/native"
echo "OK: $OHOS_NDK/native"
