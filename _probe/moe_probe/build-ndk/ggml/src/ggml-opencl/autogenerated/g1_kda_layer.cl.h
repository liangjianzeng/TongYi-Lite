R"(// g1_kda_layer.cl -- G1 逐层巨核 KDA 变体：ling/bailingmoe3 recr 层 decode 单 token
)"
R"(//                    三阶段（正文实现，R-017）。
)"
R"(//
)"
R"(// ⚠ 原型实现，未接入派发（不改 ggml-opencl.cpp / CMakeLists）。对拍探针 =
)"
R"(//   _probe/g1_probe/g1_kda_probe.cpp（照 g1_layer_probe 模板：dlopen 双栈 +
)"
R"(//   CPU 双精度参考 + 三段逐段读回 NMSE）。规格书 = _probe/g1_probe/KDA_SPEC.md，
)"
R"(//   语义锚点 = src/models/bailingmoe3.cpp:406-443（KDA op 链）+
)"
R"(//   bailingmoe3_causal_conv1d(:182-215)。opA=stage1、opB=stage2+3（拆两 op
)"
R"(//   消 GGML_MAX_SRC=10 限制；三 kernel 结构 / ulong offset / Q4_DOT / 列主 AR
)"
R"(//   归约全部复用 g1_ssm_layer.cl 骨架）。
)"
R"(//
)"
R"(// 硬约束（同 g1_ssm_layer.cl [R-005]/[E031]）：
)"
R"(//   只允许 WG 内 barrier()；阶段边界 = kernel launch 边界；无 atomics、
)"
R"(//   无 sub-group 原语。
)"
R"(//
)"
R"(// 语义对齐（bailingmoe3.cpp，decode n_tokens=1 / n_seqs=1）：
)"
R"(//   stage1（3*H 个 WG，WG=(槽 s, 头 h)）：
)"
R"(//     - 三路 q4_0 GEMV（wq/wk/wv [N_EMBD,D_INNER] 行主，本 WG 本头 D 行）
)"
R"(//       + beta f32 GEMV（gid==0 的 WG 顺带全量 H 列，各恰一次）
)"
R"(//     - 三槽 causal conv（cq/ck/cv [D_CONV,D_INNER]，(w,c) 在 c*D_CONV+w；
)"
R"(//       conv_state [3*(D_CONV-1)*D_INNER] 槽序 q|k|v、**通道主序**（地址 =
)"
R"(//       slot*CS_SLOT + c*(D_CONV-1) + w，与装载器 causal_conv1d 的 conv_state
)"
R"(//       view 同构——R-021 真模型验收：prefill 原链/decode 融合共享同一 RMW 内存，
)"
R"(//       布局必须按原链），**原地 RMW 滚动**：
)"
R"(//       out_w = in_{w+1}（w<D_CONV-2），out_{D_CONV-2} = 本 token 混合值）
)"
R"(//     - silu → q/k 逐头 l2norm（因子 = 1/sqrt(Σx²+eps)，R-018 闭式，
)"
R"(//       与 g1_ssm_layer.cl 一致）→ v 直通 → beta=sigmoid
)"
R"(//     - scratch [3*D_INNER + H] = q|k|v|beta（头内偏移 h*D+j）
)"
R"(//   stage2（H 个 WG，一线程一通道 j，WG2==D）：
)"
R"(//     - gate/ogate 逐通道自算（每通道一个 N_EMBD 点积，bailingmoe3.cpp:415-424）：
)"
R"(//       gate[c] = GATE_LB·sigmoid((f_a·x + dt_b)[c]·ssm_a[h])（LB 负 → gate∈(LB,0)）；
)"
R"(//       ogate[c] = sigmoid(g_a·x)[c]
)"
R"(//     - KDA 行衰减 AR（与 GDN 唯一差异 = 衰减按行向量 g[i]，delta-net-base.cpp
)"
R"(//       build_recurrent_attn KDA 分支 / ggml-cpu ops.cpp:11398-11428 同口径）：
)"
R"(//       sk_j = Σ_i S[j*D+i]·g[i]·k[i]（sk 用衰减后 S）
)"
R"(//       d_j  = (v_j − sk_j)·β_h
)"
R"(//       S[j*D+i] = S[j*D+i]·g[i] + k[i]·d_j   ← 衰减与外积合并单趟（state 存衰减后值）
)"
R"(//       o_j = Σ_i S[j*D+i]·q[i] × 1/sqrt(D)   ← q 预乘口径（同 GDN，op 链 scale）
)"
R"(//     - 尾部融合 gated RMSNorm（bailingmoe3.cpp:439-440）：
)"
R"(//       gated[j] = o_j·(1/sqrt(Σo²/D+rms_eps))·o_norm[j]·ogate[j]
)"
R"(//       写 out 全局 [H*D]（h*D+j 序）。out 可别名 scratch 的 v 段（2*D_INNER 起）：
)"
R"(//       每 WG 只覆写本头段，v 读（d_j）在末 barrier 前完成 —— 别名安全。
)"
R"(//   stage3（N_EMBD/WG3 个 WG，lane=输出列）：wo q4_0 GEMV = GDN stage3 原样。
)"
R"(//
)"
R"(// state 布局：[D,D,H] f32 常驻，列主 S(i,j) = state[h*D² + j*D + i]（同
)"
R"(//   GGML_OP_GATED_DELTA_NET 契约），线程=行 j → S 行访问全连续。
)"
R"(//
)"
R"(// 编译期维度参数（-D 注入，接入时从 GGUF 张量形状绑定；默认给 ling tiny 同量级形状）：
)"
R"(#ifndef N_EMBD
)"
R"(#define N_EMBD 2048          // 层输入/输出 hidden（x->ne[0]）
)"
R"(#endif
)"
R"(#ifndef D
)"
R"(#define D 128                // head_dim = ssm_o_norm->ne[0]（KDA 方阵 state 边长）
)"
R"(#endif
)"
R"(#ifndef H
)"
R"(#define H 32                 // n_head = ssm_a->ne[0]（=beta_w->ne[1]）
)"
R"(#endif
)"
R"(#ifndef D_CONV
)"
R"(#define D_CONV 4             // ssm_q_conv->ne[0]（conv 核宽）
)"
R"(#endif
)"
R"(#ifndef L2_EPS
)"
R"(#define L2_EPS 1e-6f         // f_norm_rms_eps（l2norm）
)"
R"(#endif
)"
R"(#ifndef RMS_EPS
)"
R"(#define RMS_EPS 1e-6f        // ssm_o_norm RMS eps
)"
R"(#endif
)"
R"(#ifndef GATE_LB
)"
R"(#define GATE_LB -8.0f        // hparams.kda_gate_lower_bound（负值）
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
R"(#define WG2 128              // stage2 工作组大小（== D，一线程一通道）
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
R"(#if WG2 != D
)"
R"(#error "g1_kda_layer.cl: stage2 要求 WG2 == D（一线程一通道）"
)"
R"(#endif
)"
R"(
)"
R"(#define D_INNER     (D*H)              // d_inner = head_dim * n_head
)"
R"(#define KDA_BLOCKS  (N_EMBD/32)        // q4_0 每行块数（wq/wk/wv 行长 = N_EMBD）
)"
R"(#define OUT_BLOCKS  (D_INNER/32)       // wo 每行块数（行长 = D_INNER）
)"
R"(#define CS_SLOT     ((D_CONV-1)*D_INNER)  // 每槽 conv_state 大小
)"
R"(// stage1 local 布局：x | 本头混合值(原始,未 silu) | 本头 conv+silu 出 | l2 因子
)"
R"(#define L_X      0
)"
R"(#define L_MIX    (N_EMBD)
)"
R"(#define L_CONV   (N_EMBD + D)
)"
R"(#define L_FACT   (N_EMBD + 2*D)
)"
R"(#define L1_SIZE  (N_EMBD + 2*D + 1)
)"
R"(// stage2 local 布局：ge(行衰减 exp) | og(输出门) | o 归约 | rms 因子
)"
R"(#define L2_SIZE  (3*D + 1)
)"
R"(
)"
R"(static inline float silu1(float v) { return v / (1.0f + exp(-v)); }
)"
R"(
)"
R"(// q4_0：18B/块 = f16 scale + 16B nibble。ggml canonical（quantize_row_q4_0_ref /
)"
R"(// ggml_vec_dot_q4_0_q8_0_generic）：byte j = 低 nibble 存元素 j，高 nibble 存元素 j+16。
)"
R"(static inline float q4_scale(global const uchar * blk) {
)"
R"(    return (float) as_half((ushort)(blk[0] | ((ushort)blk[1] << 8)));
)"
R"(}
)"
R"(static inline float q4_val(global const uchar * blk, const uint i) {
)"
R"(    const uchar b = blk[2 + (i & 15u)];
)"
R"(    return (float)(((i < 16u) ? (b & 0xF) : (b >> 4)) - 8);
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
R"(// stage1（opA）：三路 q4_0 GEMV + beta GEMV + 三槽 conv（原地滚动）+ silu +
)"
R"(//   q/k 逐头 l2norm + beta=sigmoid → scratch [3*D_INNER + H]。
)"
R"(//   grid = 3*H 个 WG（gid = s*H + h），WG = WG1 线程。
)"
R"(// ---------------------------------------------------------------------------
)"
R"(kernel void g1_kda_stage1_in(
)"
R"(        global const uchar * W_q,         ulong Wq_off,   // q4_0 [N_EMBD, D_INNER] 行主（行=通道）
)"
R"(        global const uchar * W_k,         ulong Wk_off,   // 同上
)"
R"(        global const uchar * W_v,         ulong Wv_off,   // 同上
)"
R"(        global const float  * x,          ulong x_off,    // [N_EMBD] 本 token 输入
)"
R"(        global const float  * c_q,        ulong cq_off,   // f32 [D_CONV, D_INNER]（(w,c) 在 c*D_CONV+w）
)"
R"(        global const float  * c_k,        ulong ck_off,   // 同上
)"
R"(        global const float  * c_v,        ulong cv_off,   // 同上
)"
R"(        global const float  * W_beta,     ulong wb_off,   // f32 [N_EMBD, H]（行 h 在 h*N_EMBD）
)"
R"(        global float        * conv_state, ulong cs_off,   // [3*CS_SLOT] RMW 常驻，槽序 q|k|v，通道主序（R-021）
)"
R"(        global float        * scratch,    ulong scr_off,  // [3*D_INNER + H] = q|k|v|beta
)"
R"(        local  float        * lmem)                          // [L1_SIZE]
)"
R"({
)"
R"(    W_q += Wq_off; W_k += Wk_off; W_v += Wv_off; x += x_off;
)"
R"(    c_q += cq_off; c_k += ck_off; c_v += cv_off; W_beta += wb_off;
)"
R"(    conv_state += cs_off; scratch += scr_off;
)"
R"(    const uint lid = get_local_id(0);
)"
R"(    const uint gid = get_group_id(0);
)"
R"(    const uint s   = gid / H;            // 槽 0=q 1=k 2=v
)"
R"(    const uint h   = gid % H;
)"
R"(
)"
R"(    for (uint i = lid; i < N_EMBD; i += WG1) lmem[L_X + i] = x[i];
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(    // (1) beta GEMV（f32，全量 H 列由 gid==0 的 WG 各算一列，恰一次）
)"
R"(    if (gid == 0 && lid < H) {
)"
R"(        global const float * wrow = W_beta + (size_t)lid * N_EMBD;
)"
R"(        float acc = 0.0f;
)"
R"(        for (uint i = 0; i < N_EMBD; ++i) acc += wrow[i] * lmem[L_X + i];
)"
R"(        scratch[3*D_INNER + lid] = 1.0f / (1.0f + exp(-acc));
)"
R"(    }
)"
R"(
)"
R"(    // (2) 本头 D 行 q4_0 GEMV（原始混合值存 L_MIX，供 conv 与 conv_state 滚动共用）
)"
R"(    global const uchar * W = (s == 0) ? W_q : (s == 1) ? W_k : W_v;
)"
R"(    for (uint j = lid; j < D; j += WG1) {
)"
R"(        global const uchar * wrow = W + (size_t)(h*D + j) * KDA_BLOCKS * 18;
)"
R"(        float acc;
)"
R"(        Q4_DOT(acc, wrow, KDA_BLOCKS, lmem + L_X);
)"
R"(        lmem[L_MIX + j] = acc;
)"
R"(    }
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(    // (3) conv + silu：窗口 = conv_state 通道 c 的 D_CONV-1 历史 + 本 token 混合值
)"
R"(    //     （conv_state 通道主序：c*(D_CONV-1)+w，R-021——原链 causal_conv1d view 同构）
)"
R"(    global const float * cw = (s == 0) ? c_q : (s == 1) ? c_k : c_v;
)"
R"(    for (uint j = lid; j < D; j += WG1) {
)"
R"(        const uint c = h*D + j;
)"
R"(        global const float * cs = conv_state + (size_t)s*CS_SLOT + (size_t)c*(D_CONV-1);
)"
R"(        float acc = 0.0f;
)"
R"(        for (uint w = 0; w < D_CONV-1; ++w)
)"
R"(            acc += cs[w] * cw[(size_t)c*D_CONV + w];
)"
R"(        acc += lmem[L_MIX + j] * cw[(size_t)c*D_CONV + (D_CONV-1)];
)"
R"(        lmem[L_CONV + j] = silu1(acc);
)"
R"(    }
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(    // (4) q/k 逐头 l2norm（因子 = 1/sqrt(Σx²+eps)，R-018 闭式）/ v 直通
)"
R"(    if (s < 2) {
)"
R"(        if (lid == 0) {
)"
R"(            float ss = 0.0f;
)"
R"(            for (uint j = 0; j < D; ++j) { const float v_ = lmem[L_CONV + j]; ss += v_*v_; }
)"
R"(            lmem[L_FACT] = 1.0f / sqrt(ss + L2_EPS);   /* build_gdn_l2_norm 闭式（R-018 代数更正） */
)"
R"(        }
)"
R"(        barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(        const float f = lmem[L_FACT];
)"
R"(        for (uint j = lid; j < D; j += WG1)
)"
R"(            scratch[(size_t)s*D_INNER + h*D + j] = lmem[L_CONV + j] * f;
)"
R"(    } else {
)"
R"(        for (uint j = lid; j < D; j += WG1)
)"
R"(            scratch[2*D_INNER + h*D + j] = lmem[L_CONV + j];
)"
R"(    }
)"
R"(
)"
R"(    // (5) conv_state 原地滚动（通道主序连续段内 out_w = in_{w+1}，升序原地安全），
)"
R"(    //     末槽 = 本 token 混合值
)"
R"(    for (uint j = lid; j < D; j += WG1) {
)"
R"(        const uint c = h*D + j;
)"
R"(        global float * cs = conv_state + (size_t)s*CS_SLOT + (size_t)c*(D_CONV-1);
)"
R"(        for (uint w = 0; w < D_CONV-2; ++w) cs[w] = cs[w+1];
)"
R"(        cs[D_CONV-2] = lmem[L_MIX + j];
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(// ---------------------------------------------------------------------------
)"
R"(// stage2（opB 之 1）：逐头 WG——gate/ogate 逐通道自算 + KDA 行衰减 AR（state
)"
R"(//   常驻 RMW，列主 S(i,j)=S[j*D+i]）+ 尾部 gated RMSNorm → gated out [H*D]。
)"
R"(//   grid = H 个 WG，WG = WG2（== D）线程，一线程一通道 j。
)"
R"(// ---------------------------------------------------------------------------
)"
R"(kernel void g1_kda_stage2_core(
)"
R"(        global const float * scratch, ulong scr_off,  // stage1 出（段偏移=编译期常量）
)"
R"(        global const float * x,       ulong x_off,    // [N_EMBD]
)"
R"(        global const float * f_a,     ulong fa_off,   // f32 [N_EMBD, D_INNER] 行主（行=通道）
)"
R"(        global const float * g_a,     ulong ga_off,   // 同上
)"
R"(        global const float * dt_b,    ulong dtb_off,  // [D_INNER]
)"
R"(        global const float * ssm_a,   ulong a_off,    // [H] 负值门系数
)"
R"(        global const float * o_norm,  ulong on_off,   // [D] ssm_o_norm
)"
R"(        global float       * state,   ulong st_off,   // [D,D,H] 常驻 state，直接 RMW
)"
R"(        global float       * out,     ulong out_off,  // [H*D] gated normed 输出（可别名 scratch v 段）
)"
R"(        local  float       * lmem)                       // [L2_SIZE]
)"
R"({
)"
R"(    scratch += scr_off; x += x_off; f_a += fa_off; g_a += ga_off;
)"
R"(    dt_b += dtb_off; ssm_a += a_off; o_norm += on_off; state += st_off; out += out_off;
)"
R"(    const uint h = get_group_id(0);
)"
R"(    const uint j = get_local_id(0);      // 一线程一通道（WG2 == D）
)"
R"(
)"
R"(    global const float * q    = scratch + h*D;
)"
R"(    global const float * k    = scratch + D_INNER + h*D;
)"
R"(    global const float * v    = scratch + 2*D_INNER + h*D;
)"
R"(    global const float * beta = scratch + 3*D_INNER;
)"
R"(    global float * S = state + (size_t)h * D * D;   // S(i,j) = S[j*D + i]
)"
R"(
)"
R"(    // (1) gate / out-gate 逐通道自算（本通道各一个 N_EMBD 点积，:415-424/:436-437）
)"
R"(    const float ah = ssm_a[h];
)"
R"(    global const float * frow = f_a + (size_t)(h*D + j) * N_EMBD;
)"
R"(    global const float * grow = g_a + (size_t)(h*D + j) * N_EMBD;
)"
R"(    float gpre = dt_b[h*D + j];
)"
R"(    float opre = 0.0f;
)"
R"(    for (uint i = 0; i < N_EMBD; ++i) {
)"
R"(        const float xi = x[i];
)"
R"(        gpre += frow[i] * xi;
)"
R"(        opre += grow[i] * xi;
)"
R"(    }
)"
R"(    lmem[j]     = exp((float)GATE_LB / (1.0f + exp(-(gpre * ah))));  // exp(gate) ∈ (exp(LB),1)
)"
R"(    lmem[D + j] = 1.0f / (1.0f + exp(-opre));                        // ogate[j]
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(    // (2) sk_j = Σ_i S[j*D+i]·g[i]·k[i]（衰减后 S 口径，本 WG 独占行 j，无跨线程依赖）
)"
R"(    float sk = 0.0f;
)"
R"(    for (uint i = 0; i < D; ++i) sk += S[(size_t)j*D + i] * lmem[i] * k[i];
)"
R"(    const float dj = (v[j] - sk) * beta[h];
)"
R"(
)"
R"(    // (3) S[j*D+i] = S[j*D+i]·g[i] + k[i]·d_j（衰减与外积合并单趟）+ o_j（衰减后 S）
)"
R"(    float oacc = 0.0f;
)"
R"(    for (uint i = 0; i < D; ++i) {
)"
R"(        const float sn = S[(size_t)j*D + i] * lmem[i] + k[i] * dj;
)"
R"(        S[(size_t)j*D + i] = sn;
)"
R"(        oacc += sn * q[i];
)"
R"(    }
)"
R"(    lmem[2*D + j] = oacc / sqrt((float)D);   // q 预乘 1/sqrt(D) 口径（同 GDN）
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);            // 保证全部 v/S 读完成（out 可别名 v 段）
)"
R"(
)"
R"(    // (4) gated RMSNorm（本头内归约，:439-440）
)"
R"(    if (j == 0) {
)"
R"(        float ss = 0.0f;
)"
R"(        for (uint t = 0; t < D; ++t) { const float o_ = lmem[2*D + t]; ss += o_*o_; }
)"
R"(        lmem[3*D] = 1.0f / sqrt(ss / D + RMS_EPS);
)"
R"(    }
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(    out[(size_t)h*D + j] = lmem[2*D + j] * lmem[3*D] * o_norm[j] * lmem[D + j];
)"
R"(}
)"
R"(
)"
R"(// ---------------------------------------------------------------------------
)"
R"(// stage3（opB 之 2）：wo GEMV（q4_0）= GDN stage3 原样。grid = N_EMBD/WG3 个 WG，
)"
R"(//   lane = 输出列，无归约无 barrier（x = stage2 出的 gated output，全局广播读）。
)"
R"(// ---------------------------------------------------------------------------
)"
R"(kernel void g1_kda_stage3_out(
)"
R"(        global const float * fin,        ulong fin_off,  // [H*D] stage2 gated 输出
)"
R"(        global const uchar * W_out,      ulong wo_off,   // q4_0 [D_INNER, N_EMBD] 行主
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
