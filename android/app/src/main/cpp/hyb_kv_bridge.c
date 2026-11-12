/*
 * [npu-line M2 Phase C] NPU prefill KV -> llama.cpp sequence-state bridge.
 * See hyb_kv_bridge.h for the frozen spec this implements (plan §6.1/§6.2).
 *
 * Acceptance: host gcc build must produce byte-identical output to the frozen
 * Python reference (npu-line/probe_m1/dec2/mcp5_95_kv_bridge.py) on the
 * Phase A samples — run hyb_kv_bridge_selftest.sh.
 */
#include "hyb_kv_bridge.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#ifdef _WIN32
#include <io.h> /* _commit/_fileno for the fsync shim below */
#else
#include <unistd.h> /* fsync/fileno on POSIX (Bionic/NDK, glibc) */
#endif

#define HYB_PATH_MAX 4096

/* portable file flush-to-disk (host mingw uses _commit/_fileno) */
#ifdef _WIN32
#define hyb_fsync _commit
#define hyb_fileno _fileno
#else
#define hyb_fsync fsync
#define hyb_fileno fileno
#endif

/* ------------------------------------------------------------------ */
/* little-endian writers (host x86_64 and target arm64 are both LE;   */
/* assemble by hand so the same TU is endian-clean everywhere)        */
/* ------------------------------------------------------------------ */

static int w_u32(FILE *f, uint32_t v)
{
    unsigned char b[4];
    b[0] = (unsigned char)(v);        b[1] = (unsigned char)(v >> 8);
    b[2] = (unsigned char)(v >> 16);  b[3] = (unsigned char)(v >> 24);
    return fwrite(b, 1, 4, f) == 4;
}

static int w_i32(FILE *f, int32_t v) { return w_u32(f, (uint32_t)v); }

static int w_u64(FILE *f, uint64_t v)
{
    unsigned char b[8];
    int i;
    for (i = 0; i < 8; i++) {
        b[i] = (unsigned char)(v >> (8 * i));
    }
    return fwrite(b, 1, 8, f) == 8;
}

/* ------------------------------------------------------------------ */
/* per-layer raw loading + row transform                               */
/* ------------------------------------------------------------------ */

/* Load one per-layer tensor file ([nc][hd][nkv] fp16) fully into memory.
 * Returns a malloc'd uint16_t (fp16 bit pattern) buffer, or NULL. */
static uint16_t *load_layer(const char *dir, const char *fmt, int layer,
                            size_t n_elems, const char *what,
                            char *err, size_t errlen)
{
    char path[HYB_PATH_MAX];
    char leaf[HYB_PATH_MAX / 2];
    FILE *f;
    long sz;
    size_t got;
    uint16_t *buf;

    /* dir + '/' + fmt with the layer index substituted */
    if (!fmt || !strchr(fmt, '%')) {
        snprintf(err, errlen, "%s format must contain one %%d (layer index)", what);
        return NULL;
    }
    if (snprintf(leaf, sizeof(leaf), fmt, layer) >= (int)sizeof(leaf)) {
        snprintf(err, errlen, "%s file name too long (layer %d)", what, layer);
        return NULL;
    }
    if (snprintf(path, sizeof(path), "%s/%s", dir, leaf) >= (int)sizeof(path)) {
        snprintf(err, errlen, "%s path too long (layer %d)", what, layer);
        return NULL;
    }

    f = fopen(path, "rb");
    if (!f) {
        snprintf(err, errlen, "cannot open %s file %s", what, path);
        return NULL;
    }
    if (fseek(f, 0, SEEK_END) != 0) {
        fclose(f);
        snprintf(err, errlen, "cannot size %s file %s", what, path);
        return NULL;
    }
    sz = ftell(f);
    if (sz < 0 || (size_t)sz != n_elems * 2u) {
        fclose(f);
        snprintf(err, errlen, "%s file %s: size %ld != %lu (want nc*hd*nkv fp16)",
                 what, path, sz, (unsigned long)(n_elems * 2u));
        return NULL;
    }
    if (fseek(f, 0, SEEK_SET) != 0) {
        fclose(f);
        snprintf(err, errlen, "cannot rewind %s file %s", what, path);
        return NULL;
    }
    buf = (uint16_t *)malloc(n_elems * 2u);
    if (!buf) {
        fclose(f);
        snprintf(err, errlen, "OOM loading %s file %s", what, path);
        return NULL;
    }
    got = fread(buf, 2, n_elems, f);
    fclose(f);
    if (got != n_elems) {
        free(buf);
        snprintf(err, errlen, "short read on %s file %s", what, path);
        return NULL;
    }
    return buf;
}

