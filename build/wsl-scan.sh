#!/usr/bin/env bash
# 全量 f2c 试转换 src/appl 所有 .f，确认没有残留不兼容构造
set -e
cd ~/r-on-ohos/build/out/src/R-4.5.1-host/src/appl
F2C=$HOME/r-on-ohos/build/out/host-tools/bin/f2c
FAIL=0
for f in *.f; do
  rm -f "${f%.f}.c"
  if ! $F2C -a -R -w -w66 "$f" >/dev/null 2>/tmp/f2cerr; then
    echo "== $f 有错误 =="; grep Error /tmp/f2cerr | head -4; FAIL=1
  fi
done
[ $FAIL = 0 ] && echo "src/appl 全部 .f 文件 f2c 转换通过 ✓"
