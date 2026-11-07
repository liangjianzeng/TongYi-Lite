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
R"(#ifdef cl_qcom_reqd_sub_group_size
)"
R"(#pragma OPENCL EXTENSION cl_qcom_reqd_sub_group_size : enable
)"
R"(#define ADRENO_GPU 1
)"
R"(#define REQD_SUBGROUP_SIZE_64 __attribute__((qcom_reqd_sub_group_size("half")))
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
R"(#define QK5_0 32
)"
R"(#define NSUBGROUPS 4
)"
R"(#define SUBGROUP_SIZE 64
)"
R"(
)"
R"(#define dequantizeBlockAccum_ns_q5_0_sgbroadcast_1_hi(total_sums, bits4, bits1, scale, y) \
)"
R"(    float shared_y; \
)"
R"(    shared_y = SGB_BC(y.s0, 0); \
)"
R"(    total_sums.s0 += (((bits4.s0 & 0x000F) | (((bits1.s0      ) & 0x01) << 4)) - 16) * scale.s0 * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s1 & 0x000F) | (((bits1.s4      ) & 0x01) << 4)) - 16) * scale.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s1, 0); \
)"
R"(    total_sums.s0 += ((((bits4.s0 & 0x00F0) >> 4) | (((bits1.s0 >> 1) & 0x01) << 4)) - 16) * scale.s0 * shared_y; \
)"
R"(    total_sums.s1 += ((((bits4.s1 & 0x00F0) >> 4) | (((bits1.s4 >> 1) & 0x01) << 4)) - 16) * scale.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s2, 0); \
)"
R"(    total_sums.s0 += ((((bits4.s0 & 0x0F00) >> 8) | (((bits1.s0 >> 2) & 0x01) << 4)) - 16) * scale.s0 * shared_y; \
)"
R"(    total_sums.s1 += ((((bits4.s1 & 0x0F00) >> 8) | (((bits1.s4 >> 2) & 0x01) << 4)) - 16) * scale.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s3, 0); \
)"
R"(    total_sums.s0 += ((((bits4.s0 & 0xF000) >> 12) | (((bits1.s0 >> 3) & 0x01) << 4)) - 16) * scale.s0 * shared_y; \
)"
R"(    total_sums.s1 += ((((bits4.s1 & 0xF000) >> 12) | (((bits1.s4 >> 3) & 0x01) << 4)) - 16) * scale.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s4, 0); \
)"
R"(    total_sums.s0 += (((bits4.s2 & 0x000F) | (((bits1.s0 >> 4) & 0x01) << 4)) - 16) * scale.s0 * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s3 & 0x000F) | (((bits1.s4 >> 4) & 0x01) << 4)) - 16) * scale.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s5, 0); \
)"
R"(    total_sums.s0 += ((((bits4.s2 & 0x00F0) >> 4) | (((bits1.s0 >> 5) & 0x01) << 4)) - 16) * scale.s0 * shared_y; \
)"
R"(    total_sums.s1 += ((((bits4.s3 & 0x00F0) >> 4) | (((bits1.s4 >> 5) & 0x01) << 4)) - 16) * scale.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s6, 0); \
)"
R"(    total_sums.s0 += ((((bits4.s2 & 0x0F00) >> 8) | (((bits1.s0 >> 6) & 0x01) << 4)) - 16) * scale.s0 * shared_y; \
)"
R"(    total_sums.s1 += ((((bits4.s3 & 0x0F00) >> 8) | (((bits1.s4 >> 6) & 0x01) << 4)) - 16) * scale.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s7, 0); \
)"
R"(    total_sums.s0 += ((((bits4.s2 & 0xF000) >> 12) | (((bits1.s0 >> 7) & 0x01) << 4)) - 16) * scale.s0 * shared_y; \
)"
R"(    total_sums.s1 += ((((bits4.s3 & 0xF000) >> 12) | (((bits1.s4 >> 7) & 0x01) << 4)) - 16) * scale.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s0, 1); \
)"
R"(    total_sums.s0 += (((bits4.s4 & 0x000F) | (((bits1.s1      ) & 0x01) << 4)) - 16) * scale.s0 * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s5 & 0x000F) | (((bits1.s5      ) & 0x01) << 4)) - 16) * scale.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s1, 1); \
)"
R"(    total_sums.s0 += ((((bits4.s4 & 0x00F0) >> 4) | (((bits1.s1 >> 1) & 0x01) << 4)) - 16) * scale.s0 * shared_y; \
)"
R"(    total_sums.s1 += ((((bits4.s5 & 0x00F0) >> 4) | (((bits1.s5 >> 1) & 0x01) << 4)) - 16) * scale.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s2, 1); \
)"
R"(    total_sums.s0 += ((((bits4.s4 & 0x0F00) >> 8) | (((bits1.s1 >> 2) & 0x01) << 4)) - 16) * scale.s0 * shared_y; \
)"
R"(    total_sums.s1 += ((((bits4.s5 & 0x0F00) >> 8) | (((bits1.s5 >> 2) & 0x01) << 4)) - 16) * scale.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s3, 1); \
)"
R"(    total_sums.s0 += ((((bits4.s4 & 0xF000) >> 12) | (((bits1.s1 >> 3) & 0x01) << 4)) - 16) * scale.s0 * shared_y; \
)"
R"(    total_sums.s1 += ((((bits4.s5 & 0xF000) >> 12) | (((bits1.s5 >> 3) & 0x01) << 4)) - 16) * scale.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s4, 1); \
)"
R"(    total_sums.s0 += (((bits4.s6 & 0x000F) | (((bits1.s1 >> 4) & 0x01) << 4)) - 16) * scale.s0 * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s7 & 0x000F) | (((bits1.s5 >> 4) & 0x01) << 4)) - 16) * scale.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s5, 1); \
)"
R"(    total_sums.s0 += ((((bits4.s6 & 0x00F0) >> 4) | (((bits1.s1 >> 5) & 0x01) << 4)) - 16) * scale.s0 * shared_y; \
)"
R"(    total_sums.s1 += ((((bits4.s7 & 0x00F0) >> 4) | (((bits1.s5 >> 5) & 0x01) << 4)) - 16) * scale.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s6, 1); \
)"
R"(    total_sums.s0 += ((((bits4.s6 & 0x0F00) >> 8) | (((bits1.s1 >> 6) & 0x01) << 4)) - 16) * scale.s0 * shared_y; \
)"
R"(    total_sums.s1 += ((((bits4.s7 & 0x0F00) >> 8) | (((bits1.s5 >> 6) & 0x01) << 4)) - 16) * scale.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s7, 1); \
)"
R"(    total_sums.s0 += ((((bits4.s6 & 0xF000) >> 12) | (((bits1.s1 >> 7) & 0x01) << 4)) - 16) * scale.s0 * shared_y; \
)"
R"(    total_sums.s1 += ((((bits4.s7 & 0xF000) >> 12) | (((bits1.s5 >> 7) & 0x01) << 4)) - 16) * scale.s1 * shared_y; \
)"
R"(
)"
R"(
)"
R"(#define dequantizeBlockAccum_ns_q5_0_sgbroadcast_1_lo(total_sums, bits4, bits1, scale, y) \
)"
R"(    shared_y = SGB_BC(y.s0, 2); \
)"
R"(    total_sums.s0 += (((bits4.s0 & 0x000F) | (((bits1.s2      ) & 0x01) << 4)) - 16) * scale.s0 * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s1 & 0x000F) | (((bits1.s6      ) & 0x01) << 4)) - 16) * scale.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s1, 2); \
)"
R"(    total_sums.s0 += ((((bits4.s0 & 0x00F0) >> 4) | (((bits1.s2 >> 1) & 0x01) << 4)) - 16) * scale.s0 * shared_y; \
)"
R"(    total_sums.s1 += ((((bits4.s1 & 0x00F0) >> 4) | (((bits1.s6 >> 1) & 0x01) << 4)) - 16) * scale.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s2, 2); \
)"
R"(    total_sums.s0 += ((((bits4.s0 & 0x0F00) >> 8) | (((bits1.s2 >> 2) & 0x01) << 4)) - 16) * scale.s0 * shared_y; \
)"
R"(    total_sums.s1 += ((((bits4.s1 & 0x0F00) >> 8) | (((bits1.s6 >> 2) & 0x01) << 4)) - 16) * scale.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s3, 2); \
)"
R"(    total_sums.s0 += ((((bits4.s0 & 0xF000) >> 12) | (((bits1.s2 >> 3) & 0x01) << 4)) - 16) * scale.s0 * shared_y; \
)"
R"(    total_sums.s1 += ((((bits4.s1 & 0xF000) >> 12) | (((bits1.s6 >> 3) & 0x01) << 4)) - 16) * scale.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s4, 2); \
)"
R"(    total_sums.s0 += (((bits4.s2 & 0x000F) | (((bits1.s2 >> 4) & 0x01) << 4)) - 16) * scale.s0 * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s3 & 0x000F) | (((bits1.s6 >> 4) & 0x01) << 4)) - 16) * scale.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s5, 2); \
)"
R"(    total_sums.s0 += ((((bits4.s2 & 0x00F0) >> 4) | (((bits1.s2 >> 5) & 0x01) << 4)) - 16) * scale.s0 * shared_y; \
)"
R"(    total_sums.s1 += ((((bits4.s3 & 0x00F0) >> 4) | (((bits1.s6 >> 5) & 0x01) << 4)) - 16) * scale.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s6, 2); \
)"
R"(    total_sums.s0 += ((((bits4.s2 & 0x0F00) >> 8) | (((bits1.s2 >> 6) & 0x01) << 4)) - 16) * scale.s0 * shared_y; \
)"
R"(    total_sums.s1 += ((((bits4.s3 & 0x0F00) >> 8) | (((bits1.s6 >> 6) & 0x01) << 4)) - 16) * scale.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s7, 2); \
)"
R"(    total_sums.s0 += ((((bits4.s2 & 0xF000) >> 12) | (((bits1.s2 >> 7) & 0x01) << 4)) - 16) * scale.s0 * shared_y; \
)"
R"(    total_sums.s1 += ((((bits4.s3 & 0xF000) >> 12) | (((bits1.s6 >> 7) & 0x01) << 4)) - 16) * scale.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s0, 3); \
)"
R"(    total_sums.s0 += (((bits4.s4 & 0x000F) | (((bits1.s3      ) & 0x01) << 4)) - 16) * scale.s0 * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s5 & 0x000F) | (((bits1.s7      ) & 0x01) << 4)) - 16) * scale.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s1, 3); \
)"
R"(    total_sums.s0 += ((((bits4.s4 & 0x00F0) >> 4) | (((bits1.s3 >> 1) & 0x01) << 4)) - 16) * scale.s0 * shared_y; \
)"
R"(    total_sums.s1 += ((((bits4.s5 & 0x00F0) >> 4) | (((bits1.s7 >> 1) & 0x01) << 4)) - 16) * scale.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s2, 3); \
)"
R"(    total_sums.s0 += ((((bits4.s4 & 0x0F00) >> 8) | (((bits1.s3 >> 2) & 0x01) << 4)) - 16) * scale.s0 * shared_y; \
)"
R"(    total_sums.s1 += ((((bits4.s5 & 0x0F00) >> 8) | (((bits1.s7 >> 2) & 0x01) << 4)) - 16) * scale.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s3, 3); \
)"
R"(    total_sums.s0 += ((((bits4.s4 & 0xF000) >> 12) | (((bits1.s3 >> 3) & 0x01) << 4)) - 16) * scale.s0 * shared_y; \
)"
R"(    total_sums.s1 += ((((bits4.s5 & 0xF000) >> 12) | (((bits1.s7 >> 3) & 0x01) << 4)) - 16) * scale.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s4, 3); \
)"
R"(    total_sums.s0 += (((bits4.s6 & 0x000F) | (((bits1.s3 >> 4) & 0x01) << 4)) - 16) * scale.s0 * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s7 & 0x000F) | (((bits1.s7 >> 4) & 0x01) << 4)) - 16) * scale.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s5, 3); \
)"
R"(    total_sums.s0 += ((((bits4.s6 & 0x00F0) >> 4) | (((bits1.s3 >> 5) & 0x01) << 4)) - 16) * scale.s0 * shared_y; \
)"
R"(    total_sums.s1 += ((((bits4.s7 & 0x00F0) >> 4) | (((bits1.s7 >> 5) & 0x01) << 4)) - 16) * scale.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s6, 3); \
)"
R"(    total_sums.s0 += ((((bits4.s6 & 0x0F00) >> 8) | (((bits1.s3 >> 6) & 0x01) << 4)) - 16) * scale.s0 * shared_y; \
)"
R"(    total_sums.s1 += ((((bits4.s7 & 0x0F00) >> 8) | (((bits1.s7 >> 6) & 0x01) << 4)) - 16) * scale.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s7, 3); \
)"
R"(    total_sums.s0 += ((((bits4.s6 & 0xF000) >> 12) | (((bits1.s3 >> 7) & 0x01) << 4)) - 16) * scale.s0 * shared_y; \
)"
R"(    total_sums.s1 += ((((bits4.s7 & 0xF000) >> 12) | (((bits1.s7 >> 7) & 0x01) << 4)) - 16) * scale.s1 * shared_y; \
)"
R"(
)"
R"(
)"
R"(#define dequantizeBlockAccum_ns_q5_0_sgbroadcast_8_hi(total_sums, bits4, bits1, scale, y) \
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
R"(    total_sums.s0 += (((bits4.s0 & 0x000F)         | (((bits1.s0     ) & 0x01) << 4)) - 16) * scale.s0 * shared_y.s0; \
)"
R"(    total_sums.s0 += ((((bits4.s0 & 0x00F0) >> 4)  | (((bits1.s0 >> 1) & 0x01) << 4)) - 16) * scale.s0 * shared_y.s1; \
)"
R"(    total_sums.s0 += ((((bits4.s0 & 0x0F00) >> 8)  | (((bits1.s0 >> 2) & 0x01) << 4)) - 16) * scale.s0 * shared_y.s2; \
)"
R"(    total_sums.s0 += ((((bits4.s0 & 0xF000) >> 12) | (((bits1.s0 >> 3) & 0x01) << 4)) - 16) * scale.s0 * shared_y.s3; \
)"
R"(    total_sums.s0 += (((bits4.s2 & 0x000F)         | (((bits1.s0 >> 4) & 0x01) << 4)) - 16) * scale.s0 * shared_y.s4; \
)"
R"(    total_sums.s0 += ((((bits4.s2 & 0x00F0) >> 4)  | (((bits1.s0 >> 5) & 0x01) << 4)) - 16) * scale.s0 * shared_y.s5; \
)"
R"(    total_sums.s0 += ((((bits4.s2 & 0x0F00) >> 8)  | (((bits1.s0 >> 6) & 0x01) << 4)) - 16) * scale.s0 * shared_y.s6; \
)"
R"(    total_sums.s0 += ((((bits4.s2 & 0xF000) >> 12) | (((bits1.s0 >> 7) & 0x01) << 4)) - 16) * scale.s0 * shared_y.s7; \
)"
R"(    total_sums.s1 += (((bits4.s1 & 0x000F)         | (((bits1.s4     ) & 0x01) << 4)) - 16) * scale.s1 * shared_y.s0; \
)"
R"(    total_sums.s1 += ((((bits4.s1 & 0x00F0) >> 4)  | (((bits1.s4 >> 1) & 0x01) << 4)) - 16) * scale.s1 * shared_y.s1; \
)"
R"(    total_sums.s1 += ((((bits4.s1 & 0x0F00) >> 8)  | (((bits1.s4 >> 2) & 0x01) << 4)) - 16) * scale.s1 * shared_y.s2; \
)"
R"(    total_sums.s1 += ((((bits4.s1 & 0xF000) >> 12) | (((bits1.s4 >> 3) & 0x01) << 4)) - 16) * scale.s1 * shared_y.s3; \
)"
R"(    total_sums.s1 += (((bits4.s3 & 0x000F)         | (((bits1.s4 >> 4) & 0x01) << 4)) - 16) * scale.s1 * shared_y.s4; \
)"
R"(    total_sums.s1 += ((((bits4.s3 & 0x00F0) >> 4)  | (((bits1.s4 >> 5) & 0x01) << 4)) - 16) * scale.s1 * shared_y.s5; \
)"
R"(    total_sums.s1 += ((((bits4.s3 & 0x0F00) >> 8)  | (((bits1.s4 >> 6) & 0x01) << 4)) - 16) * scale.s1 * shared_y.s6; \
)"
R"(    total_sums.s1 += ((((bits4.s3 & 0xF000) >> 12) | (((bits1.s4 >> 7) & 0x01) << 4)) - 16) * scale.s1 * shared_y.s7; \
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
R"(    total_sums.s0 += (((bits4.s4 & 0x000F)         | (((bits1.s1     ) & 0x01) << 4)) - 16) * scale.s0 * shared_y.s0; \
)"
R"(    total_sums.s0 += ((((bits4.s4 & 0x00F0) >> 4)  | (((bits1.s1 >> 1) & 0x01) << 4)) - 16) * scale.s0 * shared_y.s1; \
)"
R"(    total_sums.s0 += ((((bits4.s4 & 0x0F00) >> 8)  | (((bits1.s1 >> 2) & 0x01) << 4)) - 16) * scale.s0 * shared_y.s2; \
)"
R"(    total_sums.s0 += ((((bits4.s4 & 0xF000) >> 12) | (((bits1.s1 >> 3) & 0x01) << 4)) - 16) * scale.s0 * shared_y.s3; \
)"
R"(    total_sums.s0 += (((bits4.s6 & 0x000F)         | (((bits1.s1 >> 4) & 0x01) << 4)) - 16) * scale.s0 * shared_y.s4; \
)"
R"(    total_sums.s0 += ((((bits4.s6 & 0x00F0) >> 4)  | (((bits1.s1 >> 5) & 0x01) << 4)) - 16) * scale.s0 * shared_y.s5; \
)"
R"(    total_sums.s0 += ((((bits4.s6 & 0x0F00) >> 8)  | (((bits1.s1 >> 6) & 0x01) << 4)) - 16) * scale.s0 * shared_y.s6; \
)"
R"(    total_sums.s0 += ((((bits4.s6 & 0xF000) >> 12) | (((bits1.s1 >> 7) & 0x01) << 4)) - 16) * scale.s0 * shared_y.s7; \
)"
R"(    total_sums.s1 += (((bits4.s5 & 0x000F)         | (((bits1.s5     ) & 0x01) << 4)) - 16) * scale.s1 * shared_y.s0; \
)"
R"(    total_sums.s1 += ((((bits4.s5 & 0x00F0) >> 4)  | (((bits1.s5 >> 1) & 0x01) << 4)) - 16) * scale.s1 * shared_y.s1; \
)"
R"(    total_sums.s1 += ((((bits4.s5 & 0x0F00) >> 8)  | (((bits1.s5 >> 2) & 0x01) << 4)) - 16) * scale.s1 * shared_y.s2; \
)"
R"(    total_sums.s1 += ((((bits4.s5 & 0xF000) >> 12) | (((bits1.s5 >> 3) & 0x01) << 4)) - 16) * scale.s1 * shared_y.s3; \
)"
R"(    total_sums.s1 += (((bits4.s7 & 0x000F)         | (((bits1.s5 >> 4) & 0x01) << 4)) - 16) * scale.s1 * shared_y.s4; \
)"
R"(    total_sums.s1 += ((((bits4.s7 & 0x00F0) >> 4)  | (((bits1.s5 >> 5) & 0x01) << 4)) - 16) * scale.s1 * shared_y.s5; \
)"
R"(    total_sums.s1 += ((((bits4.s7 & 0x0F00) >> 8)  | (((bits1.s5 >> 6) & 0x01) << 4)) - 16) * scale.s1 * shared_y.s6; \
)"
R"(    total_sums.s1 += ((((bits4.s7 & 0xF000) >> 12) | (((bits1.s5 >> 7) & 0x01) << 4)) - 16) * scale.s1 * shared_y.s7; \
)"
R"(
)"
R"(
)"
R"(#define dequantizeBlockAccum_ns_q5_0_sgbroadcast_8_lo(total_sums, bits4, bits1, scale, y) \
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
R"(    total_sums.s0 += (((bits4.s0 & 0x000F)         | (((bits1.s2     ) & 0x01) << 4)) - 16) * scale.s0 * shared_y.s0; \
)"
R"(    total_sums.s0 += ((((bits4.s0 & 0x00F0) >> 4)  | (((bits1.s2 >> 1) & 0x01) << 4)) - 16) * scale.s0 * shared_y.s1; \
)"
R"(    total_sums.s0 += ((((bits4.s0 & 0x0F00) >> 8)  | (((bits1.s2 >> 2) & 0x01) << 4)) - 16) * scale.s0 * shared_y.s2; \
)"
R"(    total_sums.s0 += ((((bits4.s0 & 0xF000) >> 12) | (((bits1.s2 >> 3) & 0x01) << 4)) - 16) * scale.s0 * shared_y.s3; \
)"
R"(    total_sums.s0 += (((bits4.s2 & 0x000F)         | (((bits1.s2 >> 4) & 0x01) << 4)) - 16) * scale.s0 * shared_y.s4; \
)"
R"(    total_sums.s0 += ((((bits4.s2 & 0x00F0) >> 4)  | (((bits1.s2 >> 5) & 0x01) << 4)) - 16) * scale.s0 * shared_y.s5; \
)"
R"(    total_sums.s0 += ((((bits4.s2 & 0x0F00) >> 8)  | (((bits1.s2 >> 6) & 0x01) << 4)) - 16) * scale.s0 * shared_y.s6; \
)"
R"(    total_sums.s0 += ((((bits4.s2 & 0xF000) >> 12) | (((bits1.s2 >> 7) & 0x01) << 4)) - 16) * scale.s0 * shared_y.s7; \
)"
R"(    total_sums.s1 += (((bits4.s1 & 0x000F)         | (((bits1.s6     ) & 0x01) << 4)) - 16) * scale.s1 * shared_y.s0; \
)"
R"(    total_sums.s1 += ((((bits4.s1 & 0x00F0) >> 4)  | (((bits1.s6 >> 1) & 0x01) << 4)) - 16) * scale.s1 * shared_y.s1; \
)"
R"(    total_sums.s1 += ((((bits4.s1 & 0x0F00) >> 8)  | (((bits1.s6 >> 2) & 0x01) << 4)) - 16) * scale.s1 * shared_y.s2; \
)"
R"(    total_sums.s1 += ((((bits4.s1 & 0xF000) >> 12) | (((bits1.s6 >> 3) & 0x01) << 4)) - 16) * scale.s1 * shared_y.s3; \
)"
R"(    total_sums.s1 += (((bits4.s3 & 0x000F)         | (((bits1.s6 >> 4) & 0x01) << 4)) - 16) * scale.s1 * shared_y.s4; \
)"
R"(    total_sums.s1 += ((((bits4.s3 & 0x00F0) >> 4)  | (((bits1.s6 >> 5) & 0x01) << 4)) - 16) * scale.s1 * shared_y.s5; \
)"
R"(    total_sums.s1 += ((((bits4.s3 & 0x0F00) >> 8)  | (((bits1.s6 >> 6) & 0x01) << 4)) - 16) * scale.s1 * shared_y.s6; \
)"
R"(    total_sums.s1 += ((((bits4.s3 & 0xF000) >> 12) | (((bits1.s6 >> 7) & 0x01) << 4)) - 16) * scale.s1 * shared_y.s7; \
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
R"(    total_sums.s0 += (((bits4.s4 & 0x000F)         | (((bits1.s3     ) & 0x01) << 4)) - 16) * scale.s0 * shared_y.s0; \
)"
R"(    total_sums.s0 += ((((bits4.s4 & 0x00F0) >> 4)  | (((bits1.s3 >> 1) & 0x01) << 4)) - 16) * scale.s0 * shared_y.s1; \
)"
R"(    total_sums.s0 += ((((bits4.s4 & 0x0F00) >> 8)  | (((bits1.s3 >> 2) & 0x01) << 4)) - 16) * scale.s0 * shared_y.s2; \
)"
R"(    total_sums.s0 += ((((bits4.s4 & 0xF000) >> 12) | (((bits1.s3 >> 3) & 0x01) << 4)) - 16) * scale.s0 * shared_y.s3; \
)"
R"(    total_sums.s0 += (((bits4.s6 & 0x000F)         | (((bits1.s3 >> 4) & 0x01) << 4)) - 16) * scale.s0 * shared_y.s4; \
)"
R"(    total_sums.s0 += ((((bits4.s6 & 0x00F0) >> 4)  | (((bits1.s3 >> 5) & 0x01) << 4)) - 16) * scale.s0 * shared_y.s5; \
)"
R"(    total_sums.s0 += ((((bits4.s6 & 0x0F00) >> 8)  | (((bits1.s3 >> 6) & 0x01) << 4)) - 16) * scale.s0 * shared_y.s6; \
)"
R"(    total_sums.s0 += ((((bits4.s6 & 0xF000) >> 12) | (((bits1.s3 >> 7) & 0x01) << 4)) - 16) * scale.s0 * shared_y.s7; \
)"
R"(    total_sums.s1 += (((bits4.s5 & 0x000F)         | (((bits1.s7     ) & 0x01) << 4)) - 16) * scale.s1 * shared_y.s0; \
)"
R"(    total_sums.s1 += ((((bits4.s5 & 0x00F0) >> 4)  | (((bits1.s7 >> 1) & 0x01) << 4)) - 16) * scale.s1 * shared_y.s1; \
)"
R"(    total_sums.s1 += ((((bits4.s5 & 0x0F00) >> 8)  | (((bits1.s7 >> 2) & 0x01) << 4)) - 16) * scale.s1 * shared_y.s2; \
)"
R"(    total_sums.s1 += ((((bits4.s5 & 0xF000) >> 12) | (((bits1.s7 >> 3) & 0x01) << 4)) - 16) * scale.s1 * shared_y.s3; \
)"
R"(    total_sums.s1 += (((bits4.s7 & 0x000F)         | (((bits1.s7 >> 4) & 0x01) << 4)) - 16) * scale.s1 * shared_y.s4; \
)"
R"(    total_sums.s1 += ((((bits4.s7 & 0x00F0) >> 4)  | (((bits1.s7 >> 5) & 0x01) << 4)) - 16) * scale.s1 * shared_y.s5; \
)"
R"(    total_sums.s1 += ((((bits4.s7 & 0x0F00) >> 8)  | (((bits1.s7 >> 6) & 0x01) << 4)) - 16) * scale.s1 * shared_y.s6; \
)"
R"(    total_sums.s1 += ((((bits4.s7 & 0xF000) >> 12) | (((bits1.s7 >> 7) & 0x01) << 4)) - 16) * scale.s1 * shared_y.s7; \
)"
R"(
)"
R"(#ifdef ADRENO_GPU
)"
R"(REQD_SUBGROUP_SIZE_64
)"
R"(#endif
)"
R"(__kernel void kernel_gemv_noshuffle_q5_0_f32(
)"
R"(        __read_only  image1d_buffer_t src0_qs,  // quantized A
)"
R"(        global ushort * src0_qh,                 // 5th bits
)"
R"(        global half2  * src0_d,                  // A scales
)"
R"(        __read_only  image1d_buffer_t src1,      // B activations
)"
R"(        global float * dst,
)"
R"(        ulong offsetd,
)"
R"(        int ne00,               // K
)"
R"(        int ne01)               // M
)"
R"({
)"
R"(    uint groupId = get_local_id(1);
)"
R"(    uint gid     = get_global_id(0);
)"
R"(    ushort slid  = get_sub_group_local_id();
)"
R"(
)"
R"(    uint K = ne00;
)"
R"(    uint M = ne01;
)"
R"(
)"
R"(    uint LINE_STRIDE_A    = M / 2;
)"
R"(    // Keep tail lanes active for subgroup ops, but read a valid weight row.
)"
R"(    uint gid_s = min(gid, LINE_STRIDE_A - 1);
)"
R"(    uint BLOCK_STRIDE_A  = NSUBGROUPS * M;
)"
R"(
)"
R"(    private uint4     regA;
)"
R"(    private half2     regS;
)"
R"(    private float8    regB;
)"
R"(
)"
R"(    private float2 totalSum = (float2)(0.0f);
)"
R"(
)"
R"(    // [dspark 2026-10-17] runtime K-split stride (host clamps y-split to 1 on rusticl)
)"
R"(    uint nsg_rt = get_local_size(1);
)"
R"(    for (uint k = groupId; k < (K / QK5_0); k += nsg_rt) {
)"
R"(        regS = src0_d[gid_s + k * LINE_STRIDE_A];
)"
R"(
)"
R"(        ushort4 qh_raw;
)"
R"(        qh_raw.s0 = src0_qh[gid_s + (4*k + 0) * LINE_STRIDE_A];
)"
R"(        qh_raw.s1 = src0_qh[gid_s + (4*k + 1) * LINE_STRIDE_A];
)"
R"(        qh_raw.s2 = src0_qh[gid_s + (4*k + 2) * LINE_STRIDE_A];
)"
R"(        qh_raw.s3 = src0_qh[gid_s + (4*k + 3) * LINE_STRIDE_A];
)"
R"(
)"
R"(        uchar8 raw = as_uchar8(qh_raw);
)"
R"(        uchar8 qh_bytes = (uchar8)(raw.s0, raw.s2, raw.s4, raw.s6,
)"
R"(                                    raw.s1, raw.s3, raw.s5, raw.s7);
)"
R"(
)"
R"(        // Load activations
)"
R"(        if (slid < 4) {
)"
R"(            regB.s0123 = read_imagef(src1, (slid * 2 + k * 8));
)"
R"(            regB.s4567 = read_imagef(src1, (1 + slid * 2 + k * 8));
)"
R"(        }
)"
R"(
)"
R"(        regA.s0 = read_imageui(src0_qs, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 0)).x;
)"
R"(        regA.s1 = read_imageui(src0_qs, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 1)).x;
)"
R"(        regA.s2 = read_imageui(src0_qs, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 2)).x;
)"
R"(        regA.s3 = read_imageui(src0_qs, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 3)).x;
)"
R"(
)"
R"(#ifdef VECTOR_SUB_GROUP_BROADCAST
)"
R"(        dequantizeBlockAccum_ns_q5_0_sgbroadcast_8_hi(totalSum, as_ushort8(regA), qh_bytes, regS, regB);
)"
R"(#else
)"
R"(        dequantizeBlockAccum_ns_q5_0_sgbroadcast_1_hi(totalSum, as_ushort8(regA), qh_bytes, regS, regB);
)"
R"(#endif // VECTOR_SUB_GROUP_BROADCAST
)"
R"(
)"
R"(        regA.s0 = read_imageui(src0_qs, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 4)).x;
)"
R"(        regA.s1 = read_imageui(src0_qs, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 5)).x;
)"
R"(        regA.s2 = read_imageui(src0_qs, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 6)).x;
)"
R"(        regA.s3 = read_imageui(src0_qs, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 7)).x;
)"
R"(#ifdef VECTOR_SUB_GROUP_BROADCAST
)"
R"(        dequantizeBlockAccum_ns_q5_0_sgbroadcast_8_lo(totalSum, as_ushort8(regA), qh_bytes, regS, regB);
)"
R"(#else
)"
R"(        dequantizeBlockAccum_ns_q5_0_sgbroadcast_1_lo(totalSum, as_ushort8(regA), qh_bytes, regS, regB);
)"
R"(#endif // VECTOR_SUB_GROUP_BROADCAST
)"
R"(    }
)"
R"(
)"
R"(    // reduction in local memory, assumes #wave=4
)"
R"(    local float2 reduceLM[SUBGROUP_SIZE * 3];
)"
R"(    if (groupId > 0) {
)"
R"(        reduceLM[SUBGROUP_SIZE * (groupId-1) + slid] = totalSum;
)"
R"(    }
)"
R"(
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(    if (groupId == 0) {
)"
R"(        for (uint i = 0; i < nsg_rt - 1; ++i) {
)"
R"(            totalSum += reduceLM[SUBGROUP_SIZE * i + slid];
)"
R"(        }
)"
R"(    }
)"
R"(
)"
R"(    // 2 outputs per fiber in wave 0
)"
R"(    if (groupId == 0) {
)"
R"(        dst = (global float*)((global char*)dst + offsetd);
)"
R"(        // Guard the two output rows. The x-grid is padded to CEIL_DIV(ne01/2,64)*64,
)"
R"(        // so when ne01 is not a multiple of 128 the tail row-pairs run past row ne01
)"
R"(        // and would overrun dst into the adjacent tensor. No-op / byte-identical when
)"
R"(        // ne01 % 128 == 0 (M/2 already a multiple of 64 -> no padding).
)"
R"(        if (gid * 2 + 0 < M) dst[gid * 2 + 0] = totalSum.s0;
)"
R"(        if (gid * 2 + 1 < M) dst[gid * 2 + 1] = totalSum.s1;
)"
R"(    }
)"
R"(
)"
R"(}
)"
