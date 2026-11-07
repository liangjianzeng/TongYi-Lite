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
R"(inline uint iq1_m_pack(uint g, uint shift, uint negative_delta) {
)"
R"(    // 8*(grid + delta) is an exact signed integer in [-9, 9].
)"
R"(    const int bias = negative_delta ? -9 : -7;
)"
R"(    const int4 values = 8*convert_int4(as_uchar4((g >> shift) & 0x0F0F0F0Fu)) + bias;
)"
R"(    return as_uint(convert_char4(values));
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
R"(kernel void kernel_gemm_noshuffle_iq1_m_q8_1_dp4a(
)"
R"(        __global const uchar  * src0_qs,
)"
R"(        __global const uchar  * src0_qh,
)"
R"(        __global const ushort * src0_sc,
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
R"(#define IQ1_M_GRID(i) iq1_s_grid[(i)]
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
R"(    float dsuper = 0.f;
)"
R"(    for (uint step = 0; step < (uint)k; step += 32) {
)"
R"(        const uint sub = step >> 5;
)"
R"(        const uint ib  = sub >> 3;
)"
R"(
)"
R"(        if ((sub & 7u) == 0u) {
)"
R"(            const uint sb = rrow + 4u*ib*(uint)m;
)"
R"(            const uint w0 = src0_sc[sb + 0u*(uint)m];
)"
R"(            const uint w1 = src0_sc[sb + 1u*(uint)m];
)"
R"(            const uint w2 = src0_sc[sb + 2u*(uint)m];
)"
R"(            const uint w3 = src0_sc[sb + 3u*(uint)m];
)"
R"(            const ushort bits = (ushort)((w0 >> 12) | ((w1 >> 8) & 0x00f0u)
)"
R"(                                       | ((w2 >> 4) & 0x0f00u) | (w3 & 0xf000u));
)"
R"(            dsuper = (float)as_half(bits);
)"
R"(        }
)"
R"(        const uint sc = src0_sc[rrow + (4u*ib + (sub & 7u)/2u)*(uint)m];
)"
R"(        const uint sh = 6u*(sub & 1u);
)"
R"(        const float dl0 = dsuper * (float)(2u*((sc >> sh) & 7u) + 1u) * 0.125f;
)"
R"(        const float dl1 = dsuper * (float)(2u*((sc >> (sh + 3u)) & 7u) + 1u) * 0.125f;
)"
R"(        const uint h0 = src0_qh[rrow + (2u*sub + 0u)*(uint)m];
)"
R"(        const uint h1 = src0_qh[rrow + (2u*sub + 1u)*(uint)m];
)"
R"(        const uint gb = rrow + 4u*sub*(uint)m;
)"
R"(        const uint g0 = IQ1_M_GRID((uint)src0_qs[gb + 0u*(uint)m] | (( h0       & 7u) << 8));
)"
R"(        const uint g1 = IQ1_M_GRID((uint)src0_qs[gb + 1u*(uint)m] | (((h0 >> 4) & 7u) << 8));
)"
R"(        const uint g2 = IQ1_M_GRID((uint)src0_qs[gb + 2u*(uint)m] | (( h1       & 7u) << 8));
)"
R"(        const uint g3 = IQ1_M_GRID((uint)src0_qs[gb + 3u*(uint)m] | (((h1 >> 4) & 7u) << 8));
)"
R"(        const uint4 qlo = (uint4)(iq1_m_pack(g0, 0, h0 & 0x08u), iq1_m_pack(g0, 4, h0 & 0x08u),
)"
R"(                                 iq1_m_pack(g1, 0, h0 & 0x80u), iq1_m_pack(g1, 4, h0 & 0x80u));
)"
R"(        const uint4 qhi = (uint4)(iq1_m_pack(g2, 0, h1 & 0x08u), iq1_m_pack(g2, 4, h1 & 0x08u),
)"
R"(                                 iq1_m_pack(g3, 0, h1 & 0x80u), iq1_m_pack(g3, 4, h1 & 0x80u));
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
R"(#define IQ1_M_COL(b) (dl0 * (float)dot4_q8a_v(qlo, (uint4)(sh_qa4[b][0])) \
)"
R"(                           + dl1 * (float)dot4_q8a_v(qhi, (uint4)(sh_qa4[b][1])))
)"
R"(        #pragma unroll
)"
R"(        for (int g = 0; g < NGROUPS; ++g) {
)"
R"(            const int b = g * 4;
)"
R"(            float4 rf;
)"
R"(            rf.s0 = IQ1_M_COL(b+0);  rf.s1 = IQ1_M_COL(b+1);
)"
R"(            rf.s2 = IQ1_M_COL(b+2);  rf.s3 = IQ1_M_COL(b+3);
)"
R"(            acc[g] += LD4(sh_d, b) * rf;
)"
R"(        }
)"
R"(#undef IQ1_M_COL
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
R"(#undef IQ1_M_GRID
)"
R"(}
)"
