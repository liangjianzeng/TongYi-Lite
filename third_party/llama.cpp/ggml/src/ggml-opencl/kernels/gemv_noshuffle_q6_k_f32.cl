#pragma OPENCL EXTENSION cl_khr_fp16 : enable
#pragma OPENCL EXTENSION cl_khr_subgroups : enable

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

#ifdef cl_intel_required_subgroup_size
#pragma OPENCL EXTENSION cl_intel_required_subgroup_size : enable
#define INTEL_GPU 1
#define REQD_SUBGROUP_SIZE_16 __attribute__((intel_reqd_sub_group_size(16)))
#define REQD_SUBGROUP_SIZE_32 __attribute__((intel_reqd_sub_group_size(32)))
#elif defined(cl_qcom_reqd_sub_group_size)
#pragma OPENCL EXTENSION cl_qcom_reqd_sub_group_size : enable
#define ADRENO_GPU 1
#define REQD_SUBGROUP_SIZE_64  __attribute__((qcom_reqd_sub_group_size("half")))
#define REQD_SUBGROUP_SIZE_128 __attribute__((qcom_reqd_sub_group_size("full")))
#endif

// the driver's online compiler lacks float overloads of sub_group_broadcast
// (Adreno 740: only scalar uint/int/long/ulong exist). Bitcast float<->uint,
// broadcast as integer, cast back — bitwise identical, subgroup-uniform.
#define NSUBGROUPS 4
#define SUBGROUP_SIZE 64

#define dequantize_block_acc_bcast_8_hi(total_sum, bits4, bits2, scale_d, scale_s, y) \
    float8 shared_y; \
    shared_y.s0 = SGB_BC(y.s0, 0); \
    shared_y.s1 = SGB_BC(y.s1, 0); \
    shared_y.s2 = SGB_BC(y.s2, 0); \
    shared_y.s3 = SGB_BC(y.s3, 0); \
    shared_y.s4 = SGB_BC(y.s4, 0); \
    shared_y.s5 = SGB_BC(y.s5, 0); \
    shared_y.s6 = SGB_BC(y.s6, 0); \
    shared_y.s7 = SGB_BC(y.s7, 0); \
    total_sum.s0 += ((float)(((bits4.s0 & 0x000F)      ) | ((bits2.s0 & 0x03) << 4)) - 32.f) * scale_s.s0 * scale_d.s0 * shared_y.s0; \
    total_sum.s0 += ((float)(((bits4.s0 & 0x00F0) >>  4) | ((bits2.s0 & 0x0C) << 2)) - 32.f) * scale_s.s0 * scale_d.s0 * shared_y.s1; \
    total_sum.s0 += ((float)(((bits4.s0 & 0x0F00) >>  8) | ((bits2.s0 & 0x30)     )) - 32.f) * scale_s.s0 * scale_d.s0 * shared_y.s2; \
    total_sum.s0 += ((float)(((bits4.s0 & 0xF000) >> 12) | ((bits2.s0 & 0xC0) >> 2)) - 32.f) * scale_s.s0 * scale_d.s0 * shared_y.s3; \
    total_sum.s0 += ((float)(((bits4.s2 & 0x000F)      ) | ((bits2.s2 & 0x03) << 4)) - 32.f) * scale_s.s0 * scale_d.s0 * shared_y.s4; \
    total_sum.s0 += ((float)(((bits4.s2 & 0x00F0) >>  4) | ((bits2.s2 & 0x0C) << 2)) - 32.f) * scale_s.s0 * scale_d.s0 * shared_y.s5; \
    total_sum.s0 += ((float)(((bits4.s2 & 0x0F00) >>  8) | ((bits2.s2 & 0x30)     )) - 32.f) * scale_s.s0 * scale_d.s0 * shared_y.s6; \
    total_sum.s0 += ((float)(((bits4.s2 & 0xF000) >> 12) | ((bits2.s2 & 0xC0) >> 2)) - 32.f) * scale_s.s0 * scale_d.s0 * shared_y.s7; \
    total_sum.s1 += ((float)(((bits4.s1 & 0x000F)      ) | ((bits2.s1 & 0x03) << 4)) - 32.f) * scale_s.s2 * scale_d.s1 * shared_y.s0; \
    total_sum.s1 += ((float)(((bits4.s1 & 0x00F0) >>  4) | ((bits2.s1 & 0x0C) << 2)) - 32.f) * scale_s.s2 * scale_d.s1 * shared_y.s1; \
    total_sum.s1 += ((float)(((bits4.s1 & 0x0F00) >>  8) | ((bits2.s1 & 0x30)     )) - 32.f) * scale_s.s2 * scale_d.s1 * shared_y.s2; \
    total_sum.s1 += ((float)(((bits4.s1 & 0xF000) >> 12) | ((bits2.s1 & 0xC0) >> 2)) - 32.f) * scale_s.s2 * scale_d.s1 * shared_y.s3; \
    total_sum.s1 += ((float)(((bits4.s3 & 0x000F)      ) | ((bits2.s3 & 0x03) << 4)) - 32.f) * scale_s.s2 * scale_d.s1 * shared_y.s4; \
    total_sum.s1 += ((float)(((bits4.s3 & 0x00F0) >>  4) | ((bits2.s3 & 0x0C) << 2)) - 32.f) * scale_s.s2 * scale_d.s1 * shared_y.s5; \
    total_sum.s1 += ((float)(((bits4.s3 & 0x0F00) >>  8) | ((bits2.s3 & 0x30)     )) - 32.f) * scale_s.s2 * scale_d.s1 * shared_y.s6; \
    total_sum.s1 += ((float)(((bits4.s3 & 0xF000) >> 12) | ((bits2.s3 & 0xC0) >> 2)) - 32.f) * scale_s.s2 * scale_d.s1 * shared_y.s7; \
    shared_y.s0 = SGB_BC(y.s0, 1); \
    shared_y.s1 = SGB_BC(y.s1, 1); \
    shared_y.s2 = SGB_BC(y.s2, 1); \
    shared_y.s3 = SGB_BC(y.s3, 1); \
    shared_y.s4 = SGB_BC(y.s4, 1); \
    shared_y.s5 = SGB_BC(y.s5, 1); \
    shared_y.s6 = SGB_BC(y.s6, 1); \
    shared_y.s7 = SGB_BC(y.s7, 1); \
    total_sum.s0 += ((float)(((bits4.s4 & 0x000F)      ) | ((bits2.s4 & 0x03) << 4)) - 32.f) * scale_s.s0 * scale_d.s0 * shared_y.s0; \
    total_sum.s0 += ((float)(((bits4.s4 & 0x00F0) >>  4) | ((bits2.s4 & 0x0C) << 2)) - 32.f) * scale_s.s0 * scale_d.s0 * shared_y.s1; \
    total_sum.s0 += ((float)(((bits4.s4 & 0x0F00) >>  8) | ((bits2.s4 & 0x30)     )) - 32.f) * scale_s.s0 * scale_d.s0 * shared_y.s2; \
    total_sum.s0 += ((float)(((bits4.s4 & 0xF000) >> 12) | ((bits2.s4 & 0xC0) >> 2)) - 32.f) * scale_s.s0 * scale_d.s0 * shared_y.s3; \
    total_sum.s0 += ((float)(((bits4.s6 & 0x000F)      ) | ((bits2.s6 & 0x03) << 4)) - 32.f) * scale_s.s0 * scale_d.s0 * shared_y.s4; \
    total_sum.s0 += ((float)(((bits4.s6 & 0x00F0) >>  4) | ((bits2.s6 & 0x0C) << 2)) - 32.f) * scale_s.s0 * scale_d.s0 * shared_y.s5; \
    total_sum.s0 += ((float)(((bits4.s6 & 0x0F00) >>  8) | ((bits2.s6 & 0x30)     )) - 32.f) * scale_s.s0 * scale_d.s0 * shared_y.s6; \
    total_sum.s0 += ((float)(((bits4.s6 & 0xF000) >> 12) | ((bits2.s6 & 0xC0) >> 2)) - 32.f) * scale_s.s0 * scale_d.s0 * shared_y.s7; \
    total_sum.s1 += ((float)(((bits4.s5 & 0x000F)      ) | ((bits2.s5 & 0x03) << 4)) - 32.f) * scale_s.s2 * scale_d.s1 * shared_y.s0; \
    total_sum.s1 += ((float)(((bits4.s5 & 0x00F0) >>  4) | ((bits2.s5 & 0x0C) << 2)) - 32.f) * scale_s.s2 * scale_d.s1 * shared_y.s1; \
    total_sum.s1 += ((float)(((bits4.s5 & 0x0F00) >>  8) | ((bits2.s5 & 0x30)     )) - 32.f) * scale_s.s2 * scale_d.s1 * shared_y.s2; \
    total_sum.s1 += ((float)(((bits4.s5 & 0xF000) >> 12) | ((bits2.s5 & 0xC0) >> 2)) - 32.f) * scale_s.s2 * scale_d.s1 * shared_y.s3; \
    total_sum.s1 += ((float)(((bits4.s7 & 0x000F)      ) | ((bits2.s7 & 0x03) << 4)) - 32.f) * scale_s.s2 * scale_d.s1 * shared_y.s4; \
    total_sum.s1 += ((float)(((bits4.s7 & 0x00F0) >>  4) | ((bits2.s7 & 0x0C) << 2)) - 32.f) * scale_s.s2 * scale_d.s1 * shared_y.s5; \
    total_sum.s1 += ((float)(((bits4.s7 & 0x0F00) >>  8) | ((bits2.s7 & 0x30)     )) - 32.f) * scale_s.s2 * scale_d.s1 * shared_y.s6; \
    total_sum.s1 += ((float)(((bits4.s7 & 0xF000) >> 12) | ((bits2.s7 & 0xC0) >> 2)) - 32.f) * scale_s.s2 * scale_d.s1 * shared_y.s7; \

