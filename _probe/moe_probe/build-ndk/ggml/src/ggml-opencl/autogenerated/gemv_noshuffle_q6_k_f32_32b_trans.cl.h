R"(#pragma OPENCL EXTENSION cl_khr_fp16 : enable
)"
R"(#pragma OPENCL EXTENSION cl_khr_subgroups : enable
)"
R"(#pragma OPENCL EXTENSION cl_qcom_reqd_sub_group_size : enable
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
R"(// the driver's online compiler lacks float overloads of sub_group_broadcast
)"
R"(// (Adreno 740: only scalar uint/int/long/ulong exist). Bitcast float<->uint,
)"
R"(// broadcast as integer, cast back — bitwise identical, subgroup-uniform.
)"
R"(#define QK_K 256
)"
R"(#define N_SIMDGROUP 8
)"
R"(#define SIMDGROUP_WIDTH 64
)"
R"(
)"
R"(static inline float8 q6_k_to_fp32_packed8(ushort2 ql8, ushort qh8, float d_scale) {
)"
R"(    float8 fp32x8;
)"
R"(    fp32x8.s0 = ((float)(( ql8.s0 & 0x000F)        | ((uint)((qh8      ) & 0x3) << 4)) - 32.f) * d_scale;
)"
R"(    fp32x8.s1 = ((float)((( ql8.s0 >> 4) & 0x000F) | ((uint)((qh8 >> 2) & 0x3) << 4)) - 32.f) * d_scale;
)"
R"(    fp32x8.s2 = ((float)((( ql8.s0 >> 8) & 0x000F) | ((uint)((qh8 >> 4) & 0x3) << 4)) - 32.f) * d_scale;
)"
R"(    fp32x8.s3 = ((float)((( ql8.s0 >> 12)& 0x000F) | ((uint)((qh8 >> 6) & 0x3) << 4)) - 32.f) * d_scale;
)"
R"(    fp32x8.s4 = ((float)(( ql8.s1 & 0x000F)        | ((uint)((qh8 >> 8) & 0x3) << 4)) - 32.f) * d_scale;
)"
R"(    fp32x8.s5 = ((float)((( ql8.s1 >> 4) & 0x000F) | ((uint)((qh8 >>10) & 0x3) << 4)) - 32.f) * d_scale;
)"
R"(    fp32x8.s6 = ((float)((( ql8.s1 >> 8) & 0x000F) | ((uint)((qh8 >>12) & 0x3) << 4)) - 32.f) * d_scale;
)"
R"(    fp32x8.s7 = ((float)((( ql8.s1 >> 12)& 0x000F) | ((uint)((qh8 >>14) & 0x3) << 4)) - 32.f) * d_scale;
)"
R"(    return fp32x8;
)"
R"(}
)"
R"(
)"
R"(__attribute__((qcom_reqd_sub_group_size("half")))
)"
R"(__kernel void kernel_gemv_noshuffle_q6_k_f32_32b_trans(
)"
R"(    __read_only image1d_buffer_t src0_ql,
)"
R"(    __read_only image1d_buffer_t src0_qh,
)"
R"(    __global char *         src0_s,
)"
R"(    __global half *         src0_d,
)"
R"(    __read_only image1d_buffer_t src1,
)"
R"(    __global float *        dst,
)"
R"(    ulong                   offsetd,
)"
R"(    int                     ne00,
)"
R"(    int                     ne01
)"
R"() {
)"
R"(    uint i01  = get_global_id(0);
)"
R"(    uint sgid = get_local_id(1);
)"
R"(    uint slid = get_sub_group_local_id();
)"
R"(
)"
R"(    int num_superblocks = ne00 / QK_K;
)"
R"(    int num_subblocks   = ne00 / 32;    // 2 sub-blocks of 16 processed per iter below
)"
R"(    int scales_per_row   = num_superblocks * 16;
)"
R"(
)"
R"(    __private float sum = 0.0f;
)"
R"(
)"
R"(    // Loop over 32-element groups (2 sub-blocks of 16 each), N_SIMDGROUP groups per iter.
)"
R"(    // [dspark 2026-10-17] K-split stride is now the LAUNCH's y-size (was the
)"
R"(    // compile-time N_SIMDGROUP); host clamps y-split to 1 on rusticl.
)"
R"(    uint nsg_rt = get_local_size(1);
)"
R"(    for (uint ib = sgid; ib < num_subblocks; ib += nsg_rt) {
)"
R"(        uint sb = ib / 8;   // super-block index
)"
R"(        uint j  = ib % 8;   // 32-element group within super-block (0..7)
)"
R"(
)"
R"(        // Load d for this super-block.
)"
R"(        half d_val = src0_d[sb * ne01 + i01];
)"
R"(
)"
R"(        // Load 2 sub-block scales (int8), one per 16 elements.
)"
R"(        global const char * sc = src0_s + i01 * scales_per_row + sb * 16;
)"
R"(        float scale0 = (float)d_val * (float)sc[j * 2];
)"
R"(        float scale1 = (float)d_val * (float)sc[j * 2 + 1];
)"
R"(
)"
R"(        // Load 4 uints of ql (32 elements, 4-bit each = 128 bits), column-major stride ne01.
)"
R"(        uint ql_base = (ib * 4) * ne01 + i01;
)"
R"(        uint4 regQL;
)"
R"(        regQL.s0 = read_imageui(src0_ql, ql_base).x;
)"
R"(        regQL.s1 = read_imageui(src0_ql, ql_base + ne01).x;
)"
R"(        regQL.s2 = read_imageui(src0_ql, ql_base + ne01 * 2).x;
)"
R"(        regQL.s3 = read_imageui(src0_ql, ql_base + ne01 * 3).x;
)"
R"(
)"
R"(        // Load 2 uints of qh (32 elements, 2-bit each = 64 bits), column-major stride ne01.
)"
R"(        uint qh_base = (ib * 2) * ne01 + i01;
)"
R"(        uint2 regQH;
)"
R"(        regQH.s0 = read_imageui(src0_qh, qh_base).x;
)"
R"(        regQH.s1 = read_imageui(src0_qh, qh_base + ne01).x;
)"
R"(
)"
R"(        // Load activations: 32 floats = 8 float4s.
)"
R"(        uint y_offset = ib * 8;
)"
R"(
)"
R"(        float4 y_local = (slid < 8) ? read_imagef(src1, (y_offset + slid)) : (float4)0.0f;
)"
R"(        float4 y0;
)"
R"(        y0.s0 = SGB_BC(y_local.s0, 0); y0.s1 = SGB_BC(y_local.s1, 0);
)"
R"(        y0.s2 = SGB_BC(y_local.s2, 0); y0.s3 = SGB_BC(y_local.s3, 0);
)"
R"(        float4 y1;
)"
R"(        y1.s0 = SGB_BC(y_local.s0, 1); y1.s1 = SGB_BC(y_local.s1, 1);
)"
R"(        y1.s2 = SGB_BC(y_local.s2, 1); y1.s3 = SGB_BC(y_local.s3, 1);
)"
R"(        float4 y2;
)"
R"(        y2.s0 = SGB_BC(y_local.s0, 2); y2.s1 = SGB_BC(y_local.s1, 2);
)"
R"(        y2.s2 = SGB_BC(y_local.s2, 2); y2.s3 = SGB_BC(y_local.s3, 2);
)"
R"(        float4 y3;
)"
R"(        y3.s0 = SGB_BC(y_local.s0, 3); y3.s1 = SGB_BC(y_local.s1, 3);
)"
R"(        y3.s2 = SGB_BC(y_local.s2, 3); y3.s3 = SGB_BC(y_local.s3, 3);
)"
R"(        float4 y4v;
)"
R"(        y4v.s0 = SGB_BC(y_local.s0, 4); y4v.s1 = SGB_BC(y_local.s1, 4);
)"
R"(        y4v.s2 = SGB_BC(y_local.s2, 4); y4v.s3 = SGB_BC(y_local.s3, 4);
)"
R"(        float4 y5;
)"
R"(        y5.s0 = SGB_BC(y_local.s0, 5); y5.s1 = SGB_BC(y_local.s1, 5);
)"
R"(        y5.s2 = SGB_BC(y_local.s2, 5); y5.s3 = SGB_BC(y_local.s3, 5);
)"
R"(        float4 y6;
)"
R"(        y6.s0 = SGB_BC(y_local.s0, 6); y6.s1 = SGB_BC(y_local.s1, 6);
)"
R"(        y6.s2 = SGB_BC(y_local.s2, 6); y6.s3 = SGB_BC(y_local.s3, 6);
)"
R"(        float4 y7;
)"
R"(        y7.s0 = SGB_BC(y_local.s0, 7); y7.s1 = SGB_BC(y_local.s1, 7);
)"
R"(        y7.s2 = SGB_BC(y_local.s2, 7); y7.s3 = SGB_BC(y_local.s3, 7);
)"
R"(
)"
R"(        // Dequantize elements 0..7 (scale0).
)"
R"(        float8 fp32x8 = q6_k_to_fp32_packed8(as_ushort2(regQL.s0), (ushort)(regQH.s0 & 0xFFFF), scale0);
)"
R"(
)"
R"(        float4 acc = y0 * fp32x8.lo;
)"
R"(        acc += y1 * fp32x8.hi;
)"
R"(
)"
R"(        // Dequantize elements 8..15 (scale0).
)"
R"(        fp32x8 = q6_k_to_fp32_packed8(as_ushort2(regQL.s1), (ushort)(regQH.s0 >> 16), scale0);
)"
R"(
)"
R"(        acc += y2 * fp32x8.lo;
)"
R"(        acc += y3 * fp32x8.hi;
)"
R"(
)"
R"(        // Dequantize elements 16..23 (scale1).
)"
R"(        fp32x8 = q6_k_to_fp32_packed8(as_ushort2(regQL.s2), (ushort)(regQH.s1 & 0xFFFF), scale1);
)"
R"(
)"
R"(        acc += y4v * fp32x8.lo;
)"
R"(        acc += y5 * fp32x8.hi;
)"
R"(
)"
R"(        // Dequantize elements 24..31 (scale1).
)"
R"(        fp32x8 = q6_k_to_fp32_packed8(as_ushort2(regQL.s3), (ushort)(regQH.s1 >> 16), scale1);
)"
R"(
)"
R"(        acc += y6 * fp32x8.lo;
)"
R"(        acc += y7 * fp32x8.hi;
)"
R"(
)"
R"(        sum += ((acc.s0 + acc.s1) + (acc.s2 + acc.s3));
)"
R"(    }
)"
R"(
)"
R"(    // reduction in local memory, assumes #subgroups=4
)"
R"(    __local float reduceLM[SIMDGROUP_WIDTH * (N_SIMDGROUP - 1)];
)"
R"(    if (sgid > 0) {
)"
R"(        reduceLM[SIMDGROUP_WIDTH * (sgid - 1) + slid] = sum;
)"
R"(    }
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(    if (sgid == 0) {
)"
R"(        for (uint i = 0; i < nsg_rt - 1; ++i) {
)"
R"(            sum += reduceLM[SIMDGROUP_WIDTH * i + slid];
)"
R"(        }
)"
R"(    }
)"
R"(
)"
R"(    // 1 output per thread in subgroup 0
)"
R"(    if (sgid == 0) {
)"
R"(        dst = dst + (offsetd >> 2);
)"
R"(        dst[i01] = sum;
)"
R"(    }
)"
R"(}
)"
