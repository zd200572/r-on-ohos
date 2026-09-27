cmake_minimum_required(VERSION 3.5.0)
project(rhost)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

# 主进程 NAPI 桥：解包 tar + 启动 NativeChildProcess 子进程 + stdio 管道桥接
add_library(entry SHARED rhost.cpp)
target_link_libraries(entry PUBLIC libace_napi.z.so libhilog_ndk.z.so libchild_process.so)

# 子进程库：由 OH_Ability_StartNativeChildProcess("librchild.so:Main") 加载。
# dlopen libR.so（依赖预加载 libz/libomp）并运行 R 嵌入主循环。
# 不链接 libR.so —— 运行时 dlopen，避免构建期依赖；导出符号 Main 需 default 可见性。
add_library(rchild SHARED rchild.cpp)
target_link_libraries(rchild PUBLIC libhilog_ndk.z.so)
