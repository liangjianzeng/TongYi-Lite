// g1_ssm_layer.cl -- G1 逐层巨核：ling/qwen3next GDN 层 decode 单 token 三阶段（正文实现）
//
// ⚠ 原型实现，未接入派发（不改 ggml-opencl.cpp / route table / CMakeLists）。
//   对拍探针 = g1_layer_probe（照 moe_probe 模板）；接入清单见
//   docs/g1_layer_megakernel_设计_2026-10-25.md §10。
//
// 硬约束（真机实测，违反即死）：
//   [R-005] Adreno 跨 WG 全局栅栏判死——liveness 740=2/830=4 WG，且自旋栅栏单轮
//           122~3518µs > 一次 launch 税（8.26~32.69µs）。本文件**只允许**：
//           ① 阶段内 barrier()（WG 内，spec 保证）；
//           ② 阶段边界 = kernel launch 边界（host 侧同步）。
//   [R-005] 旧式 atomics only——本文件无 atomics（不需要）。
//   [E031]  不用 sub-group 原语——归约全走 __local，无回退路径需求
//           （有 subgroup 的优化版将来参照 gated_delta_net.cl 双路写法另立）。
//
// 语义对齐（llama.cpp 源，decode n_tokens=1，legacy qkvz 路径）：
//   stage1（H_K 个 WG，每 k 头 1 个）：
//     - in_proj GEMV（q4_0，本 k 头 QKVZ_NEW 列）+ ba GEMV（f32，本 k 头 2*RF 列
//       各 WG 自算，等价于全量 ba GEMV 一次，qwen3next.cpp:415-426）
//     - beta=sigmoid(b)、gate=softplus(a+ssm_dt)*ssm_a（:437-447）
//     - conv1d：窗口 = conv_state(D_CONV-1 行) + 本 token 混合值，核布局 w[c*D_CONV+t]
//       （ssm_conv CPU 口径 ggml-cpu/ops.cpp ggml_compute_forward_ssm_conv_f32；
//       conv_input=concat(state, qkv_mixed^T) delta-net-base.cpp:440-460）
//     - silu（:467）
//     - q/k 逐头 l2norm：x * S_K/sqrt(Σx²+eps)（build_gdn_l2_norm models.h:14
//       = scale(rms_norm(x,eps/n), 1/sqrt(n)) 的闭式解，:503-504）
//     - v-head interleave：repeat_factor RF=H_V/H_K，v 头 2g+r ← k 头 g 的第 r 段
//       （ggml_repeat_4d reshape 语义，:513-531）
//     - conv_state 滚动直写（消灭 build_conv_state 末尾 cpy，delta-net-base.cpp:476-493）
//   stage2（H_V 个 WG，每 v 头 1 个）GDN AR（delta-net-base.cpp:286-368，K=1）：
//     s*=exp(g) → sk_j=Σ_i s[i,j]*k[i] → d=(v-sk)*β → s+=k⊗d → o_j=Σ_i s[i,j]*q[i]
//     （q 预乘 1/sqrt(S_K)，:316-318）。state 布局 [S_V,S_V,H_V] 列主：
//     S(i,j) = state[h*S_V² + j*S_V + i]（ggml reshape ne[0] 最快 + sum_rows 口径），
//     线程=列 → S 访问全连续。尾部融合 gated RMSNorm（qwen3next.cpp:223-229
//     build_norm_gated：norm*ssm_norm*silu(z)）——norm 只依赖本头 o，融进 stage2
//     消灭 stage3 前置依赖，保住全层 3 launch。
//   stage3（N_EMBD/64 个 WG）o_proj GEMV（q4_0）：lane=输出列，无归约无 barrier。
//
// scratch 布局（global float*，stage1 写 stage2/3 读）：
//   [0)                       q    [H_V,S_K]   已 l2norm（v 头序，v 头 h = k 头 h/2）
//   [H_V*S_K)                 k    [H_V,S_K]   已 l2norm
//   [2*H_V*S_K)               v    [H_V,S_V]   已 silu(conv)
//   [2*H_V*S_K+H_V*S_V)       z    [H_V,S_V]   未门控（stage2 尾消费）
//   [2*H_V*S_K+2*H_V*S_V)     gate [H_V]       softplus(a+dt)*a 已算好
//   [...+H_V)                 beta [H_V]       sigmoid(b) 已算好
//   stage2 出 out = gated normed [H_V,S_V]（= final_output，h*S_V+j 序）
//
// 编译期维度参数（-D 注入，接入时从 GGUF hparams 绑定；这里给 ling tiny 形状默认）：
#ifndef N_EMBD
#define N_EMBD 2048          // 层输入/输出 hidden
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
#ifndef L2_EPS
#define L2_EPS 1e-6f         // f_norm_rms_eps（l2norm 与 ssm_norm 同源）
#endif
#ifndef RMS_EPS
#define RMS_EPS 1e-6f        // ssm_norm RMS eps
#endif
#ifndef WG1
#define WG1 64               // stage1 工作组大小
#endif
#ifndef WG2
#define WG2 128              // stage2 工作组大小（= S_V，一线程一列）
#endif
#ifndef WG3
#define WG3 64               // stage3 工作组大小（一 lane 一输出列）
#endif

