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
R"(#define K_SCALE_SIZE 12
)"
R"(#define N_SIMDGROUP 8
)"
R"(#define SIMDGROUP_WIDTH 64
)"
R"(
)"
R"(inline void get_scale_min_k4(
)"
R"(    int j,
)"
R"(    global const uchar * q,
)"
R"(    uint stride,
)"
R"(    uchar * d,
)"
R"(    uchar * m
)"
R"() {
)"
R"(    if (j < 4) {
)"
R"(        *d = q[j*stride]     & 63;
)"
R"(        *m = q[(j+4)*stride] & 63;
)"
R"(    } else {
)"
R"(        *d = (q[(j+4)*stride] & 0x0F) | ((q[(j-4)*stride] & 0xC0) >> 2);
)"
R"(        *m = ((q[(j+4)*stride] >> 4) & 0x0F) | ((q[j*stride] & 0xC0) >> 2);
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(static inline float8 q5_k_to_fp32_packed8(ushort2 q4x8, uint qh_byte, float scale, float minv) {
)"
R"(    float8 fp32x8;
)"
R"(    fp32x8.s0 = (float)(( q4x8.s0        & 0x000F) | (((qh_byte >> 0) & 1) << 4)) * scale - minv;
)"
R"(    fp32x8.s1 = (float)(((q4x8.s0 >> 4)  & 0x000F) | (((qh_byte >> 1) & 1) << 4)) * scale - minv;
)"
R"(    fp32x8.s2 = (float)(((q4x8.s0 >> 8)  & 0x000F) | (((qh_byte >> 2) & 1) << 4)) * scale - minv;
)"
R"(    fp32x8.s3 = (float)(((q4x8.s0 >> 12) & 0x000F) | (((qh_byte >> 3) & 1) << 4)) * scale - minv;
)"
R"(    fp32x8.s4 = (float)(( q4x8.s1        & 0x000F) | (((qh_byte >> 4) & 1) << 4)) * scale - minv;
)"
R"(    fp32x8.s5 = (float)(((q4x8.s1 >> 4)  & 0x000F) | (((qh_byte >> 5) & 1) << 4)) * scale - minv;
)"
R"(    fp32x8.s6 = (float)(((q4x8.s1 >> 8)  & 0x000F) | (((qh_byte >> 6) & 1) << 4)) * scale - minv;
)"
R"(    fp32x8.s7 = (float)(((q4x8.s1 >> 12) & 0x000F) | (((qh_byte >> 7) & 1) << 4)) * scale - minv;
)"
R"(    return fp32x8;
)"
R"(}
)"
R"(
)"
R"(__attribute__((qcom_reqd_sub_group_size("half")))
)"
R"(__kernel void gemv_noshuffle_q5_k_f32_32b_trans(
)"
R"(    read_only image1d_buffer_t src0_q,
)"
R"(    __global uchar *        src0_qh,
)"
R"(    __global half *         src0_d,
)"
R"(    __global half *         src0_dm,
)"
R"(    __global uchar *        src0_s,
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
R"(    int num_subblocks = ne00 / 32;
)"
R"(
)"
R"(    __private float sum = 0.0f;
)"
R"(
)"
R"(    // Loop over sub-blocks of 32 elements, N_SIMDGROUP sub-blocks per iter.
)"
R"(    for (uint ib = sgid; ib < num_subblocks; ib += N_SIMDGROUP) {
)"
R"(        uint sb = ib / 8;
)"
R"(        uint j  = ib % 8;
)"
R"(
)"
R"(        // Load d and dmin for this super-block.
)"
R"(        half d_val  = src0_d[sb * ne01 + i01];
)"
R"(        half dm_val = src0_dm[sb * ne01 + i01];
)"
R"(
)"
R"(        // Load sub-block scale and min. s is transposed [nb][12][M]; stride ne01 per code.
)"
R"(        global const uchar * sc = src0_s + sb * K_SCALE_SIZE * ne01 + i01;
)"
R"(        uchar sv, mn;
)"
R"(        get_scale_min_k4(j, sc, ne01, &sv, &mn);
)"
R"(
)"
R"(        float scale = (float)d_val * (float)sv;
)"
R"(        float minv  = (float)dm_val * (float)mn;
)"
R"(
)"
R"(        // Load 4 uints of quants (32 nibbles = 32 elements), column-major stride ne01.
)"
R"(        uint q_base = ib * ne01 * 4 + i01;
)"
R"(
)"
R"(        uint4 regQ;
)"
R"(        regQ.s0 = read_imageui(src0_q, q_base).x;
)"
R"(        regQ.s1 = read_imageui(src0_q, q_base + ne01).x;
)"
R"(        regQ.s2 = read_imageui(src0_q, q_base + ne01 * 2).x;
)"
R"(        regQ.s3 = read_imageui(src0_q, q_base + ne01 * 3).x;
)"
R"(
)"
R"(        uint qh_grp = ib * 4;
)"
R"(        uint qh_word = (uint)src0_qh[(qh_grp + 0) * ne01 + i01]
)"
R"(                      | ((uint)src0_qh[(qh_grp + 1) * ne01 + i01] << 8)
)"
R"(                      | ((uint)src0_qh[(qh_grp + 2) * ne01 + i01] << 16)
)"
R"(                      | ((uint)src0_qh[(qh_grp + 3) * ne01 + i01] << 24);
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
R"(        float4 y4;
)"
R"(        y4.s0 = SGB_BC(y_local.s0, 4); y4.s1 = SGB_BC(y_local.s1, 4);
)"
R"(        y4.s2 = SGB_BC(y_local.s2, 4); y4.s3 = SGB_BC(y_local.s3, 4);
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
R"(        float8 fp32x8 = q5_k_to_fp32_packed8(as_ushort2(regQ.s0), qh_word & 0xFF, scale, minv);
)"
R"(        float4 acc = y0 * fp32x8.lo;
)"
R"(        acc += y1 * fp32x8.hi;
)"
R"(
)"
R"(        fp32x8 = q5_k_to_fp32_packed8(as_ushort2(regQ.s1), (qh_word >> 8) & 0xFF, scale, minv);
)"
R"(        acc += y2 * fp32x8.lo;
)"
R"(        acc += y3 * fp32x8.hi;
)"
R"(
)"
R"(        fp32x8 = q5_k_to_fp32_packed8(as_ushort2(regQ.s2), (qh_word >> 16) & 0xFF, scale, minv);
)"
R"(        acc += y4 * fp32x8.lo;
)"
R"(        acc += y5 * fp32x8.hi;
)"
R"(
)"
R"(        fp32x8 = q5_k_to_fp32_packed8(as_ushort2(regQ.s3), (qh_word >> 24) & 0xFF, scale, minv);
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
R"(    // reduction in local memory over N_SIMDGROUP subgroups
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
R"(        for (uint i = 0; i < N_SIMDGROUP - 1; ++i) {
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
