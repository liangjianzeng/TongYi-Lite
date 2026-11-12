/* [npu-line M2 Phase C-3] hyb_feeds 主机自测（build via
 * hyb_feeds_selftest.sh，同 hyb_kv_bridge_selftest 模式）。
 *
 * 用法：
 *   hyb_feeds_selftest <out_dir> <rows.raw> <hid> <theta> <hd> \
 *       [ref_dir] [s=128] [nc=512] [pos_base=88] [chunks=4] [nkv=2]
 *
 * rows.raw = nc*hid 个 fp16 位型（WSL 参考生成器 eos-pad 补齐后的
 * token_embd 行，逐行对应 prompt token）；生成器只做布局，不看 ids。
 * 布局断言恒跑；ref_dir 存在则逐字节对拍（emb/am/kc0/vc0 要求全等）。
 * cos/sin 由「trig 真值执法」恒跑把关：与 float64 真值（double 角度 +
 * 单步 RN-even 到 fp16）的 rank-ulp 距 >1 即 FAIL；与 fp32 复刻参考表的
 * 差异只作信息打印（fp32 路径自身在大角度零点附近可超 1 ulp，见 hyb_d
 * dtest F1 结档，不作为回归判据）。 */
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "hyb_feeds.h"

static long fsize(const char *p)
{
    FILE *f = fopen(p, "rb");
    if (!f) return -1;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fclose(f);
    return n;
}

/* 0 equal; 1 differ (count); -1 missing/short. 固定 n 字节 fread 对比
 * （fgetc-EOF 短路在双 EOF 判定上有假阴性坑，不用）。 */
static int cmp_bytes(const char *a, const char *b, size_t n, size_t *diff_out)
{
    *diff_out = 0;
    if (fsize(a) != (long)n || fsize(b) != (long)n) return -1;
    FILE *fa = fopen(a, "rb"), *fb = fopen(b, "rb");
    if (!fa || !fb) { if (fa) fclose(fa); if (fb) fclose(fb); return -1; }
    int rc = 0;
    uint8_t ba[4096], bb[4096];
    size_t left = n;
    while (left) {
        size_t k = left < sizeof(ba) ? left : sizeof(ba);
        size_t ra = fread(ba, 1, k, fa), rb = fread(bb, 1, k, fb);
        if (ra != k || rb != k) { rc = -1; break; }
        for (size_t i = 0; i < k; i++) { if (ba[i] != bb[i]) (*diff_out)++; }
        left -= k;
    }
    fclose(fa); fclose(fb);
    if (rc != 0) return rc;
    return (*diff_out == 0) ? 0 : 1;
}

