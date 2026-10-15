#pragma OPENCL EXTENSION cl_khr_fp16 : enable
#pragma OPENCL EXTENSION cl_khr_subgroups : enable

// [dspark 2026-10-14] SGB bitcast shims. Host passes -DSGB_FLOAT_BROKEN when
// the driver's online compiler lacks float overloads of sub_group_broadcast
// (Adreno 740: only scalar uint/int/long/ulong exist). Bitcast float<->uint,
// broadcast as integer, cast back — bitwise identical, subgroup-uniform.
// [dspark 2026-10-14] Scalar-float subgroup broadcast. 740's online compiler
// lacks float overloads of sub_group_broadcast entirely -> host passes
// -DSGB_SCALAR_BROKEN and broadcasts go through the uint-bitcast shim.
// 830 (E031.47) has working float broadcast but miscompiles kernels whose
// broadcasts go through an inline wrapper, even in pass-through form
// (NMSE~2.2, 2026-10-14) -> uses the direct builtin. All call sites are
// per-component scalar: no vector broadcast anywhere.
#ifdef SGB_SCALAR_BROKEN
inline float sgb_f(float v, uint lid) {
    return as_float(sub_group_broadcast(as_uint(v), lid));
}
#define SGB_BC(v, lid) sgb_f(v, lid)
#else
#define SGB_BC(v, lid) sub_group_broadcast(v, lid)
#endif

#ifdef cl_qcom_reqd_sub_group_size
#pragma OPENCL EXTENSION cl_qcom_reqd_sub_group_size : enable
#define ADRENO_GPU 1
#define REQD_SUBGROUP_SIZE_64 __attribute__((qcom_reqd_sub_group_size("half")))
#endif

// the driver's online compiler lacks float overloads of sub_group_broadcast
// (Adreno 740: only scalar uint/int/long/ulong exist). Bitcast float<->uint,
// broadcast as integer, cast back — bitwise identical, subgroup-uniform.
// assume
#define QK4_0 32
#define N_SIMDGROUP 4

#define dequantizeBlockAccum_ns_sgbroadcast_1_hi(total_sums, bits4, scale, y) \
    float shared_y; \
    shared_y = SGB_BC(y.s0, 0); \
    total_sums.s0 += ((bits4.s0 & 0x000F) - 8) * scale.s0 * shared_y; \
    total_sums.s1 += ((bits4.s1 & 0x000F) - 8) * scale.s1 * shared_y; \
    shared_y = SGB_BC(y.s1, 0); \
    total_sums.s0 += (((bits4.s0 & 0x00F0) >> 4) - 8) * scale.s0 * shared_y; \
    total_sums.s1 += (((bits4.s1 & 0x00F0) >> 4) - 8) * scale.s1 * shared_y; \
    shared_y = SGB_BC(y.s2, 0); \
    total_sums.s0 += (((bits4.s0 & 0x0F00) >> 8) - 8) * scale.s0 * shared_y; \
    total_sums.s1 += (((bits4.s1 & 0x0F00) >> 8) - 8) * scale.s1 * shared_y; \
    shared_y = SGB_BC(y.s3, 0); \
    total_sums.s0 += (((bits4.s0 & 0xF000) >> 12) - 8) * scale.s0 * shared_y; \
    total_sums.s1 += (((bits4.s1 & 0xF000) >> 12) - 8) * scale.s1 * shared_y; \
    shared_y = SGB_BC(y.s4, 0); \
    total_sums.s0 += ((bits4.s2 & 0x000F) - 8) * scale.s0 * shared_y; \
    total_sums.s1 += ((bits4.s3 & 0x000F) - 8) * scale.s1 * shared_y; \
    shared_y = SGB_BC(y.s5, 0); \
    total_sums.s0 += (((bits4.s2 & 0x00F0) >> 4) - 8) * scale.s0 * shared_y; \
    total_sums.s1 += (((bits4.s3 & 0x00F0) >> 4) - 8) * scale.s1 * shared_y; \
    shared_y = SGB_BC(y.s6, 0); \
    total_sums.s0 += (((bits4.s2 & 0x0F00) >> 8) - 8) * scale.s0 * shared_y; \
    total_sums.s1 += (((bits4.s3 & 0x0F00) >> 8) - 8) * scale.s1 * shared_y; \
    shared_y = SGB_BC(y.s7, 0); \
    total_sums.s0 += (((bits4.s2 & 0xF000) >> 12) - 8) * scale.s0 * shared_y; \
    total_sums.s1 += (((bits4.s3 & 0xF000) >> 12) - 8) * scale.s1 * shared_y; \
    shared_y = SGB_BC(y.s0, 1); \
    total_sums.s0 += ((bits4.s4 & 0x000F) - 8) * scale.s0 * shared_y; \
    total_sums.s1 += ((bits4.s5 & 0x000F) - 8) * scale.s1 * shared_y; \
    shared_y = SGB_BC(y.s1, 1); \
    total_sums.s0 += (((bits4.s4 & 0x00F0) >> 4) - 8) * scale.s0 * shared_y; \
    total_sums.s1 += (((bits4.s5 & 0x00F0) >> 4) - 8) * scale.s1 * shared_y; \
    shared_y = SGB_BC(y.s2, 1); \
    total_sums.s0 += (((bits4.s4 & 0x0F00) >> 8) - 8) * scale.s0 * shared_y; \
    total_sums.s1 += (((bits4.s5 & 0x0F00) >> 8) - 8) * scale.s1 * shared_y; \
    shared_y = SGB_BC(y.s3, 1); \
    total_sums.s0 += (((bits4.s4 & 0xF000) >> 12) - 8) * scale.s0 * shared_y; \
    total_sums.s1 += (((bits4.s5 & 0xF000) >> 12) - 8) * scale.s1 * shared_y; \
    shared_y = SGB_BC(y.s4, 1); \
    total_sums.s0 += ((bits4.s6 & 0x000F) - 8) * scale.s0 * shared_y; \
    total_sums.s1 += ((bits4.s7 & 0x000F) - 8) * scale.s1 * shared_y; \
    shared_y = SGB_BC(y.s5, 1); \
    total_sums.s0 += (((bits4.s6 & 0x00F0) >> 4) - 8) * scale.s0 * shared_y; \
    total_sums.s1 += (((bits4.s7 & 0x00F0) >> 4) - 8) * scale.s1 * shared_y; \
    shared_y = SGB_BC(y.s6, 1); \
    total_sums.s0 += (((bits4.s6 & 0x0F00) >> 8) - 8) * scale.s0 * shared_y; \
    total_sums.s1 += (((bits4.s7 & 0x0F00) >> 8) - 8) * scale.s1 * shared_y; \
    shared_y = SGB_BC(y.s7, 1); \
    total_sums.s0 += (((bits4.s6 & 0xF000) >> 12) - 8) * scale.s0 * shared_y; \
    total_sums.s1 += (((bits4.s7 & 0xF000) >> 12) - 8) * scale.s1 * shared_y; \


