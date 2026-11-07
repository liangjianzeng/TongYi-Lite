R"(#pragma OPENCL EXTENSION cl_khr_fp16 : enable
)"
R"(#pragma OPENCL EXTENSION cl_khr_subgroups : enable
)"
R"(#ifdef cl_khr_integer_dot_product
)"
R"(#pragma OPENCL EXTENSION cl_khr_integer_dot_product : enable
)"
R"(#endif
)"
R"(
)"
R"(#define QK_K 256
)"
R"(
)"
R"(#ifndef TILESIZE_N
)"
R"(#define TILESIZE_N 32
)"
R"(#endif
)"
R"(
)"
R"(inline int q3_k_scale(uint sc0, uint sc1, uint sc2, uint is) {
)"
R"(    const uint w  = is >> 2;
)"
R"(    const uint sh = 8u * (is & 3u);
)"
R"(    const uint tb = (sc2 >> sh) & 0xFFu;
)"
R"(    uint v;
)"
R"(    if      (w == 0u) { v = ( (sc0 >> sh)       & 0xFu) | (((tb >> 0) & 3u) << 4); }
)"
R"(    else if (w == 1u) { v = ( (sc1 >> sh)       & 0xFu) | (((tb >> 2) & 3u) << 4); }
)"
R"(    else if (w == 2u) { v = (((sc0 >> sh) >> 4) & 0xFu) | (((tb >> 4) & 3u) << 4); }
)"
R"(    else              { v = (((sc1 >> sh) >> 4) & 0xFu) | (((tb >> 6) & 3u) << 4); }
)"
R"(    return (int)v - 32;
)"
R"(}
)"
R"(
)"
R"(inline uint q3_k_pack(uint pk, uint hb) {
)"
R"(    int v0 = (int)((pk      ) & 3u) - 4 + 4*(int)((hb     ) & 1u);
)"
R"(    int v1 = (int)((pk >> 2) & 3u) - 4 + 4*(int)((hb >> 1) & 1u);
)"
R"(    int v2 = (int)((pk >> 4) & 3u) - 4 + 4*(int)((hb >> 2) & 1u);
)"
R"(    int v3 = (int)((pk >> 6) & 3u) - 4 + 4*(int)((hb >> 3) & 1u);
)"
R"(    return ((uint)v0 & 0xFFu) | (((uint)v1 & 0xFFu) <<  8)
)"
R"(         | (((uint)v2 & 0xFFu) << 16) | (((uint)v3 & 0xFFu) << 24);
)"
R"(}
)"
R"(
)"
R"(// Pass staged operands by value; local dp4a operands miscompile on X2.
)"
R"(#define KQ_STAGE(p) vload4(0, (p))
)"
R"(
)"
R"(inline int dot4_q8a_v(uint4 qw, uint4 a) {
)"
R"(    int r = 0;
)"
R"(    r = dot_acc_sat_4x8packed_ss_int(qw.s0, a.x, r);
)"
R"(    r = dot_acc_sat_4x8packed_ss_int(qw.s1, a.y, r);
)"
R"(    r = dot_acc_sat_4x8packed_ss_int(qw.s2, a.z, r);
)"
R"(    r = dot_acc_sat_4x8packed_ss_int(qw.s3, a.w, r);
)"
R"(    return r;
)"
R"(}
)"
R"(
)"
R"(__attribute__((qcom_wave_pair_mode(1)))
)"
R"(kernel void kernel_gemm_noshuffle_q3_k_q8_1_dp4a(
)"
R"(        __global const uchar  * src0_qs,
)"
R"(        __global const uchar  * src0_hm,
)"
R"(        __global const uint   * src0_sc,
)"
R"(        __global const half   * src0_d,
)"
R"(        __global const uint   * src1_qa,   // q8_1 activations int8 (as uint, 4/elem) [N, K]
)"
R"(        __global const half   * src1_da,   // q8_1 per-block scale [N, K/32]
)"
R"(        __global       float  * dst,
)"
R"(        ulong  offsetd,
)"
R"(        int    m,                          // output features (rows)
)"
R"(        int    n_no_padding,               // tokens (cols)
)"
R"(        int    k                           // K (== ne00)
)"
R"() {
)"
R"(    dst = (global float *)((global char *)dst + offsetd);
)"
R"(
)"
R"(    const uint lid = get_local_id(0);
)"
R"(    const uint block_id_m = get_global_id(1);
)"
R"(    const uint block_id_n = get_global_id(2);
)"
R"(
)"
R"(    const uint row      = block_id_m * 64 + lid;
)"
R"(    const uint col_base = block_id_n * TILESIZE_N;
)"
R"(    const bool row_valid = row < (uint)m;
)"
R"(    const uint rrow     = row_valid ? row : 0;
)"
R"(
)"
R"(    const uint k_u = (uint)k >> 2;
)"
R"(    const uint k_b = (uint)k >> 5;
)"
R"(
)"
R"(    __local uint4 sh_qa4[TILESIZE_N][2];
)"
R"(    __local half sh_d[TILESIZE_N];
)"
R"(
)"
R"(#define NGROUPS (TILESIZE_N / 4)
)"
R"(    float4 acc[NGROUPS];
)"
R"(    #pragma unroll
)"
R"(    for (int g = 0; g < NGROUPS; ++g) acc[g] = (float4)(0.0f);
)"
R"(
)"
R"(    for (uint step = 0; step < (uint)k; step += 32) {
)"
R"(        const uint sub = step >> 5;
)"
R"(        const uint ib  = sub >> 3;                // super-block along K
)"
R"(        const uint sb  = sub & 7u;
)"
R"(
)"
R"(        const uint scb = rrow + (3u * ib) * (uint)m;
)"
R"(        const uint sc0 = src0_sc[scb + 0u * (uint)m];
)"
R"(        const uint sc1 = src0_sc[scb + 1u * (uint)m];
)"
R"(        const uint sc2 = src0_sc[scb + 2u * (uint)m];
)"
R"(
)"
R"(        const float d_w = (float)src0_d[rrow + ib * (uint)m];
)"
R"(        const float dl0 = d_w * (float)q3_k_scale(sc0, sc1, sc2, 2u*sb + 0u);
)"
R"(        const float dl1 = d_w * (float)q3_k_scale(sc0, sc1, sc2, 2u*sb + 1u);
)"
R"(
)"
R"(        const uint qsb = rrow + (step >> 2) * (uint)m;
)"
R"(        const uint hmb = rrow + (step >> 3) * (uint)m;
)"
R"(
)"
R"(        uint4 qlo, qhi;
)"
R"(        {
)"
R"(            const uint h0 = (uint)src0_hm[hmb + 0u * (uint)m];
)"
R"(            const uint h1 = (uint)src0_hm[hmb + 1u * (uint)m];
)"
R"(            const uint h2 = (uint)src0_hm[hmb + 2u * (uint)m];
)"
R"(            const uint h3 = (uint)src0_hm[hmb + 3u * (uint)m];
)"
R"(            qlo.s0 = q3_k_pack((uint)src0_qs[qsb + 0u * (uint)m],  h0       & 0xFu);
)"
R"(            qlo.s1 = q3_k_pack((uint)src0_qs[qsb + 1u * (uint)m], (h0 >> 4) & 0xFu);
)"
R"(            qlo.s2 = q3_k_pack((uint)src0_qs[qsb + 2u * (uint)m],  h1       & 0xFu);
)"
R"(            qlo.s3 = q3_k_pack((uint)src0_qs[qsb + 3u * (uint)m], (h1 >> 4) & 0xFu);
)"
R"(            qhi.s0 = q3_k_pack((uint)src0_qs[qsb + 4u * (uint)m],  h2       & 0xFu);
)"
R"(            qhi.s1 = q3_k_pack((uint)src0_qs[qsb + 5u * (uint)m], (h2 >> 4) & 0xFu);
)"
R"(            qhi.s2 = q3_k_pack((uint)src0_qs[qsb + 6u * (uint)m],  h3       & 0xFu);
)"
R"(            qhi.s3 = q3_k_pack((uint)src0_qs[qsb + 7u * (uint)m], (h3 >> 4) & 0xFu);
)"
R"(        }
)"
R"(
)"
R"(        for (uint idx = lid; idx < TILESIZE_N * 2; idx += 64) {
)"
R"(            const uint t = idx >> 1;
)"
R"(            const uint v = idx & 1;
)"
R"(            const uint c = col_base + t;
)"
R"(            sh_qa4[t][v] = (c < (uint)n_no_padding)
)"
R"(                         ? KQ_STAGE(src1_qa + c * k_u + (step >> 2) + (v << 2))
)"
R"(                         : (uint4)(0u);
)"
R"(        }
)"
R"(        if (lid < TILESIZE_N) {
)"
R"(            const uint c = col_base + lid;
)"
R"(            sh_d[lid] = (c < (uint)n_no_padding) ? src1_da[c * k_b + sub] : (half)0;
)"
R"(        }
)"
R"(        barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(#define LD4(arr, b) ((float4)((float)arr[(b)+0], (float)arr[(b)+1], (float)arr[(b)+2], (float)arr[(b)+3]))
)"
R"(        #pragma unroll
)"
R"(        for (int g = 0; g < NGROUPS; ++g) {
)"
R"(            const int b = g * 4;
)"
R"(            float4 rf;
)"
R"(#define Q3_K_COL(T) (dl0 * (float)dot4_q8a_v(qlo, (uint4)(sh_qa4[T][0]))  \
)"
R"(                  + dl1 * (float)dot4_q8a_v(qhi, (uint4)(sh_qa4[T][1])))
)"
R"(            rf.s0 = Q3_K_COL(b+0);  rf.s1 = Q3_K_COL(b+1);
)"
R"(            rf.s2 = Q3_K_COL(b+2);  rf.s3 = Q3_K_COL(b+3);
)"
R"(#undef Q3_K_COL
)"
R"(            acc[g] += LD4(sh_d, b) * rf;
)"
R"(        }
)"
R"(#undef LD4
)"
R"(        barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(    }
)"
R"(
)"
R"(    if (!row_valid) {
)"
R"(        return;
)"
R"(    }
)"
R"(
)"
R"(    #pragma unroll
)"
R"(    for (int g = 0; g < NGROUPS; ++g) {
)"
R"(        const uint b = (uint)(g * 4);
)"
R"(        const float4 a = acc[g];
)"
R"(        const uint c0 = col_base + b;
)"
R"(        if (c0 + 0 < (uint)n_no_padding) dst[(c0 + 0) * (uint)m + row] = a.s0;
)"
R"(        if (c0 + 1 < (uint)n_no_padding) dst[(c0 + 1) * (uint)m + row] = a.s1;
)"
R"(        if (c0 + 2 < (uint)n_no_padding) dst[(c0 + 2) * (uint)m + row] = a.s2;
)"
R"(        if (c0 + 3 < (uint)n_no_padding) dst[(c0 + 3) * (uint)m + row] = a.s3;
)"
R"(    }
)"
R"(#undef NGROUPS
)"
R"(}
)"
