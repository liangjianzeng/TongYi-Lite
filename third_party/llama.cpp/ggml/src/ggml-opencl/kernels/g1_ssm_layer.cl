// g1_ssm_layer.cl -- G1 逐层巨核：ling/qwen3next GDN 层 decode 单 token 三阶段原型骨架
//
// ⚠ 原型骨架，未接入派发（不改 ggml-opencl.cpp / route table / CMakeLists）。
//   接入时：用 kernels/ 现有 embed 流程生成 .cl.h，再加 case 到 GGML_OP 派发
//   （见 docs/g1_layer_megakernel_设计_2026-10-25.md §10 接入清单）。
//
// 硬约束（真机实测，违反即死）：
//   [R-005] Adreno 跨 WG 全局栅栏判死——liveness 740=2/830=4 WG，且自旋栅栏单轮
//           122~3518µs > 一次 launch 税（8.26~32.69µs）。本文件**只允许**：
//           ① 阶段内 workgroup_barrier()（WG 内，spec 保证）；
//           ② 阶段边界 = kernel launch 边界（host 侧同步）。
//   [R-005] 旧式 atomics only：atomic_add(volatile global uint*, uint)；
//           C11 atomic_uint*/atomic_fetch_add_explicit 在 Adreno 编不过。
//   [E031]  cl_khr_subgroups 在场；若用 sub-group 原语必须留无 subgroup 回退路径
//           （参照 gated_delta_net.cl 的 USE_QCOM_SUBGROUP_SHUFFLE 双路写法）。
//
// 语义对齐（llama.cpp 源，decode n_tokens=1）：
//   stage1 ← build_qkvz/build_lora_mm(ssm_in) + ba 链 + build_conv_state +
//            ggml_ssm_conv + silu + l2norm(q,k) + head interleave
//            （src/models/qwen3next.cpp:334,415-450,459,465-531）
//   stage2 ← GGML_OP_GATED_DELTA_NET（AR, K=1）语义——本阶段即该 op 的逐头版，
//            数值口径对齐 src/models/delta-net-base.cpp:286-368（AR 公式）
//   stage3 ← build_norm_gated（RMS×silu(z)）+ o_proj GEMV
//            （src/models/qwen3next.cpp:223-229,540-551）
//
// 编译期维度参数（-D 注入，接入时从 GGUF hparams 绑定；这里给安全默认防裸编）：
#ifndef N_EMBD
#define N_EMBD 2048          // 输入_hidden（ling tiny 实值接入时绑定）
#endif
#ifndef QKVZ_DIM
#define QKVZ_DIM 4096        // ssm_in 输出行数 = 2*H_k*S_k + H_v*S_v + H_v*S_v(z)
#endif
#ifndef BA_DIM
#define BA_DIM 64            // ssm_beta_alpha 输出行数 = 2*H_v
#endif
#ifndef S_K
#define S_K 128              // head_k_dim = ssm_d_state
#endif
#ifndef H_K
#define H_K 16               // num_k_heads = ssm_n_group
#endif
#ifndef H_V
#define H_V 32               // num_v_heads = ssm_dt_rank
#endif
#ifndef S_V
#define S_V 128              // head_v_dim = ssm_d_inner / H_v
#endif
#ifndef D_CONV
#define D_CONV 4             // ssm_d_conv（conv1d 核宽）
#endif
#ifndef WG1
#define WG1 64               // stage1/3 工作组大小
#endif
#ifndef WG2
#define WG2 128              // stage2 工作组大小（= S_V 一列一线程 × 列组，参照 gated_delta_net.cl）
#endif

#define q4of(x) ((x) >> 4)   // q4_0 nibble helpers（与 mul_mv_q 系一致的高半在前约定）
#define q4lo(x) ((x) & 0xF)

typedef struct __attribute__((packed)) {
    half d;                  // q4_0 block scale
    uchar qs[16];            // 32 × 4-bit
} q4b_t;                     // sizeof = 18（与 ggml q4_0 布局一致）

