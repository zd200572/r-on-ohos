# R 包移植到 Harmonybrew/OHOS 路线图

> 2026-10-03 分析 | R 4.5.1 已成功移植 | ci-runner 已验证 21 包可编译

## 现状基线

| 基础 | 状态 |
|------|------|
| R 4.5.1 formula | ✅ 已提交 PR |
| base + recommended 包（30 个） | ✅ 随 R 安装 |
| Harmonybrew 系统库 | ✅ 4761 formula，关键库全齐 |
| ci-runner tidyverse 验证 | ✅ 21 包编译成功（pthread stub 修复） |
| 已知 OHOS 坑 | pthread_cancel 缺符号、SDK stub libz.so |
| **Java (openjdk 26)** | ✅ bottle 秒装，R+rJava+JVM 端到端验证通过 |

## 难度分级标准

| 级别 | 含义 | 工作量 |
|------|------|--------|
| ★☆☆☆☆ | 纯 R，零编译 | 几乎为零，install.packages 即可 |
| ★★☆☆☆ | C/C++ 但无外部库，依赖链短 | 写 formula + bottle，1-2h |
| ★★★☆☆ | C/C++ + 外部系统库 | 确认库就位 + formula，半天 |
| ★★★★☆ | 重度 C++/Fortran 或大依赖链 | 逐包排错，1-2 天 |
| ★★★★★ | 需深度适配 OHOS 特性 | 需 patch 源码，不确定 |

---

## 第一梯队：已验证可编译（直接出 formula）

ci-runner 已成功编译这 21 个包，只需固化成 formula + bottle。

| 包 | 语言 | 依赖 | 难度 | 备注 |
|----|------|------|------|------|
| **Rcpp** | C++ | 无 | ★★☆☆☆ | 万物之基，必须先有 |
| **rlang** | C | 无 | ★★☆☆☆ | tidyverse 底座 |
| **vctrs** | C | rlang, Rcpp | ★★☆☆☆ | 向量语义核心 |
| **glue** | 纯 R | 无 | ★☆☆☆☆ | 字符串插值 |
| **cli** | C | 无 | ★★☆☆☆ | 终端输出，**曾触发 pthread stub** |
| **lifecycle** | 纯 R | rlang, glue | ★☆☆☆☆ | |
| **tibble** | C++ | Rcpp, vctrs, rlang | ★★☆☆☆ | |
| **tidyr** | C++ | Rcpp, vctrs, dplyr | ★★☆☆☆ | |
| **dplyr** | C++ | Rcpp, vctrs, rlang | ★★☆☆☆ | 数据操作核心 |
| **ggplot2** | C++ | Rcpp, vctrs, scales | ★★☆☆☆ | 绘图核心 |
| **stringr** | C | stringi | ★★★☆☆ | 依赖 stringi（ICU） |
| **purrr** | 纯 R | rlang | ★☆☆☆☆ | 函数式编程 |
| **readr** | C++ | Rcpp, vctrs | ★★☆☆☆ | 读 CSV/TSV |
| **forcats** | 纯 R | rlang | ★☆☆☆☆ | 因子操作 |
| **broom** | 纯 R | dplyr, tidyr | ★☆☆☆☆ | 模型结果整理 |
| **dbplyr** | 纯 R | dplyr, DBI | ★★☆☆☆ | SQL 后端 |
| **haven** | C++ | Rcpp + 外部库 | ★★★★☆ | 读 SAS/SPSS/Stata |
| **jsonlite** | C | 无 | ★★☆☆☆ | JSON 解析 |
| **lubridate** | 纯 R | stringr | ★☆☆☆☆ | 日期时间 |
| **modelr** | 纯 R | dplyr, tidyr | ★☆☆☆☆ | 建模辅助 |
| **pillar** | C++ | Rcpp, vctrs, cli | ★★☆☆☆ | 表格输出 |

**建议**：这 21 个直接批量出 formula，Rcpp → rlang/vctrs → 其余，按依赖拓扑排序。

---

## 第二梯队：高频使用，需验证

### 数据操作

