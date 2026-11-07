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
R"(#define QK_K 256
)"
R"(
)"
R"(typedef struct {
)"
R"(    half d;
)"
R"(    ushort scales_h;
)"
R"(    uchar scales_l[QK_K/64];
)"
R"(    uchar qs[QK_K/2];
)"
R"(} block_iq4_xs;
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
R"(#define N_DST 4
)"
R"(#define N_SIMDGROUP 1
)"
R"(#define N_SIMDWIDTH 16
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
R"(// 8 threads cover one super block, one 32 element sub block each
)"
R"(#define BLOCK_STRIDE (N_SIMDWIDTH/8)
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
R"(kernel void kernel_mul_mv_iq4_xs_f32_flat(
)"
R"(        global uchar * src0_qs,
)"
R"(        global uchar * src0_sl,
)"
R"(        global ushort * src0_sh,
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
R"(    int ix = get_sub_group_local_id()/8;  // super block index
)"
R"(    int it = get_sub_group_local_id()%8;  // sub block inside the super block
)"
R"(
)"
R"(    int nb = ne00/QK_K;
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
R"(    ulong offset_src0 = (offset0 + first_row*nb01 + (i12/r2)*nb02 + (i13/r3)*nb03)/sizeof(block_iq4_xs);
)"
R"(    ulong row_stride = nb01/sizeof(block_iq4_xs);
)"
R"(    ulong offset_src1 =        r1*nb11 + (i12   )*nb12 + (i13   )*nb13;
)"
R"(
)"
R"(    global float         * y = (global float         *) (src1 + offset_src1);
)"
R"(
)"
R"(    float yl[32];
)"
R"(    float sumf[N_DST] = {0.f};
)"
R"(    float all_sum;
)"
R"(
)"
R"(    global float * y4 = y + ix * QK_K + 32 * it;
)"
R"(
)"
R"(    for (int ib = ix; ib < nb; ib += BLOCK_STRIDE) {
)"
R"(        for (int i = 0; i < 32; ++i) {
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
R"(            int ls = ((src0_sl[4*b + it/2] >> (4*(it%2))) & 15) | (((src0_sh[b] >> (2*it)) & 3) << 4);
)"
R"(            float db = (float)src0_d[b] * (float)(ls - 32);
)"
R"(            global uchar * qs = src0_qs + 128*b + 16*it;
)"
R"(
)"
R"(            float acc = 0.f;
)"
R"(            for (int j = 0; j < 16; ++j) {
)"
R"(                acc += yl[j]    * (float)iq4_xs_values[qs[j] & 15];
)"
R"(                acc += yl[j+16] * (float)iq4_xs_values[qs[j] >>  4];
)"
R"(            }
)"
R"(
)"
R"(            sumf[row] += db * acc;
)"
R"(        }
)"
R"(
)"
R"(        y4 += BLOCK_STRIDE * QK_K;
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
