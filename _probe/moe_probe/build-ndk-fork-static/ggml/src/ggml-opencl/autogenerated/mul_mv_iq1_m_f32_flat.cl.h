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
R"(#define IQ1_M_DELTA 0.125f
)"
R"(
)"
R"(// no d field: the super block scale is 4 nibbles spread over scales[]
)"
R"(typedef struct {
)"
R"(    uchar qs[QK_K/8];
)"
R"(    uchar qh[QK_K/16];
)"
R"(    uchar scales[QK_K/32];
)"
R"(} block_iq1_m;
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
R"(kernel void kernel_mul_mv_iq1_m_f32_flat(
)"
R"(        global uchar * src0_qs,
)"
R"(        global uchar * src0_qh,
)"
R"(        global ushort * src0_sc,
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
R"(    ulong offset_src0 = (offset0 + first_row*nb01 + (i12/r2)*nb02 + (i13/r3)*nb03)/sizeof(block_iq1_m);
)"
R"(    ulong row_stride = nb01/sizeof(block_iq1_m);
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
R"(            global ushort * sc = src0_sc + 4*b;
)"
R"(            ushort u16 = (ushort)(((uint)sc[0] >> 12) | (((uint)sc[1] >> 8) & 0x00f0)
)"
R"(                                | (((uint)sc[2] >> 4) & 0x0f00) | ((uint)sc[3] & 0xf000));
)"
R"(            float dsuper = (float)as_half(u16);
)"
R"(
)"
R"(            float acc = 0.f;
)"
R"(            for (int il = 0; il < 4; ++il) {
)"
R"(                int   ib16 = 2*it + il/2;
)"
R"(                float dl   = dsuper * (float)(2*(((uint)sc[ib16/4] >> (3*(ib16%4))) & 7) + 1);
)"
R"(
)"
R"(                uchar qhb = src0_qh[16*b + 2*it + il/2];
)"
R"(                float dlt = (qhb & (0x08 << (4*(il%2)))) ? (-1.f - IQ1_M_DELTA) : (-1.f + IQ1_M_DELTA);
)"
R"(
)"
R"(                uint gi = (uint)src0_qs[32*b + 4*it+il] | ((((uint)qhb >> (4*(il%2))) & 7) << 8);
)"
R"(                uint g  = iq1_s_grid[gi];
)"
R"(
)"
R"(                float a = 0.f;
)"
R"(                for (int j = 0; j < 4; ++j) {
)"
R"(                    a += yl[8*il+j+0] * ((float)((g >> (8*j+0)) & 0xF) + dlt);
)"
R"(                    a += yl[8*il+j+4] * ((float)((g >> (8*j+4)) & 0xF) + dlt);
)"
R"(                }
)"
R"(                acc += dl * a;
)"
R"(            }
)"
R"(
)"
R"(            sumf[row] += acc;
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