| 包 | 语言 | 依赖 | 难度 | 关键难点 |
|----|------|------|------|----------|
| **data.table** | C | 无 | ★★☆☆☆ | 自带 C 实现，无 Rcpp 依赖，性能标杆 |
| **stringi** | C++ | ICU (icu4c) | ★★★☆☆ | 依赖 icu4c，Harmonybrew 有 |
| **readxl** | C++ | Rcpp, libxls/expat | ★★★☆☆ | 读 Excel，自带 libxls |
| **fst** | C++ | Rcpp, ZSTD | ★★★☆☆ | 高速序列化，zstd 已有 |
| **arrow** | C++ | Apache Arrow | ★★★★☆ | 巨大 C++ 工程，编译耗时长 |
| **duckdb** | C++ | 无 | ★★★★☆ | 嵌入式 OLAP，大量 C++ |

### 网络/IO

| 包 | 语言 | 依赖 | 难度 | 关键难点 |
|----|------|------|------|----------|
| **curl** | C | libcurl | ★★★☆☆ | Harmonybrew 有 curl，需链接配置 |
| **httr** | C | curl, openssl | ★★★☆☆ | **ci-runner 曾失败**（askpass 编译问题） |
| **httr2** | 纯 R | curl, openssl | ★★☆☆☆ | httr 的纯 R 重写版 |
| **xml2** | C | libxml2 | ★★★☆☆ | Harmonybrew 有 libxml2 |
| **rvest** | 纯 R | xml2, httr | ★★★☆☆ | 爬虫，依赖链到 httr |
| **openssl** | C | openssl 系统库 | ★★★☆☆ | 需确认 OHOS openssl 可用 |
| **askpass** | C | 无 | ★★☆☆☆ | **ci-runner 编译失败**，需排查 |
| **zip** | C | 无 | ★★☆☆☆ | ZIP 文件操作 |

### 统计/建模

| 包 | 语言 | 依赖 | 难度 | 关键难点 |
|----|------|------|------|----------|
| **lme4** | C++/Fortran | Rcpp, Eigen | ★★★★☆ | 混合效应模型，Eigen + RcppEigen |
| **glmnet** | Fortran | 无 | ★★★☆☆ | Fortran 编译，gfortran 已有 |
| **survival** | C/Fortran | 无 | ★☆☆☆☆ | **recommended，已随 R 安装** |
| **MASS** | C/Fortran | 无 | ★☆☆☆☆ | **recommended，已安装** |
| **Matrix** | C/Fortran | 无 | ★☆☆☆☆ | **recommended，已安装** |
| **caret** | 纯 R | 多包 | ★☆☆☆☆ | 机器学习框架，纯 R |
| **randomForest** | C/Fortran | 无 | ★★☆☆☆ | 经典随机森林 |
| **ranger** | C++ | Rcpp, RcppEigen | ★★★☆☆ | 快速随机森林 |
| **xgboost** | C++ | Rcpp | ★★★★☆ | 大量 C++，需 CMake |
| **lightgbm** | C++ | Rcpp | ★★★★☆ | 类似 xgboost |
| **stan/rstan** | C++ | Rcpp, Stan 库 | ★★★★★ | 贝叶斯，极复杂 C++ |
| **brms** | 纯 R | rstan | ★★★★★ | 依赖 rstan |

### 机器学习

| 包 | 语言 | 依赖 | 难度 | 关键难点 |
|----|------|------|------|----------|
| **e1071** | C/Fortran | 无 | ★★☆☆☆ | SVM，经典 |
| **class** | C | 无 | ★☆☆☆☆ | **recommended，已安装** |
| **cluster** | C/Fortran | 无 | ★☆☆☆☆ | **recommended，已安装** |
| **kernlab** | C | 无 | ★★☆☆☆ | 核方法 |
| **nnet** | C | 无 | ★☆☆☆☆ | **recommended，已安装** |
| **torch** | C++ | LibTorch | ★★★★★ | PyTorch C++ 后端，极难 |

### 可视化