#define dequantize_block_acc_bcast_8_lo(total_sum, bits4, bits2, scale_d, scale_s, y) \
    shared_y.s0 = SGB_BC(y.s0, 2); \
    shared_y.s1 = SGB_BC(y.s1, 2); \
    shared_y.s2 = SGB_BC(y.s2, 2); \
    shared_y.s3 = SGB_BC(y.s3, 2); \
    shared_y.s4 = SGB_BC(y.s4, 2); \
    shared_y.s5 = SGB_BC(y.s5, 2); \
    shared_y.s6 = SGB_BC(y.s6, 2); \
    shared_y.s7 = SGB_BC(y.s7, 2); \
    total_sum.s0 += ((float)(((bits4.s0 & 0x000F)      ) | ((bits2.s0 & 0x03) << 4)) - 32.f) * scale_s.s1 * scale_d.s0 * shared_y.s0; \
    total_sum.s0 += ((float)(((bits4.s0 & 0x00F0) >>  4) | ((bits2.s0 & 0x0C) << 2)) - 32.f) * scale_s.s1 * scale_d.s0 * shared_y.s1; \
    total_sum.s0 += ((float)(((bits4.s0 & 0x0F00) >>  8) | ((bits2.s0 & 0x30)     )) - 32.f) * scale_s.s1 * scale_d.s0 * shared_y.s2; \
    total_sum.s0 += ((float)(((bits4.s0 & 0xF000) >> 12) | ((bits2.s0 & 0xC0) >> 2)) - 32.f) * scale_s.s1 * scale_d.s0 * shared_y.s3; \
    total_sum.s0 += ((float)(((bits4.s2 & 0x000F)      ) | ((bits2.s2 & 0x03) << 4)) - 32.f) * scale_s.s1 * scale_d.s0 * shared_y.s4; \
    total_sum.s0 += ((float)(((bits4.s2 & 0x00F0) >>  4) | ((bits2.s2 & 0x0C) << 2)) - 32.f) * scale_s.s1 * scale_d.s0 * shared_y.s5; \
    total_sum.s0 += ((float)(((bits4.s2 & 0x0F00) >>  8) | ((bits2.s2 & 0x30)     )) - 32.f) * scale_s.s1 * scale_d.s0 * shared_y.s6; \
    total_sum.s0 += ((float)(((bits4.s2 & 0xF000) >> 12) | ((bits2.s2 & 0xC0) >> 2)) - 32.f) * scale_s.s1 * scale_d.s0 * shared_y.s7; \
    total_sum.s1 += ((float)(((bits4.s1 & 0x000F)      ) | ((bits2.s1 & 0x03) << 4)) - 32.f) * scale_s.s3 * scale_d.s1 * shared_y.s0; \
    total_sum.s1 += ((float)(((bits4.s1 & 0x00F0) >>  4) | ((bits2.s1 & 0x0C) << 2)) - 32.f) * scale_s.s3 * scale_d.s1 * shared_y.s1; \
    total_sum.s1 += ((float)(((bits4.s1 & 0x0F00) >>  8) | ((bits2.s1 & 0x30)     )) - 32.f) * scale_s.s3 * scale_d.s1 * shared_y.s2; \
    total_sum.s1 += ((float)(((bits4.s1 & 0xF000) >> 12) | ((bits2.s1 & 0xC0) >> 2)) - 32.f) * scale_s.s3 * scale_d.s1 * shared_y.s3; \
    total_sum.s1 += ((float)(((bits4.s3 & 0x000F)      ) | ((bits2.s3 & 0x03) << 4)) - 32.f) * scale_s.s3 * scale_d.s1 * shared_y.s4; \
    total_sum.s1 += ((float)(((bits4.s3 & 0x00F0) >>  4) | ((bits2.s3 & 0x0C) << 2)) - 32.f) * scale_s.s3 * scale_d.s1 * shared_y.s5; \
    total_sum.s1 += ((float)(((bits4.s3 & 0x0F00) >>  8) | ((bits2.s3 & 0x30)     )) - 32.f) * scale_s.s3 * scale_d.s1 * shared_y.s6; \
    total_sum.s1 += ((float)(((bits4.s3 & 0xF000) >> 12) | ((bits2.s3 & 0xC0) >> 2)) - 32.f) * scale_s.s3 * scale_d.s1 * shared_y.s7; \
    shared_y.s0 = SGB_BC(y.s0, 3); \
    shared_y.s1 = SGB_BC(y.s1, 3); \
    shared_y.s2 = SGB_BC(y.s2, 3); \
    shared_y.s3 = SGB_BC(y.s3, 3); \
    shared_y.s4 = SGB_BC(y.s4, 3); \
    shared_y.s5 = SGB_BC(y.s5, 3); \
    shared_y.s6 = SGB_BC(y.s6, 3); \
    shared_y.s7 = SGB_BC(y.s7, 3); \
    total_sum.s0 += ((float)(((bits4.s4 & 0x000F)      ) | ((bits2.s4 & 0x03) << 4)) - 32.f) * scale_s.s1 * scale_d.s0 * shared_y.s0; \
    total_sum.s0 += ((float)(((bits4.s4 & 0x00F0) >>  4) | ((bits2.s4 & 0x0C) << 2)) - 32.f) * scale_s.s1 * scale_d.s0 * shared_y.s1; \
    total_sum.s0 += ((float)(((bits4.s4 & 0x0F00) >>  8) | ((bits2.s4 & 0x30)     )) - 32.f) * scale_s.s1 * scale_d.s0 * shared_y.s2; \
    total_sum.s0 += ((float)(((bits4.s4 & 0xF000) >> 12) | ((bits2.s4 & 0xC0) >> 2)) - 32.f) * scale_s.s1 * scale_d.s0 * shared_y.s3; \
    total_sum.s0 += ((float)(((bits4.s6 & 0x000F)      ) | ((bits2.s6 & 0x03) << 4)) - 32.f) * scale_s.s1 * scale_d.s0 * shared_y.s4; \
    total_sum.s0 += ((float)(((bits4.s6 & 0x00F0) >>  4) | ((bits2.s6 & 0x0C) << 2)) - 32.f) * scale_s.s1 * scale_d.s0 * shared_y.s5; \
    total_sum.s0 += ((float)(((bits4.s6 & 0x0F00) >>  8) | ((bits2.s6 & 0x30)     )) - 32.f) * scale_s.s1 * scale_d.s0 * shared_y.s6; \
    total_sum.s0 += ((float)(((bits4.s6 & 0xF000) >> 12) | ((bits2.s6 & 0xC0) >> 2)) - 32.f) * scale_s.s1 * scale_d.s0 * shared_y.s7; \
    total_sum.s1 += ((float)(((bits4.s5 & 0x000F)      ) | ((bits2.s5 & 0x03) << 4)) - 32.f) * scale_s.s3 * scale_d.s1 * shared_y.s0; \
    total_sum.s1 += ((float)(((bits4.s5 & 0x00F0) >>  4) | ((bits2.s5 & 0x0C) << 2)) - 32.f) * scale_s.s3 * scale_d.s1 * shared_y.s1; \
    total_sum.s1 += ((float)(((bits4.s5 & 0x0F00) >>  8) | ((bits2.s5 & 0x30)     )) - 32.f) * scale_s.s3 * scale_d.s1 * shared_y.s2; \
    total_sum.s1 += ((float)(((bits4.s5 & 0xF000) >> 12) | ((bits2.s5 & 0xC0) >> 2)) - 32.f) * scale_s.s3 * scale_d.s1 * shared_y.s3; \
    total_sum.s1 += ((float)(((bits4.s7 & 0x000F)      ) | ((bits2.s7 & 0x03) << 4)) - 32.f) * scale_s.s3 * scale_d.s1 * shared_y.s4; \
    total_sum.s1 += ((float)(((bits4.s7 & 0x00F0) >>  4) | ((bits2.s7 & 0x0C) << 2)) - 32.f) * scale_s.s3 * scale_d.s1 * shared_y.s5; \
    total_sum.s1 += ((float)(((bits4.s7 & 0x0F00) >>  8) | ((bits2.s7 & 0x30)     )) - 32.f) * scale_s.s3 * scale_d.s1 * shared_y.s6; \
    total_sum.s1 += ((float)(((bits4.s7 & 0xF000) >> 12) | ((bits2.s7 & 0xC0) >> 2)) - 32.f) * scale_s.s3 * scale_d.s1 * shared_y.s7; \

