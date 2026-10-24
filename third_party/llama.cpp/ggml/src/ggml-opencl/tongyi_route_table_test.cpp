// tongyi_route_table_test.cpp —— R1 等价性/指纹/形状三族单测（无 gtest 依赖，纯断言）
// [tongyi R1 2026-10-25] 设计稿 §4：
//   A 一致性：resolve/resolve_admission == legacy 参照实现（本文件独立复刻，双眼看门）
//   B 指纹回归：代际/E17/known_bad golden
//   C 形状普查 fixture：Ling 真形状（G-754/G-748）+ MiniCPM 路由形状（L3 §18 落 CPU 4 形状）
//                   + 边界（K%256 off-by-one、E=1、n_cols、view）+ G-740 漂移点显式 pin
// 跑法（NDK 交叉 + 设备执行，或任意 host 编译器）：
//   aarch64-linux-android29-clang++ -std=c++17 -O2 -static-libstdc++ \
//     tongyi_route_table.cpp tongyi_route_table_test.cpp -o tongyi-route-test && ./tongyi-route-test
#include "tongyi_route_table.h"

#include <stdio.h>
#include <string.h>

using namespace tongyi;

static int g_fail = 0, g_pass = 0;
#define CHECK(cond, ...) do { \
    if (!(cond)) { printf("FAIL %s:%d ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); ++g_fail; } \
    else { ++g_pass; } \
} while (0)

// ============================================================================
// legacy 参照实现 —— 从 ggml-opencl.cpp（git=41ae9a72 + 865f75cd）独立复刻。
// 与 tongyi_route_table.cpp 是两份手写；断言两者逐 case 一致就是 R1 的迁移门。
// ============================================================================

// 镜像 use_adreno_moe_kernels(:9662)
static bool legacy_use_adreno(RGen gen, RCompiler comp, const char * name, int M, int mode, bool e17_off) {
    if (gen == RGEN_UNKNOWN) return false;
    if (gen == RGEN_A7X && mode == 0) return false;
    if (gen == RGEN_A6X && mode != 1) return false;
    if (comp == RCOMP_E17 && !e17_off) return false;
    const bool name_ok = (strstr(name, "ffn") && strstr(name, "exps")) || strstr(name, "as");
    return name_ok && (M % 32 == 0);
}

// 镜像 moe_use_dense_loop(:9728)
static bool legacy_dense_loop_type(RType t, bool dense_off, bool dense_force, bool vendor_diag) {
    if (dense_off) return false;
    if (dense_force) return true;
    if (vendor_diag) return false;
    return t == RTYPE_Q4_K || t == RTYPE_Q4_0;
}

// 镜像 supports_op MUL_MAT_ID 分支(:10338-10423)：返回是否准入 GPU
static bool legacy_supports_mmid(RType t, int K, int M, const char * name, bool src1_f32, bool src2_i32,
                                 bool c0, bool c1, RGen gen, RCompiler comp, int mode, bool e17_off,
                                 bool vendor_diag, bool batched_off, size_t align) {
    if ((t == RTYPE_Q4_0 || t == RTYPE_Q4_K) &&
        legacy_dense_loop_type(t, false, false, vendor_diag)) {
        if (!src1_f32 || !src2_i32 || !c0 || !c1) return false;
        size_t s_q, s_d, s_dm, s_s;
        bool shape_ok;
        if (t == RTYPE_Q4_0) {
            shape_ok = (K % 32 == 0);
            s_q = (size_t)M * (K / 4) * 2;  s_d = (size_t)M * (K / 32) * 2;  s_dm = 0; s_s = 0;
        } else {
            shape_ok = (K % 256 == 0);
            s_q = (size_t)M * (K / 4) * 2;  s_d = (size_t)M * (K / 256) * 2;
            s_dm = (size_t)M * (K / 256) * 2;  s_s = (size_t)M * (K / 256) * 12;
        }
        if (!shape_ok) return false;
        if (M % 4 != 0) return false;
        if (s_q % align || s_d % align || (s_dm && s_dm % align) || (s_s && s_s % align)) return false;
        return true;
    }
    if (t == RTYPE_Q3_K && !batched_off) {
        if (M <= 0) return false;   // 防呆（普查形状 M 恒 >0）
        return (K % 256 == 0) && (M % 128 == 0) && src1_f32 && src2_i32 && c0 && c1 &&
               (M /*E>1 由调用方保证另行核*/ > 0) && true;   // 形状部分；名字/代际/E17/E>1 下面拼
    }
    if (vendor_diag && (t == RTYPE_Q4_0 || t == RTYPE_Q8_0 || t == RTYPE_MXFP4) && src1_f32 && c0 && c1) {
        return true;
    }
    return false;
}

// 完整版 supports_op（含 q3_K 的 E>1/名字/代际门）——上面那版拆两半是为了可读，
// 这里直接给全量参照：
static bool legacy_supports_mmid_full(const RouteQuery & q, const RouteContext & ctx) {
    const bool srcs = q.src1_f32 && q.src2_i32 && q.contiguous0 && q.contiguous1;
    if ((q.type == RTYPE_Q4_0 || q.type == RTYPE_Q4_K) &&
        legacy_dense_loop_type(q.type, ctx.dense_off, ctx.dense_force, ctx.vendor_diag)) {
        if (!q.src1_f32 || !q.src2_i32 || !q.contiguous0 || !q.contiguous1) return false;
        size_t s_q = 0, s_d = 0, s_dm = 0, s_s = 0;
        bool shape_ok;
        if (q.type == RTYPE_Q4_0) {
            shape_ok = (q.K % 32 == 0);
            s_q = (size_t)q.M * (q.K / 4) * 2;  s_d = (size_t)q.M * (q.K / 32) * 2;
        } else {
            shape_ok = (q.K % 256 == 0);
            s_q = (size_t)q.M * (q.K / 4) * 2;  s_d = (size_t)q.M * (q.K / 256) * 2;
            s_dm = (size_t)q.M * (q.K / 256) * 2;  s_s = (size_t)q.M * (q.K / 256) * 12;
        }
        if (!shape_ok || q.M % 4 != 0) return false;
        if (q.align_bytes && (s_q % q.align_bytes || s_d % q.align_bytes ||
            (s_dm && s_dm % q.align_bytes) || (s_s && s_s % q.align_bytes))) return false;
        return true;
    }
    if (q.type == RTYPE_Q3_K && !ctx.batched_off) {
        return q.E > 1 && srcs &&
               legacy_use_adreno(ctx.gen, ctx.compiler, q.name ? q.name : "", q.M, ctx.moe_a7x_mode, ctx.e17_quirks_off) &&
               (q.K % 256 == 0) && (q.M % 128 == 0);
    }
    if (ctx.vendor_diag && (q.type == RTYPE_Q4_0 || q.type == RTYPE_Q8_0 || q.type == RTYPE_MXFP4) &&
        q.src1_f32 && q.contiguous0 && q.contiguous1) {
        return true;
    }
    return false;
}

// 镜像 batched 静态门（:25046 gate 0/1/4/5/6/7/8）
static bool legacy_batched_static(const RouteQuery & q, const RouteContext & ctx) {
    if (!q.src1_f32 || !q.src2_i32) return false;
    if (q.type != RTYPE_Q4_0 && q.type != RTYPE_Q4_K && q.type != RTYPE_Q3_K) return false;
    if (!legacy_use_adreno(ctx.gen, ctx.compiler, q.name ? q.name : "", q.M, ctx.moe_a7x_mode, ctx.e17_quirks_off)) return false;
    if (!q.contiguous0 || !q.contiguous1) return false;
    if (q.is_view) {
        if (q.type == RTYPE_Q3_K) { if (!q.view_slot_aligned) return false; }
        else return false;
    }
    if (q.K % 32 != 0 || q.M % 128 != 0) return false;
    if ((q.type == RTYPE_Q4_K || q.type == RTYPE_Q3_K) && q.K % 256 != 0) return false;
    if (q.type == RTYPE_Q3_K && q.E <= 1) return false;
    const long long n_cols = (long long)q.n_used * q.n_tok;
    if (q.n_used < 1 || q.n_tok < 1 || n_cols > (1LL << 20)) return false;
    return true;
}

// 镜像派发器(:29586-29705)：0=CPU 1=BATCHED 2=DENSE 3=VENDOR。
// ⚠️ 派发器只见到 supports_op 已准入的张量：先判准入，未准入恒 0
// （dgx 首轮对拍抓到的参照 bug：dense 形状门失败的张量根本到不了派发器，不能报 2）
static int legacy_dispatch_kind(const RouteQuery & q, const RouteContext & ctx) {
    if (!legacy_supports_mmid_full(q, ctx)) return 0;
    if (q.type == RTYPE_Q4_0 || q.type == RTYPE_Q4_K) {
        if (legacy_dense_loop_type(q.type, ctx.dense_off, ctx.dense_force, ctx.vendor_diag)) {
            if (!ctx.batched_off && legacy_batched_static(q, ctx)) return 1;
            return 2;   // dense-loop（函数内部还有运行时平面检查）
        }
        if (ctx.vendor_diag && q.type == RTYPE_Q4_0 && q.src1_f32 && q.contiguous0 && q.contiguous1) return 3;
        return 0;
    }
    if (q.type == RTYPE_Q3_K) {
        if (!ctx.batched_off && legacy_batched_static(q, ctx)) return 1;
        return 0;   // 静态拒 = supports_op 同门拒（GGML_ABORT 契约路径不会发生）
    }
    if (ctx.vendor_diag && (q.type == RTYPE_Q8_0 || q.type == RTYPE_MXFP4) &&
        q.src1_f32 && q.contiguous0 && q.contiguous1) return 3;
    return 0;
}

static int resolve_kind_id(const RouteResult & r) {
    if (!r.admitted()) return 0;
    switch (r.spec->kind) {
        case BATCHED_MOE: return 1;
        case DENSE_LOOP: return 2;
        case VENDOR_KERNEL: return 3;
        default: return -1;
    }
}

// ============================================================================
// 族 A：一致性（采样空间逐 case 对拍）
// ============================================================================

static void family_a() {
    const RType types[]  = { RTYPE_Q4_0, RTYPE_Q4_K, RTYPE_Q3_K, RTYPE_Q8_0, RTYPE_MXFP4, RTYPE_Q4_1 };
    const int   Ks[]     = { 31, 32, 64, 128, 255, 256, 512, 1536, 2048, 5120 };
    const int   Ms[]     = { 4, 8, 32, 64, 127, 128, 129, 512, 1536 };
    const char * names[] = { "blk.3.ffn_gate_exps", "ffn_as", "w_exps", "output.weight", "" };
    const RGen  gens[]   = { RGEN_UNKNOWN, RGEN_A6X, RGEN_A7X, RGEN_A8X, RGEN_X2E };
    const int   modes[]  = { -1, 0, 1 };
    const RCompiler comps[] = { RCOMP_E031, RCOMP_E17 };
    // env 组合：{dense_off, dense_force, vendor_diag, batched_off}
    const struct { bool d_off, d_force, vdiag, b_off; } envs[] = {
        {false, false, false, false}, {true, false, false, false}, {false, true, false, false},
        {false, false, true,  false}, {true, false, true,  false}, {false, false, false, true},
        {false, true,  false, true },
    };

    long long cases = 0, adm_ok = 0, disp_ok = 0, q3_contract = 0;
    for (unsigned ti = 0; ti < sizeof(types)/sizeof(types[0]); ++ti)
    for (unsigned ki = 0; ki < sizeof(Ks)/sizeof(Ks[0]); ++ki)
    for (unsigned mi = 0; mi < sizeof(Ms)/sizeof(Ms[0]); ++mi)
    for (unsigned ni = 0; ni < sizeof(names)/sizeof(names[0]); ++ni)
    for (unsigned gi = 0; gi < sizeof(gens)/sizeof(gens[0]); ++gi)
    for (unsigned ci = 0; ci < sizeof(comps)/sizeof(comps[0]); ++ci)
    for (unsigned ei = 0; ei < sizeof(envs)/sizeof(envs[0]); ++ei) {
        RouteQuery q = {};
        q.op = ROUTE_MUL_MAT_ID;
        q.type = types[ti]; q.K = Ks[ki]; q.M = Ms[mi]; q.E = 8;
        q.n_used = 8; q.n_tok = 1; q.name = names[ni];
        q.src1_f32 = true; q.src2_i32 = true;
        q.contiguous0 = true; q.contiguous1 = true;
        q.is_view = false; q.view_slot_aligned = false;
        q.align_bytes = 128;
        RouteContext ctx = {};
        ctx.gen = gens[gi]; ctx.compiler = comps[ci];
        ctx.moe_a7x_mode = modes[(gi + ci + ei) % 3];      // 变化 mode
        ctx.e17_quirks_off = ((gi + ei) % 2) == 0;         // 变化 E17 豁免
        ctx.dense_off = envs[ei].d_off; ctx.dense_force = envs[ei].d_force;
        ctx.vendor_diag = envs[ei].vdiag; ctx.batched_off = envs[ei].b_off;

        const bool legacy_adm = legacy_supports_mmid_full(q, ctx);
        const RouteResult adm = resolve_admission(q, ctx);
        if (adm.admitted() != legacy_adm) {
            CHECK(false, "A-admission type=%d K=%d M=%d name=%s gen=%d comp=%d mode=%d e17off=%d env(%d%d%d%d)",
                  q.type, q.K, q.M, q.name, ctx.gen, ctx.compiler, ctx.moe_a7x_mode, ctx.e17_quirks_off,
                  ctx.dense_off, ctx.dense_force, ctx.vendor_diag, ctx.batched_off);
            continue;
        }
        ++adm_ok;

        // 派发语义（准入空间内才有意义）
        const int lk = legacy_dispatch_kind(q, ctx);
        const int rk = resolve_kind_id(resolve(q, ctx));
        if (lk != rk) {
            CHECK(false, "A-dispatch type=%d K=%d M=%d name=%s gen=%d mode=%d legacy=%d route=%d",
                  q.type, q.K, q.M, q.name, ctx.gen, ctx.moe_a7x_mode, lk, rk);
            continue;
        }
        ++disp_ok;

        // G-725 契约：q3_K 的 supports_op 准入 == 派发 batched 静态门（漂移即 ABORT 风险）
        if (q.type == RTYPE_Q3_K) {
            const bool eq = legacy_adm == ((!ctx.batched_off) && legacy_batched_static(q, ctx));
            CHECK(eq, "A-q3-contract K=%d M=%d adm=%d", q.K, q.M, legacy_adm);
            ++q3_contract;
        }
        ++cases;
    }
    printf("A 一致性：%lld cases，admission %lld / dispatch %lld / q3 契约 %lld 全对拍\n",
           cases, adm_ok, disp_ok, q3_contract);
    CHECK(cases > 150000, "采样空间足够大（dispatch 对拍 case 数）");
}

// ============================================================================
// 族 B：指纹 golden
// ============================================================================

static RouteContext ctx_adreno830() {   // 830/vendor：E031.47、A8X、默认 env
    RouteContext c = {};
    c.gen = RGEN_A8X; c.compiler = RCOMP_E031; c.moe_a7x_mode = -1;
    return c;
}

static void family_b() {
    RouteContext c = ctx_adreno830();
    RouteQuery ling = {};
    ling.op = ROUTE_MUL_MAT_ID; ling.type = RTYPE_Q4_0; ling.K = 1536; ling.M = 512; ling.E = 128;
    ling.n_used = 8; ling.n_tok = 1; ling.name = "blk.3.ffn_gate_exps";
    ling.src1_f32 = ling.src2_i32 = ling.contiguous0 = ling.contiguous1 = true;
    ling.align_bytes = 128;

    // B1: 830 默认 → Ling q4_0 batched（G-754：DISPATCHED_batched=3015 同源）
    RouteResult r = resolve(ling, c);
    CHECK(r.admitted() && r.spec->kind == BATCHED_MOE && r.spec == &specs()[0],
          "B1 830+Ling q4_0 -> BATCHED（got %s）", r.admitted() ? route_kind_name(r.spec->kind) : "REFUSED");

    // B2: A6X 默认（mode=-1）→ batched 拒 gen；A7X mode=0 拒；A6X mode=1 放行（G-778 +46% 的开关）
    RouteContext c6 = c; c6.gen = RGEN_A6X;
    CHECK(!resolve(ling, c6).admitted() || resolve(ling, c6).spec->kind != BATCHED_MOE,
          "B2a A6X 默认不得 batched");
    c6.moe_a7x_mode = 1;
    CHECK(resolve(ling, c6).admitted() && resolve(ling, c6).spec->kind == BATCHED_MOE,
          "B2b A6X FORCE=1 应 batched");
    RouteContext c7 = c; c7.gen = RGEN_A7X; c7.moe_a7x_mode = 0;
    CHECK(resolve(ling, c7).spec == nullptr || resolve(ling, c7).spec->kind != BATCHED_MOE,
          "B2c A7X FORCE=0 不得 batched");
    RouteContext c7d = c; c7d.gen = RGEN_A7X;   // mode=-1 默认进（G-773 修法语义）
    CHECK(resolve(ling, c7d).admitted() && resolve(ling, c7d).spec->kind == BATCHED_MOE,
          "B2d A7X 默认应 batched");

    // B3: E17 编译器 → batched 拒（G-747 语义）；E17_QUIRKS=0 豁免
    RouteContext e17 = c; e17.compiler = RCOMP_E17;
    CHECK(resolve(ling, e17).spec == nullptr || resolve(ling, e17).spec->kind != BATCHED_MOE,
          "B3a E17 不得 batched");
    e17.e17_quirks_off = true;
    CHECK(resolve(ling, e17).admitted() && resolve(ling, e17).spec->kind == BATCHED_MOE,
          "B3b E17 豁免后应 batched");

    // B4: known_bad：E031.47 vendor gemv/gemm_moe f32_ns 族可查；无关族查不到
    CHECK(known_bad_lookup(RCOMP_E031, "gemv_moe_q4_k_f32_ns"), "B4a f32_ns 族 E031 可查");
    CHECK(known_bad_lookup(RCOMP_E031, "gemm_moe_mxfp4_f32_ns"), "B4b gemm 族可查");
    CHECK(!known_bad_lookup(RCOMP_E031, "rms_norm"), "B4c 无关族不可查");
    CHECK(!known_bad_lookup(RCOMP_E17, "gemv_moe_q4_k_f32_ns"), "B4d E17 不在 E031 坏账");
    CHECK(known_bad_count() == 3 && spec_count() == 8, "B4e 表规模 pin（8 行 + 3 坏账）");
    for (int i = 0; i < known_bad_count(); ++i) CHECK(known_bad()[i].evidence && known_bad()[i].evidence[0], "B4f 证据非空");
    for (int i = 0; i < spec_count(); ++i) CHECK(specs()[i].owner && specs()[i].owner[0], "B4g owner 非空");

    // B5: vendor 诊断 env → Q8_0/MXFP4 vendor；known_bad 同时可查（诊断隔离的账面依据）
    RouteContext vd = c; vd.vendor_diag = true;
    RouteQuery q8 = ling; q8.type = RTYPE_Q8_0; q8.name = "blk.3.ffn_gate_exps";
    RouteResult rv = resolve(q8, vd);
    CHECK(rv.admitted() && rv.spec->kind == VENDOR_KERNEL, "B5 Q8_0 vendor 诊断行");

    printf("B 指纹 golden：通过\n");
}

// ============================================================================
// 族 C：普查形状 fixture（Ling 真形状 + MiniCPM 路由形状 + 边界 + G-740 漂移 pin）
// ============================================================================

static void family_c() {
    RouteContext c = ctx_adreno830();

    // C1: Ling 真形状（G-748：ffn_{gate,up} ne=[1536,512,128]，ffn_down ne=[512,1536,128]，Q4_0）
    const struct { int K, M; } ling[] = { {1536, 512}, {512, 1536} };
    for (unsigned i = 0; i < 2; ++i) {
        RouteQuery q = {};
        q.op = ROUTE_MUL_MAT_ID; q.type = RTYPE_Q4_0; q.K = ling[i].K; q.M = ling[i].M; q.E = 128;
        q.n_used = 8; q.n_tok = 1; q.name = "blk.3.ffn_gate_exps";
        q.src1_f32 = q.src2_i32 = q.contiguous0 = q.contiguous1 = true; q.align_bytes = 128;
        RouteResult r = resolve(q, c);
        CHECK(r.admitted() && r.spec->kind == BATCHED_MOE, "C1 Ling [%d,%d] batched", q.K, q.M);
    }

    // C2: MiniCPM 路由形状（L3 §18：ffn_moe_gate-0 ne=[512,8] / ffn_moe_down-0 ne=[2048,8]，q3_K）
    //     ⇒ M%128 不过 ⇒ 落 CPU（普查口径「每 token 落 CPU 的形状集合不扩大」的锚点）
    {
        RouteQuery g = {};
        g.op = ROUTE_MUL_MAT_ID; g.type = RTYPE_Q3_K; g.K = 512; g.M = 8; g.E = 256;
        g.n_used = 8; g.n_tok = 1; g.name = "ffn_moe_gate-0";
        g.src1_f32 = g.src2_i32 = g.contiguous0 = g.contiguous1 = true; g.align_bytes = 128;
        CHECK(!resolve_admission(g, c).admitted(), "C2a MiniCPM 路由 gate 形状应落 CPU");
        g.K = 2048;
        CHECK(!resolve_admission(g, c).admitted(), "C2b MiniCPM 路由 down 形状应落 CPU");
    }

    // C3: 边界——K%256 off-by-one / E=1 / n_cols 超限 / view 三态
    {
        RouteQuery q = {};
        q.op = ROUTE_MUL_MAT_ID; q.type = RTYPE_Q4_K; q.K = 256 - 1; q.M = 512; q.E = 128;
        q.n_used = 8; q.n_tok = 1; q.name = "blk.3.ffn_up_exps";
        q.src1_f32 = q.src2_i32 = q.contiguous0 = q.contiguous1 = true; q.align_bytes = 128;
        CHECK(!resolve_admission(q, c).admitted(), "C3a K=255 q4_K 不准入");
        q.K = 256;
        CHECK(resolve_admission(q, c).admitted(), "C3b K=256 q4_K 准入");
        q.type = RTYPE_Q3_K; q.E = 1;
        CHECK(!resolve_admission(q, c).admitted(), "C3c q3_K E=1 拒（supports_op:10398）");
        q.E = 8; q.n_used = (1 << 20); q.n_tok = 2;
        CHECK(!resolve_admission(q, c).admitted(), "C3d n_cols>2^20 拒");
        q.n_used = 8; q.n_tok = 1;

        q.type = RTYPE_Q4_K; q.is_view = true; q.view_slot_aligned = true;
        RouteResult rv = resolve(q, c);
        CHECK(!rv.admitted() || rv.spec->kind != BATCHED_MOE, "C3e q4_K view 不得 batched（G-740 无 es_base）");
        CHECK(rv.admitted() && rv.spec->kind == DENSE_LOOP && rv.refuse_detail &&
              strstr(rv.refuse_detail, "batched refused") != nullptr,
              "C3e' view 落 dense 且留痕 batched 被拒");
        q.type = RTYPE_Q3_K; q.view_slot_aligned = false;
        CHECK(!resolve(q, c).admitted(), "C3f q3_K view 未对齐拒");
        q.view_slot_aligned = true;
        RouteResult r3 = resolve(q, c);
        CHECK(r3.admitted() && r3.spec->kind == BATCHED_MOE, "C3g q3_K view 对齐放行（M2 slot bank）");
    }

    // C4: G-740 漂移点显式 pin——dense 分支不查名字/代际：
    //     名字不含 ffn/exps/as 的 q4_K expert 形状，supports_op 照样按 dense 准入
    //     （set_tensor 却不会为它建 noshuffle 平面 ⇒ 运行期 batched 拒名字门后 dense-loop
    //       拿到的是未特化布局——这是 R2 要收口的结构性漂移，R1 先钉住现状）。
    {
        RouteQuery q = {};
        q.op = ROUTE_MUL_MAT_ID; q.type = RTYPE_Q4_K; q.K = 512; q.M = 512; q.E = 8;
        q.n_used = 8; q.n_tok = 1; q.name = "w_exps";
        q.src1_f32 = q.src2_i32 = q.contiguous0 = q.contiguous1 = true; q.align_bytes = 128;
        RouteResult adm = resolve_admission(q, c);
        CHECK(adm.admitted() && adm.spec->kind == DENSE_LOOP,
              "C4a 漂移 pin：dense 准入不看名字（现状=legacy）");
        RouteResult rs = resolve(q, c);
        CHECK(rs.admitted() && rs.spec->kind == DENSE_LOOP,
              "C4b 派发镜像：batched 拒名字门后落 dense（refuse_detail 应留痕）");
        CHECK(rs.refuse_detail && strstr(rs.refuse_detail, "batched refused"),
              "C4c 漂移留痕：resolve 结果须标注 batched 被拒");
    }

    // C5: dense_off（DENSE_MOE=0）→ Q4_0 全家 CPU（legacy：dense 分支跳过、vendor 需 env）
    {
        RouteContext off = c; off.dense_off = true;
        RouteQuery q = {};
        q.op = ROUTE_MUL_MAT_ID; q.type = RTYPE_Q4_0; q.K = 1536; q.M = 512; q.E = 128;
        q.n_used = 8; q.n_tok = 1; q.name = "blk.3.ffn_gate_exps";
        q.src1_f32 = q.src2_i32 = q.contiguous0 = q.contiguous1 = true; q.align_bytes = 128;
        CHECK(!resolve_admission(q, off).admitted(), "C5a dense_off → CPU");
        CHECK(!resolve(q, off).admitted(), "C5b dense_off 派发 → CPU");
        off.vendor_diag = true;   // vendor_diag 时 Q4_0 走 vendor 诊断（legacy 同）
        RouteResult rv = resolve_admission(q, off);
        CHECK(rv.admitted() && rv.spec->kind == VENDOR_KERNEL, "C5c dense_off+vendor_diag → vendor");
    }

    // C6: batched_off（BATCHED_MOE=0）→ Q4_0 直落 dense（A/B 基准开关语义）
    {
        RouteContext off = c; off.batched_off = true;
        RouteQuery q = {};
        q.op = ROUTE_MUL_MAT_ID; q.type = RTYPE_Q4_0; q.K = 1536; q.M = 512; q.E = 128;
        q.n_used = 8; q.n_tok = 1; q.name = "blk.3.ffn_gate_exps";
        q.src1_f32 = q.src2_i32 = q.contiguous0 = q.contiguous1 = true; q.align_bytes = 128;
        RouteResult r = resolve(q, off);
        CHECK(r.admitted() && r.spec->kind == DENSE_LOOP, "C6 batched_off → dense-loop");
    }

    // C7: 源类型/contiguity 拒绝
    {
        RouteQuery q = {};
        q.op = ROUTE_MUL_MAT_ID; q.type = RTYPE_Q4_0; q.K = 1536; q.M = 512; q.E = 128;
        q.n_used = 8; q.n_tok = 1; q.name = "blk.3.ffn_gate_exps";
        q.src2_i32 = q.contiguous0 = q.contiguous1 = true; q.src1_f32 = false; q.align_bytes = 128;
        CHECK(!resolve_admission(q, c).admitted(), "C7a src1 非 F32 拒");
        q.src1_f32 = true; q.contiguous1 = false;
        CHECK(!resolve_admission(q, c).admitted(), "C7b src1 非 contiguous 拒");
    }

    printf("C 普查 fixture：通过\n");
}

int main() {
    printf("== tongyi route table R1 test ==\n");
    family_a();
    family_b();
    family_c();
    printf("== %d pass, %d fail ==\n", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}
