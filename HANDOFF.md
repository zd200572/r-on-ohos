# 交接文档 —— R 语言移植到鸿蒙 PC（r-on-ohos）

> 写给下一个接手的 agent / 开发者。读完这一篇即可继续干活，不用重新摸索。
> 最后更新：2026-09-27 —— **R REPL 在 HAP UI 中完整运行！** 输入 `1+1` → UI 显示 `[1] 2`。
> 关键修复：① 删除 stub libz.so 让系统 linker 找真 zlib；② 用 R_ReplDLLdo1 替代 Rf_mainloop 避免定时器 segfault；③ 设置全部 17 个 ptr_R_* 回调；④ SIGABRT/SIGSEGV 拦截 + siglongjmp；⑤ **放弃 threadsafe function（OHOS napi_call_function bug），改用轮询机制**。

## 1. 目标与总体路线

把 CRAN R 4.5.1 交叉编译到鸿蒙电脑（aarch64 + musl，`aarch64-unknown-linux-ohos`），
当前先用 **x86_64-unknown-linux-ohos** 目标在鸿蒙 PC 模拟器里打通全流程（本机已装
HarmonyOS 6.0.0 pc_all_x86 镜像），之后 `OHOS_ARCH=aarch64` 一键重编给真机。

核心难点与已定路线：
- OHOS NDK 无 Fortran → **f2c 方案**（R 官方 R-admin B.6 认可），f77 用包装脚本 `build/f77`
- R 自带 BLAS/LAPACK 源码含 f90 构造（f2c 不支持）→ **外部 OpenBLAS(NOFORTRAN) + CLAPACK**
- R 官方"不支持交叉编译"→ **两阶段构建**：先编 host 版 R 供构建期脚本使用
- 落地形态：A) hdc 直跑；B) HAP 应用（hap/ 工程，ArkUI 终端页 + NDK 原生桥）

## 2. 环境事实（本机特有，务必遵守）

| 项 | 值 |
|----|----|
| 源码真身（Windows） | `C:\Users\chengzhenyang\.zcode\workspace\default\r-on-ohos` |
| WSL 构建副本 | `~/r-on-ohos`（Ubuntu 22.04；**改了 Windows 侧脚本必须重新同步**，见 §3） |
| WSL sudo | **无密码，不能用**。装东西用 `apt-get download xxx + dpkg -x`（f2c 就是这么装的）或源码自编 |
| Linux OHOS SDK | `~/ohos-sdk`（5.0.3-Release，含 native/llvm + musl sysroot）。注意 5.0.3 编出的二进制向上兼容 6.0 模拟器 |
| Windows OHOS SDK | `D:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\native`（仅 Windows 工具链，WSL 里用不了） |
| 模拟器镜像 | `%LOCALAPPDATA%\Huawei\Sdk\system-image\HarmonyOS-6.0.0\pc_all_x86`；Emulator 里已有部署好的 `Huawei_2in1` 实例 |
| QEMU 模拟器 | `C:\Users\chengzhenyang\Desktop\6.0qemu\run.bat`（独立 QEMU，端口转发 55555） |
| hdc 工具 | `D:\Softs\Deveco\20\toolchains\hdc.exe` 或 `D:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe` |
| 机器 | 16 核 / 14G 内存 / 900G+ 空闲（WSL ext4） |
| WSL 网络特点 | github 直连不稳（SSL 中断/截断），**用 TUNA 镜像**（debian pool、gnu、CRAN 全有）；netlib/ftp.gnu.org/curl.se/sourceware 可用但慢（~10KB/s） |

## 3. 操作规程（每个接手者都要会的三个动作）

### 3.1 同步脚本 Windows → WSL（改完脚本必做）

