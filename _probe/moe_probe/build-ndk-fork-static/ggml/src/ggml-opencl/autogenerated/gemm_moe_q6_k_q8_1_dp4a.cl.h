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
R"(// 4 2-bit highs in byte `b` (8 bits) -> 4 bytes, value 0..3 in bits 4-5
)"
R"(// (pre-multiplied by 16 so it ORs with the EXP4 nibble to form q6 in 0..63).
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
R"(// Flipping bit5 subtracts 32 in 6-bit two's complement; then replicate bit5
)"
R"(// into bits 6-7 to sign-extend to int8. Per-byte, no inter-byte carry.
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
R"(inline int dp4a_q6(uint qw0, uint qw1, uint qw2, uint qw3,
)"
R"(                   uint a0, uint a1, uint a2, uint a3) {
)"
R"(    int raw = 0;
)"
R"(    raw = dot_acc_sat_4x8packed_ss_int(qw0, a0, raw);
)"
R"(    raw = dot_acc_sat_4x8packed_ss_int(qw1, a1, raw);
)"
R"(    raw = dot_acc_sat_4x8packed_ss_int(qw2, a2, raw);
)"
R"(    raw = dot_acc_sat_4x8packed_ss_int(qw3, a3, raw);
)"
R"(    return raw;
)"
R"(}
)"
R"(
)"
R"(// One token's q6_K dp4a dot (two halves, per-16 scales) + epilogue into acc[t].
)"
R"(#define MOE_Q6K_DP4A_T(t) do {                                                                            \
)"
R"(        uint4 a0 = vload4(0, &sh_qa[t][0]);                                                               \
)"
R"(        uint4 a1 = vload4(0, &sh_qa[t][4]);                                                               \
)"
R"(        const int raw1 = dp4a_q6(qw[0], qw[1], qw[2], qw[3], a0.s0, a0.s1, a0.s2, a0.s3);                 \
)"
R"(        const int raw2 = dp4a_q6(qw[4], qw[5], qw[6], qw[7], a1.s0, a1.s1, a1.s2, a1.s3);                 \
)"
R"(        const float a_d = (float)sh_d[t];                                                                 \
)"
R"(        acc[t] += scale0 * a_d * (float)raw1 + scale1 * a_d * (float)raw2;                                \
)"
R"(    } while (0)
)"
R"(
)"
R"(__attribute__((qcom_wave_pair_mode(1)))
)"
R"(kernel void kernel_gemm_moe_q6_k_q8_1_dp4a(
)"
R"(        __read_only  image1d_buffer_t src0_ql,   // q6_K low nibbles (image, q4_K-style layout)
)"
R"(        __global     uint *           src0_qh,   // q6_K high 2-bit (16 elems/uint)
)"
R"(        __global     char *           src0_s,    // int8 scales (one per 16 elems)
)"
R"(        __global     half *           src0_d,    // per-superblock scale
)"
R"(        __global     uint *           src1_qa,   // q8_1 activations int8 (as uint, 4/elem)
)"
R"(        __global     half *           src1_da,   // q8_1 per-block scale [tok_slot * ne00/32]
)"
R"(        __global     uint *           src2,      // post-router (orig out positions)
)"
R"(        __global     ushort *         src2_emap, // tile -> expert id
)"
R"(        __write_only image1d_buffer_t dst,
)"
R"(        __global     int *            total_tiles,
)"
R"(        uint ne00,
)"
R"(        uint ne01,
)"
R"(        int  is_ragged                         // 1: compute only real tokens per tile
)"
R"() {
)"
R"(    const uint block_id_m = get_global_id(1);
)"
R"(    const uint block_id_n = get_global_id(2);
)"
R"(
)"
R"(    if (block_id_n >= total_tiles[0]) {
)"
R"(        return;
)"
R"(    }
)"
R"(
)"
R"(    const uint lid = get_local_id(0);          // 0..63 -> row within M-tile
)"
R"(
)"
R"(    const ushort expert_id = src2_emap[block_id_n];
)"
R"(    const uint   row = block_id_m * 64;
)"
R"(    const uint   col = block_id_n * TILESIZE_N;
)"
R"(
)"
R"(    const uint num_superblocks = ne00 / QK_K;
)"
R"(    const uint scales_per_row  = num_superblocks * 16;
)"
R"(    const uint row_idx         = row + lid;
)"
R"(
)"
R"(    const uint ne00_u = ne00 >> 2;
)"
R"(    const uint ne00_b = ne00 >> 5;
)"
R"(
)"
R"(    __local uint sh_qa[TILESIZE_N][8];
)"
R"(    __local half sh_d[TILESIZE_N];
)"
R"(
)"
R"(    // Real token count for this tile
)"
R"(    __local uint sh_src2[TILESIZE_N];
)"
R"(    __local int  sh_nreal;
)"
R"(    if (lid < TILESIZE_N) {
)"
R"(        sh_src2[lid] = src2[col + lid];
)"
R"(    }
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(    if (lid == 0) {
)"
R"(        int nr = TILESIZE_N;
)"
R"(        if (is_ragged) {
)"
R"(            nr = 0;
)"
R"(            #pragma unroll
)"
R"(            for (int t = 0; t < TILESIZE_N; ++t) {
)"
R"(                if (sh_src2[t] != 0xFFFFFFFFu) ++nr;
)"
R"(            }
)"
R"(        }
)"
R"(        sh_nreal = nr;
)"
R"(    }
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(    const int n_real = sh_nreal;
)"
R"(
)"
R"(    float acc[TILESIZE_N];
)"
R"(    #pragma unroll
)"
R"(    for (int t = 0; t < TILESIZE_N; ++t) acc[t] = 0.0f;
)"
R"(
)"
R"(    for (uint step = 0; step < ne00; step += 32) {
)"
R"(        const uint sub = step >> 5;
)"
R"(        const uint sb  = sub >> 3;
)"
R"(        const uint j   = sub & 7;
)"
R"(
)"
R"(        const float d_val = (float)src0_d[row + sb * ne01 + expert_id * num_superblocks * ne01 + lid];
)"
R"(        global const char * sc = src0_s + (expert_id * ne01 + row_idx) * scales_per_row + sb * 16;
)"
R"(        const float scale0 = d_val * (float)sc[j * 2];
)"
R"(        const float scale1 = d_val * (float)sc[j * 2 + 1];
)"
R"(
)"
R"(        // high bits: one uint covers 16 elems; first/second 16 of this 32-block
)"
R"(        const uint qh_base = row + (sub * 2) * ne01 + expert_id * (num_superblocks * 16) * ne01 + lid;
)"
R"(        const uint qh1 = src0_qh[qh_base];
)"
R"(        const uint qh2 = src0_qh[qh_base + ne01];
)"
R"(
)"
R"(        // low nibbles: same image layout as q4_K (8 ushorts over the 32 K)
)"
R"(        const uint qoff0 = row + ((ne01 * step) >> 3)        + ((expert_id * ne00 * ne01) >> 3);
)"
R"(        const uint qoff1 = row + ((ne01 * (step + 16)) >> 3) + ((expert_id * ne00 * ne01) >> 3);
)"
R"(        const uint r0 = read_imageui(src0_ql, qoff0 + lid).x;
)"
R"(        const uint r1 = read_imageui(src0_ql, qoff0 + lid + ne01).x;
)"
R"(        const uint r2 = read_imageui(src0_ql, qoff1 + lid).x;
)"
R"(        const uint r3 = read_imageui(src0_ql, qoff1 + lid + ne01).x;
)"
R"(
)"
R"(        uint qw[8];
)"
R"(        qw[0] = SIGN6(EXP4(r0)       | EXP2((qh1)       & 0xFFu));
)"
R"(        qw[1] = SIGN6(EXP4(r0 >> 16) | EXP2((qh1 >> 8)  & 0xFFu));
)"
R"(        qw[2] = SIGN6(EXP4(r1)       | EXP2((qh1 >> 16) & 0xFFu));
)"
R"(        qw[3] = SIGN6(EXP4(r1 >> 16) | EXP2((qh1 >> 24) & 0xFFu));
)"
R"(        qw[4] = SIGN6(EXP4(r2)       | EXP2((qh2)       & 0xFFu));
)"
R"(        qw[5] = SIGN6(EXP4(r2 >> 16) | EXP2((qh2 >> 8)  & 0xFFu));
)"
R"(        qw[6] = SIGN6(EXP4(r3)       | EXP2((qh2 >> 16) & 0xFFu));
)"
R"(        qw[7] = SIGN6(EXP4(r3 >> 16) | EXP2((qh2 >> 24) & 0xFFu));
)"
R"(
)"
R"(        // Stage each token's 8 activation uints as two 128-bit uint4 loads/stores.
)"
R"(        const uint vlim = (uint)n_real * 2;
)"
R"(        for (uint idx = lid; idx < vlim; idx += 64) {
)"
R"(            const uint t = idx >> 1;
)"
R"(            const uint h = (idx & 1) << 2;   // 0 or 4
)"
R"(            uint4 v = vload4(0, &src1_qa[(col + t) * ne00_u + (step >> 2) + h]);
)"
R"(            vstore4(v, 0, &sh_qa[t][h]);
)"
R"(        }
)"
R"(        if (lid < (uint)n_real) {
)"
R"(            sh_d[lid] = src1_da[(col + lid) * ne00_b + sub];
)"
R"(        }
)"
R"(        barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(        // Full tiles keep the fully-unrolled 32-wide loop; partial tiles run n_real.
)"
R"(        if (n_real == TILESIZE_N) {
)"
R"(            #pragma unroll
)"
R"(            for (int t = 0; t < TILESIZE_N; ++t) { MOE_Q6K_DP4A_T(t); }
)"
R"(        } else {
)"
R"(            #pragma unroll 4
)"
R"(            for (int t = 0; t < n_real; ++t) { MOE_Q6K_DP4A_T(t); }
)"
R"(        }
)"
R"(        barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(    }
)"
R"(
)"
R"(    if (row_idx >= ne01) {
)"
R"(        return;
)"
R"(    }
)"
R"(
)"
R"(    __local uint out_idx[TILESIZE_N];
)"
R"(    if (lid < TILESIZE_N) {
)"
R"(        uint idx = sh_src2[lid];
)"
R"(        if (idx == 0xFFFFFFFF) {
)"
R"(            idx = sh_src2[0];
)"
R"(        }
)"
R"(        out_idx[lid] = idx * ne01;
)"
R"(    }
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(    const uint m_offset = row + lid;
)"
R"(    if (n_real == TILESIZE_N) {
)"
R"(        #pragma unroll
)"
R"(        for (int t = 1; t < TILESIZE_N; ++t) {
)"
R"(            write_imagef(dst, out_idx[t] + m_offset, acc[t]);
)"
R"(        }
)"
R"(        barrier(CLK_GLOBAL_MEM_FENCE);
)"
R"(        write_imagef(dst, out_idx[0] + m_offset, acc[0]);
)"
R"(    } else {
)"
R"(        for (int t = 0; t < n_real; ++t) {
)"
R"(            write_imagef(dst, out_idx[t] + m_offset, acc[t]);
)"
R"(        }
)"
R"(    }
)"
R"(}
)"
