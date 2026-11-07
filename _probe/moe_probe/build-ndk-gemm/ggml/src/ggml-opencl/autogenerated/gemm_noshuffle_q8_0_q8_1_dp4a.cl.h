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
R"(// ne1<=8 keeps the f16 / bin small-batch path.
)"
R"(
)"
R"(#define TILESIZE_N 32
)"
R"(
)"
R"(// 32-K dp4a dot of one token's int8 activations (8 packed uints in lm) against
)"
R"(// 8 packed weight uints. q8_0 weights are already dp4a-format signed int8.
)"
R"(inline int dot8_q8a(uint8 qw, __local const uint * a) {
)"
R"(    int r = 0;
)"
R"(    r = dot_acc_sat_4x8packed_ss_int(qw.s0, a[0], r);
)"
R"(    r = dot_acc_sat_4x8packed_ss_int(qw.s1, a[1], r);
)"
R"(    r = dot_acc_sat_4x8packed_ss_int(qw.s2, a[2], r);
)"
R"(    r = dot_acc_sat_4x8packed_ss_int(qw.s3, a[3], r);
)"
R"(    r = dot_acc_sat_4x8packed_ss_int(qw.s4, a[4], r);
)"
R"(    r = dot_acc_sat_4x8packed_ss_int(qw.s5, a[5], r);
)"
R"(    r = dot_acc_sat_4x8packed_ss_int(qw.s6, a[6], r);
)"
R"(    r = dot_acc_sat_4x8packed_ss_int(qw.s7, a[7], r);
)"
R"(    return r;
)"
R"(}
)"
R"(
)"
R"(__attribute__((qcom_wave_pair_mode(1)))
)"
R"(kernel void kernel_gemm_noshuffle_q8_0_q8_1_dp4a(
)"
R"(        __global const uint  * src0_q,     // q8_0 weights: signed int8, 4/uint, feature-major
)"
R"(        __global const half  * src0_d,     // per-32-block scale, feature-major [row + (k/32)*m]
)"
R"(        __global const uint  * src1_qa,    // q8_1 activations int8 (as uint, 4/elem) [N, K]
)"
R"(        __global const half  * src1_da,    // q8_1 per-block scale [N, K/32]
)"
R"(        __global       float * dst,
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
R"(    const uint lid = get_local_id(0);          // 0..63 -> row within the M-tile
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
R"(    const uint rrow     = row_valid ? row : 0;  // clamp OOB rows; their writes are masked
)"
R"(
)"
R"(    const uint k_u = (uint)k >> 2;   // K in uint (int8x4) units
)"
R"(    const uint k_b = (uint)k >> 5;   // blocks-of-32 along K
)"
R"(
)"
R"(    __local uint sh_qa[TILESIZE_N][8];
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
R"(        const float d_w = (float)src0_d[rrow + sub * (uint)m];
)"
R"(
)"
R"(        // 8 weight uints (32 int8) for this row, this 32-block. Feature-major:
)"
R"(        // src0_q[row + (k/4 + u)*m], k/4 = step/4 (= step>>2).
)"
R"(        const uint wbase = rrow + (step >> 2) * (uint)m;
)"
R"(        uint8 qw;
)"
R"(        qw.s0 = src0_q[wbase + 0 * m];
)"
R"(        qw.s1 = src0_q[wbase + 1 * m];
)"
R"(        qw.s2 = src0_q[wbase + 2 * m];
)"
R"(        qw.s3 = src0_q[wbase + 3 * m];
)"
R"(        qw.s4 = src0_q[wbase + 4 * m];
)"
R"(        qw.s5 = src0_q[wbase + 5 * m];
)"
R"(        qw.s6 = src0_q[wbase + 6 * m];
)"
R"(        qw.s7 = src0_q[wbase + 7 * m];
)"
R"(
)"
R"(        // cooperatively stage the 32-token x 32-K int8 activations to LDS
)"
R"(        for (uint idx = lid; idx < TILESIZE_N * 8; idx += 64) {
)"
R"(            const uint t = idx >> 3;
)"
R"(            const uint u = idx & 7;
)"
R"(            const uint c = col_base + t;
)"
R"(            sh_qa[t][u] = (c < (uint)n_no_padding) ? src1_qa[c * k_u + (step >> 2) + u] : 0u;
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
R"(            rf.s0 = (float)dot8_q8a(qw, sh_qa[b+0]);  rf.s1 = (float)dot8_q8a(qw, sh_qa[b+1]);
)"
R"(            rf.s2 = (float)dot8_q8a(qw, sh_qa[b+2]);  rf.s3 = (float)dot8_q8a(qw, sh_qa[b+3]);
)"
R"(            acc[g] += d_w * LD4(sh_d, b) * rf;
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
R"(    // dst is [token, feature] row-major (stride m): dst[col*m + row].
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
R"(
)"
R"(__attribute__((qcom_wave_pair_mode(1)))
)"
R"(kernel void kernel_gemm_noshuffle_q8_0_q8_1_dp4a_wimg(
)"
R"(        __read_only image1d_buffer_t src0_q_img,  // q8_0 weights as uint32 texels (4 int8/texel)
)"
R"(        __global const half  * src0_d,
)"
R"(        __global const uint  * src1_qa,
)"
R"(        __global const half  * src1_da,
)"
R"(        __global       float * dst,
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
R"(    __local uint sh_qa[TILESIZE_N][8];
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
R"(        const float d_w = (float)src0_d[rrow + sub * (uint)m];
)"
R"(
)"
R"(        const uint wbase = rrow + (step >> 2) * (uint)m;
)"
R"(        uint8 qw;
)"
R"(        qw.s0 = read_imageui(src0_q_img, (int)(wbase + 0 * m)).x;
)"
R"(        qw.s1 = read_imageui(src0_q_img, (int)(wbase + 1 * m)).x;
)"
R"(        qw.s2 = read_imageui(src0_q_img, (int)(wbase + 2 * m)).x;
)"
R"(        qw.s3 = read_imageui(src0_q_img, (int)(wbase + 3 * m)).x;
)"
R"(        qw.s4 = read_imageui(src0_q_img, (int)(wbase + 4 * m)).x;
)"
R"(        qw.s5 = read_imageui(src0_q_img, (int)(wbase + 5 * m)).x;
)"
R"(        qw.s6 = read_imageui(src0_q_img, (int)(wbase + 6 * m)).x;
)"
R"(        qw.s7 = read_imageui(src0_q_img, (int)(wbase + 7 * m)).x;
)"
R"(
)"
R"(        for (uint idx = lid; idx < TILESIZE_N * 8; idx += 64) {
)"
R"(            const uint t = idx >> 3;
)"
R"(            const uint u = idx & 7;
)"
R"(            const uint c = col_base + t;
)"
R"(            sh_qa[t][u] = (c < (uint)n_no_padding) ? src1_qa[c * k_u + (step >> 2) + u] : 0u;
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
R"(            rf.s0 = (float)dot8_q8a(qw, sh_qa[b+0]);  rf.s1 = (float)dot8_q8a(qw, sh_qa[b+1]);
)"
R"(            rf.s2 = (float)dot8_q8a(qw, sh_qa[b+2]);  rf.s3 = (float)dot8_q8a(qw, sh_qa[b+3]);
)"
R"(            acc[g] += d_w * LD4(sh_d, b) * rf;
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
