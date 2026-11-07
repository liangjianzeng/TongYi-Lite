R"(// g1_ssm_layer.cl -- G1 逐层巨核：ling/qwen3next GDN 层 decode 单 token 三阶段（正文实现）
)"
R"(//
)"
R"(// ⚠ 原型实现，未接入派发（不改 ggml-opencl.cpp / route table / CMakeLists）。
)"
R"(//   对拍探针 = g1_layer_probe（照 moe_probe 模板）；接入清单见
)"
R"(//   docs/g1_layer_megakernel_设计_2026-10-25.md §10。
)"
R"(//
)"
R"(// 硬约束（真机实测，违反即死）：
)"
R"(//   [R-005] Adreno 跨 WG 全局栅栏判死——liveness 740=2/830=4 WG，且自旋栅栏单轮
)"
R"(//           122~3518µs > 一次 launch 税（8.26~32.69µs）。本文件**只允许**：
)"
R"(//           ① 阶段内 barrier()（WG 内，spec 保证）；
)"
R"(//           ② 阶段边界 = kernel launch 边界（host 侧同步）。
)"
R"(//   [R-005] 旧式 atomics only——本文件无 atomics（不需要）。
)"
R"(//   [E031]  不用 sub-group 原语——归约全走 __local，无回退路径需求
)"
R"(//           （有 subgroup 的优化版将来参照 gated_delta_net.cl 双路写法另立）。
)"
R"(//
)"
R"(// 语义对齐（llama.cpp 源，decode n_tokens=1，legacy qkvz 路径）：
)"
R"(//   stage1（H_K 个 WG，每 k 头 1 个）：
)"
R"(//     - in_proj GEMV（q4_0，本 k 头 QKVZ_NEW 列）+ ba GEMV（f32，本 k 头 2*RF 列
)"
R"(//       各 WG 自算，等价于全量 ba GEMV 一次，qwen3next.cpp:415-426）
)"
R"(//     - beta=sigmoid(b)、gate=softplus(a+ssm_dt)*ssm_a（:437-447）
)"
R"(//     - conv1d：窗口 = conv_state(D_CONV-1 行) + 本 token 混合值，核布局 w[c*D_CONV+t]
)"
R"(//       （ssm_conv CPU 口径 ggml-cpu/ops.cpp ggml_compute_forward_ssm_conv_f32；
)"
R"(//       conv_input=concat(state, qkv_mixed^T) delta-net-base.cpp:440-460）
)"
R"(//     - silu（:467）
)"
R"(//     - q/k 逐头 l2norm：x * S_K/sqrt(Σx²+eps)（build_gdn_l2_norm models.h:14
)"
R"(//       = scale(rms_norm(x,eps/n), 1/sqrt(n)) 的闭式解，:503-504）
)"
R"(//     - v-head interleave：repeat_factor RF=H_V/H_K，v 头 2g+r ← k 头 g 的第 r 段
)"
R"(//       （ggml_repeat_4d reshape 语义，:513-531）
)"
R"(//     - conv_state 滚动直写（消灭 build_conv_state 末尾 cpy，delta-net-base.cpp:476-493）
)"
R"(//   stage2（H_V 个 WG，每 v 头 1 个）GDN AR（delta-net-base.cpp:286-368，K=1）：
)"
R"(//     s*=exp(g) → sk_j=Σ_i s[i,j]*k[i] → d=(v-sk)*β → s+=k⊗d → o_j=Σ_i s[i,j]*q[i]
)"
R"(//     （q 预乘 1/sqrt(S_K)，:316-318）。state 布局 [S_V,S_V,H_V] 列主：
)"
R"(//     S(i,j) = state[h*S_V² + j*S_V + i]（ggml reshape ne[0] 最快 + sum_rows 口径），
)"
R"(//     线程=列 → S 访问全连续。尾部融合 gated RMSNorm（qwen3next.cpp:223-229
)"
R"(//     build_norm_gated：norm*ssm_norm*silu(z)）——norm 只依赖本头 o，融进 stage2
)"
R"(//     消灭 stage3 前置依赖，保住全层 3 launch。
)"
R"(//   stage3（N_EMBD/64 个 WG）o_proj GEMV（q4_0）：lane=输出列，无归约无 barrier。
)"
R"(//
)"
R"(// scratch 布局（global float*，stage1 写 stage2/3 读）：
)"
R"(//   [0)                       q    [H_V,S_K]   已 l2norm（v 头序，v 头 h = k 头 h/2）
)"
R"(//   [H_V*S_K)                 k    [H_V,S_K]   已 l2norm
)"
R"(//   [2*H_V*S_K)               v    [H_V,S_V]   已 silu(conv)
)"
R"(//   [2*H_V*S_K+H_V*S_V)       z    [H_V,S_V]   未门控（stage2 尾消费）
)"
R"(//   [2*H_V*S_K+2*H_V*S_V)     gate [H_V]       softplus(a+dt)*a 已算好
)"
R"(//   [...+H_V)                 beta [H_V]       sigmoid(b) 已算好
)"
R"(//   stage2 出 out = gated normed [H_V,S_V]（= final_output，h*S_V+j 序）
)"
R"(//
)"
R"(// 编译期维度参数（-D 注入，接入时从 GGUF hparams 绑定；这里给 ling tiny 形状默认）：
)"
R"(#ifndef N_EMBD
)"
R"(#define N_EMBD 2048          // 层输入/输出 hidden
)"
R"(#endif
)"
R"(#ifndef S_K
)"
R"(#define S_K 128              // head_k_dim = ssm_d_state
)"
R"(#endif
)"
R"(#ifndef H_K
)"
R"(#define H_K 16               // num_k_heads = ssm_n_group
)"
R"(#endif
)"
R"(#ifndef H_V
)"
R"(#define H_V 32               // num_v_heads = ssm_dt_rank
)"
R"(#endif
)"
R"(#ifndef S_V
)"
R"(#define S_V 128              // head_v_dim = ssm_d_inner / H_v
)"
R"(#endif
)"
R"(#ifndef D_CONV
)"
R"(#define D_CONV 4             // ssm_d_conv（conv1d 核宽）
)"
R"(#endif
)"
R"(#ifndef L2_EPS
)"
R"(#define L2_EPS 1e-6f         // f_norm_rms_eps（l2norm 与 ssm_norm 同源）
)"
R"(#endif
)"
R"(#ifndef RMS_EPS
)"
R"(#define RMS_EPS 1e-6f        // ssm_norm RMS eps
)"
R"(#endif
)"
R"(#ifndef WG1
)"
R"(#define WG1 64               // stage1 工作组大小
)"
R"(#endif
)"
R"(#ifndef WG2
)"
R"(#define WG2 128              // stage2 工作组大小（= S_V，一线程一列）
)"
R"(#endif
)"
R"(#ifndef WG3
)"
R"(#define WG3 64               // stage3 工作组大小（一 lane 一输出列）
)"
R"(#endif
)"
R"(
)"
R"(#define QKVZ_NEW   (2*S_K + 2*S_V*(H_V/H_K))       // 每 k 头混合块 q|k|v|z（:313）
)"
R"(#define QKVZ_DIM   (H_K * QKVZ_NEW)                // in_proj 输出行数
)"
R"(#define BA_NEW     (2*(H_V/H_K))                   // 每 k 头 b|a（:425-428）
)"
R"(#define BA_DIM     (H_K * BA_NEW)
)"
R"(#define RF         (H_V/H_K)                       // repeat factor
)"
R"(#define CONV_NEW   (2*S_K + S_V*RF)                // 每 k 头 conv 通道数 q|k|v
)"
R"(#define CC         (2*H_K*S_K + H_V*S_V)           // conv 通道总数（:448）
)"
R"(#define QKV_BLOCKS (N_EMBD/32)                     // q4_0 每行块数
)"
R"(#define OUT_BLOCKS ((H_V*S_V)/32)                  // o_proj 每行块数
)"
R"(#define SCR_K_OFF     (H_V*S_K)
)"
R"(#define SCR_V_OFF     (2*H_V*S_K)
)"
R"(#define SCR_Z_OFF     (2*H_V*S_K + H_V*S_V)
)"
R"(#define SCR_GATE_OFF  (2*H_V*S_K + 2*H_V*S_V)
)"
R"(#define SCR_BETA_OFF  (SCR_GATE_OFF + H_V)
)"
R"(// stage1 local 布局（单 local 指针切片）
)"
R"(#define L_X      0
)"
R"(#define L_QKVZ   (N_EMBD)
)"
R"(#define L_CONV   (N_EMBD + QKVZ_NEW)
)"
R"(#define L_BA     (N_EMBD + QKVZ_NEW + CONV_NEW)
)"
R"(#define L1_SIZE  (N_EMBD + QKVZ_NEW + CONV_NEW + BA_NEW)
)"
R"(
)"
R"(static inline float silu1(float v)     { return v / (1.0f + exp(-v)); }
)"
R"(static inline float softplus1(float v) { return v > 20.0f ? v : log1p(exp(v)); }
)"
R"(
)"
R"(// q4_0：18B/块 = f16 scale + 16B nibble。ggml 主约定（与 kernels/ 内
)"
R"(// gemv_noshuffle_q4_0_f32.cl 的 bits4 展开一致）：偶数位 = 低 nibble。
)"
R"(static inline float q4_scale(global const uchar * blk) {
)"
R"(    return (float) as_half((ushort)(blk[0] | ((ushort)blk[1] << 8)));
)"
R"(}
)"
R"(static inline float q4_val(global const uchar * blk, const uint i) {
)"
R"(    const uchar b = blk[2 + (i >> 1)];
)"
R"(    return (float)(((i & 1) ? (b >> 4) : (b & 0xF)) - 8);
)"
R"(}
)"
R"(
)"
R"(// q4_0 行 × x 点积：wrow = 该行首块，nblk 行内块数，x 点积向量（local 或 global）
)"
R"(#define Q4_DOT(acc, wrow, nblk, xp)                \
)"
R"(    do {                                           \
)"
R"(        (acc) = 0.0f;                              \
)"
R"(        for (uint b_ = 0; b_ < (nblk); ++b_) {     \
)"
R"(            global const uchar * blk_ = (wrow) + b_*18; \
)"
R"(            const float d_ = q4_scale(blk_);       \
)"
R"(            float s_ = 0.0f;                       \
)"
R"(            for (uint t_ = 0; t_ < 32; ++t_)       \
)"
R"(                s_ += q4_val(blk_, t_) * (xp)[b_*32 + t_]; \
)"
R"(            (acc) += s_ * d_;                      \
)"
R"(        }                                          \
)"
R"(    } while (0)
)"
R"(
)"
R"(// ---------------------------------------------------------------------------
)"
R"(// stage1：in_proj + ba GEMV、gate/beta、conv1d、silu、l2norm、interleave、
)"
R"(//         conv_state 滚动。grid = H_K 个 WG（每 k 头 1 个），WG = WG1 线程。
)"
R"(// ---------------------------------------------------------------------------
)"
R"(kernel void g1_ssm_stage1_proj(
)"
R"(        global const uchar * W_in,        ulong W_in_off,   // q4_0 [QKVZ_DIM, N_EMBD] 行主
)"
R"(        global const float  * W_ba,       ulong W_ba_off,   // f32  [BA_DIM, N_EMBD] 行主
)"
R"(        global const float  * x,          ulong x_off,      // [N_EMBD] 本 token 输入
)"
R"(        global const float  * ssm_dt,     ulong dt_off,     // [H_V] softplus 偏置
)"
R"(        global const float  * ssm_a,      ulong a_off,      // [H_V] -A_log.exp() 门系数
)"
R"(        global const float  * w_conv,     ulong conv_off,   // [CC, D_CONV]（w[c*D_CONV+t]）
)"
R"(        global const float  * conv_state, ulong cs_off,     // [D_CONV-1, CC] 上一 token 状态
)"
R"(        global float        * scratch,    ulong scr_off,    // 见文件头 scratch 布局
)"
R"(        global float        * conv_state_out, ulong cso_off, // [D_CONV-1, CC] 滚动后
)"
R"(        local  float        * lmem)                            // [L1_SIZE]
)"
R"({
)"
R"(    W_in += W_in_off; W_ba += W_ba_off; x += x_off; ssm_dt += dt_off; ssm_a += a_off;
)"
R"(    w_conv += conv_off; conv_state += cs_off; scratch += scr_off; conv_state_out += cso_off;
)"
R"(    const uint lid = get_local_id(0);
)"
R"(    const uint g   = get_group_id(0);            // k 头 id
)"
R"(
)"
R"(    for (uint i = lid; i < N_EMBD; i += WG1) lmem[i] = x[i];
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(    // (1) in_proj GEMV：本 k 头 QKVZ_NEW 列，lane 跨列步进
)"
R"(    for (uint col = lid; col < QKVZ_NEW; col += WG1) {
)"
R"(        global const uchar * wrow = W_in + (size_t)(g*QKVZ_NEW + col) * QKV_BLOCKS * 18;
)"
R"(        float acc;
)"
R"(        Q4_DOT(acc, wrow, QKV_BLOCKS, lmem);
)"
R"(        lmem[L_QKVZ + col] = acc;
)"
R"(    }
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(    // (2) ba GEMV：本 k 头 BA_NEW 列（b=前 RF 列 / a=后 RF 列，qwen3next.cpp:426-440）
)"
R"(    //     各 k 头 WG 自算 4 列 = 全量 64 列恰好各算一次，无需独立 ba WG
)"
R"(    if (lid < BA_NEW) {
)"
R"(        global const float * wrow = W_ba + (size_t)(g*BA_NEW + lid) * N_EMBD;
)"
R"(        float acc = 0.0f;
)"
R"(        for (uint i = 0; i < N_EMBD; ++i) acc += wrow[i] * lmem[i];
)"
R"(        lmem[L_BA + lid] = acc;
)"
R"(    }
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(    // (3) conv1d + silu：本 k 头通道区（q[c_q0..)、k[c_k0..)、v[c_v0..)）。
)"
R"(    //     conv 通道与 L_QKVZ/L_CONV 内偏移同序：t∈[0,S_K)=q、[S_K,2S_K)=k、
)"
R"(    //     [2S_K,CONV_NEW)=v，lofs = t 恒成立。t=D_CONV-1 窗口行 = 本 token 混合值。
)"
R"(    const uint c_q0 = g*S_K;
)"
R"(    const uint c_k0 = H_K*S_K + g*S_K;
)"
R"(    const uint c_v0 = 2*H_K*S_K + g*S_V*RF;
)"
R"(    for (uint t = lid; t < CONV_NEW; t += WG1) {
)"
R"(        const uint c = (t < S_K) ? (c_q0 + t)
)"
R"(                     : (t < 2*S_K) ? (c_k0 + (t - S_K))
)"
R"(                     : (c_v0 + (t - 2*S_K));
)"
R"(        float acc = 0.0f;
)"
R"(        for (uint w = 0; w < D_CONV-1; ++w)
)"
R"(            acc += conv_state[(size_t)w*CC + c] * w_conv[(size_t)c*D_CONV + w];
)"
R"(        acc += lmem[L_QKVZ + t] * w_conv[(size_t)c*D_CONV + (D_CONV-1)];
)"
R"(        lmem[L_CONV + t] = silu1(acc);
)"
R"(    }
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(    // (4) q/k l2norm（闭式因子 S_K/sqrt(Σx²+eps)）→ interleave 写 v 头 2g/2g+1
)"
R"(    if (lid == 0) {
)"
R"(        float ss = 0.0f;
)"
R"(        for (uint t = 0; t < S_K; ++t) { const float v_ = lmem[L_CONV + t]; ss += v_*v_; }
)"
R"(        const float f = 1.0f / sqrt(ss + L2_EPS);   /* build_gdn_l2_norm 闭式 = 1/sqrt(Σx²+eps)（单位 L2 范数；R-018 代数更正） */
)"
R"(        for (uint t = 0; t < S_K; ++t) {
)"
R"(            const float v_ = lmem[L_CONV + t] * f;
)"
R"(            scratch[2*g*S_K + t]         = v_;   // v 头 2g
)"
R"(            scratch[(2*g+1)*S_K + t]     = v_;   // v 头 2g+1
)"
R"(        }
)"
R"(        ss = 0.0f;
)"
R"(        for (uint t = 0; t < S_K; ++t) { const float v_ = lmem[L_CONV + S_K + t]; ss += v_*v_; }
)"
R"(        const float fk = 1.0f / sqrt(ss + L2_EPS);
)"
R"(        for (uint t = 0; t < S_K; ++t) {
)"
R"(            const float v_ = lmem[L_CONV + S_K + t] * fk;
)"
R"(            scratch[SCR_K_OFF + 2*g*S_K + t]     = v_;
)"
R"(            scratch[SCR_K_OFF + (2*g+1)*S_K + t] = v_;
)"
R"(        }
)"
R"(        // (6) gate/beta（每 k 头 RF 个 v 头）
)"
R"(        for (uint r = 0; r < RF; ++r) {
)"
R"(            const float b = lmem[L_BA + r];
)"
R"(            const float a = lmem[L_BA + RF + r];
)"
R"(            scratch[SCR_BETA_OFF + 2*g + r] = 1.0f / (1.0f + exp(-b));
)"
R"(            scratch[SCR_GATE_OFF + 2*g + r] = softplus1(a + ssm_dt[2*g + r]) * ssm_a[2*g + r];
)"
R"(        }
)"
R"(    }
)"
R"(    // (5) v 直通 + z 直通（interleave：v 头 2g+r ← 段 r）
)"
R"(    for (uint t = lid; t < S_V*RF; t += WG1) {
)"
R"(        scratch[SCR_V_OFF + (2*g + t/S_V)*S_V + (t%S_V)] = lmem[L_CONV + 2*S_K + t];
)"
R"(        scratch[SCR_Z_OFF + (2*g + t/S_V)*S_V + (t%S_V)] = lmem[L_QKVZ + 2*S_K + t];
)"
R"(    }
)"
R"(
)"
R"(    // (7) conv_state 滚动直写：out[0]=in[1]、out[1]=in[2]、out[2]=本 token 混合值
)"
R"(    for (uint t = lid; t < CONV_NEW; t += WG1) {
)"
R"(        const uint c = (t < S_K) ? (c_q0 + t)
)"
R"(                     : (t < 2*S_K) ? (c_k0 + (t - S_K))
)"
R"(                     : (c_v0 + (t - 2*S_K));
)"
R"(        conv_state_out[(size_t)0*CC + c] = conv_state[(size_t)1*CC + c];
)"
R"(        conv_state_out[(size_t)1*CC + c] = conv_state[(size_t)2*CC + c];
)"
R"(        conv_state_out[(size_t)2*CC + c] = lmem[L_QKVZ + t];
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(// ---------------------------------------------------------------------------
)"
R"(// stage2：GDN AR 步（逐 v 头，K=1）+ 尾部融合 gated RMSNorm。
)"
R"(//   grid = H_V 个 WG（每 v 头 1 个），WG = WG2 线程（一线程一列）。
)"
R"(//   state 直接 RMW（消灭 SCALE→GET_ROWS→CPY 状态链）；
)"
R"(//   归约列主：线程=列，S 列访问连续（S(i,j)=S[j*S_V+i]）。
)"
R"(// ---------------------------------------------------------------------------
)"
R"(kernel void g1_ssm_stage2_gdn(
)"
R"(        global const float * scratch,    ulong scr_off,  // stage1 出（段偏移=编译期常量）
)"
R"(        global const float * rms_w,      ulong rms_off,  // [S_V] ssm_norm
)"
R"(        global float       * state,      ulong st_off,   // [H_V,S_V,S_V] 常驻 state，直接 RMW
)"
R"(        global float       * out,        ulong out_off,  // [H_V,S_V] gated normed 输出
)"
R"(        local  float       * red)                           // [S_V+1]
)"
R"({
)"
R"(    scratch += scr_off; rms_w += rms_off; state += st_off; out += out_off;
)"
R"(    const uint h   = get_group_id(0);
)"
R"(    const uint lid = get_local_id(0);
)"
R"(    global const float * q    = scratch;
)"
R"(    global const float * k    = scratch + SCR_K_OFF;
)"
R"(    global const float * v    = scratch + SCR_V_OFF;
)"
R"(    global const float * gate = scratch + SCR_GATE_OFF;
)"
R"(    global const float * beta = scratch + SCR_BETA_OFF;
)"
R"(    global const float * z    = scratch + SCR_Z_OFF;
)"
R"(    global float * S = state + (size_t)h * S_V * S_V;
)"
R"(
)"
R"(    const float gexp = exp(gate[h]);
)"
R"(    const float b    = beta[h];
)"
R"(    const float qs   = 1.0f / sqrt((float)S_K);
)"
R"(
)"
R"(    // (1) 衰减 s *= exp(g)（原地，全局 RMW）
)"
R"(    for (uint idx = lid; idx < S_V*S_V; idx += WG2) S[idx] *= gexp;
)"
R"(    barrier(CLK_GLOBAL_MEM_FENCE | CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(    // (2) sk_j = Σ_i S[i,j]*k[i]（线程=列 j，S 列连续）
)"
R"(    for (uint j = lid; j < S_V; j += WG2) {
)"
R"(        float acc = 0.0f;
)"
R"(        for (uint i = 0; i < S_V; ++i) acc += S[j*S_V + i] * k[h*S_K + i];
)"
R"(        red[j] = acc;
)"
R"(    }
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(    // (3) d_j = (v_j - sk_j) * beta（复用 red）
)"
R"(    for (uint j = lid; j < S_V; j += WG2)
)"
R"(        red[j] = (v[h*S_V + j] - red[j]) * b;
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(    // (4) S[i,j] += k[i]*d[j]（外积行加，线程=列连续写）
)"
R"(    for (uint j = lid; j < S_V; j += WG2) {
)"
R"(        const float dj = red[j];
)"
R"(        for (uint i = 0; i < S_V; ++i) S[j*S_V + i] += k[h*S_K + i] * dj;
)"
R"(    }
)"
R"(    barrier(CLK_GLOBAL_MEM_FENCE | CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(    // (5) o_j = Σ_i S[i,j]*q[i] * (1/sqrt(S_K))（q 预乘，:316-318）
)"
R"(    for (uint j = lid; j < S_V; j += WG2) {
)"
R"(        float acc = 0.0f;
)"
R"(        for (uint i = 0; i < S_V; ++i) acc += S[j*S_V + i] * q[h*S_K + i];
)"
R"(        red[j] = acc * qs;
)"
R"(    }
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(    // (6) gated RMSNorm（本头内归约）：o*rms_factor*w[j]*silu(z[j])
)"
R"(    if (lid == 0) {
)"
R"(        float ss = 0.0f;
)"
R"(        for (uint j = 0; j < S_V; ++j) { const float o_ = red[j]; ss += o_*o_; }
)"
R"(        red[S_V] = 1.0f / sqrt(ss / S_V + RMS_EPS);
)"
R"(    }
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(    const float f = red[S_V];
)"
R"(    for (uint j = lid; j < S_V; j += WG2)
)"
R"(        out[h*S_V + j] = red[j] * f * rms_w[j] * silu1(z[h*S_V + j]);
)"
R"(}
)"
R"(
)"
R"(// ---------------------------------------------------------------------------
)"
R"(// stage3：o_proj GEMV（q4_0）。grid = N_EMBD/WG3 个 WG，lane = 输出列，
)"
R"(//   无归约无 barrier（x = stage2 出的 gated output，全局广播读）。
)"
R"(// ---------------------------------------------------------------------------
)"
R"(kernel void g1_ssm_stage3_out(
)"
R"(        global const float * fin,        ulong fin_off,  // [H_V*S_V] stage2 gated 输出
)"
R"(        global const uchar * W_out,      ulong wo_off,   // q4_0 [N_EMBD, H_V*S_V] 行主
)"
R"(        global float       * y,          ulong y_off)    // [N_EMBD] 层输出
)"
R"({
)"
R"(    fin += fin_off; W_out += wo_off; y += y_off;
)"
R"(    const uint lid = get_local_id(0);
)"
R"(    const uint col = get_group_id(0) * WG3 + lid;
)"
R"(    if (col >= N_EMBD) return;
)"
R"(
)"
R"(    global const uchar * wrow = W_out + (size_t)col * OUT_BLOCKS * 18;
)"
R"(    float acc;
)"
R"(    Q4_DOT(acc, wrow, OUT_BLOCKS, fin);
)"
R"(    y[col] = acc;
)"
R"(}
)"