```bash
MSYS_NO_PATHCONV=1 wsl -d Ubuntu -- bash -c "cp '/mnt/c/Users/chengzhenyang/.zcode/workspace/default/r-on-ohos/build/'*.sh '/mnt/c/Users/chengzhenyang/.zcode/workspace/default/r-on-ohos/build/f90fix.py' '/mnt/c/Users/chengzhenyang/.zcode/workspace/default/r-on-ohos/build/f2c.h' '/mnt/c/Users/chengzhenyang/.zcode/workspace/default/r-on-ohos/build/patch-makebasedb.py' '/mnt/c/Users/chengzhenyang/.zcode/workspace/default/r-on-ohos/build/patch-makefile.py' ~/r-on-ohos/build/ && chmod +x ~/r-on-ohos/build/*.sh ~/r-on-ohos/build/f77 && echo SYNCED"
```

**注意**：`f77` 没有 `.sh` 后缀，`*.sh` 不会带上它，需单独 cp（上面的命令已包含）。
`patch-makebasedb.py` 和 `patch-makefile.py` 也需同步。

### 3.2 后台跑构建链（三条链，全部幂等可重跑）

```bash
MSYS_NO_PATHCONV=1 wsl -d Ubuntu -- bash -c "bash ~/r-on-ohos/build/wsl-a.sh 2>&1 | tee ~/r-on-ohos/build/chainA.log"   # SDK→依赖→libf2c   【已完成 ✓】
MSYS_NO_PATHCONV=1 wsl -d Ubuntu -- bash -c "bash ~/r-on-ohos/build/wsl-b.sh 2>&1 | tee ~/r-on-ohos/build/chainB.log"   # host R            【已完成 ✓】
MSYS_NO_PATHCONV=1 wsl -d Ubuntu -- bash -c "bash ~/r-on-ohos/build/wsl-c.sh 2>&1 | tee ~/r-on-ohos/build/chainC.log"   # 目标 R→打包       【已完成 ✓】
```

链 C 需设置 `OHOS_ARCH=x86_64 OHOS_NDK=~/ohos-sdk`（env.sh 默认 aarch64）。
日志直接看 WSL 里的 `~/r-on-ohos/build/chain*.log`。

### 3.3 wsl.exe 传参的三大坑（踩过才写在这里）

1. **复杂 bash 一律写成文件再执行**（`bash /mnt/c/.../build/xxx.sh`）。内联 `bash -c "..."` 里
   `$var`、`$()`、嵌套引号会被 Git Bash 抢先展开，症状是"循环变量变空/命令被截断"。
   `/mnt/...` 路径必须加 `MSYS_NO_PATHCONV=1`，否则被改写成 `D:/Program Files/Git/mnt/...`。
2. `pkill -f 'xxx'` 会匹配到**自己**的命令行自杀（exit 15 伪装成构建失败）。
3. 管道里 `awk '{print $3}'` 的 `$3` 同理会被吞——统计/诊断脚本写文件。

## 4. 当前状态（截至交接时刻）

### 已完成 ✓
- **链 A 全部**：Linux OHOS SDK 解包；交叉依赖（pcre2/bzip2/xz/ncurses+readline/
  libpng/openssl/curl，全静态库）；目标 libf2c.a + libf2cblas.a；host 侧同款
- **链 B 全部**：host R 4.5.1 构建成功，安装到 `~/r-on-ohos/build/out/host-r/`
- **链 C 全部**：目标 R 交叉编译 + `make install` + strip 精简 + 打包完成
  - 产物：`rhome-x86_64.tar`（33M，ustar 格式）、`librbin.so`（8K）、`libR.so`（4.1M）
  - 安装树：`~/r-on-ohos/build/out/r-ohos-x86_64/lib/R/`
  - `exec/R` 验证为 x86_64 ELF（dynamically linked, interpreter /lib/ld-musl-x86_64.so.1）
  - 所有核心 R 包已安装：base, compiler, datasets, grDevices, graphics, grid, methods,
    parallel, splines, stats, stats4, tcltk, tools, translations, utils
  - 设备端配置文件已创建：Rprofile.site（TUNA CRAN 镜像）、Renviron.site（R_LIBS_USER）
- f2c ABI 实测验证通过；OpenBLAS 复数返回约定修复实测通过
- HAP 工程骨架、全部构建脚本、5 篇文档（docs/01–05）

