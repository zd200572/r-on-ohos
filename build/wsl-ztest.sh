#!/usr/bin/env bash
# 复现 R 的 "double complex BLAS" 测试，定位 OpenBLAS(f2c约定) 的真实失败原因
set -e
export F2C_BIN=$HOME/r-on-ohos/build/out/host-tools/bin/f2c
export DEPS_PREFIX=$HOME/r-on-ohos/build/out/host-deps
export F77_CC=gcc
W=/tmp/ztest; rm -rf $W; mkdir -p $W; cd $W

cat > conftestf.f <<'EOF'
      subroutine xerbla(srname, info)
      character*6 srname
      integer info
      end
      subroutine test1(iflag)
      double complex zx(2), ztemp, zres, zdotu
      integer iflag
      zx(1) = (3.1d0,1.7d0)
      zx(2) = (1.6d0,-0.6d0)
      zres = zdotu(2, zx, 1, zx, 1)
      ztemp = (0.0d0,0.0d0)
      do 10 i = 1,2
         ztemp = ztemp + zx(i)*zx(i)
 10      continue
      if(abs(zres - ztemp) > 1.0d-10) then
        iflag = 1
      else
        iflag = 0
      endif
      end
EOF

echo "== f77 包装器编译 conftestf.f =="
~/r-on-ohos/build/f77 -c -O2 conftestf.f && echo FC_OK

cat > conftest.c <<'EOF'
#include <stdlib.h>
extern void test1_(int *iflag);
int main (void) {
  int iflag;
  test1_(&iflag);
  exit(iflag);
}
EOF
gcc -O2 -c conftest.c -o conftest.o
echo "== 链接（带 f2c 兼容层）=="
gcc -o conftest conftest.o conftestf.o -L"$DEPS_PREFIX/lib" -lf2cblas -lopenblas -lf2c -lm && echo LINK_OK
echo "== 运行（exit 0=通过）=="
./conftest; echo "EXIT=$?"
echo "== OpenBLAS 里 zdotu 的符号形式 =="
nm --defined-only "$DEPS_PREFIX/lib/libopenblas.a" 2>/dev/null | grep -E 'T zdotu_' | head -3
