// tongyi_route_table.cpp —— MoE MUL_MAT_ID 路由表本体（R1）
// [tongyi R1 2026-10-25] 行为零变化承诺：本表 R1 只做查表决策镜像 + 记账；
// 等价性由 tongyi_route_table_test.cpp 的 legacy 参照实现钉死（断言逐 case 对拍）。
// 镜像源码（git=41ae9a72 + G-725 插桩 865f75cd）：
//   use_adreno_moe_kernels      ggml-opencl.cpp:9662
//   moe_use_dense_loop          ggml-opencl.cpp:9728
//   supports_op MUL_MAT_ID      ggml-opencl.cpp:10338-10423
//   派发器 ggml_cl_mul_mat_id   ggml-opencl.cpp:29586-29705
//   batched 静态门（G-725 后）   ggml-opencl.cpp:25046-25200
#include "tongyi_route_table.h"

#include <string.h>

namespace tongyi {

// ---- 表本体：一行一路线。改行先看 owner。 ----

// batched 行的静态门 = legacy batched gate 0/1/4/5/6/7/8（平面/extras/对齐是运行时门，
// R1 留给旧门，R2 并入 plane 需求检查）。
static const RouteSpec kSpecs[] = {
    {   // q4_0 batched：K%32 + M%128 + 名字/代际/E17 门；view 禁入（G-740 无 es_base）
        "mmid_q4_0_batched", BATCHED_MOE, RTYPE_Q4_0,
        { /*k_mult*/ 32, /*m_mult*/ 128, /*n_mult_dense*/ 0, /*need_e_gt1*/ false,
          NAME_FFN_EXPS_OR_AS, /*moe_gen_policy*/ true, /*reject_e17*/ true,
          /*forbid_view*/ true, /*view_slot_align*/ false, /*max_cols*/ 1LL << 20 },
        "mmid_q4_0_dense", "dspark",
    },
    {   // q4_K batched：多一道 K%256（superblock scales）；seff/meff 平面是运行时门
        "mmid_q4_k_batched", BATCHED_MOE, RTYPE_Q4_K,
        { 256, 128, 0, false, NAME_FFN_EXPS_OR_AS, true, true, true, false, 1LL << 20 },
        "mmid_q4_k_dense", "dspark",
    },
    {   // q3_K batched-only：K%256 + M%128 + E>1（supports_op:10398 显式门）；
        // view 允许但必须槽位对齐（M2 GPU slot bank 的 es_base 路径）
        "mmid_q3_k_batched", BATCHED_MOE, RTYPE_Q3_K,
        { 256, 128, 0, true, NAME_FFN_EXPS_OR_AS, true, true, false, true, 1LL << 20 },
        "cpu",  // supports_op 同门拒 → 不该被派发进来（派发器 GGML_ABORT 契约）
        "dspark",
    },
    {   // [tongyi M1 2026-10-25] iq4_xs batched-only（G-733 路线① 首个 sub-3bpw 行）：
        // 直读原始块布局（无平面）；view 禁入（无偏移处理）；门集镜像 q3_K
        "mmid_iq4_xs_batched", BATCHED_MOE, RTYPE_IQ4_XS,
        { 256, 128, 0, true, NAME_FFN_EXPS_OR_AS, true, true, true, false, 1LL << 20 },
        "cpu",
        "tongyi-m1",
    },
    {   // q4_0 dense-loop：supports_op dense 分支原公式（名字/代际不查 —— G-740 漂移点，
        // 由测试族 C 显式 pin，R2 决定是否收紧）
        "mmid_q4_0_dense", DENSE_LOOP, RTYPE_Q4_0,
        { 32, 0, 4, false, NAME_ANY, false, false, false, false, 0 },
        "cpu", "dspark",
    },
    {   // q4_K dense-loop：K%256 + N%4 + 子缓冲对齐（s_dm/s_s 也参与）
        "mmid_q4_k_dense", DENSE_LOOP, RTYPE_Q4_K,
        { 256, 0, 4, false, NAME_ANY, false, false, false, false, 0 },
        "cpu", "dspark",
    },
    {   // vendor 诊断行：仅 GGML_OPENCL_MUL_MAT_ID=1；E031.47 损坏证据见 known_bad
        "mmid_vendor_q4_0_diag", VENDOR_KERNEL, RTYPE_Q4_0,
        { 0, 0, 0, false, NAME_ANY, false, false, false, false, 0 },
        "cpu", "dspark",
    },
    {
        "mmid_vendor_q8_0_diag", VENDOR_KERNEL, RTYPE_Q8_0,
        { 0, 0, 0, false, NAME_ANY, false, false, false, false, 0 },
        "cpu", "dspark",
    },
    {
        "mmid_vendor_mxfp4_diag", VENDOR_KERNEL, RTYPE_MXFP4,
        { 0, 0, 0, false, NAME_ANY, false, false, false, false, 0 },
        "cpu", "dspark",
    },
};

static const KnownBadKernel kKnownBad[] = {
    { RCOMP_E031, "E031.47.* (Adreno 830 vendor, OpenCL 0800.71)",
      "gemv_moe_", "_f32_ns",
      "G-739: 真名真形状 NMSE 0.4-2.4（dense-loop 同形状 bit-exact）→ vendor MoE 降级仅诊断" },
    { RCOMP_E031, "E031.47.* (Adreno 830 vendor, OpenCL 0800.71)",
      "gemm_moe_", "_f32_ns",
      "G-739: 同上（gemm 族）" },
    { RCOMP_E031, "E031.41 (usually A7x)",
      "mul_mv_", "_K_f32_flat",
      "G-772: A7X lm_head 默认 CPU 的依据（E031.41 误编译 flat K-quant GEMV）" },
};

// ---- legacy 等价函数（表内唯一「逻辑」，其余全是数据）----

// 镜像 use_adreno_moe_kernels（:9662）。名字/代际/E17 三合一。
bool moe_admission_gate(const RouteQuery & q, const RouteContext & ctx, const char ** why) {
    if (ctx.gen == RGEN_UNKNOWN) { if (why) *why = "gen_unknown"; return false; }
    if (ctx.gen == RGEN_A7X && ctx.moe_a7x_mode == 0) { if (why) *why = "gen_a7x_env_off"; return false; }
    if (ctx.gen == RGEN_A6X && ctx.moe_a7x_mode != 1) { if (why) *why = "gen_a6x_default_off"; return false; }
    if (ctx.compiler == RCOMP_E17 && !ctx.e17_quirks_off) { if (why) *why = "e17_quirks"; return false; }
    const char * n = q.name ? q.name : "";
    const bool name_ok = (strstr(n, "ffn") && strstr(n, "exps")) || strstr(n, "as");
    if (!name_ok) { if (why) *why = "name_not_moe_expert"; return false; }
    if (q.M % 32 != 0) { if (why) *why = "ne01_not_mult32"; return false; }
    if (why) *why = nullptr;
    return true;
}

// 镜像 moe_use_dense_loop（:9728）：env 折算在 ctx。
bool dense_loop_type(RType t, const RouteContext & ctx) {
// [R2 2026-10-25] 公有导出：ggml-opencl 侧 moe_use_dense_loop 薄包装委托到这里。
    if (ctx.dense_off)   return false;
    if (ctx.dense_force) return true;
    if (ctx.vendor_diag) return false;
    return t == RTYPE_Q4_K || t == RTYPE_Q4_0;
}

// 镜像 supports_op dense 分支的切片尺寸公式（:10362-10374）。M 即 dense 门里的 N。
void dense_slice_sizes(RType t, int K, int M, size_t * s_q, size_t * s_d, size_t * s_dm, size_t * s_s) {
    *s_q = *s_d = *s_dm = *s_s = 0;
    if (t == RTYPE_Q4_0) {
        *s_q = (size_t)M * (K / 4)  * 2;
        *s_d = (size_t)M * (K / 32) * 2;
    } else if (t == RTYPE_Q4_K) {
        *s_q  = (size_t)M * (K / 4)   * 2;
        *s_d  = (size_t)M * (K / 256) * 2;
        *s_dm = (size_t)M * (K / 256) * 2;
        *s_s  = (size_t)M * (K / 256) * 12;
    }
}

static bool aligned(size_t v, size_t a) { return a == 0 || v == 0 || v % a == 0; }

// 镜像 supports_op dense 分支（:10354-10383）的形状/对齐门。
static bool dense_static_ok(RType t, const RouteQuery & q, const char ** why) {
    if (!q.src1_f32 || !q.src2_i32)            { if (why) *why = "src_types"; return false; }
    if (!q.contiguous0 || !q.contiguous1)      { if (why) *why = "contiguity"; return false; }
    const bool shape_ok = (t == RTYPE_Q4_0) ? (q.K % 32 == 0) : (q.K % 256 == 0);
    if (!shape_ok)                             { if (why) *why = "k_mult"; return false; }
    if (q.M % 4 != 0)                          { if (why) *why = "n_mult_dense"; return false; }
    size_t s_q = 0, s_d = 0, s_dm = 0, s_s = 0;
    dense_slice_sizes(t, q.K, q.M, &s_q, &s_d, &s_dm, &s_s);
    if (!aligned(s_q, q.align_bytes) || !aligned(s_d, q.align_bytes) ||
        !aligned(s_dm, q.align_bytes) || !aligned(s_s, q.align_bytes)) {
        if (why) *why = "subbuf_align"; return false;
    }
    if (why) *why = nullptr;
    return true;
}

// 镜像 batched 静态门（gate 0/1/4/5/6/7/8；gate 2/3/9 是运行时门）。
static bool batched_static_ok(RType t, const RouteQuery & q, const RouteContext & ctx, const char ** why) {
    if (!q.src1_f32 || !q.src2_i32) { if (why) *why = "src_types"; return false; }
    if (t != RTYPE_Q4_0 && t != RTYPE_Q4_K && t != RTYPE_Q3_K && t != RTYPE_IQ4_XS) { if (why) *why = "quant_type"; return false; }
    const char * gwhy = nullptr;
    if (!moe_admission_gate(q, ctx, &gwhy)) { if (why) *why = gwhy; return false; }
    if (!q.contiguous0 || !q.contiguous1) { if (why) *why = "contiguity"; return false; }
    if (q.is_view) {
        if (t == RTYPE_Q3_K) {
            if (!q.view_slot_aligned) { if (why) *why = "view_slot_q3k"; return false; }
        } else {
            // q4_0/q4_K 无 es_base view 处理（G-740）
            if (why) *why = "view_slot (q4_0/q4_K lack es_base, G-740)";
            return false;
        }
    }
    if (q.K % 32 != 0 || q.M % 128 != 0) { if (why) *why = "shape_align K%32/M%128"; return false; }
    if ((t == RTYPE_Q4_K || t == RTYPE_Q3_K || t == RTYPE_IQ4_XS) && q.K % 256 != 0) { if (why) *why = "shape_align K%256"; return false; }
    if ((t == RTYPE_Q3_K || t == RTYPE_IQ4_XS) && q.E <= 1) { if (why) *why = "e_le_1 (batched-only 家族)"; return false; }
    const long long n_cols = (long long)q.n_used * (long long)q.n_tok;
    if (q.n_used < 1 || q.n_tok < 1 || n_cols > (1LL << 20)) { if (why) *why = "cols_range"; return false; }
    if (why) *why = nullptr;
    return true;
}

static const RouteSpec * find_spec(RType t, RouteKind kind) {
    for (int i = 0; i < spec_count(); ++i) {
        if (kSpecs[i].type == t && kSpecs[i].kind == kind) return &kSpecs[i];
    }
    return nullptr;
}

static RouteResult make_cpu(const RouteSpec * attempted, const char * gate, const char * detail) {
    RouteResult r;
    r.spec = nullptr;
    r.attempted = attempted;
    r.refuse_gate = gate;
    r.refuse_detail = detail;
    return r;
}

// ---- 两个入口 ----

RouteResult resolve_admission(const RouteQuery & q, const RouteContext & ctx) {
    // 1) dense 分支：moe_use_dense_loop(type) && type∈{Q4_0,Q4_K}（:10354-10355）
    if ((q.type == RTYPE_Q4_0 || q.type == RTYPE_Q4_K) && dense_loop_type(q.type, ctx)) {
        const RouteSpec * s = find_spec(q.type, DENSE_LOOP);
        const char * why = nullptr;
        if (dense_static_ok(q.type, q, &why)) {
            RouteResult r; r.spec = s; r.attempted = s; r.refuse_gate = nullptr; r.refuse_detail = nullptr;
            return r;
        }
        // legacy：dense 分支 shape 失败直接 return false，不落 vendor（:10383）
        return make_cpu(s, why, "dense branch refused -> supports_op false");
    }
    // 2) q3_K batched 分支（:10396-10405）——准入门集与 legacy 逐字对齐：
    //    srcs + contig + E>1 + 名字/代际 + K%256/M%128。**不含 view/cols**（那是派发
    //    侧 gate 6/8 的检查；准入放行 view 未对齐张量时派发侧再拒 ⇒ q3_K 无 dense
    //    兜底 = GGML_ABORT 契约风险，由测试族 A 的 hazard pin 显式记录）。
    if (q.type == RTYPE_IQ4_XS && !ctx.batched_off) {
        // [tongyi M1] iq4_xs 准入：镜像 q3_K（batched-only 家族）
        const RouteSpec * s = find_spec(RTYPE_IQ4_XS, BATCHED_MOE);
        const char * why = nullptr;
        const bool ok = q.src1_f32 && q.src2_i32 && q.contiguous0 && q.contiguous1 &&
                        q.E > 1 && moe_admission_gate(q, ctx, &why) &&
                        q.K % 256 == 0 && q.M % 128 == 0;
        if (ok) {
            RouteResult r; r.spec = s; r.attempted = s; r.refuse_gate = nullptr; r.refuse_detail = nullptr;
            return r;
        }
        return make_cpu(s, why ? why : (q.E <= 1 ? "e_le_1" : "shape/srcs"), "iq4_xs branch refused");
    }
    if (q.type == RTYPE_Q3_K && !ctx.batched_off) {
        const RouteSpec * s = find_spec(RTYPE_Q3_K, BATCHED_MOE);
        const char * why = nullptr;
        const bool ok = q.src1_f32 && q.src2_i32 && q.contiguous0 && q.contiguous1 &&
                        q.E > 1 && moe_admission_gate(q, ctx, &why) &&
                        q.K % 256 == 0 && q.M % 128 == 0;
        if (ok) {
            RouteResult r; r.spec = s; r.attempted = s; r.refuse_gate = nullptr; r.refuse_detail = nullptr;
            return r;
        }
        return make_cpu(s, why ? why : (q.E <= 1 ? "e_le_1" : "shape/srcs"), "q3_K branch refused");
    }
    // 3) vendor 诊断分支（:10409-10421）：仅 GGML_OPENCL_MUL_MAT_ID=1
    if (ctx.vendor_diag &&
        (q.type == RTYPE_Q4_0 || q.type == RTYPE_Q8_0 || q.type == RTYPE_MXFP4) &&
        q.src1_f32 && q.contiguous0 && q.contiguous1) {
        const RouteSpec * s = find_spec(q.type, VENDOR_KERNEL);
        RouteResult r; r.spec = s; r.attempted = s; r.refuse_gate = nullptr; r.refuse_detail = nullptr;
        return r;
    }
    return make_cpu(nullptr, "no_route", "type/env 不在任何行");
}

RouteResult resolve(const RouteQuery & q, const RouteContext & ctx) {
    if (q.op != ROUTE_MUL_MAT_ID) {
        return make_cpu(nullptr, "op", "R1 只接管 MUL_MAT_ID");
    }
    if (q.type == RTYPE_Q4_0 || q.type == RTYPE_Q4_K) {
        if (dense_loop_type(q.type, ctx)) {
            // 派发器序：batched 先试（BATCHED_MOE env 门），静态拒 → dense-loop（:29685-29690）
            const RouteSpec * bs = find_spec(q.type, BATCHED_MOE);
            if (!ctx.batched_off && bs) {
                const char * why = nullptr;
                if (batched_static_ok(q.type, q, ctx, &why)) {
                    RouteResult r; r.spec = bs; r.attempted = bs; r.refuse_gate = nullptr; r.refuse_detail = nullptr;
                    return r;
                }
                const RouteSpec * ds = find_spec(q.type, DENSE_LOOP);
                const char * dwhy = nullptr;
                if (dense_static_ok(q.type, q, &dwhy)) {
                    RouteResult r; r.spec = ds; r.attempted = bs; r.refuse_gate = nullptr;
                    r.refuse_detail = "batched refused (runtime planes门仍可能拒)";
                    return r;
                }
                return make_cpu(bs, why, dwhy ? "dense also refused" : nullptr);
            }
            const RouteSpec * ds = find_spec(q.type, DENSE_LOOP);
            const char * dwhy = nullptr;
            if (dense_static_ok(q.type, q, &dwhy)) {
                RouteResult r; r.spec = ds; r.attempted = ds; r.refuse_gate = nullptr; r.refuse_detail = nullptr;
                return r;
            }
            return make_cpu(ds, dwhy, "dense refused");
        }
        // dense_loop type 关（dense_off 或 vendor_diag）：Q4_0 且 vendor_diag → vendor 路径
        if (ctx.vendor_diag && q.type == RTYPE_Q4_0 && q.src1_f32 && q.contiguous0 && q.contiguous1) {
            const RouteSpec * s = find_spec(RTYPE_Q4_0, VENDOR_KERNEL);
            RouteResult r; r.spec = s; r.attempted = s; r.refuse_gate = nullptr; r.refuse_detail = nullptr;
            return r;
        }
        return make_cpu(nullptr, "dense_loop_disabled", "dense_off 且非 vendor 诊断");
    }
    if (q.type == RTYPE_IQ4_XS) {
        const RouteSpec * s = find_spec(RTYPE_IQ4_XS, BATCHED_MOE);
        if (!ctx.batched_off && s) {
            const char * why = nullptr;
            if (batched_static_ok(RTYPE_IQ4_XS, q, ctx, &why)) {
                RouteResult r; r.spec = s; r.attempted = s; r.refuse_gate = nullptr; r.refuse_detail = nullptr;
                return r;
            }
            return make_cpu(s, why, "iq4_xs batched refused");
        }
        return make_cpu(s, "batched_off", "iq4_xs 无 dense 路线");
    }
    if (q.type == RTYPE_Q3_K) {
        const RouteSpec * s = find_spec(RTYPE_Q3_K, BATCHED_MOE);
        if (!ctx.batched_off && s) {
            const char * why = nullptr;
            if (batched_static_ok(RTYPE_Q3_K, q, ctx, &why)) {
                RouteResult r; r.spec = s; r.attempted = s; r.refuse_gate = nullptr; r.refuse_detail = nullptr;
                return r;
            }
            return make_cpu(s, why, "q3_K batched refused");
        }
        return make_cpu(s, "batched_off", "BATCHED_MOE=0 且 q3_K 无 dense 路线");
    }
    if (ctx.vendor_diag &&
        (q.type == RTYPE_Q8_0 || q.type == RTYPE_MXFP4) &&
        q.src1_f32 && q.contiguous0 && q.contiguous1) {
        const RouteSpec * s = find_spec(q.type, VENDOR_KERNEL);
        RouteResult r; r.spec = s; r.attempted = s; r.refuse_gate = nullptr; r.refuse_detail = nullptr;
        return r;
    }
    return make_cpu(nullptr, "no_route", "类型不在任何路线");
}

// ---- 表访问器 ----

const RouteSpec * specs() { return kSpecs; }
int spec_count() { return (int)(sizeof(kSpecs) / sizeof(kSpecs[0])); }
const KnownBadKernel * known_bad() { return kKnownBad; }
int known_bad_count() { return (int)(sizeof(kKnownBad) / sizeof(kKnownBad[0])); }

bool known_bad_lookup(RCompiler c, const char * kernel_name) {
    if (!kernel_name) return false;
    for (int i = 0; i < known_bad_count(); ++i) {
        const bool prefix_hit = strncmp(kernel_name, kKnownBad[i].kernel_prefix, strlen(kKnownBad[i].kernel_prefix)) == 0;
        const bool contains_hit = kKnownBad[i].kernel_contains == nullptr ||
                                  strstr(kernel_name, kKnownBad[i].kernel_contains) != nullptr;
        if (kKnownBad[i].compiler == c && prefix_hit && contains_hit) {
            return true;
        }
    }
    return false;
}

// ---- G-782 尺寸开关：小算子 CPU 路由策略表（改判定 = 改表行，不改逻辑） ----
// [2026-10-25 02:2x 真机判伪定案（740/Ling/贪心短腿）] enabled 全部改 false：
// 政策真开启时 splits 31->215（每 split 边界一次 GPU 排空/同步），tok_s 7.5->2.84
//（-62%）——边界同步税 >> 发射税节省。与 G-769（SSM 判 CPU 138 splits 2.96x 慢）
// 同向实证：本架构下 CPU 岛是毒药；740 launch-bound 出路 = 融合/megakernel 减少
// GPU 算子数，不是搬 CPU。行数据保留（换设备代际/架构后可重开）。
static const SmallOpPolicy kSmallOps[] = {
    { 256, SOP_ARGSORT,  false },
    { 256, SOP_TOP_K,    false },
    { 256, SOP_SET_ROWS, false },
    { 256, SOP_FILL,     false },
    { 256, SOP_SUM_ROWS, false },
    { 256, SOP_SIGMOID,  false },
};

const SmallOpPolicy * small_op_policies(int * count) {
    if (count) *count = (int)(sizeof(kSmallOps) / sizeof(kSmallOps[0]));
    return kSmallOps;
}

bool small_op_to_cpu(SmallOpId op, const int64_t * ne, bool any_buffered) {
    if (op == SOP_NONE || ne == nullptr) return false;
    // 豁免优先：预分配张量搬 CPU = ggml-backend.cpp:1089 abort（G-782 判负教训）
    if (any_buffered) return false;
    // 尺寸门：一维小数组（ne[1..3] 全 1，ne[0] <= 上限）
    if (ne[1] != 1 || ne[2] != 1 || ne[3] != 1) return false;
    for (int i = 0; i < (int)(sizeof(kSmallOps) / sizeof(kSmallOps[0])); ++i) {
        if (kSmallOps[i].op == op && kSmallOps[i].enabled && ne[0] <= kSmallOps[i].max_ne0) {
            return true;
        }
    }
    return false;
}

const char * route_kind_name(RouteKind k) {
    switch (k) {
        case BATCHED_MOE:   return "BATCHED_MOE";
        case DENSE_LOOP:    return "DENSE_LOOP";
        case VENDOR_KERNEL: return "VENDOR_KERNEL";
        case GPU_GENERIC:   return "GPU_GENERIC";
        case CPU_ISLAND:    return "CPU_ISLAND";
    }
    return "?";
}

} // namespace tongyi