### HAP 构建已完成 ✓（2026-09-26）
- **HAP 构建成功**：`entry-default-unsigned.hap` 已产出
  - 构建路径需在 `C:\r-on-ohos-hap`（原 `.zcode` 路径导致 hvigor 报 "Path not found"）
  - 产物：`C:\r-on-ohos-hap\entry\build\default\outputs\default\entry-default-unsigned.hap`
- **修复了 3 个构建问题**：
  - rhost.cpp: `napi_get_value_string_utf8` 的 `const char*` → `char*`（用 `&out[0]` 替代 `out.data()`）
  - Index.ets: 移除 `ESObject` 类型（ArkTS 严格模式禁止 `any/unknown`）
  - 缺失 `$media:app_icon` / `$media:icon` 图标资源 → 用 Node.js 生成最小 PNG
- **产物文件已同步**到 Windows HAP 工程：
  - `hap/entry/libs/x86_64/libR.so`（4.1M）、`librbin.so`（4.9K）
  - `hap/entry/src/main/resources/rawfile/rhome.tar`（33M）
- **代码修复已同步回**原项目目录

### NativeChildProcess 方案已实现 ✓（2026-09-27）

**execv 根因确认**：鸿蒙应用沙箱**硬性禁止** execv 任何非系统签名二进制——应用数据目录
（`/data/storage/el2/base/...`）和 nativeLibraryDir（`/data9.0.0(20)`）都被拒（errno=13 EACCES）。
这是系统安全设计，无权限可开。`verify_r.bat` 证实 R 二进制本身能在设备上运行（musl 解释器正常），
仅缺 `libz.so`/`libomp.so` 两个动态依赖——两者已补进 `R/lib/` 并重新打包 `rhome.tar`（34M）。

**官方出路**：`OH_Ability_StartNativeChildProcess`（`native_child_process.h`，API 13+，PC/2in1 支持）。
系统 dlopen 指定 so 并调用入口函数，进程由系统创建——绕过 execv 限制。fd 可通过
`NativeChildProcess_FdList`（≤16 个）桥接 stdio。

**实现（全部构建通过，CMake 一体编译，无需单独交叉编译）**：
- `entry/src/main/cpp/rchild.cpp`（新）：子进程库。`extern "C" void Main(NativeChildProcess_Args args)`：
  按 fd 名 `rstdin`/`rstdout` 提取管道并 dup2 → 解析 entryParams（`R_HOME=...;WORKDIR=...;LIBSDIR=...;NATIVELIBDIR=...`）
  → 设环境变量 → **按依赖顺序预加载 libomp.so/libz.so 再 dlopen libR.so**（RTLD_GLOBAL）
  → `Rf_initEmbeddedR(5, argv)` + `Rf_mainloop()` 跑 R REPL
- `rhost.cpp`（改）：`StartR` 中 fork/execv 整段替换为 NCP 调用；entry 格式 `"librchild.so:Main"`；
  `PumpThread` 的 waitpid 容错（NCP 子进程非 fork 所出，可能返回 ECHILD）
- `CMakeLists.txt`（改）：新增 `rchild` 共享库目标；entry 链接 `libchild_process.so`

**关键技术事实（踩坑记录）**：
1. `Rf_initEmbeddedR`（R 4.5.1 `src/unix/Rembedded.c`）= `Rf_initialize_R` + **强制 `R_Interactive=TRUE`**
   + `setup_Rmainloop` —— 恰好抵消「stdin 为管道非 tty」导致的非交互误判，官方嵌入姿势
2. libR.so 四符号均导出（readelf 已核）：`Rf_initialize_R` / `setup_Rmainloop` / `Rf_mainloop` / `Rf_initEmbeddedR`
3. libR.so 的 RUNPATH 指向构建机路径（`/home/zd200572/...`），设备上无效 → 依赖必须显式预加载：
   **musl 运行时 setenv LD_LIBRARY_PATH 对 dlopen 搜索无效**（启动时缓存），必须绝对路径 dlopen；
   dlopen 递归解析依赖时命中「已加载库列表」→ 先 dlopen libomp.so、libz.so（绝对路径）再 dlopen libR.so
