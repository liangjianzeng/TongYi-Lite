R"(#pragma OPENCL EXTENSION cl_khr_fp16 : enable
)"
R"(#pragma OPENCL EXTENSION cl_khr_subgroups : enable
)"
R"(
)"
R"(// [dspark 2026-10-14] Scalar-float subgroup broadcast. 740's online compiler
)"
R"(// lacks float overloads of sub_group_broadcast entirely -> host passes
)"
R"(// -DSGB_SCALAR_BROKEN and broadcasts go through the uint-bitcast shim.
)"
R"(// 830 (E031.47) has working float broadcast but miscompiles kernels whose
)"
R"(// broadcasts go through an inline wrapper, even in pass-through form
)"
R"(// (NMSE~2.2, 2026-10-14) -> uses the direct builtin. All call sites are
)"
R"(// per-component scalar: no vector broadcast anywhere.
)"
R"(#ifdef SGB_SCALAR_BROKEN
)"
R"(inline float sgb_f(float v, uint lid) {
)"
R"(    return as_float(sub_group_broadcast(as_uint(v), lid));
)"
R"(}
)"
R"(#define SGB_BC(v, lid) sgb_f(v, lid)
)"
R"(#else
)"
R"(#define SGB_BC(v, lid) sub_group_broadcast(v, lid)
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
R"(// the driver's online compiler lacks float overloads of sub_group_broadcast
)"
R"(// (Adreno 740: only scalar uint/int/long/ulong exist). Bitcast float<->uint,
)"
R"(// broadcast as integer, cast back — bitwise identical, subgroup-uniform.
)"
R"(#define NSUBGROUPS 4
)"
R"(#define SUBGROUP_SIZE 64
)"
R"(
)"
R"(#define dequantize_block_acc_bcast_8_hi(total_sum, bits4, bits2, scale_d, scale_s, y) \
)"
R"(    float8 shared_y; \
)"
R"(    shared_y.s0 = SGB_BC(y.s0, 0); \
)"
R"(    shared_y.s1 = SGB_BC(y.s1, 0); \
)"
R"(    shared_y.s2 = SGB_BC(y.s2, 0); \
)"
R"(    shared_y.s3 = SGB_BC(y.s3, 0); \
)"
R"(    shared_y.s4 = SGB_BC(y.s4, 0); \
)"
R"(    shared_y.s5 = SGB_BC(y.s5, 0); \
)"
R"(    shared_y.s6 = SGB_BC(y.s6, 0); \
)"
R"(    shared_y.s7 = SGB_BC(y.s7, 0); \
)"
R"(    total_sum.s0 += ((float)(((bits4.s0 & 0x000F)      ) | ((bits2.s0 & 0x03) << 4)) - 32.f) * scale_s.s0 * scale_d.s0 * shared_y.s0; \
)"
R"(    total_sum.s0 += ((float)(((bits4.s0 & 0x00F0) >>  4) | ((bits2.s0 & 0x0C) << 2)) - 32.f) * scale_s.s0 * scale_d.s0 * shared_y.s1; \
)"
R"(    total_sum.s0 += ((float)(((bits4.s0 & 0x0F00) >>  8) | ((bits2.s0 & 0x30)     )) - 32.f) * scale_s.s0 * scale_d.s0 * shared_y.s2; \
)"
R"(    total_sum.s0 += ((float)(((bits4.s0 & 0xF000) >> 12) | ((bits2.s0 & 0xC0) >> 2)) - 32.f) * scale_s.s0 * scale_d.s0 * shared_y.s3; \
)"
R"(    total_sum.s0 += ((float)(((bits4.s2 & 0x000F)      ) | ((bits2.s2 & 0x03) << 4)) - 32.f) * scale_s.s0 * scale_d.s0 * shared_y.s4; \
)"
R"(    total_sum.s0 += ((float)(((bits4.s2 & 0x00F0) >>  4) | ((bits2.s2 & 0x0C) << 2)) - 32.f) * scale_s.s0 * scale_d.s0 * shared_y.s5; \
)"
R"(    total_sum.s0 += ((float)(((bits4.s2 & 0x0F00) >>  8) | ((bits2.s2 & 0x30)     )) - 32.f) * scale_s.s0 * scale_d.s0 * shared_y.s6; \
)"
R"(    total_sum.s0 += ((float)(((bits4.s2 & 0xF000) >> 12) | ((bits2.s2 & 0xC0) >> 2)) - 32.f) * scale_s.s0 * scale_d.s0 * shared_y.s7; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s1 & 0x000F)      ) | ((bits2.s1 & 0x03) << 4)) - 32.f) * scale_s.s2 * scale_d.s1 * shared_y.s0; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s1 & 0x00F0) >>  4) | ((bits2.s1 & 0x0C) << 2)) - 32.f) * scale_s.s2 * scale_d.s1 * shared_y.s1; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s1 & 0x0F00) >>  8) | ((bits2.s1 & 0x30)     )) - 32.f) * scale_s.s2 * scale_d.s1 * shared_y.s2; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s1 & 0xF000) >> 12) | ((bits2.s1 & 0xC0) >> 2)) - 32.f) * scale_s.s2 * scale_d.s1 * shared_y.s3; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s3 & 0x000F)      ) | ((bits2.s3 & 0x03) << 4)) - 32.f) * scale_s.s2 * scale_d.s1 * shared_y.s4; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s3 & 0x00F0) >>  4) | ((bits2.s3 & 0x0C) << 2)) - 32.f) * scale_s.s2 * scale_d.s1 * shared_y.s5; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s3 & 0x0F00) >>  8) | ((bits2.s3 & 0x30)     )) - 32.f) * scale_s.s2 * scale_d.s1 * shared_y.s6; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s3 & 0xF000) >> 12) | ((bits2.s3 & 0xC0) >> 2)) - 32.f) * scale_s.s2 * scale_d.s1 * shared_y.s7; \
)"
R"(    shared_y.s0 = SGB_BC(y.s0, 1); \
)"
R"(    shared_y.s1 = SGB_BC(y.s1, 1); \
)"
R"(    shared_y.s2 = SGB_BC(y.s2, 1); \
)"
R"(    shared_y.s3 = SGB_BC(y.s3, 1); \
)"
R"(    shared_y.s4 = SGB_BC(y.s4, 1); \
)"
R"(    shared_y.s5 = SGB_BC(y.s5, 1); \
)"
R"(    shared_y.s6 = SGB_BC(y.s6, 1); \
)"
R"(    shared_y.s7 = SGB_BC(y.s7, 1); \
)"
R"(    total_sum.s0 += ((float)(((bits4.s4 & 0x000F)      ) | ((bits2.s4 & 0x03) << 4)) - 32.f) * scale_s.s0 * scale_d.s0 * shared_y.s0; \
)"
R"(    total_sum.s0 += ((float)(((bits4.s4 & 0x00F0) >>  4) | ((bits2.s4 & 0x0C) << 2)) - 32.f) * scale_s.s0 * scale_d.s0 * shared_y.s1; \
)"
R"(    total_sum.s0 += ((float)(((bits4.s4 & 0x0F00) >>  8) | ((bits2.s4 & 0x30)     )) - 32.f) * scale_s.s0 * scale_d.s0 * shared_y.s2; \
)"
R"(    total_sum.s0 += ((float)(((bits4.s4 & 0xF000) >> 12) | ((bits2.s4 & 0xC0) >> 2)) - 32.f) * scale_s.s0 * scale_d.s0 * shared_y.s3; \
)"
R"(    total_sum.s0 += ((float)(((bits4.s6 & 0x000F)      ) | ((bits2.s6 & 0x03) << 4)) - 32.f) * scale_s.s0 * scale_d.s0 * shared_y.s4; \
)"
R"(    total_sum.s0 += ((float)(((bits4.s6 & 0x00F0) >>  4) | ((bits2.s6 & 0x0C) << 2)) - 32.f) * scale_s.s0 * scale_d.s0 * shared_y.s5; \
)"
R"(    total_sum.s0 += ((float)(((bits4.s6 & 0x0F00) >>  8) | ((bits2.s6 & 0x30)     )) - 32.f) * scale_s.s0 * scale_d.s0 * shared_y.s6; \
)"
R"(    total_sum.s0 += ((float)(((bits4.s6 & 0xF000) >> 12) | ((bits2.s6 & 0xC0) >> 2)) - 32.f) * scale_s.s0 * scale_d.s0 * shared_y.s7; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s5 & 0x000F)      ) | ((bits2.s5 & 0x03) << 4)) - 32.f) * scale_s.s2 * scale_d.s1 * shared_y.s0; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s5 & 0x00F0) >>  4) | ((bits2.s5 & 0x0C) << 2)) - 32.f) * scale_s.s2 * scale_d.s1 * shared_y.s1; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s5 & 0x0F00) >>  8) | ((bits2.s5 & 0x30)     )) - 32.f) * scale_s.s2 * scale_d.s1 * shared_y.s2; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s5 & 0xF000) >> 12) | ((bits2.s5 & 0xC0) >> 2)) - 32.f) * scale_s.s2 * scale_d.s1 * shared_y.s3; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s7 & 0x000F)      ) | ((bits2.s7 & 0x03) << 4)) - 32.f) * scale_s.s2 * scale_d.s1 * shared_y.s4; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s7 & 0x00F0) >>  4) | ((bits2.s7 & 0x0C) << 2)) - 32.f) * scale_s.s2 * scale_d.s1 * shared_y.s5; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s7 & 0x0F00) >>  8) | ((bits2.s7 & 0x30)     )) - 32.f) * scale_s.s2 * scale_d.s1 * shared_y.s6; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s7 & 0xF000) >> 12) | ((bits2.s7 & 0xC0) >> 2)) - 32.f) * scale_s.s2 * scale_d.s1 * shared_y.s7; \
)"
R"(
)"
R"(#define dequantize_block_acc_bcast_8_lo(total_sum, bits4, bits2, scale_d, scale_s, y) \
)"
R"(    shared_y.s0 = SGB_BC(y.s0, 2); \
)"
R"(    shared_y.s1 = SGB_BC(y.s1, 2); \
)"
R"(    shared_y.s2 = SGB_BC(y.s2, 2); \
)"
R"(    shared_y.s3 = SGB_BC(y.s3, 2); \
)"
R"(    shared_y.s4 = SGB_BC(y.s4, 2); \
)"
R"(    shared_y.s5 = SGB_BC(y.s5, 2); \
)"
R"(    shared_y.s6 = SGB_BC(y.s6, 2); \
)"
R"(    shared_y.s7 = SGB_BC(y.s7, 2); \
)"
R"(    total_sum.s0 += ((float)(((bits4.s0 & 0x000F)      ) | ((bits2.s0 & 0x03) << 4)) - 32.f) * scale_s.s1 * scale_d.s0 * shared_y.s0; \
)"
R"(    total_sum.s0 += ((float)(((bits4.s0 & 0x00F0) >>  4) | ((bits2.s0 & 0x0C) << 2)) - 32.f) * scale_s.s1 * scale_d.s0 * shared_y.s1; \
)"
R"(    total_sum.s0 += ((float)(((bits4.s0 & 0x0F00) >>  8) | ((bits2.s0 & 0x30)     )) - 32.f) * scale_s.s1 * scale_d.s0 * shared_y.s2; \
)"
R"(    total_sum.s0 += ((float)(((bits4.s0 & 0xF000) >> 12) | ((bits2.s0 & 0xC0) >> 2)) - 32.f) * scale_s.s1 * scale_d.s0 * shared_y.s3; \
)"
R"(    total_sum.s0 += ((float)(((bits4.s2 & 0x000F)      ) | ((bits2.s2 & 0x03) << 4)) - 32.f) * scale_s.s1 * scale_d.s0 * shared_y.s4; \
)"
R"(    total_sum.s0 += ((float)(((bits4.s2 & 0x00F0) >>  4) | ((bits2.s2 & 0x0C) << 2)) - 32.f) * scale_s.s1 * scale_d.s0 * shared_y.s5; \
)"
R"(    total_sum.s0 += ((float)(((bits4.s2 & 0x0F00) >>  8) | ((bits2.s2 & 0x30)     )) - 32.f) * scale_s.s1 * scale_d.s0 * shared_y.s6; \
)"
R"(    total_sum.s0 += ((float)(((bits4.s2 & 0xF000) >> 12) | ((bits2.s2 & 0xC0) >> 2)) - 32.f) * scale_s.s1 * scale_d.s0 * shared_y.s7; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s1 & 0x000F)      ) | ((bits2.s1 & 0x03) << 4)) - 32.f) * scale_s.s3 * scale_d.s1 * shared_y.s0; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s1 & 0x00F0) >>  4) | ((bits2.s1 & 0x0C) << 2)) - 32.f) * scale_s.s3 * scale_d.s1 * shared_y.s1; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s1 & 0x0F00) >>  8) | ((bits2.s1 & 0x30)     )) - 32.f) * scale_s.s3 * scale_d.s1 * shared_y.s2; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s1 & 0xF000) >> 12) | ((bits2.s1 & 0xC0) >> 2)) - 32.f) * scale_s.s3 * scale_d.s1 * shared_y.s3; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s3 & 0x000F)      ) | ((bits2.s3 & 0x03) << 4)) - 32.f) * scale_s.s3 * scale_d.s1 * shared_y.s4; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s3 & 0x00F0) >>  4) | ((bits2.s3 & 0x0C) << 2)) - 32.f) * scale_s.s3 * scale_d.s1 * shared_y.s5; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s3 & 0x0F00) >>  8) | ((bits2.s3 & 0x30)     )) - 32.f) * scale_s.s3 * scale_d.s1 * shared_y.s6; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s3 & 0xF000) >> 12) | ((bits2.s3 & 0xC0) >> 2)) - 32.f) * scale_s.s3 * scale_d.s1 * shared_y.s7; \
)"
R"(    shared_y.s0 = SGB_BC(y.s0, 3); \
)"
R"(    shared_y.s1 = SGB_BC(y.s1, 3); \
)"
R"(    shared_y.s2 = SGB_BC(y.s2, 3); \
)"
R"(    shared_y.s3 = SGB_BC(y.s3, 3); \
)"
R"(    shared_y.s4 = SGB_BC(y.s4, 3); \
)"
R"(    shared_y.s5 = SGB_BC(y.s5, 3); \
)"
R"(    shared_y.s6 = SGB_BC(y.s6, 3); \
)"
R"(    shared_y.s7 = SGB_BC(y.s7, 3); \
)"
R"(    total_sum.s0 += ((float)(((bits4.s4 & 0x000F)      ) | ((bits2.s4 & 0x03) << 4)) - 32.f) * scale_s.s1 * scale_d.s0 * shared_y.s0; \
)"
R"(    total_sum.s0 += ((float)(((bits4.s4 & 0x00F0) >>  4) | ((bits2.s4 & 0x0C) << 2)) - 32.f) * scale_s.s1 * scale_d.s0 * shared_y.s1; \
)"
R"(    total_sum.s0 += ((float)(((bits4.s4 & 0x0F00) >>  8) | ((bits2.s4 & 0x30)     )) - 32.f) * scale_s.s1 * scale_d.s0 * shared_y.s2; \
)"
R"(    total_sum.s0 += ((float)(((bits4.s4 & 0xF000) >> 12) | ((bits2.s4 & 0xC0) >> 2)) - 32.f) * scale_s.s1 * scale_d.s0 * shared_y.s3; \
)"
R"(    total_sum.s0 += ((float)(((bits4.s6 & 0x000F)      ) | ((bits2.s6 & 0x03) << 4)) - 32.f) * scale_s.s1 * scale_d.s0 * shared_y.s4; \
)"
R"(    total_sum.s0 += ((float)(((bits4.s6 & 0x00F0) >>  4) | ((bits2.s6 & 0x0C) << 2)) - 32.f) * scale_s.s1 * scale_d.s0 * shared_y.s5; \
)"
R"(    total_sum.s0 += ((float)(((bits4.s6 & 0x0F00) >>  8) | ((bits2.s6 & 0x30)     )) - 32.f) * scale_s.s1 * scale_d.s0 * shared_y.s6; \
)"
R"(    total_sum.s0 += ((float)(((bits4.s6 & 0xF000) >> 12) | ((bits2.s6 & 0xC0) >> 2)) - 32.f) * scale_s.s1 * scale_d.s0 * shared_y.s7; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s5 & 0x000F)      ) | ((bits2.s5 & 0x03) << 4)) - 32.f) * scale_s.s3 * scale_d.s1 * shared_y.s0; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s5 & 0x00F0) >>  4) | ((bits2.s5 & 0x0C) << 2)) - 32.f) * scale_s.s3 * scale_d.s1 * shared_y.s1; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s5 & 0x0F00) >>  8) | ((bits2.s5 & 0x30)     )) - 32.f) * scale_s.s3 * scale_d.s1 * shared_y.s2; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s5 & 0xF000) >> 12) | ((bits2.s5 & 0xC0) >> 2)) - 32.f) * scale_s.s3 * scale_d.s1 * shared_y.s3; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s7 & 0x000F)      ) | ((bits2.s7 & 0x03) << 4)) - 32.f) * scale_s.s3 * scale_d.s1 * shared_y.s4; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s7 & 0x00F0) >>  4) | ((bits2.s7 & 0x0C) << 2)) - 32.f) * scale_s.s3 * scale_d.s1 * shared_y.s5; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s7 & 0x0F00) >>  8) | ((bits2.s7 & 0x30)     )) - 32.f) * scale_s.s3 * scale_d.s1 * shared_y.s6; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s7 & 0xF000) >> 12) | ((bits2.s7 & 0xC0) >> 2)) - 32.f) * scale_s.s3 * scale_d.s1 * shared_y.s7; \
)"
R"(
)"
R"(#define dequantize_block_acc_bcast_1_hi(total_sum, bits4, bits2, scale_d, scale_s, y) \
)"
R"(    float shared_y; \
)"
R"(    shared_y = SGB_BC(y.s0, 0); \
)"
R"(    total_sum.s0 += ((float)(((bits4.s0 & 0x000F)      ) | ((bits2.s0 & 0x03) << 4)) - 32.f) * scale_s.s0 * scale_d.s0 * shared_y; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s1 & 0x000F)      ) | ((bits2.s1 & 0x03) << 4)) - 32.f) * scale_s.s2 * scale_d.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s1, 0); \
)"
R"(    total_sum.s0 += ((float)(((bits4.s0 & 0x00F0) >>  4) | ((bits2.s0 & 0x0C) << 2)) - 32.f) * scale_s.s0 * scale_d.s0 * shared_y; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s1 & 0x00F0) >>  4) | ((bits2.s1 & 0x0C) << 2)) - 32.f) * scale_s.s2 * scale_d.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s2, 0); \
)"
R"(    total_sum.s0 += ((float)(((bits4.s0 & 0x0F00) >>  8) | ((bits2.s0 & 0x30)     )) - 32.f) * scale_s.s0 * scale_d.s0 * shared_y; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s1 & 0x0F00) >>  8) | ((bits2.s1 & 0x30)     )) - 32.f) * scale_s.s2 * scale_d.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s3, 0); \
)"
R"(    total_sum.s0 += ((float)(((bits4.s0 & 0xF000) >> 12) | ((bits2.s0 & 0xC0) >> 2)) - 32.f) * scale_s.s0 * scale_d.s0 * shared_y; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s1 & 0xF000) >> 12) | ((bits2.s1 & 0xC0) >> 2)) - 32.f) * scale_s.s2 * scale_d.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s4, 0); \
)"
R"(    total_sum.s0 += ((float)(((bits4.s2 & 0x000F)      ) | ((bits2.s2 & 0x03) << 4)) - 32.f) * scale_s.s0 * scale_d.s0 * shared_y; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s3 & 0x000F)      ) | ((bits2.s3 & 0x03) << 4)) - 32.f) * scale_s.s2 * scale_d.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s5, 0); \
)"
R"(    total_sum.s0 += ((float)(((bits4.s2 & 0x00F0) >>  4) | ((bits2.s2 & 0x0C) << 2)) - 32.f) * scale_s.s0 * scale_d.s0 * shared_y; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s3 & 0x00F0) >>  4) | ((bits2.s3 & 0x0C) << 2)) - 32.f) * scale_s.s2 * scale_d.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s6, 0); \
)"
R"(    total_sum.s0 += ((float)(((bits4.s2 & 0x0F00) >>  8) | ((bits2.s2 & 0x30)     )) - 32.f) * scale_s.s0 * scale_d.s0 * shared_y; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s3 & 0x0F00) >>  8) | ((bits2.s3 & 0x30)     )) - 32.f) * scale_s.s2 * scale_d.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s7, 0); \
)"
R"(    total_sum.s0 += ((float)(((bits4.s2 & 0xF000) >> 12) | ((bits2.s2 & 0xC0) >> 2)) - 32.f) * scale_s.s0 * scale_d.s0 * shared_y; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s3 & 0xF000) >> 12) | ((bits2.s3 & 0xC0) >> 2)) - 32.f) * scale_s.s2 * scale_d.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s0, 1); \
)"
R"(    total_sum.s0 += ((float)(((bits4.s4 & 0x000F)      ) | ((bits2.s4 & 0x03) << 4)) - 32.f) * scale_s.s0 * scale_d.s0 * shared_y; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s5 & 0x000F)      ) | ((bits2.s5 & 0x03) << 4)) - 32.f) * scale_s.s2 * scale_d.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s1, 1); \
)"
R"(    total_sum.s0 += ((float)(((bits4.s4 & 0x00F0) >>  4) | ((bits2.s4 & 0x0C) << 2)) - 32.f) * scale_s.s0 * scale_d.s0 * shared_y; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s5 & 0x00F0) >>  4) | ((bits2.s5 & 0x0C) << 2)) - 32.f) * scale_s.s2 * scale_d.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s2, 1); \
)"
R"(    total_sum.s0 += ((float)(((bits4.s4 & 0x0F00) >>  8) | ((bits2.s4 & 0x30)     )) - 32.f) * scale_s.s0 * scale_d.s0 * shared_y; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s5 & 0x0F00) >>  8) | ((bits2.s5 & 0x30)     )) - 32.f) * scale_s.s2 * scale_d.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s3, 1); \
)"
R"(    total_sum.s0 += ((float)(((bits4.s4 & 0xF000) >> 12) | ((bits2.s4 & 0xC0) >> 2)) - 32.f) * scale_s.s0 * scale_d.s0 * shared_y; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s5 & 0xF000) >> 12) | ((bits2.s5 & 0xC0) >> 2)) - 32.f) * scale_s.s2 * scale_d.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s4, 1); \
)"
R"(    total_sum.s0 += ((float)(((bits4.s6 & 0x000F)      ) | ((bits2.s6 & 0x03) << 4)) - 32.f) * scale_s.s0 * scale_d.s0 * shared_y; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s7 & 0x000F)      ) | ((bits2.s7 & 0x03) << 4)) - 32.f) * scale_s.s2 * scale_d.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s5, 1); \
)"
R"(    total_sum.s0 += ((float)(((bits4.s6 & 0x00F0) >>  4) | ((bits2.s6 & 0x0C) << 2)) - 32.f) * scale_s.s0 * scale_d.s0 * shared_y; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s7 & 0x00F0) >>  4) | ((bits2.s7 & 0x0C) << 2)) - 32.f) * scale_s.s2 * scale_d.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s6, 1); \
)"
R"(    total_sum.s0 += ((float)(((bits4.s6 & 0x0F00) >>  8) | ((bits2.s6 & 0x30)     )) - 32.f) * scale_s.s0 * scale_d.s0 * shared_y; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s7 & 0x0F00) >>  8) | ((bits2.s7 & 0x30)     )) - 32.f) * scale_s.s2 * scale_d.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s7, 1); \
)"
R"(    total_sum.s0 += ((float)(((bits4.s6 & 0xF000) >> 12) | ((bits2.s6 & 0xC0) >> 2)) - 32.f) * scale_s.s0 * scale_d.s0 * shared_y; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s7 & 0xF000) >> 12) | ((bits2.s7 & 0xC0) >> 2)) - 32.f) * scale_s.s2 * scale_d.s1 * shared_y; \
)"
R"(
)"
R"(#define dequantize_block_acc_bcast_1_lo(total_sum, bits4, bits2, scale_d, scale_s, y) \
)"
R"(    shared_y = SGB_BC(y.s0, 2); \
)"
R"(    total_sum.s0 += ((float)(((bits4.s0 & 0x000F)      ) | ((bits2.s0 & 0x03) << 4)) - 32.f) * scale_s.s1 * scale_d.s0 * shared_y; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s1 & 0x000F)      ) | ((bits2.s1 & 0x03) << 4)) - 32.f) * scale_s.s3 * scale_d.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s1, 2); \
)"
R"(    total_sum.s0 += ((float)(((bits4.s0 & 0x00F0) >>  4) | ((bits2.s0 & 0x0C) << 2)) - 32.f) * scale_s.s1 * scale_d.s0 * shared_y; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s1 & 0x00F0) >>  4) | ((bits2.s1 & 0x0C) << 2)) - 32.f) * scale_s.s3 * scale_d.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s2, 2); \
)"
R"(    total_sum.s0 += ((float)(((bits4.s0 & 0x0F00) >>  8) | ((bits2.s0 & 0x30)     )) - 32.f) * scale_s.s1 * scale_d.s0 * shared_y; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s1 & 0x0F00) >>  8) | ((bits2.s1 & 0x30)     )) - 32.f) * scale_s.s3 * scale_d.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s3, 2); \
)"
R"(    total_sum.s0 += ((float)(((bits4.s0 & 0xF000) >> 12) | ((bits2.s0 & 0xC0) >> 2)) - 32.f) * scale_s.s1 * scale_d.s0 * shared_y; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s1 & 0xF000) >> 12) | ((bits2.s1 & 0xC0) >> 2)) - 32.f) * scale_s.s3 * scale_d.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s4, 2); \
)"
R"(    total_sum.s0 += ((float)(((bits4.s2 & 0x000F)      ) | ((bits2.s2 & 0x03) << 4)) - 32.f) * scale_s.s1 * scale_d.s0 * shared_y; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s3 & 0x000F)      ) | ((bits2.s3 & 0x03) << 4)) - 32.f) * scale_s.s3 * scale_d.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s5, 2); \
)"
R"(    total_sum.s0 += ((float)(((bits4.s2 & 0x00F0) >>  4) | ((bits2.s2 & 0x0C) << 2)) - 32.f) * scale_s.s1 * scale_d.s0 * shared_y; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s3 & 0x00F0) >>  4) | ((bits2.s3 & 0x0C) << 2)) - 32.f) * scale_s.s3 * scale_d.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s6, 2); \
)"
R"(    total_sum.s0 += ((float)(((bits4.s2 & 0x0F00) >>  8) | ((bits2.s2 & 0x30)     )) - 32.f) * scale_s.s1 * scale_d.s0 * shared_y; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s3 & 0x0F00) >>  8) | ((bits2.s3 & 0x30)     )) - 32.f) * scale_s.s3 * scale_d.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s7, 2); \
)"
R"(    total_sum.s0 += ((float)(((bits4.s2 & 0xF000) >> 12) | ((bits2.s2 & 0xC0) >> 2)) - 32.f) * scale_s.s1 * scale_d.s0 * shared_y; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s3 & 0xF000) >> 12) | ((bits2.s3 & 0xC0) >> 2)) - 32.f) * scale_s.s3 * scale_d.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s0, 3); \
)"
R"(    total_sum.s0 += ((float)(((bits4.s4 & 0x000F)      ) | ((bits2.s4 & 0x03) << 4)) - 32.f) * scale_s.s1 * scale_d.s0 * shared_y; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s5 & 0x000F)      ) | ((bits2.s5 & 0x03) << 4)) - 32.f) * scale_s.s3 * scale_d.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s1, 3); \
)"
R"(    total_sum.s0 += ((float)(((bits4.s4 & 0x00F0) >>  4) | ((bits2.s4 & 0x0C) << 2)) - 32.f) * scale_s.s1 * scale_d.s0 * shared_y; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s5 & 0x00F0) >>  4) | ((bits2.s5 & 0x0C) << 2)) - 32.f) * scale_s.s3 * scale_d.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s2, 3); \
)"
R"(    total_sum.s0 += ((float)(((bits4.s4 & 0x0F00) >>  8) | ((bits2.s4 & 0x30)     )) - 32.f) * scale_s.s1 * scale_d.s0 * shared_y; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s5 & 0x0F00) >>  8) | ((bits2.s5 & 0x30)     )) - 32.f) * scale_s.s3 * scale_d.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s3, 3); \
)"
R"(    total_sum.s0 += ((float)(((bits4.s4 & 0xF000) >> 12) | ((bits2.s4 & 0xC0) >> 2)) - 32.f) * scale_s.s1 * scale_d.s0 * shared_y; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s5 & 0xF000) >> 12) | ((bits2.s5 & 0xC0) >> 2)) - 32.f) * scale_s.s3 * scale_d.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s4, 3); \
)"
R"(    total_sum.s0 += ((float)(((bits4.s6 & 0x000F)      ) | ((bits2.s6 & 0x03) << 4)) - 32.f) * scale_s.s1 * scale_d.s0 * shared_y; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s7 & 0x000F)      ) | ((bits2.s7 & 0x03) << 4)) - 32.f) * scale_s.s3 * scale_d.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s5, 3); \
)"
R"(    total_sum.s0 += ((float)(((bits4.s6 & 0x00F0) >>  4) | ((bits2.s6 & 0x0C) << 2)) - 32.f) * scale_s.s1 * scale_d.s0 * shared_y; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s7 & 0x00F0) >>  4) | ((bits2.s7 & 0x0C) << 2)) - 32.f) * scale_s.s3 * scale_d.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s6, 3); \
)"
R"(    total_sum.s0 += ((float)(((bits4.s6 & 0x0F00) >>  8) | ((bits2.s6 & 0x30)     )) - 32.f) * scale_s.s1 * scale_d.s0 * shared_y; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s7 & 0x0F00) >>  8) | ((bits2.s7 & 0x30)     )) - 32.f) * scale_s.s3 * scale_d.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s7, 3); \
)"
R"(    total_sum.s0 += ((float)(((bits4.s6 & 0xF000) >> 12) | ((bits2.s6 & 0xC0) >> 2)) - 32.f) * scale_s.s1 * scale_d.s0 * shared_y; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s7 & 0xF000) >> 12) | ((bits2.s7 & 0xC0) >> 2)) - 32.f) * scale_s.s3 * scale_d.s1 * shared_y; \
)"
R"(
)"
R"(#if defined(ADRENO_GPU)
)"
R"(REQD_SUBGROUP_SIZE_64
)"
R"(#endif
)"
R"(kernel void kernel_gemv_noshuffle_q6_K_f32(
)"
R"(    read_only image1d_buffer_t src0_ql,
)"
R"(    read_only image1d_buffer_t src0_qh,
)"
R"(    global half2 * src0_s,
)"
R"(    global half2 * src0_d,
)"
R"(    read_only image1d_buffer_t src1,
)"
R"(    global float * dst,
)"
R"(    ulong offsetd,
)"
R"(    int ne00,
)"
R"(    int ne01
)"
R"() {
)"
R"(    int grp = get_local_id(1);
)"
R"(    int gid = get_global_id(0);
)"
R"(    ushort slid = get_sub_group_local_id();
)"
R"(
)"
R"(    int nb = ne00 / 32;
)"
R"(
)"
R"(    uint4    reg_a_l;
)"
R"(    ushort4  reg_a_h;
)"
R"(    half2    reg_d;
)"
R"(    char4    reg_s;
)"
R"(    float8   reg_b;
)"
R"(
)"
R"(    float2  total_sum = 0.0f;
)"
R"(
)"
R"(    int line_stride_a = ne01 / 2;
)"
R"(    // Keep tail lanes active for subgroup ops, but read a valid weight row.
)"
R"(    int gid_s = min(gid, line_stride_a - 1);
)"
R"(    int block_stride_a = NSUBGROUPS * ne01;
)"
R"(
)"
R"(    // [dspark 2026-10-17] K-split stride is now the LAUNCH's y-size (was the
)"
R"(    // compile-time NSUBGROUPS). The host clamps the y-split to 1 on generic
)"
R"(    // runtimes (rusticl), so the loop must cover all blocks in that case.
)"
R"(    uint nsg_rt = get_local_size(1);
)"
R"(    for (int k = grp; k < nb; k += nsg_rt) {
)"
R"(        reg_d = src0_d[gid_s + k/8 * line_stride_a];
)"
R"(        reg_s = as_char4(src0_s[gid_s + k * line_stride_a]);
)"
R"(
)"
R"(        if (slid < 4) {
)"
R"(            reg_b.s0123 = read_imagef(src1, 0 + slid*2 + k*8);
)"
R"(            reg_b.s4567 = read_imagef(src1, 1 + slid*2 + k*8);
)"
R"(        }
)"
R"(
)"
R"(        reg_a_l.s0 = read_imageui(src0_ql, gid_s + k*block_stride_a + line_stride_a*0).x;
)"
R"(        reg_a_l.s1 = read_imageui(src0_ql, gid_s + k*block_stride_a + line_stride_a*1).x;
)"
R"(        reg_a_l.s2 = read_imageui(src0_ql, gid_s + k*block_stride_a + line_stride_a*2).x;
)"
R"(        reg_a_l.s3 = read_imageui(src0_ql, gid_s + k*block_stride_a + line_stride_a*3).x;
)"
R"(
)"
R"(        reg_a_h.s0 = as_ushort(read_imageh(src0_qh, gid_s + k*block_stride_a + line_stride_a*0).x);
)"
R"(        reg_a_h.s1 = as_ushort(read_imageh(src0_qh, gid_s + k*block_stride_a + line_stride_a*1).x);
)"
R"(        reg_a_h.s2 = as_ushort(read_imageh(src0_qh, gid_s + k*block_stride_a + line_stride_a*2).x);
)"
R"(        reg_a_h.s3 = as_ushort(read_imageh(src0_qh, gid_s + k*block_stride_a + line_stride_a*3).x);
)"
R"(
)"
R"(#ifdef VECTOR_SUB_GROUP_BROADCAT
)"
R"(        dequantize_block_acc_bcast_8_hi(total_sum, as_ushort8(reg_a_l), as_uchar8(reg_a_h), reg_d, reg_s, reg_b);
)"
R"(#else
)"
R"(        dequantize_block_acc_bcast_1_hi(total_sum, as_ushort8(reg_a_l), as_uchar8(reg_a_h), reg_d, reg_s, reg_b);
)"
R"(#endif // VECTOR_SUB_GROUP_BROADCAT
)"
R"(
)"
R"(        reg_a_l.s0 = read_imageui(src0_ql, gid_s + k*block_stride_a + line_stride_a*4).x;
)"
R"(        reg_a_l.s1 = read_imageui(src0_ql, gid_s + k*block_stride_a + line_stride_a*5).x;
)"
R"(        reg_a_l.s2 = read_imageui(src0_ql, gid_s + k*block_stride_a + line_stride_a*6).x;
)"
R"(        reg_a_l.s3 = read_imageui(src0_ql, gid_s + k*block_stride_a + line_stride_a*7).x;
)"
R"(
)"
R"(        reg_a_h.s0 = as_ushort(read_imageh(src0_qh, gid_s + k*block_stride_a + line_stride_a*4).x);
)"
R"(        reg_a_h.s1 = as_ushort(read_imageh(src0_qh, gid_s + k*block_stride_a + line_stride_a*5).x);
)"
R"(        reg_a_h.s2 = as_ushort(read_imageh(src0_qh, gid_s + k*block_stride_a + line_stride_a*6).x);
)"
R"(        reg_a_h.s3 = as_ushort(read_imageh(src0_qh, gid_s + k*block_stride_a + line_stride_a*7).x);
)"
R"(
)"
R"(#ifdef VECTOR_SUB_GROUP_BROADCAT
)"
R"(        dequantize_block_acc_bcast_8_lo(total_sum, as_ushort8(reg_a_l), as_uchar8(reg_a_h), reg_d, reg_s, reg_b);
)"
R"(#else
)"
R"(        dequantize_block_acc_bcast_1_lo(total_sum, as_ushort8(reg_a_l), as_uchar8(reg_a_h), reg_d, reg_s, reg_b);
)"
R"(#endif // VECTOR_SUB_GROUP_BROADCAT
)"
R"(    }
)"
R"(
)"
R"(    local float2 reduce_lm[SUBGROUP_SIZE * 3];
)"
R"(    if (grp > 0) {
)"
R"(        reduce_lm[SUBGROUP_SIZE*(grp-1) + slid] = total_sum;
)"
R"(    }
)"
R"(
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(    if (grp == 0) {
)"
R"(        for (uint i = 0; i < nsg_rt - 1; ++i) {
)"
R"(            total_sum += reduce_lm[SUBGROUP_SIZE*i + slid];
)"
R"(        }
)"
R"(    }
)"
R"(
)"
R"(    if (grp == 0) {
)"
R"(        dst = (global float*)((global char*)dst + offsetd);
)"
R"(        // Guard the two output rows. The x-grid is padded to CEIL_DIV(ne01/2,64)*64,
)"
R"(        // so when ne01 is not a multiple of 128 the tail row-pairs run past row ne01
)"
R"(        // and would overrun dst into the adjacent tensor (garbage downstream).
)"
R"(        // No-op / byte-identical when ne01 % 128 == 0 (no padding).
)"
R"(        if (gid * 2 + 0 < ne01) dst[gid * 2 + 0] = total_sum.s0;
)"
R"(        if (gid * 2 + 1 < ne01) dst[gid * 2 + 1] = total_sum.s1;
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(// Multi-column (N=3) q6_K decode GEMV for the spec/MTP verify batch. Same idea
)"
R"(// as the q4_K mc3: stay on the efficient GEMV path (subgroup broadcast, no
)"
R"(// transpose) instead of the transposed-GEMM dead-zone. Each K-block's weights
)"
R"(// (ql/qh, hi+lo) are loaded ONCE and reused across all 3 activation columns.
)"
R"(// Per-column accumulation is independent and identical to 3 standalone GEMVs
)"
R"(// => byte-identical; does NOT perturb the lm_head logits / spec accept rate.
)"
R"(#if defined(ADRENO_GPU)
)"
R"(REQD_SUBGROUP_SIZE_64
)"
R"(#endif
)"
R"(kernel void kernel_gemv_noshuffle_q6_K_f32_mc3(
)"
R"(    read_only image1d_buffer_t src0_ql,
)"
R"(    read_only image1d_buffer_t src0_qh,
)"
R"(    global half2 * src0_s,
)"
R"(    global half2 * src0_d,
)"
R"(    read_only image1d_buffer_t src1,
)"
R"(    global float * dst,
)"
R"(    ulong offsetd,
)"
R"(    int ne00,
)"
R"(    int ne01
)"
R"() {
)"
R"(    int grp  = get_local_id(1);
)"
R"(    int gid  = get_global_id(0);
)"
R"(    ushort slid = get_sub_group_local_id();
)"
R"(
)"
R"(    int nb = ne00 / 32;
)"
R"(    int line_stride_a  = ne01 / 2;
)"
R"(    // Keep tail lanes active for subgroup ops, but read a valid weight row.
)"
R"(    int gid_s = min(gid, line_stride_a - 1);
)"
R"(    int block_stride_a = NSUBGROUPS * ne01;
)"
R"(    int COL_STRIDE     = ne00 / 4;   // float4 pixels per activation column
)"
R"(
)"
R"(    uint4   ql_hi, ql_lo;
)"
R"(    ushort4 qh_hi, qh_lo;
)"
R"(    half2   reg_d;
)"
R"(    char4   reg_s;
)"
R"(    float8  reg_b;
)"
R"(
)"
R"(    float2  ts0 = 0.0f, ts1 = 0.0f, ts2 = 0.0f;
)"
R"(
)"
R"(    uint nsg_rt = get_local_size(1);  // [dspark] runtime K-split stride
)"
R"(    for (int k = grp; k < nb; k += nsg_rt) {
)"
R"(        reg_d = src0_d[gid_s + k/8 * line_stride_a];
)"
R"(        reg_s = as_char4(src0_s[gid_s + k * line_stride_a]);
)"
R"(
)"
R"(        // weights loaded ONCE (hi: blocks 0-3, lo: blocks 4-7), reused x3 cols
)"
R"(        ql_hi.s0 = read_imageui(src0_ql, gid_s + k*block_stride_a + line_stride_a*0).x;
)"
R"(        ql_hi.s1 = read_imageui(src0_ql, gid_s + k*block_stride_a + line_stride_a*1).x;
)"
R"(        ql_hi.s2 = read_imageui(src0_ql, gid_s + k*block_stride_a + line_stride_a*2).x;
)"
R"(        ql_hi.s3 = read_imageui(src0_ql, gid_s + k*block_stride_a + line_stride_a*3).x;
)"
R"(        qh_hi.s0 = as_ushort(read_imageh(src0_qh, gid_s + k*block_stride_a + line_stride_a*0).x);
)"
R"(        qh_hi.s1 = as_ushort(read_imageh(src0_qh, gid_s + k*block_stride_a + line_stride_a*1).x);
)"
R"(        qh_hi.s2 = as_ushort(read_imageh(src0_qh, gid_s + k*block_stride_a + line_stride_a*2).x);
)"
R"(        qh_hi.s3 = as_ushort(read_imageh(src0_qh, gid_s + k*block_stride_a + line_stride_a*3).x);
)"
R"(
)"
R"(        ql_lo.s0 = read_imageui(src0_ql, gid_s + k*block_stride_a + line_stride_a*4).x;
)"
R"(        ql_lo.s1 = read_imageui(src0_ql, gid_s + k*block_stride_a + line_stride_a*5).x;
)"
R"(        ql_lo.s2 = read_imageui(src0_ql, gid_s + k*block_stride_a + line_stride_a*6).x;
)"
R"(        ql_lo.s3 = read_imageui(src0_ql, gid_s + k*block_stride_a + line_stride_a*7).x;
)"
R"(        qh_lo.s0 = as_ushort(read_imageh(src0_qh, gid_s + k*block_stride_a + line_stride_a*4).x);
)"
R"(        qh_lo.s1 = as_ushort(read_imageh(src0_qh, gid_s + k*block_stride_a + line_stride_a*5).x);
)"
R"(        qh_lo.s2 = as_ushort(read_imageh(src0_qh, gid_s + k*block_stride_a + line_stride_a*6).x);
)"
R"(        qh_lo.s3 = as_ushort(read_imageh(src0_qh, gid_s + k*block_stride_a + line_stride_a*7).x);
)"
R"(
)"
R"(        // Per-column: load only this column's activation (single reg_b live) ->
)"
R"(        // 1/3 the activation register pressure, cutting the private-mem spill.
)"
R"(#ifdef VECTOR_SUB_GROUP_BROADCAT
)"
R"(        { if (slid < 4) { reg_b.s0123 = read_imagef(src1, 0*COL_STRIDE + 0 + slid*2 + k*8);
)"
R"(                          reg_b.s4567 = read_imagef(src1, 0*COL_STRIDE + 1 + slid*2 + k*8); }
)"
R"(          dequantize_block_acc_bcast_8_hi(ts0, as_ushort8(ql_hi), as_uchar8(qh_hi), reg_d, reg_s, reg_b);
)"
R"(          dequantize_block_acc_bcast_8_lo(ts0, as_ushort8(ql_lo), as_uchar8(qh_lo), reg_d, reg_s, reg_b); }
)"
R"(        { if (slid < 4) { reg_b.s0123 = read_imagef(src1, 1*COL_STRIDE + 0 + slid*2 + k*8);
)"
R"(                          reg_b.s4567 = read_imagef(src1, 1*COL_STRIDE + 1 + slid*2 + k*8); }
)"
R"(          dequantize_block_acc_bcast_8_hi(ts1, as_ushort8(ql_hi), as_uchar8(qh_hi), reg_d, reg_s, reg_b);
)"
R"(          dequantize_block_acc_bcast_8_lo(ts1, as_ushort8(ql_lo), as_uchar8(qh_lo), reg_d, reg_s, reg_b); }
)"
R"(        { if (slid < 4) { reg_b.s0123 = read_imagef(src1, 2*COL_STRIDE + 0 + slid*2 + k*8);
)"
R"(                          reg_b.s4567 = read_imagef(src1, 2*COL_STRIDE + 1 + slid*2 + k*8); }
)"
R"(          dequantize_block_acc_bcast_8_hi(ts2, as_ushort8(ql_hi), as_uchar8(qh_hi), reg_d, reg_s, reg_b);
)"
R"(          dequantize_block_acc_bcast_8_lo(ts2, as_ushort8(ql_lo), as_uchar8(qh_lo), reg_d, reg_s, reg_b); }
)"
R"(#else
)"
R"(        { if (slid < 4) { reg_b.s0123 = read_imagef(src1, 0*COL_STRIDE + 0 + slid*2 + k*8);
)"
R"(                          reg_b.s4567 = read_imagef(src1, 0*COL_STRIDE + 1 + slid*2 + k*8); }
)"
R"(          dequantize_block_acc_bcast_1_hi(ts0, as_ushort8(ql_hi), as_uchar8(qh_hi), reg_d, reg_s, reg_b);
)"
R"(          dequantize_block_acc_bcast_1_lo(ts0, as_ushort8(ql_lo), as_uchar8(qh_lo), reg_d, reg_s, reg_b); }
)"
R"(        { if (slid < 4) { reg_b.s0123 = read_imagef(src1, 1*COL_STRIDE + 0 + slid*2 + k*8);
)"
R"(                          reg_b.s4567 = read_imagef(src1, 1*COL_STRIDE + 1 + slid*2 + k*8); }
)"
R"(          dequantize_block_acc_bcast_1_hi(ts1, as_ushort8(ql_hi), as_uchar8(qh_hi), reg_d, reg_s, reg_b);
)"
R"(          dequantize_block_acc_bcast_1_lo(ts1, as_ushort8(ql_lo), as_uchar8(qh_lo), reg_d, reg_s, reg_b); }
)"
R"(        { if (slid < 4) { reg_b.s0123 = read_imagef(src1, 2*COL_STRIDE + 0 + slid*2 + k*8);
)"
R"(                          reg_b.s4567 = read_imagef(src1, 2*COL_STRIDE + 1 + slid*2 + k*8); }
)"
R"(          dequantize_block_acc_bcast_1_hi(ts2, as_ushort8(ql_hi), as_uchar8(qh_hi), reg_d, reg_s, reg_b);
)"
R"(          dequantize_block_acc_bcast_1_lo(ts2, as_ushort8(ql_lo), as_uchar8(qh_lo), reg_d, reg_s, reg_b); }
)"
R"(#endif
)"
R"(    }
)"
R"(
)"
R"(    local float8 reduce_lm[SUBGROUP_SIZE * 3];
)"
R"(    float8 acc = (float8)(ts0.s0, ts0.s1, ts1.s0, ts1.s1, ts2.s0, ts2.s1, 0.0f, 0.0f);
)"
R"(    if (grp > 0) {
)"
R"(        reduce_lm[SUBGROUP_SIZE*(grp-1) + slid] = acc;
)"
R"(    }
)"
R"(
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(    if (grp == 0) {
)"
R"(        for (uint i = 0; i < nsg_rt - 1; ++i) {
)"
R"(            acc += reduce_lm[SUBGROUP_SIZE*i + slid];
)"
R"(        }
)"
R"(        dst = (global float*)((global char*)dst + offsetd);
)"
R"(        // dst column-major [ne01 rows x 3 cols]: (row, col) at col*ne01 + row
)"
R"(        if (gid < line_stride_a) {
)"
R"(            vstore2((float2)(acc.s0, acc.s1), 0, &(dst[0*ne01 + gid*2]));
)"
R"(            vstore2((float2)(acc.s2, acc.s3), 0, &(dst[1*ne01 + gid*2]));
)"
R"(            vstore2((float2)(acc.s4, acc.s5), 0, &(dst[2*ne01 + gid*2]));
)"
R"(        }
)"
R"(    }
)"
R"(}
)"