#define QKVZ_NEW   (2*S_K + 2*S_V*(H_V/H_K))       // 每 k 头混合块 q|k|v|z（:313）
#define QKVZ_DIM   (H_K * QKVZ_NEW)                // in_proj 输出行数
#define BA_NEW     (2*(H_V/H_K))                   // 每 k 头 b|a（:425-428）
#define BA_DIM     (H_K * BA_NEW)
#define RF         (H_V/H_K)                       // repeat factor
#define CONV_NEW   (2*S_K + S_V*RF)                // 每 k 头 conv 通道数 q|k|v
#define CC         (2*H_K*S_K + H_V*S_V)           // conv 通道总数（:448）
#define QKV_BLOCKS (N_EMBD/32)                     // q4_0 每行块数
#define OUT_BLOCKS ((H_V*S_V)/32)                  // o_proj 每行块数
#define SCR_K_OFF     (H_V*S_K)
#define SCR_V_OFF     (2*H_V*S_K)
#define SCR_Z_OFF     (2*H_V*S_K + H_V*S_V)
#define SCR_GATE_OFF  (2*H_V*S_K + 2*H_V*S_V)
#define SCR_BETA_OFF  (SCR_GATE_OFF + H_V)
// stage1 local 布局（单 local 指针切片）
#define L_X      0
#define L_QKVZ   (N_EMBD)
#define L_CONV   (N_EMBD + QKVZ_NEW)
#define L_BA     (N_EMBD + QKVZ_NEW + CONV_NEW)
#define L1_SIZE  (N_EMBD + QKVZ_NEW + CONV_NEW + BA_NEW)

static inline float silu1(float v)     { return v / (1.0f + exp(-v)); }
static inline float softplus1(float v) { return v > 20.0f ? v : log1p(exp(v)); }

// q4_0：18B/块 = f16 scale + 16B nibble。ggml 主约定（与 kernels/ 内
// gemv_noshuffle_q4_0_f32.cl 的 bits4 展开一致）：偶数位 = 低 nibble。
static inline float q4_scale(global const uchar * blk) {
    return (float) as_half((ushort)(blk[0] | ((ushort)blk[1] << 8)));
}
static inline float q4_val(global const uchar * blk, const uint i) {
    const uchar b = blk[2 + (i >> 1)];
    return (float)(((i & 1) ? (b >> 4) : (b & 0xF)) - 8);
}

// q4_0 行 × x 点积：wrow = 该行首块，nblk 行内块数，x 点积向量（local 或 global）
#define Q4_DOT(acc, wrow, nblk, xp)                \
    do {                                           \
        (acc) = 0.0f;                              \
        for (uint b_ = 0; b_ < (nblk); ++b_) {     \
            global const uchar * blk_ = (wrow) + b_*18; \
            const float d_ = q4_scale(blk_);       \
            float s_ = 0.0f;                       \
            for (uint t_ = 0; t_ < 32; ++t_)       \
                s_ += q4_val(blk_, t_) * (xp)[b_*32 + t_]; \
            (acc) += s_ * d_;                      \
        }                                          \
    } while (0)

