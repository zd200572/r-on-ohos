class Openblas < Formula
  desc "Optimized BLAS library based on GotoBLAS2"
  homepage "https://www.openblas.net/"
  url "https://github.com/OpenMathLib/OpenBLAS/releases/download/v0.3.29/OpenBLAS-0.3.29.tar.xz"
  sha256 "eb691e2cff83799400da22aa6ab93ebaa346ad317fea578b7ae119e226ce1b01"
  license "BSD-3-Clause"

  # OpenBLAS 0.3.29 cross-compiled for OHOS (aarch64)
  # Key flags:
  #   NOFORTRAN=1    - no Fortran compiler needed (use C wrappers)
  #   NO_LAPACK=1    - skip LAPACK (R bundles its own LAPACK)
  #   USE_THREAD=0   - single-threaded (avoids pthread issues on OHOS)
  #   TARGET=ARMV8   - ARM64 assembly optimizations

  def install
    args = %W[
      NOFORTRAN=1
      NO_LAPACK=1
      USE_THREAD=0
      USE_OPENMP=0
      TARGET=ARMV8
      BINARY=64
      CC=#{ENV.cc}
      AR=llvm-ar
      RANLIB=llvm-ranlib
      HOSTCC=gcc
      PREFIX=#{prefix}
    ]

    system "make", "shared", *args
    system "make", "install", *args
  end

  test do
    (testpath/"test.c").write <<~EOF
      #include <cblas.h>
      #include <stdio.h>
      int main() {
        double A[4] = {1, 2, 3, 4};
        double B[4] = {5, 6, 7, 8};
        double C[4] = {0};
        cblas_dgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans,
                    2, 2, 2, 1.0, A, 2, B, 2, 0.0, C, 2);
        printf("%.0f %.0f %.0f %.0f\\n", C[0], C[1], C[2], C[3]);
        return 0;
      }
    EOF
    system ENV.cc, "test.c", "-I#{include}", "-L#{lib}", "-lopenblas", "-lm", "-o", "test"
    assert_equal "19 22 43 50", shell_output("./test").strip
  end
end