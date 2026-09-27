# 04 · HAP 应用封装指南

`hap/` 是一个标准 DevEco Studio（stage 模型）工程：ArkUI 终端页 + NDK 原生桥。

## 首次打开

1. DevEco Studio → Open Project → 选 `hap/`
2. 若提示 SDK 版本不匹配：改 `hap/build-profile.json5` 的 `compatibleSdkVersion`
   为你本机 SDK 对应值（DevEco 会给出候选）；hvigor 版本提示同理一键修复
3. 补两个占位图标（模板图标即可，否则编译报错）：
   - `hap/AppScope/resources/base/media/app_icon.png`
   - `hap/entry/src/main/resources/base/media/icon.png`
4. File → Sync；Build 应产出 `libentry.so`（来自 `entry/src/main/cpp`）

## 打包 R 运行时进 HAP

交叉编译完成后（build/out/rhome-aarch64.tar 存在）：

```bash
cd build && ./40-pack.sh   # 已包含：拷 tar 进 rawfile、拷 librbin.so/libR.so 进 libs
```

- `entry/src/main/resources/rawfile/rhome.tar` ← R 安装树（约 60–150 MB）
- `entry/libs/arm64-v8a/librbin.so` ← R 可执行体改名（备选执行路径）
- `entry/libs/arm64-v8a/libR.so` ← 同上备用

## 应用内启动流程（已实现，见 ets/pages/Index.ets）

1. 首启：`resourceManager.getRawFileContent("rhome.tar")` 写到应用沙箱，native `UnpackTar` 解压
2. `StartR(沙箱/librbin.so 或 rhome/bin/exec/R, R_HOME=沙箱/R, ...)`：
   native fork + dup2 + execv，环境变量设 `R_HOME/R_LIBS_USER/HOME/R_USER/LD_LIBRARY_PATH`
3. 输入框回车 → `WriteR(行)`；R 输出经线程安全函数回推到页面文本区

## 真机运行（鸿蒙 PC）

- DevEco 直连：设备用 `hdc tconn <ip>:5555` 连上后，IDE Run/Debug 正常出包安装
- 手动安装：`hdc install entry-default-signed.hap`
- 日志过滤：`hdc shell hilog | grep RHost`

## 沙箱执行能力验证（关键！）

形态 B 依赖「应用沙箱内 exec/dlopen」。先在真机验证：

```bash
hdc file send build/out/rhome-aarch64.tar /data/local/tmp/
hdc shell "cd /data/local/tmp && tar xf rhome-aarch64.tar && \
  R_HOME=/data/local/tmp/R LD_LIBRARY_PATH=/data/local/tmp/R/lib /data/local/tmp/R/bin/exec/R --version"
```

若 `/data/local/tmp` 可跑而沙箱不可跑（报 Permission denied / ENOEXEC），
切到 docs/05 的「方案 B」（R 与 libR.so 全部走 nativeLibraryDir）。