#define dequantize_block_acc_bcast_1_hi(total_sum, bits4, bits2, scale_d, scale_s, y) \
    float shared_y; \
    shared_y = SGB_BC(y.s0, 0); \
    total_sum.s0 += ((float)(((bits4.s0 & 0x000F)      ) | ((bits2.s0 & 0x03) << 4)) - 32.f) * scale_s.s0 * scale_d.s0 * shared_y; \
    total_sum.s1 += ((float)(((bits4.s1 & 0x000F)      ) | ((bits2.s1 & 0x03) << 4)) - 32.f) * scale_s.s2 * scale_d.s1 * shared_y; \
    shared_y = SGB_BC(y.s1, 0); \
    total_sum.s0 += ((float)(((bits4.s0 & 0x00F0) >>  4) | ((bits2.s0 & 0x0C) << 2)) - 32.f) * scale_s.s0 * scale_d.s0 * shared_y; \
    total_sum.s1 += ((float)(((bits4.s1 & 0x00F0) >>  4) | ((bits2.s1 & 0x0C) << 2)) - 32.f) * scale_s.s2 * scale_d.s1 * shared_y; \
    shared_y = SGB_BC(y.s2, 0); \
    total_sum.s0 += ((float)(((bits4.s0 & 0x0F00) >>  8) | ((bits2.s0 & 0x30)     )) - 32.f) * scale_s.s0 * scale_d.s0 * shared_y; \
    total_sum.s1 += ((float)(((bits4.s1 & 0x0F00) >>  8) | ((bits2.s1 & 0x30)     )) - 32.f) * scale_s.s2 * scale_d.s1 * shared_y; \
    shared_y = SGB_BC(y.s3, 0); \
    total_sum.s0 += ((float)(((bits4.s0 & 0xF000) >> 12) | ((bits2.s0 & 0xC0) >> 2)) - 32.f) * scale_s.s0 * scale_d.s0 * shared_y; \
    total_sum.s1 += ((float)(((bits4.s1 & 0xF000) >> 12) | ((bits2.s1 & 0xC0) >> 2)) - 32.f) * scale_s.s2 * scale_d.s1 * shared_y; \
    shared_y = SGB_BC(y.s4, 0); \
    total_sum.s0 += ((float)(((bits4.s2 & 0x000F)      ) | ((bits2.s2 & 0x03) << 4)) - 32.f) * scale_s.s0 * scale_d.s0 * shared_y; \
    total_sum.s1 += ((float)(((bits4.s3 & 0x000F)      ) | ((bits2.s3 & 0x03) << 4)) - 32.f) * scale_s.s2 * scale_d.s1 * shared_y; \
    shared_y = SGB_BC(y.s5, 0); \
    total_sum.s0 += ((float)(((bits4.s2 & 0x00F0) >>  4) | ((bits2.s2 & 0x0C) << 2)) - 32.f) * scale_s.s0 * scale_d.s0 * shared_y; \
    total_sum.s1 += ((float)(((bits4.s3 & 0x00F0) >>  4) | ((bits2.s3 & 0x0C) << 2)) - 32.f) * scale_s.s2 * scale_d.s1 * shared_y; \
    shared_y = SGB_BC(y.s6, 0); \
    total_sum.s0 += ((float)(((bits4.s2 & 0x0F00) >>  8) | ((bits2.s2 & 0x30)     )) - 32.f) * scale_s.s0 * scale_d.s0 * shared_y; \
    total_sum.s1 += ((float)(((bits4.s3 & 0x0F00) >>  8) | ((bits2.s3 & 0x30)     )) - 32.f) * scale_s.s2 * scale_d.s1 * shared_y; \
    shared_y = SGB_BC(y.s7, 0); \
    total_sum.s0 += ((float)(((bits4.s2 & 0xF000) >> 12) | ((bits2.s2 & 0xC0) >> 2)) - 32.f) * scale_s.s0 * scale_d.s0 * shared_y; \
    total_sum.s1 += ((float)(((bits4.s3 & 0xF000) >> 12) | ((bits2.s3 & 0xC0) >> 2)) - 32.f) * scale_s.s2 * scale_d.s1 * shared_y; \
    shared_y = SGB_BC(y.s0, 1); \
    total_sum.s0 += ((float)(((bits4.s4 & 0x000F)      ) | ((bits2.s4 & 0x03) << 4)) - 32.f) * scale_s.s0 * scale_d.s0 * shared_y; \
    total_sum.s1 += ((float)(((bits4.s5 & 0x000F)      ) | ((bits2.s5 & 0x03) << 4)) - 32.f) * scale_s.s2 * scale_d.s1 * shared_y; \
    shared_y = SGB_BC(y.s1, 1); \
    total_sum.s0 += ((float)(((bits4.s4 & 0x00F0) >>  4) | ((bits2.s4 & 0x0C) << 2)) - 32.f) * scale_s.s0 * scale_d.s0 * shared_y; \
    total_sum.s1 += ((float)(((bits4.s5 & 0x00F0) >>  4) | ((bits2.s5 & 0x0C) << 2)) - 32.f) * scale_s.s2 * scale_d.s1 * shared_y; \
    shared_y = SGB_BC(y.s2, 1); \
    total_sum.s0 += ((float)(((bits4.s4 & 0x0F00) >>  8) | ((bits2.s4 & 0x30)     )) - 32.f) * scale_s.s0 * scale_d.s0 * shared_y; \
    total_sum.s1 += ((float)(((bits4.s5 & 0x0F00) >>  8) | ((bits2.s5 & 0x30)     )) - 32.f) * scale_s.s2 * scale_d.s1 * shared_y; \
    shared_y = SGB_BC(y.s3, 1); \
    total_sum.s0 += ((float)(((bits4.s4 & 0xF000) >> 12) | ((bits2.s4 & 0xC0) >> 2)) - 32.f) * scale_s.s0 * scale_d.s0 * shared_y; \
    total_sum.s1 += ((float)(((bits4.s5 & 0xF000) >> 12) | ((bits2.s5 & 0xC0) >> 2)) - 32.f) * scale_s.s2 * scale_d.s1 * shared_y; \
    shared_y = SGB_BC(y.s4, 1); \
    total_sum.s0 += ((float)(((bits4.s6 & 0x000F)      ) | ((bits2.s6 & 0x03) << 4)) - 32.f) * scale_s.s0 * scale_d.s0 * shared_y; \
    total_sum.s1 += ((float)(((bits4.s7 & 0x000F)      ) | ((bits2.s7 & 0x03) << 4)) - 32.f) * scale_s.s2 * scale_d.s1 * shared_y; \
    shared_y = SGB_BC(y.s5, 1); \
    total_sum.s0 += ((float)(((bits4.s6 & 0x00F0) >>  4) | ((bits2.s6 & 0x0C) << 2)) - 32.f) * scale_s.s0 * scale_d.s0 * shared_y; \
    total_sum.s1 += ((float)(((bits4.s7 & 0x00F0) >>  4) | ((bits2.s7 & 0x0C) << 2)) - 32.f) * scale_s.s2 * scale_d.s1 * shared_y; \
    shared_y = SGB_BC(y.s6, 1); \
    total_sum.s0 += ((float)(((bits4.s6 & 0x0F00) >>  8) | ((bits2.s6 & 0x30)     )) - 32.f) * scale_s.s0 * scale_d.s0 * shared_y; \
    total_sum.s1 += ((float)(((bits4.s7 & 0x0F00) >>  8) | ((bits2.s7 & 0x30)     )) - 32.f) * scale_s.s2 * scale_d.s1 * shared_y; \
    shared_y = SGB_BC(y.s7, 1); \
    total_sum.s0 += ((float)(((bits4.s6 & 0xF000) >> 12) | ((bits2.s6 & 0xC0) >> 2)) - 32.f) * scale_s.s0 * scale_d.s0 * shared_y; \
    total_sum.s1 += ((float)(((bits4.s7 & 0xF000) >> 12) | ((bits2.s7 & 0xC0) >> 2)) - 32.f) * scale_s.s2 * scale_d.s1 * shared_y; \

