R"(// Tiled-wide q6_K GEMV for the long-vocab lm_head/embed (decode path).
)"
R"(//
)"
R"(// Pairs with kernel_convert_block_q6_k_tiled_ns (cvt.cl): the weights are laid
)"
R"(// out CANONICALLY (6-bit code in element order e in [0,256)) and TILED by 64
)"
R"(// output rows so the 64-thread lane group coalesces every weight load. Both the
)"
R"(// pack (convert) and the unpack (here) are owned by us — correct by construction
)"
R"(// against the reference ggml q6_K dequant, no bit-interleave reverse-engineering.
)"
R"(//
)"
R"(// One work-item produces one output row. A work-group is {64 lanes, 4 subgroups}:
)"
R"(// the 64 lanes cover the 64 rows of one tile (coalesced reads), the 4 subgroups
)"
R"(// split the K-blocks and reduce through __local at the end.
)"
R"(//
)"
R"(// Weights are read from __global (coalesced) rather than image1d_buffer: the
)"
R"(// lm_head is read once per token with no reuse, and the Adreno texture cache
)"
R"(// caps such a streaming read well below the coalesced-global rate
)"
R"(// (see opencl_q6k_gemv_o4_shipped / x2-90 roofline notes).
)"
R"(
)"
R"(#pragma OPENCL EXTENSION cl_khr_fp16 : enable
)"
R"(
)"
R"(#ifdef cl_qcom_reqd_sub_group_size
)"
R"(#pragma OPENCL EXTENSION cl_qcom_reqd_sub_group_size : enable
)"
R"(#define ADRENO_GPU 1
)"
R"(#define REQD_SUBGROUP_SIZE_64  __attribute__((qcom_reqd_sub_group_size("half")))
)"
R"(#endif
)"
R"(
)"
R"(#define NSUBGROUPS 4
)"
R"(#define TILE_ROWS  64
)"
R"(
)"
R"(#if defined(ADRENO_GPU)
)"
R"(REQD_SUBGROUP_SIZE_64
)"
R"(#endif
)"
R"(kernel void kernel_gemv_noshuffle_q6_K_f32_tiled(
)"
R"(    __global uint4 * src0_ql,   // tiled: 8 uint4 granules / superblock
)"
R"(    __global uint4 * src0_qh,   // tiled: 4 uint4 granules / superblock
)"
R"(    __global char  * src0_s,    // tiled: 16 chars / superblock
)"
R"(    __global half  * src0_d,    // tiled: 1 half  / superblock
)"
R"(    read_only image1d_buffer_t src1,   // activation (RGBA f32)
)"
R"(    global float * dst,
)"
R"(    ulong offsetd,
)"
R"(    int ne00,
)"
R"(    int ne01
)"
R"() {
)"
R"(    int grp = get_local_id(1);          // subgroup index 0..3 (splits K)
)"
R"(    int row = get_global_id(0);         // output row along ne01
)"
R"(    int rt  = row / TILE_ROWS;
)"
R"(    int rit = row % TILE_ROWS;
)"
R"(
)"
R"(    int nb = ne00 / 256;                // superblocks per row
)"
R"(
)"
R"(    float acc = 0.0f;
)"
R"(
)"
R"(    for (int sb = grp; sb < nb; sb += NSUBGROUPS) {
)"
R"(        int tile_blk = rt * nb + sb;    // ne02 == 1 for lm_head/embed
)"
R"(
)"
R"(        // d + 16 scales for this (row, superblock)
)"
R"(        float dval = (float)src0_d[tile_blk * TILE_ROWS + rit];
)"
R"(        __global char * sc = src0_s + (tile_blk * TILE_ROWS + rit) * 16;
)"
R"(
)"
R"(        // 32 ql-uints (8 codes/uint) + 16 qh-uints (16 codes/uint)
)"
R"(        uint ql[32];
)"
R"(        uint qh[16];
)"
R"(        #pragma unroll
)"
R"(        for (int g = 0; g < 8; ++g) {
)"
R"(            uint4 v = src0_ql[(tile_blk * 8 + g) * TILE_ROWS + rit];
)"
R"(            ql[g*4+0] = v.x; ql[g*4+1] = v.y; ql[g*4+2] = v.z; ql[g*4+3] = v.w;
)"
R"(        }
)"
R"(        #pragma unroll
)"
R"(        for (int g = 0; g < 4; ++g) {
)"
R"(            uint4 v = src0_qh[(tile_blk * 4 + g) * TILE_ROWS + rit];
)"
R"(            qh[g*4+0] = v.x; qh[g*4+1] = v.y; qh[g*4+2] = v.z; qh[g*4+3] = v.w;
)"
R"(        }
)"
R"(
)"
R"(        // dequant 256 codes in canonical e-order, MAC with activation.
)"
R"(        int act_base = sb * 64;         // activation float4 pixel base (256/4)
)"
R"(        #pragma unroll
)"
R"(        for (int e4 = 0; e4 < 64; ++e4) {
)"
R"(            float4 a = read_imagef(src1, act_base + e4);
)"
R"(            #pragma unroll
)"
R"(            for (int t = 0; t < 4; ++t) {
)"
R"(                int  e    = e4 * 4 + t;
)"
R"(                uint low4 = (ql[e >> 3] >> ((e & 7) * 4)) & 0xF;
)"
R"(                uint hi2  = (qh[e >> 4] >> ((e & 15) * 2)) & 0x3;
)"
R"(                int  code = (int)(low4 | (hi2 << 4)) - 32;
)"
R"(                int  sidx = ((e >> 7) << 3) + (((e >> 5) & 3) << 1) + ((e >> 4) & 1);
)"
R"(                float scale = (float)sc[sidx] * dval;
)"
R"(                float av = (t == 0) ? a.x : (t == 1) ? a.y : (t == 2) ? a.z : a.w;
)"
R"(                acc += (float)code * scale * av;
)"
R"(            }
)"
R"(        }
)"
R"(    }
)"
R"(
)"
R"(    // reduce across the NSUBGROUPS subgroups (same rit, different K-subset)
)"
R"(    local float reduce_lm[NSUBGROUPS * TILE_ROWS];
)"
R"(    reduce_lm[grp * TILE_ROWS + rit] = acc;
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(    if (grp == 0) {
)"
R"(        float total = reduce_lm[0 * TILE_ROWS + rit]
)"
R"(                    + reduce_lm[1 * TILE_ROWS + rit]
)"
R"(                    + reduce_lm[2 * TILE_ROWS + rit]
)"
R"(                    + reduce_lm[3 * TILE_ROWS + rit];
)"
R"(        dst = (global float*)((global char*)dst + offsetd);
)"
R"(        dst[row] = total;
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(// Multi-column (N=3) variant of the tiled q6_K decode GEMV, for the speculative/
)"
R"(// MTP VERIFY lm_head/embed (ne1=3 = 2 drafts + 1 bonus). Identical tiled weight
)"
R"(// layout + unpack as the ne1=1 kernel above; each WI computes 3 output columns,
)"
R"(// streaming the (large) lm_head weight ONCE per superblock and reusing it across
)"
R"(// the 3 verify activation columns (dequant once per code, MAC into 3 accs). This
)"
R"(// is the lm_head analogue of the per-layer mc3 GEMV; the multiply order matches
)"
R"(// the ne1=1 kernel, so each column is byte-identical to a standalone tiled GEMV.
)"
R"(#if defined(ADRENO_GPU)
)"
R"(REQD_SUBGROUP_SIZE_64
)"
R"(#endif
)"
R"(kernel void kernel_gemv_noshuffle_q6_K_f32_tiled_mc3(
)"
R"(    __global uint4 * src0_ql,
)"
R"(    __global uint4 * src0_qh,
)"
R"(    __global char  * src0_s,
)"
R"(    __global half  * src0_d,
)"
R"(    read_only image1d_buffer_t src1,
)"
R"(    global float * dst,
)"
R"(    ulong offsetd,
)"
R"(    int ne00,
)"
R"(    int ne01
)"
R"() {
)"
R"(    int grp = get_local_id(1);
)"
R"(    int row = get_global_id(0);
)"
R"(    int rt  = row / TILE_ROWS;
)"
R"(    int rit = row % TILE_ROWS;
)"
R"(
)"
R"(    int nb = ne00 / 256;
)"
R"(    int col_stride = ne00 / 4;          // activation float4 pixels per column
)"
R"(
)"
R"(    float acc0 = 0.0f, acc1 = 0.0f, acc2 = 0.0f;
)"
R"(
)"
R"(    for (int sb = grp; sb < nb; sb += NSUBGROUPS) {
)"
R"(        int tile_blk = rt * nb + sb;
)"
R"(
)"
R"(        float dval = (float)src0_d[tile_blk * TILE_ROWS + rit];
)"
R"(        __global char * sc = src0_s + (tile_blk * TILE_ROWS + rit) * 16;
)"
R"(
)"
R"(        uint ql[32];
)"
R"(        uint qh[16];
)"
R"(        #pragma unroll
)"
R"(        for (int g = 0; g < 8; ++g) {
)"
R"(            uint4 v = src0_ql[(tile_blk * 8 + g) * TILE_ROWS + rit];
)"
R"(            ql[g*4+0] = v.x; ql[g*4+1] = v.y; ql[g*4+2] = v.z; ql[g*4+3] = v.w;
)"
R"(        }
)"
R"(        #pragma unroll
)"
R"(        for (int g = 0; g < 4; ++g) {
)"
R"(            uint4 v = src0_qh[(tile_blk * 4 + g) * TILE_ROWS + rit];
)"
R"(            qh[g*4+0] = v.x; qh[g*4+1] = v.y; qh[g*4+2] = v.z; qh[g*4+3] = v.w;
)"
R"(        }
)"
R"(
)"
R"(        int act_base = sb * 64;
)"
R"(        #pragma unroll
)"
R"(        for (int e4 = 0; e4 < 64; ++e4) {
)"
R"(            float4 a0 = read_imagef(src1, 0*col_stride + act_base + e4);
)"
R"(            float4 a1 = read_imagef(src1, 1*col_stride + act_base + e4);
)"
R"(            float4 a2 = read_imagef(src1, 2*col_stride + act_base + e4);
)"
R"(            #pragma unroll
)"
R"(            for (int t = 0; t < 4; ++t) {
)"
R"(                int  e    = e4 * 4 + t;
)"
R"(                uint low4 = (ql[e >> 3] >> ((e & 7) * 4)) & 0xF;
)"
R"(                uint hi2  = (qh[e >> 4] >> ((e & 15) * 2)) & 0x3;
)"
R"(                int  code = (int)(low4 | (hi2 << 4)) - 32;
)"
R"(                int  sidx = ((e >> 7) << 3) + (((e >> 5) & 3) << 1) + ((e >> 4) & 1);
)"
R"(                float w   = (float)code * ((float)sc[sidx] * dval);  // dequant+scale once
)"
R"(                float av0 = (t == 0) ? a0.x : (t == 1) ? a0.y : (t == 2) ? a0.z : a0.w;
)"
R"(                float av1 = (t == 0) ? a1.x : (t == 1) ? a1.y : (t == 2) ? a1.z : a1.w;
)"
R"(                float av2 = (t == 0) ? a2.x : (t == 1) ? a2.y : (t == 2) ? a2.z : a2.w;
)"
R"(                acc0 += w * av0;
)"
R"(                acc1 += w * av1;
)"
R"(                acc2 += w * av2;
)"
R"(            }
)"
R"(        }
)"
R"(    }
)"
R"(
)"
R"(    local float4 reduce_lm[NSUBGROUPS * TILE_ROWS];
)"
R"(    reduce_lm[grp * TILE_ROWS + rit] = (float4)(acc0, acc1, acc2, 0.0f);
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(    if (grp == 0) {
)"
R"(        float4 total = reduce_lm[0 * TILE_ROWS + rit]
)"
R"(                     + reduce_lm[1 * TILE_ROWS + rit]
)"
R"(                     + reduce_lm[2 * TILE_ROWS + rit]
)"
R"(                     + reduce_lm[3 * TILE_ROWS + rit];
)"
R"(        dst = (global float*)((global char*)dst + offsetd);
)"
R"(        // dst column-major [ne01 rows x 3 cols]: (row, col) at col*ne01 + row
)"
R"(        dst[0*ne01 + row] = total.x;
)"
R"(        dst[1*ne01 + row] = total.y;
)"
R"(        dst[2*ne01 + row] = total.z;
)"
R"(    }
)"
R"(}
)"