int main(int argc, char **argv)
{
    if (argc < 6) {
        fprintf(stderr, "usage: %s <out_dir> <rows.raw> <hid> <theta> <hd> "
                        "[ref_dir] [s] [nc] [pos_base] [chunks] [nkv]\n", argv[0]);
        return 2;
    }
    const char *dir  = argv[1];
    const char *rows = argv[2];
    const int   hid  = atoi(argv[3]);
    const double theta = atof(argv[4]);
    const int   hd   = atoi(argv[5]);
    const char *ref  = (argc > 6) ? argv[6] : NULL;
    const int   s    = (argc > 7)  ? atoi(argv[7])  : HYB_FEEDS_S_DEFAULT;
    const int   nc   = (argc > 8)  ? atoi(argv[8])  : HYB_FEEDS_NC_DEFAULT;
    const long long p0 = (argc > 9) ? atoll(argv[9]) : HYB_FEEDS_P0_DEFAULT;
    const int   chunks = (argc > 10) ? atoi(argv[10]) : HYB_FEEDS_CHUNKS_DEFAULT;
    const int   nkv  = (argc > 11) ? atoi(argv[11]) : HYB_FEEDS_NKV_DEFAULT;

    int fail = 0;
    char err[128] = "";

    /* rows 表装载（nc*hid fp16 位型；参考生成器已 eos-pad 补齐） */
    size_t need = (size_t)nc * (size_t)hid * 2;
    if ((size_t)fsize(rows) != need) {
        fprintf(stderr, "FEEDS_FAIL rows.raw size %ld != %zu\n", fsize(rows), need);
        return 1;
    }
    uint16_t *tab = (uint16_t *)malloc(need);
    FILE *f = fopen(rows, "rb");
    if (!f || fread(tab, 1, need, f) != need) {
        fprintf(stderr, "FEEDS_FAIL rows.raw read\n");
        free(tab); if (f) fclose(f);
        return 1;
    }
    fclose(f);

    if (hyb_feeds_gen_emb (dir, tab, nc, s, hid, err, sizeof(err)) != 0 ||
        hyb_feeds_gen_am  (dir, chunks, s, nc, err, sizeof(err)) != 0 ||
        hyb_feeds_gen_rope(dir, p0, chunks, s, hd, theta, err, sizeof(err)) != 0 ||
        hyb_feeds_gen_kc0 (dir, nc, hd, nkv, err, sizeof(err)) != 0) {
        fprintf(stderr, "FEEDS_FAIL generate: %s\n", err);
        free(tab);
        return 1;
    }
    free(tab);

    /* ---- 布局/尺寸断言（恒跑，不依赖参考） ---- */
    struct { const char *name; long want; } files[] = {
        { "d2q_emb_0.raw",      (long)hid * s * 2 },
        { "d2q_emb_1.raw",      (long)hid * s * 2 },
        { "d2q_emb_2.raw",      (long)hid * s * 2 },
        { "d2q_emb_3.raw",      (long)hid * s * 2 },
        { "d2q_am_0.raw",       (long)s * (nc + s) * 2 },
        { "d2q_am_1.raw",       (long)s * (nc + s) * 2 },
        { "d2q_am_2.raw",       (long)s * (nc + s) * 2 },
        { "d2q_am_3.raw",       (long)s * (nc + s) * 2 },
        { "d2q_cos_table.raw",  (long)chunks * hd * s * 2 },
        { "d2q_sin_table.raw",  (long)chunks * hd * s * 2 },
        { "d2q_kc0.raw",        (long)nc * hd * nkv * 2 },
        { "d2q_vc0.raw",        (long)nc * hd * nkv * 2 },
    };
    for (size_t i = 0; i < sizeof(files) / sizeof(files[0]); i++) {
        char p[4096];
        snprintf(p, sizeof(p), "%s/%s", dir, files[i].name);
        long got = fsize(p);
        if (got != files[i].want) {
            printf("FEEDS_SIZE_FAIL %s got=%ld want=%ld\n",
                   files[i].name, got, files[i].want);
            fail = 1;
        } else {
            printf("FEEDS_SIZE_OK %s %ld\n", files[i].name, got);
        }
    }
    /* kc0/vc0 全零抽查 */
    {
        char p[4096];
        snprintf(p, sizeof(p), "%s/d2q_kc0.raw", dir);
        FILE *kf = fopen(p, "rb");
        int nz = 0;
        if (kf) {
            int c;
            while ((c = fgetc(kf)) != EOF) { if (c != 0) nz = 1; }
            fclose(kf);
        } else nz = 1;
        if (nz) { printf("FEEDS_ZERO_FAIL d2q_kc0.raw not all-zero\n"); fail = 1; }
        else    { printf("FEEDS_ZERO_OK d2q_kc0.raw\n"); }
    }

    /* ---- 参考对拍（ref_dir 存在时） ---- */
    if (ref) {
        const size_t exact_n[] = {
            (size_t)hid * s * 2, (size_t)hid * s * 2,
            (size_t)hid * s * 2, (size_t)hid * s * 2,
            (size_t)s * (nc + s) * 2, (size_t)s * (nc + s) * 2,
            (size_t)s * (nc + s) * 2, (size_t)s * (nc + s) * 2,
            (size_t)nc * hd * nkv * 2, (size_t)nc * hd * nkv * 2,
        };
        const char *exact_names[] = {
            "d2q_emb_0.raw", "d2q_emb_1.raw", "d2q_emb_2.raw", "d2q_emb_3.raw",
            "d2q_am_0.raw", "d2q_am_1.raw", "d2q_am_2.raw", "d2q_am_3.raw",
            "d2q_kc0.raw", "d2q_vc0.raw",
        };
        for (size_t i = 0; i < sizeof(exact_names) / sizeof(exact_names[0]); i++) {
            char a[4096], b[4096];
            snprintf(a, sizeof(a), "%s/%s", dir, exact_names[i]);
            snprintf(b, sizeof(b), "%s/%s", ref, exact_names[i]);
            size_t diff = 0;
            int rc = cmp_bytes(a, b, exact_n[i], &diff);
            if (rc != 0) {
                printf("FEEDS_DIFF_FAIL %s rc=%d diffbytes=%zu\n",
                       exact_names[i], rc, diff);
                fail = 1;
            } else {
                printf("FEEDS_EXACT_OK %s\n", exact_names[i]);
            }
        }
        /* cos/sin 与 ref（fp32 复刻表）的对拍降级为信息项：prep77b 的
         * fp32 rope 路径在大角度三角零点附近自身可超 1 fp16 ulp（hyb_d
         * dtest 结档 F1），C 的 double 路径更准，ref-vs-C 超界不是回归
         * 信号。真正的执法在下方「trig 真值执法」（恒跑，不依赖 ref）。 */
        const char *trig[] = { "d2q_cos_table.raw", "d2q_sin_table.raw" };
        const size_t tn = (size_t)chunks * hd * s;
        for (size_t k = 0; k < 2; k++) {
            char b[4096];
            snprintf(b, sizeof(b), "%s/%s", ref, trig[k]);
            FILE *fr = fopen(b, "rb");
            uint16_t *tb = (uint16_t *)malloc(tn * sizeof(uint16_t));
            char a[4096];
            snprintf(a, sizeof(a), "%s/%s", dir, trig[k]);
            FILE *fa = tb ? fopen(a, "rb") : NULL;
            if (!fr || !fa || fread(tb, 2, tn, fa) != tn) {
                printf("FEEDS_TRIG_REF %s (ref/generated missing — info skipped)\n", trig[k]);
            } else {
                size_t ndiff = 0;
                uint16_t hb;
                for (size_t i = 0; i < tn; i++) {
                    if (fread(&hb, 2, 1, fr) != 1) { ndiff = (size_t)-1; break; }
                    if (hb != tb[i]) ndiff++;
                }
                if (ndiff == (size_t)-1) {
                    printf("FEEDS_TRIG_REF %s ref short read (non-gating)\n", trig[k]);
                } else {
                    printf("FEEDS_TRIG_REF %s ndiff_vs_fp32ref=%zu (info)\n", trig[k], ndiff);
                }
            }
            if (fa) fclose(fa);
            if (fr) fclose(fr);
            free(tb);
        }
    } else {
        printf("FEEDS_NOTICE no ref_dir — layout-only mode\n");
    }

    /* ---- trig 真值执法（[F2 review fix]，恒跑，不依赖 ref）----
     * oracle = float64 真值：angle 用与 hyb_feeds.c:hyb_feeds_gen_rope
     * 完全相同的 double 公式重算（inv[j]=theta^(-2j/hd)，
     * pos=pos_base+c*s+i，ang=pos*inv[j%half]），cos/sin 以 double 计，
     * 经编译器单步 double→_Float16 RN-even 得 fp16 位型真值；生成表与
     * 真值的 fp16 rank-ulp 距 >1 即 FAIL。旧实现只与 fp32 复刻表计数、
     * 从不执法（gt1ulp>0 也过），1-ulp 边界从未被检验——判法与实证见
     * E:/MyLLM_exp/hyb_d/trig_truth_probe.py（float64 真值参照系）。 */
    {
        const char *trig[] = { "d2q_cos_table.raw", "d2q_sin_table.raw" };
        const int   half = hd / 2;
        const size_t tn = (size_t)chunks * hd * s;
        double *inv = (double *)malloc((size_t)half * sizeof(double));
        uint16_t *tb = (uint16_t *)malloc(tn * sizeof(uint16_t));
        if (!inv || !tb) {
            fprintf(stderr, "FEEDS_FAIL trig oracle oom\n");
            free(inv); free(tb);
            return 1;
        }
        for (int j = 0; j < half; j++) {
            inv[j] = pow(theta, -2.0 * (double)j / (double)hd);
        }
        for (size_t k = 0; k < 2; k++) {
            char a[4096];
            snprintf(a, sizeof(a), "%s/%s", dir, trig[k]);
            FILE *fa = fopen(a, "rb");
            size_t gt1 = 0, first = (size_t)-1;
            double maxd = 0.0;
            if (!fa || fread(tb, 2, tn, fa) != tn) {
                printf("FEEDS_TRIG_FAIL %s (missing/short)\n", trig[k]);
                if (fa) fclose(fa);
                fail = 1;
                continue;
            }
            fclose(fa);
            for (int c = 0; c < chunks; c++) {
                for (int i = 0; i < s; i++) {
                    double pos = (double)(p0 + (long long)(c * s + i));
                    for (int j = 0; j < hd; j++) {
                        double ang = pos * inv[j % half];
                        double truth = (k == 0) ? cos(ang) : sin(ang);
                        _Float16 th = (_Float16)truth;      /* 单步 RN-even */
                        uint16_t tbits; memcpy(&tbits, &th, 2);
                        uint16_t ob = tb[((size_t)c * hd + (size_t)j) * (size_t)s + (size_t)i];
                        if (ob == tbits) continue;
                        int ro = (int)(ob & 0x7FFFu);   if (ob & 0x8000u) ro = -ro;
                        int rt = (int)(tbits & 0x7FFFu); if (tbits & 0x8000u) rt = -rt;
                        long dist = labs((long)ro - (long)rt);
                        if (dist > 1) {
                            if (gt1 == 0) first = (size_t)c * hd * s + (size_t)j * s + i;
                            gt1++;
                        }
                        _Float16 oh; memcpy(&oh, &ob, 2);
                        double d = fabs(truth - (double)oh);
                        if (d > maxd) maxd = d;
                    }
                }
            }
            printf("FEEDS_TRIG_TRUTH %s halfs=%zu gt1ulp=%zu maxabsdiff=%.6g first_bad=%zd\n",
                   trig[k], tn, gt1, maxd, (ptrdiff_t)first);
            if (gt1 > 0) fail = 1;   /* F2：>1 fp16 rank-ulp 即执法 */
        }
        free(tb); free(inv);
    }

    if (fail) { printf("FEEDS_FAIL\n"); return 1; }
    printf("FEEDS_OK\n");
    return 0;
}
