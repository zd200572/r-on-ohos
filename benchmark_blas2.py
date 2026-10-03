#!/usr/bin/env python3
"""Run benchmarks using R script files to avoid shell mangling."""
import paramiko, base64

ssh = paramiko.SSHClient()
ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
ssh.connect('100.95.132.23', port=22, username='bz', password='201501', timeout=15)

# R benchmark script
r_script = """set.seed(42)
benchmark <- function(n) {
  A <- matrix(rnorm(n*n), n, n)
  B <- matrix(rnorm(n*n), n, n)
  t0 <- Sys.time()
  C <- A %*% B
  t1 <- Sys.time()
  matmul_time <- as.numeric(t1-t0, units="secs")
  t0 <- Sys.time()
  Ai <- solve(A)
  t1 <- Sys.time()
  solve_time <- as.numeric(t1-t0, units="secs")
  t0 <- Sys.time()
  s <- svd(A)
  t1 <- Sys.time()
  svd_time <- as.numeric(t1-t0, units="secs")
  t0 <- Sys.time()
  cp <- crossprod(A, B)
  t1 <- Sys.time()
  cp_time <- as.numeric(t1-t0, units="secs")
  cat(sprintf("n=%4d  matmul=%.3fs  solve=%.3fs  svd=%.3fs  crossprod=%.3fs\\n",
              n, matmul_time, solve_time, svd_time, cp_time))
}
for (n in c(100, 500, 1000, 2000, 3000)) {
  benchmark(n)
}
"""

r_b64 = base64.b64encode(r_script.encode()).decode()

script = f"""#!/bin/bash
BREW=/storage/Users/currentUser/.harmonybrew
export PATH=$BREW/bin:$PATH
export LD_PRELOAD=/usr/lib/libpthread_stub.so
export LD_LIBRARY_PATH=$BREW/lib:${{LD_LIBRARY_PATH:-}}

R_HOME=$BREW/Cellar/r/4.5.1/lib/R

# Write benchmark R script
echo '{r_b64}' | base64 -d > /tmp/bench.R

echo "=== OpenBLAS benchmark ==="
R -f /tmp/bench.R 2>&1 | grep 'n='

echo ""
echo "=== Switch to reference BLAS ==="
mv $R_HOME/lib/libRblas.so $R_HOME/lib/libRblas.so.openblas
cp $R_HOME/lib/libRblas.so.orig $R_HOME/lib/libRblas.so

echo "=== Reference BLAS benchmark ==="
R -f /tmp/bench.R 2>&1 | grep 'n='

echo ""
echo "=== Restore OpenBLAS ==="
rm $R_HOME/lib/libRblas.so
mv $R_HOME/lib/libRblas.so.openblas $R_HOME/lib/libRblas.so
R -e 'cat("BLAS:", unlist(tools::get_BLAS_lib()), "\\n")' 2>&1 | grep 'BLAS:'
"""

b64 = base64.b64encode(script.encode()).decode()
cmd = f'docker exec ohos bash -c "echo {b64} | base64 -d | bash"'
stdin, stdout, stderr = ssh.exec_command(cmd, timeout=300)
print(stdout.read().decode())
err = stderr.read().decode()
if err:
    print("ERR:", err)
ssh.close()