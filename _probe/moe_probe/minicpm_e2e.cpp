// End-to-end MiniCPM split-MoE harness for on-device A/B isolation.
// Usage: minicpm_e2e <model.gguf> <experts_manifest_path|""> <ngl> <n_predict> [bank]
//
// [dspark M3] Speculative A/B modes (mirrors the app's JNI wiring 1:1):
//   E2E_DRAFT=<dspark.gguf>  draft-dspark speculative loop
//   E2E_PLAIN_COMMON=1       matched plain loop (common sampler chain, same ctx)
//   E2E_NBATCH=<n>           n_batch for spec/matched mode (default 512)
//   E2E_TEMP / E2E_TOPP / E2E_SEED   sampler params (temp 0 = greedy gate)
//   E2E_TOKDUMP=<path>       write generated token ids (binary i32) for diffing
//   E2E_ADAPTIVE=1           JNI adaptive n_draft logic on (default: fixed)
#include "llama.h"
#include "ggml.h"
#include "ggml-backend.h"
#include "common/common.h"
#include "common/sampling.h"
#include "common/speculative.h"
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <cmath>
#include <map>
#include <set>
#include <string>
#include <vector>
#include <chrono>
#include <csignal>
#include <unistd.h>
#include <dlfcn.h>
#include <unwind.h>

// SIGSEGV/SIGBUS backtrace (bionic lacks backtrace())
struct bt_ctx { int n; uintptr_t pcs[24]; };
static _Unwind_Reason_Code bt_cb(struct _Unwind_Context * ctx, void * ud) {
    bt_ctx * b = (bt_ctx *) ud;
    if (b->n < 24) b->pcs[b->n++] = _Unwind_GetIP(ctx);
    return _URC_NO_REASON;
}
static void crash_handler(int) {
    static const char * msg = "\n=== CRASH ===\n";
    (void) write(2, msg, strlen(msg));
    bt_ctx b = {};
    _Unwind_Backtrace(bt_cb, &b);
    char line[256];
    for (int i = 0; i < b.n; ++i) {
        Dl_info info = {};
        int ok = dladdr((void *) b.pcs[i], &info);
        int len;
        if (ok && info.dli_fname && info.dli_sname) {
            len = snprintf(line, sizeof(line), "  #%02d %s(%s) off=%lx\n", i,
                info.dli_fname, info.dli_sname,
                (unsigned long)((uintptr_t)b.pcs[i] - (uintptr_t)info.dli_fbase));
        } else if (ok && info.dli_fname) {
            len = snprintf(line, sizeof(line), "  #%02d %s+0x%lx\n", i, info.dli_fname,
                (unsigned long)((uintptr_t)b.pcs[i] - (uintptr_t)info.dli_fbase));
        } else {
            len = snprintf(line, sizeof(line), "  #%02d pc=%lx\n", i, (unsigned long)b.pcs[i]);
        }
        (void) write(2, line, len);
    }
    _exit(139);
}

static double envd(const char * k, double dflt) {    const char * v = getenv(k);
    return v ? atof(v) : dflt;
}

using clk = std::chrono::steady_clock;
static double ms_since(const clk::time_point & t) {
    return std::chrono::duration<double, std::milli>(clk::now() - t).count();
}

// ---- per-node norm audit (E2E_CBD) ----
struct CbdState { bool armed = false; bool done = false; int dumped = 0;
                  bool cache_audit_done = false;
                  const ggml_tensor * cr38 = nullptr, * cs38 = nullptr,
                                    * cr39 = nullptr, * cs39 = nullptr;
                  std::set<std::string> seen_cache;
                  std::set<std::string> seen_w;
                  // [dspark 2026-10-18] per-base-name occurrence counter for
                  // CPY write-back audits; NOT cleared on decode re-arm so
                  // prefill occ 22 (= last prefill write, n_batch=1) and the
                  // following decode occs share one sequence.
                  std::map<std::string, int> cpy_occ;
                  std::map<std::string, int> rows_occ;
                  const char * dump_names = nullptr;
                  const char * wdump_names = nullptr;
                  char dump_dir[32] = "cpu"; };
static CbdState g_cbd;

static void cbd_audit_cache_pristine(const ggml_tensor * c, const char * tag) {
    if (!c || c->type != GGML_TYPE_F32) return;
    const int64_t row_n = c->ne[0];
    const size_t rn = (size_t) row_n * sizeof(float);
    static std::vector<char> cb2;
    cb2.resize(rn);
    ggml_backend_tensor_get(c, cb2.data(), 0, rn);
    const float * v = (const float *) cb2.data();
    long nz = 0, nn = 0, big = 0;
    for (int64_t i = 0; i < row_n; i++) {
        if (v[i] == 0.0f) continue;
        nz++;
        if (std::isnan(v[i])) nn++;
        else if (fabsf(v[i]) > 1e30f) big++;
    }
    fprintf(stderr, "[cbd]   c-pre(%s) %-20s buf=%s row_n=%lld nonzero=%ld nan=%ld big=%ld\n",
            tag, c->name, ggml_backend_buffer_name(c->buffer), (long long) row_n, nz, nn, big);
    // fingerprint: where does garbage start, and what do the raw words look like
    if (nz || nn || big) {
        long first_nz = -1;
        for (int64_t i = 0; i < row_n; i++) {
            if (v[i] != 0.0f) { first_nz = (long) i; break; }
        }
        fprintf(stderr, "[cbd]     fp first_nz=%ld raw32:", first_nz);
        for (int k = 0; k < 8 && first_nz + k < row_n; k++) {
            uint32_t w; memcpy(&w, &v[first_nz + k], 4);
            fprintf(stderr, " %08x", w);
        }
        // contiguity: count nonzero runs
        long runs = 0; bool inrun = false;
        for (int64_t i = 0; i < row_n; i++) {
            bool bad = (v[i] != 0.0f);
            if (bad && !inrun) { runs++; inrun = true; }
            else if (!bad) inrun = false;
        }
        fprintf(stderr, " | runs=%ld\n", runs);
    }
}

// [dspark 2026-10-17] root-cause-C helpers -----------------------------------
// view/permuted nodes: ggml_backend_tensor_get on them SIGSEGVs (offset/stride
// of a not-yet-assigned view). Name convention: views carry "(" in their name.
static bool cbd_is_view_node(const ggml_tensor * t) {
    return t->src[0] && strstr(t->name, "(");
}
static float cbd_f16_val(uint16_t h) {
    const uint32_t sign = (h >> 15) & 1, exp = (h >> 10) & 0x1f, man = h & 0x3ff;
    float val;
    if (exp == 0) val = (man ? ldexpf((float) man, -24) : 0.0f);
    else if (exp == 31) val = (man ? NAN : INFINITY);
    else val = ldexpf((float)(man | 0x400), (int) exp - 25);
    return sign ? -val : val;
}
// f16 buffer audit: global stats + NaN row histogram + raw words around first NaN
static void cbd_audit_f16_buf(const char * tag, const char * name, int64_t ne0, int64_t ne1,
                              const char * bname, const uint16_t * v, size_t n) {
    long nz = 0, nnan = 0, ninf = 0, nbig = 0; long first_bad = -1;
    for (size_t i = 0; i < n; i++) {
        const float x = cbd_f16_val(v[i]);
        if (x == 0.0f) continue;
        nz++;
        if (std::isnan(x)) { nnan++; if (first_bad < 0) first_bad = (long) i; }
        else if (std::isinf(x)) ninf++;
        else if (fabsf(x) > 1e30f) nbig++;
    }
    fprintf(stderr, "[cbd]   f16(%s) %-34s ne=[%lld,%lld] buf=%s nonzero=%ld nan=%ld inf=%ld big=%ld first_bad=%ld\n",
            tag, name, (long long) ne0, (long long) ne1, bname, nz, nnan, ninf, nbig, first_bad);
    if (first_bad < 0) return;
    const int64_t rn = ne0 > 0 ? ne0 : 1;
    const long bad_row = first_bad / (long) rn;
    const long bad_col = first_bad % (long) rn;
    long bad_rows = 0;
    for (long r = 0; r * rn < (long) n; r++) {
        for (int64_t i = 0; i < rn && r * rn + i < (long) n; i++) {
            if (std::isnan(cbd_f16_val(v[r * rn + i]))) { bad_rows++; break; }
        }
    }
    fprintf(stderr, "[cbd]     f16 bad_rows=%ld bad_row=%ld bad_col=%ld raw@bad:", bad_rows, bad_row, bad_col);
    for (int k = -2; k < 8; k++) {
        const long idx = first_bad + k;
        if (idx >= 0 && idx < (long) n) fprintf(stderr, " %04x", v[idx]);
    }
    fprintf(stderr, "\n");
}
static void cbd_audit_f16(const ggml_tensor * t, const char * tag) {
    const size_t nb = std::min<size_t>(ggml_nbytes(t), (32u << 20));
    static std::vector<char> buf;
    buf.resize(nb);
    ggml_backend_tensor_get(t, buf.data(), 0, nb);
    cbd_audit_f16_buf(tag, t->name, t->ne[0], t->ne[1],
                      ggml_backend_buffer_name(t->buffer), (const uint16_t *) buf.data(), nb / 2);
}

