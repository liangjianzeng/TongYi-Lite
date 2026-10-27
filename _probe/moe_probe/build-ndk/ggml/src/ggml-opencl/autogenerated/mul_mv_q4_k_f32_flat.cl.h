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
R"(// [dspark 2026-10-17] WG={64,2}=128 on rusticl/ir3 forms ONE 128-lane subgroup
)"
R"(// (vendor pins two 64-lane subgroups via qcom attr; reqd_sub_group_size is
)"
R"(// IGNORED by rusticl, probe4). Kernels that assume 2x64 must therefore:
)"
R"(//  - use get_local_id(0)/get_local_id(1) instead of subgroup lane/id queries,
)"
R"(//  - reduce with a xor-32..1 butterfly: on vendor (sg=64) it is the full
)"
R"(//    subgroup reduce; on rusticl (sg=128, lanes linearized x-fastest) it
)"
R"(//    reduces exactly the 64 lanes of one y-row.
)"
R"(// NOTE: no cl_khr_subgroup_shuffle pragma here — enabling it pulls the QCOM
)"
R"(// enum section of the injected kernel header and collides with build defines.
)"
R"(#ifdef GGML_GENERIC_SUBGROUP_SHUFFLE
)"
R"(// rusticl/freedreno: the injected kernel header exposes no prototype for the
)"
R"(// core CL 3.0 sub_group_shuffle_* builtins (probe2/probe5), and a self-declared
)"
R"(// prototype compiles but fails to lower (err=-6 at the call site). Also, the
)"
R"(// WG={64,2} forms ONE 128-lane subgroup spanning both y-rows, so even a working
)"
R"(// sub_group_reduce_add would mix rows. Reduce via local memory, grouped by the
)"
R"(// get_local_id(1) y-row; x-fastest linearization makes id(0) the in-row lane.
)"
R"(#define GGML_REDUCE64(v) do { \
)"
R"(    const uint gry = get_local_id(1) * 64u + get_local_id(0); \
)"
R"(    ggml_red[gry] = (v); \
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE); \
)"
R"(    if (get_local_id(0) < 32u) ggml_red[gry] += ggml_red[gry + 32u]; \
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE); \
)"
R"(    if (get_local_id(0) < 16u) ggml_red[gry] += ggml_red[gry + 16u]; \
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE); \
)"
R"(    if (get_local_id(0) <  8u) ggml_red[gry] += ggml_red[gry +  8u]; \
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE); \
)"
R"(    if (get_local_id(0) <  4u) ggml_red[gry] += ggml_red[gry +  4u]; \
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE); \
)"
R"(    if (get_local_id(0) <  2u) ggml_red[gry] += ggml_red[gry +  2u]; \
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE); \
)"
R"(    if (get_local_id(0) <  1u) ggml_red[gry] += ggml_red[gry +  1u]; \
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE); \
)"
R"(    (v) = ggml_red[get_local_id(1) * 64u]; \
)"
R"(} while(0)
)"
R"(#else
)"
R"(#define GGML_REDUCE64(v) do { (v) = sub_group_reduce_add((v)); } while(0)
)"
R"(#endif
)"
R"(
)"
R"(
)"
R"(//------------------------------------------------------------------------------
)"
R"(// block_q4_K
)"
R"(//------------------------------------------------------------------------------
)"
R"(#define QK_K            256
)"
R"(#define BLOCK_Q4K_SIZE  144
)"
R"(#define K_SCALE_SIZE    12
)"
R"(
)"
R"(// 8 blocks of 32 elements each
)"
R"(// weight is represented as x = a * q + b
)"
R"(typedef struct {
)"
R"(    half d;    // super-block scale for quantized scales
)"
R"(    half dmin; // super-block scale for quantized mins
)"
R"(
)"
R"(    uchar scales[K_SCALE_SIZE]; // scales and mins, quantized with 6 bits
)"
R"(    uchar qs[QK_K/2];           // 4-bit quants
)"
R"(} block_q4_K;
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
R"(#define N_DST 16 // number of rows each SIMD group works on (Intel: 8->16, 2x further activation reuse; 32 spills registers)
)"
R"(#define N_SIMDGROUP 1 // number of SIMD groups in a thread group
)"
R"(#define N_SIMDWIDTH 16 // SIMD group size
)"
R"(#elif defined (ADRENO_GPU)
)"
R"(#define N_DST 16
)"
R"(#define N_SIMDGROUP 2
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
R"(// each thread in a subgroup processes a block (32 weights)
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
R"(kernel void kernel_mul_mv_q4_K_f32_flat(
)"
R"(    global uchar * src0_q,
)"
R"(    global uchar * src0_s,
)"
R"(    global half  * src0_d,
)"
R"(    global half  * src0_dm,
)"
R"(    global char  * src1,
)"
R"(    int offset1,
)"
R"(    global char  * dst,
)"
R"(    int offsetd,
)"
R"(    int ne00,
)"
R"(    int ne01,
)"
R"(    ulong nb01,
)"
R"(    ulong nb02,
)"
R"(    ulong nb03,
)"
R"(    int ne12,
)"
R"(    ulong nb11,
)"
R"(    ulong nb12,
)"
R"(    ulong nb13,
)"
R"(    int ne0,
)"
R"(    int ne1,
)"
R"(    int r2,
)"
R"(    int r3
)"
R"() {
)"
R"(    src1 = src1 + offset1;
)"
R"(    dst  = dst  + offsetd;
)"
R"(
)"
R"(    // scratch for the rusticl row reduction (must be at kernel function scope)
)"
R"(    __local float ggml_red[128];
)"
R"(
)"
R"(    ushort kmask1 = 0x3f3f;
)"
R"(    ushort kmask2 = 0x0f0f;
)"
R"(    ushort kmask3 = 0xc0c0;
)"
R"(
)"
R"(    int ix = get_local_id(0)/8;
)"
R"(    int it = get_local_id(0)%8;
)"
R"(    int iq = it/4;
)"
R"(    int ir = it%4;
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
R"(    int first_row = (r0 * N_SIMDGROUP + get_local_id(1)) * N_DST;
)"
R"(
)"
R"(    int i12 = im%ne12;
)"
R"(    int i13 = im/ne12;
)"
R"(
)"
R"(    int offset_src0 = (first_row*nb01 + (i12/r2)*nb02 + (i13/r3)*nb03)/BLOCK_Q4K_SIZE;
)"
R"(    uint blk = nb01 / BLOCK_Q4K_SIZE;
)"
R"(    global uchar * blk_q     = (global uchar *)src0_q  + offset_src0*(QK_K/2);
)"
R"(    global uchar * blk_s     = (global uchar *)src0_s  + offset_src0*K_SCALE_SIZE;
)"
R"(    global half  * blk_d     = (global half  *)src0_d  + offset_src0;
)"
R"(    global half  * blk_dm    = (global half  *)src0_dm + offset_src0;
)"
R"(
)"
R"(    int offset_src1 = r1*nb11 + (i12)*nb12 + (i13)*nb13;
)"
R"(    global float * y = (global float *)(src1 + offset_src1);
)"
R"(
)"
R"(    float yl[16];
)"
R"(    float yh[16];
)"
R"(    float sumf[N_DST] = {0.f};
)"
R"(    float all_sum;
)"
R"(
)"
R"(    global float * y4 = y + ix * QK_K + 64 * iq + 8 * ir;
)"
R"(
)"
R"(    ushort  sc16[4];
)"
R"(    uchar * sc8 = (uchar *)sc16;
)"
R"(
)"
R"(    for (int ib = ix; ib < nb; ib += BLOCK_STRIDE) {
)"
R"(        float4 sumy = {0.f, 0.f, 0.f, 0.f};
)"
R"(        for (int i = 0; i < 8; ++i) {
)"
R"(            yl[i+0] = y4[i+0];
)"
R"(            sumy.s0 += yl[i+0];
)"
R"(
)"
R"(            yl[i+8] = y4[i+32];
)"
R"(            sumy.s1 += yl[i+8];
)"
R"(
)"
R"(            yh[i+0] = y4[i+128];
)"
R"(            sumy.s2 += yh[i+0];
)"
R"(
)"
R"(            yh[i+8] = y4[i+160];
)"
R"(            sumy.s3 += yh[i+8];
)"
R"(        }
)"
R"(
)"
R"(        global ushort * q1 = (global ushort *)(blk_q + ib * (QK_K/2)) + (16 * iq + 4 * ir);
)"
R"(        global ushort * sc = (global ushort *)(blk_s + ib * K_SCALE_SIZE) + iq;
)"
R"(        global half   * d  = blk_d + ib;
)"
R"(        global half   * dm = blk_dm + ib;
)"
R"(
)"
R"(        for (int row = 0; row < N_DST; row++) {
)"
R"(            sc16[0] = sc[0] & kmask1;
)"
R"(            sc16[1] = sc[2] & kmask1;
)"
R"(            sc16[2] = ((sc[4] >> 0) & kmask2) | ((sc[0] & kmask3) >> 2);
)"
R"(            sc16[3] = ((sc[4] >> 4) & kmask2) | ((sc[2] & kmask3) >> 2);
)"
R"(
)"
R"(            global ushort * q2 = q1 + 32;
)"
R"(
)"
R"(            // Load the 4 q1 / 4 q2 quant ushorts as 2 uints each. 16-bit integer ops are
)"
R"(            // disproportionately slow on the A7X (E031.41) compiler; keeping the dequant
)"
R"(            // operands in 32-bit registers avoids the ushort path. q1/q2 are 4-byte aligned
)"
R"(            // (ib*128 + (32*iq+8*ir) bytes; q1 += blk*128 bytes/row). Math is unchanged:
)"
R"(            // w & 0x0F00 on the low/high halves equals the original ushort mask value.
)"
R"(            global uint * q1u = (global uint *)q1;
)"
R"(            global uint * q2u = (global uint *)q2;
)"
R"(            uint a0 = q1u[0], a1 = q1u[1];
)"
R"(            uint b0 = q2u[0], b1 = q2u[1];
)"
R"(            uint w0 = a0 & 0xFFFF, w1 = a0 >> 16, w2 = a1 & 0xFFFF, w3 = a1 >> 16;
)"
R"(            uint v0 = b0 & 0xFFFF, v1 = b0 >> 16, v2 = b1 & 0xFFFF, v3 = b1 >> 16;
)"
R"(
)"
R"(            float4 acc1, acc2;
)"
R"(            acc1.s0 = yl[0]*(w0&0x000F) + yl[ 2]*(w1&0x000F) + yl[ 4]*(w2&0x000F) + yl[ 6]*(w3&0x000F);
)"
R"(            acc1.s1 = yl[1]*(w0&0x0F00) + yl[ 3]*(w1&0x0F00) + yl[ 5]*(w2&0x0F00) + yl[ 7]*(w3&0x0F00);
)"
R"(            acc1.s2 = yl[8]*(w0&0x00F0) + yl[10]*(w1&0x00F0) + yl[12]*(w2&0x00F0) + yl[14]*(w3&0x00F0);
)"
R"(            acc1.s3 = yl[9]*(w0&0xF000) + yl[11]*(w1&0xF000) + yl[13]*(w2&0xF000) + yl[15]*(w3&0xF000);
)"
R"(            acc2.s0 = yh[0]*(v0&0x000F) + yh[ 2]*(v1&0x000F) + yh[ 4]*(v2&0x000F) + yh[ 6]*(v3&0x000F);
)"
R"(            acc2.s1 = yh[1]*(v0&0x0F00) + yh[ 3]*(v1&0x0F00) + yh[ 5]*(v2&0x0F00) + yh[ 7]*(v3&0x0F00);
)"
R"(            acc2.s2 = yh[8]*(v0&0x00F0) + yh[10]*(v1&0x00F0) + yh[12]*(v2&0x00F0) + yh[14]*(v3&0x00F0);
)"
R"(            acc2.s3 = yh[9]*(v0&0xF000) + yh[11]*(v1&0xF000) + yh[13]*(v2&0xF000) + yh[15]*(v3&0xF000);
)"
R"(
)"
R"(            float dall = *d;
)"
R"(            float dmin = *dm;
)"
R"(            sumf[row] += dall * ((acc1.s0 + 1.f/256.f * acc1.s1) * sc8[0] +
)"
R"(                                 (acc1.s2 + 1.f/256.f * acc1.s3) * sc8[1] * 1.f/16.f +
)"
R"(                                 (acc2.s0 + 1.f/256.f * acc2.s1) * sc8[4] +
)"
R"(                                 (acc2.s2 + 1.f/256.f * acc2.s3) * sc8[5] * 1.f/16.f) -
)"
R"(                         dmin * (sumy.s0 * sc8[2] + sumy.s1 * sc8[3] + sumy.s2 * sc8[6] + sumy.s3 * sc8[7]);
)"
R"(
)"
R"(            q1 += blk*64;
)"
R"(            sc += blk*6;
)"
R"(            d  += blk;
)"
R"(            dm += blk;
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
R"(        all_sum = sumf[row]; GGML_REDUCE64(all_sum);
)"
R"(        if (first_row + row < ne01) {
)"
R"(            if (get_local_id(0) == 0) {
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
