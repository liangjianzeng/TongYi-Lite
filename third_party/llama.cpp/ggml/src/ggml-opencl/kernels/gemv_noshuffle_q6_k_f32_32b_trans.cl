#pragma OPENCL EXTENSION cl_khr_fp16 : enable
#pragma OPENCL EXTENSION cl_khr_subgroups : enable
#pragma OPENCL EXTENSION cl_qcom_reqd_sub_group_size : enable

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

// the driver's online compiler lacks float overloads of sub_group_broadcast
// (Adreno 740: only scalar uint/int/long/ulong exist). Bitcast float<->uint,
// broadcast as integer, cast back — bitwise identical, subgroup-uniform.
#define QK_K 256
#define N_SIMDGROUP 8
#define SIMDGROUP_WIDTH 64

static inline float8 q6_k_to_fp32_packed8(ushort2 ql8, ushort qh8, float d_scale) {
    float8 fp32x8;
    fp32x8.s0 = ((float)(( ql8.s0 & 0x000F)        | ((uint)((qh8      ) & 0x3) << 4)) - 32.f) * d_scale;
    fp32x8.s1 = ((float)((( ql8.s0 >> 4) & 0x000F) | ((uint)((qh8 >> 2) & 0x3) << 4)) - 32.f) * d_scale;
    fp32x8.s2 = ((float)((( ql8.s0 >> 8) & 0x000F) | ((uint)((qh8 >> 4) & 0x3) << 4)) - 32.f) * d_scale;
    fp32x8.s3 = ((float)((( ql8.s0 >> 12)& 0x000F) | ((uint)((qh8 >> 6) & 0x3) << 4)) - 32.f) * d_scale;
    fp32x8.s4 = ((float)(( ql8.s1 & 0x000F)        | ((uint)((qh8 >> 8) & 0x3) << 4)) - 32.f) * d_scale;
    fp32x8.s5 = ((float)((( ql8.s1 >> 4) & 0x000F) | ((uint)((qh8 >>10) & 0x3) << 4)) - 32.f) * d_scale;
    fp32x8.s6 = ((float)((( ql8.s1 >> 8) & 0x000F) | ((uint)((qh8 >>12) & 0x3) << 4)) - 32.f) * d_scale;
    fp32x8.s7 = ((float)((( ql8.s1 >> 12)& 0x000F) | ((uint)((qh8 >>14) & 0x3) << 4)) - 32.f) * d_scale;
    return fp32x8;
}

