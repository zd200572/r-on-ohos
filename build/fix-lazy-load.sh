#!/bin/bash
H=/home/zd200572/r-on-ohos/build/out/host-r/lib/R
C=/home/zd200572/r-on-ohos/build/out/r-ohos-x86_64/lib/R

echo "=== 检查并补全所有包的 lazy-load 数据库 ==="
for pkg in $(ls "$H/library/"); do
    HR="$H/library/$pkg/R"
    CR="$C/library/$pkg/R"
    if [ -d "$HR" ]; then
        for f in $(cd "$HR" && find . -name "*.rd?" -type f 2>/dev/null); do
            if [ ! -f "$CR/$f" ]; then
                echo "缺失: library/$pkg/R/$f"
                cp "$HR/$f" "$CR/$f" && echo "  已补全"
            fi
        done
    fi
done

echo "=== 检查 Meta 和 help 目录 ==="
for pkg in $(ls "$H/library/"); do
    HM="$H/library/$pkg/Meta"
    CM="$C/library/$pkg/Meta"
    if [ -d "$HM" ]; then
        for f in $(cd "$HM" && find . -type f 2>/dev/null); do
            if [ ! -f "$CM/$f" ]; then
                echo "缺失: library/$pkg/Meta/$f"
                cp "$HM/$f" "$CM/$f" && echo "  已补全"
            fi
        done
    fi
    HH="$H/library/$pkg/help"
    CH="$C/library/$pkg/help"
    if [ -d "$HH" ]; then
        for f in $(cd "$HH" && find . -type f 2>/dev/null); do
            if [ ! -f "$CH/$f" ]; then
                echo "缺失: library/$pkg/help/$f"
                cp "$HH/$f" "$CH/$f" && echo "  已补全"
            fi
        done
    fi
done

echo "=== 完成 ==="