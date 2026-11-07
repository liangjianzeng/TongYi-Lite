R"(// Tiled-wide q4_K GEMV for the long-vocab lm_head/embed (decode path).
)"
R"(//
)"
R"(// Pairs with kernel_convert_block_q4_k_tiled_ns (cvt.cl): the weights are laid
)"
R"(// out CANONICALLY (4-bit code in element order e in [0,256)) and TILED by 64
)"
R"(// output rows so the 64-thread lane group coalesces every weight load. Both the
)"
R"(// pack (convert) and the unpack (here) are owned by us -> correct by
)"
R"(// construction vs the reference ggml q4_K dequant. Same structure as the q6_K
)"
R"(// tiled GEMV; the only differences are the 4-bit dequant and the q4_K
)"
R"(// scale/min decode (get_scale_min_k4 from the packed 12-byte block).
)"
R"(//
)"
R"(// One work-item produces one output row. WG = {64 lanes, 4 subgroups}: the 64
)"
R"(// lanes cover the 64 rows of one tile (coalesced uint4 reads), the 4 subgroups
)"
R"(// split the K-blocks and reduce through __local at the end. Weights read from
)"
R"(// __global (lm_head is streamed once per token; texture cache caps it below the
)"
R"(// coalesced-global rate).
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
R"(#define QK_K       256
)"
R"(#define NSUBGROUPS 4
)"
R"(#define TILE_ROWS  64
)"
R"(
)"
R"(// Decode one q4_K sub-block scale + min from the packed 12-byte block.
)"
R"(// Identical to the o4 kernel's helper (masks hard-coded: d6=0x3F, d4=0x0F, hi2=0xC0).
)"
R"(inline void q4k_scale_min(int j, __global const uchar * q, uchar * d, uchar * m) {
)"
R"(    if (j < 4) {
)"
R"(        *d = q[j]   & 0x3F;
)"
R"(        *m = q[j+4] & 0x3F;
)"
R"(    } else {
)"
R"(        *d = (q[j+4] & 0x0F) | ((q[j-4] & 0xC0) >> 2);
)"
R"(        *m = ((q[j+4] >> 4) & 0x0F) | ((q[j] & 0xC0) >> 2);
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(#if defined(ADRENO_GPU)
)"
R"(REQD_SUBGROUP_SIZE_64
)"
R"(#endif
)"
R"(kernel void kernel_gemv_noshuffle_q4_k_f32_tiled(
)"
R"(    __global uint4 * src0_q,    // tiled: 8 uint4 granules / superblock (4-bit codes)
)"
R"(    __global half  * src0_d,    // tiled: 1 half / superblock
)"
R"(    __global half  * src0_dm,   // tiled: 1 half / superblock
)"
R"(    __global uchar * src0_s,    // tiled: 12 bytes / superblock (packed scales)
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
R"(    int nb = ne00 / QK_K;               // superblocks per row
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
R"(        float dval  = (float)src0_d [tile_blk * TILE_ROWS + rit];
)"
R"(        float dmval = (float)src0_dm[tile_blk * TILE_ROWS + rit];
)"
R"(
)"
R"(        // decode the 8 sub-block (scale, min) pairs
)"
R"(        __global uchar * sc = src0_s + (tile_blk * TILE_ROWS + rit) * 12;
)"
R"(        float scale[8], minv[8];
)"
R"(        #pragma unroll
)"
R"(        for (int is = 0; is < 8; ++is) {
)"
R"(            uchar sd, sm;
)"
R"(            q4k_scale_min(is, sc, &sd, &sm);
)"
R"(            scale[is] = dval  * (float)sd;
)"
R"(            minv[is]  = dmval * (float)sm;
)"
R"(        }
)"
R"(
)"
R"(        // 32 uints of 4-bit codes (8 codes/uint), e-order
)"
R"(        uint q[32];
)"
R"(        #pragma unroll
)"
R"(        for (int g = 0; g < 8; ++g) {
)"
R"(            uint4 v = src0_q[(tile_blk * 8 + g) * TILE_ROWS + rit];
)"
R"(            q[g*4+0] = v.x; q[g*4+1] = v.y; q[g*4+2] = v.z; q[g*4+3] = v.w;
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
R"(                uint code = (q[e >> 3] >> ((e & 7) * 4)) & 0xF;
)"
R"(                int  is   = e >> 5;     // sub-block index = e/32
)"
R"(                float av  = (t == 0) ? a.x : (t == 1) ? a.y : (t == 2) ? a.z : a.w;
)"
R"(                acc += ((float)code * scale[is] - minv[is]) * av;
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