#define dequantizeBlockAccum_ns_sgbroadcast_1_lo(total_sums, bits4, scale, y) \
    shared_y = SGB_BC(y.s0, 2); \
    total_sums.s0 += ((bits4.s0 & 0x000F) - 8) * scale.s0 * shared_y; \
    total_sums.s1 += ((bits4.s1 & 0x000F) - 8) * scale.s1 * shared_y; \
    shared_y = SGB_BC(y.s1, 2); \
    total_sums.s0 += (((bits4.s0 & 0x00F0) >> 4) - 8) * scale.s0 * shared_y; \
    total_sums.s1 += (((bits4.s1 & 0x00F0) >> 4) - 8) * scale.s1 * shared_y; \
    shared_y = SGB_BC(y.s2, 2); \
    total_sums.s0 += (((bits4.s0 & 0x0F00) >> 8) - 8) * scale.s0 * shared_y; \
    total_sums.s1 += (((bits4.s1 & 0x0F00) >> 8) - 8) * scale.s1 * shared_y; \
    shared_y = SGB_BC(y.s3, 2); \
    total_sums.s0 += (((bits4.s0 & 0xF000) >> 12) - 8) * scale.s0 * shared_y; \
    total_sums.s1 += (((bits4.s1 & 0xF000) >> 12) - 8) * scale.s1 * shared_y; \
    shared_y = SGB_BC(y.s4, 2); \
    total_sums.s0 += ((bits4.s2 & 0x000F) - 8) * scale.s0 * shared_y; \
    total_sums.s1 += ((bits4.s3 & 0x000F) - 8) * scale.s1 * shared_y; \
    shared_y = SGB_BC(y.s5, 2); \
    total_sums.s0 += (((bits4.s2 & 0x00F0) >> 4) - 8) * scale.s0 * shared_y; \
    total_sums.s1 += (((bits4.s3 & 0x00F0) >> 4) - 8) * scale.s1 * shared_y; \
    shared_y = SGB_BC(y.s6, 2); \
    total_sums.s0 += (((bits4.s2 & 0x0F00) >> 8) - 8) * scale.s0 * shared_y; \
    total_sums.s1 += (((bits4.s3 & 0x0F00) >> 8) - 8) * scale.s1 * shared_y; \
    shared_y = SGB_BC(y.s7, 2); \
    total_sums.s0 += (((bits4.s2 & 0xF000) >> 12) - 8) * scale.s0 * shared_y; \
    total_sums.s1 += (((bits4.s3 & 0xF000) >> 12) - 8) * scale.s1 * shared_y; \
    shared_y = SGB_BC(y.s0, 3); \
    total_sums.s0 += ((bits4.s4 & 0x000F) - 8) * scale.s0 * shared_y; \
    total_sums.s1 += ((bits4.s5 & 0x000F) - 8) * scale.s1 * shared_y; \
    shared_y = SGB_BC(y.s1, 3); \
    total_sums.s0 += (((bits4.s4 & 0x00F0) >> 4) - 8) * scale.s0 * shared_y; \
    total_sums.s1 += (((bits4.s5 & 0x00F0) >> 4) - 8) * scale.s1 * shared_y; \
    shared_y = SGB_BC(y.s2, 3); \
    total_sums.s0 += (((bits4.s4 & 0x0F00) >> 8) - 8) * scale.s0 * shared_y; \
    total_sums.s1 += (((bits4.s5 & 0x0F00) >> 8) - 8) * scale.s1 * shared_y; \
    shared_y = SGB_BC(y.s3, 3); \
    total_sums.s0 += (((bits4.s4 & 0xF000) >> 12) - 8) * scale.s0 * shared_y; \
    total_sums.s1 += (((bits4.s5 & 0xF000) >> 12) - 8) * scale.s1 * shared_y; \
    shared_y = SGB_BC(y.s4, 3); \
    total_sums.s0 += ((bits4.s6 & 0x000F) - 8) * scale.s0 * shared_y; \
    total_sums.s1 += ((bits4.s7 & 0x000F) - 8) * scale.s1 * shared_y; \
    shared_y = SGB_BC(y.s5, 3); \
    total_sums.s0 += (((bits4.s6 & 0x00F0) >> 4) - 8) * scale.s0 * shared_y; \
    total_sums.s1 += (((bits4.s7 & 0x00F0) >> 4) - 8) * scale.s1 * shared_y; \
    shared_y = SGB_BC(y.s6, 3); \
    total_sums.s0 += (((bits4.s6 & 0x0F00) >> 8) - 8) * scale.s0 * shared_y; \
    total_sums.s1 += (((bits4.s7 & 0x0F00) >> 8) - 8) * scale.s1 * shared_y; \
    shared_y = SGB_BC(y.s7, 3); \
    total_sums.s0 += (((bits4.s6 & 0xF000) >> 12) - 8) * scale.s0 * shared_y; \
    total_sums.s1 += (((bits4.s7 & 0xF000) >> 12) - 8) * scale.s1 * shared_y; \