4. libz.so（sysroot 版）是真 ELF 动态库（static-pie 自包含无 NEEDED）；libomp.so 仅依赖 libc.so ✓
5. **API 符号红线**：设备 API 20 的系统库不含 API 21+ 符号。只能引用
   `OH_Ability_StartNativeChildProcess`（13）；`OH_Ability_KillChildProcess`（22）等不可用——
   多引用会导致 HAP 安装后加载 libentry.so 时符号解析失败直接崩
6. NCP 进程与父进程同 uid（`NCP_ISOLATION_MODE_NORMAL`）→ `kill(pid, SIGINT/SIGTERM)` 可用于中断/停止
7. `libz.so`/`libomp.so` 双保险：已复制进 `entry/libs/x86_64/`（NATIVELIBDIR 优先命中）
   且 `rhome.tar` 的 `R/lib/` 内也有（第二兜底路径）
8. HAP 构建命令行直跑需设 `DEVECO_SDK_HOME="D:/Softs/DevEco/DevEco Studio/sdk"`；原生编译后
   打包大 tar 易超工具 300s 限制，可直接：
   `node "D:/Softs/DevEco/DevEco Studio/tools/hvigor/bin/hvigorw.js" --mode module -p module=entry@default -p product=default -p buildMode=release assembleHap --no-daemon`

**构建脚本修复**：`40-pack.sh` 已固化 libomp.so/libz.so 分发逻辑（缺失时自动从 SDK 补进 R/lib
并复制到 HAP libs）；`env.sh` 的 `OHOS_NDK` 默认路径已改为实际路径 `~/ohos-sdk`。

**产物**：`entry-default-unsigned.hap`（42.6MB，2026-09-27 07:27），已验证包内含
`librchild.so`（Main 符号 C 导出 ✓）、`libR.so`、`libomp.so`、`libz.so`、`rhome.tar`(34.7MB)。

### 待验证 ⏳
- ~~模拟器验证~~：**已通过 ✓**（2026-09-27）

### R REPL 在 HAP UI 中完整运行 ✓（2026-09-27）

**验证结果**：HAP 安装到鸿蒙 PC 模拟器（API 20, 2in1），应用启动后 UI 显示 R 4.5.1 横幅，
用户输入 `1+1` → R 返回 `[1] 2` → UI 显示结果。完整 REPL 交互验证通过。

**6 个关键修复**（按发现顺序）：

1. **stub libz.so 是根因**：OHOS SDK 的 libz.so 是 stub（93 个符号全指向 0x2800），不是真 zlib。
   R 无法用 gzfile 读取 .rdx 文件。修复：删除 stub libz.so（`unlink()`），让系统 linker 自动找到
  设备上的真 libz.so。

2. **Rf_mainloop 定时器 segfault**：Rf_mainloop 内部设置 SIGALRM 定时器，~500ms 后 segfault。
   修复：用 `R_ReplDLLinit` + `R_ReplDLLdo1` 循环替代 `Rf_mainloop`。

3. **R 嵌入式回调必须显式设置**：R 4.5.1 用 `ptr_R_*` 函数指针（OBJECT 符号），必须在
   `Rf_initEmbeddedR` **之后**设置（`setup_Rmainloop` 会覆盖）。需设置全部 17 个回调。

4. **exit(2) 拦截**：R 初始化失败时调用 exit(2)，appspawn helper 转为 SIGABRT 杀应用。
   用 `sigsetjmp`/`siglongjmp` + `signal(SIGABRT, handler)` 拦截。

5. **SIGSEGV 拦截**：R 运行时可能 segfault，用 `signal(SIGSEGV, handler)` + `siglongjmp` 优雅退出。

6. **threadsafe function 回调失败 → 改用轮询**：OHOS Node-API 的 `napi_call_function` 在
   threadsafe function 回调中返回错误码 5（`napi_function_expected`），即使 `napi_typeof` 确认
   是函数。这是 OHOS Node-API 的 bug。**修复**：放弃 threadsafe function，改用轮询机制——
   native 侧用 `std::mutex` 保护输出缓冲区 `g_outBuf`，ArkTS 侧用 `setInterval` 每 100ms
   调 `pollOutput()` 取走并清空缓冲区。简单可靠。

