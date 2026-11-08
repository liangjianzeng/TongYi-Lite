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

    // [tongyi 2026-11-08] v2 重写：per-lane 恒量外提 + 对齐 ushort 读 + 寄存器解包。
    //  -1 在 float 域（无符号 -1U 下溢 = 2^32-1，740/830 双机 2^33 级乱值定罪）。
    //  pow3 外提为标量 select（830 __constant 数组第 5 项误编档案 2026-09-27 勿回退）。
    //  740 驱动对动态索引字节读+select 链误编（旧内核 740 单 trit 错，本版向量读绕开）。
    //  每个 lane 的 (byte_off, p3) 在全部 K 块上恒定。
    uint byte_off; uint p3;
    if (v0 < 80) {
        byte_off = (uint)(v0 & 15);
        const uint n = (uint)v0 >> 4;
        p3 = (n == 4) ? 81u : (n == 3) ? 27u : (n == 2) ? 9u : (n == 1) ? 3u : 1u;
    } else if (v0 < 120) {
        byte_off = 16u + (uint)((v0 - 80) & 7);
        const uint n = (uint)(v0 - 80) >> 3;
        p3 = (n == 4) ? 81u : (n == 3) ? 27u : (n == 2) ? 9u : (n == 1) ? 3u : 1u;
    } else {
        byte_off = 24u;
        const uint n = (uint)(v0 - 120) >> 1;
        p3 = (n == 3) ? 27u : (n == 2) ? 9u : (n == 1) ? 3u : 1u;
    }
    global const uchar * lane_base[N_R0_PTQ1_0];
    for (int row = 0; row < N_R0_PTQ1_0; ++row) {
        lane_base[row] = (global const uchar *)(ax[row]) + byte_off;
    }

    const int nb2 = nb & ~1;
    int ib = 0;
    for (; ib < nb2; ib += 2) {
        float yl0[N_V_PTQ1_0], yl1[N_V_PTQ1_0];
        {
            global float * yb0 = y + (ulong)ib*QK_PTQ1_0 + v0;
            global float * yb1 = yb0 + QK_PTQ1_0;
            for (int v = 0; v < N_V_PTQ1_0; ++v) { yl0[v] = yb0[v]; yl1[v] = yb1[v]; }
        }
        for (short row = 0; row < N_R0_PTQ1_0; ++row) {
            global const uchar * lb = lane_base[row] + (ulong)ib*28;
            global block_ptq1_0 * qb0 = ax[row] + ib;
            global block_ptq1_0 * qb1 = qb0 + 1;
            // 对齐 ushort：A 字节 = 低、B 字节 = 高（byte_off 恒偶，块基址 28B 步进）
            const ushort uv0 = *(global const ushort *)lb;
            const ushort uv1 = *(global const ushort *)(lb + 28);
            const float acc0 = ((float)((((uv0 & 0xFFU) * p3) & 0xFFU) * 3U >> 8) - 1.0f) * yl0[0]
                             + ((float)((((uv0 >> 8)   * p3) & 0xFFU) * 3U >> 8) - 1.0f) * yl0[1];
            const float acc1 = ((float)((((uv1 & 0xFFU) * p3) & 0xFFU) * 3U >> 8) - 1.0f) * yl1[0]
                             + ((float)((((uv1 >> 8)   * p3) & 0xFFU) * 3U >> 8) - 1.0f) * yl1[1];
            sumf[row] += (float)qb0->d * acc0 + (float)qb1->d * acc1;
        }
    }
    for (; ib < nb; ++ib) {
        global float * yb = y + (ulong)ib*QK_PTQ1_0 + v0;
        float yl[N_V_PTQ1_0];
        for (int v = 0; v < N_V_PTQ1_0; ++v) yl[v] = yb[v];
        for (short row = 0; row < N_R0_PTQ1_0; ++row) {
            global const uchar * lb = lane_base[row] + (ulong)ib*28;
            global block_ptq1_0 * qb = ax[row] + ib;
            const ushort uv = *(global const ushort *)lb;
            const float acc = ((float)((((uv & 0xFFU) * p3) & 0xFFU) * 3U >> 8) - 1.0f) * yl[0]
                            + ((float)((((uv >> 8)   * p3) & 0xFFU) * 3U >> 8) - 1.0f) * yl[1];
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
