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
R"(// [dspark 2026-10-17] rusticl/ir3 subgroup queries LIE: get_max_sub_group_size()
)"
R"(// and get_sub_group_size() return the static device max (128 on FD740) regardless
)"
R"(// of dispatch, while shuffle/reduce act on the real active lanes. Effective
)"
R"(// subgroup size for stride loops is therefore min(max, local_size(0)); on vendor
)"
R"(// Adreno the qcom attr pins max=64==local so the macro degenerates to max.
)"
R"(#ifdef GGML_GENERIC_SUBGROUP_SHUFFLE
)"
R"(#define GGML_EFF_SGS (uint)((get_max_sub_group_size() < (uint)get_local_size(0)) ? get_max_sub_group_size() : (uint)get_local_size(0))
)"
R"(#else
)"
R"(#define GGML_EFF_SGS get_max_sub_group_size()
)"
R"(#endif
)"
R"(
)"
R"(
)"
R"(#define N_F16_F16 4
)"
R"(
)"
R"(#ifdef ADRENO_GPU
)"
R"(REQD_SUBGROUP_SIZE_64
)"
R"(#endif
)"
R"(kernel void kernel_mul_mat_f16_f16(
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
R"(        int r3)
)"
R"({
)"
R"(    src0 = (global char*)((global char*)src0 + offset0);
)"
R"(    src1 = (global char*)((global char*)src1 + offset1);
)"
R"(    dst = (global float*)((global char*)dst + offsetd);
)"
R"(
)"
R"(    int r0 = get_group_id(0);
)"
R"(    int rb = get_group_id(1)*N_F16_F16;
)"
R"(    int im = get_group_id(2);
)"
R"(
)"
R"(    int i12 = im%ne12;
)"
R"(    int i13 = im/ne12;
)"
R"(
)"
R"(    ulong offset_src0 = r0*nb01 + (i12/r2)*nb02 + (i13/r3)*nb03;
)"
R"(
)"
R"(    global half * x = (global half *) (src0 + offset_src0);
)"
R"(
)"
R"(    // The vector path below casts the row pointers to half4, which must be 8-byte aligned.
)"
R"(    // A row address is r0*nb01 + ..., and a permuted or strided src leaves nb01/nb11
)"
R"(    // unconstrained -- an odd ne00, say, gives a row that is only 2-byte aligned. Every
)"
R"(    // src1 row this work-item walks is src1_base + r1*nb11, so require both.
)"
R"(    const ulong src1_base  = (ulong) (src1 + (i12)*nb12 + (i13)*nb13);
)"
R"(    const bool  row_aligned = (((ulong) x) & 7) == 0 && (src1_base & 7) == 0 && (nb11 & 7) == 0;
)"
R"(
)"
R"(    if (ne00 < 128 || !row_aligned) {
)"
R"(        for (int row = 0; row < N_F16_F16; ++row) {
)"
R"(            int r1 = rb + row;
)"
R"(            if (r1 >= ne11) {
)"
R"(                break;
)"
R"(            }
)"
R"(
)"
R"(            ulong offset_src1 = r1*nb11 + (i12   )*nb12 + (i13   )*nb13;
)"
R"(
)"
R"(            global half * y = (global half *) (src1 + offset_src1);
)"
R"(
)"
R"(            float sumf = 0;
)"
R"(            for (int i = get_sub_group_local_id(); i < ne00; i += GGML_EFF_SGS) {
)"
R"(                sumf += (half) x[i] * (half) y[i];
)"
R"(            }
)"
R"(
)"
R"(            float all_sum = sub_group_reduce_add(sumf);
)"
R"(            if (get_sub_group_local_id() == 0) {
)"
R"(                dst[im*ne1*ne0 + r1*ne0 + r0] = all_sum;
)"
R"(            }
)"
R"(        }
)"
R"(    } else {
)"
R"(        global half4 * x4 = (global half4 *)x;
)"
R"(        for (int row = 0; row < N_F16_F16; ++row) {
)"
R"(            int r1 = rb + row;
)"
R"(            if (r1 >= ne11) {
)"
R"(                break;
)"
R"(            }
)"
R"(
)"
R"(            ulong offset_src1 = r1*nb11 + (i12   )*nb12 + (i13   )*nb13;
)"
R"(
)"
R"(            global half  * y  = (global half  *) (src1 + offset_src1);
)"
R"(            global half4 * y4 = (global half4 *) y;
)"
R"(
)"
R"(            float sumf = 0;
)"
R"(            for (int i = get_sub_group_local_id(); i < ne00/4; i += GGML_EFF_SGS) {
)"
R"(                sumf += (half) x4[i].s0 * y4[i].s0;
)"
R"(                sumf += (half) x4[i].s1 * y4[i].s1;
)"
R"(                sumf += (half) x4[i].s2 * y4[i].s2;
)"
R"(                sumf += (half) x4[i].s3 * y4[i].s3;
)"
R"(            }
)"
R"(
)"
R"(            float all_sum = sub_group_reduce_add(sumf);
)"
R"(            if (get_sub_group_local_id() == 0) {
)"
R"(                for (int i = 4*(ne00/4); i < ne00; ++i) {
)"
R"(                    all_sum += (half) x[i] * y[i];
)"
R"(                }
)"
R"(                dst[im*ne1*ne0 + r1*ne0 + r0] = all_sum;
)"
R"(            }
)"
R"(        }
)"
R"(    }
)"
R"(}
)"
