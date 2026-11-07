R"(#pragma OPENCL EXTENSION cl_khr_fp16 : enable
)"
R"(
)"
R"(// [tongyi M1 2026-10-25] iq4_xs batched MoE gather — G-733 路线① 首个 sub-3bpw 内核。
)"
R"(// 正确性优先版：直读原始 block_iq4_xs 布局（[E][M][K/256 × 136B]），不做转置平面
)"
R"(// （M1 验收 = moe_probe4 NMSE 对 CPU dequant 逐位 + 不慢于 CPU 专家路；平面化提速
)"
R"(// 留给 M2，接入形态已由路由表 mmid_iq4_xs_batched 行约束）。
)"
R"(// 语义镜像 ggml-quants.c dequantize_row_iq4_xs：
)"
R"(//   ls  = ((scales_l[ib/2] >> 4*(ib%2)) & 0xF) | (((scales_h >> 2*ib) & 3) << 4)   // 6-bit
)"
R"(//   dl  = d * (ls - 32)
)"
R"(//   val = dl * kvalues_iq4nl[nibble]
)"
R"(// 块布局：d(half) scales_h(u16) scales_l[4] qs[128] = 136B / 256 元素。
)"
R"(
)"
R"(#define IQ4XS_ROW_BYTES 136
)"
R"(
)"
R"(constant float kvalues_iq4xs[16] = {
)"
R"(    -127.f, -104.f, -83.f, -65.f,
)"
R"(     -49.f,  -35.f, -22.f, -10.f,
)"
R"(       1.f,   13.f,  25.f,  38.f,
)"
R"(      53.f,   69.f,  89.f, 113.f
)"
R"(};
)"
R"(
)"
R"(__kernel void kernel_mul_mat_id_iq4_xs_f32_batched(
)"
R"(        __global const uchar * src0,        // raw [E][M][K/256 * 136B] expert weights
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
R"(    // 专家层基址（原始布局，行主序 [M][K/256 blocks]）
)"
R"(    __global const uchar * row = src0 + src0_off + ((ulong)e * ne01 + m) * IQ4XS_ROW_BYTES * (ne00 / 256);
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
R"(    for (int sb = 0; sb < ne00 / 256; ++sb) {
)"
R"(        __global const uchar * blk = row + (ulong)sb * IQ4XS_ROW_BYTES;
)"
R"(        float  d        = (float)vload_half(0, (__global const half *)blk);
)"
R"(        ushort scales_h = *((__global const ushort *)(blk + 2));
)"
R"(        __global const uchar * sl = blk + 4;
)"
R"(        __global const uchar * qs = blk + 8;
)"
R"(
)"
R"(        for (int ib = 0; ib < 8; ++ib) {
)"
R"(            int ls = ((sl[ib / 2] >> (4 * (ib % 2))) & 0xF) | (((scales_h >> (2 * ib)) & 3) << 4);
)"
R"(            float dl = d * (float)(ls - 32);
)"
R"(
)"
R"(            // 32 个元素 = 8 个 float4 像素；像素 px 覆盖元素 4px..4px+3，
)"
R"(            // q 字节 j 的低 nibble = 元素 j、高 nibble = 元素 j+16（dequant 同源）
)"
R"(            __global const uchar * q = qs + ib * 16;
)"
R"(            uint ypix = ybase + (uint)(sb * 8 + ib) * 8;
)"
R"(            #pragma unroll
)"
R"(            for (int px = 0; px < 8; ++px) {
)"
R"(                float4 yv = read_imagef(src1, (int)(ypix + px));
)"
R"(                uchar b0 = q[4 * px + 0];
)"
R"(                uchar b1 = q[4 * px + 1];
)"
R"(                uchar b2 = q[4 * px + 2];
)"
R"(                uchar b3 = q[4 * px + 3];
)"
R"(                if (px < 4) {
)"
R"(                    // 元素 4px+c ∈ [0,16)：q[4px+c] 低 nibble
)"
R"(                    sum += dl * kvalues_iq4xs[b0 & 0xF] * yv.s0;
)"
R"(                    sum += dl * kvalues_iq4xs[b1 & 0xF] * yv.s1;
)"
R"(                    sum += dl * kvalues_iq4xs[b2 & 0xF] * yv.s2;
)"
R"(                    sum += dl * kvalues_iq4xs[b3 & 0xF] * yv.s3;
)"
R"(                } else {
)"
R"(                    // 元素 4px+c ∈ [16,32)：q[4px+c-16] 高 nibble（首版错读 q[4px+c]）
)"
R"(                    uchar h0 = q[4 * (px - 4) + 0];
)"
R"(                    uchar h1 = q[4 * (px - 4) + 1];
)"
R"(                    uchar h2 = q[4 * (px - 4) + 2];
)"
R"(                    uchar h3 = q[4 * (px - 4) + 3];
)"
R"(                    sum += dl * kvalues_iq4xs[h0 >> 4] * yv.s0;
)"
R"(                    sum += dl * kvalues_iq4xs[h1 >> 4] * yv.s1;
)"
R"(                    sum += dl * kvalues_iq4xs[h2 >> 4] * yv.s2;
)"
R"(                    sum += dl * kvalues_iq4xs[h3 >> 4] * yv.s3;
)"
R"(                }
)"
R"(            }
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