__attribute__((qcom_reqd_sub_group_size("half")))
__kernel void kernel_gemv_noshuffle_q6_k_f32_32b_trans(
    __read_only image1d_buffer_t src0_ql,
    __read_only image1d_buffer_t src0_qh,
    __global char *         src0_s,
    __global half *         src0_d,
    __read_only image1d_buffer_t src1,
    __global float *        dst,
    ulong                   offsetd,
    int                     ne00,
    int                     ne01
) {
    uint i01  = get_global_id(0);
    uint sgid = get_local_id(1);
    uint slid = get_sub_group_local_id();

    int num_superblocks = ne00 / QK_K;
    int num_subblocks   = ne00 / 32;    // 2 sub-blocks of 16 processed per iter below
    int scales_per_row   = num_superblocks * 16;

    __private float sum = 0.0f;

    // Loop over 32-element groups (2 sub-blocks of 16 each), N_SIMDGROUP groups per iter.
    for (uint ib = sgid; ib < num_subblocks; ib += N_SIMDGROUP) {
        uint sb = ib / 8;   // super-block index
        uint j  = ib % 8;   // 32-element group within super-block (0..7)

        // Load d for this super-block.
        half d_val = src0_d[sb * ne01 + i01];

        // Load 2 sub-block scales (int8), one per 16 elements.
        global const char * sc = src0_s + i01 * scales_per_row + sb * 16;
        float scale0 = (float)d_val * (float)sc[j * 2];
        float scale1 = (float)d_val * (float)sc[j * 2 + 1];

        // Load 4 uints of ql (32 elements, 4-bit each = 128 bits), column-major stride ne01.
        uint ql_base = (ib * 4) * ne01 + i01;
        uint4 regQL;
        regQL.s0 = read_imageui(src0_ql, ql_base).x;
        regQL.s1 = read_imageui(src0_ql, ql_base + ne01).x;
        regQL.s2 = read_imageui(src0_ql, ql_base + ne01 * 2).x;
        regQL.s3 = read_imageui(src0_ql, ql_base + ne01 * 3).x;

        // Load 2 uints of qh (32 elements, 2-bit each = 64 bits), column-major stride ne01.
        uint qh_base = (ib * 2) * ne01 + i01;
        uint2 regQH;
        regQH.s0 = read_imageui(src0_qh, qh_base).x;
        regQH.s1 = read_imageui(src0_qh, qh_base + ne01).x;

        // Load activations: 32 floats = 8 float4s.
        uint y_offset = ib * 8;

        float4 y_local = (slid < 8) ? read_imagef(src1, (y_offset + slid)) : (float4)0.0f;
        float4 y0;
        y0.s0 = SGB_BC(y_local.s0, 0); y0.s1 = SGB_BC(y_local.s1, 0);
        y0.s2 = SGB_BC(y_local.s2, 0); y0.s3 = SGB_BC(y_local.s3, 0);
        float4 y1;
        y1.s0 = SGB_BC(y_local.s0, 1); y1.s1 = SGB_BC(y_local.s1, 1);
        y1.s2 = SGB_BC(y_local.s2, 1); y1.s3 = SGB_BC(y_local.s3, 1);
        float4 y2;
        y2.s0 = SGB_BC(y_local.s0, 2); y2.s1 = SGB_BC(y_local.s1, 2);
        y2.s2 = SGB_BC(y_local.s2, 2); y2.s3 = SGB_BC(y_local.s3, 2);
        float4 y3;
        y3.s0 = SGB_BC(y_local.s0, 3); y3.s1 = SGB_BC(y_local.s1, 3);
        y3.s2 = SGB_BC(y_local.s2, 3); y3.s3 = SGB_BC(y_local.s3, 3);
        float4 y4v;
        y4v.s0 = SGB_BC(y_local.s0, 4); y4v.s1 = SGB_BC(y_local.s1, 4);
        y4v.s2 = SGB_BC(y_local.s2, 4); y4v.s3 = SGB_BC(y_local.s3, 4);
        float4 y5;
        y5.s0 = SGB_BC(y_local.s0, 5); y5.s1 = SGB_BC(y_local.s1, 5);
        y5.s2 = SGB_BC(y_local.s2, 5); y5.s3 = SGB_BC(y_local.s3, 5);
        float4 y6;
        y6.s0 = SGB_BC(y_local.s0, 6); y6.s1 = SGB_BC(y_local.s1, 6);
        y6.s2 = SGB_BC(y_local.s2, 6); y6.s3 = SGB_BC(y_local.s3, 6);
        float4 y7;
        y7.s0 = SGB_BC(y_local.s0, 7); y7.s1 = SGB_BC(y_local.s1, 7);
        y7.s2 = SGB_BC(y_local.s2, 7); y7.s3 = SGB_BC(y_local.s3, 7);

        // Dequantize elements 0..7 (scale0).
        float8 fp32x8 = q6_k_to_fp32_packed8(as_ushort2(regQL.s0), (ushort)(regQH.s0 & 0xFFFF), scale0);

        float4 acc = y0 * fp32x8.lo;
        acc += y1 * fp32x8.hi;

        // Dequantize elements 8..15 (scale0).
        fp32x8 = q6_k_to_fp32_packed8(as_ushort2(regQL.s1), (ushort)(regQH.s0 >> 16), scale0);

        acc += y2 * fp32x8.lo;
        acc += y3 * fp32x8.hi;

        // Dequantize elements 16..23 (scale1).
        fp32x8 = q6_k_to_fp32_packed8(as_ushort2(regQL.s2), (ushort)(regQH.s1 & 0xFFFF), scale1);

        acc += y4v * fp32x8.lo;
        acc += y5 * fp32x8.hi;

        // Dequantize elements 24..31 (scale1).
        fp32x8 = q6_k_to_fp32_packed8(as_ushort2(regQL.s3), (ushort)(regQH.s1 >> 16), scale1);

        acc += y6 * fp32x8.lo;
        acc += y7 * fp32x8.hi;

        sum += ((acc.s0 + acc.s1) + (acc.s2 + acc.s3));
    }

    // reduction in local memory, assumes #subgroups=4
    __local float reduceLM[SIMDGROUP_WIDTH * (N_SIMDGROUP - 1)];
    if (sgid > 0) {
        reduceLM[SIMDGROUP_WIDTH * (sgid - 1) + slid] = sum;
    }
    barrier(CLK_LOCAL_MEM_FENCE);
    if (sgid == 0) {
        for (uint i = 0; i < N_SIMDGROUP - 1; ++i) {
            sum += reduceLM[SIMDGROUP_WIDTH * i + slid];
        }
    }

    // 1 output per thread in subgroup 0
    if (sgid == 0) {
        dst = dst + (offsetd >> 2);
        dst[i01] = sum;
    }
}