#define dequantizeBlockAccum_ns_sgbroadcast_8_hi(total_sums, bits4, scale, y) \
    float8 shared_y; \
    shared_y.s0 = SGB_BC(y.s0, 0); \
    shared_y.s1 = SGB_BC(y.s1, 0); \
    shared_y.s2 = SGB_BC(y.s2, 0); \
    shared_y.s3 = SGB_BC(y.s3, 0); \
    shared_y.s4 = SGB_BC(y.s4, 0); \
    shared_y.s5 = SGB_BC(y.s5, 0); \
    shared_y.s6 = SGB_BC(y.s6, 0); \
    shared_y.s7 = SGB_BC(y.s7, 0); \
    total_sums.s0 += ((bits4.s0 & 0x000F) - 8) * scale.s0 * shared_y.s0; \
    total_sums.s0 += (((bits4.s0 & 0x00F0) >> 4) - 8) * scale.s0 * shared_y.s1; \
    total_sums.s0 += (((bits4.s0 & 0x0F00) >> 8) - 8) * scale.s0 * shared_y.s2; \
    total_sums.s0 += (((bits4.s0 & 0xF000) >> 12) - 8) * scale.s0 * shared_y.s3; \
    total_sums.s0 += ((bits4.s2 & 0x000F) - 8) * scale.s0 * shared_y.s4; \
    total_sums.s0 += (((bits4.s2 & 0x00F0) >> 4) - 8) * scale.s0 * shared_y.s5; \
    total_sums.s0 += (((bits4.s2 & 0x0F00) >> 8) - 8) * scale.s0 * shared_y.s6; \
    total_sums.s0 += (((bits4.s2 & 0xF000) >> 12) - 8) * scale.s0 * shared_y.s7; \
    total_sums.s1 += ((bits4.s1 & 0x000F) - 8) * scale.s1 * shared_y.s0; \
    total_sums.s1 += (((bits4.s1 & 0x00F0) >> 4) - 8) * scale.s1 * shared_y.s1; \
    total_sums.s1 += (((bits4.s1 & 0x0F00) >> 8) - 8) * scale.s1 * shared_y.s2; \
    total_sums.s1 += (((bits4.s1 & 0xF000) >> 12) - 8) * scale.s1 * shared_y.s3; \
    total_sums.s1 += ((bits4.s3 & 0x000F) - 8) * scale.s1 * shared_y.s4; \
    total_sums.s1 += (((bits4.s3 & 0x00F0) >> 4) - 8) * scale.s1 * shared_y.s5; \
    total_sums.s1 += (((bits4.s3 & 0x0F00) >> 8) - 8) * scale.s1 * shared_y.s6; \
    total_sums.s1 += (((bits4.s3 & 0xF000) >> 12) - 8) * scale.s1 * shared_y.s7; \
    shared_y.s0 = SGB_BC(y.s0, 1); \
    shared_y.s1 = SGB_BC(y.s1, 1); \
    shared_y.s2 = SGB_BC(y.s2, 1); \
    shared_y.s3 = SGB_BC(y.s3, 1); \
    shared_y.s4 = SGB_BC(y.s4, 1); \
    shared_y.s5 = SGB_BC(y.s5, 1); \
    shared_y.s6 = SGB_BC(y.s6, 1); \
    shared_y.s7 = SGB_BC(y.s7, 1); \
    total_sums.s0 += ((bits4.s4 & 0x000F) - 8) * scale.s0 * shared_y.s0; \
    total_sums.s0 += (((bits4.s4 & 0x00F0) >> 4) - 8) * scale.s0 * shared_y.s1; \
    total_sums.s0 += (((bits4.s4 & 0x0F00) >> 8) - 8) * scale.s0 * shared_y.s2; \
    total_sums.s0 += (((bits4.s4 & 0xF000) >> 12) - 8) * scale.s0 * shared_y.s3; \
    total_sums.s0 += ((bits4.s6 & 0x000F) - 8) * scale.s0 * shared_y.s4; \
    total_sums.s0 += (((bits4.s6 & 0x00F0) >> 4) - 8) * scale.s0 * shared_y.s5; \
    total_sums.s0 += (((bits4.s6 & 0x0F00) >> 8) - 8) * scale.s0 * shared_y.s6; \
    total_sums.s0 += (((bits4.s6 & 0xF000) >> 12) - 8) * scale.s0 * shared_y.s7; \
    total_sums.s1 += ((bits4.s5 & 0x000F) - 8) * scale.s1 * shared_y.s0; \
    total_sums.s1 += (((bits4.s5 & 0x00F0) >> 4) - 8) * scale.s1 * shared_y.s1; \
    total_sums.s1 += (((bits4.s5 & 0x0F00) >> 8) - 8) * scale.s1 * shared_y.s2; \
    total_sums.s1 += (((bits4.s5 & 0xF000) >> 12) - 8) * scale.s1 * shared_y.s3; \
    total_sums.s1 += ((bits4.s7 & 0x000F) - 8) * scale.s1 * shared_y.s4; \
    total_sums.s1 += (((bits4.s7 & 0x00F0) >> 4) - 8) * scale.s1 * shared_y.s5; \
    total_sums.s1 += (((bits4.s7 & 0x0F00) >> 8) - 8) * scale.s1 * shared_y.s6; \
    total_sums.s1 += (((bits4.s7 & 0xF000) >> 12) - 8) * scale.s1 * shared_y.s7; \