static bool e2e_cb_eval(ggml_tensor * t, bool ask, void *) {
    if (!g_cbd.armed || g_cbd.done) return false;
    // [dspark 2026-10-18] E2E_CBD_ONLY=<substr>: audit (and therefore force a
    // blocking readback = queue sync) ONLY on nodes whose name contains the
    // substring. Bisects the minimal synchronization point that keeps the GPU
    // leg's logits correct — every audited node acts as a clFinish.
    static const char * cbd_only = getenv("E2E_CBD_ONLY");
    static const bool   have_only = cbd_only && cbd_only[0];
    if (have_only && !strstr(t->name, cbd_only)) return false;
    // [dspark 2026-10-18] E2E_CBD_STRIDE=<n>: ask=true only on every n-th
    // armed node — bisects the minimum segmentation granularity that keeps
    // the GPU leg correct. Stride=1 == full per-node segmentation (healthy);
    // the coarser the stride, the closer to the broken whole-graph submit.
    // Counts only nodes that pass ONLY/LMAX filters so runs compose.
    static const char * cbd_stride_s = getenv("E2E_CBD_STRIDE");
    static const int    cbd_stride = cbd_stride_s ? atoi(cbd_stride_s) : 1;
    static int cbd_stride_cnt = 0;
    if (cbd_stride > 1) {
        if (++cbd_stride_cnt % cbd_stride != 1) return false;
    }
    // [dspark 2026-10-18] E2E_CBD_LMAX=<n>: only audit nodes whose name ends
    // with -<m> where m <= n. Nodes without a -<m> suffix are skipped. Layer
    // bisection for the minimal sync set.
    static const char * cbd_lmax_s = getenv("E2E_CBD_LMAX");
    static const int    cbd_lmax = cbd_lmax_s ? atoi(cbd_lmax_s) : -1;
    if (cbd_lmax >= 0) {
        const char * nm = t->name;
        size_t len = strlen(nm);
        if (len > 2 && nm[len-2] == '-') {
            int L = atoi(nm + len - 1);
            if (L > cbd_lmax) return false;
        } else {
            return false;  // no layer suffix: skip under LMAX mode
        }
    }
    // [dspark 2026-10-18] CPY-dst write-back audit. The state write-backs end
    // in ggml_cpy(src0=state_last, src1=cache view); on ask=true opt the CPY
    // node in (own graph view + backend sync), then on ask=false read the dst
    // view region = exactly what the cpy just landed in the cache buffer.
    // Occurrence numbering is per base name and shared across prefill+decode:
    // with n_batch=1 prefill is 22 single-token decode calls, so occ 22 =
    // call-22's write — the last prefill write gen-1 reads back.
    if (t->op == GGML_OP_CPY && t->src[1] && t->src[1]->view_src &&
        strstr(t->src[1]->view_src->name, "cache_")) {
        if (ask) return true;
        const ggml_tensor * dst  = t->src[1];
        const ggml_tensor * base = dst->view_src;
        const size_t off = (size_t) dst->view_offs;
        const size_t nb  = std::min<size_t>(ggml_nbytes(dst), (32u << 20));
        static std::vector<char> cbuf;
        cbuf.resize(nb);
        ggml_backend_tensor_get(base, cbuf.data(), off, nb);
        const size_t n = nb / sizeof(float);
        const float * v = (const float *) cbuf.data();
        double ss = 0; long nz = 0, nnan = 0;
        for (size_t i = 0; i < n; i++) {
            ss += (double) v[i] * v[i];
            if (v[i] == 0.0f) nz++;
            if (std::isnan(v[i])) nnan++;
        }
        const int occ = ++g_cbd.cpy_occ[base->name];
        fprintf(stderr, "[cpy] %-16s occ=%-3d ne=[%lld,%lld] off=%zu nb=%zu buf=%s rms=%.6g zero=%ld/%zu nan=%ld src0=%s\n",
                base->name, occ, (long long) dst->ne[0], (long long) dst->ne[1],
                off, nb, ggml_backend_buffer_name(base->buffer),
                n ? sqrt(ss / (double) n) : 0.0, nz, n, nnan,
                t->src[0] ? t->src[0]->name : "-");
        // [dspark 2026-10-18] src0 read at the same instant: splits "src0 was
        // already bad" vs "cpy execution lost the data". Raw byte dumps of both
        // sides for the first E2E_CPYDUMP_N occurrences give the zero-region
        // map and a cache-vs-src segment diff.
        std::vector<char> sbuf;
        if (t->src[0] && t->src[0]->buffer) {
            const ggml_tensor * s0 = t->src[0];
            const size_t snb = std::min<size_t>(ggml_nbytes(s0), (32u << 20));
            sbuf.resize(snb);
            ggml_backend_tensor_get(s0, sbuf.data(), 0, snb);
            const size_t n0 = snb / sizeof(float);
            const float * sv = (const float *) sbuf.data();
            double ss0 = 0; long nz0 = 0, nnan0 = 0;
            for (size_t i = 0; i < n0; i++) {
                ss0 += (double) sv[i] * sv[i];
                if (sv[i] == 0.0f) nz0++;
                if (std::isnan(sv[i])) nnan0++;
            }
            fprintf(stderr, "[cpy]   src0 %-14s ne=[%lld,%lld] buf=%s type=%d rms=%.6g zero=%ld/%zu nan=%ld\n",
                    s0->name, (long long) s0->ne[0], (long long) s0->ne[1],
                    ggml_backend_buffer_name(s0->buffer), (int) s0->type,
                    n0 ? sqrt(ss0 / (double) n0) : 0.0, nz0, n0, nnan0);
            static const int cpydump_n = [] { const char * e = getenv("E2E_CPYDUMP_N"); return e ? atoi(e) : 0; }();
            if (cpydump_n && occ <= cpydump_n) {
                char fn[320];
                snprintf(fn, sizeof(fn), "/data/local/tmp/cbddump/%s/cpy%03d_%s_src.bin", g_cbd.dump_dir, occ, base->name);
                FILE * f = fopen(fn, "wb"); if (f) { fwrite(sbuf.data(), 1, sbuf.size(), f); fclose(f); }
                snprintf(fn, sizeof(fn), "/data/local/tmp/cbddump/%s/cpy%03d_%s_dst.bin", g_cbd.dump_dir, occ, base->name);
                f = fopen(fn, "wb"); if (f) { fwrite(cbuf.data(), 1, cbuf.size(), f); fclose(f); }
            }
        }
        return true;
    }
    // [dspark 2026-10-18] GET_ROWS gather audit: build_rs reads the RS cache
    // through get_rows(cache view, s_copy idx). Batch-mode smoking gun: layers
    // >= 1 gather reads zero while layer 0 (buffer offset 0) accumulates fine.
    // Opt the gather node in on ask=true (own graph view + sync), then on
    // ask=false read its OUTPUT (what the conv chain gets as "old state") AND
    // the src0 view region it claims to read — a mismatch = kernel reads the
    // wrong region; output zero + src nonzero = same conclusion.
    if (t->op == GGML_OP_GET_ROWS && t->src[0] && strstr(t->src[0]->name, "cache_")) {
        if (ask) return true;
        const ggml_tensor * gout = t;
        const ggml_tensor * sview = t->src[0];
        const ggml_tensor * sbase = sview->view_src ? sview->view_src : sview;
        const size_t soff = sview->view_src ? (size_t) sview->view_offs : 0;
        static std::vector<char> gbuf, rsbuf;
        const size_t gnb = std::min<size_t>(ggml_nbytes(gout), (32u << 20));
        gbuf.resize(gnb);
        ggml_backend_tensor_get(gout, gbuf.data(), 0, gnb);
        const size_t snb = std::min<size_t>(ggml_nbytes(sview), (32u << 20));
        rsbuf.resize(snb);
        ggml_backend_tensor_get(sbase, rsbuf.data(), soff, snb);
        auto stats = [](const char * d, size_t nb, double * rms, long * nz, long * nnan) {
            const size_t n = nb / sizeof(float);
            const float * v = (const float *) d;
            double ss = 0; long z = 0, na = 0;
            for (size_t i = 0; i < n; i++) {
                ss += (double) v[i] * v[i];
                if (v[i] == 0.0f) z++;
                if (std::isnan(v[i])) na++;
            }
            *rms = n ? sqrt(ss / (double) n) : 0.0; *nz = z; *nnan = na;
            return n;
        };
        double g_rms, s_rms; long g_nz, s_nz, g_na, s_na;
        const size_t gn = stats(gbuf.data(), gnb, &g_rms, &g_nz, &g_na);
        const size_t sn = stats(rsbuf.data(), snb, &s_rms, &s_nz, &s_na);
        // faithful-gather check: idx=0 must return the view's first row
        size_t cmp = std::min<size_t>(gn, std::min<size_t>(sn, (size_t) gout->ne[0]));
        size_t ndiff = 0;
        for (size_t i = 0; i < cmp; i++) {
            float a = ((const float *) gbuf.data())[i], b = ((const float *) rsbuf.data())[i];
            if ((a == 0.0f) != (b == 0.0f) || fabsf(a - b) > 1e-4f * (1.0f + fabsf(b))) ndiff++;
        }
        const int occ = ++g_cbd.rows_occ[sbase->name];
        fprintf(stderr, "[rows] %-16s occ=%-3d out_ne=[%lld,%lld] out_rms=%.6g out_zero=%ld/%zu | src_rms=%.6g src_zero=%ld/%zu | row0diff=%zu/%zu buf=%s out_ptr=%p src_ptr=%p\n",
                sbase->name, occ, (long long) gout->ne[0], (long long) gout->ne[1],
                g_rms, g_nz, gn, s_rms, s_nz, sn, ndiff, cmp,
                ggml_backend_buffer_name(sbase->buffer), (void *) gout->data, (void *) sview->data);
        static const int rowsdump_n = [] { const char * e = getenv("E2E_CPYDUMP_N"); return e ? atoi(e) : 0; }();
        if (rowsdump_n && occ <= rowsdump_n) {
            char fn[320];
            snprintf(fn, sizeof(fn), "/data/local/tmp/cbddump/%s/rows%03d_%s_out.bin", g_cbd.dump_dir, occ, sbase->name);
            FILE * f = fopen(fn, "wb"); if (f) { fwrite(gbuf.data(), 1, gnb, f); fclose(f); }
            snprintf(fn, sizeof(fn), "/data/local/tmp/cbddump/%s/rows%03d_%s_src.bin", g_cbd.dump_dir, occ, sbase->name);
            f = fopen(fn, "wb"); if (f) { fwrite(rsbuf.data(), 1, snb, f); fclose(f); }
        }
        return true;
    }
    // E2E_CPY_ONLY=1: audit nothing but the CPY write-backs above — keeps the
    // armed prefill (E2E_CBD_PREFILL=1) cheap enough for 22 calls.
    // NB: ask=false returning false would break the whole split node loop
    // (ggml-backend.cpp), so always true on ask=false.
    static const bool cpy_only = [] { const char * e = getenv("E2E_CPY_ONLY"); return e && e[0] == '1'; }();
    if (cpy_only) return ask ? false : true;
    if (ask) {
        // pristine cache audit: fires during sched assignment, BEFORE any compute
        if (!g_cbd.cache_audit_done) {
            const ggml_tensor * base = strstr(t->name, "(") && t->src[0] ? t->src[0] : t;
            if (strstr(base->name, "cache_r_l38")) g_cbd.cr38 = base;
            else if (strstr(base->name, "cache_s_l38")) g_cbd.cs38 = base;
            else if (strstr(base->name, "cache_r_l39")) g_cbd.cr39 = base;
            else if (strstr(base->name, "cache_s_l39")) g_cbd.cs39 = base;
            if (g_cbd.cr38) {
                cbd_audit_cache_pristine(g_cbd.cr38, "ask");
                cbd_audit_cache_pristine(g_cbd.cs38, "ask");
                cbd_audit_cache_pristine(g_cbd.cr39, "ask");
                cbd_audit_cache_pristine(g_cbd.cs39, "ask");
                g_cbd.cache_audit_done = true;
            }
        }
        // [dspark 2026-10-17] root-cause-C watch: post-prefill K/V cache pristine
        // dump. Slices views from view_src at view_offs (data pointers are not yet
        // assigned during ask, so never ggml_backend_tensor_get the view itself).
        {
            const char * nm = t->name;
            const bool is_kv = strstr(nm, "cache_v") || strstr(nm, "cache_k");
            const bool wanted = strstr(nm, "_l31") || strstr(nm, "_l27") || strstr(nm, "_l35") ||
                                strcmp(nm, "cache_v") == 0 || strcmp(nm, "cache_k") == 0;
            // permuted/transposed variants re-read the same plane at off=0 — skip
            const bool redundant = strstr(nm, "(permuted)") || strstr(nm, "(transposed)");
            if (is_kv && wanted && !redundant && g_cbd.seen_cache.insert(nm).second) {
                const ggml_tensor * base = t->view_src ? t->view_src : t;
                const size_t off = t->view_src ? (size_t) t->view_offs : 0;
                const size_t nb  = std::min<size_t>(ggml_nbytes(t), (32u << 20));
                fprintf(stderr, "[cbd]   kv-pre %-24s base=%s type=%d view=%d off=%zu nb=%zu\n",
                        nm, base->name, (int) base->type, (int) (t->view_src != nullptr), off, nb);
                if (base->type == GGML_TYPE_F16) {
                    static std::vector<char> kbuf;
                    kbuf.resize(nb);
                    ggml_backend_tensor_get(base, kbuf.data(), off, nb);
                    cbd_audit_f16_buf("pre", nm, t->ne[0], t->ne[1],
                                      ggml_backend_buffer_name(base->buffer),
                                      (const uint16_t *) kbuf.data(), nb / 2);
                }
            }
        }
        return !cbd_is_view_node(t) &&
               (t->type == GGML_TYPE_F32 || t->type == GGML_TYPE_F16) &&
               ggml_nbytes(t) <= (64u << 20);
    }
    // [dspark 2026-10-17] view/permuted nodes: readback SIGSEGVs — shape only
    if (cbd_is_view_node(t)) {
        fprintf(stderr, "[cbd] (view-skip) %-38s op=%d type=%d ne=[%lld,%lld] src0=%s\n",
                t->name, (int) t->op, (int) t->type, (long long) t->ne[0], (long long) t->ne[1],
                t->src[0] ? t->src[0]->name : "-");
        return true;
    }
    if (t->type == GGML_TYPE_F16) {   // V-cache / v_cont path (root-cause C)
        cbd_audit_f16(t, "val");
        g_cbd.dumped++;
        return true;
    }
    if (t->type != GGML_TYPE_F32) return true;
    const size_t nb = ggml_nbytes(t);
    static std::vector<char> buf;
    buf.resize(nb);
    ggml_backend_tensor_get(t, buf.data(), 0, nb);
    const size_t n = nb / sizeof(float);
    const float * v = (const float *) buf.data();
    double ss = 0; float mx = 0; long nz = 0, nnan = 0;
    for (size_t i = 0; i < n; i++) {
        ss += (double) v[i] * v[i];
        const float a = fabsf(v[i]);
        if (a > mx) mx = a;
        if (v[i] == 0.0f) nz++;
        if (std::isnan(v[i])) nnan++;
    }
    if (n == 0) return true;
    const double rms = sqrt(ss / (double) n);
    // [dspark 2026-10-18] result_output identity probe: CBD reads this node
    // correct (max ~31) while the llama-context host extraction right after
    // graph completion reads garbage. Print the data pointer + first raw
    // words so both reads can be compared for the same address.
    if (strcmp(t->name, "result_output") == 0) {
        fprintf(stderr, "[cbd-ro] ptr=%p data=%p buf=%s raw32: %08x %08x %08x %08x | max=%.4f\n",
                (const void*) t, (void*) t->data, ggml_backend_buffer_name(t->buffer),
                ((const uint32_t*) v)[0], ((const uint32_t*) v)[1],
                ((const uint32_t*) v)[2], ((const uint32_t*) v)[3], mx);
    }
    const ggml_tensor * s0 = t->src[0], * s1 = t->src[1];
    // [dspark 2026-10-17] byte-fingerprint dump (E2E_CBDDUMP=name1,name2,...)
    // writes the raw bytes of matching F32 nodes for host-side byte diff.
    if (g_cbd.dump_names && t->type == GGML_TYPE_F32) {
        const char * p = g_cbd.dump_names;
        while (*p) {
            const char * q = strchr(p, ',');
            size_t len = q ? (size_t)(q - p) : strlen(p);
            if (len && strstr(t->name, std::string(p, len).c_str())) {
                char fn[320]; char sn[256]; size_t si = 0;
                for (const char * c = t->name; *c && si < sizeof(sn) - 1; c++)
                    sn[si++] = ((*c >= 'a' && *c <= 'z') || (*c >= 'A' && *c <= 'Z') ||
                                (*c >= '0' && *c <= '9') || *c == '-' || *c == '_') ? *c : '_';
                sn[si] = 0;
                snprintf(fn, sizeof(fn), "/data/local/tmp/cbddump/%s/%04d_%s.bin",
                         g_cbd.dump_dir, g_cbd.dumped, sn);
                FILE * df = fopen(fn, "wb");
                if (df) { fwrite(buf.data(), 1, nb, df); fclose(df); }
                break;
            }
            if (!q) break;
            p = q + 1;
        }
    }
    // [dspark 2026-10-17] weight raw-byte dump (E2E_WDUMP=substr): reads src0
    // through the host pointer directly (rusticl buffers are host-mapped).
    // Complements the w-audit restore-read: catches overlay/plane mismatch.
    if (g_cbd.wdump_names && s0) {
        const char * p = g_cbd.wdump_names;
        while (*p) {
            const char * q = strchr(p, ',');
            size_t len = q ? (size_t)(q - p) : strlen(p);
            if (len && (strstr(t->name, std::string(p, len).c_str()) ||
                            strstr(s0->name, std::string(p, len).c_str())) &&
                g_cbd.seen_w.insert(s0->name).second) {
                char sn[256]; size_t si = 0;
                for (const char * c = s0->name; *c && si < sizeof(sn) - 1; c++)
                    sn[si++] = ((*c >= 'a' && *c <= 'z') || (*c >= 'A' && *c <= 'Z') ||
                                (*c >= '0' && *c <= '9') || *c == '-' || *c == '_') ? *c : '_';
                sn[si] = 0;
                char fn[320];
                snprintf(fn, sizeof(fn), "/data/local/tmp/cbddump/%s/W_%s.bin",
                         g_cbd.dump_dir, sn);
                const size_t wnb = std::min<size_t>(ggml_nbytes(s0), (16u << 20));
                // [dspark 2026-10-17] rustacl buffers are NOT host-deref-able
                // (direct s0->data fwrite produced 0-byte files) — read back via
                // the backend (restore semantics) instead; identical semantics on
                // both legs makes the diff valid.
                static std::vector<char> wbuf;
                wbuf.resize(wnb);
                ggml_backend_tensor_get(s0, wbuf.data(), 0, wnb);
                FILE * wf = fopen(fn, "wb");
                if (wf) { fwrite(wbuf.data(), 1, wnb, wf); fclose(wf); }
                fprintf(stderr, "[cbd]   wdump %s <- %s (%zu B, tensor_get)\n", fn, s0->name, wnb);
                break;
            }
            if (!q) break;
            p = q + 1;
        }
    }
    fprintf(stderr, "[cbd] %-42s op=%d ne=[%lld,%lld] rms=%.6g max=%.4g zero=%ld/%zu nan=%ld src0=%s src1=%s\n",
            t->name, (int) t->op, (long long) t->ne[0], (long long) t->ne[1],
            rms, mx, nz, n, nnan,
            s0 ? s0->name : "-", s1 ? s1->name : "-");
    // suspicious GEMV: audit the q4_K weight's per-block fp16 d field
    if (rms == 0.0 || std::isnan(rms) || nnan > 0) {
        if (s0 && s0->type == GGML_TYPE_Q4_K) {
            const size_t wnb = std::min<size_t>(ggml_nbytes(s0), (4u << 20));
            static std::vector<char> wbuf;
            wbuf.resize(wnb);
            ggml_backend_tensor_get(s0, wbuf.data(), 0, wnb);
            const size_t nblk = wnb / 144;   // block_q4_K = 144B (d@0, dmin@2, scales@4, qs@16)
            long bad_d = 0; float dmin = 1e30f, dmax = -1e30f;
            long first_bad[8]; int nfirst = 0; long last_bad = -1;
            long bucket[8] = {0};
            for (size_t b = 0; b < nblk; b++) {
                uint16_t dh; memcpy(&dh, wbuf.data() + b * 144 + 0, 2);
                // simple fp16 decode
                uint32_t sign = (dh >> 15) & 1, exp = (dh >> 10) & 0x1f, man = dh & 0x3ff;
                float val;
                if (exp == 0) val = (man ? ldexpf((float)man, -24) : 0.0f);
                else if (exp == 31) val = (man ? NAN : INFINITY);
                else val = ldexpf((float)(man | 0x400), (int)exp - 25);
                if (sign) val = -val;
                if (std::isnan(val) || std::isinf(val)) {
                    bad_d++; last_bad = (long) b;
                    int bk = (int) ((b * 8) / nblk); if (bk > 7) bk = 7; bucket[bk]++;
                    if (nfirst < 8) first_bad[nfirst++] = (long) b;
                }
                else { if (val < dmin) dmin = val; if (val > dmax) dmax = val; }
            }
            fprintf(stderr, "[cbd]   w-audit %-30s q4K d-scan: buf=%s size=%zu blocks=%zu bad_d=%ld dmin=%.5g dmax=%.5g\n",
                    s0->name, ggml_backend_buffer_name(s0->buffer), ggml_backend_buffer_get_size(s0->buffer),
                    nblk, bad_d, dmin, dmax);
            fprintf(stderr, "[cbd]     bad-idx first: ");
            for (int i = 0; i < nfirst; i++) fprintf(stderr, "%ld ", first_bad[i]);
            fprintf(stderr, "| last=%ld | dist8:", last_bad);
            for (int i = 0; i < 8; i++) fprintf(stderr, " %ld", bucket[i]);
            fprintf(stderr, " | nblk%%64=%zu\n", nblk % 64);
            // SVM direct d-plane read (bypasses restore kernel): d plane lives at
            // the tensor region start under the SoA overlay (FGSVM host-mapped).
            // [dspark 2026-10-17] raw s0->data deref SIGSEGVs when the weight buf
            // is not host-mapped — opt-in via E2E_SVMDIRECT only.
            if (getenv("E2E_SVMDIRECT") && s0->data) {
                const uint16_t * raw = (const uint16_t *) s0->data;
                long svm_bad = 0, svm_zero = 0; float smin = 1e30f, smax = -1e30f;
                long mismatch_vs_restore = 0;
                for (size_t b = 0; b < nblk; b++) {
                    uint16_t dh; memcpy(&dh, &raw[b], 2);
                    uint32_t sign = (dh >> 15) & 1, exp = (dh >> 10) & 0x1f, man = dh & 0x3ff;
                    float val;
                    if (exp == 0) val = (man ? ldexpf((float)man, -24) : 0.0f);
                    else if (exp == 31) val = (man ? NAN : INFINITY);
                    else val = ldexpf((float)(man | 0x400), (int)exp - 25);
                    if (sign) val = -val;
                    if (std::isnan(val) || std::isinf(val)) svm_bad++;
                    else if (val == 0.0f) svm_zero++;
                    else { if (val < smin) smin = val; if (val > smax) smax = val; }
                    // compare vs restore-read d
                    uint16_t rh; memcpy(&rh, wbuf.data() + b * 144 + 0, 2);
                    if (rh != dh) mismatch_vs_restore++;
                }
                fprintf(stderr, "[cbd]     svm-direct: bad=%ld zero=%ld dmin=%.5g dmax=%.5g restore_mismatch=%ld\n",
                        svm_bad, svm_zero, smin, smax, mismatch_vs_restore);
            }
        }
    }
    // cache_* state tensor bad: full row histogram + triple-read stability
    if (rms == 0.0 || std::isnan(rms) || nnan > 0) {
        const ggml_tensor * c = (s0 && strstr(s0->name, "cache_")) ? s0 : (strstr(t->name, "cache_") ? t : nullptr);
        if (c && c->type == GGML_TYPE_F32) {
            const int64_t row_n = c->ne[0];
            const int64_t nrows = std::min<int64_t>(c->ne[1], 40);
            const size_t rn = (size_t) row_n * sizeof(float);
            static std::vector<char> cbuf;
            cbuf.resize((size_t) nrows * rn);
            // triple read of the first row for stability
            static std::vector<char> r1, r2, r3;
            r1.resize(rn); r2.resize(rn); r3.resize(rn);
            ggml_backend_tensor_get(c, r1.data(), 0, rn);
            ggml_backend_tensor_get(c, r2.data(), 0, rn);
            ggml_backend_tensor_get(c, r3.data(), 0, rn);
            bool stable = memcmp(r1.data(), r2.data(), rn) == 0 && memcmp(r1.data(), r3.data(), rn) == 0;
            ggml_backend_tensor_get(c, cbuf.data(), 0, (size_t) nrows * rn);
            fprintf(stderr, "[cbd]   c-audit %-24s buf=%s row_n=%lld rows=%lld stable=%d | per-row (nonzero/nan/garbage>1e30):\n",
                    c->name, ggml_backend_buffer_name(c->buffer), (long long) row_n, (long long) nrows, (int) stable);
            for (int64_t r = 0; r < nrows; r++) {
                const float * v = (const float *)(cbuf.data() + r * rn);
                long nz = 0, nn = 0, big = 0;
                for (int64_t i = 0; i < row_n; i++) {
                    if (v[i] == 0.0f) continue;
                    nz++;
                    if (std::isnan(v[i])) nn++;
                    else if (fabsf(v[i]) > 1e30f) big++;
                }
                if (nz || nn || big)
                    fprintf(stderr, "[cbd]     row %2lld: nonzero=%ld nan=%ld big=%ld\n", (long long) r, nz, nn, big);
            }
        }
    }
    g_cbd.dumped++;
    return true;
}

