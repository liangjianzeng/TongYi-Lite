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
R"(#define QK_PTQ1_0 128
)"
R"(
)"
R"(// Ternary block, 28 bytes / 128 values. qs holds 5 trits per byte for the
)"
R"(// first 120 values, qh holds 4 trits per byte for the last 8, both in the
)"
R"(// staged order of dequantize_row_ptq1_0.
)"
R"(typedef struct {
)"
R"(    uchar qs[24];
)"
R"(    uchar qh[2];
)"
R"(    half  d;
)"
R"(} block_ptq1_0;
)"
R"(
)"
R"(#ifdef INTEL_GPU
)"
R"(#define N_R0_PTQ1_0 4 // number of rows each subgroup works on
)"
R"(#define N_SG_PTQ1_0 2 // number of subgroups in a work group
)"
R"(#define N_SIMDWIDTH 16 // subgroup size
)"
R"(#elif defined (ADRENO_GPU)
)"
R"(#define N_R0_PTQ1_0 4
)"
R"(#define N_SG_PTQ1_0 2
)"
R"(#define N_SIMDWIDTH 64
)"
R"(#endif
)"
R"(
)"
R"(// values decoded per lane: one block spans exactly one subgroup
)"
R"(#define N_V_PTQ1_0 (QK_PTQ1_0/N_SIMDWIDTH)
)"
R"(
)"
R"(// trit at element slot v (0..127) mapped back from the staged storage:
)"
R"(// qs bytes 0..15 carry v < 80 as n*16+m, qs bytes 16..23 carry 80 <= v < 120
)"
R"(// as n*8+m, qh carries the trailing 8 as n*2+h.
)"
R"(// pow3 is selected by ternary, not a __constant array: the Adreno compiler
)"
R"(// misindexed the 5th element (81), zeroing every n=4 slot to -1 on device.
)"
R"(inline float block_ptq1_0_value(global block_ptq1_0 * qb, int v) {
)"
R"(    uint t;
)"
R"(    if (v < 80) {
)"
R"(        const uint b = qb->qs[v & 15];
)"
R"(        const uint n = v >> 4;
)"
R"(        t = (b * ((n == 4) ? 81u : (n == 3) ? 27u : (n == 2) ? 9u : (n == 1) ? 3u : 1u)) & 0xFFU;
)"
R"(    } else if (v < 120) {
)"
R"(        const uint b = qb->qs[16 + ((v - 80) & 7)];
)"
R"(        const uint n = (v - 80) >> 3;
)"
R"(        t = (b * ((n == 4) ? 81u : (n == 3) ? 27u : (n == 2) ? 9u : (n == 1) ? 3u : 1u)) & 0xFFU;
)"
R"(    } else {
)"
R"(        const uint b = qb->qh[(v - 120) & 1];
)"
R"(        const uint n = (v - 120) >> 1;
)"
R"(        t = (b * ((n == 3) ? 27u : (n == 2) ? 9u : (n == 1) ? 3u : 1u)) & 0xFFU;
)"
R"(    }
)"
R"(    return (float) ((t * 3U) >> 8) - 1.0f;
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
R"(kernel void kernel_mul_mv_ptq1_0_f32(
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
R"(    // ne00 is a multiple of QK_PTQ1_0 (host checked)
)"
R"(    int nb = ne00/QK_PTQ1_0;
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
R"(    int first_row = (r0*N_SG_PTQ1_0 + get_sub_group_id()) * N_R0_PTQ1_0;
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
R"(    // Row reads are NOT write-guarded below, so clamp tail rows (grid covers
)"
R"(    // ceil(ne01/4)) to the last valid row: reading past the final tensor of
)"
R"(    // the weights buffer can fault the GPU SMMU and reboot the device.
)"
R"(    global block_ptq1_0 * ax[N_R0_PTQ1_0];
)"
R"(    for (int row = 0; row < N_R0_PTQ1_0; ++row) {
)"
R"(        const int row_idx = min(first_row + row, ne01 - 1);
)"
R"(        ulong offset_src0 = (ulong)row_idx*nb01 + (i12/r2)*nb02 + (i13/r3)*nb03;
)"
R"(        ax[row] = (global block_ptq1_0 *) ((global char *) src0 + offset_src0);
)"
R"(    }
)"
R"(
)"
R"(    const short li = get_sub_group_local_id();
)"
R"(    const int   v0 = li*N_V_PTQ1_0;
)"
R"(
)"
R"(    float sumf[N_R0_PTQ1_0] = { 0.f };
)"
R"(
)"
R"(    // Each subgroup owns N_R0_PTQ1_0 rows and must visit every block itself:
)"
R"(    // sub_group_reduce_add cannot cross subgroups.
)"
R"(    for (int ib = 0; ib < nb; ++ib) {
)"
R"(        global float * yb = y + (ulong)ib*QK_PTQ1_0 + v0;
)"
R"(        float yl[N_V_PTQ1_0];
)"
R"(        for (int v = 0; v < N_V_PTQ1_0; ++v) {
)"
R"(            yl[v] = yb[v];
)"
R"(        }
)"
R"(
)"
R"(        for (short row = 0; row < N_R0_PTQ1_0; ++row) {
)"
R"(            global block_ptq1_0 * qb = ax[row] + ib;
)"
R"(            float acc = 0.f;
)"
R"(            for (int v = 0; v < N_V_PTQ1_0; ++v) {
)"
R"(                acc += block_ptq1_0_value(qb, v0 + v) * yl[v];
)"
R"(            }
)"
R"(            sumf[row] += (float)qb->d * acc;
)"
R"(        }
)"
R"(    }
)"
R"(
)"
R"(    global float * dst_f32 = (global float *) dst + (ulong)im*ne0*ne1 + (ulong)r1*ne0;
)"
R"(
)"
R"(    for (int row = 0; row < N_R0_PTQ1_0; ++row) {
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