/*
 * Emit cell_count rows of one layer into `out`.
 *
 * Source tensor is [nc][hd][nkv] fp16 (kv-head fastest). Head j of token t =
 * raw[(t*hd + d)*nkv + j], d = 0..hd-1  (stride-nkv gather, exactly numpy
 * a[t, :, j] in the Python reference).
 *
 * Row = concat_j  head_j_out, where head_out is
 *   half2inter: out[0::2] = x[:hd/2]; out[1::2] = x[hd/2:]   (K, frozen)
 *   plain     : out = x                                      (V, frozen)
 * Both are pure permutations/copies of the fp16 *bit patterns* — no
 * arithmetic, so the numpy fp16->fp32->fp16 round-trip in the reference is
 * reproduced bit-exactly.
 */
static int write_layer(FILE *out, const uint16_t *raw, int hd, int nkv,
                       int n_real, int h2i, char *err, size_t errlen)
{
    const size_t row_elems = (size_t)hd * (size_t)nkv;
    uint16_t *row = (uint16_t *)malloc(row_elems * 2u);
    int t, j, d;
    int ok = 1;

    if (!row) {
        snprintf(err, errlen, "OOM allocating row staging buffer");
        return HYB_ERR_INTERNAL;
    }
    if (!w_i32(out, (int32_t)HYB_KV_TYPE_F16) || !w_u64(out, (uint64_t)(row_elems * 2u))) {
        free(row);
        snprintf(err, errlen, "layer table write failed");
        return HYB_ERR_IO;
    }
    for (t = 0; t < n_real && ok; t++) {
        for (j = 0; j < nkv; j++) {
            const uint16_t *src = raw + (size_t)t * (size_t)hd * (size_t)nkv;
            uint16_t *dst = row + (size_t)j * (size_t)hd;
            if (h2i) {
                const int half = hd / 2;
                for (d = 0; d < half; d++) {
                    dst[2 * d]     = src[(size_t)(d) * nkv + j];
                    dst[2 * d + 1] = src[(size_t)(d + half) * nkv + j];
                }
            } else {
                for (d = 0; d < hd; d++) {
                    dst[d] = src[(size_t)d * nkv + j];
                }
            }
        }
        if (fwrite(row, 2, row_elems, out) != row_elems) {
            ok = 0;
        }
    }
    free(row);
    if (!ok) {
        snprintf(err, errlen, "row write failed");
        return HYB_ERR_IO;
    }
    return HYB_OK;
}

/* ------------------------------------------------------------------ */
/* public entry                                                        */
/* ------------------------------------------------------------------ */

