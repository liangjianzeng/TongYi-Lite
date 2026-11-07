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
R"(inline uint iq2_s_pack(uint gv, uint sg, uint base) {
)"
R"(    int v0 = (int)((gv >>  0) & 0xFF); if (sg & (1u << (base + 0))) { v0 = -v0; }
)"
R"(    int v1 = (int)((gv >>  8) & 0xFF); if (sg & (1u << (base + 1))) { v1 = -v1; }
)"
R"(    int v2 = (int)((gv >> 16) & 0xFF); if (sg & (1u << (base + 2))) { v2 = -v2; }
)"
R"(    int v3 = (int)((gv >> 24) & 0xFF); if (sg & (1u << (base + 3))) { v3 = -v3; }
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
R"(kernel void kernel_gemm_noshuffle_iq2_s_q8_1_dp4a(
)"
R"(        __global const uchar  * src0_qs,
)"
R"(        __global const uchar  * src0_sg,
)"
R"(        __global const uchar  * src0_qh,
)"
R"(        __global const uchar  * src0_sc,
)"
R"(        __global const half   * src0_d,
)"
R"(        __global const uint   * src1_qa,
)"
R"(        __global const half   * src1_da,
)"
R"(        __global       float  * dst,
)"
R"(        ulong  offsetd,
)"
R"(        int    m,
)"
R"(        int    n_no_padding,
)"
R"(        int    k
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
R"(#define IQ2_S_GRID(i) iq2_s_grid[(i)]
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
R"(        const uint ib  = sub >> 3;
)"
R"(
)"
R"(        const uint  qhv = (uint)src0_qh[rrow + sub * (uint)m];
)"
R"(        const uint  scv = (uint)src0_sc[rrow + sub * (uint)m];
)"
R"(        const float dv  = (float)src0_d[rrow + ib * (uint)m];
)"
R"(        const float dl0 = dv * (0.5f + (float)( scv       & 0xFu)) * 0.25f;
)"
R"(        const float dl1 = dv * (0.5f + (float)( scv >> 4)        ) * 0.25f;
)"
R"(
)"
R"(        const uint gb = rrow + (step >> 3) * (uint)m;
)"
R"(
)"
R"(        uint4 qlo, qhi;
)"
R"(        {
)"
R"(            const uint gi0 = (uint)src0_qs[gb + 0u * (uint)m] | ((( qhv       & 3u) << 8));
)"
R"(            const uint gi1 = (uint)src0_qs[gb + 1u * (uint)m] | ((((qhv >> 2) & 3u) << 8));
)"
R"(            const uint gi2 = (uint)src0_qs[gb + 2u * (uint)m] | ((((qhv >> 4) & 3u) << 8));
)"
R"(            const uint gi3 = (uint)src0_qs[gb + 3u * (uint)m] | ((((qhv >> 6) & 3u) << 8));
)"
R"(            const uint s0  = (uint)src0_sg[gb + 0u * (uint)m];
)"
R"(            const uint s1  = (uint)src0_sg[gb + 1u * (uint)m];
)"
R"(            const uint s2  = (uint)src0_sg[gb + 2u * (uint)m];
)"
R"(            const uint s3  = (uint)src0_sg[gb + 3u * (uint)m];
)"
R"(            qlo.s0 = iq2_s_pack(IQ2_S_GRID(2u*gi0 + 0u), s0, 0u);
)"
R"(            qlo.s1 = iq2_s_pack(IQ2_S_GRID(2u*gi0 + 1u), s0, 4u);
)"
R"(            qlo.s2 = iq2_s_pack(IQ2_S_GRID(2u*gi1 + 0u), s1, 0u);
)"
R"(            qlo.s3 = iq2_s_pack(IQ2_S_GRID(2u*gi1 + 1u), s1, 4u);
)"
R"(            qhi.s0 = iq2_s_pack(IQ2_S_GRID(2u*gi2 + 0u), s2, 0u);
)"
R"(            qhi.s1 = iq2_s_pack(IQ2_S_GRID(2u*gi2 + 1u), s2, 4u);
)"
R"(            qhi.s2 = iq2_s_pack(IQ2_S_GRID(2u*gi3 + 0u), s3, 0u);
)"
R"(            qhi.s3 = iq2_s_pack(IQ2_S_GRID(2u*gi3 + 1u), s3, 4u);
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
R"(                         ? vload4(0, src1_qa + c * k_u + (step >> 2) + (v << 2))
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
R"(#define IQ2_S_COL(b) (dl0 * (float)dot4_q8a_v(qlo, (uint4)(sh_qa4[b][0]))  \
)"
R"(                   + dl1 * (float)dot4_q8a_v(qhi, (uint4)(sh_qa4[b][1])))
)"
R"(        #pragma unroll
)"
R"(        for (int g = 0; g < NGROUPS; ++g) {
)"
R"(            const int b = g * 4;
)"
R"(            float4 rf;
)"
R"(            rf.s0 = IQ2_S_COL(b+0);  rf.s1 = IQ2_S_COL(b+1);
)"
R"(            rf.s2 = IQ2_S_COL(b+2);  rf.s3 = IQ2_S_COL(b+3);
)"
R"(            acc[g] += LD4(sh_d, b) * rf;
)"
R"(        }
)"
R"(#undef IQ2_S_COL
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
R"(#undef IQ2_S_GRID
)"
R"(}
)"
