# patches/ 说明

首轮移植策略：**能用 configure 缓存解决的绝不改源码**（config.site.ohos），
确需改源码的先在 `30-build-r.sh` 里以 sed/追加文件方式打，收敛后固化为本目录的
编号补丁（`git diff > 0001-xxx.patch` + series 文件），保持可重放。

## 已预判、大概率要动源码的点

| # | 问题 | 修法 |
|---|------|------|
| 1 | `config.guess/config.sub` 不识别 `*-linux-ohos` | 30-build-r.sh 用 savannah 最新版覆盖（已内置） |
| 2 | configure 运行型探测 | config.site.ohos 缓存（已内置种子，首轮补齐） |
| 3 | 无 Fortran | build/f77 f2c 包装（已内置） |
| 4 | musl 缺少 glibc 专有头/符号（如 `execinfo.h`、`error.h`） | 补小型兼容源文件或 `#define` 替代，加入 src/unix |
| 5 | 设备无 `/usr/share/zoneinfo` | configure 加 `--with-internal-tzcode`（已内置） |
| 6 | `bin/R` 构建期脚本指向无法运行的目标 R | 30-build-r.sh 用 host R 包装（已内置） |
| 7 | Rscript shebang 绝对路径 | 40-pack.sh 阶段不打包 shebang 脚本，直接用 exec/R |
| 8 | readline/ncurses 交叉探测 | 10-deps.sh 静态编译 + config.site 缓存 |

## 收敛后的交付要求（GPL 合规）

R 是 GPL-2/3 软件。分发 HAP/tar 时必须随包提供（或指明获取途径）：
R 官方源码 + 本目录全部补丁。发布时在本目录维护 series 与修改说明。
