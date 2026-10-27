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
R"(#define TILESIZE_N 32
)"
R"(#define QK_K 256
)"
R"(#define K_SCALE_SIZE 12
)"
R"(
)"
R"(inline void get_scale_min_k4(
)"
R"(    int j,
)"
R"(    global const uchar * q,
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
R"(        *d = q[j]   & mask_d6;
)"
R"(        *m = q[j+4] & mask_d6;
)"
R"(    } else {
)"
R"(        *d = (q[j+4] & mask_d4) | ((q[j-4] & mask_hi2) >> 2);
)"
R"(        *m = ((q[j+4] >> 4) & mask_d4) | ((q[j]   & mask_hi2) >> 2);
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(// 4 nibbles in the low 16 bits of `u` -> 4 bytes (value 0..15, bits 0-3).
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
R"(// 4 high bits (one per element, in bits 0-3 of h) -> bit 4 of each of 4 bytes,
)"
R"(// so OR with EXP4 forms the 5-bit q5_K code 0..31.
)"
R"(#define EXP1(h)  ( (((uint)((h) & 0x1u)) << 4)   | \
)"
R"(                  (((uint)((h) & 0x2u)) << 11)  | \
)"
R"(                  (((uint)((h) & 0x4u)) << 18)  | \
)"
R"(                  (((uint)((h) & 0x8u)) << 25) )
)"
R"(
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
R"(kernel void kernel_gemm_noshuffle_q5_k_q8_1_dp4a(
)"
R"(        __global const ushort * src0_q,    // q5_K low nibbles (transposed, ushort = 4 nibbles)
)"
R"(        __global const uchar  * src0_qh,   // q5_K high bits (transposed, uchar = 8 elems/byte)
)"
R"(        __global const uchar  * src0_s,    // 6-bit scale/min codes [row][superblock][12]
)"
R"(        __global const half   * src0_d,    // per-superblock scale (transposed)
)"
R"(        __global const half   * src0_dm,   // per-superblock min (transposed)
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
R"(    const uint rrow     = row_valid ? row : 0;
)"
R"(
)"
R"(    const uint num_superblocks = (uint)k / QK_K;
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
R"(        global const uchar * sc = src0_s + rrow * num_superblocks * K_SCALE_SIZE + sb_idx * K_SCALE_SIZE;
)"
R"(        uchar sv, mn;
)"
R"(        get_scale_min_k4(sub_idx, sc, &sv, &mn, mask_d6, mask_d4, mask_hi2);
)"
R"(        const float scale = dd  * (float)sv;
)"
R"(        const float minv  = dmm * (float)mn;
)"
R"(
)"
R"(        // repack this row's 32 weights (nibble | high-bit) into 8 dp4a uints.
)"
R"(        // ushort u -> 4 elements at K = step + u*4; its 4 high bits are nibble
)"
R"(        // (u&1) of qh byte (step/8 + u/2).
)"
R"(        const uint wbase  = rrow + (step >> 2) * (uint)m;
)"
R"(        const uint qhbase = rrow + (step >> 3) * (uint)m;
)"
R"(        uint8 qw;
)"
R"(#define QWU(u) ( EXP4((uint)src0_q[wbase + (uint)(u) * m]) \
)"
R"(               | EXP1( (uint)((src0_qh[qhbase + (uint)((u) >> 1) * m] >> (((u) & 1) * 4)) & 0x0Fu) ) )
)"
R"(        qw.s0 = QWU(0); qw.s1 = QWU(1); qw.s2 = QWU(2); qw.s3 = QWU(3);
)"
R"(        qw.s4 = QWU(4); qw.s5 = QWU(5); qw.s6 = QWU(6); qw.s7 = QWU(7);
)"
R"(#undef QWU
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