int main(int argc, char ** argv) {
    if (argc < 5) {
        fprintf(stderr, "usage: %s <model.gguf> <experts_manifest|-> <ngl> <n_predict> [bank]\n", argv[0]);
        return 1;
    }
    const char * model_path = argv[1];
    const char * experts    = strcmp(argv[2], "-") == 0 ? nullptr : argv[2];
    const int    ngl        = atoi(argv[3]);
    const int    n_predict  = atoi(argv[4]);
    const int    bank       = argc > 5 ? atoi(argv[5]) : 16;

    signal(SIGSEGV, crash_handler);
    signal(SIGBUS,  crash_handler);

    // [dspark 2026-10-17] byte-fingerprint dump config
    g_cbd.dump_names = getenv("E2E_CBDDUMP");
    g_cbd.wdump_names = getenv("E2E_WDUMP");
    if (const char * d = getenv("E2E_CBDDIR")) snprintf(g_cbd.dump_dir, sizeof(g_cbd.dump_dir), "%s", d);
    if (g_cbd.dump_names || g_cbd.wdump_names) {
        char mk[96]; snprintf(mk, sizeof(mk), "mkdir -p /data/local/tmp/cbddump/%s", g_cbd.dump_dir);
        if (system(mk) != 0) fprintf(stderr, "[cbd] mkdir failed\n");
    }

    llama_backend_init();

    const char * draft_path  = getenv("E2E_DRAFT");
    const bool   spec_on     = draft_path && draft_path[0];
    const bool   plain_match = !spec_on && getenv("E2E_PLAIN_COMMON") != nullptr;
    fprintf(stderr, "[spec] mode=%s\n", spec_on ? "dspark" : (plain_match ? "plain-match" : "plain-legacy"));

    auto mparams = llama_model_default_params();
    mparams.n_gpu_layers = ngl;
    if (getenv("E2E_NOMMAP")) mparams.load_mode = LLAMA_LOAD_MODE_MLOCK;
    if (experts) {
        mparams.moe_experts_path = experts;
        mparams.moe_slot_bank    = bank;
    }

    const auto t0 = clk::now();
    llama_model * model = llama_model_load_from_file(model_path, mparams);
    if (!model) { fprintf(stderr, "FATAL: model load failed\n"); return 1; }
    const double t_load = ms_since(t0);

    const llama_vocab * vocab = llama_model_get_vocab(model);

    // draft load before ctx creation (app order: n_rs_seq sized from block size)
    llama_model * draft_model = nullptr;
    int n_draft_max = 0;
    if (spec_on) {
        auto dparams = llama_model_default_params();
        dparams.n_gpu_layers = ngl;   // app: same offload policy as the target
        if (const char * dg = getenv("E2E_DNG")) {
            dparams.n_gpu_layers = atoi(dg);   // 0 = draft on CPU (backend/sampler bisect)
        }
        draft_model = llama_model_load_from_file(draft_path, dparams);
        if (!draft_model) { fprintf(stderr, "FATAL: draft load failed: %s\n", draft_path); return 1; }
        char bbuf[32] = {};
        int blk = 16;
        if (llama_model_meta_val_str(draft_model, "dflash.block_size", bbuf, sizeof(bbuf)) >= 0) {
            blk = atoi(bbuf);
        }
        if (blk < 1) blk = 16;
        n_draft_max = blk;
        if (experts && bank > 0) {
            const int k = std::max(1, (int) llama_model_n_expert_used(model));
            const int cap = bank / k - 3;   // app clamp: verify batch must fit the bank
            if (cap < 1) { fprintf(stderr, "FATAL: bank=%d too small for dspark\n", bank); return 1; }
            if (n_draft_max > cap) n_draft_max = cap;
        }
        fprintf(stderr, "[spec] draft block=%d n_draft_max=%d\n", blk, n_draft_max);
        if (const char * nd = getenv("E2E_NDMAX")) {
            n_draft_max = std::min(n_draft_max, std::max(1, atoi(nd)));
            fprintf(stderr, "[spec] n_draft_max forced to %d\n", n_draft_max);
        }
    }

    auto cparams = llama_context_default_params();
    cparams.n_ctx = 4096;
    cparams.cb_eval = e2e_cb_eval;
    int ubatch = 1;
    if (const char * u = getenv("GGML_E2E_UBATCH")) ubatch = atoi(u);
    if (ubatch < 1) ubatch = 1;
    cparams.n_batch  = ubatch;
    cparams.n_ubatch = ubatch;
    if (getenv("E2E_TFA0")) {
        cparams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_DISABLED;
    }
    if (spec_on || plain_match) {
        // app wiring: n_batch 512, ubatch clamped to bank/k, RS slots for drafts
        const int nb = (int) envd("E2E_NBATCH", 512);
        cparams.n_batch = nb;
        int ub = nb;
        if (experts && bank > 0) {
            const int k = std::max(1, (int) llama_model_n_expert_used(model));
            ub = std::min(ub, std::max(1, bank / k));
        }
        cparams.n_ubatch = ub;
        cparams.kv_unified = true;
        cparams.type_k = GGML_TYPE_Q4_0;
        cparams.type_v = GGML_TYPE_F16;
        cparams.n_rs_seq = (int) envd("E2E_RS", spec_on ? (n_draft_max + 1) : 0);
        fprintf(stderr, "[spec] ctx n_batch=%d n_ubatch=%d n_rs_seq=%d\n",
                (int) cparams.n_batch, (int) cparams.n_ubatch, (int) cparams.n_rs_seq);
    }
    llama_context * ctx = llama_init_from_model(model, cparams);
    if (!ctx) { fprintf(stderr, "FATAL: context init failed\n"); return 1; }

    llama_context * dspark_ctx = nullptr;
    common_speculative * spec = nullptr;
    common_sampler * smpl = nullptr;
    if (spec_on) {
        auto dc = llama_context_default_params();
        dc.ctx_other  = ctx;          // mirror target hidden states
        dc.n_ctx      = cparams.n_ctx;
        dc.n_batch    = cparams.n_batch;
        dc.n_ubatch   = cparams.n_ubatch;
        // official spec-init defaults draft cache to F16 (JNI matches); E2E_DKV=0 inherits
        // the target's quantized cache for comparison runs.
        dc.type_k     = GGML_TYPE_F16;
        dc.type_v     = GGML_TYPE_F16;
        if (const char * dk = getenv("E2E_DKV")) {
            if (atoi(dk) == 0) {
                dc.type_k = cparams.type_k; dc.type_v = cparams.type_v;
            } else if (atoi(dk) == 32) {
                dc.type_k = dc.type_v = GGML_TYPE_F32;
            }
        }
        dc.n_rs_seq   = 0;
        dc.kv_unified = true;
        // dspark decodes the whole noise block in one pass and samples every row:
        // without these the decode path rejects the batch (ret=-1, empty draft).
        dc.n_outputs_max         = n_draft_max + 1;
        dc.n_outputs_max_per_seq = n_draft_max + 1;
        if (getenv("E2E_DFA0")) {
            dc.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_DISABLED;   // Adreno 740 FA build crash gate
        }
        dspark_ctx = llama_init_from_model(draft_model, dc);
        if (!dspark_ctx) { fprintf(stderr, "FATAL: dspark ctx init failed\n"); return 1; }

        common_params_speculative sp;
        sp.types = { COMMON_SPECULATIVE_TYPE_DRAFT_DSPARK };
        sp.draft.n_max   = n_draft_max;
        sp.draft.n_min   = 1;
        sp.draft.p_min   = 0.0f;      // app: full block, target decides
        sp.draft.ctx_tgt = ctx;
        sp.draft.ctx_dft = dspark_ctx;
        spec = common_speculative_init(sp, 1);
        if (!spec) { fprintf(stderr, "FATAL: common_speculative_init failed\n"); return 1; }
        fprintf(stderr, "[spec] spec driver init ok\n");
    }
    if (spec_on || plain_match) {
        common_params_sampling ss;
        ss.seed           = (uint32_t) envd("E2E_SEED", 42);
        ss.penalty_last_n = 64;
        ss.penalty_repeat = 1.1f;
        ss.top_k = 128;
        ss.top_p = (float) envd("E2E_TOPP", 0.9);
        ss.temp  = (float) envd("E2E_TEMP", 1.0);
        ss.samplers = { COMMON_SAMPLER_TYPE_PENALTIES, COMMON_SAMPLER_TYPE_TOP_K,
                        COMMON_SAMPLER_TYPE_TOP_P, COMMON_SAMPLER_TYPE_TEMPERATURE };
        smpl = common_sampler_init(model, ss);
        if (!smpl) { fprintf(stderr, "FATAL: sampler init failed\n"); return 1; }
    }

    const char * raw_prompt = "中国的首都是北京。那么中国的第二大城市的名字是什么？请用一句话简要回答。";
    std::string prompt = std::string("user\n") + raw_prompt + std::string(1, '\n')
                       + "assistant" + std::string(1, '\n');
    if (const char * ov = getenv("GGML_E2E_PROMPT")) { prompt = ov; }

    llama_tokens tokens(prompt.size() + 16);
    {
        const int32_t got = llama_tokenize(vocab, prompt.c_str(), (int32_t) prompt.size(),
                                           tokens.data(), (int32_t) tokens.size(), true, true);
        if (got < 0) { fprintf(stderr, "FATAL: tokenize got=%d\n", got); return 1; }
        tokens.resize(got);
    }
    printf("[e2e] prompt tokens: %zu\n", tokens.size());

    // ---- prefill ----
    llama_tokens prompt_tgt;             // tokens minus last (spec driver seed)
    std::vector<int32_t> gen_tokens;     // for E2E_TOKDUMP
    const llama_seq_id seq_id = 0;
    int n_gen = 0;
    int n_ctx_avail = (int32_t) llama_n_ctx(ctx);

    if (spec_on || plain_match) {
        // app prefill: chunks of n_batch minus the final token, process() per chunk
        const int nb = (int) llama_n_batch(ctx);
        const size_t n_pf = tokens.size() - 1;
        prompt_tgt.assign(tokens.begin(), tokens.begin() + n_pf);
        const auto tp0 = clk::now();
        for (size_t i = 0; i < n_pf; ) {
            const size_t n = std::min<size_t>(nb, n_pf - i);
            common_batch tb = common_batch_get_one(ctx, &tokens[i], (int) n);
            if (llama_process(ctx, LLAMA_PROCESS_TYPE_DECODE, tb.get()) != 0) { fprintf(stderr, "FATAL: prefill decode failed\n"); return 1; }
            if (spec_on && !common_speculative_process(spec, tb)) {
                fprintf(stderr, "FATAL: speculative_process failed on prefill chunk %zu\n", i); return 1;
            }
            i += n;
        }
        printf("[e2e] prefill %.0f ms (%zu tok)\n", ms_since(tp0), n_pf);

        if (spec_on) {
            common_speculative_begin(spec, seq_id, prompt_tgt);

            // ---- dspark loop (mirrors JNI 2344-2507) ----
            const bool adaptive = getenv("E2E_ADAPTIVE") != nullptr;
            llama_tokens draft;
            int n_past = (int) n_pf;              // id_last goes at pos n_pf
            llama_token id_last = tokens[n_pf];   // excluded-from-prefill last token
            int n_adaptive_max = n_draft_max;
            float accept_sum = 0, draft_sum = 0;
            double ms_draft = 0, ms_verify = 0, ms_proc = 0, ms_samp = 0, ms_rb = 0;
            int iters = 0, empty_streak = 0;
            bool spec_dead = false;
            const int max_dead_streak = 8;
            common_batch vb(ctx);
            const auto tg0 = clk::now();

            while (n_gen < n_predict) {
                const auto ti0 = clk::now();
                if (draft.empty() && !spec_dead) {
                    if (adaptive && draft_sum >= 12.0f) {
                        const float rate = accept_sum / draft_sum;
                        n_adaptive_max = (rate >= 0.35f) ? n_draft_max
                                         : (rate >= 0.20f) ? std::max(2, n_draft_max / 2) : 1;
                    }
                    const int n_max = std::max(1, std::min(n_adaptive_max,
                        (int)(n_ctx_avail - n_past - 1)));
                    common_speculative_get_draft_params(spec, seq_id) = {
                        true, n_max, n_past, id_last, &prompt_tgt, &draft,
                    };
                    common_speculative_draft(spec);
                    ms_draft += ms_since(ti0);
                    if (draft.empty()) {
                        if (++empty_streak >= max_dead_streak) spec_dead = true;
                    } else {
                        empty_streak = 0;
                        llama_memory_seq_rm(llama_get_memory(dspark_ctx), seq_id, n_past, -1);
                    }
                }
                const auto ti1 = clk::now();
                vb.clear();
                vb.add(id_last, n_past++, seq_id, true);
                for (size_t k = 0; k < draft.size(); ++k) {
                    vb.add(draft[k], n_past + k, seq_id, true);
                }
                if (llama_process(ctx, LLAMA_PROCESS_TYPE_DECODE, vb.get()) != 0) { fprintf(stderr, "FATAL: verify decode failed\n"); break; }
                ms_verify += ms_since(ti1);

                const auto ti2 = clk::now();
                if (!draft.empty() && !common_speculative_process(spec, vb)) {
                    fprintf(stderr, "FATAL: speculative_process failed on verify batch\n"); break;
                }
                ms_proc += ms_since(ti2);

                const auto ti3 = clk::now();
                auto ids = common_sampler_sample_and_accept_n(smpl, ctx, draft);
                ms_samp += ms_since(ti3);
                if (ids.empty()) break;
                // diagnostic: compare draft[i] vs greedy argmax of verify row i+1
                if (iters < 6 && !draft.empty()) {
                    fprintf(stderr, "[spec-dbg] draft[0..4]=%d %d %d %d %d\n",
                            draft.size() > 0 ? draft[0] : -1, draft.size() > 1 ? draft[1] : -1,
                            draft.size() > 2 ? draft[2] : -1, draft.size() > 3 ? draft[3] : -1,
                            draft.size() > 4 ? draft[4] : -1);
                    std::string rows;
                    const int n_shown = (int) std::min<size_t>(draft.size(), 4);
                    for (int r = 0; r < n_shown; ++r) {
                        const float * lg = llama_get_logits_ith(ctx, r);   // row r predicts draft[r]
                        int best = -1; float bv = 0;
                        if (lg) {
                            best = 0; bv = lg[0];
                            for (int t = 1; t < (int) llama_vocab_n_tokens(vocab); ++t) {
                                if (lg[t] > bv) { bv = lg[t]; best = t; }
                            }
                        }
                        char b2[48]; snprintf(b2, sizeof(b2), "row%d greedy=%d vs draft=%d %s | ",
                            r, best, draft[r], (best == draft[r]) ? "HIT" : "MISS");
                        rows += b2;
                    }
                    fprintf(stderr, "[spec-dbg] %s\n", rows.c_str());
                    fprintf(stderr, "[spec-dbg] ids=%zu ids0=%d ids1=%d\n", ids.size(), ids[0],
                            ids.size() > 1 ? ids[1] : -1);
                }
                common_speculative_accept(spec, seq_id, (uint16_t) (ids.size() - 1));
                accept_sum += (float) (ids.size() - 1);
                draft_sum  += (float) draft.size();
                iters++;

                bool hit_eos = false;
                for (size_t k = 0; k < ids.size(); ++k) {
                    const llama_token tok = ids[k];
                    if (tok == llama_vocab_eos(vocab) || llama_vocab_is_eog(vocab, tok)) { hit_eos = true; break; }
                    if (n_gen >= n_predict) break;
                    char pbuf[128];
                    const int pn = llama_token_to_piece(vocab, tok, pbuf, sizeof(pbuf), 0, false);
                    if (pn > 0) { fwrite(pbuf, 1, pn, stdout); fflush(stdout); }
                    gen_tokens.push_back(tok);
                    prompt_tgt.push_back(id_last);
                    id_last = tok;
                    n_gen++;
                }
                n_past += (int) ids.size() - 1;
                draft.clear();

                const auto ti4 = clk::now();
                // E2E_RB0=1: skip rollback (correctness invalid, isolates rollback cost)
                // E2E_RBT=1: skip only the dspark-ctx rollback
                if (!getenv("E2E_RB0")) {
                    llama_memory_seq_rm(llama_get_memory(ctx), seq_id, n_past, -1);
                    if (!getenv("E2E_RBT")) {
                        llama_memory_seq_rm(llama_get_memory(dspark_ctx), seq_id, n_past, -1);
                    }
                }
                ms_rb += ms_since(ti4);

                fprintf(stderr, "[spec] it=%d acc=%zu draft_ms=%.0f verify_ms=%.0f proc_ms=%.0f samp_ms=%.0f rb_ms=%.0f\n",
                        iters, ids.size() - 1, ms_since(ti0), ms_since(ti1), 0.0, 0.0, 0.0);
                if (hit_eos) break;
            }
            const double gen_ms = ms_since(tg0);
            fprintf(stderr, "[e2e-spec] iters=%d gen=%d acc_sum=%.0f draft_sum=%.0f dead=%d\n",
                    iters, n_gen, accept_sum, draft_sum, (int) spec_dead);
            fprintf(stderr, "[e2e-spec] sums ms draft=%.0f verify=%.0f proc=%.0f samp=%.0f rb=%.0f wall=%.0f\n",
                    ms_draft, ms_verify, ms_proc, ms_samp, ms_rb, gen_ms);
            fprintf(stderr, "[e2e-spec] %.2f tok/s wall | accept_len=%.2f accept_rate=%.3f\n",
                    n_gen * 1000.0 / gen_ms, iters ? (double) n_gen / iters : 0.0,
                    draft_sum > 0 ? accept_sum / draft_sum : 0.0);
            printf("[e2e][METRIC] leg=spec gen=%d wall_ms=%.0f tok_s=%.2f accept_len=%.2f\n",
                   n_gen, gen_ms, n_gen * 1000.0 / gen_ms,
                   iters ? (double) n_gen / iters : 0.0);
            fflush(stdout);
        }
    }

    // ---- matched plain loop: same ctx/sampler, one token per step ----
    if (plain_match) {
        // decode the token the spec path leaves as id_last, then autoregress
        llama_batch lb = llama_batch_get_one(&tokens[tokens.size() - 1], 1);
        if (llama_decode(ctx, lb) != 0) { fprintf(stderr, "FATAL: matched decode failed\n"); return 1; }
        const auto tg0 = clk::now();
        while (n_gen < n_predict) {
            llama_token id = common_sampler_sample(smpl, ctx, 0, false);
            common_sampler_accept(smpl, id, true);
            if (id == llama_vocab_eos(vocab) || llama_vocab_is_eog(vocab, id)) break;
            char pbuf[128];
            const int pn = llama_token_to_piece(vocab, id, pbuf, sizeof(pbuf), 0, false);
            if (pn > 0) { fwrite(pbuf, 1, pn, stdout); fflush(stdout); }
            gen_tokens.push_back(id);
            n_gen++;
            llama_batch nb1 = llama_batch_get_one(&id, 1);
            if (llama_decode(ctx, nb1) != 0) break;
        }
        const double gen_ms = ms_since(tg0);
        fprintf(stderr, "[e2e-plain] gen=%d wall=%.0f -> %.2f tok/s\n", n_gen, gen_ms, n_gen * 1000.0 / gen_ms);
        printf("[e2e][METRIC] leg=plain gen=%d wall_ms=%.0f tok_s=%.2f\n",
               n_gen, gen_ms, n_gen * 1000.0 / gen_ms);
        fflush(stdout);
    }

    // ---- legacy greedy path (unchanged behavior) ----
    if (!spec_on && !plain_match) {
        llama_sampler * greedy = llama_sampler_init_greedy();
        const int nb = (int) llama_n_batch(ctx);
        const auto tp0 = clk::now();
        int last_n = 0;
        // [dspark 2026-10-18] treat "0" as unset: earlier scripts exported
        // E2E_CBD_PREFILL=0 expecting to disable the prefill audit, but the
        // != nullptr check armed it anyway, which set g_cbd.done=true and
        // silently killed every subsequent decode audit.
        const char * cbd_pf_e = getenv("E2E_CBD_PREFILL");
        const bool cbd_pf = cbd_pf_e && cbd_pf_e[0] != '0';
        if (cbd_pf) g_cbd.armed = true;
        for (size_t i = 0; i < tokens.size(); ) {
            const size_t n = std::min<size_t>(nb, tokens.size() - i);
            llama_batch tb = llama_batch_get_one(&tokens[i], (int) n);
            if (llama_decode(ctx, tb) != 0) { fprintf(stderr, "FATAL: prefill decode failed\n"); return 1; }
            // [dspark 2026-10-18] E2E_PREFILL_SYNC=1: sync all backends after
            // every prefill call. Production prefill never touches logits
            // between calls, so async cache write-backs from call N may not be
            // complete when call N+1's state gather reads the cache. If this
            // flag alone fixes generation, the corruption is cross-call async
            // ordering, not the cpy/gather kernels themselves.
            if (getenv("E2E_PREFILL_SYNC")) llama_synchronize(ctx);
            last_n = (int) n;
            i += n;
        }
        printf("[e2e] prefill %.0f ms\n", ms_since(tp0));
        if (cbd_pf) { g_cbd.armed = false; g_cbd.done = true; fprintf(stderr, "[cbd] prefill dumped %d nodes\n", g_cbd.dumped); }
        const auto tg0 = clk::now();
        // [dspark 2026-10-18] SYNC PROBE: same test for the prefill argmax read
        if (getenv("E2E_LGD_SYNC")) llama_synchronize(ctx);
        llama_token id = llama_sampler_sample(greedy, ctx, last_n - 1);
        // [dspark 2026-10-17] E2E_FORCE_TOKEN=<id>: override the first sampled
        // token so CPU/GPU legs generate from an identical seed token — makes
        // generation-phase CBD/text comparisons valid despite prefill argmax
        // flips from benign fp noise (top-2 ties).
        if (const char * ft = getenv("E2E_FORCE_TOKEN")) {
            const llama_token f = (llama_token) atoi(ft);
            fprintf(stderr, "[e2e] force first token: sampled=%d -> %d\n", (int) id, (int) f);
            id = f;
        }
        // [dspark 2026-10-19] E2E_FORCE_SEQ=<id[,id...]>: teacher forcing —
        // override EVERY next-token from a fixed stream so CPU/GPU (or A/B)
        // legs decode identical inputs. Removes greedy-divergence pollution
        // from cross-leg CBD pairing; deviations then measure pure kernel
        // numerics. Stream exhausted -> fall back to greedy sampling.
        std::vector<llama_token> force_seq;
        if (const char * fs = getenv("E2E_FORCE_SEQ")) {
            const char * p = fs;
            while (*p) {
                char * end = nullptr;
                const long v = strtol(p, &end, 10);
                if (end == p) break;
                force_seq.push_back((llama_token) v);
                p = (*end == ',') ? end + 1 : end;
            }
            fprintf(stderr, "[e2e] force seq: %d tokens\n", (int) force_seq.size());
        }
        size_t force_seq_idx = 0;
        while (n_gen < n_predict) {
            if (id == llama_vocab_eos(vocab) || llama_vocab_is_eog(vocab, id)) break;
            char pbuf[128];
            const int pn = llama_token_to_piece(vocab, id, pbuf, sizeof(pbuf), 0, false);
            if (pn > 0) { fwrite(pbuf, 1, pn, stdout); fflush(stdout); }
            gen_tokens.push_back(id);
            n_gen++;
            if (getenv("E2E_CBD")) {
                g_cbd.armed = true;
                // [dspark 2026-10-18] re-arm the one-shot ask-phase pristine
                // cache audit for the decode graph (consumed by the prefill
                // graph's ask pass otherwise) and clear done from any earlier
                // audit so the decode nodes are actually audited.
                g_cbd.cache_audit_done = false;
                g_cbd.done = false;
                fprintf(stderr, "[cpy] --- decode phase begin (cpy occ continues) ---\n");
            }
        llama_batch nb1 = llama_batch_get_one(&id, 1);
            if (llama_decode(ctx, nb1) != 0) break;
            if (getenv("E2E_CBD")) { g_cbd.armed = false; g_cbd.done = true; fprintf(stderr, "[cbd] dumped %d nodes\n", g_cbd.dumped); }
            if (getenv("E2E_LOGITDUMP")) {
                // [dspark 2026-10-18] SYNC PROBE: CBD-enabled runs read correct
                // logits (per-node blocking readbacks serialize the OpenCL
                // queue), CBD-free runs read garbage — test whether an explicit
                // llama_synchronize before the host logits read fixes it.
                if (getenv("E2E_LGD_SYNC")) llama_synchronize(ctx);
                const float * lg = llama_get_logits_ith(ctx, 0);
                const int nv = (int) llama_vocab_n_tokens(vocab);
                int nnan = 0, nzero = 0; float mx = -1e30f; int am = -1;
                for (int t = 0; t < nv; t++) {
                    if (std::isnan(lg[t])) nnan++;
                    else if (lg[t] == 0.0f) nzero++;
                    if (lg[t] > mx) { mx = lg[t]; am = t; }
                }
                // [dspark 2026-10-17] top-5 + margin: distinguishes benign greedy
                // chaos (near-tie flip) from real numeric bugs (large-margin miss)
                float v[nv < 5 ? 5 : nv]; int ix[nv < 5 ? 5 : nv];
                const int TOP = 5;
                for (int k = 0; k < TOP; k++) { v[k] = -1e30f; ix[k] = -1; }
                for (int t = 0; t < nv; t++) {
                    if (std::isnan(lg[t])) continue;
                    if (lg[t] > v[TOP-1]) {
                        int k = TOP - 1;
                        while (k > 0 && lg[t] > v[k-1]) { v[k] = v[k-1]; ix[k] = ix[k-1]; k--; }
                        v[k] = lg[t]; ix[k] = t;
                    }
                }
                fprintf(stderr, "[lgd] step %d: nan=%d zero=%d max=%.4f argmax=%d\n",
                        (int) gen_tokens.size(), nnan, nzero, mx, am);
                fprintf(stderr, "[lgd] top5:");
                for (int k = 0; k < TOP; k++) fprintf(stderr, " %d:%.3f", ix[k], v[k]);
                fprintf(stderr, "  margin12=%.4f\n", (TOP >= 2 && ix[1] >= 0) ? v[0] - v[1] : -1.0f);
                if (getenv("E2E_LOGITDUMP_STOP")) return 2;
            }
            id = llama_sampler_sample(greedy, ctx, 0);
            if (force_seq_idx < force_seq.size()) {
                fprintf(stderr, "[e2e] force seq[%d]: sampled=%d -> %d\n",
                        (int) force_seq_idx, (int) id, (int) force_seq[force_seq_idx]);
                id = force_seq[force_seq_idx++];
            }
        }
        const double gen_ms = ms_since(tg0);
        fprintf(stderr, "[e2e] %d gen in %.0f ms -> %.2f tok/s (load %.0f ms)\n",
                n_gen, gen_ms, n_gen * 1000.0 / gen_ms, t_load);
        // [2026-10-20 Mesa 线] 性能数必须走 stdout：Mesa 调试版把逐提交 trace 打在 stderr，
        // 取数时只能 2>/dev/null，于是 t/s 一起被丢掉（历史上"没数"就是这么来的）。
        printf("[e2e][METRIC] leg=decode gen=%d wall_ms=%.0f tok_s=%.2f load_ms=%.0f\n",
               n_gen, gen_ms, n_gen * 1000.0 / gen_ms, t_load);
        fflush(stdout);
        llama_sampler_free(greedy);
    }

    if (const char * td = getenv("E2E_TOKDUMP")) {
        FILE * f = fopen(td, "wb");
        if (f) {
            const int n = (int) gen_tokens.size();
            fwrite(&n, sizeof(int), 1, f);
            if (n > 0) fwrite(gen_tokens.data(), sizeof(int), n, f);
            fclose(f);
        }
    }
    printf("\n[e2e] done n_gen=%d\n", n_gen);

    if (spec) common_speculative_free(spec);
    if (smpl) common_sampler_free(smpl);
    if (dspark_ctx) llama_free(dspark_ctx);
    if (draft_model) llama_model_free(draft_model);
    llama_free(ctx);
    llama_model_free(model);
    llama_backend_free();
    return 0;
}