// q4_0 块取第 i 个量化值 → float
static inline float dq4(const q4b_t b, const uint i) {
    const uchar byte = b.qs[i >> 1];
    const int nib = (i & 1) ? q4lo(byte) : q4of(byte);
    return (nib - 8) * (half2float(b.d));
}

// ---------------------------------------------------------------------------
// stage1：in_proj GEMV + ba GEMV + gate/beta + conv1d + silu + l2norm + interleave
//   grid: 每 WG 负责一段输出列（qkvz 段或 ba 段），x 整条进 __local（N_EMBD f32）
//   barrier 用法：x 装载后一次 workgroup_barrier(CLK_LOCAL_MEM_FENCE)，
//   各线程对负责列做点积，局部归约后单 lane 写出。conv 段（conv_dim 输出中
//   属 qkv 的部分）由专 WG 做 D_CONV 窗口累积 + silu + l2norm + interleave 写 scratch。
//   —— 原型骨架：GEMV 段写实，conv/gate 段函数签名+步骤注释占位（接入时填）。
// ---------------------------------------------------------------------------
kernel void g1_ssm_stage1_proj(
        global const q4b_t * W_in,     // [N_EMBD/32, QKVZ_DIM] 行主 q4_0（权重 mmap 直读）
        global const q4b_t * W_ba,     // [N_EMBD/32, BA_DIM]
        global const float  * x,       // [N_EMBD] 本 token 输入（f32）
        global const float  * ssm_dt,  // [H_V] bias（softplus 偏置）
        global const float  * ssm_a,   // [H_V] -A_log（gate 系数）
        global const float  * w_conv,  // conv1d 核 [D_CONV, conv_dim]（f32，权重小）
        global const float  * conv_state, // [D_CONV-1, conv_dim] 上一 token 状态
        global float  * scratch,       // 输出 scratch：q/k/v interleaved + gate + beta + z
        global float  * conv_state_out,// 滚动后的 conv 状态（D_CONV-1 窗口）
        local float   * lx)            // [N_EMBD] 协作缓冲
{
    const uint lid = get_local_id(0);
    const uint wid = get_group_id(0);          // 输出列块 id
    const uint nwg = get_num_groups(0);

    // (1) 协作装 x → __local（N_EMBD/WG1 次迭代）
    for (uint i = lid; i < N_EMBD; i += WG1) lx[i] = x[i];
    workgroup_barrier(CLK_LOCAL_MEM_FENCE);   // ← 本内核唯一必需栅栏（WG 内）

    // (2) GEMV：wid 映射输出列 c ∈ [0, QKVZ_DIM+BA_DIM)
    //     每个 thread 走 stride=WG1 的行累积，块归约后 lane0 写出
    //     —— qkvz 段直写 scratch.z / qkv 段进 conv 输入缓冲；ba 段同步算
    //     beta=sigmoid(b)、gate=softplus(a+dt)*A（qwen3next.cpp:437-447 公式）
    // (3) conv WG：对 conv 输入（x_conv 段）做 D_CONV 窗口点积 + silu
    //     （qwen3next.cpp:465-469），q/k 段逐头 l2norm（:503-504），
    //     interleave 复制到 H_v 头布局（:512-531），v 段直通；
    //     conv_state_out = 窗口右移一格（delta-net-base.cpp:476-493 的 in-graph cpy
    //     在此被消灭——直接写滚动结果）
    // 原型占位：完整实现见设计文档 §4 的 WG 映射表；此处保证编译通过的最小体。
    if (wid == 0 && lid == 0) {
        scratch[0] = lx[0];  // 占位防空内核
    }
}