#define dequantizeBlockAccum_ns_sgbroadcast_8_lo(total_sums, bits4, scale, y) \
    shared_y.s0 = SGB_BC(y.s0, 2); \
    shared_y.s1 = SGB_BC(y.s1, 2); \
    shared_y.s2 = SGB_BC(y.s2, 2); \
    shared_y.s3 = SGB_BC(y.s3, 2); \
    shared_y.s4 = SGB_BC(y.s4, 2); \
    shared_y.s5 = SGB_BC(y.s5, 2); \
    shared_y.s6 = SGB_BC(y.s6, 2); \
    shared_y.s7 = SGB_BC(y.s7, 2); \
    total_sums.s0 += ((bits4.s0 & 0x000F) - 8) * scale.s0 * shared_y.s0; \
    total_sums.s0 += (((bits4.s0 & 0x00F0) >> 4) - 8) * scale.s0 * shared_y.s1; \
    total_sums.s0 += (((bits4.s0 & 0x0F00) >> 8) - 8) * scale.s0 * shared_y.s2; \
    total_sums.s0 += (((bits4.s0 & 0xF000) >> 12) - 8) * scale.s0 * shared_y.s3; \
    total_sums.s0 += ((bits4.s2 & 0x000F) - 8) * scale.s0 * shared_y.s4; \
    total_sums.s0 += (((bits4.s2 & 0x00F0) >> 4) - 8) * scale.s0 * shared_y.s5; \
    total_sums.s0 += (((bits4.s2 & 0x0F00) >> 8) - 8) * scale.s0 * shared_y.s6; \
    total_sums.s0 += (((bits4.s2 & 0xF000) >> 12) - 8) * scale.s0 * shared_y.s7; \
    total_sums.s1 += ((bits4.s1 & 0x000F) - 8) * scale.s1 * shared_y.s0; \
    total_sums.s1 += (((bits4.s1 & 0x00F0) >> 4) - 8) * scale.s1 * shared_y.s1; \
    total_sums.s1 += (((bits4.s1 & 0x0F00) >> 8) - 8) * scale.s1 * shared_y.s2; \
    total_sums.s1 += (((bits4.s1 & 0xF000) >> 12) - 8) * scale.s1 * shared_y.s3; \
    total_sums.s1 += ((bits4.s3 & 0x000F) - 8) * scale.s1 * shared_y.s4; \
    total_sums.s1 += (((bits4.s3 & 0x00F0) >> 4) - 8) * scale.s1 * shared_y.s5; \
    total_sums.s1 += (((bits4.s3 & 0x0F00) >> 8) - 8) * scale.s1 * shared_y.s6; \
    total_sums.s1 += (((bits4.s3 & 0xF000) >> 12) - 8) * scale.s1 * shared_y.s7; \
    shared_y.s0 = SGB_BC(y.s0, 3); \
    shared_y.s1 = SGB_BC(y.s1, 3); \
    shared_y.s2 = SGB_BC(y.s2, 3); \
    shared_y.s3 = SGB_BC(y.s3, 3); \
    shared_y.s4 = SGB_BC(y.s4, 3); \
    shared_y.s5 = SGB_BC(y.s5, 3); \
    shared_y.s6 = SGB_BC(y.s6, 3); \
    shared_y.s7 = SGB_BC(y.s7, 3); \
    total_sums.s0 += ((bits4.s4 & 0x000F) - 8) * scale.s0 * shared_y.s0; \
    total_sums.s0 += (((bits4.s4 & 0x00F0) >> 4) - 8) * scale.s0 * shared_y.s1; \
    total_sums.s0 += (((bits4.s4 & 0x0F00) >> 8) - 8) * scale.s0 * shared_y.s2; \
    total_sums.s0 += (((bits4.s4 & 0xF000) >> 12) - 8) * scale.s0 * shared_y.s3; \
    total_sums.s0 += ((bits4.s6 & 0x000F) - 8) * scale.s0 * shared_y.s4; \
    total_sums.s0 += (((bits4.s6 & 0x00F0) >> 4) - 8) * scale.s0 * shared_y.s5; \
    total_sums.s0 += (((bits4.s6 & 0x0F00) >> 8) - 8) * scale.s0 * shared_y.s6; \
    total_sums.s0 += (((bits4.s6 & 0xF000) >> 12) - 8) * scale.s0 * shared_y.s7; \
    total_sums.s1 += ((bits4.s5 & 0x000F) - 8) * scale.s1 * shared_y.s0; \
    total_sums.s1 += (((bits4.s5 & 0x00F0) >> 4) - 8) * scale.s1 * shared_y.s1; \
    total_sums.s1 += (((bits4.s5 & 0x0F00) >> 8) - 8) * scale.s1 * shared_y.s2; \
    total_sums.s1 += (((bits4.s5 & 0xF000) >> 12) - 8) * scale.s1 * shared_y.s3; \
    total_sums.s1 += ((bits4.s7 & 0x000F) - 8) * scale.s1 * shared_y.s4; \
    total_sums.s1 += (((bits4.s7 & 0x00F0) >> 4) - 8) * scale.s1 * shared_y.s5; \
    total_sums.s1 += (((bits4.s7 & 0x0F00) >> 8) - 8) * scale.s1 * shared_y.s6; \
    total_sums.s1 += (((bits4.s7 & 0xF000) >> 12) - 8) * scale.s1 * shared_y.s7; \