**当前架构**：
- `rhost.cpp`：主进程内线程运行 R（dup2 重定向 stdio → dlopen libR → Rf_initEmbeddedR →
  R_ReplDLLdo1 循环）。泵线程读 R stdout → 追加到 `g_outBuf`。`pollOutput()` napi 函数取走缓冲区。
- `Index.ets`：ArkUI 终端页，`setInterval` 每 100ms 调 `pollOutput()` 追加到 `@State output`。
- `libentry.so.d.ts`：native 模块类型声明（`pollOutput: () => string` 等）。

## 5. 战斗记录（问题 → 解法，全部已固化进脚本）

| # | 问题 | 解法（所在文件） |
|---|------|------------------|
| 1 | 无 sudo 装不了 gfortran/f2c | f2c 用 `apt-get download + dpkg -x`（build/00-host-r.sh）；host/target Fortran 全走 f2c 包装 |
| 2 | f2c ABI：integer 必须 4 字节、隐藏长度 8 字节 | **规范头 `build/f2c.h`**（integer=int, ftnlen=long），所有 f2c 构建统一复制它 |
| 3 | R 的 configure 内嵌 libtool 在 FC 测试时把 `CC` 设成 `$FC` → 无限递归烧 CPU | 包装器改用 **`F77_CC`** 变量指定真实 C 编译器（build/f77） |
| 4 | OpenBLAS `zdotu_/zdotc_` 按寄存器返回复数，与 f2c 约定冲突 | `build/zdot_compat.c` 提供 f2c 约定四函数，打进 `libf2cblas.a` |
| 5 | R 4.5 自带 BLAS/LAPACK 是 f90 源码，f2c 拒收 | 外部 OpenBLAS（NOFORTRAN=1）+ CLAPACK；`f90fix.py` 打补丁 |
| 6 | R 4.5 硬性要求 libcurl 且必须支持 https | host/target 都自编 openssl+curl |
| 7 | GNU config.sub 不识别 `*-linux-ohos` | autotools 的 `--host` 一律用 `*-linux-musl`；真实目标由 clang `--target` 决定 |
| 8 | github 下载不稳/截断 | `fetch_multi`：多镜像回退 + 完整性校验 + 停滞检测 |
| 9 | unzip 恢复的 mtime 同秒导致 make 重跑 | 生成后 `touch -d '2000-01-01'` 压源文件时间戳（20-f2c.sh） |
| 10 | CLAPACK 顶层 `lapacklib` 依赖 `lapack_install`（要运行原生自测） | 绕过：直接 `(cd SRC && make)` 出 `lapack_LINUX.a` |
| 11 | `dsvdc.f、dtrsl.f` 的 SELECT CASE（f2c 不支持） | 恢复成 computed GOTO 原版（f90fix.py） |
| 12 | CLAPACK 的 LAPACK 源码引用 `f2c_dswap` 等 f2c 前缀的 BLAS 函数名，OpenBLAS 提供标准名 `dswap_` | **`llvm-objcopy --redefine-sym`**：在 `libclapack.a` 中把 130 个 `f2c_X` 重命名为 `X_`（10-deps.sh） |
| 13 | 桥接库方案（`as --64` + `.globl` + `.set`）创建的库符号表为空 | 改用 `llvm-objcopy --redefine-sym` 直接在 `libclapack.a` 中重命名符号（10-deps.sh） |
| 14 | `DEPS_PREFIX` 不区分架构，导致 aarch64 的 CLAPACK 被 x86_64 链接 | 改为 `$OUT_DIR/deps-$OHOS_ARCH`（env.sh） |
| 15 | `untar()` 复用旧目录导致 CLAPACK 的 aarch64 对象文件被保留 | 删除旧源码目录后重建（10-deps.sh） |
| 16 | `10-deps.sh` 中 `nm` 应改为 `$NM`（系统 nm 无法读取 OHOS 对象文件格式） | 改为 `$NM`（10-deps.sh） |
| 17 | `make` 重新生成 `bin/R` 覆盖 host R 转发脚本 | 两阶段 make + `touch src/scripts/R` 阻止重生成（30-build-r.sh） |
| 18 | `makebasedb.R` 的 lazy-loading 检查（`file.info(baseFileBase)["size"] < 20000`） | `patch-makebasedb.py` 将条件改为 `if (FALSE)` |
| 19 | `make` 的 `all` 目标包含 `docs` 依赖（需 `help2man` 运行目标 Rscript） | `patch-makefile.py` 修改 **`Makefile.in`**（源模板）从 `all:` 移除 `docs`，将 `docs` 目标改为空操作 |
| 20 | `make install` 的 `doc/Makefile` 中 `install-man` 依赖 `R.1`/`Rscript.1`（需 `help2man`） | `patch-makefile.py` 修改 **`doc/Makefile.in`** 从 `install:` 移除 `install-man` |
| 21 | `patch-makefile.py` 修改 `Makefile` 后被 `config.status` 重新生成覆盖 | **改为修改 `Makefile.in`（源模板）**，即使重新生成 `Makefile` 也保留修改 |
| 22 | f2c 符号表溢出（`dlapack.f` 太大，默认 400） | f77 包装器加 `-Nx2000`（build/f77） |
| 23 | libf2c 缺 `-fPIC`（R 模块是共享库，链接静态库需 PIC 代码） | libf2c 构建加 `-fPIC`（00-host-r.sh / 20-f2c.sh） |
| 24 | `r_cv_zdotu_is_usable` 交叉编译时默认 `no`，导致 BLAS_LIBS 被清空 | `config.site.ohos` 设 `r_cv_zdotu_is_usable=yes` |
| 25 | `SIZE_MAX` 未声明 | `config.site.ohos` 设 `ac_cv_have_decl_SIZE_MAX=yes` |
| 26 | CPPFLAGS vs CFLAGS：`.c.d` 依赖文件生成规则用 `ALL_CPPFLAGS` | 单独传 `CPPFLAGS="-I$DEPS_PREFIX/include"` 给 configure |
| 27 | hvigor 报 "Path not found" 但路径确实存在 | **路径中 `.zcode` 导致 hvigor worker 无法识别**；将项目复制到 `C:\r-on-ohos-hap` 后构建成功 |
| 28 | `napi_get_value_string_utf8` 第 3 参数 `const char*` 不可用 | 用 `&out[0]` 替代 `out.data()`（C++17 const 语义差异） |
| 29 | ArkTS 严格模式禁止 `ESObject`/`any` | 移除 `as ESObject` 强转，直接用 `ctx.bundleCodeDir` |
| 30 | HAP 工程缺 `$media:app_icon` / `$media:icon` | 用 Node.js 生成最小 PNG 图标放入 media 目录 |
| 31 | OHOS SDK 的 libz.so 是 stub（93 符号全指向 0x2800），R 无法 gzfile 读 .rdx | 删除 stub libz.so，让系统 linker 找设备上的真 libz.so（rhost.cpp `unlink()`） |
| 32 | Rf_mainloop 内部设 SIGALRM 定时器，~500ms 后 segfault | 用 `R_ReplDLLinit` + `R_ReplDLLdo1` 循环替代 `Rf_mainloop`（rhost.cpp） |
| 33 | R 4.5.1 `ptr_R_*` 回调是 OBJECT 符号，`setup_Rmainloop` 会覆盖 | 在 `Rf_initEmbeddedR` **之后**设置全部 17 个回调（rhost.cpp） |
| 34 | R 初始化失败调 `exit(2)` → appspawn helper 转 SIGABRT 杀应用 | `sigsetjmp`/`siglongjmp` + `signal(SIGABRT, handler)` 拦截（rhost.cpp） |
| 35 | R 运行时 segfault | `signal(SIGSEGV, handler)` + `siglongjmp` 优雅退出 R 线程（rhost.cpp） |
| 36 | OHOS Node-API `napi_call_function` 在 threadsafe function 回调中返回错误 5（`napi_function_expected`），即使 `napi_typeof` 确认是函数 | **放弃 threadsafe function，改用轮询**：native 侧 mutex 保护 `g_outBuf`，ArkTS 侧 `setInterval` 每 100ms 调 `pollOutput()`（rhost.cpp + Index.ets） |

