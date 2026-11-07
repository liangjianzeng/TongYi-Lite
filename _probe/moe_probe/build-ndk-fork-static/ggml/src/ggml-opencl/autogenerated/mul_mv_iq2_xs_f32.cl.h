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
R"(    half   d;
)"
R"(    ushort qs[QK_K/8];
)"
R"(    uchar  scales[QK_K/32];
)"
R"(} block_iq2_xs;
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
R"(kernel void kernel_mul_mv_iq2_xs_f32(
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
R"(    src0 = src0 + offset0;
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
R"(    ulong offset_src0 = first_row*nb01 + (i12/r2)*nb02 + (i13/r3)*nb03;
)"
R"(    ulong offset_src1 =        r1*nb11 + (i12   )*nb12 + (i13   )*nb13;
)"
R"(
)"
R"(    global block_iq2_xs * x = (global block_iq2_xs *) (src0 + offset_src0);
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
R"(        global char * xrow = (global char *)(x + ib);
)"
R"(
)"
R"(        // only ne01 output rows exist; reading past them can pull in an inf scale
)"
R"(        for (int row = 0; row < N_DST && first_row + row < ne01; row++) {
)"
R"(            global block_iq2_xs * xb = (global block_iq2_xs *)(xrow + row*nb01);
)"
R"(
)"
R"(            uchar scb = xb->scales[it];
)"
R"(            float dlo = (float)xb->d * (0.5f + (float)(scb & 0xf)) * 0.25f;
)"
R"(            float dhi = (float)xb->d * (0.5f + (float)(scb >>  4)) * 0.25f;
)"
R"(
)"
R"(            global ushort * q16 = xb->qs + 4*it;
)"
R"(
)"
R"(            float alo = 0.f, ahi = 0.f;
)"
R"(            for (int l = 0; l < 4; ++l) {
)"
R"(                ushort q  = q16[l];
)"
R"(                uchar  sg = iq2_xs_signs(q >> 9);
)"
R"(                uint   lo = iq2_xs_grid[2*(q & 511)+0];
)"
R"(                uint   hi = iq2_xs_grid[2*(q & 511)+1];
)"
R"(                float  a  = 0.f;
)"
R"(                for (int j = 0; j < 4; ++j) {
)"
R"(                    a += yl[8*l+j+0] * (float)((lo >> (8*j)) & 0xFF) * ((sg & (1 << j))     ? -1.f : 1.f);
)"
R"(                    a += yl[8*l+j+4] * (float)((hi >> (8*j)) & 0xFF) * ((sg & (1 << (j+4))) ? -1.f : 1.f);
)"
R"(                }
)"
R"(                if (l < 2) alo += a; else ahi += a;
)"
R"(            }
)"
R"(
)"
R"(            sumf[row] += dlo * alo + dhi * ahi;
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
