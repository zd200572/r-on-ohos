// R on HarmonyOS —— NDK 原生桥（napi）
// 职责：
//   1) UnpackTar: 把 rawfile 打包的 R 运行时(ustar)解包到应用沙箱
//   2) StartR:    在主进程内起一个线程运行 R 嵌入引擎：
//                 dlopen libR.so → Rf_initEmbeddedR → Rf_mainloop，
//                 用 dup2 重定向 stdin/stdout 到管道，与 ArkTS 层通信。
//                 不需要 NativeChildProcess / fork / 签名——主进程内线程方案。
//   3) WriteR / InterruptR / StopR: REPL 输入与控制
// fd 约定：
//   inPipe[1]  = 父进程写端 → R 的 stdin（dup2 到 STDIN）
//   outPipe[0] = 父进程读端 ← R 的 stdout/stderr（dup2 到 STDOUT/STDERR）
// 说明：dup2 是进程级操作，但 HarmonyOS 应用 UI 不使用 stdin/stdout（用 ArkUI），
//       所以重定向不影响 UI 线程。R 崩溃会带崩整个应用，对开发工具可接受。
#include "napi/native_api.h"
#include "hilog/log.h"
#include <atomic>
#include <string>
#include <vector>
#include <pthread.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/stat.h>
#include <dlfcn.h>
#include <dirent.h>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <csetjmp>
#include <mutex>

// ---------------- exit() 拦截 ----------------
// R 初始化失败时会调用 exit(2)，在 HarmonyOS 中 exit() 被 appspawn helper 拦截
// 转为 SIGABRT 杀死整个应用。我们用 SIGABRT 信号处理器 + longjmp 捕获，
// 让 R 线程优雅退出而不崩溃整个应用。
static sigjmp_buf g_rExitJmp;
static std::atomic<bool> g_rExitJmpReady{false};
static std::atomic<int> g_rExitCode{0};

static void RAbortHandler(int sig) {
    if (g_rExitJmpReady.load()) {
        g_rExitCode.store(sig == SIGABRT ? 2 : 11);  // SIGABRT→exit(2), SIGSEGV→11
        siglongjmp(g_rExitJmp, sig == SIGABRT ? 2 : 11);
    }
    // 不在 R 初始化上下文，恢复默认处理
    signal(sig, SIG_DFL);
    raise(sig);
}

#define LOGI(...) ((void)OH_LOG_Print(LOG_APP, LOG_INFO, 0xC0DE, "RHost", __VA_ARGS__))
#define LOGE(...) ((void)OH_LOG_Print(LOG_APP, LOG_ERROR, 0xC0DE, "RHost", __VA_ARGS__))

static std::atomic<pid_t> g_pid{-1};
static int g_stdin_w = -1;   // → R 的 stdin
static int g_stdout_r = -1;  // ← R 的 stdout/stderr
static std::atomic<bool> g_rRunning{false};

// ---------------- 轮询输出缓冲区 ----------------
// 泵线程把 R 输出追加到 g_outBuf，ArkTS 侧定期调 pollOutput() 取走并清空
static std::mutex g_outMtx;
static std::string g_outBuf;

// ---------------- 工具 ----------------
static bool GetStr(napi_env env, napi_value v, std::string &out) {
    size_t len = 0;
    if (napi_get_value_string_utf8(env, v, nullptr, 0, &len) != napi_ok) return false;
    out.resize(len + 1);
    bool ok = napi_get_value_string_utf8(env, v, &out[0], len + 1, &len) == napi_ok;
    out.resize(len);
    return ok;
}

static void MakedirP(const std::string &path) {
    for (size_t i = 1; i <= path.size(); ++i) {
        if (i == path.size() || path[i] == '/') {
            mkdir(path.substr(0, i).c_str(), 0755);
        }
    }
}

static std::string DirName(const std::string &p) {
    size_t i = p.find_last_of('/');
    return i == std::string::npos ? std::string(".") : p.substr(0, i);
}

// 通过 /proc/self/maps 定位本模块(libentry.so)所在目录 —— 即 nativeLibraryDir
static std::string GetNativeLibDir() {
    FILE *fp = fopen("/proc/self/maps", "r");
    if (!fp) return "";
    char line[2048];
    std::string dir;
    while (fgets(line, sizeof(line), fp)) {
        if (strstr(line, "libentry.so")) {
            char *p = strchr(line, '/');
            if (p) {
                std::string path(p);
                size_t nl = path.find_first_of("\r\n");
                if (nl != std::string::npos) path.resize(nl);
                dir = DirName(path);
                break;
            }
        }
    }
    fclose(fp);
    return dir;
}

