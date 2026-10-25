R"(// Batched (N>1) q6_K GEMM over the 64-row-TILED canonical layout produced by
)"
R"(// kernel_convert_block_q6_k_tiled_ns (cvt.cl). Companion to the decode kernel
)"
R"(// kernel_gemv_noshuffle_q6_K_f32_tiled: SAME pack, SAME canonical e-order
)"
R"(// dequant (correct by construction vs reference ggml q6_K), extended to N output
)"
R"(// columns. Makes the batched lm_head/embed (perplexity, spec-decode verify,
)"
R"(// batched serving) correct on GPU while keeping the tiled convert the fast decode
)"
R"(// GEMV depends on.
)"
R"(//
)"
R"(// One work-item owns one output ROW for a block of BN columns. A work-group is
)"
R"(// {64 lanes, NTILES subgroups} = NTILES*64 rows; the global z dimension tiles the
)"
R"(// N columns by BN. Each work-item computes its row's FULL K (no K-split, so no
)"
R"(// cross-subgroup reduction), which lets the whole work-group share one staged
)"
R"(// activation block:
)"
R"(//
)"
R"(//   __local activation staging — the BN columns of the current superblock (BN*256
)"
R"(//   floats) are loaded into __local once per superblock, cooperatively by all
)"
R"(//   NTILES*64 work-items, then every row reads its activation from __local. This
)"
R"(//   removes the ~Nrows-fold redundant image reads of the first version (each lane
)"
R"(//   re-read the activation), which made the batched GEMM ~2x slower than the plain
)"
R"(//   noshuffle GEMM.
)"
R"(//
)"
R"(// Weights are read from __global (coalesced) — matching the decode kernel; the
)"
R"(// lm_head weight is streamed with little reuse where coalesced global beats the
)"
R"(// Adreno texture cache.
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
R"(#define NTILES     4        // 64-row tiles per work-group (NTILES*64 = 256 rows)
)"
R"(#define TILE_ROWS  64
)"
R"(#define BN         16       // output columns handled per work-group (global z step)
)"
R"(#define WG_THREADS (NTILES * TILE_ROWS)
)"
R"(
)"
R"(#if defined(ADRENO_GPU)
)"
R"(REQD_SUBGROUP_SIZE_64
)"
R"(#endif
)"
R"(kernel void kernel_gemm_noshuffle_q6_K_f32_tiled(
)"
R"(    __global uint4 * src0_ql,   // tiled: 8 uint4 granules / superblock
)"
R"(    __global uint4 * src0_qh,   // tiled: 4 uint4 granules / superblock
)"
R"(    __global char  * src0_s,    // tiled: 16 chars / superblock
)"
R"(    __global half  * src0_d,    // tiled: 1 half  / superblock
)"
R"(    read_only image1d_buffer_t src1,   // activation [ne00, ne11] f32 (RGBA), column-major
)"
R"(    global float * dst,
)"
R"(    ulong offsetd,
)"
R"(    int ne00,
)"
R"(    int ne01,
)"
R"(    int ne11
)"
R"() {
)"
R"(    int rit = get_local_id(0);          // 0..63  (lane within a tile; coalesces weight loads)
)"
R"(    int sg  = get_local_id(1);          // 0..NTILES-1
)"
R"(    int lid = sg * TILE_ROWS + rit;     // 0..WG_THREADS-1 (flat local id)
)"
R"(    int row = get_group_id(0) * WG_THREADS + lid;
)"
R"(    int rt  = row / TILE_ROWS;          // global 64-row tile index
)"
R"(    int col0 = get_global_id(2) * BN;   // first output column of this block
)"
R"(
)"
R"(    int nb = ne00 / 256;                // superblocks per row
)"
R"(    int act_col_stride = ne00 / 4;      // activation float4 pixels per column
)"
R"(
)"
R"(    const bool row_ok = row < ne01;
)"
R"(
)"
R"(    // staged activation: BN columns x 256 elements for the current superblock
)"
R"(    __local float lact[BN * 256];
)"
R"(
)"
R"(    float acc[BN];
)"
R"(    #pragma unroll
)"
R"(    for (int j = 0; j < BN; ++j) acc[j] = 0.0f;
)"
R"(
)"
R"(    for (int sb = 0; sb < nb; ++sb) {
)"
R"(        // cooperatively stage BN columns' 256 activation elements (= BN*64 float4)
)"
R"(        for (int p = lid; p < BN * 64; p += WG_THREADS) {
)"
R"(            int j  = p >> 6;            // column within the BN block (p / 64)
)"
R"(            int e4 = p & 63;            // element-quad within the column (p % 64)
)"
R"(            int c  = col0 + j;
)"
R"(            float4 v = (c < ne11)
)"
R"(                ? read_imagef(src1, c * act_col_stride + sb * 64 + e4)
)"
R"(                : (float4)(0.0f);
)"
R"(            lact[p * 4 + 0] = v.x;
)"
R"(            lact[p * 4 + 1] = v.y;
)"
R"(            lact[p * 4 + 2] = v.z;
)"
R"(            lact[p * 4 + 3] = v.w;      // lact[j*256 + e], e = e4*4 + t
)"
R"(        }
)"
R"(        barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(        if (row_ok) {
)"
R"(            int tile_blk = rt * nb + sb;    // ne02 == 1 for lm_head/embed
)"
R"(
)"
R"(            float dval = (float)src0_d[tile_blk * TILE_ROWS + rit];
)"
R"(            __global char * sc = src0_s + (tile_blk * TILE_ROWS + rit) * 16;
)"
R"(
)"
R"(            uint ql[32];
)"
R"(            uint qh[16];
)"
R"(            #pragma unroll
)"
R"(            for (int g = 0; g < 8; ++g) {
)"
R"(                uint4 v = src0_ql[(tile_blk * 8 + g) * TILE_ROWS + rit];
)"
R"(                ql[g*4+0] = v.x; ql[g*4+1] = v.y; ql[g*4+2] = v.z; ql[g*4+3] = v.w;
)"
R"(            }
)"
R"(            #pragma unroll
)"
R"(            for (int g = 0; g < 4; ++g) {
)"
R"(                uint4 v = src0_qh[(tile_blk * 4 + g) * TILE_ROWS + rit];
)"
R"(                qh[g*4+0] = v.x; qh[g*4+1] = v.y; qh[g*4+2] = v.z; qh[g*4+3] = v.w;
)"
R"(            }
)"
R"(
)"
R"(            // NOTE: the e loop (256) is deliberately NOT unrolled. Fully unrolling
)"
R"(            // 256*BN MACs overflows the in-process Adreno compiler (host stack
)"
R"(            // overflow at clBuildProgram, same class as the FA DK=512 OOM).
)"
R"(            for (int e = 0; e < 256; ++e) {
)"
R"(                uint low4 = (ql[e >> 3] >> ((e & 7) * 4)) & 0xF;
)"
R"(                uint hi2  = (qh[e >> 4] >> ((e & 15) * 2)) & 0x3;
)"
R"(                int  code = (int)(low4 | (hi2 << 4)) - 32;
)"
R"(                int  sidx = ((e >> 7) << 3) + (((e >> 5) & 3) << 1) + ((e >> 4) & 1);
)"
R"(                float cs  = (float)code * (float)sc[sidx] * dval;
)"
R"(                #pragma unroll
)"
R"(                for (int j = 0; j < BN; ++j) {
)"
R"(                    acc[j] += cs * lact[j * 256 + e];
)"
R"(                }
)"
R"(            }
)"
R"(        }
)"
R"(        barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(    }
)"
R"(
)"
R"(    if (row_ok) {
)"
R"(        dst = (global float*)((global char*)dst + offsetd);
)"
R"(        #pragma unroll
)"
R"(        for (int j = 0; j < BN; ++j) {
)"
R"(            int c = col0 + j;
)"
R"(            if (c < ne11) {
)"
R"(                dst[(ulong)c * ne01 + row] = acc[j];
)"
R"(            }
)"
R"(        }
)"
R"(    }
)"
R"(}
)"
