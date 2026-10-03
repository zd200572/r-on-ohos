#!/usr/bin/env python3
"""Verify OpenBLAS shared library: ELF arch, symbols, dlopen test."""
import paramiko, base64

ssh = paramiko.SSHClient()
ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
ssh.connect('100.95.132.23', port=22, username='bz', password='201501', timeout=15)

script = r"""#!/bin/bash
cd /tmp/OpenBLAS-0.3.29
SO=libopenblas_armv8-r0.3.29.so

echo "=== 1. ELF file type ==="
file $SO

echo "=== 2. ELF header (architecture) ==="
readelf -h $SO | grep -E 'Class|Machine|Type|OS/ABI'

echo "=== 3. Dynamic section (soname, deps) ==="
readelf -d $SO | grep -E 'SONAME|NEEDED'

echo "=== 4. Key BLAS symbols (sgemm_, dgemm_, sgemv_, dgemv_) ==="
nm -D $SO | grep -E 'sgemm_|dgemm_|sgemv_|dgemv_|saxpy_|daxpy_' | head -10

echo "=== 5. Total exported symbols count ==="
nm -D $SO | grep ' T ' | wc -l

echo "=== 6. CBLAS symbols (cblas_sgemm, cblas_dgemm) ==="
nm -D $SO | grep -E 'cblas_sgemm|cblas_dgemm|cblas_saxpy|cblas_daxpy' | head -5

echo "=== 7. dlopen test (C program) ==="
cat > /tmp/oblas_test.c << 'EOF'
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>

int main() {
    void *handle = dlopen("/tmp/OpenBLAS-0.3.29/libopenblas_armv8-r0.3.29.so", RTLD_NOW);
    if (!handle) {
        fprintf(stderr, "dlopen failed: %s\n", dlerror());
        return 1;
    }
    printf("dlopen OK\n");

    // Try to get cblas_dgemm
    void *sym = dlsym(handle, "cblas_dgemm");
    if (!sym) {
        fprintf(stderr, "dlsym cblas_dgemm failed: %s\n", dlerror());
        dlclose(handle);
        return 1;
    }
    printf("cblas_dgemm found at %p\n", sym);

    // Try openblas_get_config
    void *config = dlsym(handle, "openblas_get_config");
    if (config) {
        printf("openblas_get_config found at %p\n", config);
    }

    dlclose(handle);
    printf("All OK!\n");
    return 0;
}
EOF

BREW=/storage/Users/currentUser/.harmonybrew
export PATH=$BREW/bin:$PATH
export LD_PRELOAD=/usr/lib/libpthread_stub.so
export LD_LIBRARY_PATH=$BREW/lib:${LD_LIBRARY_PATH:-}

clang -o /tmp/oblas_test /tmp/oblas_test.c -ldl -lm
/tmp/oblas_test

echo ""
echo "=== 8. Simple BLAS test (dgemm via cblas) ==="
cat > /tmp/blas_calc.c << 'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <cblas.h>

int main() {
    // 2x2 matrix multiply: A * B = C
    // A = [1 2; 3 4], B = [5 6; 7 8]
    // C = [19 22; 43 50]
    double A[4] = {1, 2, 3, 4};
    double B[4] = {5, 6, 7, 8};
    double C[4] = {0};

    cblas_dgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans,
                2, 2, 2, 1.0, A, 2, B, 2, 0.0, C, 2);

    printf("C = [%.0f %.0f; %.0f %.0f]\n", C[0], C[1], C[2], C[3]);
    printf("Expected: [19 22; 43 50]\n");

    if (C[0]==19 && C[1]==22 && C[2]==43 && C[3]==50) {
        printf("BLAS computation CORRECT!\n");
        return 0;
    } else {
        printf("BLAS computation WRONG!\n");
        return 1;
    }
}
EOF

clang -o /tmp/blas_calc /tmp/blas_calc.c -I. -L. -lopenblas -lm
LD_LIBRARY_PATH=/tmp/OpenBLAS-0.3.29:$LD_LIBRARY_PATH /tmp/blas_calc
"""

b64 = base64.b64encode(script.encode()).decode()
cmd = f'docker exec ohos bash -c "echo {b64} | base64 -d | bash"'
stdin, stdout, stderr = ssh.exec_command(cmd, timeout=60)
print(stdout.read().decode())
err = stderr.read().decode()
if err:
    print("ERR:", err)
ssh.close()