// ---------------- ustar 解包（由 40-pack.sh 以 --format=ustar 生成） ----------------
static bool UnpackTarImpl(const std::string &tarPath, const std::string &dest) {
    FILE *fp = fopen(tarPath.c_str(), "rb");
    if (!fp) {
        LOGE("UnpackTar: 打不开 %{public}s", tarPath.c_str());
        return false;
    }
    char hdr[512];
    std::string pendingLongName;
    bool ok = true;
    while (true) {
        size_t n = fread(hdr, 1, 512, fp);
        if (n == 0) break;
        if (n < 512) { ok = false; break; }
        bool allZero = true;
        for (int i = 0; i < 512; ++i) { if (hdr[i]) { allZero = false; break; } }
        if (allZero) continue;

        char name[101], prefix[156], sizeStr[13], modeStr[9];
        memcpy(name, hdr, 100);        name[100] = 0;
        memcpy(prefix, hdr + 345, 155); prefix[155] = 0;
        memcpy(sizeStr, hdr + 124, 12); sizeStr[12] = 0;
        memcpy(modeStr, hdr + 100, 8);  modeStr[8] = 0;
        char type = hdr[156];
        long size = strtol(sizeStr, nullptr, 8);
        mode_t mode = static_cast<mode_t>(strtol(modeStr, nullptr, 8));

        std::string rel = name[0] ? name : "?";
        if (prefix[0]) rel = std::string(prefix) + "/" + rel;

        if (type == 'L') {  // GNU 超长文件名
            std::vector<char> buf(size + 1, 0);
            if (fread(buf.data(), 1, size, fp) != (size_t)size) { ok = false; break; }
            pendingLongName.assign(buf.data());
        } else {
            std::string relName = pendingLongName.empty() ? rel : pendingLongName;
            pendingLongName.clear();
            std::string full = dest + "/" + relName;
            if (type == '5') {
                MakedirP(full);
            } else if (type == '0' || type == '\0') {
                MakedirP(DirName(full));
                FILE *out = fopen(full.c_str(), "wb");
                if (!out) { LOGE("写文件失败: %{public}s", full.c_str()); ok = false; break; }
                std::vector<char> buf(64 * 1024);
                long left = size;
                while (left > 0) {
                    size_t want = left > (long)buf.size() ? buf.size() : (size_t)left;
                    if (fread(buf.data(), 1, want, fp) != want) { ok = false; break; }
                    fwrite(buf.data(), 1, want, out);
                    left -= (long)want;
                }
                fclose(out);
                if (!ok) break;
                chmod(full.c_str(), (mode & 0100) ? 0755 : 0644);
            }
            // 其余类型（pax 头 x/g 等）仅跳过内容
        }
        if (size % 512) fseek(fp, 512 - (size % 512), SEEK_CUR);  // 512 对齐
    }
    fclose(fp);
    return ok;
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

// ---------------- R 运行线程参数 ----------------
struct RThreadArgs {
    int fdStdin;   // R 读 stdin（管道读端）
    int fdStdout;  // R 写 stdout（管道写端）
    std::string rHome;
    std::string workDir;
    std::string libsDir;
    std::string nativeLibDir;
};

// ---------------- R 运行线程主函数 ----------------
// 把 rchild.cpp 的逻辑内联到主进程线程里：
// dup2 重定向 stdio → setenv → dlopen libR → Rf_initEmbeddedR → Rf_mainloop
static void *RRunnerThread(void *arg) {
    RThreadArgs *a = static_cast<RThreadArgs *>(arg);
    LOGI("R 线程启动");

    // 1) 接管 stdio（stdout+stderr 合流到同一管道）
    //    dup2 是进程级，但应用 UI 线程不使用 stdin/stdout，无副作用
    dup2(a->fdStdin,  STDIN_FILENO);
    dup2(a->fdStdout, STDOUT_FILENO);
    dup2(a->fdStdout, STDERR_FILENO);
    setvbuf(stdout, nullptr, _IONBF, 0);  // 无缓冲，确保输出立即可见
    setvbuf(stderr, nullptr, _IONBF, 0);
    // 关闭传入的 fd（已 dup2 到标准 fd，不再需要原句柄）
    close(a->fdStdin);
    close(a->fdStdout);

    // 2) 工作目录 + 环境变量（R 初始化时读取）
    if (!a->workDir.empty()) chdir(a->workDir.c_str());
    std::string ldPath = a->rHome + "/lib";
    if (!a->nativeLibDir.empty()) ldPath += ":" + a->nativeLibDir;
    setenv("R_HOME",       a->rHome.c_str(),   1);
    setenv("R_LIBS_USER",  a->libsDir.c_str(), 1);
    setenv("R_USER",       a->workDir.c_str(), 1);
    setenv("HOME",         a->workDir.c_str(), 1);
    setenv("TMPDIR",       a->workDir.c_str(), 1);
    setenv("LANG",         "C.UTF-8", 1);
    setenv("LC_ALL",       "C.UTF-8", 1);
    setenv("PATH",         (a->rHome + "/bin:" + ldPath).c_str(), 1);
    setenv("LD_LIBRARY_PATH", ldPath.c_str(), 1);
    setenv("R_LD_LIBRARY_PATH", (a->rHome + "/lib").c_str(), 1);
    // 修改 etc/ldpaths：移除硬编码的 WSL 构建路径（设备上不存在）
    {
        std::string lpPath = a->rHome + "/etc/ldpaths";
        FILE *lp = fopen(lpPath.c_str(), "r");
        if (lp) {
            char buf[4096];
            size_t n = fread(buf, 1, sizeof(buf) - 1, lp);
            fclose(lp);
            buf[n] = 0;
            std::string content(buf);
            size_t pos = content.find("/home/");
            if (pos != std::string::npos) {
                // 找到 WSL 路径的结束位置（换行或行尾）
                size_t end = content.find('\n', pos);
                if (end == std::string::npos) end = content.size();
                // 找到 WSL 路径前的冒号
                size_t colon = content.rfind(':', pos);
                if (colon != std::string::npos) {
                    content.erase(colon, end - colon);
                }
            }
            lp = fopen(lpPath.c_str(), "w");
            if (lp) {
                fwrite(content.c_str(), 1, content.size(), lp);
                fclose(lp);
                LOGI("已修改 etc/ldpaths，移除 WSL 路径");
            }
        }
    }
    // 禁用 JIT（避免 segfault），只加载 base 包（避免 tools.so/lapack.so 加载失败）
    setenv("R_DISABLE_JIT", "1", 1);
    setenv("R_DEFAULT_PACKAGES", "base", 1);
    setenv("R_MAX_VSIZE", "512M", 1);
    setenv("R_NSIZE", "200000", 1);
    // R 原生库根（可执行挂载点）：包 .so / 模块 .so 位于 nativeLibDir/R/ 下。
    // HarmonyOS app-data 挂载 noexec，dlopen 拒绝从数据目录加载共享库；
    // 补丁版 Rdynload.c 的 remapDLLPath 在 R_HOME 路径 dlopen 失败时按此
    // 前缀重映射（R_HOME/library/... → R_NATIVE_LIBRARY_ROOT/library/...），
    // R_moduleCdynload / R_cairoCdynload 也改用 nativeLibraryRoot()。
    if (!a->nativeLibDir.empty())
        setenv("R_NATIVE_LIBRARY_ROOT", (a->nativeLibDir + "/R").c_str(), 1);
    // 参照 RStudio-ohos：显式指定 R 目录与禁用字节码/JIT 编译，
    // 避免启动期触发 native 模块探测与 lazy-load 编译。
    setenv("R_LIBS_SITE",       (a->rHome + "/library").c_str(), 1);
    setenv("R_SHARE_DIR",       (a->rHome + "/share").c_str(),   1);
    setenv("R_INCLUDE_DIR",     (a->rHome + "/include").c_str(), 1);
    setenv("R_DOC_DIR",         (a->rHome + "/doc").c_str(),     1);
    setenv("R_ENABLE_JIT",      "0", 1);
    setenv("R_DISABLE_BYTECODE","1", 1);
    setenv("_R_COMPILE_PKGS_",  "0", 1);

    // 3) 按依赖顺序预加载 libR 的非系统依赖，再加载 libR.so
    //    注意：不预加载 libz.so——SDK 的 libz.so 是 stub，
    //    libR.so 有 NEEDED: libz.so，系统 linker 会自动找到设备上的真 libz.so
    //    同时删除 R/lib/libz.so（也是 stub），避免 LD_LIBRARY_PATH 找到 stub
    {
        std::string stubZ = a->rHome + "/lib/libz.so";
        if (unlink(stubZ.c_str()) == 0) LOGI("已删除 stub libz.so: %{public}s", stubZ.c_str());
    }
    std::vector<std::string> dirs;
    if (!a->nativeLibDir.empty()) dirs.push_back(a->nativeLibDir);
    dirs.push_back(a->rHome + "/lib");
    DlopenFrom("libomp.so", dirs);
    // libz.so 故意不预加载——让系统 linker 找真实现
    void *libR = DlopenFrom("libR.so", dirs);
    if (!libR) {
        LOGE("libR.so 全部路径加载失败");
        fprintf(stderr, "[RHost] 无法加载 libR.so\n");
        g_rRunning = false;
        delete a;
        return nullptr;
    }


    // 4) 解析嵌入 API
    using InitR_t = int  (*)(int, char **);
    using Loop_t  = void (*)(void);
    auto Rf_initEmbeddedR = (InitR_t)dlsym(libR, "Rf_initEmbeddedR");
    auto Rf_mainloop      = (Loop_t)dlsym(libR, "Rf_mainloop");
    if (!Rf_initEmbeddedR || !Rf_mainloop) {
        LOGE("dlsym 失败: %{public}s", dlerror());
        fprintf(stderr, "[RHost] 嵌入符号解析失败\n");
        g_rRunning = false;
        delete a;
        return nullptr;
    }

    // 4b) 回调设置移到 Rf_initEmbeddedR 之后（避免被 setup_Rmainloop 覆盖）
    auto ptr_R_ReadConsole_sym = (int (**)(const char *, unsigned char *, int, int))dlsym(libR, "ptr_R_ReadConsole");
    auto ptr_R_WriteConsole_sym = (void (**)(const char *, int))dlsym(libR, "ptr_R_WriteConsole");
    auto ptr_R_WriteConsoleEx_sym = (void (**)(const char *, int, int))dlsym(libR, "ptr_R_WriteConsoleEx");
    auto ptr_R_FlushConsole_sym = (void (**)())dlsym(libR, "ptr_R_FlushConsole");
    auto ptr_R_ResetConsole_sym = (void (**)())dlsym(libR, "ptr_R_ResetConsole");
    auto ptr_R_ProcessEvents_sym = (void (**)())dlsym(libR, "ptr_R_ProcessEvents");
    auto ptr_R_ShowMessage_sym = (void (**)(const char *))dlsym(libR, "ptr_R_ShowMessage");
    auto R_Interactive_sym = (int *)dlsym(libR, "R_Interactive");

    // 5) 初始化并进入 R REPL
    //    static 存储期：R 初始化会改写/持有 argv
    //    Rf_initEmbeddedR = Rf_initialize_R + (R_Interactive=TRUE) + setup_Rmainloop
    //    —— 显式置交互模式，抵消 stdin 为管道非 tty 的非交互判定

    // 诊断：检查 R_HOME 关键文件是否就位
    LOGI("诊断 R_HOME=%{public}s", a->rHome.c_str());
    {
        struct stat st;
        auto check = [&](const std::string &rel) {
            std::string p = a->rHome + "/" + rel;
            if (stat(p.c_str(), &st) == 0) LOGI("✓ %{public}s 存在 (size=%{public}lld)", rel.c_str(), (long long)st.st_size);
            else LOGE("✗ %{public}s 不存在", rel.c_str());
        };
        check("etc/Renviron");
        check("etc/Rprofile.site");
        check("etc/ldpaths");
        check("library/base/R/base.rdx");
        check("library/base/R/base.rdb");
        check("library/base/Meta/package.rds");
        check("library/base/Meta/nsInfo.rds");
        check("library/base/DESCRIPTION");
        check("library/base/NAMESPACE");
        check("library/methods/R/methods.rdx");
        check("library/utils/R/utils.rdx");
        check("library/grDevices/R/grDevices.rdx");
        check("library/stats/R/stats.rdx");
        check("share/R/Rd2/Rd2.R");
        check("modules");
        // 列出 modules 目录内容
        DIR *d = opendir((a->rHome + "/modules").c_str());
        if (d) {
            struct dirent *e;
            while ((e = readdir(d))) {
                if (e->d_name[0] != '.') LOGI("  modules/%{public}s", e->d_name);
            }
            closedir(d);
        } else {
            LOGE("✗ modules 目录不存在或无法打开");
        }
    }

    static char a0[] = "R";
    static char a1[] = "--vanilla", a2[] = "--interactive";
    static char *argv[] = {a0, a1, a2, nullptr};

    // 用 sigsetjmp 捕获 R 初始化和运行中的 exit()/segfault
    // exit() → appspawn helper abort() → SIGABRT → handler → siglongjmp
    // segfault → SIGSEGV → handler → siglongjmp
    signal(SIGABRT, RAbortHandler);
    signal(SIGSEGV, RAbortHandler);
    g_rExitJmpReady.store(true);
    int jmpRet = sigsetjmp(g_rExitJmp, 1);  // 1 = 保存信号掩码
    if (jmpRet == 0) {
        // 正常路径：调用 Rf_initEmbeddedR
        if (Rf_initEmbeddedR(3, argv) != 1) {
            LOGE("Rf_initEmbeddedR 失败（返回非 1）");
            g_rExitJmpReady.store(false);
            g_rRunning = false;
            delete a;
            return nullptr;
        }
        // g_rExitJmpReady 保持 true——主循环中也要捕获 segfault/exit

        // 4c) R 初始化后设置控制台回调（覆盖 setup_Rmainloop 的默认值）
        if (R_Interactive_sym) {
            *R_Interactive_sym = 1;
            LOGI("R_Interactive 已设置为 1");
        }
        if (ptr_R_ReadConsole_sym) {
            *ptr_R_ReadConsole_sym = [](const char *prompt, unsigned char *buf, int len, int /*hist*/) -> int {
                if (prompt && *prompt) fputs(prompt, stderr);
                if (fgets((char *)buf, len, stdin)) return 1;
                return 0;
            };
            LOGI("ptr_R_ReadConsole 已设置（init 后）");
        }
        if (ptr_R_WriteConsole_sym) {
            *ptr_R_WriteConsole_sym = [](const char *buf, int len) -> void { fwrite(buf, 1, len, stdout); };
            LOGI("ptr_R_WriteConsole 已设置（init 后）");
        }
        if (ptr_R_WriteConsoleEx_sym) *ptr_R_WriteConsoleEx_sym = [](const char *buf, int len, int) -> void { fwrite(buf, 1, len, stdout); };
        if (ptr_R_FlushConsole_sym) *ptr_R_FlushConsole_sym = []() -> void { fflush(stdout); };
        if (ptr_R_ResetConsole_sym) *ptr_R_ResetConsole_sym = []() -> void {};
        if (ptr_R_ProcessEvents_sym) *ptr_R_ProcessEvents_sym = []() -> void {};
        if (ptr_R_ShowMessage_sym) *ptr_R_ShowMessage_sym = [](const char *s) -> void { fputs(s, stderr); };

        // 设置其余回调为 no-op（避免 NULL 指针 segfault）
        auto ptr_R_Busy_sym = (void (**)(int))dlsym(libR, "ptr_R_Busy");
        auto ptr_R_CleanUp_sym = (void (**)(int, int, int, int))dlsym(libR, "ptr_R_CleanUp");
        auto ptr_R_Suicide_sym = (void (**)(const char *))dlsym(libR, "ptr_R_Suicide");
        auto ptr_R_ShowFiles_sym = (int (**)(int, const char **, const char **, const char *, const char *, const char *))dlsym(libR, "ptr_R_ShowFiles");
        auto ptr_R_ChooseFile_sym = (int (**)(int, char *, int))dlsym(libR, "ptr_R_ChooseFile");
        auto ptr_R_EditFile_sym = (int (**)(const char *))dlsym(libR, "ptr_R_EditFile");
        auto ptr_R_EditFiles_sym = (void (**)(int, const char **, const char **, const char *))dlsym(libR, "ptr_R_EditFiles");
        auto ptr_R_loadhistory_sym = (void (**)(const char *, const char *))dlsym(libR, "ptr_R_loadhistory");
        auto ptr_R_savehistory_sym = (void (**)(const char *, const char *))dlsym(libR, "ptr_R_savehistory");
        auto ptr_R_addhistory_sym = (void (**)(const char *, const char *))dlsym(libR, "ptr_R_addhistory");
        auto ptr_R_ClearerrConsole_sym = (void (**)())dlsym(libR, "ptr_R_ClearerrConsole");
        if (ptr_R_Busy_sym) *ptr_R_Busy_sym = [](int) -> void {};
        if (ptr_R_CleanUp_sym) *ptr_R_CleanUp_sym = [](int, int, int, int) -> void {};
        if (ptr_R_Suicide_sym) *ptr_R_Suicide_sym = [](const char *s) -> void { fputs(s, stderr); fputc('\n', stderr); fflush(stderr); };
        if (ptr_R_ShowFiles_sym) *ptr_R_ShowFiles_sym = [](int, const char **, const char **, const char *, const char *, const char *) -> int { return 0; };
        if (ptr_R_ChooseFile_sym) *ptr_R_ChooseFile_sym = [](int, char *, int) -> int { return 0; };
        if (ptr_R_EditFile_sym) *ptr_R_EditFile_sym = [](const char *) -> int { return 0; };
        if (ptr_R_EditFiles_sym) *ptr_R_EditFiles_sym = [](int, const char **, const char **, const char *) -> void {};
        if (ptr_R_loadhistory_sym) *ptr_R_loadhistory_sym = [](const char *, const char *) -> void {};
        if (ptr_R_savehistory_sym) *ptr_R_savehistory_sym = [](const char *, const char *) -> void {};
        if (ptr_R_addhistory_sym) *ptr_R_addhistory_sym = [](const char *, const char *) -> void {};
        if (ptr_R_ClearerrConsole_sym) *ptr_R_ClearerrConsole_sym = []() -> void {};
        LOGI("所有 R 回调已设置");

        // 4d) 覆盖 base::Sys.which —— HarmonyOS 无 /bin/sh，system() 会 EINVAL
        //     Rf_initEmbeddedR 后 base namespace 已就绪，用 C API 注入 R 代码
        {
            using SEXP_t = void *;
            using Rf_allocVector_t = SEXP_t (*)(int, int);
            using SET_STRING_ELT_t = void (*)(SEXP_t, int, SEXP_t);
            using Rf_mkChar_t = SEXP_t (*)(const char *);
            using R_ParseVector_t = SEXP_t (*)(SEXP_t, int, int *, SEXP_t);
            using Rf_eval_t = SEXP_t (*)(SEXP_t, SEXP_t);
            using LENGTH_t = int (*)(SEXP_t);
            using VECTOR_ELT_t = SEXP_t (*)(SEXP_t, int);

            auto Rf_allocVector_fn = (Rf_allocVector_t)dlsym(libR, "Rf_allocVector");
            auto SET_STRING_ELT_fn = (SET_STRING_ELT_t)dlsym(libR, "SET_STRING_ELT");
            auto Rf_mkChar_fn = (Rf_mkChar_t)dlsym(libR, "Rf_mkChar");
            auto R_ParseVector_fn = (R_ParseVector_t)dlsym(libR, "R_ParseVector");
            auto Rf_eval_fn = (Rf_eval_t)dlsym(libR, "Rf_eval");
            auto LENGTH_fn = (LENGTH_t)dlsym(libR, "LENGTH");
            auto VECTOR_ELT_fn = (VECTOR_ELT_t)dlsym(libR, "VECTOR_ELT");
            auto R_GlobalEnv_ptr = (SEXP_t *)dlsym(libR, "R_GlobalEnv");
            auto R_NilValue_ptr = (SEXP_t *)dlsym(libR, "R_NilValue");

            if (Rf_allocVector_fn && SET_STRING_ELT_fn && Rf_mkChar_fn &&
                R_ParseVector_fn && Rf_eval_fn && LENGTH_fn && VECTOR_ELT_fn &&
                R_GlobalEnv_ptr && R_NilValue_ptr) {

                // R 代码：覆盖 Sys.which 返回空字符串
                // assignInNamespace 在 utils 包中（未加载），改用 unlockBinding+assign
                const char *r_code =
                    "unlockBinding('Sys.which', baseenv());"
                    "assign('Sys.which', function(names) {"
                    "  res <- character(length(names)); names(res) <- names; res"
                    "}, envir=baseenv());"
                    "lockBinding('Sys.which', baseenv())";

                // 创建字符向量（STRSXP = 16）
                SEXP_t text = Rf_allocVector_fn(16, 1);
                SET_STRING_ELT_fn(text, 0, Rf_mkChar_fn(r_code));

                // 解析并执行
                int status = 0;
                SEXP_t exprs = R_ParseVector_fn(text, -1, &status, *R_NilValue_ptr);

                if (status == 1 && exprs) {  // PARSE_OK = 1
                    int n = LENGTH_fn(exprs);
                    for (int i = 0; i < n; i++) {
                        Rf_eval_fn(VECTOR_ELT_fn(exprs, i), *R_GlobalEnv_ptr);
                    }
                    LOGI("Sys.which 已覆盖（HarmonyOS 无 /bin/sh）");

                    // 图形设备初始化改为通过 REPL stdin 管道发送（避免 R_ParseVector segfault）
                    // Index.ets 在 R 启动后通过 writeR 发送 library(stats) 等命令
                    LOGI("跳过 R 代码注入，改用 REPL 管道初始化");
                } else {
                    LOGE("Sys.which 覆盖失败：解析状态=%d", status);
                }
            } else {
                LOGE("无法获取 R C API 符号，Sys.which 未覆盖");
            }
        }

        // 预加载所有包的 .so。必须从 R_NATIVE_LIBRARY_ROOT（nativeLibDir/R，
        // 可执行挂载点）加载——app-data 目录 noexec，dlopen 从数据目录加载会被拒。
        // 预加载后 musl 以基本名注册这些 .so；R 内部 dyn.load 走
        // remapDLLPath 重映射路径再次 dlopen 同一路径，返回已加载句柄。
        {
            void *testH = dlopen("libR.so", RTLD_NOW);
            if (testH) LOGI("dlopen libR.so (基本名) 成功");
            else LOGE("dlopen libR.so (基本名) 失败: %{public}s", dlerror());

            std::string nativeRoot = a->nativeLibDir.empty() ? "" : a->nativeLibDir + "/R";
            std::string libRoot = nativeRoot.empty() ? (a->rHome + "/library")
                                                     : (nativeRoot + "/library");
            LOGI("包 .so 预加载目录(可执行): %{public}s", libRoot.c_str());
            DIR *libDir = opendir(libRoot.c_str());
            if (libDir) {
                struct dirent *pkg;
                int preloadCount = 0;
                while ((pkg = readdir(libDir))) {
                    if (pkg->d_name[0] == '.') continue;
                    std::string soPath = libRoot + "/" + pkg->d_name + "/libs/" + pkg->d_name + ".so";
                    struct stat st;
                    bool exists = (stat(soPath.c_str(), &st) == 0);
                    dlerror();
                    void *h = dlopen(soPath.c_str(), RTLD_NOW | RTLD_GLOBAL);
                    if (!h) {
                        h = dlopen(soPath.c_str(), RTLD_LAZY | RTLD_GLOBAL);
                    }
                    if (h) {
                        preloadCount++;
                        LOGI("预加载 %{public}s 成功", soPath.c_str());
                    } else if (exists) {
                        const char *err = dlerror();
                        LOGE("预加载 %{public}s 失败: %{public}s", soPath.c_str(), err ? err : "unknown");
                    }
                }
                closedir(libDir);
                LOGI("预加载了 %{public}d 个包 .so", preloadCount);
            } else {
                LOGE("opendir library 失败: %{public}s", libRoot.c_str());
            }
        }

        // 重新注册信号处理器（R 的 setup_Rmainloop 可能覆盖了我们的）
        signal(SIGABRT, RAbortHandler);
        signal(SIGSEGV, RAbortHandler);

        LOGI("进入 R 主循环（ReplDLL 模式）");
        g_rRunning = true;

        // 用 ReplDLLdo1 替代 Rf_mainloop——避免定时器 segfault
        using ReplInit_t = void (*)(void);
        using ReplDo1_t = int (*)(void);
        auto R_ReplDLLinit = (ReplInit_t)dlsym(libR, "R_ReplDLLinit");
        auto R_ReplDLLdo1 = (ReplDo1_t)dlsym(libR, "R_ReplDLLdo1");
        if (R_ReplDLLinit && R_ReplDLLdo1) {
            R_ReplDLLinit();
            int replStatus = 0;
            while (g_rRunning.load() && (replStatus = R_ReplDLLdo1()) >= 0) {
                // R_ReplDLLdo1 返回 0=需要更多输入, 1=已求值
            }
            LOGI("ReplDLL 退出，status=%{public}d", replStatus);
        } else {
            LOGE("R_ReplDLLinit/do1 未找到，回退 Rf_mainloop");
            Rf_mainloop();
        }
        g_rRunning = false;
        LOGI("R 主循环退出");
        close(STDOUT_FILENO);   // 通知泵线程 EOF
        close(STDERR_FILENO);
    } else {
        // exit() 或 segfault 被拦截
        signal(SIGABRT, SIG_DFL);  // 恢复默认处理
        signal(SIGSEGV, SIG_DFL);
        int code = g_rExitCode.load();
        if (code == 11) {
            LOGE("R 发生 segfault，已拦截（siglongjmp）");
            fprintf(stderr, "\n[R 运行时 segfault，已拦截]\n");
        } else {
            LOGE("R 调用 exit(%{public}d)，已拦截（siglongjmp）", code);
            fprintf(stderr, "\n[R 退出，exit code=%d]\n", code);
        }
        fflush(stderr);
        g_rExitJmpReady.store(false);
        g_rRunning = false;
        usleep(100000);  // 100ms 让泵线程读完 R 的错误输出
        close(STDOUT_FILENO);   // 通知泵线程 EOF
        close(STDERR_FILENO);
    }

    delete a;
    return nullptr;
}

// ---------------- 输出泵线程 ----------------
// 把 R 的 stdout 读出来追加到 g_outBuf，ArkTS 侧轮询取走
static void *PumpThread(void * /*arg*/) {
    char buf[4096];
    while (true) {
        ssize_t n = read(g_stdout_r, buf, sizeof(buf));
        if (n < 0) { if (errno == EINTR) continue; break; }
        if (n == 0) break;
        // 追加到轮询缓冲区
        {
            std::lock_guard<std::mutex> lk(g_outMtx);
            g_outBuf.append(buf, (size_t)n);
        }

    }
    // R 退出标记
    {
        std::lock_guard<std::mutex> lk(g_outMtx);
        g_outBuf += "\n[R 已退出]\n";
    }
    LOGI("R 输出泵线程退出");
    return nullptr;
}

// ---------------- NAPI 导出 ----------------
static napi_value UnpackTar(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string tarPath, dest;
    if (argc < 2 || !GetStr(env, args[0], tarPath) || !GetStr(env, args[1], dest)) {
        napi_throw_error(env, nullptr, "参数应为 (tarPath, destDir)");
        return nullptr;
    }
    bool ok = UnpackTarImpl(tarPath, dest);
    napi_value res;
    napi_get_boolean(env, ok, &res);
    return res;
}

static napi_value StartR(napi_env env, napi_callback_info info) {
    size_t argc = 5;
    napi_value args[5];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string rBin, rHome, workDir, libsDir;
    napi_valuetype cbType = napi_undefined;
    // rBin 参数保留仅为 ArkTS 侧签名兼容
    if (argc < 5 || !GetStr(env, args[0], rBin) || !GetStr(env, args[1], rHome) ||
        !GetStr(env, args[2], workDir) || !GetStr(env, args[3], libsDir) ||
        napi_typeof(env, args[4], &cbType) != napi_ok || cbType != napi_function) {
        napi_throw_error(env, nullptr, "参数应为 (rBin, rHome, workDir, libsDir, onOutput)");
        return nullptr;
    }
    if (g_rRunning) {
        napi_throw_error(env, nullptr, "R 已在运行");
        return nullptr;
    }

    napi_value name;
    napi_create_string_utf8(env, "rOutput", NAPI_AUTO_LENGTH, &name);
    // 清空输出缓冲区
    {
        std::lock_guard<std::mutex> lk(g_outMtx);
        g_outBuf.clear();
    }

    int inPipe[2], outPipe[2];
    if (pipe(inPipe) || pipe(outPipe)) {
        napi_throw_error(env, nullptr, "pipe 创建失败");
        return nullptr;
    }

    // 构造 R 线程参数
    auto *rta = new RThreadArgs;
    rta->fdStdin    = inPipe[0];   // R 读端
    rta->fdStdout   = outPipe[1];  // R 写端
    rta->rHome      = rHome;
    rta->workDir    = workDir;
    rta->libsDir    = libsDir;
    rta->nativeLibDir = GetNativeLibDir();
    LOGI("R_HOME=%{public}s NATIVELIBDIR=%{public}s", rHome.c_str(), rta->nativeLibDir.c_str());

    // 启动 R 运行线程
    pthread_t rThread;
    if (pthread_create(&rThread, nullptr, RRunnerThread, rta) != 0) {
        LOGE("pthread_create RRunnerThread 失败");
        close(inPipe[0]); close(inPipe[1]);
        close(outPipe[0]); close(outPipe[1]);
        delete rta;
        napi_throw_error(env, nullptr, "无法启动 R 线程");
        return nullptr;
    }
    pthread_detach(rThread);

    // 保留父进程侧管道端
    // inPipe[0] 和 outPipe[1] 由 R 线程拥有（dup2 + close），主线程不关闭
    g_stdin_w = inPipe[1];   // 父进程写 → R stdin
    g_stdout_r = outPipe[0]; // 父进程读 ← R stdout
    g_pid = (pid_t)rThread;  // 用线程 ID 替代 pid（仅用于状态标记）
    LOGI("R 线程已启动 (主进程内线程方案)");

    // 启动输出泵线程
    pthread_t pumpThread;
    pthread_create(&pumpThread, nullptr, PumpThread, nullptr);
    pthread_detach(pumpThread);

    napi_value res;
    napi_create_int32(env, 1, &res);  // 返回 1 表示成功
    return res;
}

static napi_value WriteR(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value arg;
    napi_get_cb_info(env, info, &argc, &arg, nullptr, nullptr);
    std::string line;
    if (argc < 1 || !GetStr(env, arg, line)) return nullptr;
    if (g_stdin_w < 0) return nullptr;
    if (line.empty() || line.back() != '\n') line += '\n';
    if (write(g_stdin_w, line.c_str(), line.size()) < 0) LOGE("write stdin 失败 errno=%{public}d", errno);
    return nullptr;
}

static napi_value InterruptR(napi_env, napi_callback_info) {
    // 向 R 线程发 SIGINT（R 的信号处理会中断当前计算）
    if (g_rRunning) {
        pthread_t tid = (pthread_t)g_pid.load();
        if (tid > 0) pthread_kill(tid, SIGINT);
    }
    return nullptr;
}

static napi_value StopR(napi_env, napi_callback_info) {
    if (g_stdin_w >= 0) {
        // 向 R 发送 q() 退出命令
        const char *quitCmd = "q()\n";
        write(g_stdin_w, quitCmd, strlen(quitCmd));
        close(g_stdin_w);
        g_stdin_w = -1;
    }
    g_pid = -1;
    g_rRunning = false;
    return nullptr;
}

// ArkTS 侧轮询：取走并清空输出缓冲区
static napi_value PollOutput(napi_env env, napi_callback_info) {
    std::string out;
    {
        std::lock_guard<std::mutex> lk(g_outMtx);
        out.swap(g_outBuf);
    }
    napi_value result;
    napi_create_string_utf8(env, out.c_str(), out.size(), &result);
    return result;
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"unpackTar", nullptr, UnpackTar, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"startR", nullptr, StartR, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"writeR", nullptr, WriteR, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"interruptR", nullptr, InterruptR, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stopR", nullptr, StopR, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"pollOutput", nullptr, PollOutput, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module rhostModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "entry",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterRHostModule(void) {
    napi_module_register(&rhostModule);
}
