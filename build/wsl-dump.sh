#!/usr/bin/env bash
CFG=~/r-on-ohos/build/out/src/R-4.5.1-host/configure
n=$(grep -n 'double complex BLAS can be used' "$CFG" | head -1 | cut -d: -f1)
sed -n "$((n+10)),$((n+110))p" "$CFG" | grep -vE '^\s*$'
