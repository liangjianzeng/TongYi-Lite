#pragma OPENCL EXTENSION cl_khr_fp16 : enable
#pragma OPENCL EXTENSION cl_khr_subgroups : enable

// [dspark 2026-10-14] Scalar-float subgroup broadcast. 740's online compiler
// lacks float overloads of sub_group_broadcast entirely -> host passes
// -DSGB_SCALAR_BROKEN and broadcasts go through the uint-bitcast shim.
// 830 (E031.47) has working float broadcast but miscompiles kernels whose
// broadcasts go through an inline wrapper, even in pass-through form
// (NMSE~2.2, 2026-10-14) -> uses the direct builtin. All call sites are
// per-component scalar: no vector broadcast anywhere.
#ifdef SGB_SCALAR_BROKEN
inline float sgb_f(float v, uint lid) {
    return as_float(sub_group_broadcast(as_uint(v), lid));
}
#define SGB_BC(v, lid) sgb_f(v, lid)
#else
#define SGB_BC(v, lid) sub_group_broadcast(v, lid)
#endif

#ifdef cl_qcom_reqd_sub_group_size
#pragma OPENCL EXTENSION cl_qcom_reqd_sub_group_size : enable
#define ADRENO_GPU 1
#define REQD_SUBGROUP_SIZE_64 __attribute__((qcom_reqd_sub_group_size("half")))
#else
// [dspark 2026-10-19] rusticl (FD650/FD740) picks its native subgroup size
// (measured 128) unless pinned. The GEMV protocol below is written for 64:
// lanes slid<4 load B and broadcast to the subgroup, and the local-memory
// reduce indexes SIMDGROUP_WIDTH(=64) slots per y-group. With sgs=128 the
// broadcast crosses y-groups (wrong B per k) and the reduce writes past the
// 192-slot array (OOB) -> garbage/NaN outputs for any multi-workgroup M.
// intel_reqd_sub_group_size is honored by rusticl; unknown on the qcom
// proprietary compiler, where the qcom attribute above applies instead.
#define REQD_SUBGROUP_SIZE_64 __attribute__((intel_reqd_sub_group_size(64)))
#endif

// the driver's online compiler lacks float overloads of sub_group_broadcast
// (Adreno 740: only scalar uint/int/long/ulong exist). Bitcast float<->uint,
// broadcast as integer, cast back — bitwise identical, subgroup-uniform.
#define QK8_0 32
#define N_SIMDGROUP 4

