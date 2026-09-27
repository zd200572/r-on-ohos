# 供交叉编译 cmake 依赖库（zlib/bzip2/xz/pcre2/libpng 等）使用
# 用法: cmake -DCMAKE_TOOLCHAIN_FILE=<本文件> ...
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR "$ENV{OHOS_ARCH}")

set(OHOS_NDK   "$ENV{OHOS_NDK}")
set(_triple    "$ENV{OHOS_TRIPLE}")
set(_toolchain "${OHOS_NDK}/native/llvm/bin")

set(CMAKE_C_COMPILER   "${_toolchain}/clang")
set(CMAKE_CXX_COMPILER "${_toolchain}/clang++")
set(CMAKE_C_COMPILER_TARGET   "${_triple}")
set(CMAKE_CXX_COMPILER_TARGET "${_triple}")
set(CMAKE_SYSROOT "${OHOS_NDK}/native/sysroot")

set(CMAKE_C_FLAGS_INIT   "-D__MUSL__")
set(CMAKE_CXX_FLAGS_INIT "-D__MUSL__")
set(CMAKE_FIND_ROOT_PATH "${CMAKE_SYSROOT}" "$ENV{DEPS_PREFIX}")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
