// R on HarmonyOS —— NativeChildProcess 子进程库
//
// 由父进程 OH_Ability_StartNativeChildProcess("librchild.so:Main", ...) 加载：
//   系统 dlopen("librchild.so") → dlsym("Main") → Main(args) → 返回后子进程退出
//
// 职责：
//   1) 从 args.fdList 提取 rstdin / rstdout 管道 fd，dup2 接管标准 stdio
//   2) 从 args.entryParams 解析 R_HOME / WORKDIR / LIBSDIR / NATIVELIBDIR
//   3) 设置 R 运行环境变量（R_HOME、HOME、TMPDIR 等）
//   4) dlopen libR.so（依赖预加载 + 多路径兜底；musl 运行时 setenv
//      LD_LIBRARY_PATH 对 dlopen 搜索无效，必须绝对路径加载）
//   5) Rf_initEmbeddedR() → Rf_mainloop() 运行 R REPL
//
// 关键事实（R 4.5.1 源码 src/unix/Rembedded.c 已核实）：
//   Rf_initEmbeddedR = Rf_initialize_R + (R_Interactive=TRUE) + setup_Rmainloop
//   —— 显式置交互模式，正好抵消「stdin 为管道非 tty」导致的非交互判定。
//   libR.so 导出：Rf_initialize_R / setup_Rmainloop / Rf_mainloop / Rf_initEmbeddedR
//   libR.so NEEDED：libz.so / libomp.so / libc.so（RUNPATH 指向构建机路径，设备上无效，
//   因此必须按依赖顺序显式预加载 libz/libomp，dlopen libR 时命中已加载列表）

#include "AbilityKit/native_child_process.h"
#include "hilog/log.h"
#include <dlfcn.h>
#include <unistd.h>
#include <string>
#include <vector>
#include <cstring>
#include <cstdlib>
#include <cstdio>

#define LOGI(...) ((void)OH_LOG_Print(LOG_APP, LOG_INFO, 0xC0DE, "RChild", __VA_ARGS__))
#define LOGE(...) ((void)OH_LOG_Print(LOG_APP, LOG_ERROR, 0xC0DE, "RChild", __VA_ARGS__))

// fd 名（与父进程 rhost.cpp 的约定一致）
static const char *FD_STDIN  = "rstdin";
static const char *FD_STDOUT = "rstdout";

// ---------------- fdList 按名查找 ----------------
static int FindFd(const NativeChildProcess_FdList *list, const char *name) {
    if (!list) return -1;
    for (const NativeChildProcess_Fd *fd = list->head; fd; fd = fd->next) {
        if (fd->fdName && strcmp(fd->fdName, name) == 0) return fd->fd;
    }
    return -1;
}

// ---------------- entryParams 解析：key1=val1;key2=val2;... ----------------
// 仅匹配段首（串首或 ';' 之后），避免值中出现 "key=" 误匹配
static std::string GetParam(const char *params, const char *key) {
    if (!params) return "";
    const std::string s(params);
    const std::string prefix = std::string(key) + "=";
    size_t pos = 0;
    while ((pos = s.find(prefix, pos)) != std::string::npos) {
        if (pos == 0 || s[pos - 1] == ';') {
            size_t vStart = pos + prefix.size();
            size_t vEnd = s.find(';', vStart);
            return s.substr(vStart,
                            vEnd == std::string::npos ? std::string::npos : vEnd - vStart);
        }
        pos += prefix.size();
    }
    return "";
}

// ---------------- 多目录兜底 dlopen（绝对路径） ----------------
static void *DlopenFrom(const char *name, const std::vector<std::string> &dirs) {
    for (const auto &d : dirs) {
        std::string p = d + "/" + name;
        void *h = dlopen(p.c_str(), RTLD_NOW | RTLD_GLOBAL);
        if (h) {
            LOGI("dlopen %{public}s 成功", p.c_str());
            return h;
        }
        LOGE("dlopen %{public}s 失败: %{public}s", p.c_str(), dlerror());
    }
    return nullptr;
}