#define dequantize_block_acc_bcast_1_lo(total_sum, bits4, bits2, scale_d, scale_s, y) \
    shared_y = SGB_BC(y.s0, 2); \
    total_sum.s0 += ((float)(((bits4.s0 & 0x000F)      ) | ((bits2.s0 & 0x03) << 4)) - 32.f) * scale_s.s1 * scale_d.s0 * shared_y; \
    total_sum.s1 += ((float)(((bits4.s1 & 0x000F)      ) | ((bits2.s1 & 0x03) << 4)) - 32.f) * scale_s.s3 * scale_d.s1 * shared_y; \
    shared_y = SGB_BC(y.s1, 2); \
    total_sum.s0 += ((float)(((bits4.s0 & 0x00F0) >>  4) | ((bits2.s0 & 0x0C) << 2)) - 32.f) * scale_s.s1 * scale_d.s0 * shared_y; \
    total_sum.s1 += ((float)(((bits4.s1 & 0x00F0) >>  4) | ((bits2.s1 & 0x0C) << 2)) - 32.f) * scale_s.s3 * scale_d.s1 * shared_y; \
    shared_y = SGB_BC(y.s2, 2); \
    total_sum.s0 += ((float)(((bits4.s0 & 0x0F00) >>  8) | ((bits2.s0 & 0x30)     )) - 32.f) * scale_s.s1 * scale_d.s0 * shared_y; \
    total_sum.s1 += ((float)(((bits4.s1 & 0x0F00) >>  8) | ((bits2.s1 & 0x30)     )) - 32.f) * scale_s.s3 * scale_d.s1 * shared_y; \
    shared_y = SGB_BC(y.s3, 2); \
    total_sum.s0 += ((float)(((bits4.s0 & 0xF000) >> 12) | ((bits2.s0 & 0xC0) >> 2)) - 32.f) * scale_s.s1 * scale_d.s0 * shared_y; \
    total_sum.s1 += ((float)(((bits4.s1 & 0xF000) >> 12) | ((bits2.s1 & 0xC0) >> 2)) - 32.f) * scale_s.s3 * scale_d.s1 * shared_y; \
    shared_y = SGB_BC(y.s4, 2); \
    total_sum.s0 += ((float)(((bits4.s2 & 0x000F)      ) | ((bits2.s2 & 0x03) << 4)) - 32.f) * scale_s.s1 * scale_d.s0 * shared_y; \
    total_sum.s1 += ((float)(((bits4.s3 & 0x000F)      ) | ((bits2.s3 & 0x03) << 4)) - 32.f) * scale_s.s3 * scale_d.s1 * shared_y; \
    shared_y = SGB_BC(y.s5, 2); \
    total_sum.s0 += ((float)(((bits4.s2 & 0x00F0) >>  4) | ((bits2.s2 & 0x0C) << 2)) - 32.f) * scale_s.s1 * scale_d.s0 * shared_y; \
    total_sum.s1 += ((float)(((bits4.s3 & 0x00F0) >>  4) | ((bits2.s3 & 0x0C) << 2)) - 32.f) * scale_s.s3 * scale_d.s1 * shared_y; \
    shared_y = SGB_BC(y.s6, 2); \
    total_sum.s0 += ((float)(((bits4.s2 & 0x0F00) >>  8) | ((bits2.s2 & 0x30)     )) - 32.f) * scale_s.s1 * scale_d.s0 * shared_y; \
    total_sum.s1 += ((float)(((bits4.s3 & 0x0F00) >>  8) | ((bits2.s3 & 0x30)     )) - 32.f) * scale_s.s3 * scale_d.s1 * shared_y; \
    shared_y = SGB_BC(y.s7, 2); \
    total_sum.s0 += ((float)(((bits4.s2 & 0xF000) >> 12) | ((bits2.s2 & 0xC0) >> 2)) - 32.f) * scale_s.s1 * scale_d.s0 * shared_y; \
    total_sum.s1 += ((float)(((bits4.s3 & 0xF000) >> 12) | ((bits2.s3 & 0xC0) >> 2)) - 32.f) * scale_s.s3 * scale_d.s1 * shared_y; \
    shared_y = SGB_BC(y.s0, 3); \
    total_sum.s0 += ((float)(((bits4.s4 & 0x000F)      ) | ((bits2.s4 & 0x03) << 4)) - 32.f) * scale_s.s1 * scale_d.s0 * shared_y; \
    total_sum.s1 += ((float)(((bits4.s5 & 0x000F)      ) | ((bits2.s5 & 0x03) << 4)) - 32.f) * scale_s.s3 * scale_d.s1 * shared_y; \
    shared_y = SGB_BC(y.s1, 3); \
    total_sum.s0 += ((float)(((bits4.s4 & 0x00F0) >>  4) | ((bits2.s4 & 0x0C) << 2)) - 32.f) * scale_s.s1 * scale_d.s0 * shared_y; \
    total_sum.s1 += ((float)(((bits4.s5 & 0x00F0) >>  4) | ((bits2.s5 & 0x0C) << 2)) - 32.f) * scale_s.s3 * scale_d.s1 * shared_y; \
    shared_y = SGB_BC(y.s2, 3); \
    total_sum.s0 += ((float)(((bits4.s4 & 0x0F00) >>  8) | ((bits2.s4 & 0x30)     )) - 32.f) * scale_s.s1 * scale_d.s0 * shared_y; \
    total_sum.s1 += ((float)(((bits4.s5 & 0x0F00) >>  8) | ((bits2.s5 & 0x30)     )) - 32.f) * scale_s.s3 * scale_d.s1 * shared_y; \
    shared_y = SGB_BC(y.s3, 3); \
    total_sum.s0 += ((float)(((bits4.s4 & 0xF000) >> 12) | ((bits2.s4 & 0xC0) >> 2)) - 32.f) * scale_s.s1 * scale_d.s0 * shared_y; \
    total_sum.s1 += ((float)(((bits4.s5 & 0xF000) >> 12) | ((bits2.s5 & 0xC0) >> 2)) - 32.f) * scale_s.s3 * scale_d.s1 * shared_y; \
    shared_y = SGB_BC(y.s4, 3); \
    total_sum.s0 += ((float)(((bits4.s6 & 0x000F)      ) | ((bits2.s6 & 0x03) << 4)) - 32.f) * scale_s.s1 * scale_d.s0 * shared_y; \
    total_sum.s1 += ((float)(((bits4.s7 & 0x000F)      ) | ((bits2.s7 & 0x03) << 4)) - 32.f) * scale_s.s3 * scale_d.s1 * shared_y; \
    shared_y = SGB_BC(y.s5, 3); \
    total_sum.s0 += ((float)(((bits4.s6 & 0x00F0) >>  4) | ((bits2.s6 & 0x0C) << 2)) - 32.f) * scale_s.s1 * scale_d.s0 * shared_y; \
    total_sum.s1 += ((float)(((bits4.s7 & 0x00F0) >>  4) | ((bits2.s7 & 0x0C) << 2)) - 32.f) * scale_s.s3 * scale_d.s1 * shared_y; \
    shared_y = SGB_BC(y.s6, 3); \
    total_sum.s0 += ((float)(((bits4.s6 & 0x0F00) >>  8) | ((bits2.s6 & 0x30)     )) - 32.f) * scale_s.s1 * scale_d.s0 * shared_y; \
    total_sum.s1 += ((float)(((bits4.s7 & 0x0F00) >>  8) | ((bits2.s7 & 0x30)     )) - 32.f) * scale_s.s3 * scale_d.s1 * shared_y; \
    shared_y = SGB_BC(y.s7, 3); \
    total_sum.s0 += ((float)(((bits4.s6 & 0xF000) >> 12) | ((bits2.s6 & 0xC0) >> 2)) - 32.f) * scale_s.s1 * scale_d.s0 * shared_y; \
    total_sum.s1 += ((float)(((bits4.s7 & 0xF000) >> 12) | ((bits2.s7 & 0xC0) >> 2)) - 32.f) * scale_s.s3 * scale_d.s1 * shared_y; \

