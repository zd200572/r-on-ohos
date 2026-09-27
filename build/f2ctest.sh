#!/usr/bin/env bash
# f2c ABI 实测 v2：查看真实 typedef 形式 → 正确补丁 → 铺生成头 → C 调 Fortran 验证
set -e
F2C=~/r-on-ohos/build/out/host-tools/bin/f2c
W=$(mktemp -d); cd "$W"
echo "工作目录: $W"
curl -fsSL --retry 3 -o f2c.h https://www.netlib.org/f2c/f2c.h

echo "== f2c.h 实际 typedef =="
grep -n "typedef" f2c.h | head -12

echo "== 补丁 f2c.h（long→int，整数 4 字节）=="
sed -e 's/^typedef long integer;/typedef int integer;/' \
    -e 's/^typedef long ftnlen;/typedef int ftnlen;/' \
    -e 's/^typedef long logical;/typedef int logical;/' \
    -e 's/^typedef long ftnint;/typedef int ftnint;/' f2c.h > f2c_int.h
grep -n "typedef" f2c_int.h | head -8

echo "== host libf2c（makefile.u + 手工铺生成头 + 补丁 f2c.h）=="
mkdir -p lib && ( cd lib && unzip -oq ~/r-on-ohos/build/downloads/libf2c.zip
  cp sysdep1.h0 sysdep1.h
  cp signal1.h0 signal1.h
  cp ../f2c_int.h f2c.h
  make -f makefile.u CC=gcc CFLAGS="-O2" libf2c.a >/dev/null 2>&1 ) && echo LIBF2C_OK || { echo LIBF2C_FAIL; ( cd lib && make -f makefile.u CC=gcc CFLAGS="-O2" libf2c.a 2>&1 | tail -5 ); exit 1; }

echo "== C 调 Fortran ABI 验证（全 int 约定）=="
cat > t.f <<'EOF'
      subroutine fill(a, n, s)
      integer a(5), n, i
      character*(*) s
      a(1)=1
      do 10 i=2,5
      a(i)=a(i-1)+n
10    continue
      end
EOF
$F2C -a -w -w66 -R t.f
cat > main.c <<'EOF'
#include <stdio.h>
extern void fill_(int *a, int *n, int *slen);
int main(){
  int a[5]={0,0,0,0,0}, n=10, slen=4;
  fill_(a,&n,&slen);
  printf("%d %d %d %d %d\n",a[0],a[1],a[2],a[3],a[4]);
  return 0;
}
EOF
gcc -O2 -Ilib -c t.c -o t.o
gcc main.c t.o lib/libf2c.a -lm -o abitest
./abitest && echo "（期望输出: 1 11 21 31 41）"
