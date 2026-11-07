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
R"(// Weight layout, feature-major:
)"
R"(//   src0_q[row + (k/4)*m]  ushort = 4 nibbles (K = 4*grp .. +3)
)"
R"(//   src0_d[row + (k/32)*m] half   = per-32-block scale
)"
R"(
)"
R"(#define TILESIZE_N 32
)"
R"(
)"
R"(// IQ4_NL non-linear codebook as signed int8, packed 4 codes per uint.
)"
R"(// divergent nibble lookups read a small __constant uint array + shift,
)"
R"(// never a byte array because byte-indexed __constant loads serialize on Adreno and tank perf
)"
R"(//   idx 0-3:  -127,-104,-83,-65 = 0x81,0x98,0xAD,0xBF
)"
R"(//   idx 4-7:  -49,-35,-22,-10   = 0xCF,0xDD,0xEA,0xF6
)"
R"(//   idx 8-11:  1, 13, 25, 38    = 0x01,0x0D,0x19,0x26
)"
R"(//   idx 12-15: 53, 69, 89,113   = 0x35,0x45,0x59,0x71
)"
R"(__constant uint kvalues_iq4nl_i8x4[4] = {
)"
R"(    0xBFAD9881u, 0xF6EADDCFu, 0x26190D01u, 0x71594535u
)"
R"(};
)"
R"(
)"
R"(// nibble (0..15) -> its codebook byte in the low 8 bits.
)"
R"(inline uint iq4nl_code(uint n) {
)"
R"(    return (kvalues_iq4nl_i8x4[n >> 2] >> ((n & 3u) * 8u)) & 0xFFu;
)"
R"(}
)"
R"(
)"
R"(// 4 nibbles in low 16 bits of u -> 4 codebook int8, packed for dp4a.
)"
R"(inline uint iq4nl_pack(ushort u) {
)"
R"(    return  iq4nl_code((uint)( u        & 0xF))
)"
R"(         | (iq4nl_code((uint)((u >>  4) & 0xF)) <<  8)
)"
R"(         | (iq4nl_code((uint)((u >>  8) & 0xF)) << 16)
)"
R"(         | (iq4nl_code((uint)((u >> 12) & 0xF)) << 24);
)"
R"(}
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
R"(kernel void kernel_gemm_noshuffle_iq4_nl_q8_1_dp4a(
)"
R"(        __global const ushort * src0_q,    // IQ4_NL nibbles (4/ushort, feature-major)
)"
R"(        __global const half   * src0_d,    // per-32-block scale, feature-major
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
R"(        const uint sub = step >> 5;
)"
R"(
)"
R"(        const float d_w = (float)src0_d[rrow + sub * (uint)m];
)"
R"(
)"
R"(        // 8 weight uints (32 codebook int8) for this row, this 32-block.
)"
R"(        const uint qsbase = rrow + (step >> 2) * (uint)m;
)"
R"(        uint8 qw;
)"
R"(        qw.s0 = iq4nl_pack(src0_q[qsbase + 0 * m]);
)"
R"(        qw.s1 = iq4nl_pack(src0_q[qsbase + 1 * m]);
)"
R"(        qw.s2 = iq4nl_pack(src0_q[qsbase + 2 * m]);
)"
R"(        qw.s3 = iq4nl_pack(src0_q[qsbase + 3 * m]);
)"
R"(        qw.s4 = iq4nl_pack(src0_q[qsbase + 4 * m]);
)"
R"(        qw.s5 = iq4nl_pack(src0_q[qsbase + 5 * m]);
)"
R"(        qw.s6 = iq4nl_pack(src0_q[qsbase + 6 * m]);
)"
R"(        qw.s7 = iq4nl_pack(src0_q[qsbase + 7 * m]);
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
