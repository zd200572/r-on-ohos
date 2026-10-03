#!/bin/bash
BREW=/storage/Users/currentUser/.harmonybrew
RH=$BREW/Cellar/r/4.5.1

export LD_PRELOAD=/usr/lib/libpthread_stub.so
export LD_LIBRARY_PATH=$BREW/lib:${LD_LIBRARY_PATH:-}

# === Fix 1: Patch OHOS SDK linux/socket.h ===
SOCKET_H=/opt/ohos-sdk/ohos/native/llvm/bin/../../sysroot/usr/include/linux/socket.h
echo "=== Before patch ==="
grep -n sockaddr_storage $SOCKET_H

# Backup if not already backed up
if [ ! -f ${SOCKET_H}.orig ]; then
  cp $SOCKET_H ${SOCKET_H}.orig
fi

# Replace sockaddr_storage with __kernel_sockaddr_storage in linux/socket.h
sed -i 's/struct sockaddr_storage/struct __kernel_sockaddr_storage/g' $SOCKET_H
echo "=== After patch ==="
grep -n sockaddr_storage $SOCKET_H

# === Fix 2: Install webp for ragg ===
echo "=== Installing webp ==="
brew install webp 2>&1 | tail -5
echo "=== Check libwebp pkg-config ==="
pkg-config --exists libwebp && echo "libwebp found!" || echo "libwebp still not found"

# === Now reinstall failed packages ===
echo "=== Reinstalling ps, processx, callr, reprex, ragg, tidyverse ==="
$RH/bin/Rscript -e 'install.packages(c("ps","processx","callr","reprex","ragg","tidyverse"), repos="https://cloud.r-project.org", type="source")' > /tmp/reinstall.log 2>&1 &
echo "PID=$!"