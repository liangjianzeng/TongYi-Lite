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
R"(//------------------------------------------------------------------------------
)"
R"(// struct block_q2_K
)"
R"(//------------------------------------------------------------------------------
)"
R"(#define QK_K 256
)"
R"(
)"
R"(// 16 blocks of 16 elements each
)"
R"(// weight is represented as x = a * q + b
)"
R"(struct block_q2_K {
)"
R"(    uchar scales[QK_K/16]; // scales and mins, quantized with 4 bits
)"
R"(    uchar qs[QK_K/4];      // 2-bit quants
)"
R"(    half  d;              // super-block scale for quantized scales
)"
R"(    half  dmin;            // super-block scale for quantized mins
)"
R"(};
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
R"(// number of (super) blocks each subgroup processes
)"
R"(// 8 threads cover one super block, so a wave covers N_SIMDWIDTH/8 of them
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
R"(kernel void kernel_mul_mv_q2_K_f32_flat(
)"
R"(        global uchar * src0_qs,
)"
R"(        global uchar * src0_sc,
)"
R"(        global half * src0_dm,
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
R"(    int it = get_sub_group_local_id()%8;  // block index (inside super block)
)"
R"(    int iq = it/4;      // 0 or 1 - first or second half of the super block
)"
R"(    int ir = it%4;      // 0...3 - block index in the half super block
)"
R"(    int is = (8*ir)/16; // 0 or 1 - scale pair
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
R"(    ulong offset_src0 = (offset0 + first_row*nb01 + (i12/r2)*nb02 + (i13/r3)*nb03)/sizeof(struct block_q2_K);
)"
R"(    ulong row_stride = nb01/sizeof(struct block_q2_K);
)"
R"(    ulong offset_src1 =        r1*nb11 + (i12   )*nb12 + (i13   )*nb13;
)"
R"(
)"
R"(    global float      * y = (global float      *) (src1 + offset_src1);
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
R"(    global float * y4 = y + ix * QK_K + 128 * iq + 8 * ir;
)"
R"(
)"
R"(    for (int ib = ix; ib < nb; ib += BLOCK_STRIDE) {
)"
R"(        float4 sumy = {0.f, 0.f, 0.f, 0.f};
)"
R"(        for (int i = 0; i < 8; ++i) {
)"
R"(            yl[i+ 0] = y4[i+ 0]; sumy.s0 += yl[i+ 0];
)"
R"(            yl[i+ 8] = y4[i+32]; sumy.s1 += yl[i+ 8];
)"
R"(            yl[i+16] = y4[i+64]; sumy.s2 += yl[i+16];
)"
R"(            yl[i+24] = y4[i+96]; sumy.s3 += yl[i+24];
)"
R"(        }
)"
R"(
)"
R"(        global uchar  * sc = (src0_sc + 16*(offset_src0 + ib)) + 8*iq + is;
)"
R"(        global ushort * qs = (global ushort *)(src0_qs + 64*(offset_src0 + ib)) + 16 * iq + 4 * ir;
)"
R"(        global half   * dh = src0_dm + 2*(offset_src0 + ib);
)"
R"(
)"
R"(        // only ne01 output rows exist; reading past them can pull in an inf scale
)"
R"(        for (int row = 0; row < N_DST && first_row + row < ne01; row++) {
)"
R"(            float4 acc1 = {0.f, 0.f, 0.f, 0.f};
)"
R"(            float4 acc2 = {0.f, 0.f, 0.f, 0.f};
)"
R"(            for (int i = 0; i < 8; i += 2) {
)"
R"(                acc1.s0 += yl[i+ 0] * (qs[i/2] & 0x0003);
)"
R"(                acc2.s0 += yl[i+ 1] * (qs[i/2] & 0x0300);
)"
R"(                acc1.s1 += yl[i+ 8] * (qs[i/2] & 0x000c);
)"
R"(                acc2.s1 += yl[i+ 9] * (qs[i/2] & 0x0c00);
)"
R"(                acc1.s2 += yl[i+16] * (qs[i/2] & 0x0030);
)"
R"(                acc2.s2 += yl[i+17] * (qs[i/2] & 0x3000);
)"
R"(                acc1.s3 += yl[i+24] * (qs[i/2] & 0x00c0);
)"
R"(                acc2.s3 += yl[i+25] * (qs[i/2] & 0xc000);
)"
R"(            }
)"
R"(
)"
R"(            float dall = dh[0];
)"
R"(            float dmin = dh[1] * 1.f/16.f;
)"
R"(            sumf[row] += dall * ((acc1.s0 + 1.f/256.f * acc2.s0) * (sc[0] & 0xF) * 1.f/ 1.f +
)"
R"(                                 (acc1.s1 + 1.f/256.f * acc2.s1) * (sc[2] & 0xF) * 1.f/ 4.f +
)"
R"(                                 (acc1.s2 + 1.f/256.f * acc2.s2) * (sc[4] & 0xF) * 1.f/16.f +
)"
R"(                                 (acc1.s3 + 1.f/256.f * acc2.s3) * (sc[6] & 0xF) * 1.f/64.f) -
)"
R"(                        dmin * (sumy.s0 * (sc[0] & 0xF0) + sumy.s1 * (sc[2] & 0xF0) +
)"
R"(                                sumy.s2 * (sc[4] & 0xF0) + sumy.s3 * (sc[6] & 0xF0));
)"
R"(
)"
R"(            qs += row_stride*32;
)"
R"(            sc += row_stride*16;
)"
R"(            dh += row_stride*2;
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
