#!/usr/bin/env bash
# 测试 dpstrf_ 链接
set -e
cat > /tmp/test_dpstrf.c << 'CEOF'
char dpstrf_();
int main() { dpstrf_(); return 0; }
CEOF
gcc -o /tmp/test_dpstrf /tmp/test_dpstrf.c \
  -L/home/zd200572/r-on-ohos/build/out/host-deps/lib \
  -lclapack -lf2cblasbridge -lopenblas -lf2c -lm 2>&1
echo "LINK OK"