int hyb_kv_bridge_convert(const hyb_kv_params *p, char *err, size_t errlen)
{
    int n_layers, nc, hd, nkv, i, ver, rc = HYB_OK;
    long long t;
    size_t n_elems, got;
    int32_t *ids = NULL;
    FILE *idsf = NULL, *out = NULL;
    char ids_msg[128];

    if (err && errlen) {
        err[0] = '\0';
    }
#define HYB_FAIL(code, ...)                                            \
    do {                                                               \
        rc = (code);                                                   \
        if (err && errlen) snprintf(err, errlen, __VA_ARGS__);         \
        goto done;                                                     \
    } while (0)

    if (!p || !p->kv_dir || !p->ids_path || !p->out_path) {
        HYB_FAIL(HYB_ERR_BAD_PARAM, "kv_dir/ids_path/out_path required");
    }
    n_layers = p->n_layers ? p->n_layers : HYB_NL_DEFAULT;
    hd       = p->hd       ? p->hd       : HYB_HD_DEFAULT;
    nkv      = p->nkv      ? p->nkv      : HYB_NKV_DEFAULT;
    nc       = p->nc;
    ver      = p->state_ver ? p->state_ver : HYB_BRIDGE_DEFAULT_VER;
    if (n_layers <= 0 || hd <= 0 || (hd & 1) || nkv <= 0) {
        HYB_FAIL(HYB_ERR_BAD_PARAM, "n_layers/hd(even)/nkv invalid");
    }
    if (ver < HYB_STATE_VER_MIN || ver > HYB_STATE_VER_MAX) {
        HYB_FAIL(HYB_ERR_BAD_PARAM, "state_ver %d outside [%d,%d]",
                 ver, HYB_STATE_VER_MIN, HYB_STATE_VER_MAX);
    }
    if (nc <= 0 || p->n_real < 1 || p->n_real > nc) {
        HYB_FAIL(HYB_ERR_BAD_PARAM, "need 1 <= n_real <= nc (%d)", nc);
    }
    if (p->pos_base < 0 || p->pos_base + p->n_real - 1 > 2147483647LL) {
        HYB_FAIL(HYB_ERR_BAD_PARAM, "pos_base+n_real exceeds i32 range");
    }
    n_elems = (size_t)nc * (size_t)hd * (size_t)nkv;

    /* ---- ids: little-endian i32, n_real entries ---- */
    idsf = fopen(p->ids_path, "rb");
    if (!idsf) {
        HYB_FAIL(HYB_ERR_IO, "cannot open ids file %s", p->ids_path);
    }
    ids = (int32_t *)malloc((size_t)p->n_real * 4u);
    if (!ids) {
        HYB_FAIL(HYB_ERR_INTERNAL, "OOM reading ids");
    }
    got = fread(ids, 4, (size_t)p->n_real, idsf);
    if (got != (size_t)p->n_real) {
        snprintf(ids_msg, sizeof(ids_msg), "ids file %s: short read", p->ids_path);
        HYB_FAIL(HYB_ERR_FORMAT, "%s", ids_msg);
    }
    fclose(idsf);
    idsf = NULL;

    /* ---- output container ---- */
    out = fopen(p->out_path, "wb");
    if (!out) {
        HYB_FAIL(HYB_ERR_IO, "cannot create %s", p->out_path);
    }

    /* header: magic, ver, n_tok, tokens, n_stream=1, cell_count */
    if (!w_u32(out, HYB_STATE_MAGIC) || !w_u32(out, (uint32_t)ver) ||
        !w_u32(out, (uint32_t)p->n_real)) {
        HYB_FAIL(HYB_ERR_IO, "header write failed");
    }
    if (fwrite(ids, 4, (size_t)p->n_real, out) != (size_t)p->n_real) {
        HYB_FAIL(HYB_ERR_IO, "tokens write failed");
    }
    if (!w_u32(out, 1u) /* n_stream */ || !w_u32(out, (uint32_t)p->n_real) /* cell_count */) {
        HYB_FAIL(HYB_ERR_IO, "stream/cell_count write failed");
    }
    /* per-cell meta: {i32 pos, u32 n_seq=1, i32 sids x n_seq}; token order */
    for (t = 0; t < (long long)p->n_real; t++) {
        if (!w_i32(out, (int32_t)(p->pos_base + t)) ||
            !w_u32(out, 1u) /* n_seq */ ||
            !w_i32(out, 0)  /* sids[0] = seq 0 */) {
            HYB_FAIL(HYB_ERR_IO, "cell meta write failed");
        }
    }
    /* v_trans=0 (save_file path carries no io_magic — plan §6.1).
     * v4 (lc fork c1a2cb0 = App lineage) adds n_rot_k/n_rot_v after n_layer
     * (llama-kv-cache.cpp:2703); F16 cache => attn_rot off => both 0. */
    if (!w_u32(out, 0u) || !w_u32(out, (uint32_t)n_layers)) {
        HYB_FAIL(HYB_ERR_IO, "v_trans/n_layer write failed");
    }
    if (ver >= 4 && (!w_u32(out, 0u) /* n_rot_k */ || !w_u32(out, 0u) /* n_rot_v */)) {
        HYB_FAIL(HYB_ERR_IO, "n_rot_k/n_rot_v write failed");
    }

    /* ---- K for all layers, then V for all layers (interleaved table+data) ---- */
    for (i = 0; i < n_layers; i++) {
        uint16_t *raw = load_layer(p->kv_dir,
                                   p->kc_fmt ? p->kc_fmt : "d2q_kc_%d.raw",
                                   i, n_elems, "kc", err, errlen);
        if (!raw) {
            rc = HYB_ERR_IO;
            goto done;
        }
        rc = write_layer(out, raw, hd, nkv, p->n_real, 1 /* K: half2inter */,
                         err, errlen);
        free(raw);
        if (rc != HYB_OK) {
            goto done;
        }
    }
    for (i = 0; i < n_layers; i++) {
        uint16_t *raw = load_layer(p->kv_dir,
                                   p->vc_fmt ? p->vc_fmt : "d2q_vc_%d.raw",
                                   i, n_elems, "vc", err, errlen);
        if (!raw) {
            rc = HYB_ERR_IO;
            goto done;
        }
        rc = write_layer(out, raw, hd, nkv, p->n_real,
                         p->v_h2i /* V: plain copy in the frozen recipe */,
                         err, errlen);
        free(raw);
        if (rc != HYB_OK) {
            goto done;
        }
    }

    if (fflush(out) != 0 || hyb_fsync(hyb_fileno(out)) != 0) {
        HYB_FAIL(HYB_ERR_IO, "flush failed");
    }

done:
    if (idsf) {
        fclose(idsf);
    }
    free(ids);
    if (out) {
        fclose(out);
        if (rc != HYB_OK) {
            remove(p->out_path); /* no half-written containers */
        }
    }
#undef HYB_FAIL
    return rc;
}
