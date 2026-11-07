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
R"(//------------------------------------------------------------------------------
)"
R"(// rms_norm
)"
R"(//------------------------------------------------------------------------------
)"
R"(// This kernel depends on subgroup size.
)"
R"(#ifdef INTEL_GPU
)"
R"(REQD_SUBGROUP_SIZE_32
)"
R"(#elif defined (ADRENO_GPU)
)"
R"(REQD_SUBGROUP_SIZE_64
)"
R"(#endif
)"
R"(kernel void kernel_rms_norm(
)"
R"(        global void * src0,
)"
R"(        ulong offset0,
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
R"(        int ne03,
)"
R"(        ulong nb01,
)"
R"(        ulong nb02,
)"
R"(        ulong nb03,
)"
R"(        float eps,
)"
R"(        local float * sum // Note, the size depends on number of subgroups
)"
R"() {
)"
R"(    src0 = (global void*)((global char*)src0 + offset0);
)"
R"(    dst = (global float*)((global char*)dst + offsetd);
)"
R"(
)"
R"(    int i03 = get_group_id(2);
)"
R"(    int i02 = get_group_id(1);
)"
R"(    int i01 = get_group_id(0);
)"
R"(
)"
R"(    global float4 * x = (global float4 *) ((global char *) src0 + i03*nb03 + i02*nb02 + i01*nb01);
)"
R"(    global float * x_scalar = (global float *) x;
)"
R"(    float4 sumf = 0;
)"
R"(    float all_sum = 0;
)"
R"(
)"
R"(    // parallel sum
)"
R"(    for (int i00 = get_local_id(0); i00 < ne00/4; i00 += get_local_size(0)) {
)"
R"(        sumf += x[i00] * x[i00];
)"
R"(    }
)"
R"(    all_sum = sumf.s0 + sumf.s1 + sumf.s2 + sumf.s3;
)"
R"(    all_sum = sub_group_reduce_add(all_sum);
)"
R"(    if (get_sub_group_local_id() == 0) {
)"
R"(        sum[get_sub_group_id()] = all_sum;
)"
R"(    }
)"
R"(
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(    // broadcast
)"
R"(    for (uint i = get_local_size(0) / get_sub_group_size() / 2; i > 0; i /= 2) {
)"
R"(       if (get_local_id(0) < i) {
)"
R"(           sum[get_local_id(0)] += sum[get_local_id(0) + i];
)"
R"(       }
)"
R"(    }
)"
R"(    if (get_local_id(0) == 0) {
)"
R"(        for (int i = 4 * (ne00 / 4); i < ne00; i++) {
)"
R"(            sum[0] += x_scalar[i];
)"
R"(        }
)"
R"(        sum[0] /= ne00;
)"
R"(    }
)"
R"(
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(    const float mean  = sum[0];
)"
R"(    const float scale = 1.0f/sqrt(mean + eps);
)"
R"(
)"
R"(    global float4 * y = (global float4 *) (dst + i03*ne02*ne01*ne00 + i02*ne01*ne00 + i01*ne00);
)"
R"(    global float * y_scalar = (global float *) y;
)"
R"(    for (int i00 = get_local_id(0); i00 < ne00/4; i00 += get_local_size(0)) {
)"
R"(        y[i00] = x[i00] * scale;
)"
R"(    }
)"
R"(    if (get_local_id(0) == 0) {
)"
R"(        for (int i00 = 4 * (ne00 / 4); i00 < ne00; i00++) {
)"
R"(            y_scalar[i00] = x_scalar[i00] * scale;
)"
R"(        }
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(//------------------------------------------------------------------------------
)"
R"(// rms_norm_mul
)"
R"(//------------------------------------------------------------------------------
)"
R"(#ifdef INTEL_GPU
)"
R"(REQD_SUBGROUP_SIZE_32
)"
R"(#elif defined (ADRENO_GPU)
)"
R"(REQD_SUBGROUP_SIZE_64
)"
R"(#endif
)"
R"(kernel void kernel_rms_norm_mul(
)"
R"(        global char * src0,
)"
R"(        ulong offset0,
)"
R"(        global char * src1,
)"
R"(        ulong offset1,
)"
R"(        global char * dst,
)"
R"(        ulong offsetd,
)"
R"(        int ne00,
)"
R"(        int ne01,
)"
R"(        int ne02,
)"
R"(        int ne03,
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
R"(        int ne13,
)"
R"(        ulong nb11,
)"
R"(        ulong nb12,
)"
R"(        ulong nb13,
)"
R"(        ulong nb1,
)"
R"(        ulong nb2,
)"
R"(        ulong nb3,
)"
R"(        float eps,
)"
R"(        local float * sum
)"
R"() {
)"
R"(    src0 = src0 + offset0;
)"
R"(    src1 = src1 + offset1;
)"
R"(    dst  = dst  + offsetd;
)"
R"(
)"
R"(    // [dspark 2026-10-18] One workgroup per row: i01 = get_group_id(0) indexes
)"
R"(    // dst rows and y writes dst + i01*nb1. If the enqueue wrapper clamps local
)"
R"(    // below nth (CL_DEVICE_MAX_WORK_ITEM_SIZES[0] < CL_KERNEL_WORK_GROUP_SIZE,
)"
R"(    // e.g. 1024 vs 2048 on rusticl/FD740), the workgroup count exceeds ne01 and
)"
R"(    // the surplus groups read src0 + i01*nb01 and write dst + i01*nb1 out of
)"
R"(    // bounds. Make surplus groups no-ops.
)"
R"(    if (get_group_id(0) >= (uint)ne01 || get_group_id(1) >= (uint)ne02 || get_group_id(2) >= (uint)ne03) {
)"
R"(        return;
)"
R"(    }
)"
R"(
)"
R"(    // The size of sum is sizeof(float)*subgroup_size.
)"
R"(    // Each subgroup writes its partial sum to this array.
)"
R"(    // So the number of subgroups per workgroup for this kernel cannot exceed the subgroup size.
)"
R"(    // This is generally true -
)"
R"(    // for subgroup size 64, workgroup size should be less than 4096 (the max is usually 1024).
)"
R"(    // [dspark 2026-10-18] A/B: original subgroup-0 zero fill restored (see
)"
R"(    // git history for the in-bounds variant that coincided with a decode
)"
R"(    // regression). NOTE: when the backend ignores qcom_reqd_sub_group_size
)"
R"(    // and native sgs > 64, this writes past the 64-float local allocation.
)"
R"(    if (get_sub_group_id() == 0) {
)"
R"(        sum[get_sub_group_local_id()] = 0.0f;
)"
R"(    }
)"
R"(
)"
R"(    int i03 = get_group_id(2);
)"
R"(    int i02 = get_group_id(1);
)"
R"(    int i01 = get_group_id(0);
)"
R"(
)"
R"(    global float4 * x = (global float4 *) (src0 + i03*nb03 + i02*nb02 + i01*nb01);
)"
R"(    global float4 * f = (global float4 *) (src1 + (i03%ne13)*nb13 + (i02%ne12)*nb12 + (i01%ne11)*nb11);
)"
R"(
)"
R"(    float sumf = 0;
)"
R"(
)"
R"(    // parallel sum
)"
R"(    for (int i00 = get_local_id(0); i00 < ne00/4; i00 += get_local_size(0)) {
)"
R"(        sumf += dot(x[i00], x[i00]);
)"
R"(    }
)"
R"(    sumf = sub_group_reduce_add(sumf);
)"
R"(
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(    if (get_sub_group_local_id() == 0) {
)"
R"(        sum[get_sub_group_id()] = sumf;
)"
R"(    }
)"
R"(
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(    //for (uint i = get_local_size(0) / get_sub_group_size() / 2; i > 0; i /= 2) {
)"
R"(    //   if (get_local_id(0) < i) {
)"
R"(    //       sum[get_local_id(0)] += sum[get_local_id(0) + i];
)"
R"(    //   }
)"
R"(    //}
)"
R"(    //if (get_local_id(0) == 0) {
)"
R"(    //    sum[0] /= ne00;
)"
R"(    //}
)"
R"(
)"
R"(    //barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(    sumf = sum[get_sub_group_local_id()];
)"
R"(    sumf = sub_group_reduce_add(sumf);
)"
R"(
)"
R"(    float mean  = sumf / ne00;
)"
R"(    float scale = 1.0f/sqrt(mean + eps);
)"
R"(
)"
R"(    global float4 * y = (global float4 *) (dst + i03*nb3 + i02*nb2 + i01*nb1);
)"
R"(    for (int i00 = get_local_id(0); i00 < ne00/4; i00 += get_local_size(0)) {
)"
R"(        y[i00] = (x[i00] * scale) * f[i00%(ne10/4)];
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(//------------------------------------------------------------------------------
)"
R"(// rms_norm + mul (norm weight) + add (residual), fused. Mirrors
)"
R"(// kernel_rms_norm_mul with an extra residual operand src2: computes
)"
R"(//   y = (rmsnorm(x) * w) + g
)"
R"(// in one dispatch, removing one kernel launch + one global round-trip per
)"
R"(// residual block (the dominant per-layer adjacency on Gemma matformers).
)"
R"(//------------------------------------------------------------------------------
)"
R"(kernel void kernel_rms_norm_mul_add(
)"
R"(        global char * src0,
)"
R"(        ulong offset0,
)"
R"(        global char * src1,
)"
R"(        ulong offset1,
)"
R"(        global char * src2,
)"
R"(        ulong offset2,
)"
R"(        global char * dst,
)"
R"(        ulong offsetd,
)"
R"(        int ne00,
)"
R"(        int ne01,
)"
R"(        int ne02,
)"
R"(        int ne03,
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
R"(        int ne13,
)"
R"(        ulong nb11,
)"
R"(        ulong nb12,
)"
R"(        ulong nb13,
)"
R"(        int ne20,
)"
R"(        int ne21,
)"
R"(        int ne22,
)"
R"(        int ne23,
)"
R"(        ulong nb21,
)"
R"(        ulong nb22,
)"
R"(        ulong nb23,
)"
R"(        ulong nb1,
)"
R"(        ulong nb2,
)"
R"(        ulong nb3,
)"
R"(        float eps,
)"
R"(        local float * sum
)"
R"() {
)"
R"(    src0 = src0 + offset0;
)"
R"(    src1 = src1 + offset1;
)"
R"(    src2 = src2 + offset2;
)"
R"(    dst  = dst  + offsetd;
)"
R"(
)"
R"(    // [dspark 2026-10-18] Row-per-group invariant guard, see kernel_rms_norm_mul.
)"
R"(    if (get_group_id(0) >= (uint)ne01 || get_group_id(1) >= (uint)ne02 || get_group_id(2) >= (uint)ne03) {
)"
R"(        return;
)"
R"(    }
)"
R"(
)"
R"(    // [dspark 2026-10-18] A/B: original subgroup-0 zero fill restored (see
)"
R"(    // git history for the in-bounds variant that coincided with a decode
)"
R"(    // regression). NOTE: when the backend ignores qcom_reqd_sub_group_size
)"
R"(    // and native sgs > 64, this writes past the 64-float local allocation.
)"
R"(    if (get_sub_group_id() == 0) {
)"
R"(        sum[get_sub_group_local_id()] = 0.0f;
)"
R"(    }
)"
R"(
)"
R"(    int i03 = get_group_id(2);
)"
R"(    int i02 = get_group_id(1);
)"
R"(    int i01 = get_group_id(0);
)"
R"(
)"
R"(    global float4 * x = (global float4 *) (src0 + i03*nb03 + i02*nb02 + i01*nb01);
)"
R"(    global float4 * f = (global float4 *) (src1 + (i03%ne13)*nb13 + (i02%ne12)*nb12 + (i01%ne11)*nb11);
)"
R"(    global float4 * g = (global float4 *) (src2 + (i03%ne23)*nb23 + (i02%ne22)*nb22 + (i01%ne21)*nb21);
)"
R"(
)"
R"(    float sumf = 0;
)"
R"(
)"
R"(    for (int i00 = get_local_id(0); i00 < ne00/4; i00 += get_local_size(0)) {
)"
R"(        sumf += dot(x[i00], x[i00]);
)"
R"(    }
)"
R"(    sumf = sub_group_reduce_add(sumf);
)"
R"(
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(    if (get_sub_group_local_id() == 0) {
)"
R"(        sum[get_sub_group_id()] = sumf;
)"
R"(    }
)"
R"(
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(    sumf = sum[get_sub_group_local_id()];
)"
R"(    sumf = sub_group_reduce_add(sumf);
)"
R"(
)"
R"(    float mean  = sumf / ne00;
)"
R"(    float scale = 1.0f/sqrt(mean + eps);
)"
R"(
)"
R"(    global float4 * y = (global float4 *) (dst + i03*nb3 + i02*nb2 + i01*nb1);
)"
R"(    for (int i00 = get_local_id(0); i00 < ne00/4; i00 += get_local_size(0)) {
)"
R"(        y[i00] = (x[i00] * scale) * f[i00%(ne10/4)] + g[i00%(ne20/4)];
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(//------------------------------------------------------------------------------
)"
R"(// rms_norm + mul(norm weight) + add(residual) + mul(scalar scale), fused.
)"
R"(// Computes y = ((rmsnorm(x) * w) + g) * s, where s is a broadcast SCALAR (e.g.
)"
R"(// Gemma-4 layer_output_scale). Folds the trailing per-layer l_out scale-mul into
)"
R"(// the residual-norm kernel: one extra dispatch + global round-trip saved per
)"
R"(// layer. src3 points at the single scale value.
)"
R"(//------------------------------------------------------------------------------
)"
R"(kernel void kernel_rms_norm_mul_add_scale(
)"
R"(        global char * src0,
)"
R"(        ulong offset0,
)"
R"(        global char * src1,
)"
R"(        ulong offset1,
)"
R"(        global char * src2,
)"
R"(        ulong offset2,
)"
R"(        global char * src3,
)"
R"(        ulong offset3,
)"
R"(        global char * dst,
)"
R"(        ulong offsetd,
)"
R"(        int ne00,
)"
R"(        int ne01,
)"
R"(        int ne02,
)"
R"(        int ne03,
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
R"(        int ne13,
)"
R"(        ulong nb11,
)"
R"(        ulong nb12,
)"
R"(        ulong nb13,
)"
R"(        int ne20,
)"
R"(        int ne21,
)"
R"(        int ne22,
)"
R"(        int ne23,
)"
R"(        ulong nb21,
)"
R"(        ulong nb22,
)"
R"(        ulong nb23,
)"
R"(        ulong nb1,
)"
R"(        ulong nb2,
)"
R"(        ulong nb3,
)"
R"(        float eps,
)"
R"(        local float * sum
)"
R"() {
)"
R"(    src0 = src0 + offset0;
)"
R"(    src1 = src1 + offset1;
)"
R"(    src2 = src2 + offset2;
)"
R"(    src3 = src3 + offset3;
)"
R"(    dst  = dst  + offsetd;
)"
R"(
)"
R"(    // [dspark 2026-10-18] Row-per-group invariant guard, see kernel_rms_norm_mul.
)"
R"(    if (get_group_id(0) >= (uint)ne01 || get_group_id(1) >= (uint)ne02 || get_group_id(2) >= (uint)ne03) {
)"
R"(        return;
)"
R"(    }
)"
R"(
)"
R"(    const float sc = *((global float *) src3);
)"
R"(
)"
R"(    // [dspark 2026-10-18] A/B: original subgroup-0 zero fill restored (see
)"
R"(    // git history for the in-bounds variant that coincided with a decode
)"
R"(    // regression). NOTE: when the backend ignores qcom_reqd_sub_group_size
)"
R"(    // and native sgs > 64, this writes past the 64-float local allocation.
)"
R"(    if (get_sub_group_id() == 0) {
)"
R"(        sum[get_sub_group_local_id()] = 0.0f;
)"
R"(    }
)"
R"(
)"
R"(    int i03 = get_group_id(2);
)"
R"(    int i02 = get_group_id(1);
)"
R"(    int i01 = get_group_id(0);
)"
R"(
)"
R"(    global float4 * x = (global float4 *) (src0 + i03*nb03 + i02*nb02 + i01*nb01);
)"
R"(    global float4 * f = (global float4 *) (src1 + (i03%ne13)*nb13 + (i02%ne12)*nb12 + (i01%ne11)*nb11);
)"
R"(    global float4 * g = (global float4 *) (src2 + (i03%ne23)*nb23 + (i02%ne22)*nb22 + (i01%ne21)*nb21);
)"
R"(
)"
R"(    float sumf = 0;
)"
R"(
)"
R"(    for (int i00 = get_local_id(0); i00 < ne00/4; i00 += get_local_size(0)) {
)"
R"(        sumf += dot(x[i00], x[i00]);
)"
R"(    }
)"
R"(    sumf = sub_group_reduce_add(sumf);
)"
R"(
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(    if (get_sub_group_local_id() == 0) {
)"
R"(        sum[get_sub_group_id()] = sumf;
)"
R"(    }
)"
R"(
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(    sumf = sum[get_sub_group_local_id()];
)"
R"(    sumf = sub_group_reduce_add(sumf);
)"
R"(
)"
R"(    float mean  = sumf / ne00;
)"
R"(    float scale = 1.0f/sqrt(mean + eps);
)"
R"(
)"
R"(    global float4 * y = (global float4 *) (dst + i03*nb3 + i02*nb2 + i01*nb1);
)"
R"(    for (int i00 = get_local_id(0); i00 < ne00/4; i00 += get_local_size(0)) {
)"
R"(        y[i00] = ((x[i00] * scale) * f[i00%(ne10/4)] + g[i00%(ne20/4)]) * sc;
)"
R"(    }
)"
R"(}
)"
