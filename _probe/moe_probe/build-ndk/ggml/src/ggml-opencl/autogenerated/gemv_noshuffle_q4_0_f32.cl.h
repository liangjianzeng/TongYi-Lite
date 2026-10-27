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
R"(// A6X compiler incorrectly constant-folds get_local_size() results;
)"
R"(// force runtime materialization via a no-op ALU round-trip.
)"
R"(#ifdef GGML_CL_A6X_CONSTFOLD_FIX
)"
R"(#define MATERIALIZE_WG(x) do { (x) *= 2u; if ((x) > 1u) (x) /= 2u; } while(0)
)"
R"(#else
)"
R"(#define MATERIALIZE_WG(x)
)"
R"(#endif
)"
R"(
)"
R"(// assume
)"
R"(#define QK4_0 32
)"
R"(#define N_SIMDGROUP 4
)"
R"(
)"
R"(#define dequantizeBlockAccum_ns_sgbroadcast_1_hi(total_sums, bits4, scale, y) \
)"
R"(    float shared_y; \
)"
R"(    shared_y = SGB_BC(y.s0, 0); \
)"
R"(    total_sums.s0 += ((bits4.s0 & 0x000F) - 8) * scale.s0 * shared_y; \
)"
R"(    total_sums.s1 += ((bits4.s1 & 0x000F) - 8) * scale.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s1, 0); \
)"
R"(    total_sums.s0 += (((bits4.s0 & 0x00F0) >> 4) - 8) * scale.s0 * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s1 & 0x00F0) >> 4) - 8) * scale.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s2, 0); \
)"
R"(    total_sums.s0 += (((bits4.s0 & 0x0F00) >> 8) - 8) * scale.s0 * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s1 & 0x0F00) >> 8) - 8) * scale.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s3, 0); \
)"
R"(    total_sums.s0 += (((bits4.s0 & 0xF000) >> 12) - 8) * scale.s0 * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s1 & 0xF000) >> 12) - 8) * scale.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s4, 0); \
)"
R"(    total_sums.s0 += ((bits4.s2 & 0x000F) - 8) * scale.s0 * shared_y; \
)"
R"(    total_sums.s1 += ((bits4.s3 & 0x000F) - 8) * scale.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s5, 0); \
)"
R"(    total_sums.s0 += (((bits4.s2 & 0x00F0) >> 4) - 8) * scale.s0 * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s3 & 0x00F0) >> 4) - 8) * scale.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s6, 0); \
)"
R"(    total_sums.s0 += (((bits4.s2 & 0x0F00) >> 8) - 8) * scale.s0 * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s3 & 0x0F00) >> 8) - 8) * scale.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s7, 0); \
)"
R"(    total_sums.s0 += (((bits4.s2 & 0xF000) >> 12) - 8) * scale.s0 * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s3 & 0xF000) >> 12) - 8) * scale.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s0, 1); \
)"
R"(    total_sums.s0 += ((bits4.s4 & 0x000F) - 8) * scale.s0 * shared_y; \
)"
R"(    total_sums.s1 += ((bits4.s5 & 0x000F) - 8) * scale.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s1, 1); \
)"
R"(    total_sums.s0 += (((bits4.s4 & 0x00F0) >> 4) - 8) * scale.s0 * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s5 & 0x00F0) >> 4) - 8) * scale.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s2, 1); \
)"
R"(    total_sums.s0 += (((bits4.s4 & 0x0F00) >> 8) - 8) * scale.s0 * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s5 & 0x0F00) >> 8) - 8) * scale.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s3, 1); \
)"
R"(    total_sums.s0 += (((bits4.s4 & 0xF000) >> 12) - 8) * scale.s0 * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s5 & 0xF000) >> 12) - 8) * scale.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s4, 1); \
)"
R"(    total_sums.s0 += ((bits4.s6 & 0x000F) - 8) * scale.s0 * shared_y; \
)"
R"(    total_sums.s1 += ((bits4.s7 & 0x000F) - 8) * scale.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s5, 1); \
)"
R"(    total_sums.s0 += (((bits4.s6 & 0x00F0) >> 4) - 8) * scale.s0 * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s7 & 0x00F0) >> 4) - 8) * scale.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s6, 1); \
)"
R"(    total_sums.s0 += (((bits4.s6 & 0x0F00) >> 8) - 8) * scale.s0 * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s7 & 0x0F00) >> 8) - 8) * scale.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s7, 1); \
)"
R"(    total_sums.s0 += (((bits4.s6 & 0xF000) >> 12) - 8) * scale.s0 * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s7 & 0xF000) >> 12) - 8) * scale.s1 * shared_y; \
)"
R"(
)"
R"(
)"
R"(#define dequantizeBlockAccum_ns_sgbroadcast_1_lo(total_sums, bits4, scale, y) \
)"
R"(    shared_y = SGB_BC(y.s0, 2); \
)"
R"(    total_sums.s0 += ((bits4.s0 & 0x000F) - 8) * scale.s0 * shared_y; \
)"
R"(    total_sums.s1 += ((bits4.s1 & 0x000F) - 8) * scale.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s1, 2); \
)"
R"(    total_sums.s0 += (((bits4.s0 & 0x00F0) >> 4) - 8) * scale.s0 * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s1 & 0x00F0) >> 4) - 8) * scale.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s2, 2); \
)"
R"(    total_sums.s0 += (((bits4.s0 & 0x0F00) >> 8) - 8) * scale.s0 * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s1 & 0x0F00) >> 8) - 8) * scale.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s3, 2); \
)"
R"(    total_sums.s0 += (((bits4.s0 & 0xF000) >> 12) - 8) * scale.s0 * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s1 & 0xF000) >> 12) - 8) * scale.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s4, 2); \
)"
R"(    total_sums.s0 += ((bits4.s2 & 0x000F) - 8) * scale.s0 * shared_y; \
)"
R"(    total_sums.s1 += ((bits4.s3 & 0x000F) - 8) * scale.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s5, 2); \
)"
R"(    total_sums.s0 += (((bits4.s2 & 0x00F0) >> 4) - 8) * scale.s0 * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s3 & 0x00F0) >> 4) - 8) * scale.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s6, 2); \
)"
R"(    total_sums.s0 += (((bits4.s2 & 0x0F00) >> 8) - 8) * scale.s0 * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s3 & 0x0F00) >> 8) - 8) * scale.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s7, 2); \
)"
R"(    total_sums.s0 += (((bits4.s2 & 0xF000) >> 12) - 8) * scale.s0 * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s3 & 0xF000) >> 12) - 8) * scale.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s0, 3); \
)"
R"(    total_sums.s0 += ((bits4.s4 & 0x000F) - 8) * scale.s0 * shared_y; \
)"
R"(    total_sums.s1 += ((bits4.s5 & 0x000F) - 8) * scale.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s1, 3); \
)"
R"(    total_sums.s0 += (((bits4.s4 & 0x00F0) >> 4) - 8) * scale.s0 * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s5 & 0x00F0) >> 4) - 8) * scale.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s2, 3); \
)"
R"(    total_sums.s0 += (((bits4.s4 & 0x0F00) >> 8) - 8) * scale.s0 * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s5 & 0x0F00) >> 8) - 8) * scale.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s3, 3); \
)"
R"(    total_sums.s0 += (((bits4.s4 & 0xF000) >> 12) - 8) * scale.s0 * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s5 & 0xF000) >> 12) - 8) * scale.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s4, 3); \
)"
R"(    total_sums.s0 += ((bits4.s6 & 0x000F) - 8) * scale.s0 * shared_y; \
)"
R"(    total_sums.s1 += ((bits4.s7 & 0x000F) - 8) * scale.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s5, 3); \
)"
R"(    total_sums.s0 += (((bits4.s6 & 0x00F0) >> 4) - 8) * scale.s0 * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s7 & 0x00F0) >> 4) - 8) * scale.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s6, 3); \
)"
R"(    total_sums.s0 += (((bits4.s6 & 0x0F00) >> 8) - 8) * scale.s0 * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s7 & 0x0F00) >> 8) - 8) * scale.s1 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s7, 3); \
)"
R"(    total_sums.s0 += (((bits4.s6 & 0xF000) >> 12) - 8) * scale.s0 * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s7 & 0xF000) >> 12) - 8) * scale.s1 * shared_y; \
)"
R"(
)"
R"(
)"
R"(#define dequantizeBlockAccum_ns_sgbroadcast_8_hi(total_sums, bits4, scale, y) \
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
R"(    total_sums.s0 += ((bits4.s0 & 0x000F) - 8) * scale.s0 * shared_y.s0; \
)"
R"(    total_sums.s0 += (((bits4.s0 & 0x00F0) >> 4) - 8) * scale.s0 * shared_y.s1; \
)"
R"(    total_sums.s0 += (((bits4.s0 & 0x0F00) >> 8) - 8) * scale.s0 * shared_y.s2; \
)"
R"(    total_sums.s0 += (((bits4.s0 & 0xF000) >> 12) - 8) * scale.s0 * shared_y.s3; \
)"
R"(    total_sums.s0 += ((bits4.s2 & 0x000F) - 8) * scale.s0 * shared_y.s4; \
)"
R"(    total_sums.s0 += (((bits4.s2 & 0x00F0) >> 4) - 8) * scale.s0 * shared_y.s5; \
)"
R"(    total_sums.s0 += (((bits4.s2 & 0x0F00) >> 8) - 8) * scale.s0 * shared_y.s6; \
)"
R"(    total_sums.s0 += (((bits4.s2 & 0xF000) >> 12) - 8) * scale.s0 * shared_y.s7; \
)"
R"(    total_sums.s1 += ((bits4.s1 & 0x000F) - 8) * scale.s1 * shared_y.s0; \
)"
R"(    total_sums.s1 += (((bits4.s1 & 0x00F0) >> 4) - 8) * scale.s1 * shared_y.s1; \
)"
R"(    total_sums.s1 += (((bits4.s1 & 0x0F00) >> 8) - 8) * scale.s1 * shared_y.s2; \
)"
R"(    total_sums.s1 += (((bits4.s1 & 0xF000) >> 12) - 8) * scale.s1 * shared_y.s3; \
)"
R"(    total_sums.s1 += ((bits4.s3 & 0x000F) - 8) * scale.s1 * shared_y.s4; \
)"
R"(    total_sums.s1 += (((bits4.s3 & 0x00F0) >> 4) - 8) * scale.s1 * shared_y.s5; \
)"
R"(    total_sums.s1 += (((bits4.s3 & 0x0F00) >> 8) - 8) * scale.s1 * shared_y.s6; \
)"
R"(    total_sums.s1 += (((bits4.s3 & 0xF000) >> 12) - 8) * scale.s1 * shared_y.s7; \
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
R"(    total_sums.s0 += ((bits4.s4 & 0x000F) - 8) * scale.s0 * shared_y.s0; \
)"
R"(    total_sums.s0 += (((bits4.s4 & 0x00F0) >> 4) - 8) * scale.s0 * shared_y.s1; \
)"
R"(    total_sums.s0 += (((bits4.s4 & 0x0F00) >> 8) - 8) * scale.s0 * shared_y.s2; \
)"
R"(    total_sums.s0 += (((bits4.s4 & 0xF000) >> 12) - 8) * scale.s0 * shared_y.s3; \
)"
R"(    total_sums.s0 += ((bits4.s6 & 0x000F) - 8) * scale.s0 * shared_y.s4; \
)"
R"(    total_sums.s0 += (((bits4.s6 & 0x00F0) >> 4) - 8) * scale.s0 * shared_y.s5; \
)"
R"(    total_sums.s0 += (((bits4.s6 & 0x0F00) >> 8) - 8) * scale.s0 * shared_y.s6; \
)"
R"(    total_sums.s0 += (((bits4.s6 & 0xF000) >> 12) - 8) * scale.s0 * shared_y.s7; \
)"
R"(    total_sums.s1 += ((bits4.s5 & 0x000F) - 8) * scale.s1 * shared_y.s0; \
)"
R"(    total_sums.s1 += (((bits4.s5 & 0x00F0) >> 4) - 8) * scale.s1 * shared_y.s1; \
)"
R"(    total_sums.s1 += (((bits4.s5 & 0x0F00) >> 8) - 8) * scale.s1 * shared_y.s2; \
)"
R"(    total_sums.s1 += (((bits4.s5 & 0xF000) >> 12) - 8) * scale.s1 * shared_y.s3; \
)"
R"(    total_sums.s1 += ((bits4.s7 & 0x000F) - 8) * scale.s1 * shared_y.s4; \
)"
R"(    total_sums.s1 += (((bits4.s7 & 0x00F0) >> 4) - 8) * scale.s1 * shared_y.s5; \
)"
R"(    total_sums.s1 += (((bits4.s7 & 0x0F00) >> 8) - 8) * scale.s1 * shared_y.s6; \
)"
R"(    total_sums.s1 += (((bits4.s7 & 0xF000) >> 12) - 8) * scale.s1 * shared_y.s7; \
)"
R"(
)"
R"(
)"
R"(#define dequantizeBlockAccum_ns_sgbroadcast_8_lo(total_sums, bits4, scale, y) \
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
R"(    total_sums.s0 += ((bits4.s0 & 0x000F) - 8) * scale.s0 * shared_y.s0; \
)"
R"(    total_sums.s0 += (((bits4.s0 & 0x00F0) >> 4) - 8) * scale.s0 * shared_y.s1; \
)"
R"(    total_sums.s0 += (((bits4.s0 & 0x0F00) >> 8) - 8) * scale.s0 * shared_y.s2; \
)"
R"(    total_sums.s0 += (((bits4.s0 & 0xF000) >> 12) - 8) * scale.s0 * shared_y.s3; \
)"
R"(    total_sums.s0 += ((bits4.s2 & 0x000F) - 8) * scale.s0 * shared_y.s4; \
)"
R"(    total_sums.s0 += (((bits4.s2 & 0x00F0) >> 4) - 8) * scale.s0 * shared_y.s5; \
)"
R"(    total_sums.s0 += (((bits4.s2 & 0x0F00) >> 8) - 8) * scale.s0 * shared_y.s6; \
)"
R"(    total_sums.s0 += (((bits4.s2 & 0xF000) >> 12) - 8) * scale.s0 * shared_y.s7; \
)"
R"(    total_sums.s1 += ((bits4.s1 & 0x000F) - 8) * scale.s1 * shared_y.s0; \
)"
R"(    total_sums.s1 += (((bits4.s1 & 0x00F0) >> 4) - 8) * scale.s1 * shared_y.s1; \
)"
R"(    total_sums.s1 += (((bits4.s1 & 0x0F00) >> 8) - 8) * scale.s1 * shared_y.s2; \
)"
R"(    total_sums.s1 += (((bits4.s1 & 0xF000) >> 12) - 8) * scale.s1 * shared_y.s3; \
)"
R"(    total_sums.s1 += ((bits4.s3 & 0x000F) - 8) * scale.s1 * shared_y.s4; \
)"
R"(    total_sums.s1 += (((bits4.s3 & 0x00F0) >> 4) - 8) * scale.s1 * shared_y.s5; \
)"
R"(    total_sums.s1 += (((bits4.s3 & 0x0F00) >> 8) - 8) * scale.s1 * shared_y.s6; \
)"
R"(    total_sums.s1 += (((bits4.s3 & 0xF000) >> 12) - 8) * scale.s1 * shared_y.s7; \
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
R"(    total_sums.s0 += ((bits4.s4 & 0x000F) - 8) * scale.s0 * shared_y.s0; \
)"
R"(    total_sums.s0 += (((bits4.s4 & 0x00F0) >> 4) - 8) * scale.s0 * shared_y.s1; \
)"
R"(    total_sums.s0 += (((bits4.s4 & 0x0F00) >> 8) - 8) * scale.s0 * shared_y.s2; \
)"
R"(    total_sums.s0 += (((bits4.s4 & 0xF000) >> 12) - 8) * scale.s0 * shared_y.s3; \
)"
R"(    total_sums.s0 += ((bits4.s6 & 0x000F) - 8) * scale.s0 * shared_y.s4; \
)"
R"(    total_sums.s0 += (((bits4.s6 & 0x00F0) >> 4) - 8) * scale.s0 * shared_y.s5; \
)"
R"(    total_sums.s0 += (((bits4.s6 & 0x0F00) >> 8) - 8) * scale.s0 * shared_y.s6; \
)"
R"(    total_sums.s0 += (((bits4.s6 & 0xF000) >> 12) - 8) * scale.s0 * shared_y.s7; \
)"
R"(    total_sums.s1 += ((bits4.s5 & 0x000F) - 8) * scale.s1 * shared_y.s0; \
)"
R"(    total_sums.s1 += (((bits4.s5 & 0x00F0) >> 4) - 8) * scale.s1 * shared_y.s1; \
)"
R"(    total_sums.s1 += (((bits4.s5 & 0x0F00) >> 8) - 8) * scale.s1 * shared_y.s2; \
)"
R"(    total_sums.s1 += (((bits4.s5 & 0xF000) >> 12) - 8) * scale.s1 * shared_y.s3; \
)"
R"(    total_sums.s1 += ((bits4.s7 & 0x000F) - 8) * scale.s1 * shared_y.s4; \
)"
R"(    total_sums.s1 += (((bits4.s7 & 0x00F0) >> 4) - 8) * scale.s1 * shared_y.s5; \
)"
R"(    total_sums.s1 += (((bits4.s7 & 0x0F00) >> 8) - 8) * scale.s1 * shared_y.s6; \
)"
R"(    total_sums.s1 += (((bits4.s7 & 0xF000) >> 12) - 8) * scale.s1 * shared_y.s7; \
)"
R"(
)"
R"(// [dspark 2026-10-20] rusticl-safe (GGML_OPENCL_RUSTICL) per-lane self-load
)"
R"(// dequant: no subgroup broadcast, no local reduce. One lane owns a row pair
)"
R"(// end-to-end (full K loop), reads B itself, writes dst directly. 4x redundant
)"
R"(// B reads vs the broadcast protocol, but B is L1-resident. Bit semantics are
)"
R"(// lifted 1:1 from dequantizeBlockAccum_ns_sgbroadcast_1_hi/lo: for each half,
)"
R"(// bits4.s0/s1 (rows 0/1, nibble n) multiply activation float 4*half + n's
)"
R"(// pixel group — i.e. s0/s1 -> pixel pix+0, s2/s3 -> pix+1, s4/s5 -> pix+2,
)"
R"(// s6/s7 -> pix+3 (nibble n -> component n).
)"
R"(#define DEQUANT_ACCUM_SELF_Q40_HLF(total_sums, bits4, scale, img, pix) \
)"
R"(    { float4 sb0 = read_imagef(img, (pix)); \
)"
R"(    total_sums.s0 += ((bits4.s0 & 0x000F) - 8) * scale.s0 * sb0.x; \
)"
R"(    total_sums.s1 += ((bits4.s1 & 0x000F) - 8) * scale.s1 * sb0.x; \
)"
R"(    total_sums.s0 += (((bits4.s0 >> 4) & 0x000F) - 8) * scale.s0 * sb0.y; \
)"
R"(    total_sums.s1 += (((bits4.s1 >> 4) & 0x000F) - 8) * scale.s1 * sb0.y; \
)"
R"(    total_sums.s0 += (((bits4.s0 >> 8) & 0x000F) - 8) * scale.s0 * sb0.z; \
)"
R"(    total_sums.s1 += (((bits4.s1 >> 8) & 0x000F) - 8) * scale.s1 * sb0.z; \
)"
R"(    total_sums.s0 += (((bits4.s0 >> 12) & 0x000F) - 8) * scale.s0 * sb0.w; \
)"
R"(    total_sums.s1 += (((bits4.s1 >> 12) & 0x000F) - 8) * scale.s1 * sb0.w; \
)"
R"(    float4 sb1 = read_imagef(img, (pix) + 1); \
)"
R"(    total_sums.s0 += ((bits4.s2 & 0x000F) - 8) * scale.s0 * sb1.x; \
)"
R"(    total_sums.s1 += ((bits4.s3 & 0x000F) - 8) * scale.s1 * sb1.x; \
)"
R"(    total_sums.s0 += (((bits4.s2 >> 4) & 0x000F) - 8) * scale.s0 * sb1.y; \
)"
R"(    total_sums.s1 += (((bits4.s3 >> 4) & 0x000F) - 8) * scale.s1 * sb1.y; \
)"
R"(    total_sums.s0 += (((bits4.s2 >> 8) & 0x000F) - 8) * scale.s0 * sb1.z; \
)"
R"(    total_sums.s1 += (((bits4.s3 >> 8) & 0x000F) - 8) * scale.s1 * sb1.z; \
)"
R"(    total_sums.s0 += (((bits4.s2 >> 12) & 0x000F) - 8) * scale.s0 * sb1.w; \
)"
R"(    total_sums.s1 += (((bits4.s3 >> 12) & 0x000F) - 8) * scale.s1 * sb1.w; \
)"
R"(    float4 sb2 = read_imagef(img, (pix) + 2); \
)"
R"(    total_sums.s0 += ((bits4.s4 & 0x000F) - 8) * scale.s0 * sb2.x; \
)"
R"(    total_sums.s1 += ((bits4.s5 & 0x000F) - 8) * scale.s1 * sb2.x; \
)"
R"(    total_sums.s0 += (((bits4.s4 >> 4) & 0x000F) - 8) * scale.s0 * sb2.y; \
)"
R"(    total_sums.s1 += (((bits4.s5 >> 4) & 0x000F) - 8) * scale.s1 * sb2.y; \
)"
R"(    total_sums.s0 += (((bits4.s4 >> 8) & 0x000F) - 8) * scale.s0 * sb2.z; \
)"
R"(    total_sums.s1 += (((bits4.s5 >> 8) & 0x000F) - 8) * scale.s1 * sb2.z; \
)"
R"(    total_sums.s0 += (((bits4.s4 >> 12) & 0x000F) - 8) * scale.s0 * sb2.w; \
)"
R"(    total_sums.s1 += (((bits4.s5 >> 12) & 0x000F) - 8) * scale.s1 * sb2.w; \
)"
R"(    float4 sb3 = read_imagef(img, (pix) + 3); \
)"
R"(    total_sums.s0 += ((bits4.s6 & 0x000F) - 8) * scale.s0 * sb3.x; \
)"
R"(    total_sums.s1 += ((bits4.s7 & 0x000F) - 8) * scale.s1 * sb3.x; \
)"
R"(    total_sums.s0 += (((bits4.s6 >> 4) & 0x000F) - 8) * scale.s0 * sb3.y; \
)"
R"(    total_sums.s1 += (((bits4.s7 >> 4) & 0x000F) - 8) * scale.s1 * sb3.y; \
)"
R"(    total_sums.s0 += (((bits4.s6 >> 8) & 0x000F) - 8) * scale.s0 * sb3.z; \
)"
R"(    total_sums.s1 += (((bits4.s7 >> 8) & 0x000F) - 8) * scale.s1 * sb3.z; \
)"
R"(    total_sums.s0 += (((bits4.s6 >> 12) & 0x000F) - 8) * scale.s0 * sb3.w; \
)"
R"(    total_sums.s1 += (((bits4.s7 >> 12) & 0x000F) - 8) * scale.s1 * sb3.w; }
)"
R"(
)"
R"(#if defined(ADRENO_GPU) && !defined(GGML_OPENCL_RUSTICL)
)"
R"(REQD_SUBGROUP_SIZE_64
)"
R"(#endif
)"
R"(__kernel void kernel_gemv_noshuffle_q4_0_f32(
)"
R"(        __read_only  image1d_buffer_t src0_q,  // quantized A
)"
R"(        global half2  * src0_d,  // A scales
)"
R"(        __read_only  image1d_buffer_t src1,    // B
)"
R"(        ulong offset1,            // offset to B (0)
)"
R"(        global float * dst,     // C
)"
R"(        ulong offsetd,            // offset to C (0)
)"
R"(        int ne00,               // K
)"
R"(        int ne01,               // M
)"
R"(        int ne02,               // 1
)"
R"(        int ne10,               // K
)"
R"(        int ne12,               // 1
)"
R"(        int ne0,                // M
)"
R"(        int ne1,                // N
)"
R"(        int r2,                 // 1
)"
R"(        int r3)
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
R"(    uint BLOCK_STRIDE_A = N_SIMDGROUP * M;
)"
R"(
)"
R"(    __private uint4     regA;
)"
R"(    __private half2     regS;
)"
R"(    __private float8    regB;
)"
R"(
)"
R"(    __private float2 totalSum = (float2)(0.0f);
)"
R"(
)"
R"(#if defined(ADRENO_GPU) && !defined(GGML_OPENCL_RUSTICL)
)"
R"(    // loop along K in block granularity, skip 4 blocks every iter
)"
R"(    for (uint k = groupId; k < (K / QK4_0); k += N_SIMDGROUP) {
)"
R"(        regS = src0_d[gid_s + k * LINE_STRIDE_A]; // each fiber loads scale of two rows
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
R"(#ifdef VECTOR_SUB_GROUP_BROADCAST
)"
R"(        dequantizeBlockAccum_ns_sgbroadcast_8_hi(totalSum, as_ushort8(regA), regS, regB);
)"
R"(#else
)"
R"(        dequantizeBlockAccum_ns_sgbroadcast_1_hi(totalSum, as_ushort8(regA), regS, regB);
)"
R"(#endif // VECTOR_SUB_GROUP_BROADCAST
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
R"(#ifdef VECTOR_SUB_GROUP_BROADCAST
)"
R"(        dequantizeBlockAccum_ns_sgbroadcast_8_lo(totalSum, as_ushort8(regA), regS, regB);
)"
R"(#else
)"
R"(        dequantizeBlockAccum_ns_sgbroadcast_1_lo(totalSum, as_ushort8(regA), regS, regB);
)"
R"(#endif // VECTOR_SUB_GROUP_BROADCAST
)"
R"(    }
)"
R"(
)"
R"(    // reduction in local memory, assumes #wave=4
)"
R"(    __local float2 reduceLM[SIMDGROUP_WIDTH * 3];
)"
R"(    if (groupId == 1) reduceLM[SIMDGROUP_WIDTH * 0 + slid] = totalSum;
)"
R"(    if (groupId == 2) reduceLM[SIMDGROUP_WIDTH * 1 + slid] = totalSum;
)"
R"(    if (groupId == 3) reduceLM[SIMDGROUP_WIDTH * 2 + slid] = totalSum;
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(    if (groupId == 0) totalSum += reduceLM[SIMDGROUP_WIDTH * 0 + slid];
)"
R"(    if (groupId == 0) totalSum += reduceLM[SIMDGROUP_WIDTH * 1 + slid];
)"
R"(    if (groupId == 0) totalSum += reduceLM[SIMDGROUP_WIDTH * 2 + slid];
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
R"(#else
)"
R"(    // [dspark 2026-10-20] rusticl-safe variant (FD650 measured): rusticl drew
)"
R"(    // sgs=128 for this kernel, which spans local y-groups and breaks both the
)"
R"(    // slid<4 B broadcast (y1 receives y0's B for a different k) and the
)"
R"(    // slid-indexed local reduce (slot aliasing + OOB). Sync-free full-K path:
)"
R"(    // one lane owns its row pair end-to-end, zero cross-thread communication.
)"
R"(    for (uint k = 0; k < (K / QK4_0); k++) {
)"
R"(        regS = src0_d[gid_s + k * LINE_STRIDE_A];
)"
R"(        regA.s0 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 0)).x;
)"
R"(        regA.s1 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 1)).x;
)"
R"(        regA.s2 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 2)).x;
)"
R"(        regA.s3 = read_imageui(src0_q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 3)).x;
)"
R"(        DEQUANT_ACCUM_SELF_Q40_HLF(totalSum, as_ushort8(regA), regS, src1, k * 8);
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
R"(        DEQUANT_ACCUM_SELF_Q40_HLF(totalSum, as_ushort8(regA), regS, src1, k * 8 + 4);
)"
R"(    }
)"
R"(
)"
R"(    // every lane holds a complete total; write directly (row guards as above)
)"
R"(    dst = (global float*)((global char*)dst + offsetd);
)"
R"(    if (gid * 2 + 0 < M) dst[gid * 2 + 0] = totalSum.s0;
)"
R"(    if (gid * 2 + 1 < M) dst[gid * 2 + 1] = totalSum.s1;
)"
R"(    return;
)"
R"(#endif
)"
R"(
)"
R"(}
)"
R"(
)"
R"(// Multi-column (N in [2..4]) variant of the q4_0 decode GEMV, for the speculative
)"
R"(// / MTP verify batch (n_cols = 2..4 = drafted + bonus positions). Routes the small-
)"
R"(// batch verify OFF the transposed-GEMM dead-zone (gemm_noshuffle_q4_0) onto the
)"
R"(// efficient GEMV path. Each K-block's weights (regA hi+lo) are loaded ONCE and
)"
R"(// reused across the n_cols activation columns. Per-column accumulation is
)"
R"(// independent and identical to n_cols standalone GEMVs. n_cols==3 is byte-identical
)"
R"(// to the original mc3 (col3 disabled, slots 6/7 stay zero). Kept the _mc3 name.
)"
R"(#ifdef VECTOR_SUB_GROUP_BROADCAST
)"
R"(#define MC_DQ_HI dequantizeBlockAccum_ns_sgbroadcast_8_hi
)"
R"(#define MC_DQ_LO dequantizeBlockAccum_ns_sgbroadcast_8_lo
)"
R"(#else
)"
R"(#define MC_DQ_HI dequantizeBlockAccum_ns_sgbroadcast_1_hi
)"
R"(#define MC_DQ_LO dequantizeBlockAccum_ns_sgbroadcast_1_lo
)"
R"(#endif
)"
R"(// One column c: load this column's activation (own brace scope so the macros'
)"
R"(// `shared_y` decl is re-scoped), then dequant (hi+lo) against the shared weights.
)"
R"(#define MC_COL_Q40(ts, c) \
)"
R"(    { if (slid < 4) { regB.s0123 = read_imagef(src1, (c)*COL_STRIDE     + slid*2 + k*8); \
)"
R"(                      regB.s4567 = read_imagef(src1, (c)*COL_STRIDE + 1 + slid*2 + k*8); } \
)"
R"(      MC_DQ_HI(ts, as_ushort8(regA_hi), regS, regB); \
)"
R"(      MC_DQ_LO(ts, as_ushort8(regA_lo), regS, regB); }
)"
R"(
)"
R"(#ifdef ADRENO_GPU
)"
R"(REQD_SUBGROUP_SIZE_64
)"
R"(#endif
)"
R"(__kernel void kernel_gemv_noshuffle_q4_0_f32_mc3(
)"
R"(        __read_only  image1d_buffer_t src0_q,  // quantized A
)"
R"(        global half2  * src0_d,                // A scales
)"
R"(        __read_only  image1d_buffer_t src1,    // B (n_cols columns, col-major image)
)"
R"(        global float * dst,                    // C (column-major [M x n_cols])
)"
R"(        ulong offsetd,
)"
R"(        int ne00,                              // K
)"
R"(        int ne01,                              // M
)"
R"(        int n_cols)                            // N (2..4)
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
R"(    // BLOCK_STRIDE_A is the LAYOUT stride between consecutive K-blocks = 4 uints
)"
R"(    // per q4_0 block * M (set by the trans4_ns convert). The "4" is uints/block, NOT
)"
R"(    // the subgroup count — keep it fixed so the K-split count (nsg) can vary.
)"
R"(    uint BLOCK_STRIDE_A = N_SIMDGROUP * M;   // = 4 * M (N_SIMDGROUP is the #define 4)
)"
R"(    uint COL_STRIDE     = K / 4;   // float4 pixels per activation column
)"
R"(    uint nsg            = get_local_size(1);  // runtime K-split (4 default, 8 small-M)
)"
R"(    MATERIALIZE_WG(nsg);
)"
R"(
)"
R"(    __private uint4  regA_hi, regA_lo;
)"
R"(    __private half2  regS;
)"
R"(    __private float8 regB;
)"
R"(
)"
R"(    __private float2 ts0 = (float2)(0.0f);
)"
R"(    __private float2 ts1 = (float2)(0.0f);
)"
R"(    __private float2 ts2 = (float2)(0.0f);
)"
R"(    __private float2 ts3 = (float2)(0.0f);
)"
R"(
)"
R"(    for (uint k = groupId; k < (K / QK4_0); k += nsg) {
)"
R"(        regS = src0_d[gid_s + k * LINE_STRIDE_A];
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
R"(        MC_COL_Q40(ts0, 0);
)"
R"(        MC_COL_Q40(ts1, 1);
)"
R"(        if (n_cols > 2) MC_COL_Q40(ts2, 2);
)"
R"(        if (n_cols > 3) MC_COL_Q40(ts3, 3);
)"
R"(    }
)"
R"(
)"
R"(    // cross-subgroup reduce over nsg subgroups: pack the (up to 4) columns' float2
)"
R"(    // into a float8. Generalized to runtime nsg (4 default, 8 for small-M). Each
)"
R"(    // subgroup writes its partial; subgroup 0 sums the rest into its own acc. At
)"
R"(    // nsg==4 this is byte-identical to the original (sums subgroups 1,2,3 in order).
)"
R"(    __local float8 reduceLM[SIMDGROUP_WIDTH * 8];
)"
R"(    float8 acc = (float8)(ts0.s0, ts0.s1, ts1.s0, ts1.s1, ts2.s0, ts2.s1, ts3.s0, ts3.s1);
)"
R"(    reduceLM[groupId * SIMDGROUP_WIDTH + slid] = acc;
)"
R"(
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(    if (groupId == 0) {
)"
R"(        for (uint g = 1; g < nsg; g++) {
)"
R"(            acc += reduceLM[g * SIMDGROUP_WIDTH + slid];
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
R"(#undef MC_COL_Q40
)"
R"(#undef MC_DQ_HI
)"
R"(#undef MC_DQ_LO
)"
R"(
)"
R"(// [dspark 2026-10-13] Batched MUL_MAT_ID for q4_0 MoE: ONE dispatch computes all
)"
R"(// (expert-slot, token) GEMV columns, and the expert ids are read on-device —
)"
R"(// eliminating the dense-loop's per-expert dispatches AND the per-layer ids
)"
R"(// readback sync. Weight/b/scale addressing is the validated
)"
R"(// kernel_gemv_noshuffle_q4_0_f32 with three base shifts:
)"
R"(//   row-pair index  gid -> rp   (gid now encodes column too)
)"
R"(//   weight base     + e * q_layer_pix   (experts laid out contiguously by
)"
R"(//                    set_tensor, each layer byte-identical to a dense 2D
)"
R"(//                    [K, M] noshuffle+transposed weight — the same layout the
)"
R"(//                    dense-loop GEMV reads, validated NMSE=0)
)"
R"(//   B column base   + col * (K/4) float4 pixels
)"
R"(// Requires (host-checked): M % 128 == 0 (no row-pair padding, so every index
)"
R"(// stays inside its expert layer), K % 32 == 0, ids in [0, E).
)"
R"(#ifdef VECTOR_SUB_GROUP_BROADCAST
)"
R"(#define BMO_DQ_HI dequantizeBlockAccum_ns_sgbroadcast_8_hi
)"
R"(#define BMO_DQ_LO dequantizeBlockAccum_ns_sgbroadcast_8_lo
)"
R"(#else
)"
R"(#define BMO_DQ_HI dequantizeBlockAccum_ns_sgbroadcast_1_hi
)"
R"(#define BMO_DQ_LO dequantizeBlockAccum_ns_sgbroadcast_1_lo
)"
R"(#endif
)"
R"(#ifdef ADRENO_GPU
)"
R"(REQD_SUBGROUP_SIZE_64
)"
R"(#endif
)"
R"(__kernel void kernel_mul_mat_id_q4_0_f32_batched(
)"
R"(        __read_only  image1d_buffer_t src0_q,  // E transposed q4_0 expert layers
)"
R"(        global half2  * src0_d,                // E layers of fp16 block scales
)"
R"(        __read_only  image1d_buffer_t src1,    // B: ne11*n_tok columns of K floats
)"
R"(        global int    * ids,                   // MUL_MAT_ID ids tensor (I32)
)"
R"(        int ids_elem_off,                      // element offset of ids base
)"
R"(        global float * dst,                    // destination buffer
)"
R"(        ulong offsetd,                         // byte offset of dst base
)"
R"(        int ne00,                              // K
)"
R"(        int ne01,                              // M (output rows)
)"
R"(        int n_used,                            // expert slots per token
)"
R"(        int n_tok,                             // tokens
)"
R"(        int ne11,                              // src1 columns (1 => broadcast)
)"
R"(        int n_expert,                          // E
)"
R"(        int ids_row,                           // ids row stride in elements
)"
R"(        ulong dst_nb1,                         // dst->nb[1] bytes
)"
R"(        ulong dst_nb2,                         // dst->nb[2] bytes
)"
R"(        int grid_x_per_col,                    // CEIL_DIV(M/2, 64) * 64
)"
R"(        ulong q_layer_pix,                     // per-expert q stride (uint pixels)
)"
R"(        ulong d_layer_bytes)                   // per-expert scale stride (bytes)
)"
R"({
)"
R"(    uint gid  = get_global_id(0);
)"
R"(    uint slid = get_sub_group_local_id();
)"
R"(    uint groupId = get_local_id(1);
)"
R"(
)"
R"(    uint K  = (uint)ne00;
)"
R"(    uint M  = (uint)ne01;
)"
R"(    uint M2 = M / 2;
)"
R"(
)"
R"(    uint colp = gid / (uint)grid_x_per_col;
)"
R"(    uint rp   = gid - colp * (uint)grid_x_per_col;   // row-pair index, rp < M2 (no padding)
)"
R"(
)"
R"(    uint col = colp;   // identity (P3 sort is q3_K-only; perm param removed)
)"
R"(
)"
R"(    uint t = col / (uint)n_used;
)"
R"(    uint j = col - t * (uint)n_used;
)"
R"(
)"
R"(    int e = ids[ids_elem_off + (int)t * ids_row + (int)j];
)"
R"(    bool valid = (e >= 0) && (e < n_expert);
)"
R"(    int  es    = valid ? e : 0;   // safe reads; invalid ids write zeros
)"
R"(
)"
R"(    uint LINE_STRIDE_A  = M / 2;
)"
R"(    uint BLOCK_STRIDE_A = N_SIMDGROUP * M;
)"
R"(
)"
R"(    global half2 * drow = (global half2*)((global char*)src0_d + (ulong)es * d_layer_bytes);
)"
R"(    int qbase = (int)((ulong)es * q_layer_pix);
)"
R"(    int bbase = (int)((ulong)((j % (uint)ne11) + t * (uint)ne11) * (K / 4));
)"
R"(    global float * dstc = (global float*)((global char*)dst + offsetd
)"
R"(                            + (ulong)j * dst_nb1 + (ulong)t * dst_nb2);
)"
R"(
)"
R"(    __private uint4  regA;
)"
R"(    __private half2  regS;
)"
R"(    __private float8 regB;
)"
R"(
)"
R"(    __private float2 totalSum = (float2)(0.0f);
)"
R"(
)"
R"(    for (uint k = groupId; k < (K / QK4_0); k += N_SIMDGROUP) {
)"
R"(        regS = drow[rp + k * LINE_STRIDE_A]; // scale of two rows
)"
R"(        if (slid < 4) {
)"
R"(            regB.s0123 = read_imagef(src1, bbase + (int)(slid * 2 + k * 8));
)"
R"(            regB.s4567 = read_imagef(src1, bbase + (int)(1 + slid * 2 + k * 8));
)"
R"(        }
)"
R"(
)"
R"(        regA.s0 = read_imageui(src0_q, (int)(rp + qbase + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 0)).x;
)"
R"(        regA.s1 = read_imageui(src0_q, (int)(rp + qbase + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 1)).x;
)"
R"(        regA.s2 = read_imageui(src0_q, (int)(rp + qbase + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 2)).x;
)"
R"(        regA.s3 = read_imageui(src0_q, (int)(rp + qbase + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 3)).x;
)"
R"(        BMO_DQ_HI(totalSum, as_ushort8(regA), regS, regB);
)"
R"(
)"
R"(        regA.s0 = read_imageui(src0_q, (int)(rp + qbase + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 4)).x;
)"
R"(        regA.s1 = read_imageui(src0_q, (int)(rp + qbase + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 5)).x;
)"
R"(        regA.s2 = read_imageui(src0_q, (int)(rp + qbase + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 6)).x;
)"
R"(        regA.s3 = read_imageui(src0_q, (int)(rp + qbase + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 7)).x;
)"
R"(        BMO_DQ_LO(totalSum, as_ushort8(regA), regS, regB);
)"
R"(    }
)"
R"(
)"
R"(    // reduction in local memory, assumes #wave=4
)"
R"(    __local float2 reduceLM[SIMDGROUP_WIDTH * 3];
)"
R"(    if (groupId == 1) reduceLM[SIMDGROUP_WIDTH * 0 + slid] = totalSum;
)"
R"(    if (groupId == 2) reduceLM[SIMDGROUP_WIDTH * 1 + slid] = totalSum;
)"
R"(    if (groupId == 3) reduceLM[SIMDGROUP_WIDTH * 2 + slid] = totalSum;
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(    if (groupId == 0) {
)"
R"(        totalSum += reduceLM[SIMDGROUP_WIDTH * 0 + slid];
)"
R"(        totalSum += reduceLM[SIMDGROUP_WIDTH * 1 + slid];
)"
R"(        totalSum += reduceLM[SIMDGROUP_WIDTH * 2 + slid];
)"
R"(        if (valid) {
)"
R"(            if (rp * 2 + 0 < M) dstc[rp * 2 + 0] = totalSum.s0;
)"
R"(            if (rp * 2 + 1 < M) dstc[rp * 2 + 1] = totalSum.s1;
)"
R"(        } else {
)"
R"(            if (rp * 2 + 0 < M) dstc[rp * 2 + 0] = 0.0f;
)"
R"(            if (rp * 2 + 1 < M) dstc[rp * 2 + 1] = 0.0f;
)"
R"(        }
)"
R"(    }
)"
R"(}
)"
R"(#undef BMO_DQ_HI
)"
R"(#undef BMO_DQ_LO
)"
R"(
)"
R"(// ============================================================================
)"
R"(// [tongyi L4 2026-10-25] q4_0 fused gate+up GEMV + GLU — 克隆 q4_K GLU 族形
)"
R"(//（gemv_noshuffle_q4_k_f32.cl:440），换 q4_0 平面（q image + d half2，无 dm/s）。
)"
R"(// 动机（§20.38/G-776）：can_fuse 硬要求 gate/up 为 Q4_K，Ling 的 dense FFN
)"
R"(// （shared-expert/GDN 侧）是 q4_0/q4_1 ⇒ 融合从不触发。放开 q4_0 = 每次触发
)"
R"(// 省 2 次 GEMV 派发 + 1 次 GLU 派发（740 launch-bound 下 ~400µs/发射）。
)"
R"(// 语义对齐：两段 K-loop 与 dense GEMV 逐行同构（字节级部分和同序）。
)"
R"(// ============================================================================
)"
R"(
)"
R"(inline float q40_glu_act(int glu_op, float g) {
)"
R"(    float act = g;
)"
R"(    if (glu_op == 1) {          // GEGLU (gelu tanh)
)"
R"(        const float GLU_COEF_SQRT_2_OVER_PI = 0.79788456080286535587989211986876f;
)"
R"(        const float GLU_COEF_0P044715        = 0.044715f;
)"
R"(        float x = GLU_COEF_SQRT_2_OVER_PI * g * (1.0f + GLU_COEF_0P044715 * g * g);
)"
R"(        act = 0.5f * g * (1.0f + tanh(x));
)"
R"(    } else if (glu_op == 2) {   // SWIGLU (silu)
)"
R"(        act = g / (1.0f + exp(-g));
)"
R"(    } else if (glu_op == 0) {   // REGLU
)"
R"(        return g * (g > 0.0f);
)"
R"(    } else if (glu_op == 4) {   // GEGLU_ERF
)"
R"(        const float GLU_SQRT_2_INV = 0.70710678118654752440f;
)"
R"(        act = 0.5f * g * (1.0f + erf(g * GLU_SQRT_2_INV));
)"
R"(    } else {                    // GEGLU_QUICK (5)
)"
R"(        const float GLU_QUICK_COEF = 1.702f;
)"
R"(        act = g * (1.0f / (1.0f + exp(GLU_QUICK_COEF * g)));
)"
R"(    }
)"
R"(    return act;
)"
R"(}
)"
R"(
)"
R"(#if defined(ADRENO_GPU) && !defined(GGML_OPENCL_RUSTICL)
)"
R"(REQD_SUBGROUP_SIZE_64
)"
R"(#endif
)"
R"(__kernel void kernel_gemv_noshuffle_q4_0_f32_glu(
)"
R"(        __read_only  image1d_buffer_t src0g_q,   // gate 权重 q 平面（noshuffle）
)"
R"(        __global half2 * src0g_d,                // gate d 平面（行对 half2）
)"
R"(        __read_only  image1d_buffer_t src0u_q,   // up 权重 q 平面
)"
R"(        __global half2 * src0u_d,                // up d 平面
)"
R"(        __read_only  image1d_buffer_t src1,      // 激活（decode 单列）
)"
R"(        __global float * dst,
)"
R"(        ulong offsetd,
)"
R"(        int ne00,                                // K
)"
R"(        int ne01,                                // M（ffn 中间宽）
)"
R"(        int glu_op)
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
R"(    uint LINE_STRIDE_A = M / 2;
)"
R"(    uint gid_s = min(gid, LINE_STRIDE_A - 1);
)"
R"(    uint BLOCK_STRIDE_A = N_SIMDGROUP * M;
)"
R"(
)"
R"(    __private uint4  regA;
)"
R"(    __private half2  regS;
)"
R"(    __private float8 regB;
)"
R"(
)"
R"(    __private float2 gateSum = (float2)(0.0f);
)"
R"(    __private float2 upSum   = (float2)(0.0f);
)"
R"(
)"
R"(    // 两段顺序 K-loop（gate 全程，再 up）——寄存器足迹与单权重 GEMV 持平
)"
R"(    //（q4_K GLU 同法，见其 440 区注释）。
)"
R"(#define Q40_GLU_LOOP(SUM, Q, DD)                                                                       \
)"
R"(    for (uint k = groupId; k < (K / QK4_0); k += N_SIMDGROUP) {                                        \
)"
R"(        regS = DD[gid_s + k * LINE_STRIDE_A];                                                          \
)"
R"(        if (slid < 4) {                                                                                \
)"
R"(            regB.s0123 = read_imagef(src1, (slid * 2 + k * 8));                                        \
)"
R"(            regB.s4567 = read_imagef(src1, (1 + slid * 2 + k * 8));                                    \
)"
R"(        }                                                                                              \
)"
R"(        regA.s0 = read_imageui(Q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 0)).x;                 \
)"
R"(        regA.s1 = read_imageui(Q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 1)).x;                 \
)"
R"(        regA.s2 = read_imageui(Q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 2)).x;                 \
)"
R"(        regA.s3 = read_imageui(Q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 3)).x;                 \
)"
R"(        dequantizeBlockAccum_ns_sgbroadcast_1_hi(SUM, as_ushort8(regA), regS, regB);                   \
)"
R"(        regA.s0 = read_imageui(Q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 4)).x;                 \
)"
R"(        regA.s1 = read_imageui(Q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 5)).x;                 \
)"
R"(        regA.s2 = read_imageui(Q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 6)).x;                 \
)"
R"(        regA.s3 = read_imageui(Q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 7)).x;                 \
)"
R"(        dequantizeBlockAccum_ns_sgbroadcast_1_lo(SUM, as_ushort8(regA), regS, regB);                   \
)"
R"(    }
)"
R"(
)"
R"(    Q40_GLU_LOOP(gateSum, src0g_q, src0g_d)
)"
R"(    Q40_GLU_LOOP(upSum,   src0u_q, src0u_d)
)"
R"(#undef Q40_GLU_LOOP
)"
R"(
)"
R"(    // 跨子组归约：gate(xy)+up(zw) 打包 float4，一趟完成
)"
R"(    __local float4 reduceLM[SIMDGROUP_WIDTH * 3];
)"
R"(    if (groupId == 1) reduceLM[SIMDGROUP_WIDTH * 0 + slid] = (float4)(gateSum, upSum);
)"
R"(    if (groupId == 2) reduceLM[SIMDGROUP_WIDTH * 1 + slid] = (float4)(gateSum, upSum);
)"
R"(    if (groupId == 3) reduceLM[SIMDGROUP_WIDTH * 2 + slid] = (float4)(gateSum, upSum);
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(    if (groupId == 0) {
)"
R"(        float4 p;
)"
R"(        p = reduceLM[SIMDGROUP_WIDTH * 0 + slid]; gateSum += p.xy; upSum += p.zw;
)"
R"(        p = reduceLM[SIMDGROUP_WIDTH * 1 + slid]; gateSum += p.xy; upSum += p.zw;
)"
R"(        p = reduceLM[SIMDGROUP_WIDTH * 2 + slid]; gateSum += p.xy; upSum += p.zw;
)"
R"(
)"
R"(        dst = (__global float *)((__global char *)dst + offsetd);
)"
R"(        if (gid * 2 + 0 < M) dst[gid * 2 + 0] = q40_glu_act(glu_op, gateSum.s0) * upSum.s0;
)"
R"(        if (gid * 2 + 1 < M) dst[gid * 2 + 1] = q40_glu_act(glu_op, gateSum.s1) * upSum.s1;
)"
R"(    }
)"
R"(}
)"
