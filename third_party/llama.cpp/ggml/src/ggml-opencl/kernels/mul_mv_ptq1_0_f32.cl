#pragma OPENCL EXTENSION cl_khr_fp16 : enable

#ifdef cl_intel_subgroups
#pragma OPENCL EXTENSION cl_intel_subgroups : enable
#else
#pragma OPENCL EXTENSION cl_khr_subgroups : enable
#endif

#ifdef cl_intel_required_subgroup_size
#pragma OPENCL EXTENSION cl_intel_required_subgroup_size : enable
#define INTEL_GPU 1
#define REQD_SUBGROUP_SIZE_16 __attribute__((intel_reqd_sub_group_size(16)))
#elif defined(cl_qcom_reqd_sub_group_size)
#pragma OPENCL EXTENSION cl_qcom_reqd_sub_group_size : enable
#define ADRENO_GPU 1
#define REQD_SUBGROUP_SIZE_64  __attribute__((qcom_reqd_sub_group_size("half")))
#define REQD_SUBGROUP_SIZE_128 __attribute__((qcom_reqd_sub_group_size("full")))
#endif

#define QK_PTQ1_0 128

// Ternary block, 28 bytes / 128 values. qs holds 5 trits per byte for the
// first 120 values, qh holds 4 trits per byte for the last 8, both in the
// staged order of dequantize_row_ptq1_0.
typedef struct {
    uchar qs[24];
    uchar qh[2];
    half  d;
} block_ptq1_0;

#ifdef INTEL_GPU
#define N_R0_PTQ1_0 4 // number of rows each subgroup works on
#define N_SG_PTQ1_0 2 // number of subgroups in a work group
#define N_SIMDWIDTH 16 // subgroup size
#elif defined (ADRENO_GPU)
#define N_R0_PTQ1_0 4
#define N_SG_PTQ1_0 2
#define N_SIMDWIDTH 64
#endif

// values decoded per lane: one block spans exactly one subgroup
#define N_V_PTQ1_0 (QK_PTQ1_0/N_SIMDWIDTH)

// trit at element slot v (0..127) mapped back from the staged storage:
// qs bytes 0..15 carry v < 80 as n*16+m, qs bytes 16..23 carry 80 <= v < 120
// as n*8+m, qh carries the trailing 8 as n*2+h.
// pow3 is selected by ternary, not a __constant array: the Adreno compiler
// misindexed the 5th element (81), zeroing every n=4 slot to -1 on device.
inline float block_ptq1_0_value(global block_ptq1_0 * qb, int v) {
    uint t;
    if (v < 80) {
        const uint b = qb->qs[v & 15];
        const uint n = v >> 4;
        t = (b * ((n == 4) ? 81u : (n == 3) ? 27u : (n == 2) ? 9u : (n == 1) ? 3u : 1u)) & 0xFFU;
    } else if (v < 120) {
        const uint b = qb->qs[16 + ((v - 80) & 7)];
        const uint n = (v - 80) >> 3;
        t = (b * ((n == 4) ? 81u : (n == 3) ? 27u : (n == 2) ? 9u : (n == 1) ? 3u : 1u)) & 0xFFU;
    } else {
        const uint b = qb->qh[(v - 120) & 1];
        const uint n = (v - 120) >> 1;
        t = (b * ((n == 3) ? 27u : (n == 2) ? 9u : (n == 1) ? 3u : 1u)) & 0xFFU;
    }
    return (float) ((t * 3U) >> 8) - 1.0f;
}

#ifdef INTEL_GPU
REQD_SUBGROUP_SIZE_16
#elif defined (ADRENO_GPU)
REQD_SUBGROUP_SIZE_64
#endif
kernel void kernel_mul_mv_ptq1_0_f32(
    global char * src0,
    ulong         offset0,
    global char * src1,
    ulong         offset1,
    global char * dst,
    ulong         offsetd,
    int           ne00,
    int           ne01,
    ulong         nb01,
    ulong         nb02,
    ulong         nb03,
    int           ne12,
    ulong         nb11,
    ulong         nb12,
    ulong         nb13,
    int           ne0,
    int           ne1,
    int           r2,
    int           r3
) {
    src0 = (global char*)((global char*)src0 + offset0);
    src1 = (global char*)((global char*)src1 + offset1);
    dst  = (global char*)((global char*)dst  + offsetd);

    // ne00 is a multiple of QK_PTQ1_0 (host checked)
    int nb = ne00/QK_PTQ1_0;

    int r0 = get_group_id(0);
    int r1 = get_group_id(1);
    int im = get_group_id(2);

    int first_row = (r0*N_SG_PTQ1_0 + get_sub_group_id()) * N_R0_PTQ1_0;

    uint i12 = im%ne12;
    uint i13 = im/ne12;

    ulong offset_src1 = r1*nb11 + i12*nb12 + i13*nb13;
    global float * y  = (global float *) (src1 + offset_src1);

    // pointers to src0 rows
    // Row reads are NOT write-guarded below, so clamp tail rows (grid covers
    // ceil(ne01/4)) to the last valid row: reading past the final tensor of
    // the weights buffer can fault the GPU SMMU and reboot the device.
    global block_ptq1_0 * ax[N_R0_PTQ1_0];
    for (int row = 0; row < N_R0_PTQ1_0; ++row) {
        const int row_idx = min(first_row + row, ne01 - 1);
        ulong offset_src0 = (ulong)row_idx*nb01 + (i12/r2)*nb02 + (i13/r3)*nb03;
        ax[row] = (global block_ptq1_0 *) ((global char *) src0 + offset_src0);
    }

    const short li = get_sub_group_local_id();
    const int   v0 = li*N_V_PTQ1_0;

    float sumf[N_R0_PTQ1_0] = { 0.f };

    // Each subgroup owns N_R0_PTQ1_0 rows and must visit every block itself:
    // sub_group_reduce_add cannot cross subgroups.
    for (int ib = 0; ib < nb; ++ib) {
        global float * yb = y + (ulong)ib*QK_PTQ1_0 + v0;
        float yl[N_V_PTQ1_0];
        for (int v = 0; v < N_V_PTQ1_0; ++v) {
            yl[v] = yb[v];
        }

        for (short row = 0; row < N_R0_PTQ1_0; ++row) {
            global block_ptq1_0 * qb = ax[row] + ib;
            float acc = 0.f;
            for (int v = 0; v < N_V_PTQ1_0; ++v) {
                acc += block_ptq1_0_value(qb, v0 + v) * yl[v];
            }
            sumf[row] += (float)qb->d * acc;
        }
    }

    global float * dst_f32 = (global float *) dst + (ulong)im*ne0*ne1 + (ulong)r1*ne0;

    for (int row = 0; row < N_R0_PTQ1_0; ++row) {
        float tot = sub_group_reduce_add(sumf[row]);

        if (get_sub_group_local_id() == 0 && first_row + row < ne01) {
            dst_f32[first_row + row] = tot;
        }
    }
}
