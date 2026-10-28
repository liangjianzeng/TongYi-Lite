// tongyi_route_table.h —— MoE MUL_MAT_ID 路由表（tongyi 自研，R1 骨架）
// [tongyi R1 2026-10-25] 唯一事实源 = docs/OpenCL路由表_tongyi_route_table_设计稿_2026-10-24.md
// 纪律（设计稿头部）：本表落地后禁止新增任何 env 逃生门；表外不允许新的 if(getenv(...))。
//
// R1 语义（行为零变化）：表只做「查表即决策 + 记账」，ggml-opencl.cpp 的旧门仍是控制流
// 权威；一致性由 tongyi_route_table_test.cpp 的镜像参照实现钉死，R2 翻转控制流时同一套
// 断言就是迁移门。
//
// 本头保持可独立单测：不 include ggml 内部头 / CL 头。镜像枚举与真枚举的数值对齐由
// ggml-opencl.cpp 里的 static_assert 编译期把守（那里两个世界都可见）。
#ifndef TONGYI_ROUTE_TABLE_H
#define TONGYI_ROUTE_TABLE_H

#include <stddef.h>
#include <stdint.h>

namespace tongyi {

// ---- 输入侧镜像枚举（数值 = 被镜像枚举；ggml-opencl.cpp static_assert 对齐）----

enum RouteOp { ROUTE_MUL_MAT_ID = 0, ROUTE_SMALL_OP_CPU = 1 };

enum RGen { // 镜像 ggml-opencl.cpp 的 ADRENO_GPU_GEN
    RGEN_UNKNOWN = 0,
    RGEN_A6X = 1,
    RGEN_A7X = 2,
    RGEN_A8X = 3,
    RGEN_X1E = 4,
    RGEN_X2E = 5,
};

enum RCompiler { // 镜像 ADRENO_CL_COMPILER_TYPE
    RCOMP_E031 = 0,
    RCOMP_E17 = 1,
    RCOMP_DX = 2,
    RCOMP_UNKNOWN = 3,
};

enum RType { // 镜像 ggml_type（仅路由关心的成员）
    RTYPE_Q4_0 = 2,
    RTYPE_Q4_1 = 3,
    RTYPE_Q5_0 = 6,
    RTYPE_Q5_1 = 7,
    RTYPE_Q8_0 = 8,
    RTYPE_Q3_K = 11,
    RTYPE_Q4_K = 12,
    RTYPE_Q5_K = 13,
    RTYPE_Q6_K = 14,
    RTYPE_IQ4_XS = 23,
    RTYPE_MXFP4 = 39,
};

// ---- 表结构 ----

enum RouteKind {
    BATCHED_MOE,  // 自研单 dispatch gather（q4_0/q4_K/q3_K）
    DENSE_LOOP,   // 自研逐专家 GEMV + kernel_add_row
    VENDOR_KERNEL,// 厂商 gemv_moe/gemm_moe 族（E031.47 已知损坏 → 仅诊断）
    GPU_GENERIC,  // 通用 GPU 路径（R1 未用，占位）
    CPU_ISLAND,   // 显式落 CPU（refuse_gate 必非空）
};

enum NameMatch {
    NAME_ANY = 0,
    NAME_FFN_EXPS_OR_AS = 1, // 含 "ffn" 且含 "exps"，或含 "as"（use_adreno_moe_kernels 原语义）
};

struct GateSpec {
    int       k_mult;           // K % k_mult == 0（0=不限）
    int       m_mult;           // M % m_mult == 0（0=不限）
    int       n_mult_dense;     // dense 子缓冲切片：M % n_mult_dense == 0（0=不限）
    bool      need_e_gt1;       // E > 1
    NameMatch name_match;
    bool      moe_gen_policy;   // 用 use_adreno_moe_kernels 的代际三态策略（A6X/A7X/UNKNOWN）
    bool      reject_e17;       // compiler==E17 拒（E17 quirks；ctx.e17_quirks_off 可豁免）
    bool      forbid_view;      // 无 es_base 处理（网格 G-740：q4_0/q4_K 缺 view 槽位偏移）
    bool      view_slot_align;  // view 允许但必须槽位对齐（q3_K）
    long long max_cols;         // n_used*n_tok 上限（0=不限）
};

struct RouteSpec {
    const char *name;    // "mmid_q4_0_batched" 等；日志/测试定位用
    RouteKind  kind;
    RType      type;     // R1：一行一类型（表更平，匹配直观）
    GateSpec   gates;
    const char *fallback; // 被拒时去的路线名（CPU_ISLAND 兜底时写 "cpu"）
    const char *owner;   // 领地：改这行先找 owner
};

// known_bad_kernels：驱动指纹 × 内核族 → 判决（R3 2026-10-25 全量入表 6 行）。
// 消费方：单测族 B golden + ggml-opencl init 期指纹比对诊断日志（查表即诊断）。
// 版本粒度到编译器型，.47 级精度记在 compiler_pat，R4 成本模型时细化。
// 匹配语义：kernel_prefix 前缀命中 && kernel_contains 子串命中（如
// "gemv_moe_q4_k_f32_ns" 命中 prefix="gemv_moe_" contains="_f32_ns"）。
struct KnownBadKernel {
    RCompiler  compiler;
    const char *compiler_pat;   // 人读版本串（"E031.47.* (Adreno 830 vendor)"）
    const char *kernel_prefix;  // 内核名前缀
    const char *kernel_contains;// 内核名必含子串（nullptr = 不要求）
    const char *evidence;       // 证据文档（网格 G-739 / Ling 回归定位档）
};

// ---- 查询与上下文 ----

struct RouteQuery {
    RouteOp op;
    RType   type;
    int     K;    // src0->ne[0]
    int     M;    // src0->ne[1]
    int     E;    // src0->ne[2]
    int     n_used; // src2->ne[0]
    int     n_tok;  // src2->ne[1]
    const char *name; // src0->name（可空）
    bool    src1_f32;
    bool    src2_i32;
    bool    contiguous0;
    bool    contiguous1;
    bool    is_view;            // src0->view_src != nullptr
    bool    view_slot_aligned;  // q3_K：view_offs % slot_bpe == 0
    size_t  align_bytes;        // backend alignment（dense 子缓冲对齐判定；0=跳过对齐门）
};

struct RouteContext {
    RGen     gen;
    RCompiler compiler;
    bool     is_mesa;
    // env 策略输入（R2 将折进表行；R1 保持原 env 语义逐字等价）
    int      moe_a7x_mode;   // GGML_OPENCL_MOE_FORCE_A7X：-1 未设 / 0 关 / 1 强制
    bool     e17_quirks_off; // GGML_OPENCL_ADRENO_E17_QUIRKS=0
    bool     vendor_diag;    // GGML_OPENCL_MUL_MAT_ID=1（诊断）
    bool     dense_off;      // GGML_OPENCL_DENSE_MOE=0
    bool     dense_force;    // GGML_OPENCL_DENSE_MOE=1
    bool     batched_off;    // GGML_OPENCL_BATCHED_MOE=0
    // [tongyi TYL-UNLOCK-R4 2026-10-28] A 路 view 槽位平移（GGML_OPENCL_MOE_VIEW_SLOT=1，
    // 仅 Mesa/rusticl；一处真源 = ggml-opencl.cpp moe_view_slot_unlock）。
    // true = q4_0/q4_K 的 view 允许 batched，但**必须**槽位对齐（view_slot_aligned）：
    // es_base 由派发侧"子缓冲 origin 平移"承担，语义母本 = q3_K 的
    // kernels/gemv_noshuffle_q3_k_f32.cl:196 (esb = es + es_base)。零内核零新参数。
    // false（默认/未设 env）= 逐字节零扰动，G-740 原判据原样保留。
    // q4_1（环2 挂起）与 iq4_xs（M1 领地，m1 分支自带 src0_off）不受本字段影响，恒拒。
    bool     moe_view_slot;  // GGML_OPENCL_MOE_VIEW_SLOT=1
};

struct RouteResult {
    const RouteSpec *spec;      // 命中的行（admitted 时非空）
    const RouteSpec *attempted; // 因类型选中但被门拒的主行（记账；可能为空）
    const char *refuse_gate;    // 拒绝门名（"k_mult" 等；admitted 时为空）
    const char *refuse_detail;  // 人读细节
    bool admitted() const { return spec != nullptr && refuse_gate == nullptr; }
};

// 派发侧语义：Q4_0/Q4_K 先 batched 后 dense（镜像 ggml_cl_mul_mat_id 派发序）；Q3_K 仅
// batched（失败 = supports_op 同门拒，CPU）；vendor 诊断行仅在 ctx.vendor_diag 时生效。
RouteResult resolve(const RouteQuery &q, const RouteContext &ctx);

// supports_op 语义：dense 分支（Q4_0/Q4_K）→ q3_K batched 分支 → vendor 诊断分支，
// 逐序镜像 legacy ggml_opencl_supports_op 的 MUL_MAT_ID 分支。
RouteResult resolve_admission(const RouteQuery &q, const RouteContext &ctx);

// dense 子缓冲切片尺寸（supports_op dense 分支的原公式；对齐门共用）
void dense_slice_sizes(RType t, int K, int M, size_t *s_q, size_t *s_d, size_t *s_dm, size_t *s_s);

// legacy use_adreno_moe_kernels 的表内等价（名字+代际+E17 三合一门）
bool moe_admission_gate(const RouteQuery &q, const RouteContext &ctx, const char **why);

// legacy moe_use_dense_loop 的表内等价（env 折算进 ctx；R2 起是唯一实现）
bool dense_loop_type(RType t, const RouteContext &ctx);

// ---- G-782 尺寸开关（2026-10-25）：小算子 CPU 路由策略 ----
// 背景：A7X 档每发射 ~400µs 完成往返，decode 期 MoE 路由链的小数组算子
// （ARGSORT/TOP_K/SET_ROWS/FILL/SUM_ROWS/SIGMOID，ne 全 1 除 ne[0]<=256）搬 CPU 更省。
// 名字路由已判负（OPFILTER 撞 KV 预分配 buffer abort，ggml-backend.cpp:1089）；
// 本策略按尺寸判定 + 预分配豁免：任一相关张量（src×3/dst，含 view 溯源）已绑定
// buffer 即不搬（预分配 KV/compute 张量声明 CPU 会撞 abort）。
enum SmallOpId {
    SOP_NONE = 0, SOP_ARGSORT, SOP_TOP_K, SOP_SET_ROWS, SOP_FILL,
    SOP_SUM_ROWS, SOP_SIGMOID,
};
struct SmallOpPolicy {
    int  max_ne0;            // ne[0] 上限（含）
    SmallOpId op;            // 算子（SOP_NONE 行 = 表尾）
    bool enabled;            // 默认开关（表行数据；A/B 用双构建，不加 env）
};
const SmallOpPolicy * small_op_policies(int * count);
// 查表裁决：该 (op, ne) 是否落 CPU。任一 buffered 张量 → false（豁免）。
bool small_op_to_cpu(SmallOpId op, const int64_t * ne,
                     bool any_buffered /*src0/src1/src2/dst(含view_src) 任一 buffer!=null*/);

const RouteSpec *     specs();
int                   spec_count();
const KnownBadKernel *known_bad();
int                   known_bad_count();
bool known_bad_lookup(RCompiler c, const char *kernel_name);

const char *route_kind_name(RouteKind k);

} // namespace tongyi

#endif // TONGYI_ROUTE_TABLE_H