#define dequantizeBlockAccum_ns_sgbroadcast_1(total_sums, bits8, scale, y) \
    float shared_y; \
    char elem; \
                                             \
    shared_y = SGB_BC(y.s0, 0); \
    elem = (char)(bits8.s0 & 0x000000FF); \
    total_sums += convert_int(elem) * scale * shared_y; \
    shared_y = SGB_BC(y.s1, 0); \
    elem = (char)((bits8.s0 & 0x0000FF00) >> 8); \
    total_sums += convert_int(elem) * scale * shared_y; \
    shared_y = SGB_BC(y.s2, 0); \
    elem = (char)((bits8.s0 & 0x00FF0000) >> 16); \
    total_sums += convert_int(elem) * scale * shared_y; \
    shared_y = SGB_BC(y.s3, 0); \
    elem = (char)((bits8.s0 & 0xFF000000) >> 24); \
    total_sums += convert_int(elem) * scale * shared_y; \
                                             \
    shared_y = SGB_BC(y.s4, 0); \
    elem = (char)(bits8.s1 & 0x000000FF); \
    total_sums += convert_int(elem) * scale * shared_y; \
    shared_y = SGB_BC(y.s5, 0); \
    elem = (char)((bits8.s1 & 0x0000FF00) >> 8); \
    total_sums += convert_int(elem) * scale * shared_y; \
    shared_y = SGB_BC(y.s6, 0); \
    elem = (char)((bits8.s1 & 0x00FF0000) >> 16); \
    total_sums += convert_int(elem) * scale * shared_y; \
    shared_y = SGB_BC(y.s7, 0); \
    elem = (char)((bits8.s1 & 0xFF000000) >> 24); \
    total_sums += convert_int(elem) * scale * shared_y; \
                                             \
    shared_y = SGB_BC(y.s0, 1); \
    elem = (char)(bits8.s2 & 0x000000FF); \
    total_sums += convert_int(elem) * scale * shared_y; \
    shared_y = SGB_BC(y.s1, 1); \
    elem = (char)((bits8.s2 & 0x0000FF00) >> 8); \
    total_sums += convert_int(elem) * scale * shared_y; \
    shared_y = SGB_BC(y.s2, 1); \
    elem = (char)((bits8.s2 & 0x00FF0000) >> 16); \
    total_sums += convert_int(elem) * scale * shared_y; \
    shared_y = SGB_BC(y.s3, 1); \
    elem = (char)((bits8.s2 & 0xFF000000) >> 24); \
    total_sums += convert_int(elem) * scale * shared_y; \
                                             \
    shared_y = SGB_BC(y.s4, 1); \
    elem = (char)(bits8.s3 & 0x000000FF); \
    total_sums += convert_int(elem) * scale * shared_y; \
    shared_y = SGB_BC(y.s5, 1); \
    elem = (char)((bits8.s3 & 0x0000FF00) >> 8); \
    total_sums += convert_int(elem) * scale * shared_y; \
    shared_y = SGB_BC(y.s6, 1); \
    elem = (char)((bits8.s3 & 0x00FF0000) >> 16); \
    total_sums += convert_int(elem) * scale * shared_y; \
    shared_y = SGB_BC(y.s7, 1); \
    elem = (char)((bits8.s3 & 0xFF000000) >> 24); \
    total_sums += convert_int(elem) * scale * shared_y; \
                                             \
    shared_y = SGB_BC(y.s0, 2); \
    elem = (char)(bits8.s4 & 0x000000FF); \
    total_sums += convert_int(elem) * scale * shared_y; \
    shared_y = SGB_BC(y.s1, 2); \
    elem = (char)((bits8.s4 & 0x0000FF00) >> 8); \
    total_sums += convert_int(elem) * scale * shared_y; \
    shared_y = SGB_BC(y.s2, 2); \
    elem = (char)((bits8.s4 & 0x00FF0000) >> 16); \
    total_sums += convert_int(elem) * scale * shared_y; \
    shared_y = SGB_BC(y.s3, 2); \
    elem = (char)((bits8.s4 & 0xFF000000) >> 24); \
    total_sums += convert_int(elem) * scale * shared_y; \
                                             \
    shared_y = SGB_BC(y.s4, 2); \
    elem = (char)(bits8.s5 & 0x000000FF); \
    total_sums += convert_int(elem) * scale * shared_y; \
    shared_y = SGB_BC(y.s5, 2); \
    elem = (char)((bits8.s5 & 0x0000FF00) >> 8); \
    total_sums += convert_int(elem) * scale * shared_y; \
    shared_y = SGB_BC(y.s6, 2); \
    elem = (char)((bits8.s5 & 0x00FF0000) >> 16); \
    total_sums += convert_int(elem) * scale * shared_y; \
    shared_y = SGB_BC(y.s7, 2); \
    elem = (char)((bits8.s5 & 0xFF000000) >> 24); \
    total_sums += convert_int(elem) * scale * shared_y; \
                                             \
    shared_y = SGB_BC(y.s0, 3); \
    elem = (char)(bits8.s6 & 0x000000FF); \
    total_sums += convert_int(elem) * scale * shared_y; \
    shared_y = SGB_BC(y.s1, 3); \
    elem = (char)((bits8.s6 & 0x0000FF00) >> 8); \
    total_sums += convert_int(elem) * scale * shared_y; \
    shared_y = SGB_BC(y.s2, 3); \
    elem = (char)((bits8.s6 & 0x00FF0000) >> 16); \
    total_sums += convert_int(elem) * scale * shared_y; \
    shared_y = SGB_BC(y.s3, 3); \
    elem = (char)((bits8.s6 & 0xFF000000) >> 24); \
    total_sums += convert_int(elem) * scale * shared_y; \
                                             \
    shared_y = SGB_BC(y.s4, 3); \
    elem = (char)(bits8.s7 & 0x000000FF); \
    total_sums += convert_int(elem) * scale * shared_y; \
    shared_y = SGB_BC(y.s5, 3); \
    elem = (char)((bits8.s7 & 0x0000FF00) >> 8); \
    total_sums += convert_int(elem) * scale * shared_y; \
    shared_y = SGB_BC(y.s6, 3); \
    elem = (char)((bits8.s7 & 0x00FF0000) >> 16); \
    total_sums += convert_int(elem) * scale * shared_y; \
    shared_y = SGB_BC(y.s7, 3); \
    elem = (char)((bits8.s7 & 0xFF000000) >> 24); \
    total_sums += convert_int(elem) * scale * shared_y; \

