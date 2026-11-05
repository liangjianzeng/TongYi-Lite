#pragma OPENCL EXTENSION cl_khr_fp16 : enable

// [tongyi tern 2026-11-04] PTQ1_0 batched MoE gather — 决策档 F-1（缺项清单第一条）。
//
// ★ 状态（2026-11-04 定案）：**保留休眠（DORMANT）**。内核/路由/装载链全链就位且
//   GB10 内核级 NMSE≈1e-13 验证通过；但 G2 判卷（docs/超大MoE专家三元量化_batched内核落地_2026-11-04.md §3）
//   实测「Q3_K 直接后置三元化」质量死刑（全 40 层 KL 超门 15–27×、文本崩坏），判因 =
//   无旋转/QAT 的重尾分布 + 40 层×8 专家误差复利（单层臂过线证明管线无罪）。
//   本内核激活条件 = 出现**原厂 QAT 三元 MoE checkpoint**（Bonsai 式：训练期 Hadamard
//   旋转 + 符号折叠，如 prism.hadamard.* 配方）或 G3 另选格式（q2_K 模板同构复用）。
//   当前 catalog 无 PTQ1_0 专家模型 ⇒ 路由不命中，对现有模型零影响。
// 骨架镜像 gemv_noshuffle_iq4_xs_f32.cl（M1 路线① raw 直读、无平面无 q_img），
// trit 解码逐字镜像 mul_mv_ptq1_0_f32.cl 的 block_ptq1_0_value（真机 174/174 的那套，
// 含 Adreno __constant 数组误编的规避：pow3 用三元选择，不用数组）。
// 语义镜像 ggml-quants.c dequantize_row_ptq1_0：
//   v < 80 : b = qs[v & 15],  n = v >> 4      (5 trits/byte, stride 16)
//   v <120 : b = qs[16 + ((v-80) & 7)], n = (v-80) >> 3  (5 trits/byte, stride 8)
//   v >=120: b = qh[(v-120) & 1], n = (v-120) >> 1       (4 trits/byte, stride 2)
//   t = (b * 3^n) & 0xFF; trit = ((t * 3) >> 8) - 1 ∈ {-1,0,1}; val = trit * d
// 块布局：qs[24] qh[2] d(half) = 28 B / 128 元素；行主序 [E][M][K/128 × 28B]。

#define PTQ1_0_ROW_BYTES 28

// pow3 选择用三元表达式：Adreno 编译器把 __constant 数组第 5 项 (81) 误编成 0，
// 每块 16 个 trit 全解 -1（PTQ1_0 内核档案 2026-09-27 定罪，勿回退成数组）。
inline int ptq1_0_trit(const uchar b, const uint n) {
    const uint p = (n == 4) ? 81u : (n == 3) ? 27u : (n == 2) ? 9u : (n == 1) ? 3u : 1u;
    return (int) (((b * p) & 0xFFU) * 3U >> 8) - 1;
}

inline float ptq1_0_value(global const uchar * blk, const int v) {
    uchar b; uint n;
    if (v < 80) {
        b = blk[v & 15];
        n = v >> 4;
    } else if (v < 120) {
        b = blk[16 + ((v - 80) & 7)];
        n = (v - 80) >> 3;
    } else {
        b = blk[24 + ((v - 120) & 1)];
        n = (v - 120) >> 1;
    }
    return (float) ptq1_0_trit(b, n);
}

__kernel void kernel_mul_mat_id_ptq1_0_f32_batched(
        __global const uchar * src0,        // raw [E][M][K/128 * 28B] expert weights
        ulong          src0_off,             // byte offset of tensor start in src0
        __read_only image1d_buffer_t src1,  // B: (ne11*n_tok) columns × K floats (f4 pixels)
        __global const int * ids,           // MUL_MAT_ID ids (I32)
        int ids_elem_off,
        __global float * dst,
        ulong offsetd,
        int ne00,                           // K
        int ne01,                           // M
        int n_used,
        int n_tok,
        int ne11,
        int n_expert,
        int ids_row,
        ulong dst_nb1,
        ulong dst_nb2)
{
    uint col = get_global_id(0);            // n_used * n_tok
    uint m   = get_global_id(1);            // ne01
    if (col >= (uint)(n_used * n_tok) || m >= (uint)ne01) {
        return;
    }

    uint t = col / (uint)n_used;
    uint j = col - t * (uint)n_used;

    int e = ids[ids_elem_off + (int)t * ids_row + (int)j];
    bool valid = (e >= 0) && (e < n_expert);

    __global float * dstc = (__global float *)((__global char *)dst + offsetd
                            + (ulong)j * dst_nb1 + (ulong)t * dst_nb2);

    if (!valid) {
        dstc[m] = 0.0f;
        return;
    }

    // 专家层基址（原始布局，行主序 [M][K/128 blocks]）
    __global const uchar * row = src0 + src0_off + ((ulong)e * ne01 + m) * PTQ1_0_ROW_BYTES * (ne00 / 128);

    // 激活列：f4 像素 (K/4) 每列
    uint ybase = ((j % (uint)ne11) + t * (uint)ne11) * (uint)(ne00 / 4);

    float sum = 0.0f;

    for (int sb = 0; sb < ne00 / 128; ++sb) {
        __global const uchar * blk = row + (ulong)sb * PTQ1_0_ROW_BYTES;
        const float d = (float)vload_half(0, (__global const half *)(blk + 26));

        // 128 元素 = 32 个 float4 像素；像素 px 覆盖元素 4px..4px+3
        uint ypix = ybase + (uint)sb * 32;
        #pragma unroll 8
        for (int px = 0; px < 32; ++px) {
            float4 yv = read_imagef(src1, (int)(ypix + px));
            sum += d * ptq1_0_value(blk, px * 4 + 0) * yv.s0;
            sum += d * ptq1_0_value(blk, px * 4 + 1) * yv.s1;
            sum += d * ptq1_0_value(blk, px * 4 + 2) * yv.s2;
            sum += d * ptq1_0_value(blk, px * 4 + 3) * yv.s3;
        }
    }

    dstc[m] = sum;
}
