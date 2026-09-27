#!/usr/bin/env bash
# hdc 推送 R 到鸿蒙 PC / 设备并验证运行（形态 A，开发期直跑）。
# 设备需开启开发者模式；hdc 可执行文件来自 DevEco toolchains。
set -euo pipefail
cd "$(dirname "$0")" && source ./env.sh

HDC="${HDC:-$(ls "/d/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/toolchains/hdc.exe" 2>/dev/null || command -v hdc)}"
[ -n "$HDC" ] || { echo "找不到 hdc，设置 HDC 环境变量"; exit 1; }
[ -f "$R_TARBALL" ] || { echo "缺 $R_TARBALL，先跑 40-pack.sh"; exit 1; }

"$HDC" list targets
echo ">> file send ..."
"$HDC" shell "mkdir -p /data/local/tmp"
"$HDC" file send "$R_TARBALL" /data/local/tmp/rhome.tar
"$HDC" shell "cd /data/local/tmp && rm -rf R && tar xf rhome.tar && echo 解包完成"

echo ">> 版本验证"
"$HDC" shell "R_HOME=/data/local/tmp/R LD_LIBRARY_PATH=/data/local/tmp/R/lib \
  R_LIBS_USER=/data/local/tmp/rlibs HOME=/data/local/tmp \
  /data/local/tmp/R/bin/exec/R --version"

cat <<'TIP'
验证 REPL（退出 Ctrl-D）:
  hdc shell
  R_HOME=/data/local/tmp/R LD_LIBRARY_PATH=/data/local/tmp/R/lib /data/local/tmp/R/bin/exec/R

若报 Permission denied（沙箱/分区禁执行），改走形态 B（HAP + nativeLibraryDir），见 docs/05。
TIP