| 包 | 语言 | 依赖 | 难度 | 关键难点 |
|----|------|------|------|----------|
| **scales** | 纯 R | 无 | ★☆☆☆☆ | 图表标度 |
| **patchwork** | 纯 R | ggplot2 | ★☆☆☆☆ | 拼图 |
| **ggrepel** | C++ | Rcpp, ggplot2 | ★★☆☆☆ | 标签避让 |
| **ggridges** | 纯 R | ggplot2 | ★☆☆☆☆ | 山脊图 |
| **ggpubr** | 纯 R | ggplot2 | ★☆☆☆☆ | 出版级图表 |
| **plotly** | 纯 R | htmlwidgets | ★★☆☆☆ | 交互图，依赖 htmlwidgets |
| **leaflet** | 纯 R | htmlwidgets | ★★☆☆☆ | 地图，依赖 htmlwidgets |
| **viridis** | 纯 R | 无 | ★☆☆☆☆ | 配色 |
| **RColorBrewer** | 纯 R | 无 | ★☆☆☆☆ | 配色 |
| **lattice** | C | 无 | ★☆☆☆☆ | **recommended，已安装** |
| **gridExtra** | 纯 R | 无 | ★☆☆☆☆ | 网格布局 |

### 空间/地理

| 包 | 语言 | 依赖 | 难度 | 关键难点 |
|----|------|------|------|----------|
| **sf** | C++ | GDAL, GEOS, PROJ | ★★★★☆ | 空间数据，3 个大库 |
| **terra** | C++ | GDAL, PROJ | ★★★★☆ | 栅格数据 |
| **sp** | C++ | 无 | ★★★☆☆ | 旧空间框架 |
| **rgdal** | C/Fortran | GDAL, PROJ | ★★★★☆ | 已被 sf/terra 取代 |

### 时间序列

| 包 | 语言 | 依赖 | 难度 | 关键难点 |
|----|------|------|------|----------|
| **forecast** | C/Fortran | tseries, fracdiff | ★★★☆☆ | 时间序列预测 |
| **fable** | 纯 R | fabletools | ★★☆☆☆ | forecast 的 tidy 替代 |
| **zoo** | C | 无 | ★★☆☆☆ | 不规则时间序列 |
| **xts** | C | zoo | ★★☆☆☆ | 扩展时间序列 |
| **quantmod** | 纯 R | TTR, xts | ★★☆☆☆ | 金融量化 |

### 文本/NLP

| 包 | 语言 | 依赖 | 难度 | 关键难点 |
|----|------|------|------|----------|
| **tokenizers** | C++ | Rcpp | ★★☆☆☆ | 分词 |
| **tidytext** | 纯 R | dplyr, stringr | ★☆☆☆☆ | tidy 文本 |
| **textshaping** | C++ | fribidi, harfbuzz | ★★★☆☆ | 文本整形 |
| **stringr** | C | stringi | ★★★☆☆ | 已在第一梯队 |

### 并行/性能

| 包 | 语言 | 依赖 | 难度 | 关键难点 |
|----|------|------|------|----------|
| **RcppParallel** | C++ | TBB | ★★★★☆ | **TBB 可能不兼容 OHOS musl** |
| **future** | 纯 R | 无 | ★☆☆☆☆ | 异步框架 |
| **foreach** | 纯 R | 无 | ★☆☆☆☆ | 并行循环 |
| **parallel** | C | 无 | ★☆☆☆☆ | **base，已安装** |
| **RcppArmadillo** | C++ | Rcpp, Armadillo | ★★★☆☆ | 线性代数 |
| **RcppEigen** | C++ | Rcpp, Eigen | ★★★☆☆ | 线性代数 |

---

## 第三梯队：生信（Bioconductor）

生信包依赖链深、C 代码多，但用户群体明确。