#ifdef ADRENO_GPU
REQD_SUBGROUP_SIZE_64
#endif
__kernel void kernel_gemv_noshuffle_q4_0_f32(
        __read_only  image1d_buffer_t src0_q,  // quantized A
        global half2  * src0_d,  // A scales
        __read_only  image1d_buffer_t src1,    // B
        ulong offset1,            // offset to B (0)
        global float * dst,     // C
        ulong offsetd,            // offset to C (0)
        int ne00,               // K
        int ne01,               // M
        int ne02,               // 1
        int ne10,               // K
        int ne12,               // 1
        int ne0,                // M
        int ne1,                // N
        int r2,                 // 1
        int r3)
{
    uint groupId = get_local_id(1);
    uint gid     = get_global_id(0);
    ushort slid    = get_sub_group_local_id();

    uint K = ne00;
    uint M = ne01;

    uint LINE_STRIDE_A = M / 2;
    uint BLOCK_STRIDE_A = N_SIMDGROUP * M;

    __private uint4     regA;
    __private half2     regS;
    __private float8    regB;

    __private float2 totalSum = (float2)(0.0f);

    // loop along K in block granularity, skip 4 blocks every iter
    for (uint k = groupId; k < (K / QK4_0); k += N_SIMDGROUP) {
        regS = src0_d[gid + k * LINE_STRIDE_A]; // each fiber loads scale of two rows
        // first 4 fibers in each wave load 8 B values to its private scope
        if (slid < 4) {
            regB.s0123 = read_imagef(src1, (slid * 2 + k * 8));
            regB.s4567 = read_imagef(src1, (1 + slid * 2 + k * 8));
        }

        // load half weights for two blocks in consecutive rows
        regA.s0 = read_imageui(src0_q, (gid + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 0)).x;
        regA.s1 = read_imageui(src0_q, (gid + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 1)).x;
        regA.s2 = read_imageui(src0_q, (gid + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 2)).x;
        regA.s3 = read_imageui(src0_q, (gid + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 3)).x;
#ifdef VECTOR_SUB_GROUP_BROADCAST
        dequantizeBlockAccum_ns_sgbroadcast_8_hi(totalSum, as_ushort8(regA), regS, regB);
#else
        dequantizeBlockAccum_ns_sgbroadcast_1_hi(totalSum, as_ushort8(regA), regS, regB);
#endif // VECTOR_SUB_GROUP_BROADCAST

        regA.s0 = read_imageui(src0_q, (gid + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 4)).x;
        regA.s1 = read_imageui(src0_q, (gid + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 5)).x;
        regA.s2 = read_imageui(src0_q, (gid + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 6)).x;
        regA.s3 = read_imageui(src0_q, (gid + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 7)).x;
#ifdef VECTOR_SUB_GROUP_BROADCAST
        dequantizeBlockAccum_ns_sgbroadcast_8_lo(totalSum, as_ushort8(regA), regS, regB);
#else
        dequantizeBlockAccum_ns_sgbroadcast_1_lo(totalSum, as_ushort8(regA), regS, regB);
#endif // VECTOR_SUB_GROUP_BROADCAST
    }

    // reduction in local memory, assumes #wave=4
    __local float2 reduceLM[SIMDGROUP_WIDTH * 3];
    if (groupId == 1) reduceLM[SIMDGROUP_WIDTH * 0 + slid] = totalSum;
    if (groupId == 2) reduceLM[SIMDGROUP_WIDTH * 1 + slid] = totalSum;
    if (groupId == 3) reduceLM[SIMDGROUP_WIDTH * 2 + slid] = totalSum;
    barrier(CLK_LOCAL_MEM_FENCE);
    if (groupId == 0) totalSum += reduceLM[SIMDGROUP_WIDTH * 0 + slid];
    if (groupId == 0) totalSum += reduceLM[SIMDGROUP_WIDTH * 1 + slid];
    if (groupId == 0) totalSum += reduceLM[SIMDGROUP_WIDTH * 2 + slid];

    // 2 outputs per fiber in wave 0
    if (groupId == 0) {
        dst = (global float*)((global char*)dst + offsetd);
        // Guard the two output rows. The x-grid is padded to CEIL_DIV(ne01/2,64)*64,
        // so when ne01 is not a multiple of 128 the tail row-pairs run past row ne01
        // and would overrun dst into the adjacent tensor. No-op / byte-identical when
        // ne01 % 128 == 0 (M/2 already a multiple of 64 -> no padding).
        if (gid * 2 + 0 < M) dst[gid * 2 + 0] = totalSum.s0;
        if (gid * 2 + 1 < M) dst[gid * 2 + 1] = totalSum.s1;
    }

}

