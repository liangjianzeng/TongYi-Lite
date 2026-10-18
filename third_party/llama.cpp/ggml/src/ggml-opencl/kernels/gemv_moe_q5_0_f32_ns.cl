#pragma OPENCL EXTENSION cl_khr_fp16 : enable
#pragma OPENCL EXTENSION cl_khr_subgroups : enable
#pragma OPENCL EXTENSION cl_qcom_reqd_sub_group_size : enable
// [dspark 2026-10-16] generic backend (rusticl/freedreno): emulate the QCOM
// extra-vector-types float8/float32 with clang ext_vector_type (guarded by the
// host-injected GGML_GENERIC_SUBGROUP_SHUFFLE define; no-op on Adreno).
#ifdef GGML_GENERIC_SUBGROUP_SHUFFLE
typedef float __attribute__((ext_vector_type(8))) float8;
#ifndef GGML_MESA_SPIRV
typedef float __attribute__((ext_vector_type(32))) float32;
#endif
#endif

// [dspark 2026-10-17] GGML_MESA_SPIRV: SPIR-V caps vectors at 16 components,
// so the 32-lane float32 accumulator cannot survive rusticl's SPIR-V path.
// Emulate it as a lo/hi float16 pair; every access site below (lo/hi
// quadrants + scalar lanes) maps 1:1, arithmetic is bit-identical.
#ifdef GGML_MESA_SPIRV
#define REGC_Q00 reg_c_lo.lo
#define REGC_Q01 reg_c_lo.hi
#define REGC_Q10 reg_c_hi.lo
#define REGC_Q11 reg_c_hi.hi
#define REGC_LO  reg_c_lo
#define REGC_HI  reg_c_hi
#else
#define REGC_Q00 reg_c.lo.lo
#define REGC_Q01 reg_c.lo.hi
#define REGC_Q10 reg_c.hi.lo
#define REGC_Q11 reg_c.hi.hi
#define REGC_LO  (reg_c.lo)
#define REGC_HI  (reg_c.hi)
#endif



#define QK_Q5_0 32
#define N_SIMDGROUP 4
#define SIMDGROUP_WIDTH 64

static inline float8 q5_0_to_fp32_packed8(ushort2 qs5x8, uchar qh5x8) {
    float8 fp32x8;
    fp32x8.s0 = (float)((( qs5x8.s0 & 0x000F)        | (( qh5x8       & 0x01) << 4)) - 16);
    fp32x8.s1 = (float)((((qs5x8.s0 & 0x00F0) >> 4 ) | (((qh5x8 >> 1) & 0x01) << 4)) - 16);
    fp32x8.s2 = (float)((((qs5x8.s0 & 0x0F00) >> 8 ) | (((qh5x8 >> 2) & 0x01) << 4)) - 16);
    fp32x8.s3 = (float)((((qs5x8.s0 & 0xF000) >> 12) | (((qh5x8 >> 3) & 0x01) << 4)) - 16);
    fp32x8.s4 = (float)((( qs5x8.s1 & 0x000F)        | (((qh5x8 >> 4) & 0x01) << 4)) - 16);
    fp32x8.s5 = (float)((((qs5x8.s1 & 0x00F0) >> 4 ) | (((qh5x8 >> 5) & 0x01) << 4)) - 16);
    fp32x8.s6 = (float)((((qs5x8.s1 & 0x0F00) >> 8 ) | (((qh5x8 >> 6) & 0x01) << 4)) - 16);
    fp32x8.s7 = (float)((((qs5x8.s1 & 0xF000) >> 12) | (((qh5x8 >> 7) & 0x01) << 4)) - 16);
    return fp32x8;
}


