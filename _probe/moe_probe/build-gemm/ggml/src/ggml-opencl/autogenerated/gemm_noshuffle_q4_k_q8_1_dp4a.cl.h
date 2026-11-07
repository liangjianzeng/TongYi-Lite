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
R"(#ifndef TILESIZE_N
)"
R"(#define TILESIZE_N 32
)"
R"(#endif
)"
R"(#define QK_K 256
)"
R"(#define K_SCALE_SIZE 12
)"
R"(
)"
R"(// scales are transposed: consecutive codes of a row are `stride` apart
)"
R"(inline void get_scale_min_k4(
)"
R"(    int j,
)"
R"(    global const uchar * q,
)"
R"(    uint stride,
)"
R"(    uchar * d,
)"
R"(    uchar * m,
)"
R"(    uchar mask_d6,
)"
R"(    uchar mask_d4,
)"
R"(    uchar mask_hi2
)"
R"() {
)"
R"(    if (j < 4) {
)"
R"(        *d = q[j*stride]     & mask_d6;
)"
R"(        *m = q[(j+4)*stride] & mask_d6;
)"
R"(    } else {
)"
R"(        *d = (q[(j+4)*stride] & mask_d4) | ((q[(j-4)*stride] & mask_hi2) >> 2);
)"
R"(        *m = ((q[(j+4)*stride] >> 4) & mask_d4) | ((q[j*stride] & mask_hi2) >> 2);
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(// Expand the 4 nibbles in the low 16 bits of `u` into 4 bytes (one nibble per
)"
R"(// byte, value 0..15), packed for the int8 dp4a.
)"
R"(#define EXP4(u)  ( ((uint)((u) & 0x000Fu))        | \
)"
R"(                  (((uint)((u) & 0x00F0u)) << 4)  | \
)"
R"(                  (((uint)((u) & 0x0F00u)) << 8)  | \
)"
R"(                  (((uint)((u) & 0xF000u)) << 12) )
)"
R"(
)"
R"(// 32-K dp4a dot of one token's int8 activations (8 packed uints in lm) against the
)"
R"(// row's 8 packed weight uints. qw passed by value as a uint8 (register), not an array.
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
R"(kernel void kernel_gemm_noshuffle_q4_k_q8_1_dp4a(
)"
R"(        __global const ushort * src0_q,    // q4_K weights (noshuffle, packed nibbles)
)"
R"(        __global const uchar  * src0_s,    // 6-bit scale/min codes
)"
R"(        __global const half   * src0_d,    // per-superblock scale
)"
R"(        __global const half   * src0_dm,   // per-superblock min
)"
R"(        __global const uint   * src1_qa,   // q8_1 activations int8 (as uint, 4/elem) [N, K]
)"
R"(        __global const half   * src1_da,   // q8_1 per-block scale [N, K/32]
)"
R"(        __global const half   * src1_sa,   // q8_1 per-block sum*d [N, K/32]
)"
R"(        __global       float  * dst,
)"
R"(        ulong  offsetd,
)"
R"(        int    m,                          // output features (rows)
)"
R"(        int    n_no_padding,               // tokens (cols)
)"
R"(        int    k,                          // K (== ne00)
)"
R"(        uchar  mask_d6,
)"
R"(        uchar  mask_d4,
)"
R"(        uchar  mask_hi2
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
R"(    __local half sh_s[TILESIZE_N];
)"
R"(
)"
R"(    // One float4 vector-register accumulator per group of 4 tokens (NGROUPS = TILESIZE_N/4).
)"
R"(#define NGROUPS (TILESIZE_N / 4)
)"
R"(    float4 acc[NGROUPS];
)"
R"(    #pragma unroll
)"
R"(    for (int g = 0; g < NGROUPS; ++g) { acc[g] = (float4)(0.0f); }
)"
R"(
)"
R"(    for (uint step = 0; step < (uint)k; step += 32) {
)"
R"(        const uint sub     = step >> 5;
)"
R"(        const uint sb_idx  = step / QK_K;
)"
R"(        const uint sub_idx = sub & 7;
)"
R"(
)"
R"(        // weight scale/min for this WI's row, this subblock
)"
R"(        const float dd  = (float)src0_d [rrow + sb_idx * m];
)"
R"(        const float dmm = (float)src0_dm[rrow + sb_idx * m];
)"
R"(        global const uchar * sc = src0_s + sb_idx * K_SCALE_SIZE * (uint)m + rrow;
)"
R"(        uchar sv, mn;
)"
R"(        get_scale_min_k4(sub_idx, sc, (uint)m, &sv, &mn, mask_d6, mask_d4, mask_hi2);
)"
R"(        const float scale = dd  * (float)sv;
)"
R"(        const float minv  = dmm * (float)mn;
)"
R"(
)"
R"(        // repack this row's 32 weight nibbles into 8 dp4a uints. The packed q4_K
)"
R"(        // layout stores one ushort = 4 consecutive-K nibbles for a row at
)"
R"(        // src0_q[row + (K_group)*m], K_group = step/4 + u.
)"
R"(        const uint wbase = rrow + (step >> 2) * (uint)m;
)"
R"(        uint8 qw;
)"
R"(        qw.s0 = EXP4(src0_q[wbase + 0 * m]);
)"
R"(        qw.s1 = EXP4(src0_q[wbase + 1 * m]);
)"
R"(        qw.s2 = EXP4(src0_q[wbase + 2 * m]);
)"
R"(        qw.s3 = EXP4(src0_q[wbase + 3 * m]);
)"
R"(        qw.s4 = EXP4(src0_q[wbase + 4 * m]);
)"
R"(        qw.s5 = EXP4(src0_q[wbase + 5 * m]);
)"
R"(        qw.s6 = EXP4(src0_q[wbase + 6 * m]);
)"
R"(        qw.s7 = EXP4(src0_q[wbase + 7 * m]);
)"
R"(
)"
R"(        // cooperatively stage the 32-token x 32-K int8 activations to lm
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
R"(            sh_s[lid] = (c < (uint)n_no_padding) ? src1_sa[c * k_b + sub] : (half)0;
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
R"(            acc[g] += scale * LD4(sh_d, b) * rf - minv * LD4(sh_s, b);
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
R"(    // dst is [token, feature] row-major (stride m): dst[col*m + row]. Scatter each
)"
R"(    // lane with a per-token padding guard (dst is non-contiguous in token).
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
R"(kernel void kernel_gemm_noshuffle_q4_k_q8_1_dp4a_wimg(
)"
R"(        __read_only image1d_buffer_t src0_q_img, // q4_K weights as uint32 texels (2 ushorts/texel)
)"
R"(        __global const uchar  * src0_s,    // 6-bit scale/min codes
)"
R"(        __global const half   * src0_d,    // per-superblock scale
)"
R"(        __global const half   * src0_dm,   // per-superblock min
)"
R"(        __global const uint   * src1_qa,   // q8_1 activations int8 (as uint, 4/elem) [N, K]
)"
R"(        __global const half   * src1_da,   // q8_1 per-block scale [N, K/32]
)"
R"(        __global const half   * src1_sa,   // q8_1 per-block sum*d [N, K/32]
)"
R"(        __global       float  * dst,
)"
R"(        ulong  offsetd,
)"
R"(        int    m,                          // output features (rows)
)"
R"(        int    n_no_padding,               // tokens (cols)
)"
R"(        int    k,                          // K (== ne00)
)"
R"(        uchar  mask_d6,
)"
R"(        uchar  mask_d4,
)"
R"(        uchar  mask_hi2
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
R"(    // Constant per WI: the ushort the row needs always sits in the same half of
)"
R"(    // its uint32 texel (m even => index parity == rrow parity). Hoist the shift.
)"
R"(    const uint sel = (rrow & 1u) * 16u;
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
R"(    __local half sh_s[TILESIZE_N];
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
R"(        const uint sub     = step >> 5;
)"
R"(        const uint sb_idx  = step / QK_K;
)"
R"(        const uint sub_idx = sub & 7;
)"
R"(
)"
R"(        const float dd  = (float)src0_d [rrow + sb_idx * m];
)"
R"(        const float dmm = (float)src0_dm[rrow + sb_idx * m];
)"
R"(        global const uchar * sc = src0_s + sb_idx * K_SCALE_SIZE * (uint)m + rrow;
)"
R"(        uchar sv, mn;
)"
R"(        get_scale_min_k4(sub_idx, sc, (uint)m, &sv, &mn, mask_d6, mask_d4, mask_hi2);
)"
R"(        const float scale = dd  * (float)sv;
)"
R"(        const float minv  = dmm * (float)mn;
)"
R"(
)"
R"(        const uint wbase = rrow + (step >> 2) * (uint)m;
)"
R"(        uint8 qw;
)"
R"(        qw.s0 = EXP4(read_imageui(src0_q_img, (int)((wbase + 0 * m) >> 1)).x >> sel);
)"
R"(        qw.s1 = EXP4(read_imageui(src0_q_img, (int)((wbase + 1 * m) >> 1)).x >> sel);
)"
R"(        qw.s2 = EXP4(read_imageui(src0_q_img, (int)((wbase + 2 * m) >> 1)).x >> sel);
)"
R"(        qw.s3 = EXP4(read_imageui(src0_q_img, (int)((wbase + 3 * m) >> 1)).x >> sel);
)"
R"(        qw.s4 = EXP4(read_imageui(src0_q_img, (int)((wbase + 4 * m) >> 1)).x >> sel);
)"
R"(        qw.s5 = EXP4(read_imageui(src0_q_img, (int)((wbase + 5 * m) >> 1)).x >> sel);
)"
R"(        qw.s6 = EXP4(read_imageui(src0_q_img, (int)((wbase + 6 * m) >> 1)).x >> sel);
)"
R"(        qw.s7 = EXP4(read_imageui(src0_q_img, (int)((wbase + 7 * m) >> 1)).x >> sel);
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
R"(            sh_s[lid] = (c < (uint)n_no_padding) ? src1_sa[c * k_b + sub] : (half)0;
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
R"(            acc[g] += scale * LD4(sh_d, b) * rf - minv * LD4(sh_s, b);
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