| 包 | 语言 | 依赖 | 难度 | 备注 |
|----|------|------|------|------|
| **BiocManager** | 纯 R | 无 | ★☆☆☆☆ | Bioconductor 入口 |
| **limma** | 纯 R | 无 | ★☆☆☆☆ | 差异表达，纯 R |
| **DESeq2** | C++ | Rcpp, S4Vectors | ★★★★☆ | 差异表达核心 |
| **edgeR** | C | 无 | ★★★☆☆ | 差异表达 |
| **Biostrings** | C | 无 | ★★★☆☆ | 序列操作 |
| **GenomicRanges** | C | 无 | ★★★☆☆ | 基因组区间 |
| **SummarizedExperiment** | 纯 R | GenomicRanges | ★★☆☆☆ | 数据容器 |
| **SingleCellExperiment** | 纯 R | SummarizedExperiment | ★★☆☆☆ | 单细胞 |
| **Seurat** | C++ | Rcpp, 众多 | ★★★★☆ | 单细胞分析旗舰 |
| **ComplexHeatmap** | 纯 R | 无 | ★☆☆☆☆ | 热图绘制 |
| **clusterProfiler** | 纯 R | 多包 | ★★☆☆☆ | 富集分析 |

---

## 已知坑与风险

### 1. pthread_cancel（已解决）
OHOS musl 不导出 `pthread_cancel`/`pthread_setcanceltype`。需 `libpthread_stub.so` + `LD_PRELOAD`。
**影响**：cli 包及所有依赖它的 tidyverse 包。ci-runner 已验证修复方案。

### 2. SDK stub libz.so（已解决）
OHOS SDK sysroot 的 stub libz.so 导致 gzfile 失败。R formula 已修复（zlib-ng-compat -L）。
**影响**：R 本身。R 包安装时如果链接 zlib 也需注意。

### 3. TBB / RcppParallel（未验证）
Intel TBB 可能不兼容 OHOS musl。data.table、dplyr 等可能用 RcppParallel。
**风险**：★★★★☆，需验证或改用单线程后端。

### 4. Fortran 编译（低风险）
gfortran 已在 R formula 中配置（`FC=gfortran`）。但 OHOS 的 Fortran 运行时库需确认。
**影响**：glmnet, randomForest, lme4 等。

### 5. Java（✅ 可用，已验证 2026-10-03）
Harmonybrew 有 openjdk 26 的 arm64_ohos bottle，`brew install openjdk` 秒装。
R 不需重新编译——`R CMD javareconf` 即可配置 Java。rJava 编译安装成功，`.jinit()` 启动 JVM 正常，
R 可调用 Java 对象和方法（`Math.sqrt(144)=12` 验证通过）。
**解锁**：rJava, xlsx, XLConnect, RJDBC, tabulapdf 等 Java 生态 R 包。

### 6. askpass/ps/ragg 编译失败（✅ 全部已解决 2026-10-03）
- **askpass**：直接编译成功（之前失败已自行修复，仅 getpass 隐式声明 warning）
- **ps**：OHOS SDK `linux/socket.h` 与 `sys/socket.h` 的 `sockaddr_storage` 重定义 → patch SDK 头文件
- **ragg**：缺 libwebp → `brew install webp`（有 arm64_ohos bottle）
- **结果**：httr→rvest→reprex→tidyverse 全链路打通，98 包安装成功，tidyverse 完整可用

---

## 建议优先级

### P0 — 立即可做（已验证）
固化 ci-runner 已成功的 21 包为 formula：
```
Rcpp → rlang, vctrs, glue, cli, lifecycle
     → tibble, pillar, tidyr, dplyr, ggplot2
     → purrr, readr, forcats, stringr(stringi)
     → broom, dbplyr, jsonlite, lubridate, modelr
     → haven
```

### P1 — 高价值低风险
| 包 | 理由 |
|----|------|
| data.table | 性能标杆，用户量大 |
| zoo, xts | 金融时间序列必备 |
| scales, patchwork, ggrepel | ggplot2 生态补全 |
| RcppArmadillo, RcppEigen | 很多建模包的底座 |
| BiocManager | Bioconductor 入口 |
| httr2 | httr 的纯 R 替代，绕过 askpass 问题 |

### P2 — 中等难度高价值
| 包 | 理由 |
|----|------|
| curl, xml2, openssl | 网络/解析基础设施 |
| readxl | Excel 读取，高频需求 |
| ranger, e1071, kernlab | 经典 ML |
| forecast, fable | 时间序列 |
| sf, terra | 空间分析（需验证 GDAL/PROJ 链接） |

