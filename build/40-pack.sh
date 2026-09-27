#!/usr/bin/env bash
# 打包 R 安装树：
#   out/rhome-<arch>.tar                    —— ustar 包（hdc 直跑 + HAP rawfile 共用）
#   hap/entry/src/main/resources/rawfile/rhome.tar
#   hap/entry/libs/arm64-v8a/{librbin.so,libR.so}   —— 沙箱禁执行时的备用执行体
set -euo pipefail
cd "$(dirname "$0")" && source ./env.sh

R_HOME_TREE="$R_PREFIX/lib/R"
[ -d "$R_HOME_TREE" ] || { echo "缺 $R_HOME_TREE，先跑 30-build-r.sh"; exit 1; }

echo ">> 打 ustar 包"
tar --format=ustar --sort=name --owner=0 --group=0 --numeric-owner \
    -cf "$R_TARBALL" -C "$R_PREFIX/lib" R

echo ">> 拷贝进 HAP 工程（ABI=$OHOS_ABI；模拟器用 OHOS_ARCH=x86_64 重新构建本包）"
HAP_LIBS="$ROOT_DIR/hap/entry/libs/$OHOS_ABI"; mkdir -p "$HAP_LIBS"
cp -f "$R_HOME_TREE/bin/exec/R"    "$HAP_LIBS/librbin.so"
cp -f "$R_HOME_TREE/lib/libR.so"   "$HAP_LIBS/libR.so"
mkdir -p "$ROOT_DIR/hap/entry/src/main/resources/rawfile"
cp -f "$R_TARBALL" "$ROOT_DIR/hap/entry/src/main/resources/rawfile/rhome.tar"

du -h "$R_TARBALL" "$HAP_LIBS/librbin.so" "$HAP_LIBS/libR.so"
echo "完成。下一步: DevEco 打开 hap/ 运行，或 ./50-install-device.sh 真机直跑"