// ============================================================================
// Split-K variant for small-M decode GEMVs.
// ----------------------------------------------------------------------------
// The base kernel below puts one output row per lane and splits K only across
// the N_SIMDGROUP subgroups of a single workgroup, so M=512 yields M/64 = 8
// workgroups -- half the compute units on a 16-CU X2 sit idle, and the kernel
// measures ~48 GB/s against the ~122 GB/s the larger projections reach in the
// same graph. Here each (kslice, subgroup) pair reduces a disjoint set of
// K-blocks into partial[kslice * M + row]; kernel_gemv_splitk_reduce_f32 (in
// gemv_noshuffle_q4_k_f32.cl) sums the slices. Same operand order within a
// slice as the base kernel; only the cross-slice grouping differs.
//
// Placed BEFORE the base kernel deliberately: on A6X no kernel may be defined
// after one that uses a subgroup builtin, or it silently miscompiles.
// ============================================================================
REQD_SUBGROUP_SIZE_64
__kernel void kernel_gemv_noshuffle_q8_0_f32_splitk(
        __read_only  image1d_buffer_t src0_q,   // quantized A (weights)
        global half  * src0_d,                  // A scales
        __read_only  image1d_buffer_t src1,     // B (activations)
        global float * partial,                 // [ksplit * M], slice-major
        int ne00,                               // K
        int ne01)                               // M
{
    uint groupId = get_local_id(1);
    uint gid     = get_global_id(0);
    ushort slid  = get_sub_group_local_id();
    uint nsg     = get_local_size(1);
    uint ksplit  = get_num_groups(1);
    uint kslice  = get_group_id(1);

    uint K = ne00;
    uint M = ne01;

    uint LINE_STRIDE_A  = M;
    // Keep tail lanes active for subgroup ops, but read a valid weight row.
    uint gid_s = min(gid, LINE_STRIDE_A - 1);
    uint BLOCK_STRIDE_A = 8 * M;   // physical, independent of the K-split

    __private uint8  regA;
    __private half   regS;
    __private float8 regB;
    __private float  totalSum = (float)(0.0f);

    #pragma unroll 1
    for (uint k = kslice * nsg + groupId; k < (K / QK8_0); k += ksplit * nsg) {
        regS = src0_d[gid_s + k * LINE_STRIDE_A];
        if (slid < 4) {
            regB.s0123 = read_imagef(src1, (slid * 2 + k * 8));
            regB.s4567 = read_imagef(src1, (1 + slid * 2 + k * 8));
        }
        regA.s0 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 0)).x;
        regA.s1 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 1)).x;
        regA.s2 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 2)).x;
        regA.s3 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 3)).x;
        regA.s4 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 4)).x;
        regA.s5 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 5)).x;
        regA.s6 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 6)).x;
        regA.s7 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 7)).x;

        dequantizeBlockAccum_ns_sgbroadcast_1(totalSum, regA, convert_float(regS), regB);
    }

    // Intra-workgroup reduce across this K-slice's subgroups. Sized for
    // nsg <= 8; the host never dispatches more.
    __local float reduceLM[SIMDGROUP_WIDTH * 7];
    if (groupId > 0) {
        reduceLM[SIMDGROUP_WIDTH * (groupId - 1) + slid] = totalSum;
    }
    barrier(CLK_LOCAL_MEM_FENCE);
    if (groupId == 0) {
        for (uint i = 0; i < nsg - 1; ++i) {
            totalSum += reduceLM[SIMDGROUP_WIDTH * i + slid];
        }
        // x-grid is padded to CEIL_DIV(M,wave)*wave; guard the tail rows.
        if (gid < M) {
            partial[kslice * M + gid] = totalSum;
        }
    }
}

REQD_SUBGROUP_SIZE_64