#if defined(ADRENO_GPU)
REQD_SUBGROUP_SIZE_64
#endif
kernel void kernel_gemv_noshuffle_q6_K_f32(
    read_only image1d_buffer_t src0_ql,
    read_only image1d_buffer_t src0_qh,
    global half2 * src0_s,
    global half2 * src0_d,
    read_only image1d_buffer_t src1,
    global float * dst,
    ulong offsetd,
    int ne00,
    int ne01
) {
    int grp = get_local_id(1);
    int gid = get_global_id(0);
    ushort slid = get_sub_group_local_id();

    int nb = ne00 / 32;

    uint4    reg_a_l;
    ushort4  reg_a_h;
    half2    reg_d;
    char4    reg_s;
    float8   reg_b;

    float2  total_sum = 0.0f;

    int line_stride_a = ne01 / 2;
    // Keep tail lanes active for subgroup ops, but read a valid weight row.
    int gid_s = min(gid, line_stride_a - 1);
    int block_stride_a = NSUBGROUPS * ne01;

    // [dspark 2026-10-17] K-split stride is now the LAUNCH's y-size (was the
    // compile-time NSUBGROUPS). The host clamps the y-split to 1 on generic
    // runtimes (rusticl), so the loop must cover all blocks in that case.
    uint nsg_rt = get_local_size(1);
    for (int k = grp; k < nb; k += nsg_rt) {
        reg_d = src0_d[gid_s + k/8 * line_stride_a];
        reg_s = as_char4(src0_s[gid_s + k * line_stride_a]);

        if (slid < 4) {
            reg_b.s0123 = read_imagef(src1, 0 + slid*2 + k*8);
            reg_b.s4567 = read_imagef(src1, 1 + slid*2 + k*8);
        }

        reg_a_l.s0 = read_imageui(src0_ql, gid_s + k*block_stride_a + line_stride_a*0).x;
        reg_a_l.s1 = read_imageui(src0_ql, gid_s + k*block_stride_a + line_stride_a*1).x;
        reg_a_l.s2 = read_imageui(src0_ql, gid_s + k*block_stride_a + line_stride_a*2).x;
        reg_a_l.s3 = read_imageui(src0_ql, gid_s + k*block_stride_a + line_stride_a*3).x;

        reg_a_h.s0 = as_ushort(read_imageh(src0_qh, gid_s + k*block_stride_a + line_stride_a*0).x);
        reg_a_h.s1 = as_ushort(read_imageh(src0_qh, gid_s + k*block_stride_a + line_stride_a*1).x);
        reg_a_h.s2 = as_ushort(read_imageh(src0_qh, gid_s + k*block_stride_a + line_stride_a*2).x);
        reg_a_h.s3 = as_ushort(read_imageh(src0_qh, gid_s + k*block_stride_a + line_stride_a*3).x);

#ifdef VECTOR_SUB_GROUP_BROADCAT
        dequantize_block_acc_bcast_8_hi(total_sum, as_ushort8(reg_a_l), as_uchar8(reg_a_h), reg_d, reg_s, reg_b);
#else
        dequantize_block_acc_bcast_1_hi(total_sum, as_ushort8(reg_a_l), as_uchar8(reg_a_h), reg_d, reg_s, reg_b);
#endif // VECTOR_SUB_GROUP_BROADCAT

        reg_a_l.s0 = read_imageui(src0_ql, gid_s + k*block_stride_a + line_stride_a*4).x;
        reg_a_l.s1 = read_imageui(src0_ql, gid_s + k*block_stride_a + line_stride_a*5).x;
        reg_a_l.s2 = read_imageui(src0_ql, gid_s + k*block_stride_a + line_stride_a*6).x;
        reg_a_l.s3 = read_imageui(src0_ql, gid_s + k*block_stride_a + line_stride_a*7).x;

        reg_a_h.s0 = as_ushort(read_imageh(src0_qh, gid_s + k*block_stride_a + line_stride_a*4).x);
        reg_a_h.s1 = as_ushort(read_imageh(src0_qh, gid_s + k*block_stride_a + line_stride_a*5).x);
        reg_a_h.s2 = as_ushort(read_imageh(src0_qh, gid_s + k*block_stride_a + line_stride_a*6).x);
        reg_a_h.s3 = as_ushort(read_imageh(src0_qh, gid_s + k*block_stride_a + line_stride_a*7).x);

#ifdef VECTOR_SUB_GROUP_BROADCAT
        dequantize_block_acc_bcast_8_lo(total_sum, as_ushort8(reg_a_l), as_uchar8(reg_a_h), reg_d, reg_s, reg_b);
#else
        dequantize_block_acc_bcast_1_lo(total_sum, as_ushort8(reg_a_l), as_uchar8(reg_a_h), reg_d, reg_s, reg_b);
#endif // VECTOR_SUB_GROUP_BROADCAT
    }

    local float2 reduce_lm[SUBGROUP_SIZE * 3];
    if (grp > 0) {
        reduce_lm[SUBGROUP_SIZE*(grp-1) + slid] = total_sum;
    }

    barrier(CLK_LOCAL_MEM_FENCE);

    if (grp == 0) {
        for (uint i = 0; i < nsg_rt - 1; ++i) {
            total_sum += reduce_lm[SUBGROUP_SIZE*i + slid];
        }
    }

    if (grp == 0) {
        dst = (global float*)((global char*)dst + offsetd);
        // Guard the two output rows. The x-grid is padded to CEIL_DIV(ne01/2,64)*64,
        // so when ne01 is not a multiple of 128 the tail row-pairs run past row ne01
        // and would overrun dst into the adjacent tensor (garbage downstream).
        // No-op / byte-identical when ne01 % 128 == 0 (no padding).
        if (gid * 2 + 0 < ne01) dst[gid * 2 + 0] = total_sum.s0;
        if (gid * 2 + 1 < ne01) dst[gid * 2 + 1] = total_sum.s1;
    }
}

