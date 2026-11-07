R"(#pragma OPENCL EXTENSION cl_khr_fp16 : enable
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
R"(#define QK2_0 64
)"
R"(
)"
R"(// 00=-1, 01=0, 10=+1, 11=+2
)"
R"(typedef struct {
)"
R"(    half  d;
)"
R"(    uchar qs[QK2_0/4];
)"
R"(} block_q2_0;
)"
R"(
)"
R"(#undef N_DST
)"
R"(#undef N_SIMDGROUP
)"
R"(#undef N_SIMDWIDTH
)"
R"(
)"
R"(#ifdef INTEL_GPU
)"
R"(#define N_DST 4 // number of rows each SIMD group works on
)"
R"(#define N_SIMDGROUP 1 // number of SIMD groups in a thread group
)"
R"(#define N_SIMDWIDTH 16 // SIMD group size
)"
R"(#elif defined (ADRENO_GPU)
)"
R"(#define N_DST 4
)"
R"(#define N_SIMDGROUP 1
)"
R"(#define N_SIMDWIDTH 64
)"
R"(#endif
)"
R"(
)"
R"(#undef  BLOCK_STRIDE
)"
R"(// 4 threads cover one block
)"
R"(#define BLOCK_STRIDE (N_SIMDWIDTH/4)
)"
R"(
)"
R"(#ifdef INTEL_GPU
)"
R"(REQD_SUBGROUP_SIZE_16
)"
R"(#elif defined (ADRENO_GPU)
)"
R"(REQD_SUBGROUP_SIZE_64
)"
R"(#endif
)"
R"(kernel void kernel_mul_mv_q2_0_f32_flat(
)"
R"(        global uchar * src0_qs,
)"
R"(        global half * src0_d,
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
R"(        ulong nb01,
)"
R"(        ulong nb02,
)"
R"(        ulong nb03,
)"
R"(        int ne12,
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
R"(    src1 = src1 + offset1;
)"
R"(    dst  = dst  + offsetd;
)"
R"(
)"
R"(    int ix = get_sub_group_local_id()/4;  // block index
)"
R"(    int it = get_sub_group_local_id()%4;  // part of the block
)"
R"(
)"
R"(    int nb = ne00/QK2_0;
)"
R"(
)"
R"(    int r0 = get_group_id(0);
)"
R"(    int r1 = get_group_id(1);
)"
R"(    int im = get_group_id(2);
)"
R"(    int first_row = (r0 * N_SIMDGROUP + get_sub_group_id()) * N_DST;
)"
R"(
)"
R"(    int i12 = im%ne12;
)"
R"(    int i13 = im/ne12;
)"
R"(
)"
R"(    ulong offset_src0 = (offset0 + first_row*nb01 + (i12/r2)*nb02 + (i13/r3)*nb03)/sizeof(block_q2_0);
)"
R"(    ulong row_stride = nb01/sizeof(block_q2_0);
)"
R"(    ulong offset_src1 =        r1*nb11 + (i12   )*nb12 + (i13   )*nb13;
)"
R"(
)"
R"(    global float   * y = (global float   *) (src1 + offset_src1);
)"
R"(
)"
R"(    float yl[16];
)"
R"(    float sumf[N_DST] = {0.f};
)"
R"(    float all_sum;
)"
R"(
)"
R"(    global float * y4 = y + ix * QK2_0 + 16 * it;
)"
R"(
)"
R"(    for (int ib = ix; ib < nb; ib += BLOCK_STRIDE) {
)"
R"(        for (int i = 0; i < 16; ++i) {
)"
R"(            yl[i] = y4[i];
)"
R"(        }
)"
R"(
)"
R"(        // only ne01 output rows exist; reading past them can pull in an inf scale
)"
R"(        for (int row = 0; row < N_DST && first_row + row < ne01; row++) {
)"
R"(            const ulong b = offset_src0 + ib + row*row_stride;
)"
R"(
)"
R"(            global uchar * q = src0_qs + 16*b + 4*it;
)"
R"(
)"
R"(            float acc = 0.f;
)"
R"(            for (int i = 0; i < 4; ++i) {
)"
R"(                uchar b = q[i];
)"
R"(                acc += yl[4*i+0] * (float)(((b >> 0) & 3) - 1);
)"
R"(                acc += yl[4*i+1] * (float)(((b >> 2) & 3) - 1);
)"
R"(                acc += yl[4*i+2] * (float)(((b >> 4) & 3) - 1);
)"
R"(                acc += yl[4*i+3] * (float)(((b >> 6) & 3) - 1);
)"
R"(            }
)"
R"(
)"
R"(            sumf[row] += (float)src0_d[b] * acc;
)"
R"(        }
)"
R"(
)"
R"(        y4 += BLOCK_STRIDE * QK2_0;
)"
R"(    }
)"
R"(
)"
R"(    global float * dst_f32 = (global float *) dst + im*ne0*ne1 + r1*ne0;
)"
R"(
)"
R"(    for (int row = 0; row < N_DST; ++row) {
)"
R"(        all_sum = sub_group_reduce_add(sumf[row]);
)"
R"(        if (first_row + row < ne01) {
)"
R"(            if (get_sub_group_local_id() == 0) {
)"
R"(                dst_f32[first_row + row] = all_sum;
)"
R"(            }
)"
R"(        }
)"
R"(    }
)"
R"(}
)"
