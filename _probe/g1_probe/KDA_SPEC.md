# G1-KDA 变体规格书（R-017，共享契约——所有工作者以此为准）

ling/bailingmoe3 recr 层 = KDA（R-016 定案）。复用 G1-GDN 三阶段骨架（3 launch/层），
拆两 op 消 GGML_MAX_SRC=10 限制。**所有语义锚点 = src/models/bailingmoe3.cpp:406-443
原 op 链 + bailingmoe3_causal_conv1d(:182-215)**。

## 维度（从张量形状反解，不读 hparams）
- head_dim d = ssm_o_norm->ne[0]；n_head H = ssm_a->ne[0]（=beta_w->ne[1]）；
  d_inner = d*H；n_embd = x->ne[0]；d_conv = ssm_q_conv->ne[0]。
- 记：S_K = S_V = d（KDA 方阵 state）；q/k/v 均为 H 头 × d（**无 repeat interleave**）。

## opA：GGML_OP_G1_KDA_IN（stage1，1 kernel）
srcs（9）：`x[n_embd]f32, wq[n_embd,d_inner]Q4_0, wk 同, wv 同,
cq[d_conv,d_inner]f32, ck 同, cv 同, beta_w[n_embd,n_head]f32,
conv_state[3*(d_conv-1)*d_inner]f32(RMW 常驻，槽序 q|k|v，每槽窗口主序 [d_conv-1 行, d_inner 列])`
dst：scratch f32 [3*d_inner + n_head] = q(l2norm 后)|k(l2norm 后)|v|beta[n_head]
op_params：i32[0..3]=n_embd,head_dim(H=d),d_conv；f32[4]=l2_eps。
- GEMV（q4_0，Q4_DOT 序：块内 Σt q·x 再 ×d 累加；f32 GEMV 双精度）：qkv_proj =
  [wq|wk|wv]·x 各 [d_inner]；beta_raw = beta_w·x [n_head]。
- conv（每槽 s∈{0,1,2}，通道 c）：out_s[c] = Σ_{w<d_conv-1}
  cs[(s*(d_conv-1)+w)*d_inner+c]·cqw[(s*d_inner+c)*d_conv+w]
  + qkv_proj[s*d_inner+c]·cqw[(s*d_inner+c)*d_conv+(d_conv-1)]，再 silu
  （cqw = cq|ck|cv 按槽拼接的通道主序视角：cq ne=[d_conv,d_inner] → cqw[(s*d_inner+c)*d_conv+w]）。
- l2norm：q/k 逐头（H 头，因子 = **1/sqrt(Σx²+eps)**，build_gdn_l2_norm 闭式=单位 L2 范数；R-018 代数更正——rms_norm(x,eps/n)×1/sqrt(n) 的 √n 恰好抵消）。
- beta = sigmoid(beta_raw)。
- conv_state 原地滚动（每槽：out_w0=in_w1, out_w1=in_w2, out_w2=qkv_proj 段）。

## opB：GGML_OP_G1_KDA_OUT（stage2+3，2 kernel）
srcs（9）：`scratchA(dstA), x, f_a[n_embd,d_inner]f32, g_a[n_embd,d_inner]f32,
dt_b[d_inner]f32, ssm_a[1,n_head]f32, o_norm[d]f32, wo[d_inner,n_embd]Q4_0,
state[d,d,H]f32(RMW 常驻，列主 S(i,j)=s[j*d+i])`
dst：y [n_embd]。
op_params：i32[0..2]=n_embd,head_dim,d_conv?（d_conv opB 不需要→i32[0..1]=n_embd,head_dim）；
f32[2]=rms_eps, gate_lower_bound（hparams.kda_gate_lower_bound，负值）。

### stage2 kernel（每 WG 一头 h）
- gate 逐通道自算（本头 d 个通道，每通道一个 n_embd 点积）：
  gout_pre[c] = f_a·x（本头列）+ dt_b[h*d+c]；gate[c] = lower_bound·sigmoid(gout_pre[c]·ssm_a[h])
  （lower_bound 负 → gate∈(lb,0)，exp(gate)<1）。
- out-gate 逐通道自算：ogate[c] = sigmoid(g_a·x 本头列)。
- AR（KDA 行衰减，与 GDN 唯一差异=衰减按行向量 g[i]）：
  sk_j = Σ_i S[j*d+i]·g[i]·k[i]
  d_j = (v_j − sk_j)·β_h
  S[j*d+i] = S[j*d+i]·g[i] + k[i]·d_j   ← 衰减与外积合并单趟（state 存衰减后值，同 delta-net）
  o_j = Σ_i S[j*d+i]·q[i]
- 尾部融合：gated[j] = o_j·rms_norm因子·o_norm[j]·ogate[j]（rms 因子 = 1/sqrt(Σo²/d+rms_eps)）
  写 scratch 全局 [H*d]（h*d+j 序）。

### stage3 kernel（= GDN stage3 原样）
y = wo GEMV（q4_0，lane=输出列，无 barrier）。

## 红线
- n_seqs==1、n_tokens==1 门（bailingmoe3 侧已有）。
- 数值对拍：probe 参考实现双精度，容差照 GDN（NMSE ≤1e-6；GEMV f32 噪声 ~1e-4 abs）。
- 探针 = `_probe/g1_probe/` 新文件 g1_kda_probe.cpp（照 g1_layer_probe.cpp 模板：
  dlopen+双栈+三 kernel 逐段读回），或扩展现探针加 KDA 模式（任选，报告注明）。
- 内核语言用 `ulong` 非 cl_ulong；全局指针参数配 ulong offset（house style，71f30017）。
- 派发/opencl/CPU/图分支由并行工作者按本规格落地；文件分工见任务书。
