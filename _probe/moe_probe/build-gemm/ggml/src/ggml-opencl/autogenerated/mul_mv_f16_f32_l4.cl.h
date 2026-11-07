R"(#pragma OPENCL EXTENSION cl_khr_fp16 : enable
)"
R"(
)"
R"(// NOTE: do NOT #define CLK_SUB_GROUP_SHUFFLE_WIDTH_WAVE_SIZE_QCOM here (or via
)"
R"(// -D). rusticl predefines cl_qcom_subgroup_shuffle and its injected header
)"
R"(// declares the width enum; shadowing it with a plain integer makes the real
)"
R"(// qcom shuffle builtin reject the width ("valid Width ... is [CLK_...]").
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
R"(#ifdef cl_khr_subgroup_shuffle
)"
R"(#pragma OPENCL EXTENSION cl_khr_subgroup_shuffle : enable
)"
R"(#define HAS_SUBGROUP_SHUFFLE 1
)"
R"(#elif defined(cl_qcom_subgroup_shuffle)
)"
R"(#pragma OPENCL EXTENSION cl_qcom_subgroup_shuffle : enable
)"
R"(#define HAS_SUBGROUP_SHUFFLE 1
)"
R"(// Adreno compilers that expose only cl_qcom_subgroup_shuffle do not declare the KHR
)"
R"(// name, so calling it is an implicit declaration and the program fails to build.
)"
R"(// Route it to the qcom builtin.
)"
R"(#define sub_group_shuffle_xor(val, mask) qcom_sub_group_shuffle_xor((val), (mask), CLK_SUB_GROUP_SHUFFLE_WIDTH_WAVE_SIZE_QCOM, 0.0f)
)"
R"(#endif
)"
R"(
)"
R"(// Assumes row size (ne00) is a multiple of 4
)"
R"(#ifdef ADRENO_GPU
)"
R"(REQD_SUBGROUP_SIZE_64
)"
R"(#endif
)"
R"(kernel void kernel_mul_mat_f16_f32_l4(
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
R"(        int r3
)"
R"() {
)"
R"(    src0 = (global char*)((global char*)src0 + offset0);
)"
R"(    src1 = (global char*)((global char*)src1 + offset1);
)"
R"(    dst = (global float*)((global char*)dst + offsetd);
)"
R"(
)"
R"(    int nrows = ne11;
)"
R"(    int r0 = get_group_id(0);
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
R"(    global half4 * x4 = (global half4 *) (src0 + offset_src0);
)"
R"(
)"
R"(    for (int r1 = 0; r1 < nrows; ++r1) {
)"
R"(        ulong offset_src1 = r1*nb11 + (i12   )*nb12 + (i13   )*nb13;
)"
R"(
)"
R"(        global float4 * y4 = (global float4 *) (src1 + offset_src1);
)"
R"(
)"
R"(        float sumf = 0;
)"
R"(        for (int i = get_sub_group_local_id(); i < ne00/4; i += GGML_EFF_SGS) {
)"
R"(            sumf += convert_float(x4[i].s0) * y4[i].s0;
)"
R"(            sumf += convert_float(x4[i].s1) * y4[i].s1;
)"
R"(            sumf += convert_float(x4[i].s2) * y4[i].s2;
)"
R"(            sumf += convert_float(x4[i].s3) * y4[i].s3;
)"
R"(        }
)"
R"(
)"
R"(        float all_sum = sub_group_reduce_add(sumf);
)"
R"(        if (get_sub_group_local_id() == 0) {
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
R"(// Each subgroup produces DR_NDST outputs, assumes ne11 == 1
)"
R"(#define MUL_MAT_F16_F32_L4_DR_NDST 4
)"
R"(
)"
R"(#ifdef ADRENO_GPU
)"
R"(REQD_SUBGROUP_SIZE_64
)"
R"(#endif
)"
R"(kernel void kernel_mul_mat_f16_f32_l4_dr(
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
R"(        int r3
)"
R"() {
)"
R"(    src0 = (global char*)((global char*)src0 + offset0);
)"
R"(    src1 = (global char*)((global char*)src1 + offset1);
)"
R"(    dst  = (global float*)((global char*)dst  + offsetd);
)"
R"(
)"
R"(    const int r0_base = get_group_id(0) * MUL_MAT_F16_F32_L4_DR_NDST;
)"
R"(    const int im      = get_group_id(2);
)"
R"(
)"
R"(    const int i12 = im % ne12;
)"
R"(    const int i13 = im / ne12;
)"
R"(
)"
R"(    // assume ne11 == 1
)"
R"(    const ulong offset_src1 = i12*nb12 + i13*nb13;
)"
R"(    global float4 * y4 = (global float4 *)(src1 + offset_src1);
)"
R"(
)"
R"(    global half4 * x4[MUL_MAT_F16_F32_L4_DR_NDST];
)"
R"(    float          sumf[MUL_MAT_F16_F32_L4_DR_NDST];
)"
R"(
)"
R"(    const ulong   k_head_off = (i12/r2)*nb02 + (i13/r3)*nb03;
)"
R"(
)"
R"(    #pragma unroll
)"
R"(    for (int n = 0; n < MUL_MAT_F16_F32_L4_DR_NDST; ++n) {
)"
R"(        int       r0   = r0_base + n;
)"
R"(        int       r0c  = r0 < ne01 ? r0 : 0;
)"
R"(        ulong     off  = (ulong)r0c*nb01 + k_head_off;
)"
R"(        x4[n]   = (global half4 *)(src0 + off);
)"
R"(        sumf[n] = 0.0f;
)"
R"(    }
)"
R"(
)"
R"(    const int n_chunks = ne00 / 4;
)"
R"(    const int sg_size  = GGML_EFF_SGS;
)"
R"(    const int lid      = get_sub_group_local_id();
)"
R"(
)"
R"(    for (int i = lid; i < n_chunks; i += sg_size) {
)"
R"(        float4 q = y4[i];
)"
R"(        #pragma unroll
)"
R"(        for (int n = 0; n < MUL_MAT_F16_F32_L4_DR_NDST; ++n) {
)"
R"(            float4 k = convert_float4(x4[n][i]);
)"
R"(            sumf[n] = mad(k.s0, q.s0, sumf[n]);
)"
R"(            sumf[n] = mad(k.s1, q.s1, sumf[n]);
)"
R"(            sumf[n] = mad(k.s2, q.s2, sumf[n]);
)"
R"(            sumf[n] = mad(k.s3, q.s3, sumf[n]);
)"
R"(        }
)"
R"(    }
)"
R"(
)"
R"(    #pragma unroll
)"
R"(    for (int n = 0; n < MUL_MAT_F16_F32_L4_DR_NDST; ++n) {
)"
R"(        float reduced = sub_group_reduce_add(sumf[n]);
)"
R"(        int   r0      = r0_base + n;
)"
R"(        if (lid == 0 && r0 < ne01) {
)"
R"(            dst[im*ne1*ne0 + r0] = reduced;
)"
R"(        }
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(// Kernels for decoding, Adreno only for now
)"
R"(#define MUL_MAT_F16_F32_L4_DR_LS_R2_MAX 8
)"
R"(
)"
R"(#ifdef ADRENO_GPU
)"
R"(#if !defined(GGML_GENERIC_SUBGROUP_SHUFFLE)
)"
R"(#pragma OPENCL EXTENSION cl_qcom_subgroup_shuffle : enable
)"
R"(#define sub_group_shuffle_xor(val, mask) qcom_sub_group_shuffle_xor((val), (mask), CLK_SUB_GROUP_SHUFFLE_WIDTH_WAVE_SIZE_QCOM, 0.0f)
)"
R"(#endif
)"
R"(// [dspark 2026-10-16] GGML_GENERIC_SUBGROUP_SHUFFLE (rusticl/freedreno): no
)"
R"(// qcom shuffle builtin; use the core CL 3.0 sub_group_shuffle_xor directly.
)"
R"(
)"
R"(REQD_SUBGROUP_SIZE_64
)"
R"(kernel void kernel_mul_mat_f16_f32_l4_dr_ls(
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
R"(        int r3
)"
R"() {
)"
R"(    src0 = (global char*)((global char*)src0 + offset0);
)"
R"(    src1 = (global char*)((global char*)src1 + offset1);
)"
R"(    dst  = (global float*)((global char*)dst  + offsetd);
)"
R"(
)"
R"(    const int r0_base = get_group_id(0) * 2;
)"
R"(    const int kv_grp  = get_group_id(2);   // KV head group; im = kv_grp*r2 + q
)"
R"(
)"
R"(    const int i12_kv = kv_grp % ne02;
)"
R"(    const int i13_kv = kv_grp / ne02;
)"
R"(
)"
R"(    const int lid     = get_sub_group_local_id();
)"
R"(    const int subhalf = lid >> 5;          // 0 or 1 (which K row in the WG)
)"
R"(    const int intra   = lid & 31;          // 0..31 (lane within the half)
)"
R"(
)"
R"(    const int r0  = r0_base + subhalf;
)"
R"(    const int r0c = r0 < ne01 ? r0 : 0;    // clamp OOB to row 0; skip write below
)"
R"(
)"
R"(    // K row pointer for this lane (one K row per half-wave).
)"
R"(    const ulong k_off = (ulong)r0c*nb01 + (ulong)i12_kv*nb02 + (ulong)i13_kv*nb03;
)"
R"(    global half4 * x4 = (global half4 *)(src0 + k_off);
)"
R"(
)"
R"(    global float4 * y4[MUL_MAT_F16_F32_L4_DR_LS_R2_MAX];
)"
R"(    #pragma unroll
)"
R"(    for (int q = 0; q < MUL_MAT_F16_F32_L4_DR_LS_R2_MAX; ++q) {
)"
R"(        const int i12_q = i12_kv*r2 + q;
)"
R"(        const ulong q_off = (ulong)i12_q*nb12 + (ulong)i13_kv*nb13;
)"
R"(        y4[q] = (global float4 *)(src1 + q_off);
)"
R"(    }
)"
R"(
)"
R"(    float partial[MUL_MAT_F16_F32_L4_DR_LS_R2_MAX];
)"
R"(    #pragma unroll
)"
R"(    for (int q = 0; q < MUL_MAT_F16_F32_L4_DR_LS_R2_MAX; ++q) {
)"
R"(        partial[q] = 0.0f;
)"
R"(    }
)"
R"(
)"
R"(    const int n_chunks = ne00 / 4;
)"
R"(
)"
R"(    for (int i = intra; i < n_chunks; i += 32) {
)"
R"(        float4 k = convert_float4(x4[i]);
)"
R"(
)"
R"(        #pragma unroll
)"
R"(        for (int q = 0; q < MUL_MAT_F16_F32_L4_DR_LS_R2_MAX; ++q) {
)"
R"(            if (q < r2) {
)"
R"(                float4 v = y4[q][i];
)"
R"(                partial[q] = mad(k.s0, v.s0, partial[q]);
)"
R"(                partial[q] = mad(k.s1, v.s1, partial[q]);
)"
R"(                partial[q] = mad(k.s2, v.s2, partial[q]);
)"
R"(                partial[q] = mad(k.s3, v.s3, partial[q]);
)"
R"(            }
)"
R"(        }
)"
R"(    }
)"
R"(
)"
R"(    // half-wave reduction
)"
R"(    #pragma unroll
)"
R"(    for (int q = 0; q < MUL_MAT_F16_F32_L4_DR_LS_R2_MAX; ++q) {
)"
R"(        if (q < r2) {
)"
R"(            partial[q] += sub_group_shuffle_xor(partial[q],  1u);
)"
R"(            partial[q] += sub_group_shuffle_xor(partial[q],  2u);
)"
R"(            partial[q] += sub_group_shuffle_xor(partial[q],  4u);
)"
R"(            partial[q] += sub_group_shuffle_xor(partial[q],  8u);
)"
R"(            partial[q] += sub_group_shuffle_xor(partial[q], 16u);
)"
R"(        }
)"
R"(    }
)"
R"(
)"
R"(    if (intra == 0 && r0 < ne01) {
)"
R"(        #pragma unroll
)"
R"(        for (int q = 0; q < MUL_MAT_F16_F32_L4_DR_LS_R2_MAX; ++q) {
)"
R"(            if (q < r2) {
)"
R"(                const int im = i12_kv*r2 + q + i13_kv*ne12;
)"
R"(                dst[im*ne1*ne0 + r0] = partial[q];
)"
R"(            }
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
R"(kernel void kernel_mul_mat_f16_f32_l4_dr_lq(
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
R"(        int r3
)"
R"() {
)"
R"(    src0 = (global char*)((global char*)src0 + offset0);
)"
R"(    src1 = (global char*)((global char*)src1 + offset1);
)"
R"(    dst  = (global float*)((global char*)dst  + offsetd);
)"
R"(
)"
R"(    const int r0_base = get_group_id(0) * 4;
)"
R"(    const int kv_grp  = get_group_id(2);
)"
R"(
)"
R"(    const int i12_kv = kv_grp % ne02;
)"
R"(    const int i13_kv = kv_grp / ne02;
)"
R"(
)"
R"(    const int lid   = get_sub_group_local_id();
)"
R"(    const int subq  = lid >> 4;            // 0..3 (which K row)
)"
R"(    const int intra = lid & 15;            // 0..15 (lane within quarter)
)"
R"(
)"
R"(    const int r0  = r0_base + subq;
)"
R"(    const int r0c = r0 < ne01 ? r0 : 0;
)"
R"(
)"
R"(    const ulong k_off = (ulong)r0c*nb01 + (ulong)i12_kv*nb02 + (ulong)i13_kv*nb03;
)"
R"(    global half4 * x4 = (global half4 *)(src0 + k_off);
)"
R"(
)"
R"(    global float4 * y4[MUL_MAT_F16_F32_L4_DR_LS_R2_MAX];
)"
R"(    #pragma unroll
)"
R"(    for (int q = 0; q < MUL_MAT_F16_F32_L4_DR_LS_R2_MAX; ++q) {
)"
R"(        const int i12_q = i12_kv*r2 + q;
)"
R"(        const ulong q_off = (ulong)i12_q*nb12 + (ulong)i13_kv*nb13;
)"
R"(        y4[q] = (global float4 *)(src1 + q_off);
)"
R"(    }
)"
R"(
)"
R"(    float partial[MUL_MAT_F16_F32_L4_DR_LS_R2_MAX];
)"
R"(    #pragma unroll
)"
R"(    for (int q = 0; q < MUL_MAT_F16_F32_L4_DR_LS_R2_MAX; ++q) {
)"
R"(        partial[q] = 0.0f;
)"
R"(    }
)"
R"(
)"
R"(    const int n_chunks = ne00 / 4;
)"
R"(
)"
R"(    for (int i = intra; i < n_chunks; i += 16) {
)"
R"(        float4 k = convert_float4(x4[i]);
)"
R"(
)"
R"(        #pragma unroll
)"
R"(        for (int q = 0; q < MUL_MAT_F16_F32_L4_DR_LS_R2_MAX; ++q) {
)"
R"(            if (q < r2) {
)"
R"(                float4 v = y4[q][i];
)"
R"(                partial[q] = mad(k.s0, v.s0, partial[q]);
)"
R"(                partial[q] = mad(k.s1, v.s1, partial[q]);
)"
R"(                partial[q] = mad(k.s2, v.s2, partial[q]);
)"
R"(                partial[q] = mad(k.s3, v.s3, partial[q]);
)"
R"(            }
)"
R"(        }
)"
R"(    }
)"
R"(
)"
R"(    // quarter-wave reduction
)"
R"(    #pragma unroll
)"
R"(    for (int q = 0; q < MUL_MAT_F16_F32_L4_DR_LS_R2_MAX; ++q) {
)"
R"(        if (q < r2) {
)"
R"(            partial[q] += sub_group_shuffle_xor(partial[q], 1u);
)"
R"(            partial[q] += sub_group_shuffle_xor(partial[q], 2u);
)"
R"(            partial[q] += sub_group_shuffle_xor(partial[q], 4u);
)"
R"(            partial[q] += sub_group_shuffle_xor(partial[q], 8u);
)"
R"(        }
)"
R"(    }
)"
R"(
)"
R"(    if (intra == 0 && r0 < ne01) {
)"
R"(        #pragma unroll
)"
R"(        for (int q = 0; q < MUL_MAT_F16_F32_L4_DR_LS_R2_MAX; ++q) {
)"
R"(            if (q < r2) {
)"
R"(                const int im = i12_kv*r2 + q + i13_kv*ne12;
)"
R"(                dst[im*ne1*ne0 + r0] = partial[q];
)"
R"(            }
)"
R"(        }
)"
R"(    }
)"
R"(}
)"
R"(#endif // ADRENO_GPU
)"
R"(
)"
R"(#define N_ROWS_PER_WG 8
)"
R"(#define N_OUTS_PER_WG 8
)"
R"(
)"
R"(#ifdef ADRENO_GPU
)"
R"(REQD_SUBGROUP_SIZE_64
)"
R"(#endif
)"
R"(kernel void kernel_mul_mat_f16_f32_l4_x8(
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
R"(        int r3
)"
R"() {
)"
R"(    src0 = (global char *)((global char *)src0 + offset0);
)"
R"(    src1 = (global char *)((global char *)src1 + offset1);
)"
R"(    dst  = (global float*)((global char *)dst  + offsetd);
)"
R"(
)"
R"(    const int sgs_lid = get_sub_group_local_id();
)"
R"(    const int sgs_sz  = GGML_EFF_SGS;
)"
R"(
)"
R"(    const int r0_base = get_group_id(0) * N_ROWS_PER_WG;
)"
R"(    const int im      = get_group_id(2);
)"
R"(
)"
R"(    const int i12 = im % ne12;
)"
R"(    const int i13 = im / ne12;
)"
R"(
)"
R"(    const ulong offset_src1 = (i12) * nb12 + (i13) * nb13;
)"
R"(    global float4 * y4 = (global float4 *)(src1 + offset_src1);
)"
R"(
)"
R"(    __local float4 q_loc[64];   // ne00/4 max for sub_group_size 64
)"
R"(    if (sgs_lid < ne00 / 4) {
)"
R"(        q_loc[sgs_lid] = y4[sgs_lid];
)"
R"(    }
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(    #pragma unroll
)"
R"(    for (int dr = 0; dr < N_ROWS_PER_WG; ++dr) {
)"
R"(        const int r0 = r0_base + dr;
)"
R"(        if (r0 >= ne01) return;
)"
R"(
)"
R"(        const ulong offset_src0 = r0 * nb01 + (i12 / r2) * nb02 + (i13 / r3) * nb03;
)"
R"(        global half4 * x4 = (global half4 *)(src0 + offset_src0);
)"
R"(
)"
R"(        float sumf = 0.0f;
)"
R"(        for (int i = sgs_lid; i < ne00 / 4; i += sgs_sz) {
)"
R"(            const half4   k4 = x4[i];
)"
R"(            const float4  q  = q_loc[i];
)"
R"(            sumf += convert_float(k4.s0) * q.s0
)"
R"(                  + convert_float(k4.s1) * q.s1
)"
R"(                  + convert_float(k4.s2) * q.s2
)"
R"(                  + convert_float(k4.s3) * q.s3;
)"
R"(        }
)"
R"(
)"
R"(        const float all_sum = sub_group_reduce_add(sumf);
)"
R"(        if (sgs_lid == 0) {
)"
R"(            dst[im * ne1 * ne0 + r0] = all_sum;  // ne11 == 1, so r1==0
)"
R"(        }
)"
R"(    }
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
R"(kernel void kernel_mul_mat_f16_f32_l4_y8(
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
R"(        int r3
)"
R"() {
)"
R"(    src0 = (global char *)((global char *)src0 + offset0);
)"
R"(    src1 = (global char *)((global char *)src1 + offset1);
)"
R"(    dst  = (global float*)((global char *)dst  + offsetd);
)"
R"(
)"
R"(    const int sgs_lid = get_sub_group_local_id();
)"
R"(    const int sgs_sz  = GGML_EFF_SGS;
)"
R"(
)"
R"(    const int r0_base = get_group_id(0) * N_OUTS_PER_WG;
)"
R"(    const int im      = get_group_id(2);
)"
R"(
)"
R"(    const int i12 = im % ne12;
)"
R"(    const int i13 = im / ne12;
)"
R"(
)"
R"(    const ulong offset_src1 = (i12) * nb12 + (i13) * nb13;
)"
R"(    global float4 * y4 = (global float4 *)(src1 + offset_src1);
)"
R"(
)"
R"(    global half4 * x4_o[N_OUTS_PER_WG];
)"
R"(    #pragma unroll
)"
R"(    for (int o = 0; o < N_OUTS_PER_WG; ++o) {
)"
R"(        const int r0 = r0_base + o;
)"
R"(        const int r0c = (r0 < ne01) ? r0 : 0;
)"
R"(        const ulong off = r0c * nb01 + (i12 / r2) * nb02 + (i13 / r3) * nb03;
)"
R"(        x4_o[o] = (global half4 *)(src0 + off);
)"
R"(    }
)"
R"(
)"
R"(    float sum[N_OUTS_PER_WG] = { 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f };
)"
R"(
)"
R"(    for (int i = sgs_lid; i < ne00 / 4; i += sgs_sz) {
)"
R"(        const float4 q4 = y4[i];
)"
R"(        #pragma unroll
)"
R"(        for (int o = 0; o < N_OUTS_PER_WG; ++o) {
)"
R"(            const half4 v4 = x4_o[o][i];
)"
R"(            sum[o] += convert_float(v4.s0) * q4.s0
)"
R"(                    + convert_float(v4.s1) * q4.s1
)"
R"(                    + convert_float(v4.s2) * q4.s2
)"
R"(                    + convert_float(v4.s3) * q4.s3;
)"
R"(        }
)"
R"(    }
)"
R"(
)"
R"(    #pragma unroll
)"
R"(    for (int o = 0; o < N_OUTS_PER_WG; ++o) {
)"
R"(        const int r0 = r0_base + o;
)"
R"(        const float s = sub_group_reduce_add(sum[o]);
)"
R"(        if (sgs_lid == 0 && r0 < ne01) {
)"
R"(            dst[im * ne1 * ne0 + r0] = s;
)"
R"(        }
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(#define N_OUTS_PAIR  8
)"
R"(#define N_PAIRS_PAIR (N_OUTS_PAIR / 2)
)"
R"(
)"
R"(#ifdef ADRENO_GPU
)"
R"(REQD_SUBGROUP_SIZE_64
)"
R"(#endif
)"
R"(kernel void kernel_mul_mat_f16_f32_l4_x8_pair(
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
R"(        int r3
)"
R"() {
)"
R"(    src0 = (global char *)((global char *)src0 + offset0);
)"
R"(    src1 = (global char *)((global char *)src1 + offset1);
)"
R"(    dst  = (global float*)((global char *)dst  + offsetd);
)"
R"(
)"
R"(    const int sgs_lid = get_sub_group_local_id();
)"
R"(    const int half_id = sgs_lid >> 5;     // 0 = lower half, 1 = upper half
)"
R"(    const int lane_h  = sgs_lid & 31;     // lane 0..31 within half
)"
R"(
)"
R"(    const int r0_base = get_group_id(0) * N_OUTS_PAIR;
)"
R"(    const int im      = get_group_id(2);
)"
R"(
)"
R"(    const int i12 = im % ne12;
)"
R"(    const int i13 = im / ne12;
)"
R"(
)"
R"(    const ulong offset_src1 = (i12) * nb12 + (i13) * nb13;
)"
R"(    global float4 * y4 = (global float4 *)(src1 + offset_src1);
)"
R"(
)"
R"(    __local float4 q_loc[64];   // ne00/4 max for sub_group_size 64
)"
R"(    if (sgs_lid < ne00 / 4) {
)"
R"(        q_loc[sgs_lid] = y4[sgs_lid];
)"
R"(    }
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(    const int dk_vec = ne00 / 4;
)"
R"(
)"
R"(    #pragma unroll
)"
R"(    for (int p = 0; p < N_PAIRS_PAIR; ++p) {
)"
R"(        const int r0 = r0_base + 2 * p + half_id;
)"
R"(
)"
R"(        const ulong offset_src0 = r0 * nb01 + (i12 / r2) * nb02 + (i13 / r3) * nb03;
)"
R"(        global half4 * x4 = (global half4 *)(src0 + offset_src0);
)"
R"(
)"
R"(        float sumf = 0.0f;
)"
R"(        for (int i = lane_h; i < dk_vec; i += 32) {
)"
R"(            const half4  k4 = x4[i];
)"
R"(            const float4 q  = q_loc[i];
)"
R"(            sumf += convert_float(k4.s0) * q.s0
)"
R"(                  + convert_float(k4.s1) * q.s1
)"
R"(                  + convert_float(k4.s2) * q.s2
)"
R"(                  + convert_float(k4.s3) * q.s3;
)"
R"(        }
)"
R"(
)"
R"(        sumf += sub_group_shuffle_xor(sumf, 16);
)"
R"(        sumf += sub_group_shuffle_xor(sumf, 8);
)"
R"(        sumf += sub_group_shuffle_xor(sumf, 4);
)"
R"(        sumf += sub_group_shuffle_xor(sumf, 2);
)"
R"(        sumf += sub_group_shuffle_xor(sumf, 1);
)"
R"(
)"
R"(        if (lane_h == 0) {
)"
R"(            dst[im * ne1 * ne0 + r0] = sumf;
)"
R"(        }
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(#define N_K_ROWS_GQA   16
)"
R"(#define GQA_RATIO_GQA  8
)"
R"(#define LANES_PER_QH   8    // 64 / GQA_RATIO_GQA
)"
R"(#define DK_VEC_GQA     32   // DK / 4 for DK=128
)"
R"(
)"
R"(#ifdef ADRENO_GPU
)"
R"(REQD_SUBGROUP_SIZE_64
)"
R"(#endif
)"
R"(kernel void kernel_mul_mat_f16_f32_l4_x8_gqa4(
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
R"(        int r3
)"
R"() {
)"
R"(    src0 = (global char *)((global char *)src0 + offset0);
)"
R"(    src1 = (global char *)((global char *)src1 + offset1);
)"
R"(    dst  = (global float*)((global char *)dst  + offsetd);
)"
R"(
)"
R"(    const int sgs_lid = get_sub_group_local_id();
)"
R"(    const int q_id    = sgs_lid >> 3;       // 0..7: which Q-head (8 per WG)
)"
R"(    const int lane_q  = sgs_lid & 7;        // 0..7: lane within Q-head partition
)"
R"(
)"
R"(    const int r0_base = get_group_id(0) * N_K_ROWS_GQA;
)"
R"(    const int im_kv   = get_group_id(2);
)"
R"(
)"
R"(    const int i02 = im_kv % ne02;           // K-head index (also K2 batch)
)"
R"(    const int i03 = im_kv / ne02;           // n13 batch index
)"
R"(
)"
R"(    const int q_head_lo = i02 * GQA_RATIO_GQA;
)"
R"(
)"
R"(    __local float4 q_loc[GQA_RATIO_GQA * DK_VEC_GQA];   // 4 × 32 = 128 float4
)"
R"(    #pragma unroll
)"
R"(    for (int qh = 0; qh < GQA_RATIO_GQA; ++qh) {
)"
R"(        const int qh_idx = q_head_lo + qh;
)"
R"(        global float4 * y4 = (global float4 *)(src1 + qh_idx * nb12 + i03 * nb13);
)"
R"(
)"
R"(        if (sgs_lid < DK_VEC_GQA) {
)"
R"(            q_loc[qh * DK_VEC_GQA + sgs_lid] = y4[sgs_lid];
)"
R"(        }
)"
R"(    }
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(    // K base offset for this WG. All 8 K-rows × 4 Q-heads share this K-head.
)"
R"(    const ulong offset_src0_base = (i02) * nb02 + (i03 / r3) * nb03;
)"
R"(
)"
R"(    #pragma unroll
)"
R"(    for (int dr = 0; dr < N_K_ROWS_GQA; ++dr) {
)"
R"(        const int r0 = r0_base + dr;
)"
R"(
)"
R"(        const ulong offset_src0 = r0 * nb01 + offset_src0_base;
)"
R"(        global half4 * x4 = (global half4 *)(src0 + offset_src0);
)"
R"(
)"
R"(        float sumf = 0.0f;
)"
R"(        #pragma unroll
)"
R"(        for (int t = 0; t < 4; ++t) {
)"
R"(            const int i = lane_q + t * LANES_PER_QH;   // 8, 16, 24-step
)"
R"(            const half4  k4 = x4[i];
)"
R"(            const float4 q  = q_loc[q_id * DK_VEC_GQA + i];
)"
R"(            sumf += convert_float(k4.s0) * q.s0
)"
R"(                  + convert_float(k4.s1) * q.s1
)"
R"(                  + convert_float(k4.s2) * q.s2
)"
R"(                  + convert_float(k4.s3) * q.s3;
)"
R"(        }
)"
R"(
)"
R"(        sumf += sub_group_shuffle_xor(sumf, 4);
)"
R"(        sumf += sub_group_shuffle_xor(sumf, 2);
)"
R"(        sumf += sub_group_shuffle_xor(sumf, 1);
)"
R"(
)"
R"(        if (lane_q == 0) {
)"
R"(            const int im_out = i03 * ne12 + (q_head_lo + q_id);
)"
R"(            dst[im_out * ne1 * ne0 + r0] = sumf;
)"
R"(        }
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(#define N_DV_ROWS_Y8GQA  8
)"
R"(#define GQA_RATIO_Y8GQA  8
)"
R"(
)"
R"(#ifdef ADRENO_GPU
)"
R"(REQD_SUBGROUP_SIZE_64
)"
R"(#endif
)"
R"(kernel void kernel_mul_mat_f16_f32_l4_y8_gqa(
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
R"(        int r3
)"
R"() {
)"
R"(    src0 = (global char *)((global char *)src0 + offset0);
)"
R"(    src1 = (global char *)((global char *)src1 + offset1);
)"
R"(    dst  = (global float*)((global char *)dst  + offsetd);
)"
R"(
)"
R"(    const int sgs_lid = get_sub_group_local_id();
)"
R"(    const int sgs_sz  = GGML_EFF_SGS;
)"
R"(
)"
R"(    const int r0_base = get_group_id(0) * N_DV_ROWS_Y8GQA;
)"
R"(    const int im_kv   = get_group_id(2);
)"
R"(
)"
R"(    const int i02 = im_kv % ne02;           // K-head index
)"
R"(    const int i03 = im_kv / ne02;           // n13 batch index
)"
R"(
)"
R"(    // GQA Q-heads sharing this K-head.
)"
R"(    const int q_head_lo = i02 * GQA_RATIO_Y8GQA;
)"
R"(
)"
R"(    global float4 * y4_q[GQA_RATIO_Y8GQA];
)"
R"(    #pragma unroll
)"
R"(    for (int qh = 0; qh < GQA_RATIO_Y8GQA; ++qh) {
)"
R"(        const int qh_idx = q_head_lo + qh;
)"
R"(        y4_q[qh] = (global float4 *)(src1 + qh_idx * nb12 + i03 * nb13);
)"
R"(    }
)"
R"(
)"
R"(    global half4 * x4_o[N_DV_ROWS_Y8GQA];
)"
R"(    #pragma unroll
)"
R"(    for (int o = 0; o < N_DV_ROWS_Y8GQA; ++o) {
)"
R"(        const int r0 = r0_base + o;
)"
R"(        const int r0c = (r0 < ne01) ? r0 : 0;
)"
R"(        const ulong off = r0c * nb01 + (i02) * nb02 + (i03 / r3) * nb03;
)"
R"(        x4_o[o] = (global half4 *)(src0 + off);
)"
R"(    }
)"
R"(
)"
R"(    float sum[N_DV_ROWS_Y8GQA][GQA_RATIO_Y8GQA] = { {0.0f} };
)"
R"(
)"
R"(    for (int i = sgs_lid; i < ne00 / 4; i += sgs_sz) {
)"
R"(        // load 8 V values (one per DV row), same K-head, K-pos = i.
)"
R"(        half4 v[N_DV_ROWS_Y8GQA];
)"
R"(        #pragma unroll
)"
R"(        for (int o = 0; o < N_DV_ROWS_Y8GQA; ++o) {
)"
R"(            v[o] = x4_o[o][i];
)"
R"(        }
)"
R"(
)"
R"(        // load 8 softmax values (one per Q-head).
)"
R"(        float4 q[GQA_RATIO_Y8GQA];
)"
R"(        #pragma unroll
)"
R"(        for (int qh = 0; qh < GQA_RATIO_Y8GQA; ++qh) {
)"
R"(            q[qh] = y4_q[qh][i];
)"
R"(        }
)"
R"(
)"
R"(        #pragma unroll
)"
R"(        for (int o = 0; o < N_DV_ROWS_Y8GQA; ++o) {
)"
R"(            const float4 vf = (float4)(convert_float(v[o].s0),
)"
R"(                                       convert_float(v[o].s1),
)"
R"(                                       convert_float(v[o].s2),
)"
R"(                                       convert_float(v[o].s3));
)"
R"(            #pragma unroll
)"
R"(            for (int qh = 0; qh < GQA_RATIO_Y8GQA; ++qh) {
)"
R"(                sum[o][qh] += vf.s0 * q[qh].s0
)"
R"(                            + vf.s1 * q[qh].s1
)"
R"(                            + vf.s2 * q[qh].s2
)"
R"(                            + vf.s3 * q[qh].s3;
)"
R"(            }
)"
R"(        }
)"
R"(    }
)"
R"(
)"
R"(    #pragma unroll
)"
R"(    for (int o = 0; o < N_DV_ROWS_Y8GQA; ++o) {
)"
R"(        const int r0 = r0_base + o;
)"
R"(        #pragma unroll
)"
R"(        for (int qh = 0; qh < GQA_RATIO_Y8GQA; ++qh) {
)"
R"(            const float s = sub_group_reduce_add(sum[o][qh]);
)"
R"(            if (sgs_lid == 0 && r0 < ne01) {
)"
R"(                const int im_out = i03 * ne12 + (q_head_lo + qh);
)"
R"(                dst[im_out * ne1 * ne0 + r0] = s;
)"
R"(            }
)"
R"(        }
)"
R"(    }
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
R"(kernel void kernel_mul_mat_f16_f32_l4_x8_gqa4_img(
)"
R"(        __read_only image1d_buffer_t src0_img,
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
R"(        int r3
)"
R"() {
)"
R"(    src1 = (global char *)((global char *)src1 + offset1);
)"
R"(    dst  = (global float*)((global char *)dst  + offsetd);
)"
R"(
)"
R"(    const int sgs_lid = get_sub_group_local_id();
)"
R"(    const int q_id    = sgs_lid >> 3;       // 0..7: which Q-head (8 per WG)
)"
R"(    const int lane_q  = sgs_lid & 7;        // 0..7: lane within Q-head partition
)"
R"(
)"
R"(    const int r0_base = get_group_id(0) * N_K_ROWS_GQA;
)"
R"(    const int im_kv   = get_group_id(2);
)"
R"(
)"
R"(    const int i02 = im_kv % ne02;
)"
R"(    const int i03 = im_kv / ne02;
)"
R"(
)"
R"(    const int q_head_lo = i02 * GQA_RATIO_GQA;
)"
R"(
)"
R"(    __local float4 q_loc[GQA_RATIO_GQA * DK_VEC_GQA];
)"
R"(    #pragma unroll
)"
R"(    for (int qh = 0; qh < GQA_RATIO_GQA; ++qh) {
)"
R"(        const int qh_idx = q_head_lo + qh;
)"
R"(        global float4 * y4 = (global float4 *)(src1 + qh_idx * nb12 + i03 * nb13);
)"
R"(        if (sgs_lid < DK_VEC_GQA) {
)"
R"(            q_loc[qh * DK_VEC_GQA + sgs_lid] = y4[sgs_lid];
)"
R"(        }
)"
R"(    }
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(    const int pitch_px_row  = (int)(nb01 >> 4);
)"
R"(    const int pitch_px_head = (int)(nb02 >> 4);
)"
R"(    const int pitch_px_n13  = (int)(nb03 >> 4);
)"
R"(
)"
R"(    const int head_px_base = i02 * pitch_px_head + (i03 / r3) * pitch_px_n13;
)"
R"(
)"
R"(    #pragma unroll
)"
R"(    for (int dr = 0; dr < N_K_ROWS_GQA; ++dr) {
)"
R"(        const int r0 = r0_base + dr;
)"
R"(        const int row_px_base = r0 * pitch_px_row + head_px_base;
)"
R"(
)"
R"(        float sumf = 0.0f;
)"
R"(        #pragma unroll
)"
R"(        for (int t = 0; t < 2; ++t) {
)"
R"(            const int p = lane_q + t * LANES_PER_QH;          // pixel idx in row, 0..15
)"
R"(            const half8 k8 = as_half8(read_imagef(src0_img, row_px_base + p));
)"
R"(            const int   i0 = 2 * p;                            // first half4 idx
)"
R"(            const float4 qa = q_loc[q_id * DK_VEC_GQA + i0    ];
)"
R"(            const float4 qb = q_loc[q_id * DK_VEC_GQA + i0 + 1];
)"
R"(            sumf += convert_float(k8.s0) * qa.s0
)"
R"(                  + convert_float(k8.s1) * qa.s1
)"
R"(                  + convert_float(k8.s2) * qa.s2
)"
R"(                  + convert_float(k8.s3) * qa.s3
)"
R"(                  + convert_float(k8.s4) * qb.s0
)"
R"(                  + convert_float(k8.s5) * qb.s1
)"
R"(                  + convert_float(k8.s6) * qb.s2
)"
R"(                  + convert_float(k8.s7) * qb.s3;
)"
R"(        }
)"
R"(
)"
R"(        sumf += sub_group_shuffle_xor(sumf, 4);
)"
R"(        sumf += sub_group_shuffle_xor(sumf, 2);
)"
R"(        sumf += sub_group_shuffle_xor(sumf, 1);
)"
R"(
)"
R"(        if (lane_q == 0) {
)"
R"(            const int im_out = i03 * ne12 + (q_head_lo + q_id);
)"
R"(            dst[im_out * ne1 * ne0 + r0] = sumf;
)"
R"(        }
)"
R"(    }
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
R"(kernel void kernel_mul_mat_f16_f32_l4_y8_gqa_img(
)"
R"(        __read_only image1d_buffer_t src0_img,
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
R"(        int r3
)"
R"() {
)"
R"(    src1 = (global char *)((global char *)src1 + offset1);
)"
R"(    dst  = (global float*)((global char *)dst  + offsetd);
)"
R"(
)"
R"(    const int sgs_lid = get_sub_group_local_id();
)"
R"(    const int sgs_sz  = GGML_EFF_SGS;
)"
R"(
)"
R"(    const int r0_base = get_group_id(0) * N_DV_ROWS_Y8GQA;
)"
R"(    const int im_kv   = get_group_id(2);
)"
R"(
)"
R"(    const int i02 = im_kv % ne02;
)"
R"(    const int i03 = im_kv / ne02;
)"
R"(
)"
R"(    const int q_head_lo = i02 * GQA_RATIO_Y8GQA;
)"
R"(
)"
R"(    // Q (= softmax(KQ)) base pointers per Q-head
)"
R"(    global float4 * y4_q[GQA_RATIO_Y8GQA];
)"
R"(    #pragma unroll
)"
R"(    for (int qh = 0; qh < GQA_RATIO_Y8GQA; ++qh) {
)"
R"(        const int qh_idx = q_head_lo + qh;
)"
R"(        y4_q[qh] = (global float4 *)(src1 + qh_idx * nb12 + i03 * nb13);
)"
R"(    }
)"
R"(
)"
R"(    const int pitch_px_row  = (int)(nb01 >> 3);
)"
R"(    const int pitch_px_head = (int)(nb02 >> 3);
)"
R"(    const int pitch_px_n13  = (int)(nb03 >> 3);
)"
R"(
)"
R"(    const int head_px_base = i02 * pitch_px_head + (i03 / r3) * pitch_px_n13;
)"
R"(
)"
R"(    // per-DV-row pixel base
)"
R"(    int row_px_base[N_DV_ROWS_Y8GQA];
)"
R"(    #pragma unroll
)"
R"(    for (int o = 0; o < N_DV_ROWS_Y8GQA; ++o) {
)"
R"(        const int r0  = r0_base + o;
)"
R"(        const int r0c = (r0 < ne01) ? r0 : 0;
)"
R"(        row_px_base[o] = r0c * pitch_px_row + head_px_base;
)"
R"(    }
)"
R"(
)"
R"(    float sum[N_DV_ROWS_Y8GQA][GQA_RATIO_Y8GQA] = { {0.0f} };
)"
R"(
)"
R"(    for (int i = sgs_lid; i < ne00 / 4; i += sgs_sz) {
)"
R"(        half4 v[N_DV_ROWS_Y8GQA];
)"
R"(
)"
R"(        #pragma unroll
)"
R"(        for (int o = 0; o < N_DV_ROWS_Y8GQA; ++o) {
)"
R"(            v[o] = read_imageh(src0_img, row_px_base[o] + i);
)"
R"(        }
)"
R"(
)"
R"(        float4 q[GQA_RATIO_Y8GQA];
)"
R"(        #pragma unroll
)"
R"(        for (int qh = 0; qh < GQA_RATIO_Y8GQA; ++qh) {
)"
R"(            q[qh] = y4_q[qh][i];
)"
R"(        }
)"
R"(        // 64 mads.
)"
R"(        #pragma unroll
)"
R"(        for (int o = 0; o < N_DV_ROWS_Y8GQA; ++o) {
)"
R"(            const float4 vf = (float4)(convert_float(v[o].s0),
)"
R"(                                       convert_float(v[o].s1),
)"
R"(                                       convert_float(v[o].s2),
)"
R"(                                       convert_float(v[o].s3));
)"
R"(            #pragma unroll
)"
R"(            for (int qh = 0; qh < GQA_RATIO_Y8GQA; ++qh) {
)"
R"(                sum[o][qh] += vf.s0 * q[qh].s0
)"
R"(                            + vf.s1 * q[qh].s1
)"
R"(                            + vf.s2 * q[qh].s2
)"
R"(                            + vf.s3 * q[qh].s3;
)"
R"(            }
)"
R"(        }
)"
R"(    }
)"
R"(
)"
R"(    #pragma unroll
)"
R"(    for (int o = 0; o < N_DV_ROWS_Y8GQA; ++o) {
)"
R"(        const int r0 = r0_base + o;
)"
R"(        #pragma unroll
)"
R"(        for (int qh = 0; qh < GQA_RATIO_Y8GQA; ++qh) {
)"
R"(            const float s = sub_group_reduce_add(sum[o][qh]);
)"
R"(            if (sgs_lid == 0 && r0 < ne01) {
)"
R"(                const int im_out = i03 * ne12 + (q_head_lo + qh);
)"
R"(                dst[im_out * ne1 * ne0 + r0] = s;
)"
R"(            }
)"
R"(        }
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(#define N_K_ROWS_GQA_R4   16
)"
R"(#define GQA_RATIO_R4      4
)"
R"(#define LANES_PER_QH_R4   16    // = 64 / GQA_RATIO_R4
)"
R"(#define DK_VEC_R4         32    // DK / 4 for DK=128
)"
R"(
)"
R"(#ifdef ADRENO_GPU
)"
R"(REQD_SUBGROUP_SIZE_64
)"
R"(#endif
)"
R"(kernel void kernel_mul_mat_f16_f32_l4_x8_gqa_r4_img(
)"
R"(        __read_only image1d_buffer_t src0_img,
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
R"(        int r3
)"
R"() {
)"
R"(    src1 = (global char *)((global char *)src1 + offset1);
)"
R"(    dst  = (global float*)((global char *)dst  + offsetd);
)"
R"(
)"
R"(    const int sgs_lid = get_sub_group_local_id();
)"
R"(    const int q_id    = sgs_lid >> 4;       // 0..3
)"
R"(    const int lane_q  = sgs_lid & 15;       // 0..15
)"
R"(
)"
R"(    const int r0_base = get_group_id(0) * N_K_ROWS_GQA_R4;
)"
R"(    const int im_kv   = get_group_id(2);
)"
R"(
)"
R"(    const int i02 = im_kv % ne02;
)"
R"(    const int i03 = im_kv / ne02;
)"
R"(
)"
R"(    const int q_head_lo = i02 * GQA_RATIO_R4;
)"
R"(
)"
R"(    __local float4 q_loc[GQA_RATIO_R4 * DK_VEC_R4];
)"
R"(    #pragma unroll
)"
R"(    for (int qh = 0; qh < GQA_RATIO_R4; ++qh) {
)"
R"(        const int qh_idx = q_head_lo + qh;
)"
R"(        global float4 * y4 = (global float4 *)(src1 + qh_idx * nb12 + i03 * nb13);
)"
R"(        if (sgs_lid < DK_VEC_R4) {
)"
R"(            q_loc[qh * DK_VEC_R4 + sgs_lid] = y4[sgs_lid];
)"
R"(        }
)"
R"(    }
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(    const int pitch_px_row  = (int)(nb01 >> 4);
)"
R"(    const int pitch_px_head = (int)(nb02 >> 4);
)"
R"(    const int pitch_px_n13  = (int)(nb03 >> 4);
)"
R"(
)"
R"(    const int head_px_base = i02 * pitch_px_head + (i03 / r3) * pitch_px_n13;
)"
R"(
)"
R"(    #pragma unroll
)"
R"(    for (int dr = 0; dr < N_K_ROWS_GQA_R4; ++dr) {
)"
R"(        const int r0 = r0_base + dr;
)"
R"(        const int row_px_base = r0 * pitch_px_row + head_px_base;
)"
R"(
)"
R"(        const int p = lane_q;
)"
R"(        const half8 k8 = as_half8(read_imagef(src0_img, row_px_base + p));
)"
R"(        const int   i0 = 2 * p;
)"
R"(        const float4 qa = q_loc[q_id * DK_VEC_R4 + i0    ];
)"
R"(        const float4 qb = q_loc[q_id * DK_VEC_R4 + i0 + 1];
)"
R"(
)"
R"(        float sumf =
)"
R"(              convert_float(k8.s0) * qa.s0
)"
R"(            + convert_float(k8.s1) * qa.s1
)"
R"(            + convert_float(k8.s2) * qa.s2
)"
R"(            + convert_float(k8.s3) * qa.s3
)"
R"(            + convert_float(k8.s4) * qb.s0
)"
R"(            + convert_float(k8.s5) * qb.s1
)"
R"(            + convert_float(k8.s6) * qb.s2
)"
R"(            + convert_float(k8.s7) * qb.s3;
)"
R"(
)"
R"(        sumf += sub_group_shuffle_xor(sumf, 8);
)"
R"(        sumf += sub_group_shuffle_xor(sumf, 4);
)"
R"(        sumf += sub_group_shuffle_xor(sumf, 2);
)"
R"(        sumf += sub_group_shuffle_xor(sumf, 1);
)"
R"(
)"
R"(        if (lane_q == 0) {
)"
R"(            const int im_out = i03 * ne12 + (q_head_lo + q_id);
)"
R"(            dst[im_out * ne1 * ne0 + r0] = sumf;
)"
R"(        }
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(#define N_K_ROWS_GQA_R2_DK256   16
)"
R"(#define GQA_RATIO_R2            2
)"
R"(#define LANES_PER_QH_R2         32    // = 64 / GQA_RATIO_R2
)"
R"(#define DK_VEC_DK256            64    // DK / 4 for DK=256
)"
R"(
)"
R"(#ifdef ADRENO_GPU
)"
R"(REQD_SUBGROUP_SIZE_64
)"
R"(#endif
)"
R"(kernel void kernel_mul_mat_f16_f32_l4_x8_gqa_r2_dk256_img(
)"
R"(        __read_only image1d_buffer_t src0_img,
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
R"(        int r3
)"
R"() {
)"
R"(    src1 = (global char *)((global char *)src1 + offset1);
)"
R"(    dst  = (global float*)((global char *)dst  + offsetd);
)"
R"(
)"
R"(    const int sgs_lid = get_sub_group_local_id();
)"
R"(    const int q_id    = sgs_lid >> 5;       // 0..1
)"
R"(    const int lane_q  = sgs_lid & 31;       // 0..31
)"
R"(
)"
R"(    const int r0_base = get_group_id(0) * N_K_ROWS_GQA_R2_DK256;
)"
R"(    const int im_kv   = get_group_id(2);
)"
R"(
)"
R"(    const int i02 = im_kv % ne02;
)"
R"(    const int i03 = im_kv / ne02;
)"
R"(
)"
R"(    const int q_head_lo = i02 * GQA_RATIO_R2;
)"
R"(
)"
R"(    __local float4 q_loc[GQA_RATIO_R2 * DK_VEC_DK256];
)"
R"(    #pragma unroll
)"
R"(    for (int qh = 0; qh < GQA_RATIO_R2; ++qh) {
)"
R"(        const int qh_idx = q_head_lo + qh;
)"
R"(        global float4 * y4 = (global float4 *)(src1 + qh_idx * nb12 + i03 * nb13);
)"
R"(        q_loc[qh * DK_VEC_DK256 + sgs_lid] = y4[sgs_lid];
)"
R"(    }
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(    const int pitch_px_row  = (int)(nb01 >> 4);
)"
R"(    const int pitch_px_head = (int)(nb02 >> 4);
)"
R"(    const int pitch_px_n13  = (int)(nb03 >> 4);
)"
R"(
)"
R"(    const int head_px_base = i02 * pitch_px_head + (i03 / r3) * pitch_px_n13;
)"
R"(
)"
R"(    #pragma unroll
)"
R"(    for (int dr = 0; dr < N_K_ROWS_GQA_R2_DK256; ++dr) {
)"
R"(        const int r0 = r0_base + dr;
)"
R"(        const int row_px_base = r0 * pitch_px_row + head_px_base;
)"
R"(
)"
R"(        const int p = lane_q;
)"
R"(        const half8 k8 = as_half8(read_imagef(src0_img, row_px_base + p));
)"
R"(        const int   i0 = 2 * p;
)"
R"(        const float4 qa = q_loc[q_id * DK_VEC_DK256 + i0    ];
)"
R"(        const float4 qb = q_loc[q_id * DK_VEC_DK256 + i0 + 1];
)"
R"(
)"
R"(        float sumf =
)"
R"(              convert_float(k8.s0) * qa.s0
)"
R"(            + convert_float(k8.s1) * qa.s1
)"
R"(            + convert_float(k8.s2) * qa.s2
)"
R"(            + convert_float(k8.s3) * qa.s3
)"
R"(            + convert_float(k8.s4) * qb.s0
)"
R"(            + convert_float(k8.s5) * qb.s1
)"
R"(            + convert_float(k8.s6) * qb.s2
)"
R"(            + convert_float(k8.s7) * qb.s3;
)"
R"(
)"
R"(        sumf += sub_group_shuffle_xor(sumf, 16);
)"
R"(        sumf += sub_group_shuffle_xor(sumf, 8);
)"
R"(        sumf += sub_group_shuffle_xor(sumf, 4);
)"
R"(        sumf += sub_group_shuffle_xor(sumf, 2);
)"
R"(        sumf += sub_group_shuffle_xor(sumf, 1);
)"
R"(
)"
R"(        if (lane_q == 0) {
)"
R"(            const int im_out = i03 * ne12 + (q_head_lo + q_id);
)"
R"(            dst[im_out * ne1 * ne0 + r0] = sumf;
)"
R"(        }
)"
R"(    }
)"
R"(}
)"
