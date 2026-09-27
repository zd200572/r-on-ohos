#!/usr/bin/env bash
# 诊断：链 B 的 R configure 是否卡在 f77 探测；若有挂起进程则现场解剖
echo "=== configure 进程 ==="
pgrep -af 'configure --prefix' | head -3 || echo "无"
echo "=== f77/f2c/gcc 进程 ==="
pgrep -a -f 'build/f77' | head -3 || echo "无 f77"
pgrep -a f2c | head -3 || echo "无 f2c"
pgrep -x gcc | head -3 || echo "无 gcc"
pgrep -a make | head -2 || echo "无 make"

for p in $(pgrep -f 'build/f77' | head -3); do
  echo "--- pid $p ---"
  tr '\0' ' ' < "/proc/$p/cmdline"; echo
  grep -E 'State|PPid' "/proc/$p/status"
  echo "wchan: $(cat /proc/$p/wchan 2>/dev/null)"
  ls -l "/proc/$p/fd" 2>/dev/null | tail -5
done

echo "=== config.log 尾部 ==="
tail -4 ~/r-on-ohos/build/out/src/R-4.5.1-host/config.log 2>/dev/null
