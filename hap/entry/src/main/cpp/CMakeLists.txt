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
# R 原生库树（包 .so / 模块 .so）复制进 CMake 输出目录的 R/ 子目录。
# HarmonyOS app-data 挂载 noexec，包 .so 解包到数据目录后 dlopen 会被拒；
# 必须放在 nativeLibraryDir（可执行）。hvigor 会把 CMake 输出目录整个内容
# 打包进 HAP libs/<abi>/，因此带子目录的 R/ 树经此途径进入 nativeLibraryDir/R/。
# 运行时 Rdynload.c 的 remapDLLPath 会把 R_HOME 前缀重映射到 R_NATIVE_LIBRARY_ROOT。
set(R_NATIVE_TREE "${CMAKE_CURRENT_SOURCE_DIR}/../../../libs/${OHOS_ARCH}/R")
if(EXISTS "${R_NATIVE_TREE}")
    add_custom_command(TARGET entry POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_directory
            "${R_NATIVE_TREE}"
            "$<TARGET_FILE_DIR:entry>/R"
        COMMENT "Copying R native library tree to output dir")
endif()
