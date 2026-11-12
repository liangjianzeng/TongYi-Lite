/* [npu-line M2 Phase C-3] d2q_* feeds 生成器实现 —— 冻结语义 =
 * npu-line/probe_m1/dec2/mcp5_95_prep77b.py（numpy/torch 侧真身）+
 * mcp5_79_gen_pre2_manifests.py（消费端文件名与 cos/sin stride=S*HD*2）。
 *
 * 判卷（hyb_feeds_selftest.sh，主机）：WSL torch 从 /home/liang/models/
 * minicpm5-2b 产参考；am/kc0/emb（同表喂入）要求逐字节全等，cos/sin 允许
 * 边界 1-ulp fp16 差异并计数上报（torch float32 cos vs 本模块 double cos）。
 *
 * 风格与 hyb_kv_bridge.c 一致：纯 C11 + stdio，失败清半成品。 */
#include "hyb_feeds.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <io.h>
#define HYB_FSYNC(fd)      _commit(fd)
#define HYB_FILENO(fp)     _fileno(fp)
#else
#include <unistd.h>
#define HYB_FSYNC(fd)      fsync(fd)
#define HYB_FILENO(fp)     fileno(fp)
#endif

static void feeds_fail(char *err, size_t errlen, const char *msg)
{
    if (err && errlen) { snprintf(err, errlen, "%s", msg); }
}

/* IEEE 754 binary32 → binary16，round-to-nearest-even。输入均为有限值
 * （cos/sin ∈ [-1,1]、mask ∈ {0,-1e4}、emb 行是 fp16 位型搬运），
 * NaN/Inf 分支仅为完备性。 */
uint16_t hyb_f32_to_f16(float f)
{
    uint32_t x;
    memcpy(&x, &f, sizeof(x));
    uint32_t sign = (x >> 16) & 0x8000u;
    uint32_t bexp = (x >> 23) & 0xFFu;
    uint32_t mant = x & 0x7FFFFFu;

    if (bexp == 0xFFu) { /* inf/nan（本模块理论不可达） */
        return (uint16_t)(sign | 0x7C00u | (mant ? 0x200u : 0u));
    }
    int32_t exp = (int32_t)bexp - 127 + 15;
    if (exp >= 0x1F) { return (uint16_t)(sign | 0x7C00u); } /* 溢出 → ±inf */
    if (exp <= 0) {                                          /* 次正规 half */
        if (exp < -10) { return (uint16_t)sign; }
        mant |= 0x800000u;
        uint32_t shift   = (uint32_t)(14 - exp);
        uint32_t half    = mant >> shift;
        uint32_t rem     = mant & ((1u << shift) - 1u);
        uint32_t halfway = 1u << (shift - 1u);
        if (rem > halfway || (rem == halfway && (half & 1u))) { half++; }
        return (uint16_t)(sign | half);
    }
    uint32_t half = ((uint32_t)exp << 10) | (mant >> 13);
    uint32_t rem  = mant & 0x1FFFu;
    if (rem > 0x1000u || (rem == 0x1000u && (half & 1u))) { half++; } /* 进位自然溢入 exp */
    return (uint16_t)(sign | half);
}

/* 写全缓冲 + fsync（chain_run5 由子进程 execve 后即读，落稳不吃亏）。 */
static int write_whole(const char *path, const void *buf, size_t n,
                       char *err, size_t errlen)
{
    FILE *f = fopen(path, "wb");
    if (!f) { feeds_fail(err, errlen, "feeds_open"); return -1; }
    if (n && fwrite(buf, 1, n, f) != n) {
        fclose(f); remove(path);
        feeds_fail(err, errlen, "feeds_write"); return -1;
    }
    if (fflush(f) != 0 || HYB_FSYNC(HYB_FILENO(f)) != 0) {
        fclose(f); remove(path);
        feeds_fail(err, errlen, "feeds_fsync"); return -1;
    }
    fclose(f);
    return 0;
}

int hyb_feeds_gen_kc0(const char *dir, int nc, int hd, int nkv,
                      char *err, size_t errlen)
{
    if (!dir || nc <= 0 || hd <= 0 || nkv <= 0) {
        feeds_fail(err, errlen, "kc0_param"); return -1;
    }
    size_t n = (size_t)nc * (size_t)hd * (size_t)nkv;
    uint16_t *z = (uint16_t *)calloc(n, sizeof(uint16_t));
    if (!z) { feeds_fail(err, errlen, "kc0_oom"); return -1; }
    char path[4096];
    int rc = 0;
    snprintf(path, sizeof(path), "%s/%skc0.raw", dir, HYB_FEEDS_PREFIX);
    rc = write_whole(path, z, n * 2, err, errlen);
    if (rc == 0) {
        snprintf(path, sizeof(path), "%s/%svc0.raw", dir, HYB_FEEDS_PREFIX);
        rc = write_whole(path, z, n * 2, err, errlen);
    }
    free(z);
    return rc;
}

