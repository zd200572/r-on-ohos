#!/usr/bin/env python3
"""从 nm 输出文件中提取 f2c_ 前缀符号，生成桥接库。"""
import subprocess, sys, os

nm_file = sys.argv[1] if len(sys.argv) > 1 else "/tmp/clapack_nm.txt"
out_dir = sys.argv[2] if len(sys.argv) > 2 else "build/out/host-deps"

names = set()
with open(nm_file) as f:
    for line in f:
        parts = line.split()
        for p in parts:
            if p.startswith("f2c_") and len(p) > 4:
                names.add(p[4:])

names = sorted(names)
print(f"需要桥接的 BLAS 函数数量: {len(names)}")

asm_file = "/tmp/f2c_blas_aliases.s"
with open(asm_file, "w") as f:
    f.write(".text\n")
    for name in names:
        f.write(f".globl f2c_{name}\n")
        f.write(f".type f2c_{name}, @function\n")
        f.write(f"f2c_{name}:\n")
        f.write(f"    jmp {name}_\n")

print(f"汇编文件已生成: {asm_file}")

obj_file = "/tmp/f2c_blas_bridge.o"
subprocess.run(["gcc", "-c", asm_file, "-o", obj_file], check=True)

lib_path = os.path.join(out_dir, "lib", "libf2cblasbridge.a")
subprocess.run(["ar", "cr", lib_path, obj_file], check=True)
subprocess.run(["ranlib", lib_path], check=True)

print(f"桥接库已创建: {lib_path}")

result = subprocess.run(["nm", lib_path], capture_output=True, text=True)
defined = [l for l in result.stdout.splitlines() if " T f2c_" in l]
print(f"已定义别名数量: {len(defined)}")
