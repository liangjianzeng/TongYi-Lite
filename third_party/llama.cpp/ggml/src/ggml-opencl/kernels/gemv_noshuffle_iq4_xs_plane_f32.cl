#pragma OPENCL EXTENSION cl_khr_fp16 : enable

// [tongyi M1 2026-10-25] iq4_xs batched MoE gather — G-733 路线① 首个 sub-3bpw 内核。
// 正确性优先版：直读原始 block_iq4_xs 布局（[E][M][K/256 × 136B]），不做转置平面
// （M1 验收 = moe_probe4 NMSE 对 CPU dequant 逐位 + 不慢于 CPU 专家路；平面化提速
// 留给 M2，接入形态已由路由表 mmid_iq4_xs_batched 行约束）。
// 语义镜像 ggml-quants.c dequantize_row_iq4_xs：
//   ls  = ((scales_l[ib/2] >> 4*(ib%2)) & 0xF) | (((scales_h >> 2*ib) & 3) << 4)   // 6-bit
//   dl  = d * (ls - 32)
//   val = dl * kvalues_iq4nl[nibble]
// 块布局：d(half) scales_h(u16) scales_l[4] qs[128] = 136B / 256 元素。

#define IQ4XS_ROW_BYTES 136

constant float kvalues_iq4xs[16] = {
    -127.f, -104.f, -83.f, -65.f,
     -49.f,  -35.f, -22.f, -10.f,
       1.f,   13.f,  25.f,  38.f,
      53.f,   69.f,  89.f, 113.f
};

__kernel void kernel_mul_mat_id_iq4_xs_f32_batched(
        __global const uchar * src0,        // raw [E][M][K/256 * 136B] expert weights
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

    // 专家层基址（原始布局，行主序 [M][K/256 blocks]）
    __global const uchar * row = src0 + src0_off + ((ulong)e * ne01 + m) * IQ4XS_ROW_BYTES * (ne00 / 256);

    // 激活列：f4 像素 (K/4) 每列
    uint ybase = ((j % (uint)ne11) + t * (uint)ne11) * (uint)(ne00 / 4);

    float sum = 0.0f;

    for (int sb = 0; sb < ne00 / 256; ++sb) {
        __global const uchar * blk = row + (ulong)sb * IQ4XS_ROW_BYTES;
        float  d        = (float)vload_half(0, (__global const half *)blk);
        ushort scales_h = *((__global const ushort *)(blk + 2));
        __global const uchar * sl = blk + 4;
        __global const uchar * qs = blk + 8;

        for (int ib = 0; ib < 8; ++ib) {
            int ls = ((sl[ib / 2] >> (4 * (ib % 2))) & 0xF) | (((scales_h >> (2 * ib)) & 3) << 4);
            float dl = d * (float)(ls - 32);

            // 32 个元素 = 8 个 float4 像素；像素 px 覆盖元素 4px..4px+3，
            // q 字节 j 的低 nibble = 元素 j、高 nibble = 元素 j+16（dequant 同源）
            __global const uchar * q = qs + ib * 16;
            uint ypix = ybase + (uint)(sb * 8 + ib) * 8;
            #pragma unroll
            for (int px = 0; px < 8; ++px) {
                float4 yv = read_imagef(src1, (int)(ypix + px));
                uchar b0 = q[4 * px + 0];
                uchar b1 = q[4 * px + 1];
                uchar b2 = q[4 * px + 2];
                uchar b3 = q[4 * px + 3];
                if (px < 4) {
                    // 元素 4px+c ∈ [0,16)：q[4px+c] 低 nibble
                    sum += dl * kvalues_iq4xs[b0 & 0xF] * yv.s0;
                    sum += dl * kvalues_iq4xs[b1 & 0xF] * yv.s1;
                    sum += dl * kvalues_iq4xs[b2 & 0xF] * yv.s2;
                    sum += dl * kvalues_iq4xs[b3 & 0xF] * yv.s3;
                } else {
                    // 元素 4px+c ∈ [16,32)：q[4px+c-16] 高 nibble（首版错读 q[4px+c]）
                    uchar h0 = q[4 * (px - 4) + 0];
                    uchar h1 = q[4 * (px - 4) + 1];
                    uchar h2 = q[4 * (px - 4) + 2];
                    uchar h3 = q[4 * (px - 4) + 3];
                    sum += dl * kvalues_iq4xs[h0 >> 4] * yv.s0;
                    sum += dl * kvalues_iq4xs[h1 >> 4] * yv.s1;
                    sum += dl * kvalues_iq4xs[h2 >> 4] * yv.s2;
                    sum += dl * kvalues_iq4xs[h3 >> 4] * yv.s3;
                }
            }
        }
    }

    dstc[m] = sum;
}