// ---------------------------------------------------------------------------
// stage1：in_proj + ba GEMV、gate/beta、conv1d、silu、l2norm、interleave、
//         conv_state 滚动。grid = H_K 个 WG（每 k 头 1 个），WG = WG1 线程。
// ---------------------------------------------------------------------------
kernel void g1_ssm_stage1_proj(
        global const uchar * W_in,        // q4_0 [QKVZ_DIM, N_EMBD] 行主
        global const float  * W_ba,       // f32  [BA_DIM, N_EMBD] 行主
        global const float  * x,          // [N_EMBD] 本 token 输入
        global const float  * ssm_dt,     // [H_V] softplus 偏置
        global const float  * ssm_a,      // [H_V] -A_log.exp() 门系数
        global const float  * w_conv,     // [CC, D_CONV]（w[c*D_CONV+t]）
        global const float  * conv_state, // [D_CONV-1, CC] 上一 token 状态
        global float        * scratch,    // 见文件头 scratch 布局
        global float        * conv_state_out, // [D_CONV-1, CC] 滚动后
        local  float        * lmem)       // [L1_SIZE]
{
    const uint lid = get_local_id(0);
    const uint g   = get_group_id(0);            // k 头 id

    for (uint i = lid; i < N_EMBD; i += WG1) lmem[i] = x[i];
    barrier(CLK_LOCAL_MEM_FENCE);

    // (1) in_proj GEMV：本 k 头 QKVZ_NEW 列，lane 跨列步进
    for (uint col = lid; col < QKVZ_NEW; col += WG1) {
        global const uchar * wrow = W_in + (size_t)(g*QKVZ_NEW + col) * QKV_BLOCKS * 18;
        float acc;
        Q4_DOT(acc, wrow, QKV_BLOCKS, lmem);
        lmem[L_QKVZ + col] = acc;
    }
    barrier(CLK_LOCAL_MEM_FENCE);

    // (2) ba GEMV：本 k 头 BA_NEW 列（b=前 RF 列 / a=后 RF 列，qwen3next.cpp:426-440）
    //     各 k 头 WG 自算 4 列 = 全量 64 列恰好各算一次，无需独立 ba WG
    if (lid < BA_NEW) {
        global const float * wrow = W_ba + (size_t)(g*BA_NEW + lid) * N_EMBD;
        float acc = 0.0f;
        for (uint i = 0; i < N_EMBD; ++i) acc += wrow[i] * lmem[i];
        lmem[L_BA + lid] = acc;
    }
    barrier(CLK_LOCAL_MEM_FENCE);

    // (3) conv1d + silu：本 k 头通道区（q[c_q0..)、k[c_k0..)、v[c_v0..)）。
    //     conv 通道与 L_QKVZ/L_CONV 内偏移同序：t∈[0,S_K)=q、[S_K,2S_K)=k、
    //     [2S_K,CONV_NEW)=v，lofs = t 恒成立。t=D_CONV-1 窗口行 = 本 token 混合值。
    const uint c_q0 = g*S_K;
    const uint c_k0 = H_K*S_K + g*S_K;
    const uint c_v0 = 2*H_K*S_K + g*S_V*RF;
    for (uint t = lid; t < CONV_NEW; t += WG1) {
        const uint c = (t < S_K) ? (c_q0 + t)
                     : (t < 2*S_K) ? (c_k0 + (t - S_K))
                     : (c_v0 + (t - 2*S_K));
        float acc = 0.0f;
        for (uint w = 0; w < D_CONV-1; ++w)
            acc += conv_state[(size_t)w*CC + c] * w_conv[(size_t)c*D_CONV + w];
        acc += lmem[L_QKVZ + t] * w_conv[(size_t)c*D_CONV + (D_CONV-1)];
        lmem[L_CONV + t] = silu1(acc);
    }
    barrier(CLK_LOCAL_MEM_FENCE);

    // (4) q/k l2norm（闭式因子 S_K/sqrt(Σx²+eps)）→ interleave 写 v 头 2g/2g+1
    if (lid == 0) {
        float ss = 0.0f;
        for (uint t = 0; t < S_K; ++t) { const float v_ = lmem[L_CONV + t]; ss += v_*v_; }
        const float f = (float)S_K / sqrt(ss + L2_EPS);
        for (uint t = 0; t < S_K; ++t) {
            const float v_ = lmem[L_CONV + t] * f;
            scratch[2*g*S_K + t]         = v_;   // v 头 2g
            scratch[(2*g+1)*S_K + t]     = v_;   // v 头 2g+1
        }
        ss = 0.0f;
        for (uint t = 0; t < S_K; ++t) { const float v_ = lmem[L_CONV + S_K + t]; ss += v_*v_; }
        const float fk = (float)S_K / sqrt(ss + L2_EPS);
        for (uint t = 0; t < S_K; ++t) {
            const float v_ = lmem[L_CONV + S_K + t] * fk;
            scratch[SCR_K_OFF + 2*g*S_K + t]     = v_;
            scratch[SCR_K_OFF + (2*g+1)*S_K + t] = v_;
        }
        // (6) gate/beta（每 k 头 RF 个 v 头）
        for (uint r = 0; r < RF; ++r) {
            const float b = lmem[L_BA + r];
            const float a = lmem[L_BA + RF + r];
            scratch[SCR_BETA_OFF + 2*g + r] = 1.0f / (1.0f + exp(-b));
            scratch[SCR_GATE_OFF + 2*g + r] = softplus1(a + ssm_dt[2*g + r]) * ssm_a[2*g + r];
        }
    }
    // (5) v 直通 + z 直通（interleave：v 头 2g+r ← 段 r）
    for (uint t = lid; t < S_V*RF; t += WG1) {
        scratch[SCR_V_OFF + (2*g + t/S_V)*S_V + (t%S_V)] = lmem[L_CONV + 2*S_K + t];
        scratch[SCR_Z_OFF + (2*g + t/S_V)*S_V + (t%S_V)] = lmem[L_QKVZ + 2*S_K + t];
    }

    // (7) conv_state 滚动直写：out[0]=in[1]、out[1]=in[2]、out[2]=本 token 混合值
    for (uint t = lid; t < CONV_NEW; t += WG1) {
        const uint c = (t < S_K) ? (c_q0 + t)
                     : (t < 2*S_K) ? (c_k0 + (t - S_K))
                     : (c_v0 + (t - 2*S_K));
        conv_state_out[(size_t)0*CC + c] = conv_state[(size_t)1*CC + c];
        conv_state_out[(size_t)1*CC + c] = conv_state[(size_t)2*CC + c];
        conv_state_out[(size_t)2*CC + c] = lmem[L_QKVZ + t];
    }
}

