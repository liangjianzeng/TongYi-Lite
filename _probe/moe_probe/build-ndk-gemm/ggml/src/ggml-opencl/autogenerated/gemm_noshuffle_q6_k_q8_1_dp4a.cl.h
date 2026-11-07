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
R"(
)"
R"(// 4 nibbles in the low 16 bits of `u` -> 4 bytes (value 0..15, in bits 0-3).
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
R"(// 4 2-bit highs in byte `b` -> 4 bytes, value 0..3 in bits 4-5 (pre-multiplied
)"
R"(// by 16 so it ORs with the EXP4 nibble to form q6 in 0..63).
)"
R"(#define EXP2(b)  ( (((uint)((b) & 0x03u)) << 4)   | \
)"
R"(                  (((uint)((b) & 0x0Cu)) << 10)  | \
)"
R"(                  (((uint)((b) & 0x30u)) << 16)  | \
)"
R"(                  (((uint)((b) & 0xC0u)) << 22) )
)"
R"(
)"
R"(// q6 (0..63, bits 0-5 of each byte) -> (q6-32) as a signed int8 per byte.
)"
R"(inline uint SIGN6(uint q6p) {
)"
R"(    uint x = q6p ^ 0x20202020u;
)"
R"(    uint s = x & 0x20202020u;
)"
R"(    return x | (s << 1) | (s << 2);
)"
R"(}
)"
R"(
)"
R"(// 16-K dp4a dot: 4 packed weight uints against 4 packed int8 activation uints.
)"
R"(inline int dot4_q8a(uint w0, uint w1, uint w2, uint w3,
)"
R"(                    uint a0, uint a1, uint a2, uint a3) {
)"
R"(    int r = 0;
)"
R"(    r = dot_acc_sat_4x8packed_ss_int(w0, a0, r);
)"
R"(    r = dot_acc_sat_4x8packed_ss_int(w1, a1, r);
)"
R"(    r = dot_acc_sat_4x8packed_ss_int(w2, a2, r);
)"
R"(    r = dot_acc_sat_4x8packed_ss_int(w3, a3, r);
)"
R"(    return r;
)"
R"(}
)"
R"(
)"
R"(__attribute__((qcom_wave_pair_mode(1)))
)"
R"(kernel void kernel_gemm_noshuffle_q6_k_q8_1_dp4a(
)"
R"(        __global const ushort * src0_ql,   // q6_K low nibbles (noshuffle)
)"
R"(        __global const uchar  * src0_qh,   // q6_K high 2-bit (uchar, 4 highs/elem)
)"
R"(        __global const ushort * src0_s,    // int8 scale codes (2 chars/ushort, per 16)
)"
R"(        __global const half   * src0_d,    // per-superblock scale
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
R"(        const uint sub    = step >> 5;    // 32-block index along K
)"
R"(        const uint sb_idx = step / QK_K;  // superblock index
)"
R"(
)"
R"(        // q6_K superblock scale + the two int8 sub-scales spanning this 32-block
)"
R"(        const float dd = (float)src0_d[rrow + sb_idx * m];
)"
R"(        const char2 sc = as_char2(src0_s[rrow + sub * m]);
)"
R"(        const float scale0 = dd * (float)sc.s0;   // K step..step+15
)"
R"(        const float scale1 = dd * (float)sc.s1;   // K step+16..step+31
)"
R"(
)"
R"(        // repack this row's 32 weights into 8 dp4a uints (4 K each). ql ushort +
)"
R"(        // qh uchar are co-located at src0_*[row + (step/4 + u)*m].
)"
R"(        const uint wbase = rrow + (step >> 2) * (uint)m;
)"
R"(        uint qw[8];
)"
R"(        #pragma unroll
)"
R"(        for (int u = 0; u < 8; ++u) {
)"
R"(            const uint o  = wbase + (uint)u * (uint)m;
)"
R"(            qw[u] = SIGN6(EXP4((uint)src0_ql[o]) | EXP2((uint)src0_qh[o]));
)"
R"(        }
)"
R"(
)"
R"(        // cooperatively stage the 32-token x 32-K int8 activations + scale
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
R"(        #pragma unroll
)"
R"(        for (int g = 0; g < NGROUPS; ++g) {
)"
R"(            const int b = g * 4;
)"
R"(            float4 rf;
)"
R"(            #define DOT_TOK(j) { \
)"
R"(                __local const uint * a = sh_qa[b + (j)]; \
)"
R"(                const int raw1 = dot4_q8a(qw[0], qw[1], qw[2], qw[3], a[0], a[1], a[2], a[3]); \
)"
R"(                const int raw2 = dot4_q8a(qw[4], qw[5], qw[6], qw[7], a[4], a[5], a[6], a[7]); \
)"
R"(                rf.s##j = scale0 * (float)raw1 + scale1 * (float)raw2; \
)"
R"(            }
)"
R"(            DOT_TOK(0); DOT_TOK(1); DOT_TOK(2); DOT_TOK(3);
)"
R"(            #undef DOT_TOK
)"
R"(            const float4 ad = (float4)((float)sh_d[b+0], (float)sh_d[b+1], (float)sh_d[b+2], (float)sh_d[b+3]);
)"
R"(            acc[g] += ad * rf;
)"
R"(        }
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
