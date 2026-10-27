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
R"(#define TILESIZE_M 64
)"
R"(#define TILESIZE_N 32
)"
R"(
)"
R"(// 2*mxfp4_value as signed int8, packed 4 codes per uint. Divergent nibble
)"
R"(// lookups read a __constant *uint* array + shift, never a byte array
)"
R"(// (byte-indexed __constant loads serialize on Adreno and are far slower).
)"
R"(//   idx 0-3:   0,  1,  2,  3   = 0x03020100
)"
R"(//   idx 4-7:   4,  6,  8, 12   = 0x0C080604
)"
R"(//   idx 8-11:  0, -1, -2, -3   = 0xFDFEFF00   (-1=0xFF,-2=0xFE,-3=0xFD)
)"
R"(//   idx 12-15:-4, -6, -8,-12   = 0xF4F8FAFC   (-4=0xFC,-6=0xFA,-8=0xF8,-12=0xF4)
)"
R"(__constant uint mxfp4_i8x4[4] = {
)"
R"(    0x03020100u, 0x0C080604u, 0xFDFEFF00u, 0xF4F8FAFCu
)"
R"(};
)"
R"(inline uint mxfp4_code(uint n) {
)"
R"(    return (mxfp4_i8x4[n >> 2] >> ((n & 3u) * 8u)) & 0xFFu;
)"
R"(}
)"
R"(// 4 nibbles in the low 16 bits of u -> 4 codebook int8, packed for dp4a.
)"
R"(inline uint mxfp4_pack(ushort u) {
)"
R"(    return  mxfp4_code((uint)( u        & 0xF))
)"
R"(         | (mxfp4_code((uint)((u >>  4) & 0xF)) <<  8)
)"
R"(         | (mxfp4_code((uint)((u >>  8) & 0xF)) << 16)
)"
R"(         | (mxfp4_code((uint)((u >> 12) & 0xF)) << 24);
)"
R"(}
)"
R"(
)"
R"(static inline float e8m0_to_fp32(uchar x) {
)"
R"(    int bits;
)"
R"(    bits = (x == 0) ? 0x00400000 : ((uint) x << 23);
)"
R"(    return as_float(bits);
)"
R"(}
)"
R"(
)"
R"(// One token's dp4a dot (8 uints = 32 K elems) + mxfp4 block-scale epilogue.
)"
R"(// blk_scale already carries the 0.5 factor (== 0.5 * 2^e).
)"
R"(#define MOE_MXFP4_DP4A_T(t) do {                                     \
)"
R"(        uint4 a0 = vload4(0, &sh_qa[t][0]);                          \
)"
R"(        uint4 a1 = vload4(0, &sh_qa[t][4]);                          \
)"
R"(        int raw = 0;                                                 \
)"
R"(        raw = dot_acc_sat_4x8packed_ss_int(qw[0], a0.s0, raw);       \
)"
R"(        raw = dot_acc_sat_4x8packed_ss_int(qw[1], a0.s1, raw);       \
)"
R"(        raw = dot_acc_sat_4x8packed_ss_int(qw[2], a0.s2, raw);       \
)"
R"(        raw = dot_acc_sat_4x8packed_ss_int(qw[3], a0.s3, raw);       \
)"
R"(        raw = dot_acc_sat_4x8packed_ss_int(qw[4], a1.s0, raw);       \
)"
R"(        raw = dot_acc_sat_4x8packed_ss_int(qw[5], a1.s1, raw);       \
)"
R"(        raw = dot_acc_sat_4x8packed_ss_int(qw[6], a1.s2, raw);       \
)"
R"(        raw = dot_acc_sat_4x8packed_ss_int(qw[7], a1.s3, raw);       \
)"
R"(        acc[t] += blk_scale * (float)sh_d[t] * (float)raw;           \
)"
R"(    } while (0)
)"
R"(
)"
R"(__attribute__((qcom_wave_pair_mode(1)))
)"
R"(kernel void kernel_gemm_moe_mxfp4_q8_1_dp4a(
)"
R"(        __read_only  image1d_buffer_t src0_q,    // mxfp4 codes (transposed, packed nibbles)
)"
R"(        __global     uchar *          src0_e,    // e8m0 per-32-block scale
)"
R"(        __global     uint *           src1_qa,   // q8_1 activations: int8 quants (as uint, 4/elem)
)"
R"(        __global     half *           src1_da,   // q8_1 per-block scale  [tok_slot * ne00/32]
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
R"(        int  is_ragged                           // 1: compute only real tokens per tile
)"
R"() {
)"
R"(    const uint block_id_m = get_global_id(1); // m_tile
)"
R"(    const uint block_id_n = get_global_id(2); // n_tile
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
R"(    const uint lid = get_local_id(0);          // 0..63, == this WI's output row in the M-tile
)"
R"(
)"
R"(    const ushort expert_id = src2_emap[block_id_n];
)"
R"(    const uint   row = block_id_m * TILESIZE_M;
)"
R"(    const uint   col = block_id_n * TILESIZE_N;
)"
R"(
)"
R"(    const uint num_blocks = ne00 >> 5;          // blocks-of-32 per token
)"
R"(    const uint row_idx    = row + lid;
)"
R"(
)"
R"(    const uint ne00_u = ne00 >> 2;   // ne00 in uint (int8x4) units
)"
R"(
)"
R"(    __local uint sh_qa[TILESIZE_N][8]; // 32 tokens x 8 uints (32 int8) = 1 KiB
)"
R"(    __local half sh_d[TILESIZE_N];
)"
R"(
)"
R"(    // Real token count for this tile.
)"
R"(    // Real tokens are packed contiguously at the tile start; padded slots hold
)"
R"(    // 0xFFFFFFFF (only the last tile of each expert is partial). is_ragged skips
)"
R"(    // the dp4a/staging/scatter for padded slots; is_ragged==0 forces n_real=32.
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
R"(        const uint sub = step >> 5;        // 32-block index along K
)"
R"(
)"
R"(        // e8m0 block scale for this WI's row, this 32-block (folded x0.5)
)"
R"(        const uint e_offset = row_idx + sub * ne01 + expert_id * num_blocks * ne01;
)"
R"(        const float blk_scale = 0.5f * e8m0_to_fp32(src0_e[e_offset]);
)"
R"(
)"
R"(        // repack this WI's 32 weight nibbles into 8 dp4a uints
)"
R"(        const uint qoff0 = row + ((ne01 * step) >> 3)        + ((expert_id * ne00 * ne01) >> 3);
)"
R"(        const uint qoff1 = row + ((ne01 * (step + 16)) >> 3) + ((expert_id * ne00 * ne01) >> 3);
)"
R"(        const uint r0 = read_imageui(src0_q, qoff0 + lid).x;
)"
R"(        const uint r1 = read_imageui(src0_q, qoff0 + lid + ne01).x;
)"
R"(        const uint r2 = read_imageui(src0_q, qoff1 + lid).x;
)"
R"(        const uint r3 = read_imageui(src0_q, qoff1 + lid + ne01).x;
)"
R"(        uint qw[8];
)"
R"(        qw[0] = mxfp4_pack((ushort)(r0));        qw[1] = mxfp4_pack((ushort)(r0 >> 16));
)"
R"(        qw[2] = mxfp4_pack((ushort)(r1));        qw[3] = mxfp4_pack((ushort)(r1 >> 16));
)"
R"(        qw[4] = mxfp4_pack((ushort)(r2));        qw[5] = mxfp4_pack((ushort)(r2 >> 16));
)"
R"(        qw[6] = mxfp4_pack((ushort)(r3));        qw[7] = mxfp4_pack((ushort)(r3 >> 16));
)"
R"(
)"
R"(        // cooperatively stage the n_real-token x 32-K int8 activations
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
R"(            sh_d[lid] = src1_da[(col + lid) * num_blocks + sub];
)"
R"(        }
)"
R"(        barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(        // Full tiles keep the fully-unrolled 32-wide loop; partial tiles run only n_real
)"
R"(        if (n_real == TILESIZE_N) {
)"
R"(            #pragma unroll
)"
R"(            for (int t = 0; t < TILESIZE_N; ++t) { MOE_MXFP4_DP4A_T(t); }
)"
R"(        } else {
)"
R"(            #pragma unroll 4
)"
R"(            for (int t = 0; t < n_real; ++t) { MOE_MXFP4_DP4A_T(t); }
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
R"(    // scatter results to original output rows (reuse sh_src2 from the top)
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