int hyb_feeds_gen_am(const char *dir, int chunks, int s, int nc,
                     char *err, size_t errlen)
{
    if (!dir || chunks <= 0 || s <= 0 || nc < s) {
        feeds_fail(err, errlen, "am_param"); return -1;
    }
    const uint16_t NEG16 = hyb_f32_to_f16(HYB_FEEDS_NEG);
    size_t row   = (size_t)nc + (size_t)s;          /* [S, NC+S] ravel */
    size_t cells = (size_t)s * row;
    uint16_t *m  = (uint16_t *)malloc(cells * sizeof(uint16_t));
    if (!m) { feeds_fail(err, errlen, "am_oom"); return -1; }

    for (int c = 0; c < chunks; c++) {
        memset(m, 0, cells * sizeof(uint16_t));
        int pad = nc - c * s;                        /* 滑窗左界（坑 50 式） */
        if (pad > (int)row) { pad = (int)row; }
        for (int i = 0; i < s; i++) {
            uint16_t *r = m + (size_t)i * row;
            for (int j = 0; j < pad; j++) { r[j] = NEG16; }
            /* 新 S 行 vs chunk 内 query 行：triu(diagonal=1) 屏蔽未来
             * （prep77b: am[:, NC:] = triu(full(S,S,NEG), 1) → (i,NC+j)=NEG
             * 当 j>i；行 i 的后块列 j∈[i+1,s) 全 NEG） */
            for (int j = i + 1; j < s; j++) { r[(size_t)nc + j] = NEG16; }
        }
        char path[4096];
        snprintf(path, sizeof(path), "%s/%sam_%d.raw", dir, HYB_FEEDS_PREFIX, c);
        if (write_whole(path, m, cells * 2, err, errlen) != 0) { free(m); return -1; }
    }
    free(m);
    return 0;
}

int hyb_feeds_gen_rope(const char *dir, long long pos_base, int chunks, int s,
                       int hd, double theta, char *err, size_t errlen)
{
    if (!dir || chunks <= 0 || s <= 0 || hd <= 2 || (hd % 2) != 0 ||
        !(theta > 0.0)) {
        feeds_fail(err, errlen, "rope_param"); return -1;
    }
    const int   half = hd / 2;
    const size_t nel = (size_t)chunks * (size_t)hd * (size_t)s;
    double   *inv = (double *)malloc((size_t)half * sizeof(double));
    uint16_t *tc  = (uint16_t *)malloc(nel * sizeof(uint16_t));
    uint16_t *ts  = (uint16_t *)malloc(nel * sizeof(uint16_t));
    if (!inv || !tc || !ts) {
        free(inv); free(tc); free(ts);
        feeds_fail(err, errlen, "rope_oom"); return -1;
    }
    for (int j = 0; j < half; j++) {
        /* HF: inv_freq[j] = 1/theta^(2j/hd)（MiniCPM5 rotary dims = head dim
         * 全旋；j>=half 列复用 j-half —— 下面的 j % half） */
        inv[j] = pow(theta, -2.0 * (double)j / (double)hd);
    }
    /* 文件 = chunks 个 (hd, s) 块堆叠（prep77b：reshape(chunks,s,-1)
     * .transpose(0,2,1)）：out[(c*hd + j)*s + i]，t = c*s + i，
     * pos = pos_base + t。 */
    for (int c = 0; c < chunks; c++) {
        for (int i = 0; i < s; i++) {
            double pos = (double)(pos_base + (long long)(c * s + i));
            for (int j = 0; j < hd; j++) {
                double ang = pos * inv[j % half];
                size_t o   = ((size_t)c * (size_t)hd + (size_t)j) * (size_t)s
                             + (size_t)i;
                tc[o] = hyb_f32_to_f16((float)cos(ang));
                ts[o] = hyb_f32_to_f16((float)sin(ang));
            }
        }
    }
    char path[4096];
    int rc = 0;
    snprintf(path, sizeof(path), "%s/%scos_table.raw", dir, HYB_FEEDS_PREFIX);
    rc = write_whole(path, tc, nel * 2, err, errlen);
    if (rc == 0) {
        snprintf(path, sizeof(path), "%s/%ssin_table.raw", dir, HYB_FEEDS_PREFIX);
        rc = write_whole(path, ts, nel * 2, err, errlen);
    }
    free(inv); free(tc); free(ts);
    return rc;
}

int hyb_feeds_gen_emb(const char *dir, const uint16_t *rows, int total,
                      int s, int hid, char *err, size_t errlen)
{
    if (!dir || !rows || total <= 0 || s <= 0 || hid <= 0 || (total % s) != 0) {
        feeds_fail(err, errlen, "emb_param"); return -1;
    }
    const int chunks = total / s;
    const size_t blk = (size_t)hid * (size_t)s;
    uint16_t *buf = (uint16_t *)malloc((size_t)total * (size_t)hid
                                       * sizeof(uint16_t));
    if (!buf) { feeds_fail(err, errlen, "emb_oom"); return -1; }

    for (int t = 0; t < total; t++) {
        const uint16_t *row = rows + (size_t)t * (size_t)hid;
        int c = t / s, i = t % s;
        /* (hid, s) 块转置：out[(c*hid + h)*s + i] = rows[t][h]
         * （HF e.T.contiguous() 语义，prep77b: e.T.contiguous().tofile） */
        uint16_t *dst = buf + (size_t)c * blk + (size_t)i;
        for (int h = 0; h < hid; h++) { dst[(size_t)h * (size_t)s] = row[h]; }
    }
    for (int c = 0; c < chunks; c++) {
        char path[4096];
        snprintf(path, sizeof(path), "%s/%semb_%d.raw", dir, HYB_FEEDS_PREFIX, c);
        if (write_whole(path, buf + (size_t)c * blk, blk * 2, err, errlen) != 0) {
            free(buf); return -1;
        }
    }
    free(buf);
    return 0;
}
