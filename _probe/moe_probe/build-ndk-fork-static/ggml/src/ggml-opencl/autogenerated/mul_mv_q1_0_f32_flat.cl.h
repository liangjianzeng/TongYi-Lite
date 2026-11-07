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
R"(#define QK1_0 128
)"
R"(#define QK1_0_BYTES (QK1_0/8)              // 16 quant bytes per block
)"
R"(#define QK1_0_BLK_BYTES (QK1_0_BYTES + 2)  // d + qs in original tensor = 18
)"
R"(
)"
R"(#define NB_Q1_0 16 // quants handled per thread (two qs bytes)
)"
R"(
)"
R"(#ifdef INTEL_GPU
)"
R"(#define N_R0_Q1_0 4 // number of rows each subgroup works on
)"
R"(#define N_SG_Q1_0 2 // number of subgroups in a work group
)"
R"(#define N_SIMDWIDTH 16 // subgroup size
)"
R"(#elif defined (ADRENO_GPU)
)"
R"(#define N_R0_Q1_0 4
)"
R"(#define N_SG_Q1_0 2
)"
R"(#define N_SIMDWIDTH 64
)"
R"(#endif
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
R"(kernel void kernel_mul_mv_q1_0_f32_flat(
)"
R"(    global char * src0_q,
)"
R"(    global half * src0_d,
)"
R"(    global char * src1,
)"
R"(    ulong         offset1,
)"
R"(    global char * dst,
)"
R"(    ulong         offsetd,
)"
R"(    int           ne00,
)"
R"(    int           ne01,
)"
R"(    ulong         nb01,
)"
R"(    ulong         nb02,
)"
R"(    ulong         nb03,
)"
R"(    int           ne12,
)"
R"(    ulong         nb11,
)"
R"(    ulong         nb12,
)"
R"(    ulong         nb13,
)"
R"(    int           ne0,
)"
R"(    int           ne1,
)"
R"(    int           r2,
)"
R"(    int           r3
)"
R"() {
)"
R"(    src1 = (global char*)((global char*)src1 + offset1);
)"
R"(    dst  = (global char*)((global char*)dst  + offsetd);
)"
R"(
)"
R"(    int nb = ne00/QK1_0;
)"
R"(
)"
R"(    int r0 = get_group_id(0);
)"
R"(    int r1 = get_group_id(1);
)"
R"(    int im = get_group_id(2);
)"
R"(
)"
R"(    int first_row = (r0*N_SG_Q1_0 + get_sub_group_id()) * N_R0_Q1_0;
)"
R"(
)"
R"(    uint i12 = im%ne12;
)"
R"(    uint i13 = im/ne12;
)"
R"(
)"
R"(    ulong offset_src1 = r1*nb11 + i12*nb12 + i13*nb13;
)"
R"(    global float * y  = (global float *) (src1 + offset_src1);
)"
R"(
)"
R"(    // pointers to src0 rows (flat: q bytes + scales)
)"
R"(    uint offset_src0_base = first_row*nb01 + (i12/r2)*nb02 + (i13/r3)*nb03;
)"
R"(
)"
R"(    global uchar * ax0, * ax1, * ax2, * ax3;
)"
R"(    global half  * ad0, * ad1, * ad2, * ad3;
)"
R"(    uint offset_src0;
)"
R"(
)"
R"(    offset_src0 = (offset_src0_base + 0*nb01) / QK1_0_BLK_BYTES;
)"
R"(    ax0 = (global uchar *) ((global char *) src0_q + offset_src0*QK1_0_BYTES);
)"
R"(    ad0 = (global half  *) ((global char *) src0_d + offset_src0*sizeof(half));
)"
R"(
)"
R"(    offset_src0 = (offset_src0_base + 1*nb01) / QK1_0_BLK_BYTES;
)"
R"(    ax1 = (global uchar *) ((global char *) src0_q + offset_src0*QK1_0_BYTES);
)"
R"(    ad1 = (global half  *) ((global char *) src0_d + offset_src0*sizeof(half));
)"
R"(
)"
R"(    offset_src0 = (offset_src0_base + 2*nb01) / QK1_0_BLK_BYTES;
)"
R"(    ax2 = (global uchar *) ((global char *) src0_q + offset_src0*QK1_0_BYTES);
)"
R"(    ad2 = (global half  *) ((global char *) src0_d + offset_src0*sizeof(half));
)"
R"(
)"
R"(    offset_src0 = (offset_src0_base + 3*nb01) / QK1_0_BLK_BYTES;
)"
R"(    ax3 = (global uchar *) ((global char *) src0_q + offset_src0*QK1_0_BYTES);
)"
R"(    ad3 = (global half  *) ((global char *) src0_d + offset_src0*sizeof(half));
)"
R"(
)"
R"(    const short ix = get_sub_group_local_id()/8;
)"
R"(    const short il = get_sub_group_local_id()%8;
)"
R"(
)"
R"(    global float * yb = y + ix*QK1_0 + il*NB_Q1_0;
)"
R"(
)"
R"(    float8 yl_lo;
)"
R"(    float8 yl_hi;
)"
R"(    float4 sumf = 0.f;
)"
R"(
)"
R"(    // each thread handles NB_Q1_0 = 16 quants (two qs bytes) at a time
)"
R"(    for (int ib = ix; ib < nb; ib += N_SIMDWIDTH/8) {
)"
R"(        yl_lo = vload8(0, yb);
)"
R"(        yl_hi = vload8(0, yb + 8);
)"
R"(        float sumy = yl_lo.s0 + yl_lo.s1 + yl_lo.s2 + yl_lo.s3
)"
R"(                   + yl_lo.s4 + yl_lo.s5 + yl_lo.s6 + yl_lo.s7
)"
R"(                   + yl_hi.s0 + yl_hi.s1 + yl_hi.s2 + yl_hi.s3
)"
R"(                   + yl_hi.s4 + yl_hi.s5 + yl_hi.s6 + yl_hi.s7;
)"
R"(
)"
R"(        uint b0, b1;
)"
R"(        float acc;
)"
R"(
)"
R"(        b0 = ax0[ib*QK1_0_BYTES + il*2 + 0];
)"
R"(        b1 = ax0[ib*QK1_0_BYTES + il*2 + 1];
)"
R"(        acc  = yl_lo.s0*(float)((b0 >> 0) & 1) + yl_lo.s1*(float)((b0 >> 1) & 1)
)"
R"(             + yl_lo.s2*(float)((b0 >> 2) & 1) + yl_lo.s3*(float)((b0 >> 3) & 1)
)"
R"(             + yl_lo.s4*(float)((b0 >> 4) & 1) + yl_lo.s5*(float)((b0 >> 5) & 1)
)"
R"(             + yl_lo.s6*(float)((b0 >> 6) & 1) + yl_lo.s7*(float)((b0 >> 7) & 1)
)"
R"(             + yl_hi.s0*(float)((b1 >> 0) & 1) + yl_hi.s1*(float)((b1 >> 1) & 1)
)"
R"(             + yl_hi.s2*(float)((b1 >> 2) & 1) + yl_hi.s3*(float)((b1 >> 3) & 1)
)"
R"(             + yl_hi.s4*(float)((b1 >> 4) & 1) + yl_hi.s5*(float)((b1 >> 5) & 1)
)"
R"(             + yl_hi.s6*(float)((b1 >> 6) & 1) + yl_hi.s7*(float)((b1 >> 7) & 1);
)"
R"(        sumf.s0 += (float)ad0[ib] * (2.0f*acc - sumy);
)"
R"(
)"
R"(        b0 = ax1[ib*QK1_0_BYTES + il*2 + 0];
)"
R"(        b1 = ax1[ib*QK1_0_BYTES + il*2 + 1];
)"
R"(        acc  = yl_lo.s0*(float)((b0 >> 0) & 1) + yl_lo.s1*(float)((b0 >> 1) & 1)
)"
R"(             + yl_lo.s2*(float)((b0 >> 2) & 1) + yl_lo.s3*(float)((b0 >> 3) & 1)
)"
R"(             + yl_lo.s4*(float)((b0 >> 4) & 1) + yl_lo.s5*(float)((b0 >> 5) & 1)
)"
R"(             + yl_lo.s6*(float)((b0 >> 6) & 1) + yl_lo.s7*(float)((b0 >> 7) & 1)
)"
R"(             + yl_hi.s0*(float)((b1 >> 0) & 1) + yl_hi.s1*(float)((b1 >> 1) & 1)
)"
R"(             + yl_hi.s2*(float)((b1 >> 2) & 1) + yl_hi.s3*(float)((b1 >> 3) & 1)
)"
R"(             + yl_hi.s4*(float)((b1 >> 4) & 1) + yl_hi.s5*(float)((b1 >> 5) & 1)
)"
R"(             + yl_hi.s6*(float)((b1 >> 6) & 1) + yl_hi.s7*(float)((b1 >> 7) & 1);
)"
R"(        sumf.s1 += (float)ad1[ib] * (2.0f*acc - sumy);
)"
R"(
)"
R"(        b0 = ax2[ib*QK1_0_BYTES + il*2 + 0];
)"
R"(        b1 = ax2[ib*QK1_0_BYTES + il*2 + 1];
)"
R"(        acc  = yl_lo.s0*(float)((b0 >> 0) & 1) + yl_lo.s1*(float)((b0 >> 1) & 1)
)"
R"(             + yl_lo.s2*(float)((b0 >> 2) & 1) + yl_lo.s3*(float)((b0 >> 3) & 1)
)"
R"(             + yl_lo.s4*(float)((b0 >> 4) & 1) + yl_lo.s5*(float)((b0 >> 5) & 1)
)"
R"(             + yl_lo.s6*(float)((b0 >> 6) & 1) + yl_lo.s7*(float)((b0 >> 7) & 1)
)"
R"(             + yl_hi.s0*(float)((b1 >> 0) & 1) + yl_hi.s1*(float)((b1 >> 1) & 1)
)"
R"(             + yl_hi.s2*(float)((b1 >> 2) & 1) + yl_hi.s3*(float)((b1 >> 3) & 1)
)"
R"(             + yl_hi.s4*(float)((b1 >> 4) & 1) + yl_hi.s5*(float)((b1 >> 5) & 1)
)"
R"(             + yl_hi.s6*(float)((b1 >> 6) & 1) + yl_hi.s7*(float)((b1 >> 7) & 1);
)"
R"(        sumf.s2 += (float)ad2[ib] * (2.0f*acc - sumy);
)"
R"(
)"
R"(        b0 = ax3[ib*QK1_0_BYTES + il*2 + 0];
)"
R"(        b1 = ax3[ib*QK1_0_BYTES + il*2 + 1];
)"
R"(        acc  = yl_lo.s0*(float)((b0 >> 0) & 1) + yl_lo.s1*(float)((b0 >> 1) & 1)
)"
R"(             + yl_lo.s2*(float)((b0 >> 2) & 1) + yl_lo.s3*(float)((b0 >> 3) & 1)
)"
R"(             + yl_lo.s4*(float)((b0 >> 4) & 1) + yl_lo.s5*(float)((b0 >> 5) & 1)
)"
R"(             + yl_lo.s6*(float)((b0 >> 6) & 1) + yl_lo.s7*(float)((b0 >> 7) & 1)
)"
R"(             + yl_hi.s0*(float)((b1 >> 0) & 1) + yl_hi.s1*(float)((b1 >> 1) & 1)
)"
R"(             + yl_hi.s2*(float)((b1 >> 2) & 1) + yl_hi.s3*(float)((b1 >> 3) & 1)
)"
R"(             + yl_hi.s4*(float)((b1 >> 4) & 1) + yl_hi.s5*(float)((b1 >> 5) & 1)
)"
R"(             + yl_hi.s6*(float)((b1 >> 6) & 1) + yl_hi.s7*(float)((b1 >> 7) & 1);
)"
R"(        sumf.s3 += (float)ad3[ib] * (2.0f*acc - sumy);
)"
R"(
)"
R"(        yb += N_SIMDWIDTH*NB_Q1_0;
)"
R"(    }
)"
R"(
)"
R"(    global float * dst_f32 = (global float *) dst + (ulong)im*ne0*ne1 + (ulong)r1*ne0;
)"
R"(
)"
R"(    float4 tot = (float4)(
)"
R"(        sub_group_reduce_add(sumf.s0),
)"
R"(        sub_group_reduce_add(sumf.s1),
)"
R"(        sub_group_reduce_add(sumf.s2),
)"
R"(        sub_group_reduce_add(sumf.s3)
)"
R"(    );
)"
R"(
)"
R"(    if (get_sub_group_local_id() == 0) {
)"
R"(        if (first_row + 0 < ne01) dst_f32[first_row + 0] = tot.s0;
)"
R"(        if (first_row + 1 < ne01) dst_f32[first_row + 1] = tot.s1;
)"
R"(        if (first_row + 2 < ne01) dst_f32[first_row + 2] = tot.s2;
)"
R"(        if (first_row + 3 < ne01) dst_f32[first_row + 3] = tot.s3;
)"
R"(    }
)"
R"(}
)"
