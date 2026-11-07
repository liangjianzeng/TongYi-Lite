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
R"(typedef struct {
)"
R"(    half d;
)"
R"(    uchar qs[QK1_0/8];
)"
R"(} block_q1_0;
)"
R"(
)"
R"(#define NB_Q1_0 16
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
R"(inline float block_q_1_0_dot_y(global block_q1_0 * qb, float sumy, float yl[NB_Q1_0], short il) {
)"
R"(    global uchar * qs = qb->qs + il*2;
)"
R"(    uint b0 = qs[0];
)"
R"(    uint b1 = qs[1];
)"
R"(
)"
R"(    float acc = 0.f;
)"
R"(    acc += yl[ 0]*(float)((b0 >> 0) & 1) + yl[ 1]*(float)((b0 >> 1) & 1);
)"
R"(    acc += yl[ 2]*(float)((b0 >> 2) & 1) + yl[ 3]*(float)((b0 >> 3) & 1);
)"
R"(    acc += yl[ 4]*(float)((b0 >> 4) & 1) + yl[ 5]*(float)((b0 >> 5) & 1);
)"
R"(    acc += yl[ 6]*(float)((b0 >> 6) & 1) + yl[ 7]*(float)((b0 >> 7) & 1);
)"
R"(
)"
R"(    acc += yl[ 8]*(float)((b1 >> 0) & 1) + yl[ 9]*(float)((b1 >> 1) & 1);
)"
R"(    acc += yl[10]*(float)((b1 >> 2) & 1) + yl[11]*(float)((b1 >> 3) & 1);
)"
R"(    acc += yl[12]*(float)((b1 >> 4) & 1) + yl[13]*(float)((b1 >> 5) & 1);
)"
R"(    acc += yl[14]*(float)((b1 >> 6) & 1) + yl[15]*(float)((b1 >> 7) & 1);
)"
R"(
)"
R"(    return qb->d * (2.0f*acc - sumy);
)"
R"(}
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
R"(kernel void kernel_mul_mv_q1_0_f32(
)"
R"(    global char * src0,
)"
R"(    ulong         offset0,
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
R"(    src0 = (global char*)((global char*)src0 + offset0);
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
R"(    // pointers to src0 rows
)"
R"(    global block_q1_0 * ax[N_R0_Q1_0];
)"
R"(    for (int row = 0; row < N_R0_Q1_0; ++row) {
)"
R"(        ulong offset_src0 = (first_row + row)*nb01 + (i12/r2)*nb02 + (i13/r3)*nb03;
)"
R"(        ax[row] = (global block_q1_0 *) ((global char *) src0 + offset_src0);
)"
R"(    }
)"
R"(
)"
R"(    float yl[NB_Q1_0];
)"
R"(    float sumf[N_R0_Q1_0] = { 0.f };
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
R"(    // each thread handles NB_Q1_0 quants at a time
)"
R"(    for (int ib = ix; ib < nb; ib += N_SIMDWIDTH/8) {
)"
R"(        float sumy = 0.f;
)"
R"(        for (short i = 0; i < NB_Q1_0; ++i) {
)"
R"(            yl[i] = yb[i];
)"
R"(            sumy += yb[i];
)"
R"(        }
)"
R"(
)"
R"(        for (short row = 0; row < N_R0_Q1_0; row++) {
)"
R"(            sumf[row] += block_q_1_0_dot_y(ax[row] + ib, sumy, yl, il);
)"
R"(        }
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
R"(    for (int row = 0; row < N_R0_Q1_0; ++row) {
)"
R"(        float tot = sub_group_reduce_add(sumf[row]);
)"
R"(
)"
R"(        if (get_sub_group_local_id() == 0 && first_row + row < ne01) {
)"
R"(            dst_f32[first_row + row] = tot;
)"
R"(        }
)"
R"(    }
)"
R"(}
)"
