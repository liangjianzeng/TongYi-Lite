R"(#pragma OPENCL EXTENSION cl_khr_fp16 : enable
)"
R"(#pragma OPENCL EXTENSION cl_khr_subgroups : enable
)"
R"(
)"
R"(// [dspark 2026-10-14] SGB bitcast shims. Host passes -DSGB_FLOAT_BROKEN when
)"
R"(// the driver's online compiler lacks float overloads of sub_group_broadcast
)"
R"(// (Adreno 740: only scalar uint/int/long/ulong exist). Bitcast float<->uint,
)"
R"(// broadcast as integer, cast back — bitwise identical, subgroup-uniform.
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
R"(#define QK1_0 128
)"
R"(#define N_SIMDGROUP 4
)"
R"(
)"
R"(#define dequantizeBlockAccum_q1(total, bits, scale, regB, lb)                                       \
)"
R"(    total += (2.0f*(float)((bits >>  0) & 1u) - 1.0f) * scale * SGB_BC(regB.s0, lb+0); \
)"
R"(    total += (2.0f*(float)((bits >>  1) & 1u) - 1.0f) * scale * SGB_BC(regB.s1, lb+0); \
)"
R"(    total += (2.0f*(float)((bits >>  2) & 1u) - 1.0f) * scale * SGB_BC(regB.s2, lb+0); \
)"
R"(    total += (2.0f*(float)((bits >>  3) & 1u) - 1.0f) * scale * SGB_BC(regB.s3, lb+0); \
)"
R"(    total += (2.0f*(float)((bits >>  4) & 1u) - 1.0f) * scale * SGB_BC(regB.s4, lb+0); \
)"
R"(    total += (2.0f*(float)((bits >>  5) & 1u) - 1.0f) * scale * SGB_BC(regB.s5, lb+0); \
)"
R"(    total += (2.0f*(float)((bits >>  6) & 1u) - 1.0f) * scale * SGB_BC(regB.s6, lb+0); \
)"
R"(    total += (2.0f*(float)((bits >>  7) & 1u) - 1.0f) * scale * SGB_BC(regB.s7, lb+0); \
)"
R"(    total += (2.0f*(float)((bits >>  8) & 1u) - 1.0f) * scale * SGB_BC(regB.s0, lb+1); \
)"
R"(    total += (2.0f*(float)((bits >>  9) & 1u) - 1.0f) * scale * SGB_BC(regB.s1, lb+1); \
)"
R"(    total += (2.0f*(float)((bits >> 10) & 1u) - 1.0f) * scale * SGB_BC(regB.s2, lb+1); \
)"
R"(    total += (2.0f*(float)((bits >> 11) & 1u) - 1.0f) * scale * SGB_BC(regB.s3, lb+1); \
)"
R"(    total += (2.0f*(float)((bits >> 12) & 1u) - 1.0f) * scale * SGB_BC(regB.s4, lb+1); \
)"
R"(    total += (2.0f*(float)((bits >> 13) & 1u) - 1.0f) * scale * SGB_BC(regB.s5, lb+1); \
)"
R"(    total += (2.0f*(float)((bits >> 14) & 1u) - 1.0f) * scale * SGB_BC(regB.s6, lb+1); \
)"
R"(    total += (2.0f*(float)((bits >> 15) & 1u) - 1.0f) * scale * SGB_BC(regB.s7, lb+1); \
)"
R"(    total += (2.0f*(float)((bits >> 16) & 1u) - 1.0f) * scale * SGB_BC(regB.s0, lb+2); \
)"
R"(    total += (2.0f*(float)((bits >> 17) & 1u) - 1.0f) * scale * SGB_BC(regB.s1, lb+2); \
)"
R"(    total += (2.0f*(float)((bits >> 18) & 1u) - 1.0f) * scale * SGB_BC(regB.s2, lb+2); \
)"
R"(    total += (2.0f*(float)((bits >> 19) & 1u) - 1.0f) * scale * SGB_BC(regB.s3, lb+2); \
)"
R"(    total += (2.0f*(float)((bits >> 20) & 1u) - 1.0f) * scale * SGB_BC(regB.s4, lb+2); \
)"
R"(    total += (2.0f*(float)((bits >> 21) & 1u) - 1.0f) * scale * SGB_BC(regB.s5, lb+2); \
)"
R"(    total += (2.0f*(float)((bits >> 22) & 1u) - 1.0f) * scale * SGB_BC(regB.s6, lb+2); \
)"
R"(    total += (2.0f*(float)((bits >> 23) & 1u) - 1.0f) * scale * SGB_BC(regB.s7, lb+2); \
)"
R"(    total += (2.0f*(float)((bits >> 24) & 1u) - 1.0f) * scale * SGB_BC(regB.s0, lb+3); \
)"
R"(    total += (2.0f*(float)((bits >> 25) & 1u) - 1.0f) * scale * SGB_BC(regB.s1, lb+3); \
)"
R"(    total += (2.0f*(float)((bits >> 26) & 1u) - 1.0f) * scale * SGB_BC(regB.s2, lb+3); \
)"
R"(    total += (2.0f*(float)((bits >> 27) & 1u) - 1.0f) * scale * SGB_BC(regB.s3, lb+3); \
)"
R"(    total += (2.0f*(float)((bits >> 28) & 1u) - 1.0f) * scale * SGB_BC(regB.s4, lb+3); \
)"
R"(    total += (2.0f*(float)((bits >> 29) & 1u) - 1.0f) * scale * SGB_BC(regB.s5, lb+3); \
)"
R"(    total += (2.0f*(float)((bits >> 30) & 1u) - 1.0f) * scale * SGB_BC(regB.s6, lb+3); \
)"
R"(    total += (2.0f*(float)((bits >> 31) & 1u) - 1.0f) * scale * SGB_BC(regB.s7, lb+3);
)"
R"(
)"
R"(
)"
R"(// [dspark 2026-10-20] rusticl-safe (GGML_OPENCL_RUSTICL) per-lane self-load
)"
R"(// dequant, one q1_0 32-bit word at a time: bit i of the word multiplies
)"
R"(// activation float 32*j + i, i.e. pixel (pix + i/4) component (i%4) where
)"
R"(// pix = kb*32 + 8*j for word j. No broadcast, no local reduce; one lane owns
)"
R"(// a row end-to-end (full K loop), 4x redundant B reads (L1-resident).
)"
R"(#define DEQUANT_ACCUM_SELF_Q1_W(total, bits, scale, img, pix) \
)"
R"(    { for (uint _p = 0; _p < 8; _p++) { \
)"
R"(        float4 qb4 = read_imagef(img, (pix) + _p); \
)"
R"(        uint _s = _p * 4; \
)"
R"(        total += (2.0f*(float)((bits >> (_s+0)) & 1u) - 1.0f) * scale * qb4.x; \
)"
R"(        total += (2.0f*(float)((bits >> (_s+1)) & 1u) - 1.0f) * scale * qb4.y; \
)"
R"(        total += (2.0f*(float)((bits >> (_s+2)) & 1u) - 1.0f) * scale * qb4.z; \
)"
R"(        total += (2.0f*(float)((bits >> (_s+3)) & 1u) - 1.0f) * scale * qb4.w; \
)"
R"(    } }
)"
R"(
)"
R"(#if defined(ADRENO_GPU) && !defined(GGML_OPENCL_RUSTICL)
)"
R"(REQD_SUBGROUP_SIZE_64
)"
R"(#endif
)"
R"(__kernel void kernel_gemv_noshuffle_q1_0_f32(
)"
R"(        read_only  image1d_buffer_t src0_q,
)"
R"(        global half  * src0_d,
)"
R"(        read_only  image1d_buffer_t src1,
)"
R"(        ulong offset1,
)"
R"(        global float * dst,
)"
R"(        ulong offsetd,
)"
R"(        int ne00,
)"
R"(        int ne01,
)"
R"(        int ne02,
)"
R"(        int ne10,
)"
R"(        int ne12,
)"
R"(        int ne0,
)"
R"(        int ne1,
)"
R"(        int r2,
)"
R"(        int r3)
)"
R"({
)"
R"(    uint groupId = get_local_id(1);
)"
R"(    uint gid     = get_global_id(0);
)"
R"(    ushort slid  = get_sub_group_local_id();
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
R"(    uint BLOCK_STRIDE_A = 4 * M;
)"
R"(
)"
R"(    uint4  regA;
)"
R"(    half   regS;
)"
R"(    float8 regB;
)"
R"(
)"
R"(    float totalSum = 0.0f;
)"
R"(
)"
R"(#if defined(ADRENO_GPU) && !defined(GGML_OPENCL_RUSTICL)
)"
R"(    #pragma unroll 1
)"
R"(    for (uint kb = groupId; kb < (K / QK1_0); kb += N_SIMDGROUP) {
)"
R"(        regS = src0_d[gid_s + kb * LINE_STRIDE_A]; // each fiber loads its row's scale
)"
R"(
)"
R"(        // first 16 fibers load 8 B values each -> 128 activations for this block
)"
R"(        if (slid < 16) {
)"
R"(            regB.s0123 = read_imagef(src1, (slid * 2 + kb * 32));
)"
R"(            regB.s4567 = read_imagef(src1, (1 + slid * 2 + kb * 32));
)"
R"(        }
)"
R"(
)"
R"(        // load this row's 4 uint32 (128 sign bits)
)"
R"(        regA.s0 = read_imageui(src0_q, (gid_s + kb * BLOCK_STRIDE_A + LINE_STRIDE_A * 0)).x;
)"
R"(        regA.s1 = read_imageui(src0_q, (gid_s + kb * BLOCK_STRIDE_A + LINE_STRIDE_A * 1)).x;
)"
R"(        regA.s2 = read_imageui(src0_q, (gid_s + kb * BLOCK_STRIDE_A + LINE_STRIDE_A * 2)).x;
)"
R"(        regA.s3 = read_imageui(src0_q, (gid_s + kb * BLOCK_STRIDE_A + LINE_STRIDE_A * 3)).x;
)"
R"(
)"
R"(        float scale = (float)regS;
)"
R"(        dequantizeBlockAccum_q1(totalSum, regA.s0, scale, regB, 0);
)"
R"(        dequantizeBlockAccum_q1(totalSum, regA.s1, scale, regB, 4);
)"
R"(        dequantizeBlockAccum_q1(totalSum, regA.s2, scale, regB, 8);
)"
R"(        dequantizeBlockAccum_q1(totalSum, regA.s3, scale, regB, 12);
)"
R"(    }
)"
R"(
)"
R"(    // reduction in local memory, assumes #wave = N_SIMDGROUP = 4
)"
R"(    local float reduceLM[SIMDGROUP_WIDTH * 3];
)"
R"(    if (groupId == 1) reduceLM[SIMDGROUP_WIDTH * 0 + slid] = totalSum;
)"
R"(    if (groupId == 2) reduceLM[SIMDGROUP_WIDTH * 1 + slid] = totalSum;
)"
R"(    if (groupId == 3) reduceLM[SIMDGROUP_WIDTH * 2 + slid] = totalSum;
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(    if (groupId == 0) totalSum += reduceLM[SIMDGROUP_WIDTH * 0 + slid];
)"
R"(    if (groupId == 0) totalSum += reduceLM[SIMDGROUP_WIDTH * 1 + slid];
)"
R"(    if (groupId == 0) totalSum += reduceLM[SIMDGROUP_WIDTH * 2 + slid];
)"
R"(
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
R"(#else
)"
R"(    // [dspark 2026-10-20] rusticl-safe variant (FD650 measured sgs=128 for this
)"
R"(    // kernel): sync-free full-K path, one lane owns its output row end-to-end.
)"
R"(    #pragma unroll 1
)"
R"(    for (uint kb = 0; kb < (K / QK1_0); kb++) {
)"
R"(        regS = src0_d[gid_s + kb * LINE_STRIDE_A];
)"
R"(        regA.s0 = read_imageui(src0_q, (gid_s + kb * BLOCK_STRIDE_A + LINE_STRIDE_A * 0)).x;
)"
R"(        regA.s1 = read_imageui(src0_q, (gid_s + kb * BLOCK_STRIDE_A + LINE_STRIDE_A * 1)).x;
)"
R"(        regA.s2 = read_imageui(src0_q, (gid_s + kb * BLOCK_STRIDE_A + LINE_STRIDE_A * 2)).x;
)"
R"(        regA.s3 = read_imageui(src0_q, (gid_s + kb * BLOCK_STRIDE_A + LINE_STRIDE_A * 3)).x;
)"
R"(
)"
R"(        float scale = (float)regS;
)"
R"(        DEQUANT_ACCUM_SELF_Q1_W(totalSum, regA.s0, scale, src1, kb * 32 + 0);
)"
R"(        DEQUANT_ACCUM_SELF_Q1_W(totalSum, regA.s1, scale, src1, kb * 32 + 8);
)"
R"(        DEQUANT_ACCUM_SELF_Q1_W(totalSum, regA.s2, scale, src1, kb * 32 + 16);
)"
R"(        DEQUANT_ACCUM_SELF_Q1_W(totalSum, regA.s3, scale, src1, kb * 32 + 24);
)"
R"(    }
)"
R"(
)"
R"(    dst = (global float*)((global char*)dst + offsetd);
)"
R"(    if (gid < M) dst[gid] = totalSum;
)"
R"(    return;
)"
R"(#endif
)"
R"(}
)"
