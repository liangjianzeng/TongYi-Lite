R"(#pragma OPENCL EXTENSION cl_khr_fp16 : enable
)"
R"(#pragma OPENCL EXTENSION cl_khr_subgroups : enable
)"
R"(
)"
R"(// [dspark 2026-10-14] SGB bitcast shims. Host passes -DSGB_FLOAT_BROKEN when
)"
R"(// the driver's online compiler lacks float overloads of sub_group_broadcast
)"
R"(// (Adreno 740: only scalar uint/int/long/ulong exist). Bitcast float<->uint,
)"
R"(// broadcast as integer, cast back — bitwise identical, subgroup-uniform.
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
R"(#define QK4_0 32
)"
R"(#define NSUBGROUPS 4
)"
R"(#define SUBGROUP_SIZE 64
)"
R"(
)"
R"(#define dequantizeBlockAccum_ns_sgbroadcast_1_hi(total_sums, bits4, scale, minv, y) \
)"
R"(    float shared_y; \
)"
R"(    shared_y = SGB_BC(y.s0, 0); \
)"
R"(    total_sums.s0 += ((bits4.s0 & 0x000F) * scale.s0 + minv.s0) * shared_y; \
)"
R"(    total_sums.s1 += ((bits4.s1 & 0x000F) * scale.s1 + minv.s1) * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s1, 0); \
)"
R"(    total_sums.s0 += (((bits4.s0 & 0x00F0) >> 4) * scale.s0 + minv.s0) * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s1 & 0x00F0) >> 4) * scale.s1 + minv.s1) * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s2, 0); \
)"
R"(    total_sums.s0 += (((bits4.s0 & 0x0F00) >> 8) * scale.s0 + minv.s0) * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s1 & 0x0F00) >> 8) * scale.s1 + minv.s1) * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s3, 0); \
)"
R"(    total_sums.s0 += (((bits4.s0 & 0xF000) >> 12) * scale.s0 + minv.s0) * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s1 & 0xF000) >> 12) * scale.s1 + minv.s1) * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s4, 0); \
)"
R"(    total_sums.s0 += ((bits4.s2 & 0x000F) * scale.s0 + minv.s0) * shared_y; \
)"
R"(    total_sums.s1 += ((bits4.s3 & 0x000F) * scale.s1 + minv.s1) * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s5, 0); \
)"
R"(    total_sums.s0 += (((bits4.s2 & 0x00F0) >> 4) * scale.s0 + minv.s0) * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s3 & 0x00F0) >> 4) * scale.s1 + minv.s1) * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s6, 0); \
)"
R"(    total_sums.s0 += (((bits4.s2 & 0x0F00) >> 8) * scale.s0 + minv.s0) * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s3 & 0x0F00) >> 8) * scale.s1 + minv.s1) * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s7, 0); \
)"
R"(    total_sums.s0 += (((bits4.s2 & 0xF000) >> 12) * scale.s0 + minv.s0) * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s3 & 0xF000) >> 12) * scale.s1 + minv.s1) * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s0, 1); \
)"
R"(    total_sums.s0 += ((bits4.s4 & 0x000F) * scale.s0 + minv.s0) * shared_y; \
)"
R"(    total_sums.s1 += ((bits4.s5 & 0x000F) * scale.s1 + minv.s1) * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s1, 1); \
)"
R"(    total_sums.s0 += (((bits4.s4 & 0x00F0) >> 4) * scale.s0 + minv.s0) * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s5 & 0x00F0) >> 4) * scale.s1 + minv.s1) * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s2, 1); \
)"
R"(    total_sums.s0 += (((bits4.s4 & 0x0F00) >> 8) * scale.s0 + minv.s0) * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s5 & 0x0F00) >> 8) * scale.s1 + minv.s1) * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s3, 1); \
)"
R"(    total_sums.s0 += (((bits4.s4 & 0xF000) >> 12) * scale.s0 + minv.s0) * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s5 & 0xF000) >> 12) * scale.s1 + minv.s1) * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s4, 1); \
)"
R"(    total_sums.s0 += ((bits4.s6 & 0x000F) * scale.s0 + minv.s0) * shared_y; \
)"
R"(    total_sums.s1 += ((bits4.s7 & 0x000F) * scale.s1 + minv.s1) * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s5, 1); \
)"
R"(    total_sums.s0 += (((bits4.s6 & 0x00F0) >> 4) * scale.s0 + minv.s0) * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s7 & 0x00F0) >> 4) * scale.s1 + minv.s1) * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s6, 1); \
)"
R"(    total_sums.s0 += (((bits4.s6 & 0x0F00) >> 8) * scale.s0 + minv.s0) * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s7 & 0x0F00) >> 8) * scale.s1 + minv.s1) * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s7, 1); \
)"
R"(    total_sums.s0 += (((bits4.s6 & 0xF000) >> 12) * scale.s0 + minv.s0) * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s7 & 0xF000) >> 12) * scale.s1 + minv.s1) * shared_y; \
)"
R"(
)"
R"(
)"
R"(#define dequantizeBlockAccum_ns_sgbroadcast_1_lo(total_sums, bits4, scale, minv, y) \
)"
R"(    shared_y = SGB_BC(y.s0, 2); \
)"
R"(    total_sums.s0 += ((bits4.s0 & 0x000F) * scale.s0 + minv.s0) * shared_y; \
)"
R"(    total_sums.s1 += ((bits4.s1 & 0x000F) * scale.s1 + minv.s1) * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s1, 2); \
)"
R"(    total_sums.s0 += (((bits4.s0 & 0x00F0) >> 4) * scale.s0 + minv.s0) * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s1 & 0x00F0) >> 4) * scale.s1 + minv.s1) * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s2, 2); \
)"
R"(    total_sums.s0 += (((bits4.s0 & 0x0F00) >> 8) * scale.s0 + minv.s0) * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s1 & 0x0F00) >> 8) * scale.s1 + minv.s1) * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s3, 2); \
)"
R"(    total_sums.s0 += (((bits4.s0 & 0xF000) >> 12) * scale.s0 + minv.s0) * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s1 & 0xF000) >> 12) * scale.s1 + minv.s1) * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s4, 2); \
)"
R"(    total_sums.s0 += ((bits4.s2 & 0x000F) * scale.s0 + minv.s0) * shared_y; \
)"
R"(    total_sums.s1 += ((bits4.s3 & 0x000F) * scale.s1 + minv.s1) * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s5, 2); \
)"
R"(    total_sums.s0 += (((bits4.s2 & 0x00F0) >> 4) * scale.s0 + minv.s0) * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s3 & 0x00F0) >> 4) * scale.s1 + minv.s1) * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s6, 2); \
)"
R"(    total_sums.s0 += (((bits4.s2 & 0x0F00) >> 8) * scale.s0 + minv.s0) * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s3 & 0x0F00) >> 8) * scale.s1 + minv.s1) * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s7, 2); \
)"
R"(    total_sums.s0 += (((bits4.s2 & 0xF000) >> 12) * scale.s0 + minv.s0) * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s3 & 0xF000) >> 12) * scale.s1 + minv.s1) * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s0, 3); \
)"
R"(    total_sums.s0 += ((bits4.s4 & 0x000F) * scale.s0 + minv.s0) * shared_y; \
)"
R"(    total_sums.s1 += ((bits4.s5 & 0x000F) * scale.s1 + minv.s1) * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s1, 3); \
)"
R"(    total_sums.s0 += (((bits4.s4 & 0x00F0) >> 4) * scale.s0 + minv.s0) * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s5 & 0x00F0) >> 4) * scale.s1 + minv.s1) * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s2, 3); \
)"
R"(    total_sums.s0 += (((bits4.s4 & 0x0F00) >> 8) * scale.s0 + minv.s0) * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s5 & 0x0F00) >> 8) * scale.s1 + minv.s1) * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s3, 3); \
)"
R"(    total_sums.s0 += (((bits4.s4 & 0xF000) >> 12) * scale.s0 + minv.s0) * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s5 & 0xF000) >> 12) * scale.s1 + minv.s1) * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s4, 3); \
)"
R"(    total_sums.s0 += ((bits4.s6 & 0x000F) * scale.s0 + minv.s0) * shared_y; \
)"
R"(    total_sums.s1 += ((bits4.s7 & 0x000F) * scale.s1 + minv.s1) * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s5, 3); \
)"
R"(    total_sums.s0 += (((bits4.s6 & 0x00F0) >> 4) * scale.s0 + minv.s0) * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s7 & 0x00F0) >> 4) * scale.s1 + minv.s1) * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s6, 3); \
)"
R"(    total_sums.s0 += (((bits4.s6 & 0x0F00) >> 8) * scale.s0 + minv.s0) * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s7 & 0x0F00) >> 8) * scale.s1 + minv.s1) * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s7, 3); \
)"
R"(    total_sums.s0 += (((bits4.s6 & 0xF000) >> 12) * scale.s0 + minv.s0) * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s7 & 0xF000) >> 12) * scale.s1 + minv.s1) * shared_y; \
)"
R"(
)"
R"(
)"
R"(#define dequantizeBlockAccum_ns_sgbroadcast_8_hi(total_sums, bits4, scale, minv, y) \
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
R"(    total_sums.s0 += ((bits4.s0 & 0x000F)         * scale.s0 + minv.s0) * shared_y.s0; \
)"
R"(    total_sums.s0 += (((bits4.s0 & 0x00F0) >> 4)  * scale.s0 + minv.s0) * shared_y.s1; \
)"
R"(    total_sums.s0 += (((bits4.s0 & 0x0F00) >> 8)  * scale.s0 + minv.s0) * shared_y.s2; \
)"
R"(    total_sums.s0 += (((bits4.s0 & 0xF000) >> 12) * scale.s0 + minv.s0) * shared_y.s3; \
)"
R"(    total_sums.s0 += ((bits4.s2 & 0x000F)         * scale.s0 + minv.s0) * shared_y.s4; \
)"
R"(    total_sums.s0 += (((bits4.s2 & 0x00F0) >> 4)  * scale.s0 + minv.s0) * shared_y.s5; \
)"
R"(    total_sums.s0 += (((bits4.s2 & 0x0F00) >> 8)  * scale.s0 + minv.s0) * shared_y.s6; \
)"
R"(    total_sums.s0 += (((bits4.s2 & 0xF000) >> 12) * scale.s0 + minv.s0) * shared_y.s7; \
)"
R"(    total_sums.s1 += ((bits4.s1 & 0x000F)         * scale.s1 + minv.s1) * shared_y.s0; \
)"
R"(    total_sums.s1 += (((bits4.s1 & 0x00F0) >> 4)  * scale.s1 + minv.s1) * shared_y.s1; \
)"
R"(    total_sums.s1 += (((bits4.s1 & 0x0F00) >> 8)  * scale.s1 + minv.s1) * shared_y.s2; \
)"
R"(    total_sums.s1 += (((bits4.s1 & 0xF000) >> 12) * scale.s1 + minv.s1) * shared_y.s3; \
)"
R"(    total_sums.s1 += ((bits4.s3 & 0x000F)         * scale.s1 + minv.s1) * shared_y.s4; \
)"
R"(    total_sums.s1 += (((bits4.s3 & 0x00F0) >> 4)  * scale.s1 + minv.s1) * shared_y.s5; \
)"
R"(    total_sums.s1 += (((bits4.s3 & 0x0F00) >> 8)  * scale.s1 + minv.s1) * shared_y.s6; \
)"
R"(    total_sums.s1 += (((bits4.s3 & 0xF000) >> 12) * scale.s1 + minv.s1) * shared_y.s7; \
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
R"(    total_sums.s0 += ((bits4.s4 & 0x000F)         * scale.s0 + minv.s0) * shared_y.s0; \
)"
R"(    total_sums.s0 += (((bits4.s4 & 0x00F0) >> 4)  * scale.s0 + minv.s0) * shared_y.s1; \
)"
R"(    total_sums.s0 += (((bits4.s4 & 0x0F00) >> 8)  * scale.s0 + minv.s0) * shared_y.s2; \
)"
R"(    total_sums.s0 += (((bits4.s4 & 0xF000) >> 12) * scale.s0 + minv.s0) * shared_y.s3; \
)"
R"(    total_sums.s0 += ((bits4.s6 & 0x000F)         * scale.s0 + minv.s0) * shared_y.s4; \
)"
R"(    total_sums.s0 += (((bits4.s6 & 0x00F0) >> 4)  * scale.s0 + minv.s0) * shared_y.s5; \
)"
R"(    total_sums.s0 += (((bits4.s6 & 0x0F00) >> 8)  * scale.s0 + minv.s0) * shared_y.s6; \
)"
R"(    total_sums.s0 += (((bits4.s6 & 0xF000) >> 12) * scale.s0 + minv.s0) * shared_y.s7; \
)"
R"(    total_sums.s1 += ((bits4.s5 & 0x000F)         * scale.s1 + minv.s1) * shared_y.s0; \
)"
R"(    total_sums.s1 += (((bits4.s5 & 0x00F0) >> 4)  * scale.s1 + minv.s1) * shared_y.s1; \
)"
R"(    total_sums.s1 += (((bits4.s5 & 0x0F00) >> 8)  * scale.s1 + minv.s1) * shared_y.s2; \
)"
R"(    total_sums.s1 += (((bits4.s5 & 0xF000) >> 12) * scale.s1 + minv.s1) * shared_y.s3; \
)"
R"(    total_sums.s1 += ((bits4.s7 & 0x000F)         * scale.s1 + minv.s1) * shared_y.s4; \
)"
R"(    total_sums.s1 += (((bits4.s7 & 0x00F0) >> 4)  * scale.s1 + minv.s1) * shared_y.s5; \
)"
R"(    total_sums.s1 += (((bits4.s7 & 0x0F00) >> 8)  * scale.s1 + minv.s1) * shared_y.s6; \
)"
R"(    total_sums.s1 += (((bits4.s7 & 0xF000) >> 12) * scale.s1 + minv.s1) * shared_y.s7; \
)"
R"(
)"
R"(
)"
R"(#define dequantizeBlockAccum_ns_sgbroadcast_8_lo(total_sums, bits4, scale, minv, y) \
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
R"(    total_sums.s0 += ((bits4.s0 & 0x000F)         * scale.s0 + minv.s0) * shared_y.s0; \
)"
R"(    total_sums.s0 += (((bits4.s0 & 0x00F0) >> 4)  * scale.s0 + minv.s0) * shared_y.s1; \
)"
R"(    total_sums.s0 += (((bits4.s0 & 0x0F00) >> 8)  * scale.s0 + minv.s0) * shared_y.s2; \
)"
R"(    total_sums.s0 += (((bits4.s0 & 0xF000) >> 12) * scale.s0 + minv.s0) * shared_y.s3; \
)"
R"(    total_sums.s0 += ((bits4.s2 & 0x000F)         * scale.s0 + minv.s0) * shared_y.s4; \
)"
R"(    total_sums.s0 += (((bits4.s2 & 0x00F0) >> 4)  * scale.s0 + minv.s0) * shared_y.s5; \
)"
R"(    total_sums.s0 += (((bits4.s2 & 0x0F00) >> 8)  * scale.s0 + minv.s0) * shared_y.s6; \
)"
R"(    total_sums.s0 += (((bits4.s2 & 0xF000) >> 12) * scale.s0 + minv.s0) * shared_y.s7; \
)"
R"(    total_sums.s1 += ((bits4.s1 & 0x000F)         * scale.s1 + minv.s1) * shared_y.s0; \
)"
R"(    total_sums.s1 += (((bits4.s1 & 0x00F0) >> 4)  * scale.s1 + minv.s1) * shared_y.s1; \
)"
R"(    total_sums.s1 += (((bits4.s1 & 0x0F00) >> 8)  * scale.s1 + minv.s1) * shared_y.s2; \
)"
R"(    total_sums.s1 += (((bits4.s1 & 0xF000) >> 12) * scale.s1 + minv.s1) * shared_y.s3; \
)"
R"(    total_sums.s1 += ((bits4.s3 & 0x000F)         * scale.s1 + minv.s1) * shared_y.s4; \
)"
R"(    total_sums.s1 += (((bits4.s3 & 0x00F0) >> 4)  * scale.s1 + minv.s1) * shared_y.s5; \
)"
R"(    total_sums.s1 += (((bits4.s3 & 0x0F00) >> 8)  * scale.s1 + minv.s1) * shared_y.s6; \
)"
R"(    total_sums.s1 += (((bits4.s3 & 0xF000) >> 12) * scale.s1 + minv.s1) * shared_y.s7; \
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
R"(    total_sums.s0 += ((bits4.s4 & 0x000F)         * scale.s0 + minv.s0) * shared_y.s0; \
)"
R"(    total_sums.s0 += (((bits4.s4 & 0x00F0) >> 4)  * scale.s0 + minv.s0) * shared_y.s1; \
)"
R"(    total_sums.s0 += (((bits4.s4 & 0x0F00) >> 8)  * scale.s0 + minv.s0) * shared_y.s2; \
)"
R"(    total_sums.s0 += (((bits4.s4 & 0xF000) >> 12) * scale.s0 + minv.s0) * shared_y.s3; \
)"
R"(    total_sums.s0 += ((bits4.s6 & 0x000F)         * scale.s0 + minv.s0) * shared_y.s4; \
)"
R"(    total_sums.s0 += (((bits4.s6 & 0x00F0) >> 4)  * scale.s0 + minv.s0) * shared_y.s5; \
)"
R"(    total_sums.s0 += (((bits4.s6 & 0x0F00) >> 8)  * scale.s0 + minv.s0) * shared_y.s6; \
)"
R"(    total_sums.s0 += (((bits4.s6 & 0xF000) >> 12) * scale.s0 + minv.s0) * shared_y.s7; \
)"
R"(    total_sums.s1 += ((bits4.s5 & 0x000F)         * scale.s1 + minv.s1) * shared_y.s0; \
)"
R"(    total_sums.s1 += (((bits4.s5 & 0x00F0) >> 4)  * scale.s1 + minv.s1) * shared_y.s1; \
)"
R"(    total_sums.s1 += (((bits4.s5 & 0x0F00) >> 8)  * scale.s1 + minv.s1) * shared_y.s2; \
)"
R"(    total_sums.s1 += (((bits4.s5 & 0xF000) >> 12) * scale.s1 + minv.s1) * shared_y.s3; \
)"
R"(    total_sums.s1 += ((bits4.s7 & 0x000F)         * scale.s1 + minv.s1) * shared_y.s4; \
)"
R"(    total_sums.s1 += (((bits4.s7 & 0x00F0) >> 4)  * scale.s1 + minv.s1) * shared_y.s5; \
)"
R"(    total_sums.s1 += (((bits4.s7 & 0x0F00) >> 8)  * scale.s1 + minv.s1) * shared_y.s6; \
)"
R"(    total_sums.s1 += (((bits4.s7 & 0xF000) >> 12) * scale.s1 + minv.s1) * shared_y.s7; \
)"
R"(
)"
R"(#ifdef ADRENO_GPU
)"
R"(REQD_SUBGROUP_SIZE_64
)"
R"(#endif
)"
R"(kernel void kernel_gemv_noshuffle_q4_1_f32(
)"
R"(        read_only  image1d_buffer_t src0_q,
)"
R"(        global half2  * src0_d,
)"
R"(        global half2  * src0_m,
)"
R"(        read_only  image1d_buffer_t src1,
)"
R"(        global float * dst,
)"
R"(        ulong offsetd,
)"
R"(        int ne00,
)"
R"(        int ne01)
)"
R"({
)"
R"(    uint groupId = get_local_id(1);
)"
R"(    uint gid     = get_global_id(0);
)"
R"(    ushort slid    = get_sub_group_local_id();
)"
R"(
)"
R"(    uint K = ne00;
)"
R"(    uint M = ne01;
)"
R"(
)"
R"(    uint LINE_STRIDE_A = M / 2;
)"
R"(    // Keep tail lanes active for subgroup ops, but read a valid weight row.
)"
R"(    uint gid_s = min(gid, LINE_STRIDE_A - 1);
)"
R"(    uint BLOCK_STRIDE_A = NSUBGROUPS * M;
)"
R"(
)"
R"(    private uint4     regA;
)"
R"(    private half2     regS;
)"
R"(    private half2     regM;
)"
R"(    private float8    regB;
)"
R"(
)"
R"(    private float2 totalSum = (float2)(0.0f);
)"
R"(
)"
R"(    // loop along K in block granularity, skip 4 blocks every iter
)"
R"(    // [dspark 2026-10-17] runtime K-split stride (host clamps y-split to 1 on rusticl)
)"
R"(    uint nsg_rt = get_local_size(1);
)"
R"(    for (uint k = groupId; k < (K / QK4_0); k += nsg_rt) {
)"
R"(        regS = src0_d[gid_s + k * LINE_STRIDE_A]; // each fiber loads scale of two rows
)"
R"(        regM = src0_m[gid_s + k * LINE_STRIDE_A]; // each fiber loads min of two rows
)"
R"(        // first 4 fibers in each wave load 8 B values to its private scope
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
R"(        // load half weights for two blocks in consecutive rows
)"
R"(        regA.s0 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 0)).x;
)"
R"(        regA.s1 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 1)).x;
)"
R"(        regA.s2 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 2)).x;
)"
R"(        regA.s3 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 3)).x;
)"
R"(#ifdef VECTOR_SUB_GROUP_BROADCAT
)"
R"(        dequantizeBlockAccum_ns_sgbroadcast_8_hi(totalSum, as_ushort8(regA), regS, regM, regB);
)"
R"(#else
)"
R"(        dequantizeBlockAccum_ns_sgbroadcast_1_hi(totalSum, as_ushort8(regA), regS, regM, regB);
)"
R"(#endif // VECTOR_SUB_GROUP_BROADCAT
)"
R"(
)"
R"(        regA.s0 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 4)).x;
)"
R"(        regA.s1 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 5)).x;
)"
R"(        regA.s2 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 6)).x;
)"
R"(        regA.s3 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 7)).x;
)"
R"(#ifdef VECTOR_SUB_GROUP_BROADCAT
)"
R"(        dequantizeBlockAccum_ns_sgbroadcast_8_lo(totalSum, as_ushort8(regA), regS, regM, regB);
)"
R"(#else
)"
R"(        dequantizeBlockAccum_ns_sgbroadcast_1_lo(totalSum, as_ushort8(regA), regS, regM, regB);
)"
R"(#endif // VECTOR_SUB_GROUP_BROADCAT
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
R"(
)"
R"(// Multi-column (N in [2..4]) variant of the q4_1 decode GEMV (spec/MTP verify) =
)"
R"(// q4_0 mc3 + the q4_1 per-block min (regM; dequant = q*scale + minv). n_cols=2..4;
)"
R"(// routes the small-batch verify OFF the gemm_noshuffle_q4_1 dead-zone. n_cols==3 is
)"
R"(// byte-identical to the original mc3. NB: this file spells the vec-broadcast define
)"
R"(// BROADCAT (no S) — match it so the fast _8 path compiles.
)"
R"(#ifdef VECTOR_SUB_GROUP_BROADCAT
)"
R"(#define MC_DQ1_HI dequantizeBlockAccum_ns_sgbroadcast_8_hi
)"
R"(#define MC_DQ1_LO dequantizeBlockAccum_ns_sgbroadcast_8_lo
)"
R"(#else
)"
R"(#define MC_DQ1_HI dequantizeBlockAccum_ns_sgbroadcast_1_hi
)"
R"(#define MC_DQ1_LO dequantizeBlockAccum_ns_sgbroadcast_1_lo
)"
R"(#endif
)"
R"(#define MC_COL_Q41(ts, c) \
)"
R"(    { if (slid < 4) { regB.s0123 = read_imagef(src1, (c)*COL_STRIDE     + slid*2 + k*8); \
)"
R"(                      regB.s4567 = read_imagef(src1, (c)*COL_STRIDE + 1 + slid*2 + k*8); } \
)"
R"(      MC_DQ1_HI(ts, as_ushort8(regA_hi), regS, regM, regB); \
)"
R"(      MC_DQ1_LO(ts, as_ushort8(regA_lo), regS, regM, regB); }
)"
R"(#ifdef ADRENO_GPU
)"
R"(REQD_SUBGROUP_SIZE_64
)"
R"(#endif
)"
R"(kernel void kernel_gemv_noshuffle_q4_1_f32_mc3(
)"
R"(        read_only  image1d_buffer_t src0_q,
)"
R"(        global half2  * src0_d,
)"
R"(        global half2  * src0_m,
)"
R"(        read_only  image1d_buffer_t src1,
)"
R"(        global float * dst,
)"
R"(        ulong offsetd,
)"
R"(        int ne00,
)"
R"(        int ne01,
)"
R"(        int n_cols)
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
R"(    uint LINE_STRIDE_A  = M / 2;
)"
R"(    // Keep tail lanes active for subgroup ops, but read a valid weight row.
)"
R"(    uint gid_s = min(gid, LINE_STRIDE_A - 1);
)"
R"(    uint BLOCK_STRIDE_A = NSUBGROUPS * M;
)"
R"(    uint COL_STRIDE     = K / 4;   // float4 pixels per activation column
)"
R"(
)"
R"(    private uint4  regA_hi, regA_lo;
)"
R"(    private half2  regS, regM;
)"
R"(    private float8 regB;
)"
R"(
)"
R"(    private float2 ts0 = (float2)(0.0f);
)"
R"(    private float2 ts1 = (float2)(0.0f);
)"
R"(    private float2 ts2 = (float2)(0.0f);
)"
R"(    private float2 ts3 = (float2)(0.0f);
)"
R"(
)"
R"(    uint nsg_rt = get_local_size(1);  // [dspark] runtime K-split stride
)"
R"(    for (uint k = groupId; k < (K / QK4_0); k += nsg_rt) {
)"
R"(        regS = src0_d[gid_s + k * LINE_STRIDE_A];
)"
R"(        regM = src0_m[gid_s + k * LINE_STRIDE_A];
)"
R"(
)"
R"(        // weights loaded ONCE, reused across the columns
)"
R"(        regA_hi.s0 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 0)).x;
)"
R"(        regA_hi.s1 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 1)).x;
)"
R"(        regA_hi.s2 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 2)).x;
)"
R"(        regA_hi.s3 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 3)).x;
)"
R"(        regA_lo.s0 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 4)).x;
)"
R"(        regA_lo.s1 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 5)).x;
)"
R"(        regA_lo.s2 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 6)).x;
)"
R"(        regA_lo.s3 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 7)).x;
)"
R"(
)"
R"(        MC_COL_Q41(ts0, 0);
)"
R"(        MC_COL_Q41(ts1, 1);
)"
R"(        if (n_cols > 2) MC_COL_Q41(ts2, 2);
)"
R"(        if (n_cols > 3) MC_COL_Q41(ts3, 3);
)"
R"(    }
)"
R"(
)"
R"(    // cross-subgroup reduce: pack the (up to 4) columns' float2 into a float8.
)"
R"(    local float8 reduceLM[SUBGROUP_SIZE * 3];
)"
R"(    float8 acc = (float8)(ts0.s0, ts0.s1, ts1.s0, ts1.s1, ts2.s0, ts2.s1, ts3.s0, ts3.s1);
)"
R"(    if (groupId > 0) { reduceLM[SUBGROUP_SIZE * (groupId-1) + slid] = acc; }
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
R"(            acc += reduceLM[SUBGROUP_SIZE * i + slid];
)"
R"(        }
)"
R"(        dst = (global float*)((global char*)dst + offsetd);
)"
R"(        // dst is column-major [M rows x n_cols cols]: (row, col) at col*M + row
)"
R"(        if (gid < LINE_STRIDE_A) {
)"
R"(            vstore2((float2)(acc.s0, acc.s1), 0, &(dst[0 * M + gid * 2]));
)"
R"(            vstore2((float2)(acc.s2, acc.s3), 0, &(dst[1 * M + gid * 2]));
)"
R"(            if (n_cols > 2) vstore2((float2)(acc.s4, acc.s5), 0, &(dst[2 * M + gid * 2]));
)"
R"(            if (n_cols > 3) vstore2((float2)(acc.s6, acc.s7), 0, &(dst[3 * M + gid * 2]));
)"
R"(        }
)"
R"(    }
)"
R"(}
)"
R"(#undef MC_COL_Q41
)"
R"(#undef MC_DQ1_HI
)"
R"(#undef MC_DQ1_LO
)"
