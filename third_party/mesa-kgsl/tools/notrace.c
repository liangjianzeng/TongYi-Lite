/* [Mesa 线 P0-2 替代路径] 运行时 trace-off：LD_PRELOAD 拦掉 Mesa 调试版的逐提交 printf。
 *
 * 为什么要它：在机那颗 libRusticlOpenCL.so（md5 c82f84d8…）里 KGSLSUBMIT/FDBATCH/BORERELEASE/
 * CSDESC 是无条件 fprintf(stderr,...)。源码（P0-1）到手前编不出 trace-off 干净版，但**打印税可以
 * 在运行时剥掉**：这些 lib 对 fprintf 的调用走 PLT，可被 LD_PRELOAD 覆盖。拦掉之后既省掉格式化+
 * write，也给"trace 版到底比干净版慢多少"一个**真工作量上的直接 A/B**（比 trace_tax 的合成估计硬）。
 *
 * 诚实条款（重要）：
 *   1) 这只剥 printf。若调试版还编进了别的跟踪逻辑（额外锁/记账/额外 ioctl），本工具剥不掉 ——
 *      用它测出的差值只覆盖"打印"这一项，报告里必须这么写。
 *   2) **必须验计数**：退出时打印拦到的行数。计数为 0 = 覆盖没生效（比如 bionic 把 fprintf
 *      优化成了内部 __fwalk 路径），此时任何"没差别"的结论都不许下。
 *   3) 只拦我们认识的前缀，其余原样输出，免得把真错误也吞了。
 *
 * 用法（设备侧）：
 *   LD_PRELOAD=/data/local/tmp/libnotrace.so GGML_OPENCL_OPFLUSH=0 ./minicpm_e2e ...
 *   NOTRACE_KEEP=1  只计数不吞（对照用）
 *   NOTRACE_DEBUG=1 把被吞的行首 60 字节打到 stdout（确认前缀认全了）
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>

static const char *kTraceTags[] = {
    "KGSLSUBMIT", "KGSLWAIT", "KGSLSCAN", "KGSLPROBE", "KGSLDEV",
    "FDBATCH", "BORERELEASE", "CSDESC", "FDGRID", "KGSLFAULT",
};
#define NTAGS ((int)(sizeof(kTraceTags) / sizeof(kTraceTags[0])))

static long g_swallowed = 0, g_passed = 0;
static int g_keep = 0, g_debug = 0;

static void notrace_fini(void) {
    /* 计数走 stdout：stderr 常被取数脚本重定向 */
    fprintf(stdout, "[notrace] swallowed=%ld passed=%ld keep=%d\n", g_swallowed, g_passed, g_keep);
    fflush(stdout);
}

static int is_trace(const char *fmt) {
    if (!fmt) return 0;
    for (int i = 0; i < NTAGS; i++) {
        size_t n = strlen(kTraceTags[i]);
        if (strncmp(fmt, kTraceTags[i], n) == 0) return 1;
    }
    return 0;
}

int fprintf(FILE *stream, const char *fmt, ...) {
    if (!g_keep && is_trace(fmt)) {
        g_swallowed++;
        if (g_debug) { /* 只认前缀，不格式化，省掉被测成本 */
            fwrite(fmt, 1, strnlen(fmt, 60) < 60 ? strnlen(fmt, 60) : 60, stdout);
            fputc('\n', stdout);
        }
        return 0;
    }
    g_passed++;
    va_list ap;
    va_start(ap, fmt);
    int r = vfprintf(stream, fmt, ap);
    va_end(ap);
    return r;
}

/* 有些编译单元会直接用 printf / vfprintf，一并接住 */
int printf(const char *fmt, ...) {
    if (!g_keep && is_trace(fmt)) { g_swallowed++; return 0; }
    g_passed++;
    va_list ap; va_start(ap, fmt); int r = vfprintf(stdout, fmt, ap); va_end(ap); return r;
}

int vfprintf(FILE *stream, const char *fmt, va_list ap) {
    if (!g_keep && is_trace(fmt)) { g_swallowed++; return 0; }
    g_passed++;
    /* 直接落到 fd，避免再绕回自己 */
    char buf[4096];
    int n = vsnprintf(buf, sizeof buf, fmt, ap);
    if (n <= 0) return n;
    size_t want = (size_t) n < sizeof buf ? (size_t) n : sizeof buf - 1;
    FILE *real = stream;
    if (real == NULL) real = stderr;
    return (int) fwrite(buf, 1, want, real);
}

__attribute__((constructor)) static void notrace_init(void) {
    g_keep = getenv("NOTRACE_KEEP") ? 1 : 0;
    g_debug = getenv("NOTRACE_DEBUG") ? 1 : 0;
    atexit(notrace_fini);
}