## 6. 待办（按序）

1. ~~模拟器验证~~：**已通过 ✓**（2026-09-27，UI REPL 交互验证完成）
2. **`OHOS_ARCH=aarch64` 重跑三条链出真机包**（源码/补丁全复用）
3. **修复 tools.so/lapack.so 加载**（扩展包功能，当前仅 base 包可用）
4. **收尾**：git init + 首次提交

## 7. 产物与文件速查

```
WSL ~/r-on-ohos/build/out/
  deps-x86_64/   x86_64 交叉依赖（libclapack.a 符号已重命名、libopenblas.a、libf2c.a、libf2cblas.a）
  deps/           旧的 aarch64 依赖库（保留给后续 aarch64 构建）
  host-deps/      host 同款 + host 工具（f2c 在 out/host-tools/bin/f2c）
  host-r/         host R（链 B 产物，构建期用）
  r-ohos-x86_64/  目标 R 安装树（链 C 产物，已 strip 精简）
  rhome-x86_64.tar  可部署包（33M，链 C 产物）
  src/            各源码树
Windows r-on-ohos/
  build/          全部脚本（真身）；f2c.h, f90fix.py, patch-makebasedb.py, patch-makefile.py
  hap/            DevEco 工程（ArkUI 终端页 + cpp/rhost.cpp 原生桥）
  hap/entry/libs/x86_64/    librbin.so + libR.so（已 strip）
  hap/entry/src/main/resources/rawfile/rhome.tar  打包好的 R 安装树
  docs/           01 路线 / 02 环境 / 03 交叉编译调试手册 / 04 HAP 封装 / 05 问题与路线图
```

