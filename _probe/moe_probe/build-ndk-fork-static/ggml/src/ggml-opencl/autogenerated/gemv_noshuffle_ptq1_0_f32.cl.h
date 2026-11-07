R"(#pragma OPENCL EXTENSION cl_khr_fp16 : enable
)"
R"(
)"
R"(// [tongyi tern 2026-11-04] PTQ1_0 batched MoE gather — 决策档 F-1（缺项清单第一条）。
)"
R"(//
)"
R"(// ★ 状态（2026-11-04 定案）：**保留休眠（DORMANT）**。内核/路由/装载链全链就位且
)"
R"(//   GB10 内核级 NMSE≈1e-13 验证通过；但 G2 判卷（docs/超大MoE专家三元量化_batched内核落地_2026-11-04.md §3）
)"
R"(//   实测「Q3_K 直接后置三元化」质量死刑（全 40 层 KL 超门 15–27×、文本崩坏），判因 =
)"
R"(//   无旋转/QAT 的重尾分布 + 40 层×8 专家误差复利（单层臂过线证明管线无罪）。
)"
R"(//   本内核激活条件 = 出现**原厂 QAT 三元 MoE checkpoint**（Bonsai 式：训练期 Hadamard
)"
R"(//   旋转 + 符号折叠，如 prism.hadamard.* 配方）或 G3 另选格式（q2_K 模板同构复用）。
)"
R"(//   当前 catalog 无 PTQ1_0 专家模型 ⇒ 路由不命中，对现有模型零影响。
)"
R"(// 骨架镜像 gemv_noshuffle_iq4_xs_f32.cl（M1 路线① raw 直读、无平面无 q_img），
)"
R"(// trit 解码逐字镜像 mul_mv_ptq1_0_f32.cl 的 block_ptq1_0_value（真机 174/174 的那套，
)"
R"(// 含 Adreno __constant 数组误编的规避：pow3 用三元选择，不用数组）。
)"
R"(// 语义镜像 ggml-quants.c dequantize_row_ptq1_0：
)"
R"(//   v < 80 : b = qs[v & 15],  n = v >> 4      (5 trits/byte, stride 16)
)"
R"(//   v <120 : b = qs[16 + ((v-80) & 7)], n = (v-80) >> 3  (5 trits/byte, stride 8)
)"
R"(//   v >=120: b = qh[(v-120) & 1], n = (v-120) >> 1       (4 trits/byte, stride 2)
)"
R"(//   t = (b * 3^n) & 0xFF; trit = ((t * 3) >> 8) - 1 ∈ {-1,0,1}; val = trit * d
)"
R"(// 块布局：qs[24] qh[2] d(half) = 28 B / 128 元素；行主序 [E][M][K/128 × 28B]。
)"
R"(
)"
R"(#define PTQ1_0_ROW_BYTES 28
)"
R"(
)"
R"(// pow3 选择用三元表达式：Adreno 编译器把 __constant 数组第 5 项 (81) 误编成 0，
)"
R"(// 每块 16 个 trit 全解 -1（PTQ1_0 内核档案 2026-09-27 定罪，勿回退成数组）。
)"
R"(inline int ptq1_0_trit(const uchar b, const uint n) {
)"
R"(    const uint p = (n == 4) ? 81u : (n == 3) ? 27u : (n == 2) ? 9u : (n == 1) ? 3u : 1u;
)"
R"(    return (int) (((b * p) & 0xFFU) * 3U >> 8) - 1;
)"
R"(}
)"
R"(
)"
R"(inline float ptq1_0_value(global const uchar * blk, const int v) {
)"
R"(    uchar b; uint n;
)"
R"(    if (v < 80) {
)"
R"(        b = blk[v & 15];
)"
R"(        n = v >> 4;
)"
R"(    } else if (v < 120) {
)"
R"(        b = blk[16 + ((v - 80) & 7)];
)"
R"(        n = (v - 80) >> 3;
)"
R"(    } else {
)"
R"(        b = blk[24 + ((v - 120) & 1)];
)"
R"(        n = (v - 120) >> 1;
)"
R"(    }
)"
R"(    return (float) ptq1_0_trit(b, n);
)"
R"(}
)"
R"(
)"
R"(__kernel void kernel_mul_mat_id_ptq1_0_f32_batched(
)"
R"(        __global const uchar * src0,        // raw [E][M][K/128 * 28B] expert weights
)"
R"(        ulong          src0_off,             // byte offset of tensor start in src0
)"
R"(        __read_only image1d_buffer_t src1,  // B: (ne11*n_tok) columns × K floats (f4 pixels)
)"
R"(        __global const int * ids,           // MUL_MAT_ID ids (I32)
)"
R"(        int ids_elem_off,
)"
R"(        __global float * dst,
)"
R"(        ulong offsetd,
)"
R"(        int ne00,                           // K
)"
R"(        int ne01,                           // M
)"
R"(        int n_used,
)"
R"(        int n_tok,
)"
R"(        int ne11,
)"
R"(        int n_expert,
)"
R"(        int ids_row,
)"
R"(        ulong dst_nb1,
)"
R"(        ulong dst_nb2)
)"
R"({
)"
R"(    uint col = get_global_id(0);            // n_used * n_tok
)"
R"(    uint m   = get_global_id(1);            // ne01
)"
R"(    if (col >= (uint)(n_used * n_tok) || m >= (uint)ne01) {
)"
R"(        return;
)"
R"(    }
)"
R"(
)"
R"(    uint t = col / (uint)n_used;
)"
R"(    uint j = col - t * (uint)n_used;
)"
R"(
)"
R"(    int e = ids[ids_elem_off + (int)t * ids_row + (int)j];
)"
R"(    bool valid = (e >= 0) && (e < n_expert);
)"
R"(
)"
R"(    __global float * dstc = (__global float *)((__global char *)dst + offsetd
)"
R"(                            + (ulong)j * dst_nb1 + (ulong)t * dst_nb2);
)"
R"(
)"
R"(    if (!valid) {
)"
R"(        dstc[m] = 0.0f;
)"
R"(        return;
)"
R"(    }
)"
R"(
)"
R"(    // 专家层基址（原始布局，行主序 [M][K/128 blocks]）
)"
R"(    __global const uchar * row = src0 + src0_off + ((ulong)e * ne01 + m) * PTQ1_0_ROW_BYTES * (ne00 / 128);
)"
R"(
)"
R"(    // 激活列：f4 像素 (K/4) 每列
)"
R"(    uint ybase = ((j % (uint)ne11) + t * (uint)ne11) * (uint)(ne00 / 4);
)"
R"(
)"
R"(    float sum = 0.0f;
)"
R"(
)"
R"(    for (int sb = 0; sb < ne00 / 128; ++sb) {
)"
R"(        __global const uchar * blk = row + (ulong)sb * PTQ1_0_ROW_BYTES;
)"
R"(        const float d = (float)vload_half(0, (__global const half *)(blk + 26));
)"
R"(
)"
R"(        // 128 元素 = 32 个 float4 像素；像素 px 覆盖元素 4px..4px+3
)"
R"(        uint ypix = ybase + (uint)sb * 32;
)"
R"(        #pragma unroll 8
)"
R"(        for (int px = 0; px < 32; ++px) {
)"
R"(            float4 yv = read_imagef(src1, (int)(ypix + px));
)"
R"(            sum += d * ptq1_0_value(blk, px * 4 + 0) * yv.s0;
)"
R"(            sum += d * ptq1_0_value(blk, px * 4 + 1) * yv.s1;
)"
R"(            sum += d * ptq1_0_value(blk, px * 4 + 2) * yv.s2;
)"
R"(            sum += d * ptq1_0_value(blk, px * 4 + 3) * yv.s3;
)"
R"(        }
)"
R"(    }
)"
R"(
)"
R"(    dstc[m] = sum;
)"
R"(}
)"
