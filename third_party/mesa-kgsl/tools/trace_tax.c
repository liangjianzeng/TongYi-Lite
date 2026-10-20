/* [Mesa 线 P0-2 附属量具] trace 税的量上界尺子。
 *
 * 背景：现在在机那颗 libRusticlOpenCL.so（md5 c82f84d8…）里 KGSLSUBMIT/FDBATCH/BORERELEASE/
 * CSDESC 这些是无条件 printf 的调试版。所有 Mesa 性能数因此都带一个"打印税"，之前只写成
 * "估计 2-4×"，那是拍脑袋。这个量具把拍脑袋换成一个可复现的上界：
 *   在真机上按 830 实测的**每 token 行数配比**刷同样的行到 stderr（调用侧 2>/dev/null），
 *   测出 µs/行 与 ms/token，与同循环的"不打印"对照相减 => 每 token 的打印税上界。
 * 为什么是上界：真机 printf 走的是同一个 FILE*、同样的格式化路径，但真机还有别的活干；
 * 而这里 stderr 直接进 /dev/null，比落文件的真实调试环境更快，所以是"最少也要付这么多"。
 *
 * 用法（设备侧）：
 *   /data/local/tmp/trace_tax [tokens=64] [repeat=3]
 * 程序自己把 stderr freopen 到 /dev/null —— **不要**让调用方去重定向 stdout，
 * 否则结果行会被一起吞掉（第一版就踩过：调用写成 >/dev/null 2>/dev/null 打出个空）。
 */
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <stdint.h>

static double now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double) ts.tv_sec * 1e3 + (double) ts.tv_nsec * 1e-6;
}

/* 830 实测（64 token 腿，OPFLUSH=1，IO_THREADS=1）：
 *   KGSLSUBMIT cmd[]=169954  FDBATCH flush=169954  BORERELEASE=575825  CSDESC=215991
 *   => 每 token：2656 / 2656 / 8997 / 3375 ≈ 17684 行（含 SCAN/WAIT 少量，取 15000 为保守配比）
 * 下面按同一配比刷行，格式串形状照抄（长度决定格式化成本，形状必须像）。 */
#define PER_TOKEN_SUBMIT   2656
#define PER_TOKEN_FDBATCH  2656
#define PER_TOKEN_BORERELEASE 8997
#define PER_TOKEN_CSDESC   3375

static volatile long sink;

/* one pass = `tokens` 个 token 的全部 trace 行 */
static void emit(int tokens, int do_print) {
    for (int t = 0; t < tokens; t++) {
        for (int i = 0; i < PER_TOKEN_SUBMIT; i++) {
            if (do_print)
                fprintf(stderr, "KGSLSUBMIT ring=%p ib=%d numcmds=%d nsyncs=%d seqno=%u ret=%d errno=%s\n",
                        (void *) 0x7abf1200UL, i & 0x1f, 1, 0, (unsigned) i, 0, "Try again");
            else sink += i;
        }
        for (int i = 0; i < PER_TOKEN_FDBATCH; i++) {
            if (do_print)
                fprintf(stderr, "FDBATCH flush: ring=%p ib_offset=%d size=%d nr_cmds=%d nr_bos=%d\n",
                        (void *) 0x7abf1200UL, (i * 32) & 0xffff, 584, 1, 3);
            else sink += i;
        }
        for (int i = 0; i < PER_TOKEN_BORERELEASE; i++) {
            if (do_print)
                fprintf(stderr, "BORERELEASE bo=%p size=%d name=%u\n",
                        (void *) 0x7c110000UL, 32768, (unsigned)(t * 977 + i));
            else sink += i;
        }
        for (int i = 0; i < PER_TOKEN_CSDESC; i++) {
            if (do_print)
                fprintf(stderr, "CSDESC ib=%p sz=%d pad=%d ts=%d\n",
                        (void *) 0x7c220000UL, 584, 8, 1);
            else sink += i;
        }
    }
}

int main(int argc, char **argv) {
    int tokens = argc > 1 ? atoi(argv[1]) : 64;
    int repeat = argc > 2 ? atoi(argv[2]) : 3;
    if (tokens <= 0) tokens = 1;
    if (repeat <= 0) repeat = 1;
    /* 自己关 stderr：格式化照跑（这才是被测的成本），只是落 /dev/null。
     * 留 TRACETAX_KEEP_STDERR 给"想看真刷屏"的人。 */
    if (!getenv("TRACETAX_KEEP_STDERR")) freopen("/dev/null", "w", stderr);
    const long lines = (long) tokens * (PER_TOKEN_SUBMIT + PER_TOKEN_FDBATCH +
                                        PER_TOKEN_BORERELEASE + PER_TOKEN_CSDESC);

    double best_print = 1e30, best_silent = 1e30;
    for (int r = 0; r < repeat; r++) {
        double a = now_ms(); emit(tokens, 1); double b = now_ms();
        if (b - a < best_print) best_print = b - a;
        a = now_ms(); emit(tokens, 0); b = now_ms();
        if (b - a < best_silent) best_silent = b - a;
    }
    /* stdout 不受 2>/dev/null 影响 */
    printf("[tracetax] tokens=%d repeat=%d lines=%ld\n", tokens, repeat, lines);
    printf("[tracetax] print_ms=%.1f silent_ms=%.1f tax_ms_total=%.1f\n",
           best_print, best_silent, best_print - best_silent);
    printf("[tracetax] us_per_line=%.3f  ms_per_token=%.2f  lines_per_token=%.0f\n",
           (best_print - best_silent) * 1e3 / (double) lines,
           (best_print - best_silent) / (double) tokens,
           (double) lines / (double) tokens);
    (void) sink;
    return 0;
}