// [dspark] self-B accumulation macro: lane loads its own B pixels, no
// subgroup broadcast. 32 FMAs for one q8_0 block.
#define DEQUANT_ACCUM_SELFB_1(total_sums, bits8, sc, img, kk) \
{ \
    float4 b0 = read_imagef(img, (kk * 8 + 0)); \
    float4 b1 = read_imagef(img, (kk * 8 + 1)); \
    total_sums += convert_int((char)(bits8.s0 & 0xFF)) * sc * b0.x \
              + convert_int((char)((bits8.s0 >> 8) & 0xFF)) * sc * b0.y \
              + convert_int((char)((bits8.s0 >> 16) & 0xFF)) * sc * b0.z \
              + convert_int((char)((bits8.s0 >> 24) & 0xFF)) * sc * b0.w \
              + convert_int((char)(bits8.s1 & 0xFF)) * sc * b1.x \
              + convert_int((char)((bits8.s1 >> 8) & 0xFF)) * sc * b1.y \
              + convert_int((char)((bits8.s1 >> 16) & 0xFF)) * sc * b1.z \
              + convert_int((char)((bits8.s1 >> 24) & 0xFF)) * sc * b1.w; \
    float4 b2 = read_imagef(img, (kk * 8 + 2)); \
    float4 b3 = read_imagef(img, (kk * 8 + 3)); \
    total_sums += convert_int((char)(bits8.s2 & 0xFF)) * sc * b2.x \
              + convert_int((char)((bits8.s2 >> 8) & 0xFF)) * sc * b2.y \
              + convert_int((char)((bits8.s2 >> 16) & 0xFF)) * sc * b2.z \
              + convert_int((char)((bits8.s2 >> 24) & 0xFF)) * sc * b2.w \
              + convert_int((char)(bits8.s3 & 0xFF)) * sc * b3.x \
              + convert_int((char)((bits8.s3 >> 8) & 0xFF)) * sc * b3.y \
              + convert_int((char)((bits8.s3 >> 16) & 0xFF)) * sc * b3.z \
              + convert_int((char)((bits8.s3 >> 24) & 0xFF)) * sc * b3.w; \
    float4 b4 = read_imagef(img, (kk * 8 + 4)); \
    float4 b5 = read_imagef(img, (kk * 8 + 5)); \
    total_sums += convert_int((char)(bits8.s4 & 0xFF)) * sc * b4.x \
              + convert_int((char)((bits8.s4 >> 8) & 0xFF)) * sc * b4.y \
              + convert_int((char)((bits8.s4 >> 16) & 0xFF)) * sc * b4.z \
              + convert_int((char)((bits8.s4 >> 24) & 0xFF)) * sc * b4.w \
              + convert_int((char)(bits8.s5 & 0xFF)) * sc * b5.x \
              + convert_int((char)((bits8.s5 >> 8) & 0xFF)) * sc * b5.y \
              + convert_int((char)((bits8.s5 >> 16) & 0xFF)) * sc * b5.z \
              + convert_int((char)((bits8.s5 >> 24) & 0xFF)) * sc * b5.w; \
    float4 b6 = read_imagef(img, (kk * 8 + 6)); \
    float4 b7 = read_imagef(img, (kk * 8 + 7)); \
    total_sums += convert_int((char)(bits8.s6 & 0xFF)) * sc * b6.x \
              + convert_int((char)((bits8.s6 >> 8) & 0xFF)) * sc * b6.y \
              + convert_int((char)((bits8.s6 >> 16) & 0xFF)) * sc * b6.z \
              + convert_int((char)((bits8.s6 >> 24) & 0xFF)) * sc * b6.w \
              + convert_int((char)(bits8.s7 & 0xFF)) * sc * b7.x \
              + convert_int((char)((bits8.s7 >> 8) & 0xFF)) * sc * b7.y \
              + convert_int((char)((bits8.s7 >> 16) & 0xFF)) * sc * b7.z \
              + convert_int((char)((bits8.s7 >> 24) & 0xFF)) * sc * b7.w; \
}

