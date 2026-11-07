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
R"(#define QK_K  256
)"
R"(#define NSUBGROUPS 4
)"
R"(#define SUBGROUP_SIZE 64
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
R"(kernel void kernel_gemv_noshuffle_q4_k_f32_o4(
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
R"(    uint gid     = get_global_id(0);        // 4-output quad index
)"
R"(    ushort slid  = get_sub_group_local_id();
)"
R"(
)"
R"(    // Two consecutive pair-indices (each the same access pattern the 2-output
)"
R"(    // kernel uses); together they cover 4 consecutive output rows.
)"
R"(    // Keep tail lanes active for subgroup ops, but read valid weight pairs.
)"
R"(    uint gid_a = min(gid * 2,     (uint)(ne01 / 2) - 1u);
)"
R"(    uint gid_b = min(gid * 2 + 1, (uint)(ne01 / 2) - 1u);
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
R"(    uint BLOCK_STRIDE_A = NSUBGROUPS * M;
)"
R"(
)"
R"(    private uint4  regA;
)"
R"(    private half2  regS_a, regS_b;
)"
R"(    private half2  regM_a, regM_b;
)"
R"(    private float8 regB;
)"
R"(
)"
R"(    private float2 totalSum_a = (float2)(0.0f);
)"
R"(    private float2 totalSum_b = (float2)(0.0f);
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
R"(        // pair a scales/mins
)"
R"(        half2 d_a  = src0_d[gid_a + sb * LINE_STRIDE_A];
)"
R"(        half2 dm_a = src0_m[gid_a + sb * LINE_STRIDE_A];
)"
R"(        global const uchar * sc0a = src0_s + sb * 12 * M + 2 * gid_a;
)"
R"(        global const uchar * sc1a = sc0a + 1;
)"
R"(        uchar sv0a, mn0a, sv1a, mn1a;
)"
R"(        get_scale_min_k4(j, sc0a, M, &sv0a, &mn0a, mask_d6, mask_d4, mask_hi2);
)"
R"(        get_scale_min_k4(j, sc1a, M, &sv1a, &mn1a, mask_d6, mask_d4, mask_hi2);
)"
R"(        regS_a = convert_half2(convert_float2(d_a)  * convert_float2((uchar2)(sv0a, sv1a)));
)"
R"(        regM_a = convert_half2(convert_float2(dm_a) * convert_float2((uchar2)(mn0a, mn1a)));
)"
R"(
)"
R"(        // pair b scales/mins
)"
R"(        half2 d_b  = src0_d[gid_b + sb * LINE_STRIDE_A];
)"
R"(        half2 dm_b = src0_m[gid_b + sb * LINE_STRIDE_A];
)"
R"(        global const uchar * sc0b = src0_s + sb * 12 * M + 2 * gid_b;
)"
R"(        global const uchar * sc1b = sc0b + 1;
)"
R"(        uchar sv0b, mn0b, sv1b, mn1b;
)"
R"(        get_scale_min_k4(j, sc0b, M, &sv0b, &mn0b, mask_d6, mask_d4, mask_hi2);
)"
R"(        get_scale_min_k4(j, sc1b, M, &sv1b, &mn1b, mask_d6, mask_d4, mask_hi2);
)"
R"(        regS_b = convert_half2(convert_float2(d_b)  * convert_float2((uchar2)(sv0b, sv1b)));
)"
R"(        regM_b = convert_half2(convert_float2(dm_b) * convert_float2((uchar2)(mn0b, mn1b)));
)"
R"(
)"
R"(        // activation: load once, reuse for both pairs
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
R"(        // pair a (own block so _lo sees the shared_y declared by _hi)
)"
R"(        {
)"
R"(            regA.s0 = read_imageui(src0_q, (gid_a + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 0)).x;
)"
R"(            regA.s1 = read_imageui(src0_q, (gid_a + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 1)).x;
)"
R"(            regA.s2 = read_imageui(src0_q, (gid_a + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 2)).x;
)"
R"(            regA.s3 = read_imageui(src0_q, (gid_a + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 3)).x;
)"
R"(#ifdef VECTOR_SUB_GROUP_BROADCAST
)"
R"(            dequantizeBlockAccum_ns_sgbroadcast_8_hi(totalSum_a, as_ushort8(regA), regS_a, regM_a, regB);
)"
R"(#else
)"
R"(            dequantizeBlockAccum_ns_sgbroadcast_1_hi(totalSum_a, as_ushort8(regA), regS_a, regM_a, regB);
)"
R"(#endif
)"
R"(            regA.s0 = read_imageui(src0_q, (gid_a + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 4)).x;
)"
R"(            regA.s1 = read_imageui(src0_q, (gid_a + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 5)).x;
)"
R"(            regA.s2 = read_imageui(src0_q, (gid_a + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 6)).x;
)"
R"(            regA.s3 = read_imageui(src0_q, (gid_a + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 7)).x;
)"
R"(#ifdef VECTOR_SUB_GROUP_BROADCAST
)"
R"(            dequantizeBlockAccum_ns_sgbroadcast_8_lo(totalSum_a, as_ushort8(regA), regS_a, regM_a, regB);
)"
R"(#else
)"
R"(            dequantizeBlockAccum_ns_sgbroadcast_1_lo(totalSum_a, as_ushort8(regA), regS_a, regM_a, regB);
)"
R"(#endif
)"
R"(        }
)"
R"(
)"
R"(        // pair b
)"
R"(        {
)"
R"(            regA.s0 = read_imageui(src0_q, (gid_b + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 0)).x;
)"
R"(            regA.s1 = read_imageui(src0_q, (gid_b + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 1)).x;
)"
R"(            regA.s2 = read_imageui(src0_q, (gid_b + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 2)).x;
)"
R"(            regA.s3 = read_imageui(src0_q, (gid_b + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 3)).x;
)"
R"(#ifdef VECTOR_SUB_GROUP_BROADCAST
)"
R"(            dequantizeBlockAccum_ns_sgbroadcast_8_hi(totalSum_b, as_ushort8(regA), regS_b, regM_b, regB);
)"
R"(#else
)"
R"(            dequantizeBlockAccum_ns_sgbroadcast_1_hi(totalSum_b, as_ushort8(regA), regS_b, regM_b, regB);
)"
R"(#endif
)"
R"(            regA.s0 = read_imageui(src0_q, (gid_b + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 4)).x;
)"
R"(            regA.s1 = read_imageui(src0_q, (gid_b + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 5)).x;
)"
R"(            regA.s2 = read_imageui(src0_q, (gid_b + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 6)).x;
)"
R"(            regA.s3 = read_imageui(src0_q, (gid_b + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 7)).x;
)"
R"(#ifdef VECTOR_SUB_GROUP_BROADCAST
)"
R"(            dequantizeBlockAccum_ns_sgbroadcast_8_lo(totalSum_b, as_ushort8(regA), regS_b, regM_b, regB);
)"
R"(#else
)"
R"(            dequantizeBlockAccum_ns_sgbroadcast_1_lo(totalSum_b, as_ushort8(regA), regS_b, regM_b, regB);
)"
R"(#endif
)"
R"(        }
)"
R"(    }
)"
R"(
)"
R"(    // reduce 4 outputs (a.s0, a.s1, b.s0, b.s1) across the 4 subgroups
)"
R"(    local float4 reduceLM[SUBGROUP_SIZE * 3];
)"
R"(    float4 acc = (float4)(totalSum_a.s0, totalSum_a.s1, totalSum_b.s0, totalSum_b.s1);
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
R"(        // The dispatch rounds ne01/4 up to the subgroup width, so the tail
)"
R"(        // quads past the last row must not store (they wrote 128 rows past
)"
R"(        // dst on every ne01 % 256 == 128 vocab, e.g. 151936).
)"
R"(        if (gid * 4 + 3 < (uint)ne01) {
)"
R"(            vstore4(acc, 0, &(dst[gid * 4]));
)"
R"(        }
)"
R"(    }
)"
R"(}
)"