## 8. 关键脚本说明

| 脚本 | 作用 |
|------|------|
| `env.sh` | 环境变量定义。`DEPS_PREFIX=$OUT_DIR/deps-$OHOS_ARCH`（架构隔离），`R_PREFIX=$OUT_DIR/r-ohos-$OHOS_ARCH` |
| `f77` | f2c 包装脚本。加 `-Nx2000` 解决符号表溢出；用 `F77_CC` 指定真实 C 编译器避免递归 |
| `f90fix.py` | f2c 兼容补丁：dqrdc2.f 裸DO、cmplx.f、dlapack.f、dsvdc.f/dtrsl.f SELECT CASE→GOTO、hclust.f/ppr.f 局部可调数组、portsrc.f SELECT CASE→IF-THEN-ELSE |
| `patch-makebasedb.py` | 修补 `makebasedb.R` 的 lazy-loading 检查（`if (FALSE)`） |
| `patch-makefile.py` | 修改 `Makefile.in` + `doc/Makefile.in`：从 `all:` 移除 `docs`，从 `install:` 移除 `install-man` |
| `config.site.ohos` | 交叉编译缓存变量（r_cv_zdotu_is_usable=yes, ac_cv_have_decl_SIZE_MAX=yes 等） |
| `10-deps.sh` | 交叉依赖构建。CLAPACK 符号重命名用 `$NM` + `llvm-objcopy --redefine-sym` |
| `30-build-r.sh` | 目标 R 构建。两阶段 make + `touch src/scripts/R` + patch-makebasedb.py + patch-makefile.py |

## 9. 给接手 agent 的一句话启动指令

> 读 `C:\Users\chengzhenyang\.zcode\workspace\default\r-on-ohos\HANDOFF.md`，
> 链 A/B/C 均已完成，`rhome-x86_64.tar` 已产出（33M）。
> 下一步：启动模拟器（`C:\Users\chengzhenyang\Desktop\6.0qemu\run.bat`），
> 用 hdc（`D:\Softs\Deveco\20\toolchains\hdc.exe`）推送 tar 包并验证 R 运行。
