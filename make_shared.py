#!/usr/bin/env python3
"""Execute make shared for OpenBLAS and check results."""
import paramiko, base64, time

ssh = paramiko.SSHClient()
ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
ssh.connect('100.95.132.23', port=22, username='bz', password='201501', timeout=15)

script = r"""#!/bin/bash
cd /tmp/OpenBLAS-0.3.29

BREW=/storage/Users/currentUser/.harmonybrew
export PATH=$BREW/bin:$PATH
export LD_PRELOAD=/usr/lib/libpthread_stub.so
export LD_LIBRARY_PATH=$BREW/lib:${LD_LIBRARY_PATH:-}

echo "=== Step 1: Execute make shared ==="
make -j4 shared \
  NOFORTRAN=1 \
  USE_THREAD=0 USE_OPENMP=0 \
  TARGET=ARMV8 BINARY=64 \
  CC=clang AR=llvm-ar RANLIB=llvm-ranlib \
  HOSTCC=gcc \
  2>&1 | tail -40

echo ""
echo "=== Step 2: Check output files ==="
ls -la libopenblas*.so* 2>/dev/null || echo "No .so found"
ls -la libopenblas*.a 2>/dev/null || echo "No .a found"

echo ""
echo "=== Step 3: Check exports directory ==="
ls -la exports/*.so* 2>/dev/null || echo "No .so in exports/"
"""

b64 = base64.b64encode(script.encode()).decode()
cmd = f'docker exec ohos bash -c "echo {b64} | base64 -d | bash"'
stdin, stdout, stderr = ssh.exec_command(cmd, timeout=120)
print(stdout.read().decode())
err = stderr.read().decode()
if err:
    print("ERR:", err)
ssh.close()