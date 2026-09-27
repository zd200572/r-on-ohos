# R on OpenHarmony / HarmonyOS PC（移植工程）

把 **R 语言运行时**（CRAN R 4.5.x）交叉编译到鸿蒙电脑（HarmonyOS NEXT PC，arm64 + musl libc），
并提供两种使用形态：

```
形态 A（开发期直跑）                形态 B（正式应用）
┌──────────────────────┐          ┌─────────────────────────────────┐
│ WSL2 交叉编译          │          │ HAP 应用（hap/ 目录，ArkTS 工程）  │
│   ↓                  │          │  ArkUI 终端页 (Index.ets)        │
│ rhome.tar (R 安装树)  │  hdc     │  NDK 原生桥 (cpp/rhost.cpp)      │
│   ↓                  │ ──────→  │   fork/exec R + stdio 管道       │
│ PC /data/local/tmp   │          │  沙箱内解包 R_HOME               │
│ 直接执行 R.bin        │          │   ↓ R --slave --interactive     │
└──────────────────────┘          └─────────────────────────────────┘
```

## 核心技术决策

| 难点 | 方案 |
|------|------|
| OHOS NDK 无 Fortran 编译器 | f2c 把 R 的 Fortran 源码转成 C，再用 clang 编译（R 源码自带 `scripts/f77_f2c` 参考；Termux 的 Android R 移植同思路） |
| R 官方不支持交叉编译 | 两阶段构建：先编译一份 x86_64 Linux 的 host R，交叉构建目标 R 时让构建期脚本跑 host R |
| 目标平台 musl libc | 需要交叉编译 bzip2/xz/pcre2/ncurses/readline；zlib、iconv 由 sysroot 自带 |
| 执行方式 | 形态 A 用 hdc shell 直跑；形态 B 在 HAP 内解包到沙箱后 fork/exec（若沙箱禁执行则走 nativeLibraryDir 方案，见 docs/05） |

## 目录结构

```
docs/    移植指南（01 路线 → 02 环境 → 03 交叉编译 → 04 HAP 封装 → 05 问题清单）
build/   交叉编译脚本（在 WSL Ubuntu 中运行，逐个见脚本头注释）
patches/ 源码补丁说明（首轮以 sed/脚本内补丁为主，收敛后固化）
hap/     DevEco Studio 工程（ArkTS 终端 UI + NDK 原生桥）
```

## 快速开始

前置条件：WSL Ubuntu、Linux 版 OpenHarmony SDK（见 docs/02）、DevEco Studio 6.x（已装）。

```bash
# 1) WSL 里配置 SDK 路径后一键构建（首次约 30–60 分钟）
cd /mnt/c/Users/chengzhenyang/.zcode/workspace/default/r-on-ohos/build
export OHOS_NDK=/opt/ohos-sdk      # Linux 版 OpenHarmony SDK
./all.sh                           # 默认 aarch64（真机）；模拟器验证用: OHOS_ARCH=x86_64 ./all.sh

# 2a) 无真机：DevEco Device Manager 用 pc_all_x86 镜像建 PC 模拟器后同样可跑（docs/02）
# 2b) 真机直跑（开发者模式 + hdc）
./50-install-device.sh

# 2c) 或打包进 HAP：用 DevEco Studio 打开 hap/ 工程，Run 到模拟器/真机
```

## 状态

- [x] 工程骨架、构建脚本、HAP 应用骨架
- [ ] 首轮上机编译调试（预计需按 docs/03 的清单迭代修 configure 缓存与补丁）
- [ ] CRAN 包生态（纯 R 包可直接装；含 C/Fortran 的包需建立 OHOS 预编译仓库，见 docs/05）

R 以 GPL-2/3 发布，二次分发请保留许可证与源码获取途径（docs/05）。