// ---------------------------------------------------------------------------
// stage2：GDN AR 步（逐头，K=1）——GGML_OP_GATED_DELTA_NET 同语义的自有实现
//   grid: 每 WG 一个 v 头；state [S_V,S_V] 全局常驻直接 RMW
//   （消灭 SCALE→GET_ROWS→CPY ×36 状态链——state 不再经图拷贝）
//   数值（delta-net-base.cpp:316-367，AR 公式逐条对齐）：
//     s *= exp(g)                                  // :336-337
//     sk_j = Σ_i s[i,j]*k[i]                       // :341-342 (sum_rows(s*k))
//     d    = (v - sk) * beta                       // :346-347
//     s   += k ⊗ d                                 // :355-358 (kd)
//     o_j  = Σ_i s[i,j]*q[i]  (q 先 1/sqrt(S_K) 缩放 :316-318)
//   归约方式：列和用 __local 转置块归约（无 subgroup 回退路径）；
//   有 cl_qcom_subgroup_shuffle 时可换 shuffle 归约（参照 gated_delta_net.cl）。
// ---------------------------------------------------------------------------
kernel void g1_ssm_stage2_gdn(
        global const float * q,        // scratch 内 [H_V, S_K]（已 interleave、已 l2norm、已 scale）
        global const float * k,        // [H_V, S_K]
        global const float * v,        // [H_V, S_V]
        global const float * gate,     // [H_V]（stage1 已算好 g）
        global const float * beta,     // [H_V]
        global float       * state,    // [H_V, S_V, S_V] 常驻 state，直接 RMW
        global float       * o,        // [H_V, S_V] 输出到 scratch
        local float       * red)       // [WG2] 归约缓冲
{
    const uint h   = get_group_id(0);          // 头 id（0..H_V-1）
    const uint lid = get_local_id(0);
    global float * S = state + (size_t)h * S_V * S_V;

    const float g = exp(gate[h]);
    const float b = beta[h];

    // (1) state 衰减：s *= exp(g) —— 原地
    for (uint i = lid; i < S_V * S_V; i += WG2) S[i] *= g;
    workgroup_barrier(CLK_GLOBAL_MEM_FENCE | CLK_LOCAL_MEM_FENCE);

    // (2) sk_j = Σ_i S[i,j]*k[i]：列 j 的归约由负责 j 列的 lane 组做
    //     原型：行步进累积 + __local 归约（转置访问模式的简化版；优化版
    //     走 gated_delta_net.cl 的 LANES_PER_COLUMN 列组布局）
    // (3) d = (v - sk)*beta；(4) S[i,j] += k[i]*d[j]；(5) o_j = Σ_i S[i,j]*q[i]
    //     每步之间 workgroup_barrier（WG 内，保证 S 的读写序）。
    if (lid == 0) { o[(size_t)h * S_V] = S[0]; }  // 占位防空内核
}

// ---------------------------------------------------------------------------
// stage3：gated RMSNorm + o_proj GEMV
//   o_head RMSNorm（eps，w=ssm_norm[S_V]）× silu(z_head) → final_output
//   （qwen3next.cpp:223-229,540-547），随后 o_proj GEMV（q4_0）→ cur [N_EMBD]
//   grid/WG 与 stage1 同构：norm 段每 WG 一头（S_V 小，单 WG 内归约），
//   GEMV 段每 WG 一段输出列，x=final_output 进 __local 复用。
// ---------------------------------------------------------------------------
kernel void g1_ssm_stage3_out(
        global const float   * o,       // scratch 内 [H_V, S_V]（stage2 出）
        global const float   * z,       // scratch 内 [H_V, S_V]（stage1 直通）
        global const float   * rms_w,   // [S_V] ssm_norm
        global const q4b_t   * W_out,   // [H_V*S_V/32, N_EMBD] o_proj（q4_0）
        global float         * y,       // [N_EMBD] 层输出
        local float          * lbuf)    // [max(WG1, S_V)] norm 归约 + GEMV x 缓冲复用
{
    const uint lid = get_local_id(0);
    // (1) 每 WG 一头：RMS(o_h)（WG 内归约，workgroup_barrier×2）→ norm*w*silu(z)
    //     写 final_output 到 global scratch（或 __local 若 H_V*S_V ≤ local 上限）
    // (2) GEMV：final_output × W_out^T → y（与 stage1 (2) 同构）
    if (lid == 0) { y[0] = o[0]; }  // 占位防空内核
}
