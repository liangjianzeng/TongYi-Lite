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
R"(inline uint q2_k_pack(uint pk) {
)"
R"(    return ( (pk      ) & 3u)
)"
R"(         | (((pk >> 2) & 3u) <<  8)
)"
R"(         | (((pk >> 4) & 3u) << 16)
)"
R"(         | (((pk >> 6) & 3u) << 24);
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
R"(kernel void kernel_gemm_noshuffle_q2_k_q8_1_dp4a(
)"
R"(        __global const uchar  * src0_qs,
)"
R"(        __global const uchar  * src0_sc,
)"
R"(        __global const half   * src0_dm,   // half pairs: d, dmin
)"
R"(        __global const uint   * src1_qa,   // q8_1 activations int8 (as uint, 4/elem) [N, K]
)"
R"(        __global const half   * src1_da,   // q8_1 per-block scale [N, K/32]
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
R"(    __local float sh_s [TILESIZE_N][2];   // per-16 activation sums, in qa units
)"
R"(    __local half  sh_d [TILESIZE_N];
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
R"(        const half2 dm  = vload2(rrow + ib * (uint)m, src0_dm);
)"
R"(        const float dv  = (float)dm.s0;
)"
R"(        const float dmv = (float)dm.s1;
)"
R"(
)"
R"(        const uint  scb = rrow + (sub << 1) * (uint)m;
)"
R"(        const uint  sc0 = (uint)src0_sc[scb + 0u * (uint)m];
)"
R"(        const uint  sc1 = (uint)src0_sc[scb + 1u * (uint)m];
)"
R"(        const float dl0 = dv  * (float)( sc0       & 0xFu);
)"
R"(        const float ml0 = dmv * (float)( sc0 >> 4);
)"
R"(        const float dl1 = dv  * (float)( sc1       & 0xFu);
)"
R"(        const float ml1 = dmv * (float)( sc1 >> 4);
)"
R"(
)"
R"(        const uint qsb = rrow + (step >> 2) * (uint)m;
)"
R"(        uint4 qlo, qhi;
)"
R"(        qlo.s0 = q2_k_pack((uint)src0_qs[qsb + 0u * (uint)m]);
)"
R"(        qlo.s1 = q2_k_pack((uint)src0_qs[qsb + 1u * (uint)m]);
)"
R"(        qlo.s2 = q2_k_pack((uint)src0_qs[qsb + 2u * (uint)m]);
)"
R"(        qlo.s3 = q2_k_pack((uint)src0_qs[qsb + 3u * (uint)m]);
)"
R"(        qhi.s0 = q2_k_pack((uint)src0_qs[qsb + 4u * (uint)m]);
)"
R"(        qhi.s1 = q2_k_pack((uint)src0_qs[qsb + 5u * (uint)m]);
)"
R"(        qhi.s2 = q2_k_pack((uint)src0_qs[qsb + 6u * (uint)m]);
)"
R"(        qhi.s3 = q2_k_pack((uint)src0_qs[qsb + 7u * (uint)m]);
)"
R"(
)"
R"(        for (uint idx = lid; idx < TILESIZE_N * 2u; idx += 64u) {
)"
R"(            const uint t  = idx >> 1;
)"
R"(            const uint h  = idx & 1u;
)"
R"(            const uint c  = col_base + t;
)"
R"(            const bool ok = c < (uint)n_no_padding;
)"
R"(            const uint4 w = ok ? KQ_STAGE(src1_qa + c * k_u + (step >> 2) + (h << 2))
)"
R"(                               : (uint4)(0u);
)"
R"(            sh_qa4[t][h] = w;
)"
R"(            int s = 0;
)"
R"(            s = dot_acc_sat_4x8packed_ss_int(w.x, 0x01010101u, s);
)"
R"(            s = dot_acc_sat_4x8packed_ss_int(w.y, 0x01010101u, s);
)"
R"(            s = dot_acc_sat_4x8packed_ss_int(w.z, 0x01010101u, s);
)"
R"(            s = dot_acc_sat_4x8packed_ss_int(w.w, 0x01010101u, s);
)"
R"(            sh_s[t][h] = (float)s;
)"
R"(            if (h == 0u) {
)"
R"(                sh_d[t] = ok ? src1_da[c * k_b + sub] : (half)0;
)"
R"(            }
)"
R"(        }
)"
R"(        barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(#define LD4(arr, b) ((float4)((float)arr[(b)+0], (float)arr[(b)+1], (float)arr[(b)+2], (float)arr[(b)+3]))
)"
R"(#define Q2_K_COL(b) (dl0 * (float)dot4_q8a_v(qlo, (uint4)(sh_qa4[b][0])) - ml0 * sh_s[b][0] + \
)"
R"(                    dl1 * (float)dot4_q8a_v(qhi, (uint4)(sh_qa4[b][1])) - ml1 * sh_s[b][1])
)"
R"(        #pragma unroll
)"
R"(        for (int g = 0; g < NGROUPS; ++g) {
)"
R"(            const int b = g * 4;
)"
R"(            float4 rf;
)"
R"(            rf.s0 = Q2_K_COL(b+0);  rf.s1 = Q2_K_COL(b+1);
)"
R"(            rf.s2 = Q2_K_COL(b+2);  rf.s3 = Q2_K_COL(b+3);
)"
R"(            acc[g] += LD4(sh_d, b) * rf;
)"
R"(        }
)"
R"(#undef Q2_K_COL
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