__kernel void kernel_gemv_noshuffle_q8_0_f32(
        __read_only  image1d_buffer_t src0_q,  // quantized A
        global half  * src0_d,  // A scales
        __read_only  image1d_buffer_t src1,    // B
        ulong offset1,            // offset to B (0)
        global float * dst,     // C
        ulong offsetd,            // offset to C
        int ne00,               // K
        int ne01,               // M
        int ne02,               // 1
        int ne10,               // K
        int ne12,               // 1
        int ne0,                // M
        int ne1,                // N
        int r2,                 // 1
        int r3)
{
    uint groupId = get_local_id(1);
    uint gid     = get_global_id(0);
    ushort slid    = get_sub_group_local_id();

    uint K = ne00;
    uint M = ne01;

    uint LINE_STRIDE_A = M;
    // Keep tail lanes active for subgroup ops, but read a valid weight row.
    uint gid_s = min(gid, LINE_STRIDE_A - 1);
    uint BLOCK_STRIDE_A = 8 * M;   // 32 / 4 = 8

    // [dspark 2026-10-19] staged diagnostics (ne12 repurposed as stage selector
    // via GGML_OPENCL_Q8_DBG_STAGE on the host):
    //   1: launch/dst addressing only (expect dst[gid] = gid + 0.5)
    //   2: reduceLM protocol with constant 1.0 (expect dst[gid] = 4.0)
    //   3: b_img pixel 0 read
    //   4: q_img pixel gid read (expect dst[gid] = first q byte of row gid)
    //   5: d scale read for k=0 (expect dst[gid] = scale(row gid, block 0))
    __local float dbg_lm[SIMDGROUP_WIDTH * 3];
    int dbg_stage = -ne12; /* real calls: ne12>=1 */
    if (dbg_stage >= 1 && dbg_stage <= 8) {
        dst = (global float*)((global char*)dst + offsetd);
        if (gid >= M) return;
        if (dbg_stage == 8) {
            // compile-time branch discriminator: 1 = ADRENO path compiled,
            // 0 = rusticl-safe v2 path compiled; +10 = VECTOR_SUB_GROUP_BROADCAST
#if defined(ADRENO_GPU)
            dst[gid] = 1.0f;
#else
            dst[gid] = 0.0f;
#endif
#ifdef VECTOR_SUB_GROUP_BROADCAST
            dst[gid] += 10.0f;
#endif
            return;
        }
        if (dbg_stage == 1) { dst[gid] = (float)gid + 0.5f; return; }
        if (dbg_stage == 2) {
            float t = 1.0f;
            if (groupId == 1) dbg_lm[SIMDGROUP_WIDTH * 0 + slid] = t;
            if (groupId == 2) dbg_lm[SIMDGROUP_WIDTH * 1 + slid] = t;
            if (groupId == 3) dbg_lm[SIMDGROUP_WIDTH * 2 + slid] = t;
            barrier(CLK_LOCAL_MEM_FENCE);
            if (groupId == 0) {
                t += dbg_lm[SIMDGROUP_WIDTH * 0 + slid];
                t += dbg_lm[SIMDGROUP_WIDTH * 1 + slid];
                t += dbg_lm[SIMDGROUP_WIDTH * 2 + slid];
            }
            if (groupId == 0) dst[gid] = t;
            return;
        }
        if (dbg_stage == 3) {
            float t = 0.0f;
            if (slid < 4) {
                float4 v = read_imagef(src1, (slid * 2 + 0));
                t = v.x + v.y + v.z + v.w;
            }
            t = SGB_BC(t, slid % 4);
            if (groupId == 0) dst[gid] = t;
            return;
        }
        if (dbg_stage == 4) {
            uint t = read_imageui(src0_q, (gid_s + 0 * (8 * M) + LINE_STRIDE_A * 0)).x;
            if (groupId == 0) dst[gid] = (float)(t & 0xFF);
            return;
        }
        if (dbg_stage == 7) {
            float t = 0.0f;
            uint8 rA;
            #pragma unroll 1
            for (uint k = 0; k < (K / QK8_0); k++) {
                half rS = src0_d[gid_s + k * LINE_STRIDE_A];
                rA.s0 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 0)).x;
                rA.s1 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 1)).x;
                rA.s2 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 2)).x;
                rA.s3 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 3)).x;
                rA.s4 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 4)).x;
                rA.s5 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 5)).x;
                rA.s6 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 6)).x;
                rA.s7 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 7)).x;
                DEQUANT_ACCUM_SELFB_1(t, rA, convert_float(rS), src1, k);
            }
            if (groupId == 0 && gid < M) dst[gid] = t;
            return;
        }
        if (dbg_stage == 6) {
            if (groupId == 0) dst[gid] = (float)get_sub_group_size();
            return;
        }
        if (dbg_stage == 5) {
            float s = (float)(src0_d[gid_s + 0 * LINE_STRIDE_A]);
            if (groupId == 0) dst[gid] = s;
            return;
        }
    }

    __private uint8     regA;
    __private half      regS;

    __private float totalSum = (float)(0.0f);

