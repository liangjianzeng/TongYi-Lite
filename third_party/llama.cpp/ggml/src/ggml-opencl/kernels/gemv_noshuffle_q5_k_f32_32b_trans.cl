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
#define K_SCALE_SIZE 12
#define N_SIMDGROUP 8
#define SIMDGROUP_WIDTH 64

inline void get_scale_min_k4(
    int j,
    global const uchar * q,
    uint stride,
    uchar * d,
    uchar * m
) {
    if (j < 4) {
        *d = q[j*stride]     & 63;
        *m = q[(j+4)*stride] & 63;
    } else {
        *d = (q[(j+4)*stride] & 0x0F) | ((q[(j-4)*stride] & 0xC0) >> 2);
        *m = ((q[(j+4)*stride] >> 4) & 0x0F) | ((q[j*stride] & 0xC0) >> 2);
    }
}

static inline float8 q5_k_to_fp32_packed8(ushort2 q4x8, uint qh_byte, float scale, float minv) {
    float8 fp32x8;
    fp32x8.s0 = (float)(( q4x8.s0        & 0x000F) | (((qh_byte >> 0) & 1) << 4)) * scale - minv;
    fp32x8.s1 = (float)(((q4x8.s0 >> 4)  & 0x000F) | (((qh_byte >> 1) & 1) << 4)) * scale - minv;
    fp32x8.s2 = (float)(((q4x8.s0 >> 8)  & 0x000F) | (((qh_byte >> 2) & 1) << 4)) * scale - minv;
    fp32x8.s3 = (float)(((q4x8.s0 >> 12) & 0x000F) | (((qh_byte >> 3) & 1) << 4)) * scale - minv;
    fp32x8.s4 = (float)(( q4x8.s1        & 0x000F) | (((qh_byte >> 4) & 1) << 4)) * scale - minv;
    fp32x8.s5 = (float)(((q4x8.s1 >> 4)  & 0x000F) | (((qh_byte >> 5) & 1) << 4)) * scale - minv;
    fp32x8.s6 = (float)(((q4x8.s1 >> 8)  & 0x000F) | (((qh_byte >> 6) & 1) << 4)) * scale - minv;
    fp32x8.s7 = (float)(((q4x8.s1 >> 12) & 0x000F) | (((qh_byte >> 7) & 1) << 4)) * scale - minv;
    return fp32x8;
}

__attribute__((qcom_reqd_sub_group_size("half")))
__kernel void gemv_noshuffle_q5_k_f32_32b_trans(
    read_only image1d_buffer_t src0_q,
    __global uchar *        src0_qh,
    __global half *         src0_d,
    __global half *         src0_dm,
    __global uchar *        src0_s,
    __read_only image1d_buffer_t src1,
    __global float *        dst,
    ulong                   offsetd,
    int                     ne00,
    int                     ne01
) {
    uint i01  = get_global_id(0);
    uint sgid = get_local_id(1);
    uint slid = get_sub_group_local_id();

    int num_subblocks = ne00 / 32;

    __private float sum = 0.0f;

    // Loop over sub-blocks of 32 elements, N_SIMDGROUP sub-blocks per iter.
    for (uint ib = sgid; ib < num_subblocks; ib += N_SIMDGROUP) {
        uint sb = ib / 8;
        uint j  = ib % 8;

        // Load d and dmin for this super-block.
        half d_val  = src0_d[sb * ne01 + i01];
        half dm_val = src0_dm[sb * ne01 + i01];

        // Load sub-block scale and min. s is transposed [nb][12][M]; stride ne01 per code.
        global const uchar * sc = src0_s + sb * K_SCALE_SIZE * ne01 + i01;
        uchar sv, mn;
        get_scale_min_k4(j, sc, ne01, &sv, &mn);

        float scale = (float)d_val * (float)sv;
        float minv  = (float)dm_val * (float)mn;

        // Load 4 uints of quants (32 nibbles = 32 elements), column-major stride ne01.
        uint q_base = ib * ne01 * 4 + i01;

        uint4 regQ;
        regQ.s0 = read_imageui(src0_q, q_base).x;
        regQ.s1 = read_imageui(src0_q, q_base + ne01).x;
        regQ.s2 = read_imageui(src0_q, q_base + ne01 * 2).x;
        regQ.s3 = read_imageui(src0_q, q_base + ne01 * 3).x;

        uint qh_grp = ib * 4;
        uint qh_word = (uint)src0_qh[(qh_grp + 0) * ne01 + i01]
                      | ((uint)src0_qh[(qh_grp + 1) * ne01 + i01] << 8)
                      | ((uint)src0_qh[(qh_grp + 2) * ne01 + i01] << 16)
                      | ((uint)src0_qh[(qh_grp + 3) * ne01 + i01] << 24);

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
        float4 y4;
        y4.s0 = SGB_BC(y_local.s0, 4); y4.s1 = SGB_BC(y_local.s1, 4);
        y4.s2 = SGB_BC(y_local.s2, 4); y4.s3 = SGB_BC(y_local.s3, 4);
        float4 y5;
        y5.s0 = SGB_BC(y_local.s0, 5); y5.s1 = SGB_BC(y_local.s1, 5);
        y5.s2 = SGB_BC(y_local.s2, 5); y5.s3 = SGB_BC(y_local.s3, 5);
        float4 y6;
        y6.s0 = SGB_BC(y_local.s0, 6); y6.s1 = SGB_BC(y_local.s1, 6);
        y6.s2 = SGB_BC(y_local.s2, 6); y6.s3 = SGB_BC(y_local.s3, 6);
        float4 y7;
        y7.s0 = SGB_BC(y_local.s0, 7); y7.s1 = SGB_BC(y_local.s1, 7);
        y7.s2 = SGB_BC(y_local.s2, 7); y7.s3 = SGB_BC(y_local.s3, 7);

        float8 fp32x8 = q5_k_to_fp32_packed8(as_ushort2(regQ.s0), qh_word & 0xFF, scale, minv);
        float4 acc = y0 * fp32x8.lo;
        acc += y1 * fp32x8.hi;

        fp32x8 = q5_k_to_fp32_packed8(as_ushort2(regQ.s1), (qh_word >> 8) & 0xFF, scale, minv);
        acc += y2 * fp32x8.lo;
        acc += y3 * fp32x8.hi;

        fp32x8 = q5_k_to_fp32_packed8(as_ushort2(regQ.s2), (qh_word >> 16) & 0xFF, scale, minv);
        acc += y4 * fp32x8.lo;
        acc += y5 * fp32x8.hi;

        fp32x8 = q5_k_to_fp32_packed8(as_ushort2(regQ.s3), (qh_word >> 24) & 0xFF, scale, minv);
        acc += y6 * fp32x8.lo;
        acc += y7 * fp32x8.hi;

        sum += ((acc.s0 + acc.s1) + (acc.s2 + acc.s3));
    }

    // reduction in local memory over N_SIMDGROUP subgroups
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
