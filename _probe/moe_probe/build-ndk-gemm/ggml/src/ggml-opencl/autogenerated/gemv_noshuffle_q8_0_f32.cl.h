R"(#pragma OPENCL EXTENSION cl_khr_fp16 : enable
)"
R"(#pragma OPENCL EXTENSION cl_khr_subgroups : enable
)"
R"(
)"
R"(// [dspark 2026-10-14] Scalar-float subgroup broadcast. 740's online compiler
)"
R"(// lacks float overloads of sub_group_broadcast entirely -> host passes
)"
R"(// -DSGB_SCALAR_BROKEN and broadcasts go through the uint-bitcast shim.
)"
R"(// 830 (E031.47) has working float broadcast but miscompiles kernels whose
)"
R"(// broadcasts go through an inline wrapper, even in pass-through form
)"
R"(// (NMSE~2.2, 2026-10-14) -> uses the direct builtin. All call sites are
)"
R"(// per-component scalar: no vector broadcast anywhere.
)"
R"(#ifdef SGB_SCALAR_BROKEN
)"
R"(inline float sgb_f(float v, uint lid) {
)"
R"(    return as_float(sub_group_broadcast(as_uint(v), lid));
)"
R"(}
)"
R"(#define SGB_BC(v, lid) sgb_f(v, lid)
)"
R"(#else
)"
R"(#define SGB_BC(v, lid) sub_group_broadcast(v, lid)
)"
R"(#endif
)"
R"(
)"
R"(#ifdef cl_qcom_reqd_sub_group_size
)"
R"(#pragma OPENCL EXTENSION cl_qcom_reqd_sub_group_size : enable
)"
R"(#define ADRENO_GPU 1
)"
R"(#define REQD_SUBGROUP_SIZE_64 __attribute__((qcom_reqd_sub_group_size("half")))
)"
R"(#else
)"
R"(// [dspark 2026-10-19] rusticl (FD650/FD740) picks its native subgroup size
)"
R"(// (measured 128) unless pinned. The GEMV protocol below is written for 64:
)"
R"(// lanes slid<4 load B and broadcast to the subgroup, and the local-memory
)"
R"(// reduce indexes SIMDGROUP_WIDTH(=64) slots per y-group. With sgs=128 the
)"
R"(// broadcast crosses y-groups (wrong B per k) and the reduce writes past the
)"
R"(// 192-slot array (OOB) -> garbage/NaN outputs for any multi-workgroup M.
)"
R"(// intel_reqd_sub_group_size is honored by rusticl; unknown on the qcom
)"
R"(// proprietary compiler, where the qcom attribute above applies instead.
)"
R"(#define REQD_SUBGROUP_SIZE_64 __attribute__((intel_reqd_sub_group_size(64)))
)"
R"(#endif
)"
R"(
)"
R"(// the driver's online compiler lacks float overloads of sub_group_broadcast
)"
R"(// (Adreno 740: only scalar uint/int/long/ulong exist). Bitcast float<->uint,
)"
R"(// broadcast as integer, cast back — bitwise identical, subgroup-uniform.
)"
R"(#define QK8_0 32
)"
R"(#define N_SIMDGROUP 4
)"
R"(
)"
R"(#define dequantizeBlockAccum_ns_sgbroadcast_1(total_sums, bits8, scale, y) \
)"
R"(    float shared_y; \
)"
R"(    char elem; \
)"
R"(                                             \
)"
R"(    shared_y = SGB_BC(y.s0, 0); \
)"
R"(    elem = (char)(bits8.s0 & 0x000000FF); \
)"
R"(    total_sums += convert_int(elem) * scale * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s1, 0); \
)"
R"(    elem = (char)((bits8.s0 & 0x0000FF00) >> 8); \
)"
R"(    total_sums += convert_int(elem) * scale * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s2, 0); \
)"
R"(    elem = (char)((bits8.s0 & 0x00FF0000) >> 16); \
)"
R"(    total_sums += convert_int(elem) * scale * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s3, 0); \
)"
R"(    elem = (char)((bits8.s0 & 0xFF000000) >> 24); \
)"
R"(    total_sums += convert_int(elem) * scale * shared_y; \
)"
R"(                                             \
)"
R"(    shared_y = SGB_BC(y.s4, 0); \
)"
R"(    elem = (char)(bits8.s1 & 0x000000FF); \
)"
R"(    total_sums += convert_int(elem) * scale * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s5, 0); \
)"
R"(    elem = (char)((bits8.s1 & 0x0000FF00) >> 8); \
)"
R"(    total_sums += convert_int(elem) * scale * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s6, 0); \
)"
R"(    elem = (char)((bits8.s1 & 0x00FF0000) >> 16); \
)"
R"(    total_sums += convert_int(elem) * scale * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s7, 0); \
)"
R"(    elem = (char)((bits8.s1 & 0xFF000000) >> 24); \
)"
R"(    total_sums += convert_int(elem) * scale * shared_y; \
)"
R"(                                             \
)"
R"(    shared_y = SGB_BC(y.s0, 1); \
)"
R"(    elem = (char)(bits8.s2 & 0x000000FF); \
)"
R"(    total_sums += convert_int(elem) * scale * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s1, 1); \
)"
R"(    elem = (char)((bits8.s2 & 0x0000FF00) >> 8); \
)"
R"(    total_sums += convert_int(elem) * scale * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s2, 1); \
)"
R"(    elem = (char)((bits8.s2 & 0x00FF0000) >> 16); \
)"
R"(    total_sums += convert_int(elem) * scale * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s3, 1); \
)"
R"(    elem = (char)((bits8.s2 & 0xFF000000) >> 24); \
)"
R"(    total_sums += convert_int(elem) * scale * shared_y; \
)"
R"(                                             \
)"
R"(    shared_y = SGB_BC(y.s4, 1); \
)"
R"(    elem = (char)(bits8.s3 & 0x000000FF); \
)"
R"(    total_sums += convert_int(elem) * scale * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s5, 1); \
)"
R"(    elem = (char)((bits8.s3 & 0x0000FF00) >> 8); \
)"
R"(    total_sums += convert_int(elem) * scale * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s6, 1); \
)"
R"(    elem = (char)((bits8.s3 & 0x00FF0000) >> 16); \
)"
R"(    total_sums += convert_int(elem) * scale * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s7, 1); \
)"
R"(    elem = (char)((bits8.s3 & 0xFF000000) >> 24); \
)"
R"(    total_sums += convert_int(elem) * scale * shared_y; \
)"
R"(                                             \
)"
R"(    shared_y = SGB_BC(y.s0, 2); \
)"
R"(    elem = (char)(bits8.s4 & 0x000000FF); \
)"
R"(    total_sums += convert_int(elem) * scale * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s1, 2); \
)"
R"(    elem = (char)((bits8.s4 & 0x0000FF00) >> 8); \
)"
R"(    total_sums += convert_int(elem) * scale * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s2, 2); \
)"
R"(    elem = (char)((bits8.s4 & 0x00FF0000) >> 16); \
)"
R"(    total_sums += convert_int(elem) * scale * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s3, 2); \
)"
R"(    elem = (char)((bits8.s4 & 0xFF000000) >> 24); \
)"
R"(    total_sums += convert_int(elem) * scale * shared_y; \
)"
R"(                                             \
)"
R"(    shared_y = SGB_BC(y.s4, 2); \
)"
R"(    elem = (char)(bits8.s5 & 0x000000FF); \
)"
R"(    total_sums += convert_int(elem) * scale * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s5, 2); \
)"
R"(    elem = (char)((bits8.s5 & 0x0000FF00) >> 8); \
)"
R"(    total_sums += convert_int(elem) * scale * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s6, 2); \
)"
R"(    elem = (char)((bits8.s5 & 0x00FF0000) >> 16); \
)"
R"(    total_sums += convert_int(elem) * scale * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s7, 2); \
)"
R"(    elem = (char)((bits8.s5 & 0xFF000000) >> 24); \
)"
R"(    total_sums += convert_int(elem) * scale * shared_y; \
)"
R"(                                             \
)"
R"(    shared_y = SGB_BC(y.s0, 3); \
)"
R"(    elem = (char)(bits8.s6 & 0x000000FF); \
)"
R"(    total_sums += convert_int(elem) * scale * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s1, 3); \
)"
R"(    elem = (char)((bits8.s6 & 0x0000FF00) >> 8); \
)"
R"(    total_sums += convert_int(elem) * scale * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s2, 3); \
)"
R"(    elem = (char)((bits8.s6 & 0x00FF0000) >> 16); \
)"
R"(    total_sums += convert_int(elem) * scale * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s3, 3); \
)"
R"(    elem = (char)((bits8.s6 & 0xFF000000) >> 24); \
)"
R"(    total_sums += convert_int(elem) * scale * shared_y; \
)"
R"(                                             \
)"
R"(    shared_y = SGB_BC(y.s4, 3); \
)"
R"(    elem = (char)(bits8.s7 & 0x000000FF); \
)"
R"(    total_sums += convert_int(elem) * scale * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s5, 3); \
)"
R"(    elem = (char)((bits8.s7 & 0x0000FF00) >> 8); \
)"
R"(    total_sums += convert_int(elem) * scale * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s6, 3); \
)"
R"(    elem = (char)((bits8.s7 & 0x00FF0000) >> 16); \
)"
R"(    total_sums += convert_int(elem) * scale * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s7, 3); \
)"
R"(    elem = (char)((bits8.s7 & 0xFF000000) >> 24); \
)"
R"(    total_sums += convert_int(elem) * scale * shared_y; \
)"
R"(
)"
R"(// ============================================================================
)"
R"(// Split-K variant for small-M decode GEMVs.
)"
R"(// ----------------------------------------------------------------------------
)"
R"(// The base kernel below puts one output row per lane and splits K only across
)"
R"(// the N_SIMDGROUP subgroups of a single workgroup, so M=512 yields M/64 = 8
)"
R"(// workgroups -- half the compute units on a 16-CU X2 sit idle, and the kernel
)"
R"(// measures ~48 GB/s against the ~122 GB/s the larger projections reach in the
)"
R"(// same graph. Here each (kslice, subgroup) pair reduces a disjoint set of
)"
R"(// K-blocks into partial[kslice * M + row]; kernel_gemv_splitk_reduce_f32 (in
)"
R"(// gemv_noshuffle_q4_k_f32.cl) sums the slices. Same operand order within a
)"
R"(// slice as the base kernel; only the cross-slice grouping differs.
)"
R"(//
)"
R"(// Placed BEFORE the base kernel deliberately: on A6X no kernel may be defined
)"
R"(// after one that uses a subgroup builtin, or it silently miscompiles.
)"
R"(// ============================================================================
)"
R"(REQD_SUBGROUP_SIZE_64
)"
R"(__kernel void kernel_gemv_noshuffle_q8_0_f32_splitk(
)"
R"(        __read_only  image1d_buffer_t src0_q,   // quantized A (weights)
)"
R"(        global half  * src0_d,                  // A scales
)"
R"(        __read_only  image1d_buffer_t src1,     // B (activations)
)"
R"(        global float * partial,                 // [ksplit * M], slice-major
)"
R"(        int ne00,                               // K
)"
R"(        int ne01)                               // M
)"
R"({
)"
R"(    uint groupId = get_local_id(1);
)"
R"(    uint gid     = get_global_id(0);
)"
R"(    ushort slid  = get_sub_group_local_id();
)"
R"(    uint nsg     = get_local_size(1);
)"
R"(    uint ksplit  = get_num_groups(1);
)"
R"(    uint kslice  = get_group_id(1);
)"
R"(
)"
R"(    uint K = ne00;
)"
R"(    uint M = ne01;
)"
R"(
)"
R"(    uint LINE_STRIDE_A  = M;
)"
R"(    // Keep tail lanes active for subgroup ops, but read a valid weight row.
)"
R"(    uint gid_s = min(gid, LINE_STRIDE_A - 1);
)"
R"(    uint BLOCK_STRIDE_A = 8 * M;   // physical, independent of the K-split
)"
R"(
)"
R"(    __private uint8  regA;
)"
R"(    __private half   regS;
)"
R"(    __private float8 regB;
)"
R"(    __private float  totalSum = (float)(0.0f);
)"
R"(
)"
R"(    #pragma unroll 1
)"
R"(    for (uint k = kslice * nsg + groupId; k < (K / QK8_0); k += ksplit * nsg) {
)"
R"(        regS = src0_d[gid_s + k * LINE_STRIDE_A];
)"
R"(        if (slid < 4) {
)"
R"(            regB.s0123 = read_imagef(src1, (slid * 2 + k * 8));
)"
R"(            regB.s4567 = read_imagef(src1, (1 + slid * 2 + k * 8));
)"
R"(        }
)"
R"(        regA.s0 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 0)).x;
)"
R"(        regA.s1 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 1)).x;
)"
R"(        regA.s2 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 2)).x;
)"
R"(        regA.s3 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 3)).x;
)"
R"(        regA.s4 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 4)).x;
)"
R"(        regA.s5 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 5)).x;
)"
R"(        regA.s6 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 6)).x;
)"
R"(        regA.s7 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 7)).x;
)"
R"(
)"
R"(        dequantizeBlockAccum_ns_sgbroadcast_1(totalSum, regA, convert_float(regS), regB);
)"
R"(    }
)"
R"(
)"
R"(    // Intra-workgroup reduce across this K-slice's subgroups. Sized for
)"
R"(    // nsg <= 8; the host never dispatches more.
)"
R"(    __local float reduceLM[SIMDGROUP_WIDTH * 7];
)"
R"(    if (groupId > 0) {
)"
R"(        reduceLM[SIMDGROUP_WIDTH * (groupId - 1) + slid] = totalSum;
)"
R"(    }
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(    if (groupId == 0) {
)"
R"(        for (uint i = 0; i < nsg - 1; ++i) {
)"
R"(            totalSum += reduceLM[SIMDGROUP_WIDTH * i + slid];
)"
R"(        }
)"
R"(        // x-grid is padded to CEIL_DIV(M,wave)*wave; guard the tail rows.
)"
R"(        if (gid < M) {
)"
R"(            partial[kslice * M + gid] = totalSum;
)"
R"(        }
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(REQD_SUBGROUP_SIZE_64
)"
R"(
)"
R"(// [dspark] self-B accumulation macro: lane loads its own B pixels, no
)"
R"(// subgroup broadcast. 32 FMAs for one q8_0 block.
)"
R"(#define DEQUANT_ACCUM_SELFB_1(total_sums, bits8, sc, img, kk) \
)"
R"({ \
)"
R"(    float4 b0 = read_imagef(img, (kk * 8 + 0)); \
)"
R"(    float4 b1 = read_imagef(img, (kk * 8 + 1)); \
)"
R"(    total_sums += convert_int((char)(bits8.s0 & 0xFF)) * sc * b0.x \
)"
R"(              + convert_int((char)((bits8.s0 >> 8) & 0xFF)) * sc * b0.y \
)"
R"(              + convert_int((char)((bits8.s0 >> 16) & 0xFF)) * sc * b0.z \
)"
R"(              + convert_int((char)((bits8.s0 >> 24) & 0xFF)) * sc * b0.w \
)"
R"(              + convert_int((char)(bits8.s1 & 0xFF)) * sc * b1.x \
)"
R"(              + convert_int((char)((bits8.s1 >> 8) & 0xFF)) * sc * b1.y \
)"
R"(              + convert_int((char)((bits8.s1 >> 16) & 0xFF)) * sc * b1.z \
)"
R"(              + convert_int((char)((bits8.s1 >> 24) & 0xFF)) * sc * b1.w; \
)"
R"(    float4 b2 = read_imagef(img, (kk * 8 + 2)); \
)"
R"(    float4 b3 = read_imagef(img, (kk * 8 + 3)); \
)"
R"(    total_sums += convert_int((char)(bits8.s2 & 0xFF)) * sc * b2.x \
)"
R"(              + convert_int((char)((bits8.s2 >> 8) & 0xFF)) * sc * b2.y \
)"
R"(              + convert_int((char)((bits8.s2 >> 16) & 0xFF)) * sc * b2.z \
)"
R"(              + convert_int((char)((bits8.s2 >> 24) & 0xFF)) * sc * b2.w \
)"
R"(              + convert_int((char)(bits8.s3 & 0xFF)) * sc * b3.x \
)"
R"(              + convert_int((char)((bits8.s3 >> 8) & 0xFF)) * sc * b3.y \
)"
R"(              + convert_int((char)((bits8.s3 >> 16) & 0xFF)) * sc * b3.z \
)"
R"(              + convert_int((char)((bits8.s3 >> 24) & 0xFF)) * sc * b3.w; \
)"
R"(    float4 b4 = read_imagef(img, (kk * 8 + 4)); \
)"
R"(    float4 b5 = read_imagef(img, (kk * 8 + 5)); \
)"
R"(    total_sums += convert_int((char)(bits8.s4 & 0xFF)) * sc * b4.x \
)"
R"(              + convert_int((char)((bits8.s4 >> 8) & 0xFF)) * sc * b4.y \
)"
R"(              + convert_int((char)((bits8.s4 >> 16) & 0xFF)) * sc * b4.z \
)"
R"(              + convert_int((char)((bits8.s4 >> 24) & 0xFF)) * sc * b4.w \
)"
R"(              + convert_int((char)(bits8.s5 & 0xFF)) * sc * b5.x \
)"
R"(              + convert_int((char)((bits8.s5 >> 8) & 0xFF)) * sc * b5.y \
)"
R"(              + convert_int((char)((bits8.s5 >> 16) & 0xFF)) * sc * b5.z \
)"
R"(              + convert_int((char)((bits8.s5 >> 24) & 0xFF)) * sc * b5.w; \
)"
R"(    float4 b6 = read_imagef(img, (kk * 8 + 6)); \
)"
R"(    float4 b7 = read_imagef(img, (kk * 8 + 7)); \
)"
R"(    total_sums += convert_int((char)(bits8.s6 & 0xFF)) * sc * b6.x \
)"
R"(              + convert_int((char)((bits8.s6 >> 8) & 0xFF)) * sc * b6.y \
)"
R"(              + convert_int((char)((bits8.s6 >> 16) & 0xFF)) * sc * b6.z \
)"
R"(              + convert_int((char)((bits8.s6 >> 24) & 0xFF)) * sc * b6.w \
)"
R"(              + convert_int((char)(bits8.s7 & 0xFF)) * sc * b7.x \
)"
R"(              + convert_int((char)((bits8.s7 >> 8) & 0xFF)) * sc * b7.y \
)"
R"(              + convert_int((char)((bits8.s7 >> 16) & 0xFF)) * sc * b7.z \
)"
R"(              + convert_int((char)((bits8.s7 >> 24) & 0xFF)) * sc * b7.w; \
)"
R"(}
)"
R"(
)"
R"(__kernel void kernel_gemv_noshuffle_q8_0_f32(
)"
R"(        __read_only  image1d_buffer_t src0_q,  // quantized A
)"
R"(        global half  * src0_d,  // A scales
)"
R"(        __read_only  image1d_buffer_t src1,    // B
)"
R"(        ulong offset1,            // offset to B (0)
)"
R"(        global float * dst,     // C
)"
R"(        ulong offsetd,            // offset to C
)"
R"(        int ne00,               // K
)"
R"(        int ne01,               // M
)"
R"(        int ne02,               // 1
)"
R"(        int ne10,               // K
)"
R"(        int ne12,               // 1
)"
R"(        int ne0,                // M
)"
R"(        int ne1,                // N
)"
R"(        int r2,                 // 1
)"
R"(        int r3)
)"
R"({
)"
R"(    uint groupId = get_local_id(1);
)"
R"(    uint gid     = get_global_id(0);
)"
R"(    ushort slid    = get_sub_group_local_id();
)"
R"(
)"
R"(    uint K = ne00;
)"
R"(    uint M = ne01;
)"
R"(
)"
R"(    uint LINE_STRIDE_A = M;
)"
R"(    // Keep tail lanes active for subgroup ops, but read a valid weight row.
)"
R"(    uint gid_s = min(gid, LINE_STRIDE_A - 1);
)"
R"(    uint BLOCK_STRIDE_A = 8 * M;   // 32 / 4 = 8
)"
R"(
)"
R"(    // [dspark 2026-10-19] staged diagnostics (ne12 repurposed as stage selector
)"
R"(    // via GGML_OPENCL_Q8_DBG_STAGE on the host):
)"
R"(    //   1: launch/dst addressing only (expect dst[gid] = gid + 0.5)
)"
R"(    //   2: reduceLM protocol with constant 1.0 (expect dst[gid] = 4.0)
)"
R"(    //   3: b_img pixel 0 read
)"
R"(    //   4: q_img pixel gid read (expect dst[gid] = first q byte of row gid)
)"
R"(    //   5: d scale read for k=0 (expect dst[gid] = scale(row gid, block 0))
)"
R"(    __local float dbg_lm[SIMDGROUP_WIDTH * 3];
)"
R"(    int dbg_stage = -ne12; /* real calls: ne12>=1 */
)"
R"(    if (dbg_stage >= 1 && dbg_stage <= 8) {
)"
R"(        dst = (global float*)((global char*)dst + offsetd);
)"
R"(        if (gid >= M) return;
)"
R"(        if (dbg_stage == 8) {
)"
R"(            // compile-time branch discriminator: 1 = ADRENO path compiled,
)"
R"(            // 0 = rusticl-safe v2 path compiled; +10 = VECTOR_SUB_GROUP_BROADCAST
)"
R"(#if defined(ADRENO_GPU)
)"
R"(            dst[gid] = 1.0f;
)"
R"(#else
)"
R"(            dst[gid] = 0.0f;
)"
R"(#endif
)"
R"(#ifdef VECTOR_SUB_GROUP_BROADCAST
)"
R"(            dst[gid] += 10.0f;
)"
R"(#endif
)"
R"(            return;
)"
R"(        }
)"
R"(        if (dbg_stage == 1) { dst[gid] = (float)gid + 0.5f; return; }
)"
R"(        if (dbg_stage == 2) {
)"
R"(            float t = 1.0f;
)"
R"(            if (groupId == 1) dbg_lm[SIMDGROUP_WIDTH * 0 + slid] = t;
)"
R"(            if (groupId == 2) dbg_lm[SIMDGROUP_WIDTH * 1 + slid] = t;
)"
R"(            if (groupId == 3) dbg_lm[SIMDGROUP_WIDTH * 2 + slid] = t;
)"
R"(            barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(            if (groupId == 0) {
)"
R"(                t += dbg_lm[SIMDGROUP_WIDTH * 0 + slid];
)"
R"(                t += dbg_lm[SIMDGROUP_WIDTH * 1 + slid];
)"
R"(                t += dbg_lm[SIMDGROUP_WIDTH * 2 + slid];
)"
R"(            }
)"
R"(            if (groupId == 0) dst[gid] = t;
)"
R"(            return;
)"
R"(        }
)"
R"(        if (dbg_stage == 3) {
)"
R"(            float t = 0.0f;
)"
R"(            if (slid < 4) {
)"
R"(                float4 v = read_imagef(src1, (slid * 2 + 0));
)"
R"(                t = v.x + v.y + v.z + v.w;
)"
R"(            }
)"
R"(            t = SGB_BC(t, slid % 4);
)"
R"(            if (groupId == 0) dst[gid] = t;
)"
R"(            return;
)"
R"(        }
)"
R"(        if (dbg_stage == 4) {
)"
R"(            uint t = read_imageui(src0_q, (gid_s + 0 * (8 * M) + LINE_STRIDE_A * 0)).x;
)"
R"(            if (groupId == 0) dst[gid] = (float)(t & 0xFF);
)"
R"(            return;
)"
R"(        }
)"
R"(        if (dbg_stage == 7) {
)"
R"(            float t = 0.0f;
)"
R"(            uint8 rA;
)"
R"(            #pragma unroll 1
)"
R"(            for (uint k = 0; k < (K / QK8_0); k++) {
)"
R"(                half rS = src0_d[gid_s + k * LINE_STRIDE_A];
)"
R"(                rA.s0 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 0)).x;
)"
R"(                rA.s1 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 1)).x;
)"
R"(                rA.s2 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 2)).x;
)"
R"(                rA.s3 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 3)).x;
)"
R"(                rA.s4 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 4)).x;
)"
R"(                rA.s5 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 5)).x;
)"
R"(                rA.s6 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 6)).x;
)"
R"(                rA.s7 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 7)).x;
)"
R"(                DEQUANT_ACCUM_SELFB_1(t, rA, convert_float(rS), src1, k);
)"
R"(            }
)"
R"(            if (groupId == 0 && gid < M) dst[gid] = t;
)"
R"(            return;
)"
R"(        }
)"
R"(        if (dbg_stage == 6) {
)"
R"(            if (groupId == 0) dst[gid] = (float)get_sub_group_size();
)"
R"(            return;
)"
R"(        }
)"
R"(        if (dbg_stage == 5) {
)"
R"(            float s = (float)(src0_d[gid_s + 0 * LINE_STRIDE_A]);
)"
R"(            if (groupId == 0) dst[gid] = s;
)"
R"(            return;
)"
R"(        }
)"
R"(    }
)"
R"(
)"
R"(    __private uint8     regA;
)"
R"(    __private half      regS;
)"
R"(
)"
R"(    __private float totalSum = (float)(0.0f);
)"
R"(
)"
R"(#if defined(ADRENO_GPU)
)"
R"(    // Proprietary qcom stack: subgroup size is pinned to 64 by the qcom
)"
R"(    // attribute, so the broadcast + slid-indexed protocol is safe there.
)"
R"(    __private float8    regB;
)"
R"(
)"
R"(    // loop along K in block granularity, skip 4 blocks every iter
)"
R"(    #pragma unroll 1 /* tell compiler not to unroll */
)"
R"(    for (uint k = groupId; k < (K / QK8_0); k += N_SIMDGROUP) {
)"
R"(        regS = src0_d[gid_s + k * LINE_STRIDE_A]; // each fiber loads the scale of one row
)"
R"(        // first 4 fibers in each wave load 8 B values to its private scope
)"
R"(        if (slid < 4) {
)"
R"(            regB.s0123 = read_imagef(src1, (slid * 2 + k * 8));
)"
R"(            regB.s4567 = read_imagef(src1, (1 + slid * 2 + k * 8));
)"
R"(        }
)"
R"(
)"
R"(        // load weights for one block in consecutive rows
)"
R"(        regA.s0 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 0)).x;
)"
R"(        regA.s1 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 1)).x;
)"
R"(        regA.s2 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 2)).x;
)"
R"(        regA.s3 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 3)).x;
)"
R"(        regA.s4 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 4)).x;
)"
R"(        regA.s5 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 5)).x;
)"
R"(        regA.s6 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 6)).x;
)"
R"(        regA.s7 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 7)).x;
)"
R"(
)"
R"(        dequantizeBlockAccum_ns_sgbroadcast_1(totalSum, regA, convert_float(regS), regB);
)"
R"(    }
)"
R"(#else
)"
R"(    // [dspark 2026-10-19] rusticl-safe variant v2. Measured on FD650
)"
R"(    // rusticl+kgsl: the compiler hands this kernel a 128-wide subgroup that
)"
R"(    // SPANS local y-groups, and with that layout neither subgroup broadcast
)"
R"(    // (lanes of groupId 1 receive groupId 0's B for a different k) nor the
)"
R"(    // work-group barrier + local-memory reduce (partial sums never become
)"
R"(    // visible across y-groups) works -- stage-isolated probes showed a pure
)"
R"(    // full-K loop with zero cross-thread communication computes bit-exact
)"
R"(    // results (corr 1-1e-15 vs python) while any y-group reduce corrupts.
)"
R"(    // So: one lane owns an output row end-to-end. No barrier, no local mem,
)"
R"(    // no subgroup ops. 4x redundant B reads, but B is a few KB and cached.
)"
R"(    #pragma unroll 1
)"
R"(    for (uint k = 0; k < (K / QK8_0); k++) {
)"
R"(        regS = src0_d[gid_s + k * LINE_STRIDE_A];
)"
R"(
)"
R"(        regA.s0 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 0)).x;
)"
R"(        regA.s1 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 1)).x;
)"
R"(        regA.s2 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 2)).x;
)"
R"(        regA.s3 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 3)).x;
)"
R"(        regA.s4 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 4)).x;
)"
R"(        regA.s5 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 5)).x;
)"
R"(        regA.s6 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 6)).x;
)"
R"(        regA.s7 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 7)).x;
)"
R"(
)"
R"(        DEQUANT_ACCUM_SELFB_1(totalSum, regA, convert_float(regS), src1, k);
)"
R"(    }
)"
R"(
)"
R"(    // single-lane totals: write directly, no reduce
)"
R"(    if (gid < M) {
)"
R"(        dst = (global float*)((global char*)dst + offsetd);
)"
R"(        dst[gid] = totalSum;
)"
R"(    }
)"
R"(    return;
)"
R"(#endif
)"
R"(
)"
R"(#if defined(ADRENO_GPU)
)"
R"(    // reduction in local memory, assumes #wave=4 (qcom stack pins sgs=64)
)"
R"(    __local float reduceLM[SIMDGROUP_WIDTH * 3];
)"
R"(    const uint lid_x = (uint)get_local_id(0);
)"
R"(    if (groupId == 1) reduceLM[SIMDGROUP_WIDTH * 0 + lid_x] = totalSum;
)"
R"(    if (groupId == 2) reduceLM[SIMDGROUP_WIDTH * 1 + lid_x] = totalSum;
)"
R"(    if (groupId == 3) reduceLM[SIMDGROUP_WIDTH * 2 + lid_x] = totalSum;
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(    if (groupId == 0) totalSum += reduceLM[SIMDGROUP_WIDTH * 0 + lid_x];
)"
R"(    if (groupId == 0) totalSum += reduceLM[SIMDGROUP_WIDTH * 1 + lid_x];
)"
R"(    if (groupId == 0) totalSum += reduceLM[SIMDGROUP_WIDTH * 2 + lid_x];
)"
R"(
)"
R"(    // 1 outputs per fiber in wave 0
)"
R"(    if (groupId == 0) {
)"
R"(        dst = (global float*)((global char*)dst + offsetd);
)"
R"(        // Guard the output row. The x-grid is padded to CEIL_DIV(M,wavesize)*wavesize,
)"
R"(        // so when ne01 is not a multiple of the wave size the tail work-items run past
)"
R"(        // row ne01 and would overrun dst into the adjacent tensor. No-op / byte-identical
)"
R"(        // when ne01 is wave-aligned (no padding).
)"
R"(        if (gid < M) dst[gid] = totalSum;
)"
R"(    }
)"
R"(#endif // ADRENO_GPU
)"
R"(}
)"