// Multi-column (N=3) q6_K decode GEMV for the spec/MTP verify batch. Same idea
// as the q4_K mc3: stay on the efficient GEMV path (subgroup broadcast, no
// transpose) instead of the transposed-GEMM dead-zone. Each K-block's weights
// (ql/qh, hi+lo) are loaded ONCE and reused across all 3 activation columns.
// Per-column accumulation is independent and identical to 3 standalone GEMVs
// => byte-identical; does NOT perturb the lm_head logits / spec accept rate.
#if defined(ADRENO_GPU)
REQD_SUBGROUP_SIZE_64
#endif
kernel void kernel_gemv_noshuffle_q6_K_f32_mc3(
    read_only image1d_buffer_t src0_ql,
    read_only image1d_buffer_t src0_qh,
    global half2 * src0_s,
    global half2 * src0_d,
    read_only image1d_buffer_t src1,
    global float * dst,
    ulong offsetd,
    int ne00,
    int ne01
) {
    int grp  = get_local_id(1);
    int gid  = get_global_id(0);
    ushort slid = get_sub_group_local_id();

    int nb = ne00 / 32;
    int line_stride_a  = ne01 / 2;
    // Keep tail lanes active for subgroup ops, but read a valid weight row.
    int gid_s = min(gid, line_stride_a - 1);
    int block_stride_a = NSUBGROUPS * ne01;
    int COL_STRIDE     = ne00 / 4;   // float4 pixels per activation column

    uint4   ql_hi, ql_lo;
    ushort4 qh_hi, qh_lo;
    half2   reg_d;
    char4   reg_s;
    float8  reg_b;

    float2  ts0 = 0.0f, ts1 = 0.0f, ts2 = 0.0f;

<<<<<<< fork
    uint nsg_rt = get_local_size(1);  // [dspark] runtime K-split stride
    for (int k = grp; k < nb; k += nsg_rt) {
        reg_d = src0_d[gid_s + k/8 * line_stride_a];
        reg_s = as_char4(src0_s[gid_s + k * line_stride_a]);

        // weights loaded ONCE (hi: blocks 0-3, lo: blocks 4-7), reused x3 cols
        ql_hi.s0 = read_imageui(src0_ql, gid_s + k*block_stride_a + line_stride_a*0).x;
        ql_hi.s1 = read_imageui(src0_ql, gid_s + k*block_stride_a + line_stride_a*1).x;
        ql_hi.s2 = read_imageui(src0_ql, gid_s + k*block_stride_a + line_stride_a*2).x;
        ql_hi.s3 = read_imageui(src0_ql, gid_s + k*block_stride_a + line_stride_a*3).x;
        qh_hi.s0 = as_ushort(read_imageh(src0_qh, gid_s + k*block_stride_a + line_stride_a*0).x);
        qh_hi.s1 = as_ushort(read_imageh(src0_qh, gid_s + k*block_stride_a + line_stride_a*1).x);
        qh_hi.s2 = as_ushort(read_imageh(src0_qh, gid_s + k*block_stride_a + line_stride_a*2).x);
        qh_hi.s3 = as_ushort(read_imageh(src0_qh, gid_s + k*block_stride_a + line_stride_a*3).x);

        ql_lo.s0 = read_imageui(src0_ql, gid_s + k*block_stride_a + line_stride_a*4).x;
        ql_lo.s1 = read_imageui(src0_ql, gid_s + k*block_stride_a + line_stride_a*5).x;
        ql_lo.s2 = read_imageui(src0_ql, gid_s + k*block_stride_a + line_stride_a*6).x;
        ql_lo.s3 = read_imageui(src0_ql, gid_s + k*block_stride_a + line_stride_a*7).x;
        qh_lo.s0 = as_ushort(read_imageh(src0_qh, gid_s + k*block_stride_a + line_stride_a*4).x);
        qh_lo.s1 = as_ushort(read_imageh(src0_qh, gid_s + k*block_stride_a + line_stride_a*5).x);
        qh_lo.s2 = as_ushort(read_imageh(src0_qh, gid_s + k*block_stride_a + line_stride_a*6).x);
        qh_lo.s3 = as_ushort(read_imageh(src0_qh, gid_s + k*block_stride_a + line_stride_a*7).x);

        // Per-column: load only this column's activation (single reg_b live) ->
        // 1/3 the activation register pressure, cutting the private-mem spill.
#ifdef VECTOR_SUB_GROUP_BROADCAT
        { if (slid < 4) { reg_b.s0123 = read_imagef(src1, 0*COL_STRIDE + 0 + slid*2 + k*8);
                          reg_b.s4567 = read_imagef(src1, 0*COL_STRIDE + 1 + slid*2 + k*8); }
          dequantize_block_acc_bcast_8_hi(ts0, as_ushort8(ql_hi), as_uchar8(qh_hi), reg_d, reg_s, reg_b);
          dequantize_block_acc_bcast_8_lo(ts0, as_ushort8(ql_lo), as_uchar8(qh_lo), reg_d, reg_s, reg_b); }
        { if (slid < 4) { reg_b.s0123 = read_imagef(src1, 1*COL_STRIDE + 0 + slid*2 + k*8);
                          reg_b.s4567 = read_imagef(src1, 1*COL_STRIDE + 1 + slid*2 + k*8); }
          dequantize_block_acc_bcast_8_hi(ts1, as_ushort8(ql_hi), as_uchar8(qh_hi), reg_d, reg_s, reg_b);
          dequantize_block_acc_bcast_8_lo(ts1, as_ushort8(ql_lo), as_uchar8(qh_lo), reg_d, reg_s, reg_b); }
        { if (slid < 4) { reg_b.s0123 = read_imagef(src1, 2*COL_STRIDE + 0 + slid*2 + k*8);
                          reg_b.s4567 = read_imagef(src1, 2*COL_STRIDE + 1 + slid*2 + k*8); }
          dequantize_block_acc_bcast_8_hi(ts2, as_ushort8(ql_hi), as_uchar8(qh_hi), reg_d, reg_s, reg_b);
          dequantize_block_acc_bcast_8_lo(ts2, as_ushort8(ql_lo), as_uchar8(qh_lo), reg_d, reg_s, reg_b); }
#else
        { if (slid < 4) { reg_b.s0123 = read_imagef(src1, 0*COL_STRIDE + 0 + slid*2 + k*8);
                          reg_b.s4567 = read_imagef(src1, 0*COL_STRIDE + 1 + slid*2 + k*8); }
          dequantize_block_acc_bcast_1_hi(ts0, as_ushort8(ql_hi), as_uchar8(qh_hi), reg_d, reg_s, reg_b);
          dequantize_block_acc_bcast_1_lo(ts0, as_ushort8(ql_lo), as_uchar8(qh_lo), reg_d, reg_s, reg_b); }
        { if (slid < 4) { reg_b.s0123 = read_imagef(src1, 1*COL_STRIDE + 0 + slid*2 + k*8);
                          reg_b.s4567 = read_imagef(src1, 1*COL_STRIDE + 1 + slid*2 + k*8); }
          dequantize_block_acc_bcast_1_hi(ts1, as_ushort8(ql_hi), as_uchar8(qh_hi), reg_d, reg_s, reg_b);
          dequantize_block_acc_bcast_1_lo(ts1, as_ushort8(ql_lo), as_uchar8(qh_lo), reg_d, reg_s, reg_b); }
        { if (slid < 4) { reg_b.s0123 = read_imagef(src1, 2*COL_STRIDE + 0 + slid*2 + k*8);
                          reg_b.s4567 = read_imagef(src1, 2*COL_STRIDE + 1 + slid*2 + k*8); }
          dequantize_block_acc_bcast_1_hi(ts2, as_ushort8(ql_hi), as_uchar8(qh_hi), reg_d, reg_s, reg_b);
          dequantize_block_acc_bcast_1_lo(ts2, as_ushort8(ql_lo), as_uchar8(qh_lo), reg_d, reg_s, reg_b); }
#endif
    }

    local float8 reduce_lm[SUBGROUP_SIZE * 3];
    float8 acc = (float8)(ts0.s0, ts0.s1, ts1.s0, ts1.s1, ts2.s0, ts2.s1, 0.0f, 0.0f);
    if (grp > 0) {
        reduce_lm[SUBGROUP_SIZE*(grp-1) + slid] = acc;
    }

    barrier(CLK_LOCAL_MEM_FENCE);

    if (grp == 0) {
        for (uint i = 0; i < nsg_rt - 1; ++i) {
            acc += reduce_lm[SUBGROUP_SIZE*i + slid];
        }
        dst = (global float*)((global char*)dst + offsetd);
        // dst column-major [ne01 rows x 3 cols]: (row, col) at col*ne01 + row
        if (gid < line_stride_a) {
            vstore2((float2)(acc.s0, acc.s1), 0, &(dst[0*ne01 + gid*2]));
            vstore2((float2)(acc.s2, acc.s3), 0, &(dst[1*ne01 + gid*2]));
            vstore2((float2)(acc.s4, acc.s5), 0, &(dst[2*ne01 + gid*2]));
        }
    }
}
