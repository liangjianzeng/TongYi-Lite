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
R"(inline uint iq4_xs_pack(ushort q) {
)"
R"(    return iq4_xs_code(q & 15)
)"
R"(         | (iq4_xs_code((q >> 4) & 15) << 8)
)"
R"(         | (iq4_xs_code((q >> 8) & 15) << 16)
)"
R"(         | (iq4_xs_code(q >> 12) << 24);
)"
R"(}
)"
R"(
)"
R"(// Pass staged operands by value; local dp4a operands miscompile on X2.
)"
R"(inline int dot8_q8a_v(uint8 qw, uint4 a0, uint4 a1) {
)"
R"(    int r = 0;
)"
R"(    r = dot_acc_sat_4x8packed_ss_int(qw.s0, a0.x, r);
)"
R"(    r = dot_acc_sat_4x8packed_ss_int(qw.s1, a0.y, r);
)"
R"(    r = dot_acc_sat_4x8packed_ss_int(qw.s2, a0.z, r);
)"
R"(    r = dot_acc_sat_4x8packed_ss_int(qw.s3, a0.w, r);
)"
R"(    r = dot_acc_sat_4x8packed_ss_int(qw.s4, a1.x, r);
)"
R"(    r = dot_acc_sat_4x8packed_ss_int(qw.s5, a1.y, r);
)"
R"(    r = dot_acc_sat_4x8packed_ss_int(qw.s6, a1.z, r);
)"
R"(    r = dot_acc_sat_4x8packed_ss_int(qw.s7, a1.w, r);
)"
R"(    return r;
)"
R"(}
)"
R"(
)"
R"(__attribute__((qcom_wave_pair_mode(1)))
)"
R"(kernel void kernel_gemm_noshuffle_iq4_xs_q8_1_dp4a(
)"
R"(        __global const ushort * src0_qs,
)"
R"(        __global const uint   * src0_sl,
)"
R"(        __global const ushort * src0_sh,
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
R"(
)"
R"(        const uint ib = sub >> 3;
)"
R"(        const uint sb = sub & 7u;
)"
R"(        const uint sl = src0_sl[rrow + ib*(uint)m];
)"
R"(        const uint sh = src0_sh[rrow + ib*(uint)m];
)"
R"(        const int ls = (int)(((sl >> (4*sb)) & 15u) | (((sh >> (2*sb)) & 3u) << 4)) - 32;
)"
R"(        const float d_w = (float)src0_d[rrow + ib*(uint)m] * (float)ls;
)"
R"(        const uint qsb = rrow + sub*8u*(uint)m;
)"
R"(
)"
R"(        uint8 qw;
)"
R"(        qw.s0 = iq4_xs_pack(src0_qs[qsb + 0u*(uint)m]);
)"
R"(        qw.s1 = iq4_xs_pack(src0_qs[qsb + 1u*(uint)m]);
)"
R"(        qw.s2 = iq4_xs_pack(src0_qs[qsb + 2u*(uint)m]);
)"
R"(        qw.s3 = iq4_xs_pack(src0_qs[qsb + 3u*(uint)m]);
)"
R"(        qw.s4 = iq4_xs_pack(src0_qs[qsb + 4u*(uint)m]);
)"
R"(        qw.s5 = iq4_xs_pack(src0_qs[qsb + 5u*(uint)m]);
)"
R"(        qw.s6 = iq4_xs_pack(src0_qs[qsb + 6u*(uint)m]);
)"
R"(        qw.s7 = iq4_xs_pack(src0_qs[qsb + 7u*(uint)m]);
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
R"(        #pragma unroll
)"
R"(        for (int g = 0; g < NGROUPS; ++g) {
)"
R"(            const int b = g * 4;
)"
R"(            float4 rf;
)"
R"(#define TDOT4(T) dot8_q8a_v(qw, (uint4)(sh_qa4[T][0]), (uint4)(sh_qa4[T][1]))
)"
R"(            rf.s0 = (float)TDOT4(b+0);  rf.s1 = (float)TDOT4(b+1);
)"
R"(            rf.s2 = (float)TDOT4(b+2);  rf.s3 = (float)TDOT4(b+3);
)"
R"(            acc[g] += d_w * LD4(sh_d, b) * rf;
)"
R"(        }
)"
R"(#undef TDOT4
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