// ---------------------------------------------------------------------------
// stage2：GDN AR 步（逐 v 头，K=1）+ 尾部融合 gated RMSNorm。
//   grid = H_V 个 WG（每 v 头 1 个），WG = WG2 线程（一线程一列）。
//   state 直接 RMW（消灭 SCALE→GET_ROWS→CPY 状态链）；
//   归约列主：线程=列，S 列访问连续（S(i,j)=S[j*S_V+i]）。
// ---------------------------------------------------------------------------
kernel void g1_ssm_stage2_gdn(
        global const float * scratch,    // stage1 出（布局见文件头，段偏移=编译期常量）
        global const float * rms_w,      // [S_V] ssm_norm
        global float       * state,      // [H_V,S_V,S_V] 常驻 state，直接 RMW
        global float       * out,        // [H_V,S_V] gated normed 输出
        local  float       * red)        // [S_V+1]：red[0..S_V)=列暂存，red[S_V]=rms 因子
{
    const uint h   = get_group_id(0);
    const uint lid = get_local_id(0);
    global const float * q    = scratch;
    global const float * k    = scratch + SCR_K_OFF;
    global const float * v    = scratch + SCR_V_OFF;
    global const float * gate = scratch + SCR_GATE_OFF;
    global const float * beta = scratch + SCR_BETA_OFF;
    global const float * z    = scratch + SCR_Z_OFF;
    global float * S = state + (size_t)h * S_V * S_V;

    const float gexp = exp(gate[h]);
    const float b    = beta[h];
    const float qs   = 1.0f / sqrt((float)S_K);

    // (1) 衰减 s *= exp(g)（原地，全局 RMW）
    for (uint idx = lid; idx < S_V*S_V; idx += WG2) S[idx] *= gexp;
    barrier(CLK_GLOBAL_MEM_FENCE | CLK_LOCAL_MEM_FENCE);

    // (2) sk_j = Σ_i S[i,j]*k[i]（线程=列 j，S 列连续）
    for (uint j = lid; j < S_V; j += WG2) {
        float acc = 0.0f;
        for (uint i = 0; i < S_V; ++i) acc += S[j*S_V + i] * k[h*S_K + i];
        red[j] = acc;
    }
    barrier(CLK_LOCAL_MEM_FENCE);

    // (3) d_j = (v_j - sk_j) * beta（复用 red）
    for (uint j = lid; j < S_V; j += WG2)
        red[j] = (v[h*S_V + j] - red[j]) * b;
    barrier(CLK_LOCAL_MEM_FENCE);

    // (4) S[i,j] += k[i]*d[j]（外积行加，线程=列连续写）
    for (uint j = lid; j < S_V; j += WG2) {
        const float dj = red[j];
        for (uint i = 0; i < S_V; ++i) S[j*S_V + i] += k[h*S_K + i] * dj;
    }
    barrier(CLK_GLOBAL_MEM_FENCE | CLK_LOCAL_MEM_FENCE);

    // (5) o_j = Σ_i S[i,j]*q[i] * (1/sqrt(S_K))（q 预乘，:316-318）
    for (uint j = lid; j < S_V; j += WG2) {
        float acc = 0.0f;
        for (uint i = 0; i < S_V; ++i) acc += S[j*S_V + i] * q[h*S_K + i];
        red[j] = acc * qs;
    }
    barrier(CLK_LOCAL_MEM_FENCE);

    // (6) gated RMSNorm（本头内归约）：o*rms_factor*w[j]*silu(z[j])
    if (lid == 0) {
        float ss = 0.0f;
        for (uint j = 0; j < S_V; ++j) { const float o_ = red[j]; ss += o_*o_; }
        red[S_V] = 1.0f / sqrt(ss / S_V + RMS_EPS);
    }
    barrier(CLK_LOCAL_MEM_FENCE);

    const float f = red[S_V];
    for (uint j = lid; j < S_V; j += WG2)
        out[h*S_V + j] = red[j] * f * rms_w[j] * silu1(z[h*S_V + j]);
}

// ---------------------------------------------------------------------------
// stage3：o_proj GEMV（q4_0）。grid = N_EMBD/WG3 个 WG，lane = 输出列，
//   无归约无 barrier（x = stage2 出的 gated output，全局广播读）。
// ---------------------------------------------------------------------------
kernel void g1_ssm_stage3_out(
        global const float * fin,        // [H_V*S_V] stage2 gated 输出
        global const uchar * W_out,      // q4_0 [N_EMBD, H_V*S_V] 行主
        global float       * y)          // [N_EMBD] 层输出
{
    const uint lid = get_local_id(0);
    const uint col = get_group_id(0) * WG3 + lid;
    if (col >= N_EMBD) return;

    global const uchar * wrow = W_out + (size_t)col * OUT_BLOCKS * 18;
    float acc;
    Q4_DOT(acc, wrow, OUT_BLOCKS, fin);
    y[col] = acc;
}
