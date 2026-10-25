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
R"(#define QK_K  256
)"
R"(#define NSUBGROUPS 4
)"
R"(#define SUBGROUP_SIZE 64
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
R"(// scales are transposed: consecutive codes of a row are `stride` apart
)"
R"(inline void get_scale_min_k4(
)"
R"(    int j,
)"
R"(    global const uchar * q,
)"
R"(    uint stride,
)"
R"(    uchar * d,
)"
R"(    uchar * m,
)"
R"(    uchar mask_d6,
)"
R"(    uchar mask_d4,
)"
R"(    uchar mask_hi2
)"
R"() {
)"
R"(    if (j < 4) {
)"
R"(        *d = q[j*stride]     & mask_d6;
)"
R"(        *m = q[(j+4)*stride] & mask_d6;
)"
R"(    } else {
)"
R"(        *d = (q[(j+4)*stride] & mask_d4) | ((q[(j-4)*stride] & mask_hi2) >> 2);
)"
R"(        *m = ((q[(j+4)*stride] >> 4) & mask_d4) | ((q[j*stride] & mask_hi2) >> 2);
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(#define dequantizeBlockAccum_ns_sgbroadcast_1_hi(total_sums, bits4, scale, minv, y) \
)"
R"(    float shared_y; \
)"
R"(    shared_y = SGB_BC(y.s0, 0); \
)"
R"(    total_sums.s0 += ((bits4.s0 & 0x000F) * scale.s0 - minv.s0) * shared_y; \
)"
R"(    total_sums.s1 += ((bits4.s1 & 0x000F) * scale.s1 - minv.s1) * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s1, 0); \
)"
R"(    total_sums.s0 += (((bits4.s0 & 0x00F0) >> 4) * scale.s0 - minv.s0) * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s1 & 0x00F0) >> 4) * scale.s1 - minv.s1) * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s2, 0); \
)"
R"(    total_sums.s0 += (((bits4.s0 & 0x0F00) >> 8) * scale.s0 - minv.s0) * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s1 & 0x0F00) >> 8) * scale.s1 - minv.s1) * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s3, 0); \
)"
R"(    total_sums.s0 += (((bits4.s0 & 0xF000) >> 12) * scale.s0 - minv.s0) * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s1 & 0xF000) >> 12) * scale.s1 - minv.s1) * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s4, 0); \
)"
R"(    total_sums.s0 += ((bits4.s2 & 0x000F) * scale.s0 - minv.s0) * shared_y; \
)"
R"(    total_sums.s1 += ((bits4.s3 & 0x000F) * scale.s1 - minv.s1) * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s5, 0); \
)"
R"(    total_sums.s0 += (((bits4.s2 & 0x00F0) >> 4) * scale.s0 - minv.s0) * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s3 & 0x00F0) >> 4) * scale.s1 - minv.s1) * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s6, 0); \
)"
R"(    total_sums.s0 += (((bits4.s2 & 0x0F00) >> 8) * scale.s0 - minv.s0) * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s3 & 0x0F00) >> 8) * scale.s1 - minv.s1) * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s7, 0); \
)"
R"(    total_sums.s0 += (((bits4.s2 & 0xF000) >> 12) * scale.s0 - minv.s0) * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s3 & 0xF000) >> 12) * scale.s1 - minv.s1) * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s0, 1); \
)"
R"(    total_sums.s0 += ((bits4.s4 & 0x000F) * scale.s0 - minv.s0) * shared_y; \
)"
R"(    total_sums.s1 += ((bits4.s5 & 0x000F) * scale.s1 - minv.s1) * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s1, 1); \
)"
R"(    total_sums.s0 += (((bits4.s4 & 0x00F0) >> 4) * scale.s0 - minv.s0) * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s5 & 0x00F0) >> 4) * scale.s1 - minv.s1) * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s2, 1); \
)"
R"(    total_sums.s0 += (((bits4.s4 & 0x0F00) >> 8) * scale.s0 - minv.s0) * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s5 & 0x0F00) >> 8) * scale.s1 - minv.s1) * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s3, 1); \
)"
R"(    total_sums.s0 += (((bits4.s4 & 0xF000) >> 12) * scale.s0 - minv.s0) * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s5 & 0xF000) >> 12) * scale.s1 - minv.s1) * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s4, 1); \
)"
R"(    total_sums.s0 += ((bits4.s6 & 0x000F) * scale.s0 - minv.s0) * shared_y; \
)"
R"(    total_sums.s1 += ((bits4.s7 & 0x000F) * scale.s1 - minv.s1) * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s5, 1); \
)"
R"(    total_sums.s0 += (((bits4.s6 & 0x00F0) >> 4) * scale.s0 - minv.s0) * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s7 & 0x00F0) >> 4) * scale.s1 - minv.s1) * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s6, 1); \
)"
R"(    total_sums.s0 += (((bits4.s6 & 0x0F00) >> 8) * scale.s0 - minv.s0) * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s7 & 0x0F00) >> 8) * scale.s1 - minv.s1) * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s7, 1); \
)"
R"(    total_sums.s0 += (((bits4.s6 & 0xF000) >> 12) * scale.s0 - minv.s0) * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s7 & 0xF000) >> 12) * scale.s1 - minv.s1) * shared_y; \
)"
R"(
)"
R"(
)"
R"(#define dequantizeBlockAccum_ns_sgbroadcast_1_lo(total_sums, bits4, scale, minv, y) \
)"
R"(    shared_y = SGB_BC(y.s0, 2); \
)"
R"(    total_sums.s0 += ((bits4.s0 & 0x000F) * scale.s0 - minv.s0) * shared_y; \
)"
R"(    total_sums.s1 += ((bits4.s1 & 0x000F) * scale.s1 - minv.s1) * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s1, 2); \
)"
R"(    total_sums.s0 += (((bits4.s0 & 0x00F0) >> 4) * scale.s0 - minv.s0) * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s1 & 0x00F0) >> 4) * scale.s1 - minv.s1) * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s2, 2); \
)"
R"(    total_sums.s0 += (((bits4.s0 & 0x0F00) >> 8) * scale.s0 - minv.s0) * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s1 & 0x0F00) >> 8) * scale.s1 - minv.s1) * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s3, 2); \
)"
R"(    total_sums.s0 += (((bits4.s0 & 0xF000) >> 12) * scale.s0 - minv.s0) * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s1 & 0xF000) >> 12) * scale.s1 - minv.s1) * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s4, 2); \
)"
R"(    total_sums.s0 += ((bits4.s2 & 0x000F) * scale.s0 - minv.s0) * shared_y; \
)"
R"(    total_sums.s1 += ((bits4.s3 & 0x000F) * scale.s1 - minv.s1) * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s5, 2); \
)"
R"(    total_sums.s0 += (((bits4.s2 & 0x00F0) >> 4) * scale.s0 - minv.s0) * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s3 & 0x00F0) >> 4) * scale.s1 - minv.s1) * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s6, 2); \
)"
R"(    total_sums.s0 += (((bits4.s2 & 0x0F00) >> 8) * scale.s0 - minv.s0) * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s3 & 0x0F00) >> 8) * scale.s1 - minv.s1) * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s7, 2); \
)"
R"(    total_sums.s0 += (((bits4.s2 & 0xF000) >> 12) * scale.s0 - minv.s0) * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s3 & 0xF000) >> 12) * scale.s1 - minv.s1) * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s0, 3); \
)"
R"(    total_sums.s0 += ((bits4.s4 & 0x000F) * scale.s0 - minv.s0) * shared_y; \
)"
R"(    total_sums.s1 += ((bits4.s5 & 0x000F) * scale.s1 - minv.s1) * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s1, 3); \
)"
R"(    total_sums.s0 += (((bits4.s4 & 0x00F0) >> 4) * scale.s0 - minv.s0) * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s5 & 0x00F0) >> 4) * scale.s1 - minv.s1) * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s2, 3); \
)"
R"(    total_sums.s0 += (((bits4.s4 & 0x0F00) >> 8) * scale.s0 - minv.s0) * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s5 & 0x0F00) >> 8) * scale.s1 - minv.s1) * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s3, 3); \
)"
R"(    total_sums.s0 += (((bits4.s4 & 0xF000) >> 12) * scale.s0 - minv.s0) * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s5 & 0xF000) >> 12) * scale.s1 - minv.s1) * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s4, 3); \
)"
R"(    total_sums.s0 += ((bits4.s6 & 0x000F) * scale.s0 - minv.s0) * shared_y; \
)"
R"(    total_sums.s1 += ((bits4.s7 & 0x000F) * scale.s1 - minv.s1) * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s5, 3); \
)"
R"(    total_sums.s0 += (((bits4.s6 & 0x00F0) >> 4) * scale.s0 - minv.s0) * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s7 & 0x00F0) >> 4) * scale.s1 - minv.s1) * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s6, 3); \
)"
R"(    total_sums.s0 += (((bits4.s6 & 0x0F00) >> 8) * scale.s0 - minv.s0) * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s7 & 0x0F00) >> 8) * scale.s1 - minv.s1) * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s7, 3); \
)"
R"(    total_sums.s0 += (((bits4.s6 & 0xF000) >> 12) * scale.s0 - minv.s0) * shared_y; \
)"
R"(    total_sums.s1 += (((bits4.s7 & 0xF000) >> 12) * scale.s1 - minv.s1) * shared_y; \
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
R"(    total_sums.s0 += ((bits4.s0 & 0x000F)         * scale.s0 - minv.s0) * shared_y.s0; \
)"
R"(    total_sums.s0 += (((bits4.s0 & 0x00F0) >> 4)  * scale.s0 - minv.s0) * shared_y.s1; \
)"
R"(    total_sums.s0 += (((bits4.s0 & 0x0F00) >> 8)  * scale.s0 - minv.s0) * shared_y.s2; \
)"
R"(    total_sums.s0 += (((bits4.s0 & 0xF000) >> 12) * scale.s0 - minv.s0) * shared_y.s3; \
)"
R"(    total_sums.s0 += ((bits4.s2 & 0x000F)         * scale.s0 - minv.s0) * shared_y.s4; \
)"
R"(    total_sums.s0 += (((bits4.s2 & 0x00F0) >> 4)  * scale.s0 - minv.s0) * shared_y.s5; \
)"
R"(    total_sums.s0 += (((bits4.s2 & 0x0F00) >> 8)  * scale.s0 - minv.s0) * shared_y.s6; \
)"
R"(    total_sums.s0 += (((bits4.s2 & 0xF000) >> 12) * scale.s0 - minv.s0) * shared_y.s7; \
)"
R"(    total_sums.s1 += ((bits4.s1 & 0x000F)         * scale.s1 - minv.s1) * shared_y.s0; \
)"
R"(    total_sums.s1 += (((bits4.s1 & 0x00F0) >> 4)  * scale.s1 - minv.s1) * shared_y.s1; \
)"
R"(    total_sums.s1 += (((bits4.s1 & 0x0F00) >> 8)  * scale.s1 - minv.s1) * shared_y.s2; \
)"
R"(    total_sums.s1 += (((bits4.s1 & 0xF000) >> 12) * scale.s1 - minv.s1) * shared_y.s3; \
)"
R"(    total_sums.s1 += ((bits4.s3 & 0x000F)         * scale.s1 - minv.s1) * shared_y.s4; \
)"
R"(    total_sums.s1 += (((bits4.s3 & 0x00F0) >> 4)  * scale.s1 - minv.s1) * shared_y.s5; \
)"
R"(    total_sums.s1 += (((bits4.s3 & 0x0F00) >> 8)  * scale.s1 - minv.s1) * shared_y.s6; \
)"
R"(    total_sums.s1 += (((bits4.s3 & 0xF000) >> 12) * scale.s1 - minv.s1) * shared_y.s7; \
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
R"(    total_sums.s0 += ((bits4.s4 & 0x000F)         * scale.s0 - minv.s0) * shared_y.s0; \
)"
R"(    total_sums.s0 += (((bits4.s4 & 0x00F0) >> 4)  * scale.s0 - minv.s0) * shared_y.s1; \
)"
R"(    total_sums.s0 += (((bits4.s4 & 0x0F00) >> 8)  * scale.s0 - minv.s0) * shared_y.s2; \
)"
R"(    total_sums.s0 += (((bits4.s4 & 0xF000) >> 12) * scale.s0 - minv.s0) * shared_y.s3; \
)"
R"(    total_sums.s0 += ((bits4.s6 & 0x000F)         * scale.s0 - minv.s0) * shared_y.s4; \
)"
R"(    total_sums.s0 += (((bits4.s6 & 0x00F0) >> 4)  * scale.s0 - minv.s0) * shared_y.s5; \
)"
R"(    total_sums.s0 += (((bits4.s6 & 0x0F00) >> 8)  * scale.s0 - minv.s0) * shared_y.s6; \
)"
R"(    total_sums.s0 += (((bits4.s6 & 0xF000) >> 12) * scale.s0 - minv.s0) * shared_y.s7; \
)"
R"(    total_sums.s1 += ((bits4.s5 & 0x000F)         * scale.s1 - minv.s1) * shared_y.s0; \
)"
R"(    total_sums.s1 += (((bits4.s5 & 0x00F0) >> 4)  * scale.s1 - minv.s1) * shared_y.s1; \
)"
R"(    total_sums.s1 += (((bits4.s5 & 0x0F00) >> 8)  * scale.s1 - minv.s1) * shared_y.s2; \
)"
R"(    total_sums.s1 += (((bits4.s5 & 0xF000) >> 12) * scale.s1 - minv.s1) * shared_y.s3; \
)"
R"(    total_sums.s1 += ((bits4.s7 & 0x000F)         * scale.s1 - minv.s1) * shared_y.s4; \
)"
R"(    total_sums.s1 += (((bits4.s7 & 0x00F0) >> 4)  * scale.s1 - minv.s1) * shared_y.s5; \
)"
R"(    total_sums.s1 += (((bits4.s7 & 0x0F00) >> 8)  * scale.s1 - minv.s1) * shared_y.s6; \
)"
R"(    total_sums.s1 += (((bits4.s7 & 0xF000) >> 12) * scale.s1 - minv.s1) * shared_y.s7; \
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
R"(    total_sums.s0 += ((bits4.s0 & 0x000F)         * scale.s0 - minv.s0) * shared_y.s0; \
)"
R"(    total_sums.s0 += (((bits4.s0 & 0x00F0) >> 4)  * scale.s0 - minv.s0) * shared_y.s1; \
)"
R"(    total_sums.s0 += (((bits4.s0 & 0x0F00) >> 8)  * scale.s0 - minv.s0) * shared_y.s2; \
)"
R"(    total_sums.s0 += (((bits4.s0 & 0xF000) >> 12) * scale.s0 - minv.s0) * shared_y.s3; \
)"
R"(    total_sums.s0 += ((bits4.s2 & 0x000F)         * scale.s0 - minv.s0) * shared_y.s4; \
)"
R"(    total_sums.s0 += (((bits4.s2 & 0x00F0) >> 4)  * scale.s0 - minv.s0) * shared_y.s5; \
)"
R"(    total_sums.s0 += (((bits4.s2 & 0x0F00) >> 8)  * scale.s0 - minv.s0) * shared_y.s6; \
)"
R"(    total_sums.s0 += (((bits4.s2 & 0xF000) >> 12) * scale.s0 - minv.s0) * shared_y.s7; \
)"
R"(    total_sums.s1 += ((bits4.s1 & 0x000F)         * scale.s1 - minv.s1) * shared_y.s0; \
)"
R"(    total_sums.s1 += (((bits4.s1 & 0x00F0) >> 4)  * scale.s1 - minv.s1) * shared_y.s1; \
)"
R"(    total_sums.s1 += (((bits4.s1 & 0x0F00) >> 8)  * scale.s1 - minv.s1) * shared_y.s2; \
)"
R"(    total_sums.s1 += (((bits4.s1 & 0xF000) >> 12) * scale.s1 - minv.s1) * shared_y.s3; \
)"
R"(    total_sums.s1 += ((bits4.s3 & 0x000F)         * scale.s1 - minv.s1) * shared_y.s4; \
)"
R"(    total_sums.s1 += (((bits4.s3 & 0x00F0) >> 4)  * scale.s1 - minv.s1) * shared_y.s5; \
)"
R"(    total_sums.s1 += (((bits4.s3 & 0x0F00) >> 8)  * scale.s1 - minv.s1) * shared_y.s6; \
)"
R"(    total_sums.s1 += (((bits4.s3 & 0xF000) >> 12) * scale.s1 - minv.s1) * shared_y.s7; \
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
R"(    total_sums.s0 += ((bits4.s4 & 0x000F)         * scale.s0 - minv.s0) * shared_y.s0; \
)"
R"(    total_sums.s0 += (((bits4.s4 & 0x00F0) >> 4)  * scale.s0 - minv.s0) * shared_y.s1; \
)"
R"(    total_sums.s0 += (((bits4.s4 & 0x0F00) >> 8)  * scale.s0 - minv.s0) * shared_y.s2; \
)"
R"(    total_sums.s0 += (((bits4.s4 & 0xF000) >> 12) * scale.s0 - minv.s0) * shared_y.s3; \
)"
R"(    total_sums.s0 += ((bits4.s6 & 0x000F)         * scale.s0 - minv.s0) * shared_y.s4; \
)"
R"(    total_sums.s0 += (((bits4.s6 & 0x00F0) >> 4)  * scale.s0 - minv.s0) * shared_y.s5; \
)"
R"(    total_sums.s0 += (((bits4.s6 & 0x0F00) >> 8)  * scale.s0 - minv.s0) * shared_y.s6; \
)"
R"(    total_sums.s0 += (((bits4.s6 & 0xF000) >> 12) * scale.s0 - minv.s0) * shared_y.s7; \
)"
R"(    total_sums.s1 += ((bits4.s5 & 0x000F)         * scale.s1 - minv.s1) * shared_y.s0; \
)"
R"(    total_sums.s1 += (((bits4.s5 & 0x00F0) >> 4)  * scale.s1 - minv.s1) * shared_y.s1; \
)"
R"(    total_sums.s1 += (((bits4.s5 & 0x0F00) >> 8)  * scale.s1 - minv.s1) * shared_y.s2; \
)"
R"(    total_sums.s1 += (((bits4.s5 & 0xF000) >> 12) * scale.s1 - minv.s1) * shared_y.s3; \
)"
R"(    total_sums.s1 += ((bits4.s7 & 0x000F)         * scale.s1 - minv.s1) * shared_y.s4; \
)"
R"(    total_sums.s1 += (((bits4.s7 & 0x00F0) >> 4)  * scale.s1 - minv.s1) * shared_y.s5; \
)"
R"(    total_sums.s1 += (((bits4.s7 & 0x0F00) >> 8)  * scale.s1 - minv.s1) * shared_y.s6; \
)"
R"(    total_sums.s1 += (((bits4.s7 & 0xF000) >> 12) * scale.s1 - minv.s1) * shared_y.s7; \
)"
R"(
)"
R"(#ifdef ADRENO_GPU
)"
R"(REQD_SUBGROUP_SIZE_64
)"
R"(#endif
)"
R"(kernel void kernel_gemv_noshuffle_q4_k_f32(
)"
R"(        read_only  image1d_buffer_t src0_q,
)"
R"(        global half2  * src0_d,
)"
R"(        global half2  * src0_m,
)"
R"(        global uchar  * src0_s,
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
R"(        uchar mask_d6,
)"
R"(        uchar mask_d4,
)"
R"(        uchar mask_hi2)
)"
R"({
)"
R"(    uint groupId = get_local_id(1);
)"
R"(    uint gid     = get_global_id(0);
)"
R"(    ushort slid  = get_sub_group_local_id();
)"
R"(    // K-split factor = #subgroups in the WG. Read from the launch (NOT a compile
)"
R"(    // constant) so small-M projections (Kcur/Vcur/Qcur) can dispatch a wider
)"
R"(    // K-split (more waves/SP -> latency hiding) while large-M keeps 4. The
)"
R"(    // physical weight layout stride below is INDEPENDENT of this (see BLOCK_STRIDE_A).
)"
R"(    uint nsg = get_local_size(1);
)"
R"(    MATERIALIZE_WG(nsg);
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
R"(    // Physical per-K-block stride in the packed image: 8 uints/block-row-pair *
)"
R"(    // (M/2) row-pairs = 4*M uints. This is a layout constant, not tied to nsg.
)"
R"(    uint BLOCK_STRIDE_A = 4 * M;
)"
R"(    uint scales_per_row = (K / QK_K) * 12;
)"
R"(
)"
R"(    // The x-grid is padded to CEIL_DIV(ne01/2,64)*64, so when ne01 % 128 != 0 the
)"
R"(    // tail lanes hold gid >= ne01/2. The output stores below are guarded, but the
)"
R"(    // input fetches are not: src0_d and src0_m are raw global half2 pointers,
)"
R"(    // src0_s is a raw global uchar pointer, and read_imageui on an
)"
R"(    // image1d_buffer_t is UNDEFINED out of range -- an image clamps only for
)"
R"(    // SAMPLER reads, which these are not. Those lanes therefore read past the end
)"
R"(    // of all three allocations. For a [2816, 2112] weight (2112 % 128 == 64) the
)"
R"(    // top tail lane is gid = 1087 while only gid < 1056 is backed, and it runs
)"
R"(    // 32 half2 past src0_d/src0_m, 31 uints past the quant image, and 63 bytes
)"
R"(    // past src0_s.
)"
R"(    //
)"
R"(    // Clamp the row used for every fetch. The lanes stay ACTIVE, which the
)"
R"(    // sub_group_broadcast in the dequant macros requires, and their results are
)"
R"(    // still discarded by the existing output guard. No-op and byte-identical
)"
R"(    // whenever ne01 % 128 == 0.
)"
R"(    uint gid_s = min(gid, LINE_STRIDE_A - 1);
)"
R"(
)"
R"(    private uint4     regA;
)"
R"(    private float2    regS;
)"
R"(    private float2    regM;
)"
R"(    private float8    regB;
)"
R"(
)"
R"(    private float2 totalSum = (float2)(0.0f);
)"
R"(
)"
R"(    for (uint k = groupId; k < (K / 32); k += nsg) {
)"
R"(        uint sb = k / 8;
)"
R"(        uint j  = k % 8;
)"
R"(
)"
R"(        half2 d   = src0_d[gid_s + sb * LINE_STRIDE_A];
)"
R"(        half2 dm  = src0_m[gid_s + sb * LINE_STRIDE_A];
)"
R"(
)"
R"(        global const uchar * sc0 = src0_s + sb * 12 * M + 2 * gid_s;
)"
R"(        global const uchar * sc1 = sc0 + 1;
)"
R"(
)"
R"(        uchar sv0, mn0, sv1, mn1;
)"
R"(        get_scale_min_k4(j, sc0, M, &sv0, &mn0, mask_d6, mask_d4, mask_hi2);
)"
R"(        get_scale_min_k4(j, sc1, M, &sv1, &mn1, mask_d6, mask_d4, mask_hi2);
)"
R"(
)"
R"(        regS = convert_float2(d)  * convert_float2((uchar2)(sv0, sv1));
)"
R"(        regM = convert_float2(dm) * convert_float2((uchar2)(mn0, mn1));
)"
R"(
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
R"(        dequantizeBlockAccum_ns_sgbroadcast_8_hi(totalSum, as_ushort8(regA), regS, regM, regB);
)"
R"(#else
)"
R"(        dequantizeBlockAccum_ns_sgbroadcast_1_hi(totalSum, as_ushort8(regA), regS, regM, regB);
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
R"(        dequantizeBlockAccum_ns_sgbroadcast_8_lo(totalSum, as_ushort8(regA), regS, regM, regB);
)"
R"(#else
)"
R"(        dequantizeBlockAccum_ns_sgbroadcast_1_lo(totalSum, as_ushort8(regA), regS, regM, regB);
)"
R"(#endif // VECTOR_SUB_GROUP_BROADCAST
)"
R"(    }
)"
R"(
)"
R"(    // Cross-subgroup reduction in local memory. Generalized to nsg subgroups
)"
R"(    // (was a hard-coded 4-wave unroll). Sized for up to 16 subgroups (the widest
)"
R"(    // K-split we dispatch for small M). At nsg==4 the accumulation order is
)"
R"(    // identical to the original unroll -> byte-identical for the large-M path.
)"
R"(    local float2 reduceLM[SUBGROUP_SIZE * 15];
)"
R"(    if (groupId > 0) {
)"
R"(        reduceLM[SUBGROUP_SIZE * (groupId - 1) + slid] = totalSum;
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
R"(        for (uint i = 0; i < nsg - 1; ++i) {
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
R"(// --- Fused gate+up GEMV + GLU epilogue (FFN) ------------------------------------
)"
R"(// Folds the FFN's two decode GEMVs (ffn_gate, ffn_up) and the following GLU into a
)"
R"(// SINGLE dispatch: {MUL_MAT(Wg,x), MUL_MAT(Wu,x), GLU}. Both matmuls share the same
)"
R"(// activation x (ffn_norm), so the activation image read is issued ONCE per K-block
)"
R"(// and reused for the gate and up dot products (the per-op path re-reads it twice and
)"
R"(// also materializes the two full ffn-wide intermediates to global, which the GLU
)"
R"(// then re-reads). The gate/up partial sums are accumulated in the SAME per-fiber
)"
R"(// order and reduced in the SAME cross-subgroup order as the standalone GEMV, and the
)"
R"(// GLU formula is the exact scalar expression from kernels/glu.cl, so the output is
)"
R"(// BYTE-IDENTICAL to the per-op matmul+matmul+glu path -> safe to default on.
)"
R"(//   glu_op: REGLU=0, GEGLU=1, SWIGLU=2, GEGLU_ERF=4, GEGLU_QUICK=5 (ggml_glu_op).
)"
R"(// Weights: src0g_* = gate (= GLU src[0]); src0u_* = up (= GLU src[1]).
)"
R"(#define GLU_GEGLU_COEF_A      0.044715f
)"
R"(#define GLU_SQRT_2_OVER_PI    0.79788456080286535587989211986876f
)"
R"(#define GLU_SQRT_2_INV        0.70710678118654752440084436210484f
)"
R"(#define GLU_QUICK_COEF       -1.702f
)"
R"(
)"
R"(inline float glu_apply(int glu_op, float g, float u) {
)"
R"(    float act;
)"
R"(    if (glu_op == 1) {        // GEGLU (tanh-approx gelu)
)"
R"(        act = 0.5f*g*(1.0f + tanh(GLU_SQRT_2_OVER_PI*g*(1.0f + GLU_GEGLU_COEF_A*g*g)));
)"
R"(    } else if (glu_op == 2) { // SWIGLU (silu)
)"
R"(        act = g / (1.0f + exp(-g));
)"
R"(    } else if (glu_op == 0) { // REGLU
)"
R"(        return g*u*(g > 0.0f);
)"
R"(    } else if (glu_op == 4) { // GEGLU_ERF
)"
R"(        act = 0.5f*g*(1.0f + erf(g*GLU_SQRT_2_INV));
)"
R"(    } else {                  // GEGLU_QUICK (glu_op == 5)
)"
R"(        act = g*(1.0f/(1.0f + exp(GLU_QUICK_COEF*g)));
)"
R"(    }
)"
R"(    return act*u;
)"
R"(}
)"
R"(
)"
R"(#ifdef ADRENO_GPU
)"
R"(REQD_SUBGROUP_SIZE_64
)"
R"(#endif
)"
R"(kernel void kernel_gemv_noshuffle_q4_k_f32_glu(
)"
R"(        read_only  image1d_buffer_t src0g_q,
)"
R"(        global half2  * src0g_d,
)"
R"(        global half2  * src0g_m,
)"
R"(        global uchar  * src0g_s,
)"
R"(        read_only  image1d_buffer_t src0u_q,
)"
R"(        global half2  * src0u_d,
)"
R"(        global half2  * src0u_m,
)"
R"(        global uchar  * src0u_s,
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
R"(        int glu_op,
)"
R"(        uchar mask_d6,
)"
R"(        uchar mask_d4,
)"
R"(        uchar mask_hi2)
)"
R"({
)"
R"(    uint groupId = get_local_id(1);
)"
R"(    uint gid     = get_global_id(0);
)"
R"(    ushort slid  = get_sub_group_local_id();
)"
R"(    uint nsg     = get_local_size(1);
)"
R"(    MATERIALIZE_WG(nsg);
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
R"(    uint BLOCK_STRIDE_A = 4 * M;
)"
R"(
)"
R"(    private uint4  regA;
)"
R"(    private float2  regS, regM;
)"
R"(    private float8 regB;
)"
R"(
)"
R"(    private float2 gateSum = (float2)(0.0f);
)"
R"(    private float2 upSum   = (float2)(0.0f);
)"
R"(
)"
R"(    // Two SEQUENTIAL K-loops (gate fully, then up). Keeping only one weight's
)"
R"(    // working set live at a time holds the kernel's register footprint at ~the
)"
R"(    // base single-weight GEMV's, so its max WG stays 1024 (16 subgroups) and the
)"
R"(    // per-subgroup K-split matches the standalone wide GEMV exactly -> the gate
)"
R"(    // and up partial sums are BYTE-IDENTICAL to the per-op path. The macro body
)"
R"(    // is the base kernel's inner loop verbatim, parameterized by weight source.
)"
R"(#define Q4K_GLU_LOOP(SUM, Q, DD, MM, SS)                                                       \
)"
R"(    for (uint k = groupId; k < (K / 32); k += nsg) {                                           \
)"
R"(        uint sb = k / 8;                                                                       \
)"
R"(        uint j  = k % 8;                                                                       \
)"
R"(        half2 d   = DD[gid_s + sb * LINE_STRIDE_A];                                            \
)"
R"(        half2 dm  = MM[gid_s + sb * LINE_STRIDE_A];                                            \
)"
R"(        global const uchar * sc0 = SS + sb * 12 * M + 2 * gid_s;                               \
)"
R"(        global const uchar * sc1 = sc0 + 1;                                                    \
)"
R"(        uchar sv0, mn0, sv1, mn1;                                                              \
)"
R"(        get_scale_min_k4(j, sc0, M, &sv0, &mn0, mask_d6, mask_d4, mask_hi2);                      \
)"
R"(        get_scale_min_k4(j, sc1, M, &sv1, &mn1, mask_d6, mask_d4, mask_hi2);                      \
)"
R"(        regS = convert_float2(d)  * convert_float2((uchar2)(sv0, sv1));         \
)"
R"(        regM = convert_float2(dm) * convert_float2((uchar2)(mn0, mn1));         \
)"
R"(        if (slid < 4) {                                                                        \
)"
R"(            regB.s0123 = read_imagef(src1, (slid * 2 + k * 8));                                \
)"
R"(            regB.s4567 = read_imagef(src1, (1 + slid * 2 + k * 8));                            \
)"
R"(        }                                                                                      \
)"
R"(        regA.s0 = read_imageui(Q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 0)).x;           \
)"
R"(        regA.s1 = read_imageui(Q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 1)).x;           \
)"
R"(        regA.s2 = read_imageui(Q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 2)).x;           \
)"
R"(        regA.s3 = read_imageui(Q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 3)).x;           \
)"
R"(        DEQ_HI(SUM, as_ushort8(regA), regS, regM, regB);                                       \
)"
R"(        regA.s0 = read_imageui(Q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 4)).x;           \
)"
R"(        regA.s1 = read_imageui(Q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 5)).x;           \
)"
R"(        regA.s2 = read_imageui(Q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 6)).x;           \
)"
R"(        regA.s3 = read_imageui(Q, (gid_s + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 7)).x;           \
)"
R"(        DEQ_LO(SUM, as_ushort8(regA), regS, regM, regB);                                       \
)"
R"(    }
)"
R"(
)"
R"(#ifdef VECTOR_SUB_GROUP_BROADCAST
)"
R"(#define DEQ_HI dequantizeBlockAccum_ns_sgbroadcast_8_hi
)"
R"(#define DEQ_LO dequantizeBlockAccum_ns_sgbroadcast_8_lo
)"
R"(#else
)"
R"(#define DEQ_HI dequantizeBlockAccum_ns_sgbroadcast_1_hi
)"
R"(#define DEQ_LO dequantizeBlockAccum_ns_sgbroadcast_1_lo
)"
R"(#endif
)"
R"(
)"
R"(    Q4K_GLU_LOOP(gateSum, src0g_q, src0g_d, src0g_m, src0g_s)
)"
R"(    Q4K_GLU_LOOP(upSum,   src0u_q, src0u_d, src0u_m, src0u_s)
)"
R"(
)"
R"(#undef DEQ_HI
)"
R"(#undef DEQ_LO
)"
R"(#undef Q4K_GLU_LOOP
)"
R"(
)"
R"(    // Cross-subgroup reduction in local memory. Packs gate (xy) + up (zw) into a
)"
R"(    // float4 so both reduce in one pass; summation order matches the base GEMV's
)"
R"(    // per-channel loop -> byte-identical partial sums.
)"
R"(    local float4 reduceLM[SUBGROUP_SIZE * 15];
)"
R"(    if (groupId > 0) {
)"
R"(        reduceLM[SUBGROUP_SIZE * (groupId - 1) + slid] = (float4)(gateSum, upSum);
)"
R"(    }
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(    if (groupId == 0) {
)"
R"(        for (uint i = 0; i < nsg - 1; ++i) {
)"
R"(            float4 p = reduceLM[SUBGROUP_SIZE * i + slid];
)"
R"(            gateSum += p.xy;
)"
R"(            upSum   += p.zw;
)"
R"(        }
)"
R"(        dst = (global float*)((global char*)dst + offsetd);
)"
R"(        if (gid < LINE_STRIDE_A) {
)"
R"(            dst[gid * 2 + 0] = glu_apply(glu_op, gateSum.s0, upSum.s0);
)"
R"(            dst[gid * 2 + 1] = glu_apply(glu_op, gateSum.s1, upSum.s1);
)"
R"(        }
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(// --- Split-K-across-workgroups decode GEMV (small-M projections) ----------------
)"
R"(// A single-token GEMV makes only ceil(M/2/64) workgroups; a WG runs on one Adreno
)"
R"(// compute unit, so for small M (Kcur/Vcur, M=512 -> 4 WGs) most of the 16 CUs sit
)"
R"(// idle and the matmul is bandwidth-starved even with a wide intra-WG K-split. This
)"
R"(// variant adds a SECOND grid dimension of `ksplit` workgroups that each reduce a
)"
R"(// disjoint slice of K and write a per-slice partial; kernel_gemv_splitk_reduce_f32
)"
R"(// then sums the partials into dst. Identical math/layout to the base kernel
)"
R"(// (physical block stride 4*M, get_scale_min_k4) -> coherent. Gated host-side to
)"
R"(// M<=1024 (M>=2048
)"
R"(// already fills the CUs and the extra reduce dispatch only hurts).
)"
R"(#ifdef ADRENO_GPU
)"
R"(REQD_SUBGROUP_SIZE_64
)"
R"(#endif
)"
R"(kernel void kernel_gemv_noshuffle_q4_k_f32_splitk(
)"
R"(        read_only  image1d_buffer_t src0_q,
)"
R"(        global half2  * src0_d,
)"
R"(        global half2  * src0_m,
)"
R"(        global uchar  * src0_s,
)"
R"(        read_only  image1d_buffer_t src1,
)"
R"(        global float * partial,          // [ksplit * M], slice-major
)"
R"(        int ne00,
)"
R"(        int ne01,
)"
R"(        uchar mask_d6,
)"
R"(        uchar mask_d4,
)"
R"(        uchar mask_hi2)
)"
R"({
)"
R"(    uint groupId = get_local_id(1);
)"
R"(    uint gid     = get_global_id(0);
)"
R"(    ushort slid  = get_sub_group_local_id();
)"
R"(    uint nsg     = get_local_size(1);
)"
R"(    MATERIALIZE_WG(nsg);
)"
R"(    uint ksplit  = get_num_groups(1);
)"
R"(    uint kslice  = get_group_id(1);
)"
R"(
)"
R"(    uint K = ne00;
)"
R"(    uint M = ne01;
)"
R"(    uint LINE_STRIDE_A  = M / 2;
)"
R"(    uint BLOCK_STRIDE_A = 4 * M;      // physical, independent of the K-split
)"
R"(
)"
R"(    // Keep tail lanes active for subgroup ops, but read a valid weight row.
)"
R"(    uint gid_s = min(gid, LINE_STRIDE_A - 1);
)"
R"(
)"
R"(    private uint4  regA;
)"
R"(    private float2  regS, regM;
)"
R"(    private float8 regB;
)"
R"(    private float2 totalSum = (float2)(0.0f);
)"
R"(
)"
R"(    // each (kslice, subgroup) pair owns a disjoint set of K-blocks
)"
R"(    for (uint k = kslice * nsg + groupId; k < (K / 32); k += ksplit * nsg) {
)"
R"(        uint sb = k / 8;
)"
R"(        uint j  = k % 8;
)"
R"(        half2 d   = src0_d[gid_s + sb * LINE_STRIDE_A];
)"
R"(        half2 dm  = src0_m[gid_s + sb * LINE_STRIDE_A];
)"
R"(        global const uchar * sc0 = src0_s + sb * 12 * M + 2 * gid_s;
)"
R"(        global const uchar * sc1 = sc0 + 1;
)"
R"(        uchar sv0, mn0, sv1, mn1;
)"
R"(        get_scale_min_k4(j, sc0, M, &sv0, &mn0, mask_d6, mask_d4, mask_hi2);
)"
R"(        get_scale_min_k4(j, sc1, M, &sv1, &mn1, mask_d6, mask_d4, mask_hi2);
)"
R"(        regS = convert_float2(d)  * convert_float2((uchar2)(sv0, sv1));
)"
R"(        regM = convert_float2(dm) * convert_float2((uchar2)(mn0, mn1));
)"
R"(        if (slid < 4) {
)"
R"(            regB.s0123 = read_imagef(src1, (slid * 2 + k * 8));
)"
R"(            regB.s4567 = read_imagef(src1, (1 + slid * 2 + k * 8));
)"
R"(        }
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
R"(        dequantizeBlockAccum_ns_sgbroadcast_8_hi(totalSum, as_ushort8(regA), regS, regM, regB);
)"
R"(#else
)"
R"(        dequantizeBlockAccum_ns_sgbroadcast_1_hi(totalSum, as_ushort8(regA), regS, regM, regB);
)"
R"(#endif
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
R"(        dequantizeBlockAccum_ns_sgbroadcast_8_lo(totalSum, as_ushort8(regA), regS, regM, regB);
)"
R"(#else
)"
R"(        dequantizeBlockAccum_ns_sgbroadcast_1_lo(totalSum, as_ushort8(regA), regS, regM, regB);
)"
R"(#endif
)"
R"(    }
)"
R"(
)"
R"(    local float2 reduceLM[SUBGROUP_SIZE * 15];
)"
R"(    if (groupId > 0) {
)"
R"(        reduceLM[SUBGROUP_SIZE * (groupId - 1) + slid] = totalSum;
)"
R"(    }
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(    if (groupId == 0) {
)"
R"(        for (uint i = 0; i < nsg - 1; ++i) {
)"
R"(            totalSum += reduceLM[SUBGROUP_SIZE * i + slid];
)"
R"(        }
)"
R"(        // Keep tail stores inside this K-slice.
)"
R"(        if (gid * 2 + 0 < M) partial[kslice * M + gid * 2 + 0] = totalSum.s0;
)"
R"(        if (gid * 2 + 1 < M) partial[kslice * M + gid * 2 + 1] = totalSum.s1;
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(// Sum the per-slice partials [ksplit * M] into dst[M]; applies the dst byte offset.
)"
R"(kernel void kernel_gemv_splitk_reduce_f32(
)"
R"(        global float * partial,
)"
R"(        global float * dst,
)"
R"(        ulong offsetd,
)"
R"(        int   ne01,         // M
)"
R"(        int   ksplit)
)"
R"({
)"
R"(    uint r = get_global_id(0);
)"
R"(    if (r >= (uint)ne01) return;
)"
R"(    float acc = 0.0f;
)"
R"(    for (uint s = 0; s < (uint)ksplit; ++s) {
)"
R"(        acc += partial[s * (uint)ne01 + r];
)"
R"(    }
)"
R"(    dst = (global float*)((global char*)dst + offsetd);
)"
R"(    dst[r] = acc;
)"
R"(}
)"
R"(
)"
R"(
)"
R"(// --- Dequant-once macros for the mc3 verify GEMV (Q4K_MC3_DEQUANT_ONCE) ---
)"
R"(// The inline dequantizeBlockAccum_* macros recompute the dequantized weight
)"
R"(// ((code & mask)>>shift)*scale - minv ONCE PER COLUMN (3x), and the flat
)"
R"(// 32-FMA unroll spills ~430 B of temporaries. These macros split the work:
)"
R"(// DEQUANT_Q4K_BLOCK computes the 16 weights/row of one 32-block ONCE into a
)"
R"(// half2[] (row0 in .s0, row1 in .s1) — stored as half, the exact type the
)"
R"(// inline expression yields (int*half-half), so no extra rounding. MAC_Q4K_BLOCK
)"
R"(// then accumulates them against a column's broadcast activation in the SAME
)"
R"(// per-accumulator order as the inline macro. Each weight value and each
)"
R"(// accumulator's add-chain is bit-for-bit identical => byte-identical output,
)"
R"(// while the dequant ALU drops 3x->1x and the live set shrinks. Requires the
)"
R"(// Qualcomm vector sub_group_broadcast (float8); enabled opt-in on Adreno.
)"
R"(#define DEQ_Q4K_HALF2(b0, b1, msk, sh, scale, minv) \
)"
R"(    (half2)( ((b0 & msk) >> sh) * scale.s0 - minv.s0, \
)"
R"(             ((b1 & msk) >> sh) * scale.s1 - minv.s1 )
)"
R"(
)"
R"(#define DEQUANT_Q4K_BLOCK(wq, bits, scale, minv) \
)"
R"(    wq[0]  = DEQ_Q4K_HALF2(bits.s0, bits.s1, 0x000F, 0,  scale, minv); \
)"
R"(    wq[1]  = DEQ_Q4K_HALF2(bits.s0, bits.s1, 0x00F0, 4,  scale, minv); \
)"
R"(    wq[2]  = DEQ_Q4K_HALF2(bits.s0, bits.s1, 0x0F00, 8,  scale, minv); \
)"
R"(    wq[3]  = DEQ_Q4K_HALF2(bits.s0, bits.s1, 0xF000, 12, scale, minv); \
)"
R"(    wq[4]  = DEQ_Q4K_HALF2(bits.s2, bits.s3, 0x000F, 0,  scale, minv); \
)"
R"(    wq[5]  = DEQ_Q4K_HALF2(bits.s2, bits.s3, 0x00F0, 4,  scale, minv); \
)"
R"(    wq[6]  = DEQ_Q4K_HALF2(bits.s2, bits.s3, 0x0F00, 8,  scale, minv); \
)"
R"(    wq[7]  = DEQ_Q4K_HALF2(bits.s2, bits.s3, 0xF000, 12, scale, minv); \
)"
R"(    wq[8]  = DEQ_Q4K_HALF2(bits.s4, bits.s5, 0x000F, 0,  scale, minv); \
)"
R"(    wq[9]  = DEQ_Q4K_HALF2(bits.s4, bits.s5, 0x00F0, 4,  scale, minv); \
)"
R"(    wq[10] = DEQ_Q4K_HALF2(bits.s4, bits.s5, 0x0F00, 8,  scale, minv); \
)"
R"(    wq[11] = DEQ_Q4K_HALF2(bits.s4, bits.s5, 0xF000, 12, scale, minv); \
)"
R"(    wq[12] = DEQ_Q4K_HALF2(bits.s6, bits.s7, 0x000F, 0,  scale, minv); \
)"
R"(    wq[13] = DEQ_Q4K_HALF2(bits.s6, bits.s7, 0x00F0, 4,  scale, minv); \
)"
R"(    wq[14] = DEQ_Q4K_HALF2(bits.s6, bits.s7, 0x0F00, 8,  scale, minv); \
)"
R"(    wq[15] = DEQ_Q4K_HALF2(bits.s6, bits.s7, 0xF000, 12, scale, minv);
)"
R"(
)"
R"(// ln0/ln1 = the two source lanes whose activation float8 this block consumes
)"
R"(// (0,1 for the hi block, 2,3 for the lo block — matching the inline _hi/_lo).
)"
R"(#define MAC_Q4K_BLOCK(ts, wq, y, ln0, ln1) { \
)"
R"(    float8 sy; \
)"
R"(    sy.s0 = SGB_BC(y.s0, ln0); \
)"
R"(    sy.s1 = SGB_BC(y.s1, ln0); \
)"
R"(    sy.s2 = SGB_BC(y.s2, ln0); \
)"
R"(    sy.s3 = SGB_BC(y.s3, ln0); \
)"
R"(    sy.s4 = SGB_BC(y.s4, ln0); \
)"
R"(    sy.s5 = SGB_BC(y.s5, ln0); \
)"
R"(    sy.s6 = SGB_BC(y.s6, ln0); \
)"
R"(    sy.s7 = SGB_BC(y.s7, ln0); \
)"
R"(    ts.s0 += wq[0].s0*sy.s0; ts.s0 += wq[1].s0*sy.s1; ts.s0 += wq[2].s0*sy.s2; ts.s0 += wq[3].s0*sy.s3; \
)"
R"(    ts.s0 += wq[4].s0*sy.s4; ts.s0 += wq[5].s0*sy.s5; ts.s0 += wq[6].s0*sy.s6; ts.s0 += wq[7].s0*sy.s7; \
)"
R"(    ts.s1 += wq[0].s1*sy.s0; ts.s1 += wq[1].s1*sy.s1; ts.s1 += wq[2].s1*sy.s2; ts.s1 += wq[3].s1*sy.s3; \
)"
R"(    ts.s1 += wq[4].s1*sy.s4; ts.s1 += wq[5].s1*sy.s5; ts.s1 += wq[6].s1*sy.s6; ts.s1 += wq[7].s1*sy.s7; \
)"
R"(    sy.s0 = SGB_BC(y.s0, ln1); \
)"
R"(    sy.s1 = SGB_BC(y.s1, ln1); \
)"
R"(    sy.s2 = SGB_BC(y.s2, ln1); \
)"
R"(    sy.s3 = SGB_BC(y.s3, ln1); \
)"
R"(    sy.s4 = SGB_BC(y.s4, ln1); \
)"
R"(    sy.s5 = SGB_BC(y.s5, ln1); \
)"
R"(    sy.s6 = SGB_BC(y.s6, ln1); \
)"
R"(    sy.s7 = SGB_BC(y.s7, ln1); \
)"
R"(    ts.s0 += wq[8].s0*sy.s0;  ts.s0 += wq[9].s0*sy.s1;  ts.s0 += wq[10].s0*sy.s2; ts.s0 += wq[11].s0*sy.s3; \
)"
R"(    ts.s0 += wq[12].s0*sy.s4; ts.s0 += wq[13].s0*sy.s5; ts.s0 += wq[14].s0*sy.s6; ts.s0 += wq[15].s0*sy.s7; \
)"
R"(    ts.s1 += wq[8].s1*sy.s0;  ts.s1 += wq[9].s1*sy.s1;  ts.s1 += wq[10].s1*sy.s2; ts.s1 += wq[11].s1*sy.s3; \
)"
R"(    ts.s1 += wq[12].s1*sy.s4; ts.s1 += wq[13].s1*sy.s5; ts.s1 += wq[14].s1*sy.s6; ts.s1 += wq[15].s1*sy.s7; \
)"
R"(}
)"
R"(
)"
R"(// Multi-column (N=3) variant of the q4_K decode GEMV, for the speculative /
)"
R"(// MTP verify batch (ne1=3 = 2 drafts + 1 bonus). Stays on the efficient GEMV
)"
R"(// path (subgroup-broadcast activation, NSUBGROUPS K-split) instead of the
)"
R"(// transposed-GEMM dead-zone path. Each K-block's weights (regA_hi/regA_lo) are
)"
R"(// loaded ONCE and reused across all 3 activation columns — same weight traffic
)"
R"(// as one decode, ~3x the (cheap) dequant ALU. Per-column accumulation is
)"
R"(// independent and identical to 3 standalone GEMVs => byte-identical, so it does
)"
R"(// NOT perturb the lm_head logits / spec accept rate.
)"
R"(#ifdef ADRENO_GPU
)"
R"(REQD_SUBGROUP_SIZE_64
)"
R"(#endif
)"
R"(kernel void kernel_gemv_noshuffle_q4_k_f32_mc3(
)"
R"(        read_only  image1d_buffer_t src0_q,
)"
R"(        global half2  * src0_d,
)"
R"(        global half2  * src0_m,
)"
R"(        global uchar  * src0_s,
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
R"(        uchar mask_d6,
)"
R"(        uchar mask_d4,
)"
R"(        uchar mask_hi2)
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
R"(    private float2  regS, regM;
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
R"(
)"
R"(#ifdef Q4K_MC3_DEQUANT_LDS
)"
R"(    // One 16-half2 block buffer per WI (reused hi->lo): forces the dequantized
)"
R"(    // weights into LDS instead of private arrays (which spill to slow global on
)"
R"(    // Adreno). 64*NSUBGROUPS WIs * 16 half2 = 16 KB; each WI owns its own slot
)"
R"(    // range (flat*16) -> no cross-lane sharing, no barrier needed.
)"
R"(    local half2 wstage[SUBGROUP_SIZE * NSUBGROUPS * 16];
)"
R"(    local half2 * ws = wstage + (groupId * SUBGROUP_SIZE + slid) * 16;
)"
R"(#endif
)"
R"(
)"
R"(    for (uint k = groupId; k < (K / 32); k += NSUBGROUPS) {
)"
R"(        uint sb = k / 8;
)"
R"(        uint j  = k % 8;
)"
R"(
)"
R"(        half2 d   = src0_d[gid_s + sb * LINE_STRIDE_A];
)"
R"(        half2 dm  = src0_m[gid_s + sb * LINE_STRIDE_A];
)"
R"(
)"
R"(        global const uchar * sc0 = src0_s + sb * 12 * M + 2 * gid_s;
)"
R"(        global const uchar * sc1 = sc0 + 1;
)"
R"(
)"
R"(        uchar sv0, mn0, sv1, mn1;
)"
R"(        get_scale_min_k4(j, sc0, M, &sv0, &mn0, mask_d6, mask_d4, mask_hi2);
)"
R"(        get_scale_min_k4(j, sc1, M, &sv1, &mn1, mask_d6, mask_d4, mask_hi2);
)"
R"(
)"
R"(        regS = convert_float2(d)  * convert_float2((uchar2)(sv0, sv1));
)"
R"(        regM = convert_float2(dm) * convert_float2((uchar2)(mn0, mn1));
)"
R"(
)"
R"(        // weights loaded ONCE, reused across the 3 columns
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
R"(#ifdef Q4K_MC3_DEQUANT_ONCE
)"
R"(        // Dequant the 32 weights/row (16 hi + 16 lo) ONCE into half2[] (byte-
)"
R"(        // identical to the inline intermediate), then MAC against each column's
)"
R"(        // activation. Drops the dequant ALU 3x->1x and the macro-temp spill.
)"
R"(        half2 wq_hi[16], wq_lo[16];
)"
R"(        DEQUANT_Q4K_BLOCK(wq_hi, as_ushort8(regA_hi), regS, regM);
)"
R"(        DEQUANT_Q4K_BLOCK(wq_lo, as_ushort8(regA_lo), regS, regM);
)"
R"(        { if (slid < 4) { regB.s0123 = read_imagef(src1, 0*COL_STRIDE     + slid*2 + k*8);
)"
R"(                          regB.s4567 = read_imagef(src1, 0*COL_STRIDE + 1 + slid*2 + k*8); }
)"
R"(          MAC_Q4K_BLOCK(ts0, wq_hi, regB, 0, 1); MAC_Q4K_BLOCK(ts0, wq_lo, regB, 2, 3); }
)"
R"(        { if (slid < 4) { regB.s0123 = read_imagef(src1, 1*COL_STRIDE     + slid*2 + k*8);
)"
R"(                          regB.s4567 = read_imagef(src1, 1*COL_STRIDE + 1 + slid*2 + k*8); }
)"
R"(          MAC_Q4K_BLOCK(ts1, wq_hi, regB, 0, 1); MAC_Q4K_BLOCK(ts1, wq_lo, regB, 2, 3); }
)"
R"(        { if (slid < 4) { regB.s0123 = read_imagef(src1, 2*COL_STRIDE     + slid*2 + k*8);
)"
R"(                          regB.s4567 = read_imagef(src1, 2*COL_STRIDE + 1 + slid*2 + k*8); }
)"
R"(          MAC_Q4K_BLOCK(ts2, wq_hi, regB, 0, 1); MAC_Q4K_BLOCK(ts2, wq_lo, regB, 2, 3); }
)"
R"(#elif defined(Q4K_MC3_DEQUANT_LDS)
)"
R"(        // LDS-staged dequant: dequant a 32-block ONCE into the per-WI LDS slot
)"
R"(        // (hi pass then lo pass, overwriting), MAC each column from LDS. ts*
)"
R"(        // receive hi-then-lo in the same order as DEQUANT_ONCE -> byte-identical.
)"
R"(        // Activations reloaded per pass (cheap, imaged); only one regB + 0 weight
)"
R"(        // regs live -> the weight working set lives in LDS, not spilled private.
)"
R"(        DEQUANT_Q4K_BLOCK(ws, as_ushort8(regA_hi), regS, regM);
)"
R"(        { if (slid < 4) { regB.s0123 = read_imagef(src1, 0*COL_STRIDE     + slid*2 + k*8);
)"
R"(                          regB.s4567 = read_imagef(src1, 0*COL_STRIDE + 1 + slid*2 + k*8); }
)"
R"(          MAC_Q4K_BLOCK(ts0, ws, regB, 0, 1); }
)"
R"(        { if (slid < 4) { regB.s0123 = read_imagef(src1, 1*COL_STRIDE     + slid*2 + k*8);
)"
R"(                          regB.s4567 = read_imagef(src1, 1*COL_STRIDE + 1 + slid*2 + k*8); }
)"
R"(          MAC_Q4K_BLOCK(ts1, ws, regB, 0, 1); }
)"
R"(        { if (slid < 4) { regB.s0123 = read_imagef(src1, 2*COL_STRIDE     + slid*2 + k*8);
)"
R"(                          regB.s4567 = read_imagef(src1, 2*COL_STRIDE + 1 + slid*2 + k*8); }
)"
R"(          MAC_Q4K_BLOCK(ts2, ws, regB, 0, 1); }
)"
R"(        DEQUANT_Q4K_BLOCK(ws, as_ushort8(regA_lo), regS, regM);
)"
R"(        { if (slid < 4) { regB.s0123 = read_imagef(src1, 0*COL_STRIDE     + slid*2 + k*8);
)"
R"(                          regB.s4567 = read_imagef(src1, 0*COL_STRIDE + 1 + slid*2 + k*8); }
)"
R"(          MAC_Q4K_BLOCK(ts0, ws, regB, 2, 3); }
)"
R"(        { if (slid < 4) { regB.s0123 = read_imagef(src1, 1*COL_STRIDE     + slid*2 + k*8);
)"
R"(                          regB.s4567 = read_imagef(src1, 1*COL_STRIDE + 1 + slid*2 + k*8); }
)"
R"(          MAC_Q4K_BLOCK(ts1, ws, regB, 2, 3); }
)"
R"(        { if (slid < 4) { regB.s0123 = read_imagef(src1, 2*COL_STRIDE     + slid*2 + k*8);
)"
R"(                          regB.s4567 = read_imagef(src1, 2*COL_STRIDE + 1 + slid*2 + k*8); }
)"
R"(          MAC_Q4K_BLOCK(ts2, ws, regB, 2, 3); }
)"
R"(#else
)"
R"(        // Per-column: load only this column's activation (single regB live at a
)"
R"(        // time -> 1/3 the activation register pressure vs holding all 3) then
)"
R"(        // dequant against the shared weights. Cuts the private-mem spill.
)"
R"(#ifdef VECTOR_SUB_GROUP_BROADCAST
)"
R"(        { if (slid < 4) { regB.s0123 = read_imagef(src1, 0*COL_STRIDE     + slid*2 + k*8);
)"
R"(                          regB.s4567 = read_imagef(src1, 0*COL_STRIDE + 1 + slid*2 + k*8); }
)"
R"(          dequantizeBlockAccum_ns_sgbroadcast_8_hi(ts0, as_ushort8(regA_hi), regS, regM, regB);
)"
R"(          dequantizeBlockAccum_ns_sgbroadcast_8_lo(ts0, as_ushort8(regA_lo), regS, regM, regB); }
)"
R"(        { if (slid < 4) { regB.s0123 = read_imagef(src1, 1*COL_STRIDE     + slid*2 + k*8);
)"
R"(                          regB.s4567 = read_imagef(src1, 1*COL_STRIDE + 1 + slid*2 + k*8); }
)"
R"(          dequantizeBlockAccum_ns_sgbroadcast_8_hi(ts1, as_ushort8(regA_hi), regS, regM, regB);
)"
R"(          dequantizeBlockAccum_ns_sgbroadcast_8_lo(ts1, as_ushort8(regA_lo), regS, regM, regB); }
)"
R"(        { if (slid < 4) { regB.s0123 = read_imagef(src1, 2*COL_STRIDE     + slid*2 + k*8);
)"
R"(                          regB.s4567 = read_imagef(src1, 2*COL_STRIDE + 1 + slid*2 + k*8); }
)"
R"(          dequantizeBlockAccum_ns_sgbroadcast_8_hi(ts2, as_ushort8(regA_hi), regS, regM, regB);
)"
R"(          dequantizeBlockAccum_ns_sgbroadcast_8_lo(ts2, as_ushort8(regA_lo), regS, regM, regB); }
)"
R"(#else
)"
R"(        { if (slid < 4) { regB.s0123 = read_imagef(src1, 0*COL_STRIDE     + slid*2 + k*8);
)"
R"(                          regB.s4567 = read_imagef(src1, 0*COL_STRIDE + 1 + slid*2 + k*8); }
)"
R"(          dequantizeBlockAccum_ns_sgbroadcast_1_hi(ts0, as_ushort8(regA_hi), regS, regM, regB);
)"
R"(          dequantizeBlockAccum_ns_sgbroadcast_1_lo(ts0, as_ushort8(regA_lo), regS, regM, regB); }
)"
R"(        { if (slid < 4) { regB.s0123 = read_imagef(src1, 1*COL_STRIDE     + slid*2 + k*8);
)"
R"(                          regB.s4567 = read_imagef(src1, 1*COL_STRIDE + 1 + slid*2 + k*8); }
)"
R"(          dequantizeBlockAccum_ns_sgbroadcast_1_hi(ts1, as_ushort8(regA_hi), regS, regM, regB);
)"
R"(          dequantizeBlockAccum_ns_sgbroadcast_1_lo(ts1, as_ushort8(regA_lo), regS, regM, regB); }
)"
R"(        { if (slid < 4) { regB.s0123 = read_imagef(src1, 2*COL_STRIDE     + slid*2 + k*8);
)"
R"(                          regB.s4567 = read_imagef(src1, 2*COL_STRIDE + 1 + slid*2 + k*8); }
)"
R"(          dequantizeBlockAccum_ns_sgbroadcast_1_hi(ts2, as_ushort8(regA_hi), regS, regM, regB);
)"
R"(          dequantizeBlockAccum_ns_sgbroadcast_1_lo(ts2, as_ushort8(regA_lo), regS, regM, regB); }
)"
R"(#endif
)"
R"(#endif // Q4K_MC3_DEQUANT_ONCE
)"
R"(    }
)"
R"(
)"
R"(    // cross-subgroup reduce: pack the 3 columns' float2 into a float8 (6 used).
)"
R"(    local float8 reduceLM[SUBGROUP_SIZE * 3];
)"
R"(    float8 acc = (float8)(ts0.s0, ts0.s1, ts1.s0, ts1.s1, ts2.s0, ts2.s1, 0.0f, 0.0f);
)"
R"(    if (groupId == 1) { reduceLM[SUBGROUP_SIZE * 0 + slid] = acc; }
)"
R"(    if (groupId == 2) { reduceLM[SUBGROUP_SIZE * 1 + slid] = acc; }
)"
R"(    if (groupId == 3) { reduceLM[SUBGROUP_SIZE * 2 + slid] = acc; }
)"
R"(
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(    if (groupId == 0) {
)"
R"(        acc += reduceLM[SUBGROUP_SIZE * 0 + slid];
)"
R"(        acc += reduceLM[SUBGROUP_SIZE * 1 + slid];
)"
R"(        acc += reduceLM[SUBGROUP_SIZE * 2 + slid];
)"
R"(        dst = (global float*)((global char*)dst + offsetd);
)"
R"(        // dst is column-major [M rows x 3 cols]: (row, col) at col*M + row
)"
R"(        if (gid < LINE_STRIDE_A) {
)"
R"(            vstore2((float2)(acc.s0, acc.s1), 0, &(dst[0 * M + gid * 2]));
)"
R"(            vstore2((float2)(acc.s2, acc.s3), 0, &(dst[1 * M + gid * 2]));
)"
R"(            vstore2((float2)(acc.s4, acc.s5), 0, &(dst[2 * M + gid * 2]));
)"
R"(        }
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(// [dspark 2026-10-14] Batched MUL_MAT_ID for q4_K MoE: ONE dispatch computes all
)"
R"(// (expert-slot, token) GEMV columns with on-device ids — the q4_K twin of
)"
R"(// kernel_mul_mat_id_q4_0_f32_batched. Weight addressing is the validated
)"
R"(// kernel_gemv_noshuffle_q4_k_f32 layout (noshuffle + transposed, 8 uints per
)"
R"(// K-step per row-pair) with per-expert base shifts on all four planes:
)"
R"(//   q image  + es * q_layer_pix   (uint pixels)
)"
R"(//   d / dm   + es * *_layer_bytes (half2)
)"
R"(//   s codes  + es * s_layer_bytes (uchar)
)"
R"(// Scale decode (get_scale_min_k4) and the accumulate order are byte-identical
)"
R"(// to the dense GEMV, so each (slot, token) column equals the dense-loop's
)"
R"(// per-expert result (NMSE=0 expected — same layout that passed tbo 2/2).
)"
R"(// Requires (host-checked): M % 128 == 0 (no row-pair padding: with M%128, the
)"
R"(// x-grid per column is exactly M2, so every weight/scale index stays inside
)"
R"(// its expert layer), K % 256 == 0 (superblock scale indexing), ids in [0, E).
)"
R"(#define BMO_Q4K_MASK_D6  0x3F
)"
R"(#define BMO_Q4K_MASK_D4  0x0F
)"
R"(#define BMO_Q4K_MASK_HI2 0xC0
)"
R"(#ifdef VECTOR_SUB_GROUP_BROADCAST
)"
R"(#define BMO_Q4K_DQ_HI dequantizeBlockAccum_ns_sgbroadcast_8_hi
)"
R"(#define BMO_Q4K_DQ_LO dequantizeBlockAccum_ns_sgbroadcast_8_lo
)"
R"(#else
)"
R"(#define BMO_Q4K_DQ_HI dequantizeBlockAccum_ns_sgbroadcast_1_hi
)"
R"(#define BMO_Q4K_DQ_LO dequantizeBlockAccum_ns_sgbroadcast_1_lo
)"
R"(#endif
)"
R"(#ifdef ADRENO_GPU
)"
R"(REQD_SUBGROUP_SIZE_64
)"
R"(#endif
)"
R"(__kernel void kernel_mul_mat_id_q4_k_f32_batched(
)"
R"(        read_only  image1d_buffer_t src0_q,   // E transposed q4_K expert layers
)"
R"(        global half2  * src0_se,              // E layers of fp16 effective scales  (d*sc, precomputed on host)
)"
R"(        global half2  * src0_me,              // E layers of fp16 effective mins    (dm*mn, precomputed on host)
)"
R"(        read_only  image1d_buffer_t src1,     // B: ne11*n_tok columns of K floats
)"
R"(        global int    * ids,                  // MUL_MAT_ID ids tensor (I32)
)"
R"(        int ids_elem_off,                     // element offset of ids base
)"
R"(        global float * dst,                   // destination buffer
)"
R"(        ulong offsetd,                        // byte offset of dst base
)"
R"(        int ne00,                             // K
)"
R"(        int ne01,                             // M (output rows)
)"
R"(        int n_used,                           // expert slots per token
)"
R"(        int n_tok,                            // tokens
)"
R"(        int ne11,                             // src1 columns (1 => broadcast)
)"
R"(        int n_expert,                         // E
)"
R"(        int ids_row,                          // ids row stride in elements
)"
R"(        ulong dst_nb1,                        // dst->nb[1] bytes
)"
R"(        ulong dst_nb2,                        // dst->nb[2] bytes
)"
R"(        int grid_x_per_col,                   // CEIL_DIV(M/2, 64) * 64 (== M/2 when M%128==0)
)"
R"(        ulong q_layer_pix,                    // per-expert q stride (uint pixels)
)"
R"(        ulong se_layer_bytes,                 // per-expert seff/me stride (bytes)
)"
R"(        global float * dbg)                   // [dspark] KDBG: n_cols*(K/32)*6 floats or NULL
)"
R"({
)"
R"(    uint gid     = get_global_id(0);
)"
R"(    uint slid    = get_sub_group_local_id();
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
R"(    uint js = col - t * (uint)n_used;              // expert slot (j taken by scale idx)
)"
R"(
)"
R"(    int e = ids[ids_elem_off + (int)t * ids_row + (int)js];
)"
R"(    bool valid = (e >= 0) && (e < n_expert);
)"
R"(    int  es    = valid ? e : 0;   // safe reads; invalid ids write zeros
)"
R"(
)"
R"(    uint LINE_STRIDE_A  = M / 2;
)"
R"(    uint BLOCK_STRIDE_A = NSUBGROUPS * M;
)"
R"(
)"
R"(    // [dspark 2026-10-14] precomputed effective-scale planes (host: se=d*sc,
)"
R"(    // me=dm*mn per 32-block, fp16 row pairs). Scale reads are now plain half2
)"
R"(    // loads, structurally identical to the q4_0 batched kernel (NMSE=0); the
)"
R"(    // entire get_scale_min_k4 / 6-bit mask reassembly subsystem is gone.
)"
R"(    global half2  * serow = (global half2 *)((global char *)src0_se + (ulong)es * se_layer_bytes);
)"
R"(    global half2  * merow = (global half2 *)((global char *)src0_me + (ulong)es * se_layer_bytes);
)"
R"(    int qbase = (int)((ulong)es * q_layer_pix);
)"
R"(    int bbase = (int)((ulong)((js % (uint)ne11) + t * (uint)ne11) * (K / 4));
)"
R"(    global float * dstc = (global float *)((global char *)dst + offsetd
)"
R"(                            + (ulong)js * dst_nb1 + (ulong)t * dst_nb2);
)"
R"(
)"
R"(    private uint4  regA;
)"
R"(    private float2  regS, regM;
)"
R"(    private float8 regB;
)"
R"(    private half2  wq[16];
)"
R"(
)"
R"(    private float2 totalSum = (float2)(0.0f);
)"
R"(
)"
R"(    for (uint k = groupId; k < (K / 32); k += NSUBGROUPS) {
)"
R"(        float2 ts_prev = totalSum;   // KDBG: per-block contribution = delta
)"
R"(
)"
R"(        regS = convert_float2(serow[rp + k * M2]);
)"
R"(        regM = convert_float2(merow[rp + k * M2]);
)"
R"(
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
R"(        DEQUANT_Q4K_BLOCK(wq, as_ushort8(regA), regS, regM);
)"
R"(        MAC_Q4K_BLOCK(totalSum, wq, regB, 0, 1);
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
R"(        DEQUANT_Q4K_BLOCK(wq, as_ushort8(regA), regS, regM);
)"
R"(        MAC_Q4K_BLOCK(totalSum, wq, regB, 2, 3);
)"
R"(
)"
R"(        if (dbg != (global float *)0) {
)"
R"(            global float * db = dbg + ((ulong)col * (K / 32) + k) * 6;
)"
R"(            db[0] = totalSum.s0 - ts_prev.s0;
)"
R"(            db[1] = totalSum.s1 - ts_prev.s1;
)"
R"(            db[2] = (float)regS.s0;  db[3] = (float)regS.s1;
)"
R"(            db[4] = (float)regM.s0;  db[5] = (float)regM.s1;
)"
R"(        }
)"
R"(    }
)"
R"(
)"
R"(    // reduction in local memory, assumes #wave=4 (SUBGROUP_SIZE: the q4_K program
)"
R"(    // build does not define SIMDGROUP_WIDTH)
)"
R"(    local float2 reduceLM[SUBGROUP_SIZE * 3];
)"
R"(    if (groupId == 1) reduceLM[SUBGROUP_SIZE * 0 + slid] = totalSum;
)"
R"(    if (groupId == 2) reduceLM[SUBGROUP_SIZE * 1 + slid] = totalSum;
)"
R"(    if (groupId == 3) reduceLM[SUBGROUP_SIZE * 2 + slid] = totalSum;
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(    if (groupId == 0) {
)"
R"(        totalSum += reduceLM[SUBGROUP_SIZE * 0 + slid];
)"
R"(        totalSum += reduceLM[SUBGROUP_SIZE * 1 + slid];
)"
R"(        totalSum += reduceLM[SUBGROUP_SIZE * 2 + slid];
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
R"(#undef BMO_Q4K_DQ_HI
)"
R"(#undef BMO_Q4K_DQ_LO
)"