// Multi-column (N in [2..4]) variant of the q4_0 decode GEMV, for the speculative
// / MTP verify batch (n_cols = 2..4 = drafted + bonus positions). Routes the small-
// batch verify OFF the transposed-GEMM dead-zone (gemm_noshuffle_q4_0) onto the
// efficient GEMV path. Each K-block's weights (regA hi+lo) are loaded ONCE and
// reused across the n_cols activation columns. Per-column accumulation is
// independent and identical to n_cols standalone GEMVs. n_cols==3 is byte-identical
// to the original mc3 (col3 disabled, slots 6/7 stay zero). Kept the _mc3 name.
#ifdef VECTOR_SUB_GROUP_BROADCAST
#define MC_DQ_HI dequantizeBlockAccum_ns_sgbroadcast_8_hi
#define MC_DQ_LO dequantizeBlockAccum_ns_sgbroadcast_8_lo
#else
#define MC_DQ_HI dequantizeBlockAccum_ns_sgbroadcast_1_hi
#define MC_DQ_LO dequantizeBlockAccum_ns_sgbroadcast_1_lo
#endif
// One column c: load this column's activation (own brace scope so the macros'
// `shared_y` decl is re-scoped), then dequant (hi+lo) against the shared weights.
#define MC_COL_Q40(ts, c) \
    { if (slid < 4) { regB.s0123 = read_imagef(src1, (c)*COL_STRIDE     + slid*2 + k*8); \
                      regB.s4567 = read_imagef(src1, (c)*COL_STRIDE + 1 + slid*2 + k*8); } \
      MC_DQ_HI(ts, as_ushort8(regA_hi), regS, regB); \
      MC_DQ_LO(ts, as_ushort8(regA_lo), regS, regB); }

