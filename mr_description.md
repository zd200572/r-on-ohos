# r: add 4.5.1 formula

## 概述

新增 R 4.5.1 formula，使 `brew install r` 在 OHOS 平台可用。Harmonybrew/homebrew-core 上游原本没有 R formula，本 PR 为纯新增。

## OHOS 平台适配

### 1. zlib stub 修复（关键）

OHOS SDK sysroot (`ohos-sdk-native`) 内有一个 **stub `libz.so`**（约 13KB，SONAME=`libz.so`，`gzopen`/`gzread` 均为 4 字节空函数）。Homebrew superenv 的 clang 默认搜索路径包含该 sysroot，导致 `-lz` 静默解析到 stub，R 构建时 `gzfile()`/`read.dcf()` 失败（报 "No error information"，errno=0），在 `tools` 包 `installing 'sysdata.rda'` 阶段崩溃。

**修复**：在 LDFLAGS/CPPFLAGS 中加入 `zlib-ng-compat` 的 `-L`/`-I`，使链接器优先找到真 zlib（SONAME=`libz.so.1`）。

### 2. mktime 预设

OHOS musl 缺少 tzdata，configure 的 mktime 检测会失败。通过 ENV 预设 `r_cv_working_mktime` 等检测结果绕过。

### 3. LD_LIBRARY_PATH

OHOS 上 R binary 的 RUNPATH 指向 Cellar prefix，`make` 阶段该路径尚不存在。R 需自举运行（如 `make sysdata`），需通过 `LD_LIBRARY_PATH` 指向 buildpath/lib 才能找到 libRblas.so。

### 4. 条件依赖

`openblas` 和 `tcl-tk` 在 OHOS 上不可用，用 `unless OS.ohos?` 条件跳过，OHOS 下用 `--without-tcltk`。

## 测试

```
brew install -s r
```

退出码 0。验证结果：
- Cellar/r/4.5.1：1908 files，87MB
- `Rscript -e 'print(1+1)'` → `[1] 2`
- `gzfile()` 读写 gzip 正常
- `read.dcf()` 正常
- `libR.so` NEEDED=`libz.so.1`（真 zlib，非 stub）

## 文件

- `Formula/r/r.rb`（180 行，新增）