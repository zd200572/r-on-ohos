#!/usr/bin/env python3
"""Replace R's reference BLAS with OpenBLAS and benchmark."""
import paramiko, base64

ssh = paramiko.SSHClient()
ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
ssh.connect('100.95.132.23', port=22, username='bz', password='201501', timeout=15)

script = r"""#!/bin/bash
BREW=/storage/Users/currentUser/.harmonybrew
export PATH=$BREW/bin:$PATH
export LD_PRELOAD=/usr/lib/libpthread_stub.so
export LD_LIBRARY_PATH=$BREW/lib:${LD_LIBRARY_PATH:-}

R_HOME=$BREW/Cellar/r/4.5.1/lib/R
OBLAS=$BREW/Cellar/openblas/0.3.29/lib/libopenblas_armv8-r0.3.29.so

echo "=== 1. Backup R's reference BLAS ==="
if [ ! -f $R_HOME/lib/libRblas.so.orig ]; then
  cp $R_HOME/lib/libRblas.so $R_HOME/lib/libRblas.so.orig
  echo "Backed up to libRblas.so.orig"
else
  echo "Backup already exists"
fi
ls -la $R_HOME/lib/libRblas.so.orig

echo ""
echo "=== 2. Benchmark with reference BLAS (before) ==="
R -e '
set.seed(42)
n <- 1000
A <- matrix(rnorm(n*n), n, n)
B <- matrix(rnorm(n*n), n, n)
t0 <- Sys.time()
C <- A %*% B
t1 <- Sys.time()
cat(sprintf("Reference BLAS 1000x1000 matmul: %.3f sec\n", as.numeric(t1-t0, units="secs")))
cat(sprintf("Checksum: %.6f\n", sum(C)))
' 2>&1 | grep -E 'Reference|Checksum'

echo ""
echo "=== 3. Replace libRblas.so with OpenBLAS symlink ==="
# Remove old libRblas.so and create symlink to OpenBLAS
rm $R_HOME/lib/libRblas.so
ln -s $OBLAS $R_HOME/lib/libRblas.so
ls -la $R_HOME/lib/libRblas.so
file $R_HOME/lib/libRblas.so

echo ""
echo "=== 4. Benchmark with OpenBLAS (after) ==="
R -e '
set.seed(42)
n <- 1000
A <- matrix(rnorm(n*n), n, n)
B <- matrix(rnorm(n*n), n, n)
t0 <- Sys.time()
C <- A %*% B
t1 <- Sys.time()
cat(sprintf("OpenBLAS 1000x1000 matmul: %.3f sec\n", as.numeric(t1-t0, units="secs")))
cat(sprintf("Checksum: %.6f\n", sum(C)))
' 2>&1 | grep -E 'OpenBLAS|Checksum'

echo ""
echo "=== 5. Verify R still works correctly ==="
R -e '
# Basic sanity checks
cat("1+1 =", 1+1, "\n")
cat("mean(1:100) =", mean(1:100), "\n")
# Matrix operations
m <- matrix(c(1,2,3,4), 2, 2)
cat("det(m) =", det(m), "\n")
cat("solve(m) =\n")
print(solve(m))
# Eigenvalues
e <- eigen(m)
cat("eigenvalues:", e$values, "\n")
# Linear model
x <- 1:10
y <- 2*x + 1 + rnorm(10, 0, 0.1)
fit <- lm(y ~ x)
cat("lm coef:", coef(fit), "\n")
' 2>&1 | tail -15

echo ""
echo "=== 6. Check R sees OpenBLAS ==="
R -e 'sessionInfo()' 2>&1 | grep -i blas | head -3
"""

b64 = base64.b64encode(script.encode()).decode()
cmd = f'docker exec ohos bash -c "echo {b64} | base64 -d | bash"'
stdin, stdout, stderr = ssh.exec_command(cmd, timeout=120)
print(stdout.read().decode())
err = stderr.read().decode()
if err:
    print("ERR:", err)
ssh.close()