__attribute__((qcom_reqd_sub_group_size("half")))
__kernel void kernel_gemv_moe_q5_0_f32_ns(
    __global    uint *           src0_qs,
    __global    uint *           src0_qh,
    __global    half *           src0_d,
    __read_only image1d_buffer_t src1,
    __global    uint *           src2,
    __global    float *          dst,
    ulong offsetd,
    uint  ne00,
    uint  ne01,
    uint  ne11
) {
    uint i01  = get_global_id(0);
    uint i20  = get_global_id(2);
    uint sgid = get_local_id(1);
    uint slid = get_local_id(0);  // [dspark] rusticl sg=128 spans rows; lane==local_id(0) by design

    if (i01 >= ne01) {
        return;
    }

    uint i11 = i20 % ne11;

    uint expert_id = src2[i20];
    uint expert_offset = expert_id * ne00 * ne01 / 32;

    __private float sum = 0.0f; // each thread calculate partial sum of one output

    // loop along ne00 in block granularity, skip 4 blocks every iter
    for (uint ib00 = sgid; ib00 < (ne00 / QK_Q5_0); ib00 += N_SIMDGROUP) {

        // load one block of q
        uint4 regQ;
        uint block_offset = expert_offset * 4 + ib00 * ne01 * 4 + i01;

        regQ.s0 = src0_qs[block_offset];
        regQ.s1 = src0_qs[block_offset + ne01];
        regQ.s2 = src0_qs[block_offset + ne01 * 2];
        regQ.s3 = src0_qs[block_offset + ne01 * 3];

        uint offset = i11 * ne00 / 4 + ib00 * 8;

        uchar4 regQh = as_uchar4(src0_qh[ib00 * ne01 + i01 + expert_offset]);
        half regS = src0_d[ib00 * ne01 + i01 + expert_offset];

        float8 fp32x8 = q5_0_to_fp32_packed8(as_ushort2(regQ.s0), regQh.s0);

        float4 shared_y4;
        shared_y4 = read_imagef(src1, (offset + 0));
        float4 acc = shared_y4 * fp32x8.lo;

        shared_y4 = read_imagef(src1, (offset + 1));
        acc += shared_y4 * fp32x8.hi;

        fp32x8 = q5_0_to_fp32_packed8(as_ushort2(regQ.s1), regQh.s1);

        shared_y4 = read_imagef(src1, (offset + 2));
        acc += shared_y4 * fp32x8.lo;

        shared_y4 = read_imagef(src1, (offset + 3));
        acc += shared_y4 * fp32x8.hi;


        fp32x8 = q5_0_to_fp32_packed8(as_ushort2(regQ.s2), regQh.s2);

        shared_y4 = read_imagef(src1, (offset + 4));
        acc += shared_y4 * fp32x8.lo;

        shared_y4 = read_imagef(src1, (offset + 5));
        acc += shared_y4 * fp32x8.hi;


        fp32x8 = q5_0_to_fp32_packed8(as_ushort2(regQ.s3), regQh.s3);

        shared_y4 = read_imagef(src1, (offset + 6));
        acc += shared_y4 * fp32x8.lo;

        shared_y4 = read_imagef(src1, (offset + 7));
        acc += shared_y4 * fp32x8.hi;

        sum += (float)(regS) * ((acc.s0 + acc.s1) + (acc.s2 + acc.s3));
    }

    // reduction in local memory, assumes #subgroups=4
    __local float reduceLM[SIMDGROUP_WIDTH * (N_SIMDGROUP - 1)];
    if (sgid == 1) reduceLM[SIMDGROUP_WIDTH * 0 + slid] = sum;
    if (sgid == 2) reduceLM[SIMDGROUP_WIDTH * 1 + slid] = sum;
    if (sgid == 3) reduceLM[SIMDGROUP_WIDTH * 2 + slid] = sum;
    barrier(CLK_LOCAL_MEM_FENCE);
    if (sgid == 0) sum += reduceLM[SIMDGROUP_WIDTH * 0 + slid];
    if (sgid == 0) sum += reduceLM[SIMDGROUP_WIDTH * 1 + slid];
    if (sgid == 0) sum += reduceLM[SIMDGROUP_WIDTH * 2 + slid];

    // 1 outputs per thread in subgroup 0
    if (sgid == 0) {
        dst = dst + (offsetd >> 2);
        dst[i01 + i20 * ne01] = sum;
    }

}
