R"(#pragma OPENCL EXTENSION cl_khr_fp16 : enable
)"
R"(
)"
R"(#ifdef cl_intel_subgroups
)"
R"(#pragma OPENCL EXTENSION cl_intel_subgroups : enable
)"
R"(#else
)"
R"(#pragma OPENCL EXTENSION cl_khr_subgroups : enable
)"
R"(#endif
)"
R"(
)"
R"(#ifdef cl_intel_required_subgroup_size
)"
R"(#pragma OPENCL EXTENSION cl_intel_required_subgroup_size : enable
)"
R"(#define INTEL_GPU 1
)"
R"(#define REQD_SUBGROUP_SIZE_16 __attribute__((intel_reqd_sub_group_size(16)))
)"
R"(#define REQD_SUBGROUP_SIZE_32 __attribute__((intel_reqd_sub_group_size(32)))
)"
R"(#elif defined(cl_qcom_reqd_sub_group_size)
)"
R"(#pragma OPENCL EXTENSION cl_qcom_reqd_sub_group_size : enable
)"
R"(#define ADRENO_GPU 1
)"
R"(#define REQD_SUBGROUP_SIZE_64  __attribute__((qcom_reqd_sub_group_size("half")))
)"
R"(#define REQD_SUBGROUP_SIZE_128 __attribute__((qcom_reqd_sub_group_size("full")))
)"
R"(#endif
)"
R"(
)"
R"(// Multi-row f16xf32 GEMV for the DECODE path (single token, ne11*ne12 small).
)"
R"(// The legacy kernel_mul_mat_f16_f32_1row runs ONE 64-lane subgroup per workgroup =
)"
R"(// one output row per WG, which caps memory-level parallelism at roughly half of
)"
R"(// LPDDR5x peak. This variant packs MROW subgroups per workgroup, each
)"
R"(// computing a distinct output row, so a WG keeps 64*MROW loads in flight. The
)"
R"(// activation column y (shared by every output row) is staged into __local ONCE per
)"
R"(// WG and reused across the MROW rows, cutting redundant activation reads. Used for
)"
R"(// the f16 attention projections (Q/K/V/O) and lm_head, which dominate decode.
)"
R"(// Numerically equivalent to _1row (same f16->f32 widening, same float4 partial sums,
)"
R"(// same subgroup-reduce order), so byte-identical to the per-op path.
)"
R"(
)"
R"(#define MROW 16
)"
R"(
)"
R"(#ifdef ADRENO_GPU
)"
R"(REQD_SUBGROUP_SIZE_64
)"
R"(#endif
)"
R"(kernel void kernel_mul_mat_f16_f32_mrow(
)"
R"(        global char * src0,
)"
R"(        ulong offset0,
)"
R"(        global char * src1,
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
R"(        ulong nb00,
)"
R"(        ulong nb01,
)"
R"(        ulong nb02,
)"
R"(        ulong nb03,
)"
R"(        int ne10,
)"
R"(        int ne11,
)"
R"(        int ne12,
)"
R"(        ulong nb10,
)"
R"(        ulong nb11,
)"
R"(        ulong nb12,
)"
R"(        ulong nb13,
)"
R"(        int ne0,
)"
R"(        int ne1,
)"
R"(        int r2,
)"
R"(        int r3,
)"
R"(        __local float * ysh
)"
R"() {
)"
R"(    src0 = (global char*)((global char*)src0 + offset0);
)"
R"(    src1 = (global char*)((global char*)src1 + offset1);
)"
R"(    dst  = (global float*)((global char*)dst + offsetd);
)"
R"(
)"
R"(    int r0   = get_group_id(0) * MROW + get_local_id(1);  // output row
)"
R"(    int r1   = get_group_id(1);                            // token (ne11)
)"
R"(    int im   = get_group_id(2);
)"
R"(    int lid  = get_sub_group_local_id();                   // 0..63
)"
R"(    int nsg  = get_local_size(1);                          // == MROW
)"
R"(
)"
R"(    int i12 = im % ne12;
)"
R"(    int i13 = im / ne12;
)"
R"(
)"
R"(    ulong offset_src1 = r1*nb11 + (i12)*nb12 + (i13)*nb13;
)"
R"(    global float * y = (global float *) (src1 + offset_src1);
)"
R"(
)"
R"(    // Cooperatively stage the activation column (ne00 floats) into __local once per
)"
R"(    // WG and reuse across the MROW rows. Staging is the actual win here: dropping it
)"
R"(    // (each subgroup re-reading y from global) regresses below the 1-row kernel.
)"
R"(    for (int i = get_local_id(1)*get_sub_group_size() + lid; i < ne00; i += nsg*get_sub_group_size()) {
)"
R"(        ysh[i] = y[i];
)"
R"(    }
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(    if (r0 >= ne01) {
)"
R"(        return;
)"
R"(    }
)"
R"(
)"
R"(    ulong offset_src0 = r0*nb01 + (i12/r2)*nb02 + (i13/r3)*nb03;
)"
R"(    global half * x = (global half *) (src0 + offset_src0);
)"
R"(
)"
R"(    // The vector path below casts the row pointer to half4, which must be 8-byte aligned.
)"
R"(    // A row address is r0*nb01 + ..., and a permuted or strided src0 leaves nb01/nb02/nb03
)"
R"(    // unconstrained -- ne00 % 4 == 0 bounds the element count per row, not the byte stride
)"
R"(    // between rows. Take the vector path only when this work-item's row is actually
)"
R"(    // aligned; the scalar loop below has no such requirement.
)"
R"(    const bool row_aligned = (((ulong) x) & 7) == 0;
)"
R"(
)"
R"(    float sumf = 0.0f;
)"
R"(    if (ne00 < 128 || !row_aligned) {
)"
R"(        for (int i = lid; i < ne00; i += get_sub_group_size()) {
)"
R"(            sumf += (float) x[i] * ysh[i];
)"
R"(        }
)"
R"(        float all_sum = sub_group_reduce_add(sumf);
)"
R"(        if (lid == 0) {
)"
R"(            dst[im*ne1*ne0 + r1*ne0 + r0] = all_sum;
)"
R"(        }
)"
R"(    } else {
)"
R"(        global half4 * x4 = (global half4 *) x;
)"
R"(        __local float4 * ysh4 = (__local float4 *) ysh;
)"
R"(        for (int i = lid; i < ne00/4; i += get_sub_group_size()) {
)"
R"(            float4 yv = ysh4[i];
)"
R"(            sumf += (float) x4[i].s0 * yv.s0;
)"
R"(            sumf += (float) x4[i].s1 * yv.s1;
)"
R"(            sumf += (float) x4[i].s2 * yv.s2;
)"
R"(            sumf += (float) x4[i].s3 * yv.s3;
)"
R"(        }
)"
R"(        float all_sum = sub_group_reduce_add(sumf);
)"
R"(        if (lid == 0) {
)"
R"(            for (int i = 4*(ne00/4); i < ne00; ++i) {
)"
R"(                all_sum += (float) x[i] * ysh[i];
)"
R"(            }
)"
R"(            dst[im*ne1*ne0 + r1*ne0 + r0] = all_sum;
)"
R"(        }
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(// Register-blocked variant: each 64-lane subgroup accumulates RPT consecutive
)"
R"(// output rows instead of one. The staged activation is reused across all RPT rows,
)"
R"(// and each lane keeps RPT independent weight loads in flight per column step ->
)"
R"(// more memory-level parallelism on the streaming f16 weight read (the BW limiter),
)"
R"(// plus RPT fewer staging barriers per output row. Per-row reduction order is
)"
R"(// identical to _mrow, so byte-identical to the per-op path. Dispatch guarantees
)"
R"(// ne00 >= 128 and ne00 % 4 == 0, so only the half4 path is needed (no tail).
)"
R"(#define MROW_RB_BODY(RPT)                                                                 \
)"
R"(    src0 = (global char*)((global char*)src0 + offset0);                                  \
)"
R"(    src1 = (global char*)((global char*)src1 + offset1);                                  \
)"
R"(    dst  = (global float*)((global char*)dst + offsetd);                                  \
)"
R"(    int r0b = (get_group_id(0) * get_local_size(1) + get_local_id(1)) * (RPT);            \
)"
R"(    int r1  = get_group_id(1);                                                            \
)"
R"(    int im  = get_group_id(2);                                                            \
)"
R"(    int lid = get_sub_group_local_id();                                                   \
)"
R"(    int nsg = get_local_size(1);                                                          \
)"
R"(    int i12 = im % ne12;                                                                  \
)"
R"(    int i13 = im / ne12;                                                                  \
)"
R"(    ulong off_y = r1*nb11 + i12*nb12 + i13*nb13;                                          \
)"
R"(    global float * y = (global float *) (src1 + off_y);                                   \
)"
R"(    for (int i = get_local_id(1)*get_sub_group_size() + lid; i < ne00;                    \
)"
R"(         i += nsg*get_sub_group_size()) {                                                 \
)"
R"(        ysh[i] = y[i];                                                                    \
)"
R"(    }                                                                                     \
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);                                                         \
)"
R"(    __local float4 * ysh4 = (__local float4 *) ysh;                                       \
)"
R"(    global half4 * xr[RPT];                                                               \
)"
R"(    _Pragma("unroll")                                                                     \
)"
R"(    for (int rr = 0; rr < (RPT); ++rr) {                                                  \
)"
R"(        int row = r0b + rr;                                                               \
)"
R"(        if (row > ne01 - 1) row = ne01 - 1;                                               \
)"
R"(        xr[rr] = (global half4 *) (src0 + (ulong)row*nb01 + (i12/r2)*nb02 + (i13/r3)*nb03); \
)"
R"(    }                                                                                     \
)"
R"(    float sumf[RPT];                                                                      \
)"
R"(    _Pragma("unroll")                                                                     \
)"
R"(    for (int rr = 0; rr < (RPT); ++rr) sumf[rr] = 0.0f;                                   \
)"
R"(    for (int i = lid; i < ne00/4; i += get_sub_group_size()) {                            \
)"
R"(        float4 yv = ysh4[i];                                                              \
)"
R"(        _Pragma("unroll")                                                                 \
)"
R"(        for (int rr = 0; rr < (RPT); ++rr) {                                              \
)"
R"(            half4 xv = xr[rr][i];                                                         \
)"
R"(            sumf[rr] += (float) xv.s0 * yv.s0 + (float) xv.s1 * yv.s1                      \
)"
R"(                      + (float) xv.s2 * yv.s2 + (float) xv.s3 * yv.s3;                     \
)"
R"(        }                                                                                 \
)"
R"(    }                                                                                     \
)"
R"(    _Pragma("unroll")                                                                     \
)"
R"(    for (int rr = 0; rr < (RPT); ++rr) {                                                  \
)"
R"(        float s = sub_group_reduce_add(sumf[rr]);                                         \
)"
R"(        int row = r0b + rr;                                                               \
)"
R"(        if (lid == 0 && row < ne01) {                                                     \
)"
R"(            dst[im*ne1*ne0 + r1*ne0 + row] = s;                                           \
)"
R"(        }                                                                                 \
)"
R"(    }
)"
R"(
)"
R"(// half8 (128-bit) load variant: Adreno's load/store unit issues 128-bit
)"
R"(// transactions, so half4 (64-bit) loads may leave the load path half-idle. This
)"
R"(// processes 8 weight elements per lane per step via half8. Accumulation groups
)"
R"(// elements in 8s rather than 4s, so it is NOT bit-identical to _1row (float add is
)"
R"(// non-associative) -- experimental BW probe, gate on ne00 % 8 == 0.
)"
R"(#define MROW_H8_BODY(RPT)                                                                 \
)"
R"(    src0 = (global char*)((global char*)src0 + offset0);                                  \
)"
R"(    src1 = (global char*)((global char*)src1 + offset1);                                  \
)"
R"(    dst  = (global float*)((global char*)dst + offsetd);                                  \
)"
R"(    int r0b = (get_group_id(0) * get_local_size(1) + get_local_id(1)) * (RPT);            \
)"
R"(    int r1  = get_group_id(1);                                                            \
)"
R"(    int im  = get_group_id(2);                                                            \
)"
R"(    int lid = get_sub_group_local_id();                                                   \
)"
R"(    int nsg = get_local_size(1);                                                          \
)"
R"(    int i12 = im % ne12;                                                                  \
)"
R"(    int i13 = im / ne12;                                                                  \
)"
R"(    ulong off_y = r1*nb11 + i12*nb12 + i13*nb13;                                          \
)"
R"(    global float * y = (global float *) (src1 + off_y);                                   \
)"
R"(    for (int i = get_local_id(1)*get_sub_group_size() + lid; i < ne00;                    \
)"
R"(         i += nsg*get_sub_group_size()) {                                                 \
)"
R"(        ysh[i] = y[i];                                                                    \
)"
R"(    }                                                                                     \
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);                                                         \
)"
R"(    __local float4 * ysh4 = (__local float4 *) ysh;                                       \
)"
R"(    global half8 * xr[RPT];                                                               \
)"
R"(    _Pragma("unroll")                                                                     \
)"
R"(    for (int rr = 0; rr < (RPT); ++rr) {                                                  \
)"
R"(        int row = r0b + rr;                                                               \
)"
R"(        if (row > ne01 - 1) row = ne01 - 1;                                               \
)"
R"(        xr[rr] = (global half8 *) (src0 + (ulong)row*nb01 + (i12/r2)*nb02 + (i13/r3)*nb03); \
)"
R"(    }                                                                                     \
)"
R"(    float sumf[RPT];                                                                      \
)"
R"(    _Pragma("unroll")                                                                     \
)"
R"(    for (int rr = 0; rr < (RPT); ++rr) sumf[rr] = 0.0f;                                   \
)"
R"(    for (int i = lid; i < ne00/8; i += get_sub_group_size()) {                            \
)"
R"(        float4 y0 = ysh4[2*i];                                                            \
)"
R"(        float4 y1 = ysh4[2*i + 1];                                                        \
)"
R"(        _Pragma("unroll")                                                                 \
)"
R"(        for (int rr = 0; rr < (RPT); ++rr) {                                              \
)"
R"(            half8 xv = xr[rr][i];                                                         \
)"
R"(            sumf[rr] += (float) xv.s0 * y0.s0 + (float) xv.s1 * y0.s1                      \
)"
R"(                      + (float) xv.s2 * y0.s2 + (float) xv.s3 * y0.s3                      \
)"
R"(                      + (float) xv.s4 * y1.s0 + (float) xv.s5 * y1.s1                      \
)"
R"(                      + (float) xv.s6 * y1.s2 + (float) xv.s7 * y1.s3;                     \
)"
R"(        }                                                                                 \
)"
R"(    }                                                                                     \
)"
R"(    _Pragma("unroll")                                                                     \
)"
R"(    for (int rr = 0; rr < (RPT); ++rr) {                                                  \
)"
R"(        float s = sub_group_reduce_add(sumf[rr]);                                         \
)"
R"(        int row = r0b + rr;                                                               \
)"
R"(        if (lid == 0 && row < ne01) {                                                     \
)"
R"(            dst[im*ne1*ne0 + r1*ne0 + row] = s;                                           \
)"
R"(        }                                                                                 \
)"
R"(    }
)"
R"(
)"
R"(#ifdef ADRENO_GPU
)"
R"(REQD_SUBGROUP_SIZE_64
)"
R"(#endif
)"
R"(kernel void kernel_mul_mat_f16_f32_mrow_h8(
)"
R"(        global char * src0, ulong offset0,
)"
R"(        global char * src1, ulong offset1,
)"
R"(        global float * dst, ulong offsetd,
)"
R"(        int ne00, int ne01, int ne02,
)"
R"(        ulong nb00, ulong nb01, ulong nb02, ulong nb03,
)"
R"(        int ne10, int ne11, int ne12,
)"
R"(        ulong nb10, ulong nb11, ulong nb12, ulong nb13,
)"
R"(        int ne0, int ne1, int r2, int r3,
)"
R"(        __local float * ysh
)"
R"() {
)"
R"(    MROW_H8_BODY(1)
)"
R"(}
)"
R"(
)"
R"(#ifdef ADRENO_GPU
)"
R"(REQD_SUBGROUP_SIZE_64
)"
R"(#endif
)"
R"(kernel void kernel_mul_mat_f16_f32_mrow_h8r2(
)"
R"(        global char * src0, ulong offset0,
)"
R"(        global char * src1, ulong offset1,
)"
R"(        global float * dst, ulong offsetd,
)"
R"(        int ne00, int ne01, int ne02,
)"
R"(        ulong nb00, ulong nb01, ulong nb02, ulong nb03,
)"
R"(        int ne10, int ne11, int ne12,
)"
R"(        ulong nb10, ulong nb11, ulong nb12, ulong nb13,
)"
R"(        int ne0, int ne1, int r2, int r3,
)"
R"(        __local float * ysh
)"
R"() {
)"
R"(    MROW_H8_BODY(2)
)"
R"(}
)"
R"(
)"
R"(#ifdef ADRENO_GPU
)"
R"(REQD_SUBGROUP_SIZE_64
)"
R"(#endif
)"
R"(kernel void kernel_mul_mat_f16_f32_mrow_r2(
)"
R"(        global char * src0, ulong offset0,
)"
R"(        global char * src1, ulong offset1,
)"
R"(        global float * dst, ulong offsetd,
)"
R"(        int ne00, int ne01, int ne02,
)"
R"(        ulong nb00, ulong nb01, ulong nb02, ulong nb03,
)"
R"(        int ne10, int ne11, int ne12,
)"
R"(        ulong nb10, ulong nb11, ulong nb12, ulong nb13,
)"
R"(        int ne0, int ne1, int r2, int r3,
)"
R"(        __local float * ysh
)"
R"() {
)"
R"(    MROW_RB_BODY(2)
)"
R"(}
)"
R"(
)"
R"(#ifdef ADRENO_GPU
)"
R"(REQD_SUBGROUP_SIZE_64
)"
R"(#endif
)"
R"(kernel void kernel_mul_mat_f16_f32_mrow_r4(
)"
R"(        global char * src0, ulong offset0,
)"
R"(        global char * src1, ulong offset1,
)"
R"(        global float * dst, ulong offsetd,
)"
R"(        int ne00, int ne01, int ne02,
)"
R"(        ulong nb00, ulong nb01, ulong nb02, ulong nb03,
)"
R"(        int ne10, int ne11, int ne12,
)"
R"(        ulong nb10, ulong nb11, ulong nb12, ulong nb13,
)"
R"(        int ne0, int ne1, int r2, int r3,
)"
R"(        __local float * ysh
)"
R"() {
)"
R"(    MROW_RB_BODY(4)
)"
R"(}
)"