extern "C" __attribute__((visibility("default")))
void Main(NativeChildProcess_Args args) {
    LOGI("R 子进程启动");

    // 1) 接管 stdio（stdout+stderr 合流到同一管道）
    int fdIn  = FindFd(&args.fdList, FD_STDIN);
    int fdOut = FindFd(&args.fdList, FD_STDOUT);
    if (fdIn  >= 0) dup2(fdIn,  STDIN_FILENO);  else LOGE("缺少 %{public}s fd", FD_STDIN);
    if (fdOut >= 0) { dup2(fdOut, STDOUT_FILENO); dup2(fdOut, STDERR_FILENO); }
    else            LOGE("缺少 %{public}s fd", FD_STDOUT);

    // 2) 解析启动参数
    std::string rHome       = GetParam(args.entryParams, "R_HOME");
    std::string workDir     = GetParam(args.entryParams, "WORKDIR");
    std::string libsDir     = GetParam(args.entryParams, "LIBSDIR");
    std::string nativeLibDir = GetParam(args.entryParams, "NATIVELIBDIR");
    LOGI("R_HOME=%{public}s WORKDIR=%{public}s", rHome.c_str(), workDir.c_str());
    LOGI("NATIVELIBDIR=%{public}s LIBSDIR=%{public}s", nativeLibDir.c_str(), libsDir.c_str());
    if (rHome.empty()) {
        LOGE("R_HOME 为空，无法启动");
        fprintf(stderr, "[RChild] R_HOME 为空\n");
        return;
    }

    // 3) 工作目录 + 环境变量（R 初始化时读取）
    if (!workDir.empty()) chdir(workDir.c_str());
    std::string ldPath = rHome + "/lib";
    if (!nativeLibDir.empty()) ldPath += ":" + nativeLibDir;
    setenv("R_HOME",       rHome.c_str(),   1);
    setenv("R_LIBS_USER",  libsDir.c_str(), 1);
    setenv("R_USER",       workDir.c_str(), 1);
    setenv("HOME",         workDir.c_str(), 1);
    setenv("TMPDIR",       workDir.c_str(), 1);   // R 临时目录（Rtmp*）
    setenv("LANG",         "C.UTF-8", 1);
    setenv("LC_ALL",       "C.UTF-8", 1);
    setenv("PATH",         (rHome + "/bin:" + ldPath).c_str(), 1);
    // LD_LIBRARY_PATH 照设：musl 启动后 setenv 对自身 dlopen 搜索无效，
    // 但 R 内部再起的子进程/工具链可能受益
    setenv("LD_LIBRARY_PATH", ldPath.c_str(), 1);

    // 4) 按依赖顺序预加载 libR 的非系统依赖，再加载 libR.so
    //    （dlopen 递归解析依赖时命中「已加载库列表」，绝对路径绕开搜索路径限制）
    std::vector<std::string> dirs;
    if (!nativeLibDir.empty()) dirs.push_back(nativeLibDir);
    dirs.push_back(rHome + "/lib");
    DlopenFrom("libomp.so", dirs);
    DlopenFrom("libz.so",   dirs);
    void *libR = DlopenFrom("libR.so", dirs);
    if (!libR) {
        LOGE("libR.so 全部路径加载失败");
        fprintf(stderr, "[RChild] 无法加载 libR.so\n");
        return;   // Main 返回 → 子进程退出
    }

    // 5) 解析嵌入 API
    using InitR_t = int  (*)(int, char **);
    using Loop_t  = void (*)(void);
    auto Rf_initEmbeddedR = (InitR_t)dlsym(libR, "Rf_initEmbeddedR");
    auto Rf_mainloop      = (Loop_t)dlsym(libR, "Rf_mainloop");
    if (!Rf_initEmbeddedR || !Rf_mainloop) {
        LOGE("dlsym 失败: %{public}s", dlerror());
        fprintf(stderr, "[RChild] 嵌入符号解析失败\n");
        return;
    }

    // 6) 初始化并进入 R REPL（static 存储期：R 初始化会改写/持有 argv）
    static char a0[] = "R";
    static char a1[] = "--no-save", a2[] = "--no-restore";
    static char a3[] = "--slave",   a4[] = "--interactive";
    static char *argv[] = {a0, a1, a2, a3, a4, nullptr};
    if (Rf_initEmbeddedR(5, argv) != 1) {
        LOGE("Rf_initEmbeddedR 失败");
        return;
    }
    LOGI("进入 R 主循环");
    Rf_mainloop();          // stdin EOF 或 q() 时返回
    LOGI("R 主循环退出，子进程结束");
}