// moe_topk_fused_route_test.cpp —— [tongyi M-R1 2026-10-25] 桌面对拍单测
//
// 验收协议第 1 条（docs/megakernel_router_pipeline_2026-10-25.md §5）：
//   CPU 参考实现（moe_topk_fused_core.h，ops.cpp 同源）vs 「模拟图路径」——
//   按 llama-graph.cpp build_moe_ffn 路由段的算子链（SIGMOID → ADD(bias) →
//   reshape → argsort_top_k(2) → get_rows → sum_rows → argsort_top_k(gu) →
//   get_rows → fill(-inf) → set_rows → reshape → argsort_top_k(K) →
//   get_rows(probs) → sum_rows → clamp → div → scale）逐算子独立复刻，双眼看门。
//   1e5 随机 logits（含量化档强制 tie 案 + 全 tie 案 + bias/无 bias）。
//
// 跑法（本机 MinGW / 任意 host g++）：
//   g++ -std=c++17 -O2 -I../ggml-cpu moe_topk_fused_route_test.cpp -o moe_topk_route_test && ./moe_topk_route_test
// 期望：全 pass 退出码 0（含 ids→f32→I32 CAST roundtrip 位精确断言）。
//
// 设备验收记录（2026-10-25，740 / Adreno 830，Ling-3.0-tiny-Q4_0，16-token 短腿）：
//   ① 文本：ON/OFF 六腿生成文本逐字节相同
//   ② kernels/token：1498 → 1199（-299，-20.0%；设计稿预测 ~1210）
//   ③ tok_s 交错 A/B：OFF 7.70/8.18/8.48 vs ON 9.21/8.86/8.83
//      （首腿对 +19.6%，后两腿对均值 +6.2%，无回退）
//   ④ 无 GGML_ABORT / signal；decode host_ms 均值 ~143 → ~109（-24%）
#include "moe_topk_fused_core.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vector>
#include <random>

// 镜像 ggml-impl.h 的 MIN/MAX（clamp 复刻用）
#define MIN(a, b) ((a) < (b) ? (a) : (b))
#define MAX(a, b) ((a) > (b) ? (a) : (b))

using namespace moe_topk_core;

