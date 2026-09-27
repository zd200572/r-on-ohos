#!/usr/bin/env bash
cd ~/r-on-ohos/build/out/src/R-4.5.1-host/src/appl
export F2C_BIN=$HOME/r-on-ohos/build/out/host-tools/bin/f2c
export DEPS_PREFIX=$HOME/r-on-ohos/build/out/host-deps
export F77_CC=gcc
rm -f dqrdc2.c
~/r-on-ohos/build/f77 -fPIE -O2 -c dqrdc2.f -o dqrdc2.o
echo "EXIT=$?"