#ifdef ADRENO_GPU
REQD_SUBGROUP_SIZE_64
#endif
__kernel void kernel_gemv_noshuffle_q4_0_f32_mc3(
        __read_only  image1d_buffer_t src0_q,  // quantized A
        global half2  * src0_d,                // A scales
        __read_only  image1d_buffer_t src1,    // B (n_cols columns, col-major image)
        global float * dst,                    // C (column-major [M x n_cols])
        ulong offsetd,
        int ne00,                              // K
        int ne01,                              // M
        int n_cols)                            // N (2..4)
{
    uint groupId = get_local_id(1);
    uint gid     = get_global_id(0);
    ushort slid  = get_sub_group_local_id();

    uint K = ne00;
    uint M = ne01;

    uint LINE_STRIDE_A  = M / 2;
    // BLOCK_STRIDE_A is the LAYOUT stride between consecutive K-blocks = 4 uints
    // per q4_0 block * M (set by the trans4_ns convert). The "4" is uints/block, NOT
    // the subgroup count — keep it fixed so the K-split count (nsg) can vary.
    uint BLOCK_STRIDE_A = N_SIMDGROUP * M;   // = 4 * M (N_SIMDGROUP is the #define 4)
    uint COL_STRIDE     = K / 4;   // float4 pixels per activation column
    uint nsg            = get_local_size(1);  // runtime K-split (4 default, 8 small-M)

    __private uint4  regA_hi, regA_lo;
    __private half2  regS;
    __private float8 regB;

    __private float2 ts0 = (float2)(0.0f);
    __private float2 ts1 = (float2)(0.0f);
    __private float2 ts2 = (float2)(0.0f);
    __private float2 ts3 = (float2)(0.0f);

    for (uint k = groupId; k < (K / QK4_0); k += nsg) {
        regS = src0_d[gid + k * LINE_STRIDE_A];

        // weights loaded ONCE, reused across the columns
        regA_hi.s0 = read_imageui(src0_q, (gid + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 0)).x;
        regA_hi.s1 = read_imageui(src0_q, (gid + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 1)).x;
        regA_hi.s2 = read_imageui(src0_q, (gid + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 2)).x;
        regA_hi.s3 = read_imageui(src0_q, (gid + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 3)).x;
        regA_lo.s0 = read_imageui(src0_q, (gid + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 4)).x;
        regA_lo.s1 = read_imageui(src0_q, (gid + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 5)).x;
        regA_lo.s2 = read_imageui(src0_q, (gid + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 6)).x;
        regA_lo.s3 = read_imageui(src0_q, (gid + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 7)).x;

        MC_COL_Q40(ts0, 0);
        MC_COL_Q40(ts1, 1);
        if (n_cols > 2) MC_COL_Q40(ts2, 2);
        if (n_cols > 3) MC_COL_Q40(ts3, 3);
    }

    // cross-subgroup reduce over nsg subgroups: pack the (up to 4) columns' float2
    // into a float8. Generalized to runtime nsg (4 default, 8 for small-M). Each
    // subgroup writes its partial; subgroup 0 sums the rest into its own acc. At
    // nsg==4 this is byte-identical to the original (sums subgroups 1,2,3 in order).
    __local float8 reduceLM[SIMDGROUP_WIDTH * 8];
    float8 acc = (float8)(ts0.s0, ts0.s1, ts1.s0, ts1.s1, ts2.s0, ts2.s1, ts3.s0, ts3.s1);
    reduceLM[groupId * SIMDGROUP_WIDTH + slid] = acc;

    barrier(CLK_LOCAL_MEM_FENCE);

    if (groupId == 0) {
        for (uint g = 1; g < nsg; g++) {
            acc += reduceLM[g * SIMDGROUP_WIDTH + slid];
        }
        dst = (global float*)((global char*)dst + offsetd);
        // dst is column-major [M rows x n_cols cols]: (row, col) at col*M + row
        vstore2((float2)(acc.s0, acc.s1), 0, &(dst[0 * M + gid * 2]));
        vstore2((float2)(acc.s2, acc.s3), 0, &(dst[1 * M + gid * 2]));
        if (n_cols > 2) vstore2((float2)(acc.s4, acc.s5), 0, &(dst[2 * M + gid * 2]));
        if (n_cols > 3) vstore2((float2)(acc.s6, acc.s7), 0, &(dst[3 * M + gid * 2]));
    }
}
#undef MC_COL_Q40
#undef MC_DQ_HI
#undef MC_DQ_LO