#if defined(ADRENO_GPU)
    // Proprietary qcom stack: subgroup size is pinned to 64 by the qcom
    // attribute, so the broadcast + slid-indexed protocol is safe there.
    __private float8    regB;

    // loop along K in block granularity, skip 4 blocks every iter
    #pragma unroll 1 /* tell compiler not to unroll */
    for (uint k = groupId; k < (K / QK8_0); k += N_SIMDGROUP) {
        regS = src0_d[gid_s + k * LINE_STRIDE_A]; // each fiber loads the scale of one row
        // first 4 fibers in each wave load 8 B values to its private scope
        if (slid < 4) {
            regB.s0123 = read_imagef(src1, (slid * 2 + k * 8));
            regB.s4567 = read_imagef(src1, (1 + slid * 2 + k * 8));
        }

        // load weights for one block in consecutive rows
        regA.s0 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 0)).x;
        regA.s1 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 1)).x;
        regA.s2 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 2)).x;
        regA.s3 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 3)).x;
        regA.s4 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 4)).x;
        regA.s5 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 5)).x;
        regA.s6 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 6)).x;
        regA.s7 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 7)).x;

        dequantizeBlockAccum_ns_sgbroadcast_1(totalSum, regA, convert_float(regS), regB);
    }
#else
    // [dspark 2026-10-19] rusticl-safe variant v2. Measured on FD650
    // rusticl+kgsl: the compiler hands this kernel a 128-wide subgroup that
    // SPANS local y-groups, and with that layout neither subgroup broadcast
    // (lanes of groupId 1 receive groupId 0's B for a different k) nor the
    // work-group barrier + local-memory reduce (partial sums never become
    // visible across y-groups) works -- stage-isolated probes showed a pure
    // full-K loop with zero cross-thread communication computes bit-exact
    // results (corr 1-1e-15 vs python) while any y-group reduce corrupts.
    // So: one lane owns an output row end-to-end. No barrier, no local mem,
    // no subgroup ops. 4x redundant B reads, but B is a few KB and cached.
    #pragma unroll 1
    for (uint k = 0; k < (K / QK8_0); k++) {
        regS = src0_d[gid_s + k * LINE_STRIDE_A];

        regA.s0 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 0)).x;
        regA.s1 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 1)).x;
        regA.s2 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 2)).x;
        regA.s3 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 3)).x;
        regA.s4 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 4)).x;
        regA.s5 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 5)).x;
        regA.s6 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 6)).x;
        regA.s7 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 7)).x;

        DEQUANT_ACCUM_SELFB_1(totalSum, regA, convert_float(regS), src1, k);
    }

    // single-lane totals: write directly, no reduce
    if (gid < M) {
        dst = (global float*)((global char*)dst + offsetd);
        dst[gid] = totalSum;
    }
    return;
#endif

#if defined(ADRENO_GPU)
    // reduction in local memory, assumes #wave=4 (qcom stack pins sgs=64)
    __local float reduceLM[SIMDGROUP_WIDTH * 3];
    const uint lid_x = (uint)get_local_id(0);
    if (groupId == 1) reduceLM[SIMDGROUP_WIDTH * 0 + lid_x] = totalSum;
    if (groupId == 2) reduceLM[SIMDGROUP_WIDTH * 1 + lid_x] = totalSum;
    if (groupId == 3) reduceLM[SIMDGROUP_WIDTH * 2 + lid_x] = totalSum;
    barrier(CLK_LOCAL_MEM_FENCE);
    if (groupId == 0) totalSum += reduceLM[SIMDGROUP_WIDTH * 0 + lid_x];
    if (groupId == 0) totalSum += reduceLM[SIMDGROUP_WIDTH * 1 + lid_x];
    if (groupId == 0) totalSum += reduceLM[SIMDGROUP_WIDTH * 2 + lid_x];

    // 1 outputs per fiber in wave 0
    if (groupId == 0) {
        dst = (global float*)((global char*)dst + offsetd);
        // Guard the output row. The x-grid is padded to CEIL_DIV(M,wavesize)*wavesize,
        // so when ne01 is not a multiple of the wave size the tail work-items run past
        // row ne01 and would overrun dst into the adjacent tensor. No-op / byte-identical
        // when ne01 is wave-aligned (no padding).
        if (gid < M) dst[gid] = totalSum;
    }
#endif // ADRENO_GPU
}