### P3 — 高难度按需
| 包 | 理由 |
|----|------|
| arrow, duckdb | 大 C++ 工程，编译耗时长 |
| xgboost, lightgbm | 需 CMake，大量 C++ |
| lme4 | RcppEigen + 复杂依赖 |
| Seurat | 单细胞旗舰，依赖链极深 |
| rstan/brms | Stan C++ 引擎，极复杂 |

### 暂不推荐
| 包 | 理由 |
|----|------|
| torch | LibTorch 移植工作量巨大 |
| RcppParallel | TBB 兼容性未验证 |
| rgdal | 已被 sf/terra 取代 |

### Java 生态（✅ 已解锁）
| 包 | 用途 | 难度 | 备注 |
|----|------|------|------|
| **rJava** | R-Java 桥梁 | ★★☆☆☆ | **已验证**：编译+加载+.jinit() 全通过 |
| **xlsx** | Excel 读写（Java POI） | ★★☆☆☆ | 依赖 rJava |
| **XLConnect** | Excel 操作（Java） | ★★☆☆☆ | 依赖 rJava |
| **RJDBC** | 数据库连接（JDBC） | ★★☆☆☆ | 依赖 rJava |
| **tabulapdf** | PDF 表格提取（Java） | ★★☆☆☆ | 依赖 rJava |
| **groovy** | Java Groovy 桥接 | ★★☆☆☆ | 依赖 rJava |
---

## OpenBLAS 加速（✅ 已完成）

### 突破

OpenBLAS 0.3.29 成功交叉编译到 OHOS (aarch64)，并替换 R 的 reference BLAS，获得 **5-7x 矩阵运算加速**。

### 成果

| 项目 | 详情 |
|------|------|
| OpenBLAS formula | ✅ 已写入 `Formula/o/openblas.rb`，`brew install -s openblas` 成功（37 秒） |
| 共享库 | `libopenblas_armv8-r0.3.29.so`（2.3MB），ELF64 AArch64，1873 导出符号 |
| R BLAS 替换 | ✅ `libRblas.so` → OpenBLAS 符号链接，R sessionInfo 确认 |
| 计算正确性 | ✅ checksum 一致，det/solve/eigen/lm 全正确 |
| R formula 更新 | ✅ `depends_on "openblas"` + `--with-blas` 在 OHOS 上也启用 |

### Benchmark（容器内 aarch64 OHOS）

| 矩阵大小 | 操作 | Reference BLAS | OpenBLAS | 加速比 |
|----------|------|---------------|----------|--------|
| 500×500 | matmul | 0.051s | 0.010s | 5.1x |
| 1000×1000 | matmul | 0.394s | 0.066s | 6.0x |
| 2000×2000 | matmul | 3.525s | 0.533s | 6.6x |
| 3000×3000 | matmul | 12.645s | 1.769s | **7.1x** |
| 3000×3000 | solve | 16.234s | 2.650s | 6.1x |
| 3000×3000 | SVD | 64.016s | 17.000s | 3.8x |

### 编译参数

```bash
make shared NOFORTRAN=1 NO_LAPACK=1 USE_THREAD=0 USE_OPENMP=0 \
     TARGET=ARMV8 BINARY=64 CC=clang AR=llvm-ar RANLIB=llvm-ranlib HOSTCC=gcc
```

- `NOFORTRAN=1`：无需 Fortran 编译器（用 C wrapper）
- `NO_LAPACK=1`：跳过 LAPACK（R 自带 LAPACK），同时跳过 netlib 依赖
- `USE_THREAD=0`：单线程（避免 OHOS pthread 兼容问题）
- `TARGET=ARMV8`：ARM64 汇编优化

### 关键发现

- `make libs` 只生成静态库 (.a)，`make shared` 才生成共享库 (.so)
- `make shared` 依赖 `netlib` target（需要 lapack-netlib 目录），加 `NO_LAPACK=1` 跳过
- OpenBLAS 的 Fortran 接口符号 (`dgemm_`, `sgemm_`) 与 R 的 BLAS 接口完全兼容
- 替换方法：`ln -sf openblas.so libRblas.so`（R 的 libR.so 依赖 libRblas.so）