// [dspark 2026-10-13] Batched MUL_MAT_ID for q4_0 MoE: ONE dispatch computes all
// (expert-slot, token) GEMV columns, and the expert ids are read on-device —
// eliminating the dense-loop's per-expert dispatches AND the per-layer ids
// readback sync. Weight/b/scale addressing is the validated
// kernel_gemv_noshuffle_q4_0_f32 with three base shifts:
//   row-pair index  gid -> rp   (gid now encodes column too)
//   weight base     + e * q_layer_pix   (experts laid out contiguously by
//                    set_tensor, each layer byte-identical to a dense 2D
//                    [K, M] noshuffle+transposed weight — the same layout the
//                    dense-loop GEMV reads, validated NMSE=0)
//   B column base   + col * (K/4) float4 pixels
// Requires (host-checked): M % 128 == 0 (no row-pair padding, so every index
// stays inside its expert layer), K % 32 == 0, ids in [0, E).
#ifdef VECTOR_SUB_GROUP_BROADCAST
#define BMO_DQ_HI dequantizeBlockAccum_ns_sgbroadcast_8_hi
#define BMO_DQ_LO dequantizeBlockAccum_ns_sgbroadcast_8_lo
#else
#define BMO_DQ_HI dequantizeBlockAccum_ns_sgbroadcast_1_hi
#define BMO_DQ_LO dequantizeBlockAccum_ns_sgbroadcast_1_lo
#endif
#ifdef ADRENO_GPU
REQD_SUBGROUP_SIZE_64
#endif
__kernel void kernel_mul_mat_id_q4_0_f32_batched(
        __read_only  image1d_buffer_t src0_q,  // E transposed q4_0 expert layers
        global half2  * src0_d,                // E layers of fp16 block scales
        __read_only  image1d_buffer_t src1,    // B: ne11*n_tok columns of K floats
        global int    * ids,                   // MUL_MAT_ID ids tensor (I32)
        int ids_elem_off,                      // element offset of ids base
        global float * dst,                    // destination buffer
        ulong offsetd,                         // byte offset of dst base
        int ne00,                              // K
        int ne01,                              // M (output rows)
        int n_used,                            // expert slots per token
        int n_tok,                             // tokens
        int ne11,                              // src1 columns (1 => broadcast)
        int n_expert,                          // E
        int ids_row,                           // ids row stride in elements
        ulong dst_nb1,                         // dst->nb[1] bytes
        ulong dst_nb2,                         // dst->nb[2] bytes
        int grid_x_per_col,                    // CEIL_DIV(M/2, 64) * 64
        ulong q_layer_pix,                     // per-expert q stride (uint pixels)
        ulong d_layer_bytes)                   // per-expert scale stride (bytes)
{
    uint gid  = get_global_id(0);
    uint slid = get_sub_group_local_id();
    uint groupId = get_local_id(1);

    uint K  = (uint)ne00;
    uint M  = (uint)ne01;
    uint M2 = M / 2;

    uint colp = gid / (uint)grid_x_per_col;
    uint rp   = gid - colp * (uint)grid_x_per_col;   // row-pair index, rp < M2 (no padding)

    uint col = colp;   // identity (P3 sort is q3_K-only; perm param removed)

    uint t = col / (uint)n_used;
    uint j = col - t * (uint)n_used;

    int e = ids[ids_elem_off + (int)t * ids_row + (int)j];
    bool valid = (e >= 0) && (e < n_expert);
    int  es    = valid ? e : 0;   // safe reads; invalid ids write zeros

    uint LINE_STRIDE_A  = M / 2;
    uint BLOCK_STRIDE_A = N_SIMDGROUP * M;

    global half2 * drow = (global half2*)((global char*)src0_d + (ulong)es * d_layer_bytes);
    int qbase = (int)((ulong)es * q_layer_pix);
    int bbase = (int)((ulong)((j % (uint)ne11) + t * (uint)ne11) * (K / 4));
    global float * dstc = (global float*)((global char*)dst + offsetd
                            + (ulong)j * dst_nb1 + (ulong)t * dst_nb2);

    __private uint4  regA;
    __private half2  regS;
    __private float8 regB;

    __private float2 totalSum = (float2)(0.0f);

    for (uint k = groupId; k < (K / QK4_0); k += N_SIMDGROUP) {
        regS = drow[rp + k * LINE_STRIDE_A]; // scale of two rows
        if (slid < 4) {
            regB.s0123 = read_imagef(src1, bbase + (int)(slid * 2 + k * 8));
            regB.s4567 = read_imagef(src1, bbase + (int)(1 + slid * 2 + k * 8));
        }

        regA.s0 = read_imageui(src0_q, (int)(rp + qbase + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 0)).x;
        regA.s1 = read_imageui(src0_q, (int)(rp + qbase + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 1)).x;
        regA.s2 = read_imageui(src0_q, (int)(rp + qbase + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 2)).x;
        regA.s3 = read_imageui(src0_q, (int)(rp + qbase + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 3)).x;
        BMO_DQ_HI(totalSum, as_ushort8(regA), regS, regB);

        regA.s0 = read_imageui(src0_q, (int)(rp + qbase + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 4)).x;
        regA.s1 = read_imageui(src0_q, (int)(rp + qbase + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 5)).x;
        regA.s2 = read_imageui(src0_q, (int)(rp + qbase + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 6)).x;
        regA.s3 = read_imageui(src0_q, (int)(rp + qbase + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 7)).x;
        BMO_DQ_LO(totalSum, as_ushort8(regA), regS, regB);
    }

    // reduction in local memory, assumes #wave=4
    __local float2 reduceLM[SIMDGROUP_WIDTH * 3];
    if (groupId == 1) reduceLM[SIMDGROUP_WIDTH * 0 + slid] = totalSum;
    if (groupId == 2) reduceLM[SIMDGROUP_WIDTH * 1 + slid] = totalSum;
    if (groupId == 3) reduceLM[SIMDGROUP_WIDTH * 2 + slid] = totalSum;
    barrier(CLK_LOCAL_MEM_FENCE);
    if (groupId == 0) {
        totalSum += reduceLM[SIMDGROUP_WIDTH * 0 + slid];
        totalSum += reduceLM[SIMDGROUP_WIDTH * 1 + slid];
        totalSum += reduceLM[SIMDGROUP_WIDTH * 2 + slid];
        if (valid) {
            if (rp * 2 + 0 < M) dstc[rp * 2 + 0] = totalSum.s0;
            if (rp * 2 + 1 < M) dstc[rp * 2 + 1] = totalSum.s1;
        } else {
            if (rp * 2 + 0 < M) dstc[rp * 2 + 0] = 0.0f;
            if (rp * 2 + 1 < M) dstc[rp * 2 + 1] = 0.0f;
        }
    }
}
#undef BMO_DQ_HI
#undef BMO_DQ_LO