static int g_fail = 0, g_pass = 0;
#define CHECK(cond, ...) do { \
    if (!(cond)) { printf("FAIL %s:%d ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); ++g_fail; } \
    else { ++g_pass; } \
} while (0)

// ============================================================================
// 「模拟图路径」—— 独立复刻 build_moe_ffn 路由段（llama-graph.cpp）。
// 与 moe_topk_fused_core.h 是两份手写；逐字节一致 = M-R1 CPU 参考的迁移门。
// 复刻纪律：每个 ggml 算子的语义照 ops.cpp 实现（argsort_top_k = argsort DESC
// + view 截断；sum_rows = 顺序累加；set_rows = dst[ids[i]] = src[i]；clamp =
// MAX(MIN(x, max), min)；gather 无 bias probs）。
// ============================================================================

// 镜像 ggml_argsort_top_k：argsort DESC（cmp_argsort<DESC> 同款严格 >）+ 取前 k
static std::vector<int32_t> sim_argsort_top_k(const std::vector<float> & v, int k) {
    std::vector<int32_t> idx(v.size());
    for (size_t i = 0; i < v.size(); ++i) idx[i] = (int32_t) i;
    std::sort(idx.begin(), idx.end(), cmp_argsort_desc{v.data()});
    idx.resize(k);
    return idx;
}

static void graph_path_row(
        const float * logits,
        const float * bias,
        int E, int G, int epg, int gu, int K,
        float w_scale,
        float * w_out,
        int32_t * ids_out) {
    // probs = SIGMOID(logits)  [E]
    std::vector<float> probs(E);
    for (int i = 0; i < E; ++i) probs[i] = 1.f / (1.f + expf(-logits[i]));

    // selection_probs = probs + exp_probs_b（有 bias 时）
    std::vector<float> selp(E);
    for (int i = 0; i < E; ++i) selp[i] = bias ? probs[i] + bias[i] : probs[i];

    // ---- 分组路由（n_expert_groups > 1）----
    // selection_groups = reshape [epg, G]（列 = 组）
    // group_scores = argsort_top_k(selection_groups 列, 2) -> get_rows -> sum_rows
    std::vector<float> gsum(G);
    for (int g = 0; g < G; ++g) {
        std::vector<float> col(epg);
        for (int i = 0; i < epg; ++i) col[i] = selp[g*epg + i];
        std::vector<int32_t> top2 = sim_argsort_top_k(col, 2);
        // sum_rows：按 gather 后顺序累加
        gsum[g] = col[top2[0]] + col[top2[1]];
    }

    // expert_groups = argsort_top_k(gsum, gu)
    std::vector<int32_t> expert_groups = sim_argsort_top_k(gsum, gu);

    // masked = set_rows(fill(selection_groups, -inf), get_rows(...), expert_groups)
    std::vector<float> masked(E, -INFINITY);
    for (int j = 0; j < gu; ++j) {
        const int g0 = expert_groups[j];
        for (int i = 0; i < epg; ++i) masked[g0*epg + i] = selp[g0*epg + i];
    }

    // selected_experts = argsort_top_k(masked, K)
    std::vector<int32_t> selected = sim_argsort_top_k(masked, K);

    // weights = get_rows(probs, selected)  —— 无 bias gather
    // norm_w: sum_rows -> clamp(6.103515625e-5, +inf) -> div (-> scale)
    std::vector<float> w(K);
    for (int k = 0; k < K; ++k) w[k] = probs[selected[k]];
    float s = 0.f;
    for (int k = 0; k < K; ++k) s += w[k];
    s = MAX(MIN(s, INFINITY), kMinWeightSum);
    for (int k = 0; k < K; ++k) w_out[k] = w[k] / s;
    if (w_scale != 0.0f && w_scale != 1.0f) {
        for (int k = 0; k < K; ++k) w_out[k] *= w_scale;
    }

    for (int k = 0; k < K; ++k) ids_out[k] = selected[k];
}

// ============================================================================
// kernel 风格参照（有序 argmax 扫描，最低下标破 tie）—— 只统计与 std::sort
// 参照在 id 序列上的分歧率（信息项，不作 pass/fail：分歧只可能出现在有限值
// 精确 tie，e2e 文本 diff 是最终裁决）。
// ============================================================================
static int kernel_style_row(
        const float * p,
        const float * bias,
        int E, int G, int epg, int gu, int K,
        int32_t * ids_out) {
    std::vector<float> sel(E);
    for (int i = 0; i < E; ++i) sel[i] = bias ? p[i] + bias[i] : p[i];
    std::vector<float> gsum(G);
    for (int g = 0; g < G; ++g) {
        float b1 = -INFINITY, b2 = -INFINITY;
        for (int j = 0; j < epg; ++j) {
            const float v = sel[g*epg + j];
            if (v > b1) { b2 = b1; b1 = v; } else if (v > b2) { b2 = v; }
        }
        gsum[g] = b1 + b2;
    }
    std::vector<float> gtmp = gsum;
    std::vector<int> gsel(gu);
    for (int j = 0; j < gu; ++j) {
        int bi = -1; float bv = -INFINITY;
        for (int g = 0; g < G; ++g) if (gtmp[g] > bv) { bv = gtmp[g]; bi = g; }
        gsel[j] = bi; gtmp[bi] = -INFINITY;
    }
    std::vector<float> masked(E, -INFINITY);
    for (int j = 0; j < gu; ++j) {
        for (int i = 0; i < epg; ++i) masked[gsel[j]*epg + i] = sel[gsel[j]*epg + i];
    }
    std::vector<float> mtmp = masked;
    int diff = 0;
    std::vector<int32_t> ref(E);
    for (int i = 0; i < E; ++i) ref[i] = i;
    std::sort(ref.begin(), ref.end(), cmp_argsort_desc{masked.data()});
    for (int j = 0; j < K; ++j) {
        int bi = -1; float bv = -INFINITY;
        for (int e = 0; e < E; ++e) if (mtmp[e] > bv) { bv = mtmp[e]; bi = e; }
        mtmp[bi] = -INFINITY;
        if (ref[j] != bi) ++diff;
    }
    for (int k = 0; k < K; ++k) ids_out[k] = ref[k];
    return diff;
}

static uint32_t rng_u32(std::mt19937 & rng) { return rng(); }

static void run_case_family(const char * tag, int E, int G, int epg, int gu, int K,
                            int n_rows, int bias_mode, int quant_mode, uint32_t seed,
                            int * tie_rows) {
    Workspace ws;
    std::vector<float> p(E), logits(E), bias_v(E, 0.0f);
    const float * bias = bias_mode ? bias_v.data() : nullptr;
    std::vector<float> w_core(K), w_sim(K);
    std::vector<int32_t> ids_core(K), ids_sim(K), ids_kern(K);
    std::mt19937 rng(seed);

    long id_diff = 0, w_diff = 0;
    for (int r = 0; r < n_rows; ++r) {
        for (int i = 0; i < E; ++i) {
            float v;
            if (quant_mode == 0) {
                std::uniform_real_distribution<float> dist(-10.f, 10.f);
                v = dist(rng);
            } else if (quant_mode == 1) {
                // 量化档：{-3..3} 的 0.25 步进 —— sigmoid 后大概率精确 tie
                v = (float)((int)(rng_u32(rng) % 25) - 12) * 0.25f;
            } else {
                // 全 tie 档：同一行全部相同值
                v = 0.5f;
            }
            logits[i] = v;
            p[i] = 1.f / (1.f + expf(-v));
        }
        if (bias_mode) {
            for (int i = 0; i < E; ++i) {
                bias_v[i] = quant_mode == 1
                    ? (float)((int)(rng_u32(rng) % 5) - 2) * 0.125f
                    : (float)((int)(rng_u32(rng) % 200) - 100) / 1000.0f;
            }
        }
        if (quant_mode == 2) {
            for (int i = 1; i < E; ++i) { logits[i] = logits[0]; p[i] = p[0]; }
        }

        graph_path_row(logits.data(), bias, E, G, epg, gu, K, 1.0f, w_sim.data(), ids_sim.data());
        route_row(p.data(), bias, E, G, epg, gu, K, 1.0f, w_core.data(), ids_core.data(), ws);
        *tie_rows += kernel_style_row(p.data(), bias, E, G, epg, gu, K, ids_kern.data());

        if (memcmp(w_core.data(), w_sim.data(), K*sizeof(float)) != 0) ++w_diff;
        if (memcmp(ids_core.data(), ids_sim.data(), K*sizeof(int32_t)) != 0) ++id_diff;

        CHECK(memcmp(w_core.data(), w_sim.data(), K*sizeof(float)) == 0,
              "%s row=%d weights differ (quant=%d bias=%d)", tag, r, quant_mode, bias_mode);
        CHECK(memcmp(ids_core.data(), ids_sim.data(), K*sizeof(int32_t)) == 0,
              "%s row=%d ids differ (quant=%d bias=%d)", tag, r, quant_mode, bias_mode);

        // ids -> f32 -> I32 CAST roundtrip 位精确（graph 接线靠这个）
        for (int k = 0; k < K; ++k) {
            const float f = (float) ids_core[k];
            CHECK((int32_t) f == ids_core[k], "%s cast roundtrip id=%d", tag, ids_core[k]);
        }
    }
    if (w_diff || id_diff) {
        printf("FAIL %s: w_diff=%ld id_diff=%ld (quant=%d bias=%d)\n", tag, w_diff, id_diff, quant_mode, bias_mode);
        g_fail++;
    } else {
        printf("PASS %s (quant=%d bias=%d) rows=%d: core == graph-path 逐字节\n", tag, quant_mode, bias_mode, n_rows);
        g_pass++;
    }
}

int main(int argc, char ** argv) {
    const int n_random = (argc > 1) ? atoi(argv[1]) : 100000;
    const float wscs[] = { 1.0f, 0.0f, 1.0f, 2.5f };
    int tie_rows = 0;

    // Ling-3.0 真形（pin）：E=128 G=8 epg=16 gu=4 K=8；随机 / 量化 tie / 全 tie × 有无 bias × w_scale
    int case_i = 0;
    for (int q = 0; q < 3; ++q) {
        for (int b = 0; b < 2; ++b) {
            const float wsc = wscs[case_i++ % 4];
            char tag[64]; snprintf(tag, sizeof(tag), "ling128");
            Workspace ws;
            std::vector<float> p(128), logits(128), bias_v(128, 0.f);
            std::vector<float> w_c(8), w_s(8);
            std::vector<int32_t> ic(8), is(8);
            std::mt19937 rng(42 + q*10 + b);
            long wd = 0, idd = 0;
            int n_rows = q == 0 ? n_random : 20000;
            for (int r = 0; r < n_rows; ++r) {
                for (int i = 0; i < 128; ++i) {
                    float v = q == 0
                        ? std::uniform_real_distribution<float>(-10.f, 10.f)(rng)
                        : q == 1
                            ? (float)((int)(rng() % 25) - 12) * 0.25f
                            : 0.5f;
                    logits[i] = v;
                    p[i] = 1.f / (1.f + expf(-v));
                }
                if (b) {
                    for (int i = 0; i < 128; ++i) {
                        bias_v[i] = q == 1
                            ? (float)((int)(rng() % 5) - 2) * 0.125f
                            : (float)((int)(rng() % 200) - 100) / 1000.0f;
                    }
                }
                graph_path_row(logits.data(), b ? bias_v.data() : nullptr, 128, 8, 16, 4, 8, wsc, w_s.data(), is.data());
                route_row(p.data(), b ? bias_v.data() : nullptr, 128, 8, 16, 4, 8, wsc, w_c.data(), ic.data(), ws);
                if (memcmp(w_c.data(), w_s.data(), 8*sizeof(float)) != 0) ++wd;
                if (memcmp(ic.data(), is.data(), 8*sizeof(int32_t)) != 0) ++idd;
                for (int k = 0; k < 8; ++k) CHECK((int32_t)(float)ic[k] == ic[k], "ling cast roundtrip");
            }
            if (wd || idd) {
                printf("FAIL ling128 q=%d b=%d wsc=%.2f: w_diff=%ld id_diff=%ld\n", q, b, wsc, wd, idd);
                g_fail++;
            } else {
                printf("PASS ling128 (q=%d b=%d wsc=%.2f) rows=%d: core == graph-path 逐字节\n", q, b, wsc, n_rows);
                g_pass++;
            }
        }
    }

    // 形状泛化：小组合（gate 会拦 GPU 侧，但 CPU 参考必须通用正确）
    run_case_family("E64G4epg16gu3K6", 64, 4, 16, 3, 6, 20000, 1, 0, 7, &tie_rows);
    run_case_family("E32G2epg16gu1K2", 32, 2, 16, 1, 2, 20000, 1, 1, 8, &tie_rows);
    run_case_family("E96G6epg16gu5K7", 96, 6, 16, 5, 7, 20000, 1, 0, 9, &tie_rows);

    printf("\n== kernel-style 有序 argmax vs std::sort id 分歧行累计 = %d（信息项：仅有限值精确 tie 会分歧）\n", tie_rows);
    printf("== %d pass / %d fail ==\n", g_pass, g_fail);
    return g_fail ? 1 : 0;
}
