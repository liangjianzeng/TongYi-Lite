R"(// 4-output-per-WI variant of kernel_gemv_noshuffle_q6_K_f32.
)"
R"(// Each WI now produces 4 consecutive outputs (output quad). The activation
)"
R"(// fetch (reg_b) is shared across all 4 outputs, doubling per-WI ALU per
)"
R"(// activation broadcast and halving the WG count vs the 2-output kernel.
)"
R"(//
)"
R"(// Implementation: each K-block we fetch TWO sets of (scales + ql + qh)
)"
R"(// — one for the low pair (rows 0,1 of the quad) and one for the high pair
)"
R"(// (rows 2,3) — and invoke the existing 2-output dequant macros twice
)"
R"(// against the *same* reg_b. Identical data layout to the 2-output kernel,
)"
R"(// so the host only needs to halve the grid and double the gid-to-output
)"
R"(// mapping.
)"
R"(//
)"
R"(// Opt-in via the host dispatch when GGML_OPENCL_Q6K_GEMV_O4=1.
)"
R"(
)"
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
R"(// Macros are identical to the 2-output kernel — they accept `total_sum` as
)"
R"(// a parameter so we can call them twice (once per pair) against different
)"
R"(// accumulators against the same reg_b.
)"
R"(#define dequantize_block_acc_bcast_8_hi(total_sum, bits4, bits2, cs, y) \
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
R"(    total_sum.s0 += ((float)(((bits4.s0 & 0x000F)      ) | ((bits2.s0 & 0x03) << 4)) - 32.f) * cs.s0 * shared_y.s0; \
)"
R"(    total_sum.s0 += ((float)(((bits4.s0 & 0x00F0) >>  4) | ((bits2.s0 & 0x0C) << 2)) - 32.f) * cs.s0 * shared_y.s1; \
)"
R"(    total_sum.s0 += ((float)(((bits4.s0 & 0x0F00) >>  8) | ((bits2.s0 & 0x30)     )) - 32.f) * cs.s0 * shared_y.s2; \
)"
R"(    total_sum.s0 += ((float)(((bits4.s0 & 0xF000) >> 12) | ((bits2.s0 & 0xC0) >> 2)) - 32.f) * cs.s0 * shared_y.s3; \
)"
R"(    total_sum.s0 += ((float)(((bits4.s2 & 0x000F)      ) | ((bits2.s2 & 0x03) << 4)) - 32.f) * cs.s0 * shared_y.s4; \
)"
R"(    total_sum.s0 += ((float)(((bits4.s2 & 0x00F0) >>  4) | ((bits2.s2 & 0x0C) << 2)) - 32.f) * cs.s0 * shared_y.s5; \
)"
R"(    total_sum.s0 += ((float)(((bits4.s2 & 0x0F00) >>  8) | ((bits2.s2 & 0x30)     )) - 32.f) * cs.s0 * shared_y.s6; \
)"
R"(    total_sum.s0 += ((float)(((bits4.s2 & 0xF000) >> 12) | ((bits2.s2 & 0xC0) >> 2)) - 32.f) * cs.s0 * shared_y.s7; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s1 & 0x000F)      ) | ((bits2.s1 & 0x03) << 4)) - 32.f) * cs.s2 * shared_y.s0; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s1 & 0x00F0) >>  4) | ((bits2.s1 & 0x0C) << 2)) - 32.f) * cs.s2 * shared_y.s1; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s1 & 0x0F00) >>  8) | ((bits2.s1 & 0x30)     )) - 32.f) * cs.s2 * shared_y.s2; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s1 & 0xF000) >> 12) | ((bits2.s1 & 0xC0) >> 2)) - 32.f) * cs.s2 * shared_y.s3; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s3 & 0x000F)      ) | ((bits2.s3 & 0x03) << 4)) - 32.f) * cs.s2 * shared_y.s4; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s3 & 0x00F0) >>  4) | ((bits2.s3 & 0x0C) << 2)) - 32.f) * cs.s2 * shared_y.s5; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s3 & 0x0F00) >>  8) | ((bits2.s3 & 0x30)     )) - 32.f) * cs.s2 * shared_y.s6; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s3 & 0xF000) >> 12) | ((bits2.s3 & 0xC0) >> 2)) - 32.f) * cs.s2 * shared_y.s7; \
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
R"(    total_sum.s0 += ((float)(((bits4.s4 & 0x000F)      ) | ((bits2.s4 & 0x03) << 4)) - 32.f) * cs.s0 * shared_y.s0; \
)"
R"(    total_sum.s0 += ((float)(((bits4.s4 & 0x00F0) >>  4) | ((bits2.s4 & 0x0C) << 2)) - 32.f) * cs.s0 * shared_y.s1; \
)"
R"(    total_sum.s0 += ((float)(((bits4.s4 & 0x0F00) >>  8) | ((bits2.s4 & 0x30)     )) - 32.f) * cs.s0 * shared_y.s2; \
)"
R"(    total_sum.s0 += ((float)(((bits4.s4 & 0xF000) >> 12) | ((bits2.s4 & 0xC0) >> 2)) - 32.f) * cs.s0 * shared_y.s3; \
)"
R"(    total_sum.s0 += ((float)(((bits4.s6 & 0x000F)      ) | ((bits2.s6 & 0x03) << 4)) - 32.f) * cs.s0 * shared_y.s4; \
)"
R"(    total_sum.s0 += ((float)(((bits4.s6 & 0x00F0) >>  4) | ((bits2.s6 & 0x0C) << 2)) - 32.f) * cs.s0 * shared_y.s5; \
)"
R"(    total_sum.s0 += ((float)(((bits4.s6 & 0x0F00) >>  8) | ((bits2.s6 & 0x30)     )) - 32.f) * cs.s0 * shared_y.s6; \
)"
R"(    total_sum.s0 += ((float)(((bits4.s6 & 0xF000) >> 12) | ((bits2.s6 & 0xC0) >> 2)) - 32.f) * cs.s0 * shared_y.s7; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s5 & 0x000F)      ) | ((bits2.s5 & 0x03) << 4)) - 32.f) * cs.s2 * shared_y.s0; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s5 & 0x00F0) >>  4) | ((bits2.s5 & 0x0C) << 2)) - 32.f) * cs.s2 * shared_y.s1; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s5 & 0x0F00) >>  8) | ((bits2.s5 & 0x30)     )) - 32.f) * cs.s2 * shared_y.s2; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s5 & 0xF000) >> 12) | ((bits2.s5 & 0xC0) >> 2)) - 32.f) * cs.s2 * shared_y.s3; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s7 & 0x000F)      ) | ((bits2.s7 & 0x03) << 4)) - 32.f) * cs.s2 * shared_y.s4; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s7 & 0x00F0) >>  4) | ((bits2.s7 & 0x0C) << 2)) - 32.f) * cs.s2 * shared_y.s5; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s7 & 0x0F00) >>  8) | ((bits2.s7 & 0x30)     )) - 32.f) * cs.s2 * shared_y.s6; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s7 & 0xF000) >> 12) | ((bits2.s7 & 0xC0) >> 2)) - 32.f) * cs.s2 * shared_y.s7; \
)"
R"(
)"
R"(#define dequantize_block_acc_bcast_8_lo(total_sum, bits4, bits2, cs, y) \
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
R"(    total_sum.s0 += ((float)(((bits4.s0 & 0x000F)      ) | ((bits2.s0 & 0x03) << 4)) - 32.f) * cs.s1 * shared_y.s0; \
)"
R"(    total_sum.s0 += ((float)(((bits4.s0 & 0x00F0) >>  4) | ((bits2.s0 & 0x0C) << 2)) - 32.f) * cs.s1 * shared_y.s1; \
)"
R"(    total_sum.s0 += ((float)(((bits4.s0 & 0x0F00) >>  8) | ((bits2.s0 & 0x30)     )) - 32.f) * cs.s1 * shared_y.s2; \
)"
R"(    total_sum.s0 += ((float)(((bits4.s0 & 0xF000) >> 12) | ((bits2.s0 & 0xC0) >> 2)) - 32.f) * cs.s1 * shared_y.s3; \
)"
R"(    total_sum.s0 += ((float)(((bits4.s2 & 0x000F)      ) | ((bits2.s2 & 0x03) << 4)) - 32.f) * cs.s1 * shared_y.s4; \
)"
R"(    total_sum.s0 += ((float)(((bits4.s2 & 0x00F0) >>  4) | ((bits2.s2 & 0x0C) << 2)) - 32.f) * cs.s1 * shared_y.s5; \
)"
R"(    total_sum.s0 += ((float)(((bits4.s2 & 0x0F00) >>  8) | ((bits2.s2 & 0x30)     )) - 32.f) * cs.s1 * shared_y.s6; \
)"
R"(    total_sum.s0 += ((float)(((bits4.s2 & 0xF000) >> 12) | ((bits2.s2 & 0xC0) >> 2)) - 32.f) * cs.s1 * shared_y.s7; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s1 & 0x000F)      ) | ((bits2.s1 & 0x03) << 4)) - 32.f) * cs.s3 * shared_y.s0; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s1 & 0x00F0) >>  4) | ((bits2.s1 & 0x0C) << 2)) - 32.f) * cs.s3 * shared_y.s1; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s1 & 0x0F00) >>  8) | ((bits2.s1 & 0x30)     )) - 32.f) * cs.s3 * shared_y.s2; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s1 & 0xF000) >> 12) | ((bits2.s1 & 0xC0) >> 2)) - 32.f) * cs.s3 * shared_y.s3; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s3 & 0x000F)      ) | ((bits2.s3 & 0x03) << 4)) - 32.f) * cs.s3 * shared_y.s4; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s3 & 0x00F0) >>  4) | ((bits2.s3 & 0x0C) << 2)) - 32.f) * cs.s3 * shared_y.s5; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s3 & 0x0F00) >>  8) | ((bits2.s3 & 0x30)     )) - 32.f) * cs.s3 * shared_y.s6; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s3 & 0xF000) >> 12) | ((bits2.s3 & 0xC0) >> 2)) - 32.f) * cs.s3 * shared_y.s7; \
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
R"(    total_sum.s0 += ((float)(((bits4.s4 & 0x000F)      ) | ((bits2.s4 & 0x03) << 4)) - 32.f) * cs.s1 * shared_y.s0; \
)"
R"(    total_sum.s0 += ((float)(((bits4.s4 & 0x00F0) >>  4) | ((bits2.s4 & 0x0C) << 2)) - 32.f) * cs.s1 * shared_y.s1; \
)"
R"(    total_sum.s0 += ((float)(((bits4.s4 & 0x0F00) >>  8) | ((bits2.s4 & 0x30)     )) - 32.f) * cs.s1 * shared_y.s2; \
)"
R"(    total_sum.s0 += ((float)(((bits4.s4 & 0xF000) >> 12) | ((bits2.s4 & 0xC0) >> 2)) - 32.f) * cs.s1 * shared_y.s3; \
)"
R"(    total_sum.s0 += ((float)(((bits4.s6 & 0x000F)      ) | ((bits2.s6 & 0x03) << 4)) - 32.f) * cs.s1 * shared_y.s4; \
)"
R"(    total_sum.s0 += ((float)(((bits4.s6 & 0x00F0) >>  4) | ((bits2.s6 & 0x0C) << 2)) - 32.f) * cs.s1 * shared_y.s5; \
)"
R"(    total_sum.s0 += ((float)(((bits4.s6 & 0x0F00) >>  8) | ((bits2.s6 & 0x30)     )) - 32.f) * cs.s1 * shared_y.s6; \
)"
R"(    total_sum.s0 += ((float)(((bits4.s6 & 0xF000) >> 12) | ((bits2.s6 & 0xC0) >> 2)) - 32.f) * cs.s1 * shared_y.s7; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s5 & 0x000F)      ) | ((bits2.s5 & 0x03) << 4)) - 32.f) * cs.s3 * shared_y.s0; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s5 & 0x00F0) >>  4) | ((bits2.s5 & 0x0C) << 2)) - 32.f) * cs.s3 * shared_y.s1; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s5 & 0x0F00) >>  8) | ((bits2.s5 & 0x30)     )) - 32.f) * cs.s3 * shared_y.s2; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s5 & 0xF000) >> 12) | ((bits2.s5 & 0xC0) >> 2)) - 32.f) * cs.s3 * shared_y.s3; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s7 & 0x000F)      ) | ((bits2.s7 & 0x03) << 4)) - 32.f) * cs.s3 * shared_y.s4; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s7 & 0x00F0) >>  4) | ((bits2.s7 & 0x0C) << 2)) - 32.f) * cs.s3 * shared_y.s5; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s7 & 0x0F00) >>  8) | ((bits2.s7 & 0x30)     )) - 32.f) * cs.s3 * shared_y.s6; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s7 & 0xF000) >> 12) | ((bits2.s7 & 0xC0) >> 2)) - 32.f) * cs.s3 * shared_y.s7; \
)"
R"(
)"
R"(#define dequantize_block_acc_bcast_1_hi(total_sum, bits4, bits2, cs, y) \
)"
R"(    float shared_y; \
)"
R"(    shared_y = SGB_BC(y.s0, 0); \
)"
R"(    total_sum.s0 += ((float)(((bits4.s0 & 0x000F)      ) | ((bits2.s0 & 0x03) << 4)) - 32.f) * cs.s0 * shared_y; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s1 & 0x000F)      ) | ((bits2.s1 & 0x03) << 4)) - 32.f) * cs.s2 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s1, 0); \
)"
R"(    total_sum.s0 += ((float)(((bits4.s0 & 0x00F0) >>  4) | ((bits2.s0 & 0x0C) << 2)) - 32.f) * cs.s0 * shared_y; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s1 & 0x00F0) >>  4) | ((bits2.s1 & 0x0C) << 2)) - 32.f) * cs.s2 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s2, 0); \
)"
R"(    total_sum.s0 += ((float)(((bits4.s0 & 0x0F00) >>  8) | ((bits2.s0 & 0x30)     )) - 32.f) * cs.s0 * shared_y; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s1 & 0x0F00) >>  8) | ((bits2.s1 & 0x30)     )) - 32.f) * cs.s2 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s3, 0); \
)"
R"(    total_sum.s0 += ((float)(((bits4.s0 & 0xF000) >> 12) | ((bits2.s0 & 0xC0) >> 2)) - 32.f) * cs.s0 * shared_y; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s1 & 0xF000) >> 12) | ((bits2.s1 & 0xC0) >> 2)) - 32.f) * cs.s2 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s4, 0); \
)"
R"(    total_sum.s0 += ((float)(((bits4.s2 & 0x000F)      ) | ((bits2.s2 & 0x03) << 4)) - 32.f) * cs.s0 * shared_y; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s3 & 0x000F)      ) | ((bits2.s3 & 0x03) << 4)) - 32.f) * cs.s2 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s5, 0); \
)"
R"(    total_sum.s0 += ((float)(((bits4.s2 & 0x00F0) >>  4) | ((bits2.s2 & 0x0C) << 2)) - 32.f) * cs.s0 * shared_y; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s3 & 0x00F0) >>  4) | ((bits2.s3 & 0x0C) << 2)) - 32.f) * cs.s2 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s6, 0); \
)"
R"(    total_sum.s0 += ((float)(((bits4.s2 & 0x0F00) >>  8) | ((bits2.s2 & 0x30)     )) - 32.f) * cs.s0 * shared_y; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s3 & 0x0F00) >>  8) | ((bits2.s3 & 0x30)     )) - 32.f) * cs.s2 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s7, 0); \
)"
R"(    total_sum.s0 += ((float)(((bits4.s2 & 0xF000) >> 12) | ((bits2.s2 & 0xC0) >> 2)) - 32.f) * cs.s0 * shared_y; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s3 & 0xF000) >> 12) | ((bits2.s3 & 0xC0) >> 2)) - 32.f) * cs.s2 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s0, 1); \
)"
R"(    total_sum.s0 += ((float)(((bits4.s4 & 0x000F)      ) | ((bits2.s4 & 0x03) << 4)) - 32.f) * cs.s0 * shared_y; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s5 & 0x000F)      ) | ((bits2.s5 & 0x03) << 4)) - 32.f) * cs.s2 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s1, 1); \
)"
R"(    total_sum.s0 += ((float)(((bits4.s4 & 0x00F0) >>  4) | ((bits2.s4 & 0x0C) << 2)) - 32.f) * cs.s0 * shared_y; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s5 & 0x00F0) >>  4) | ((bits2.s5 & 0x0C) << 2)) - 32.f) * cs.s2 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s2, 1); \
)"
R"(    total_sum.s0 += ((float)(((bits4.s4 & 0x0F00) >>  8) | ((bits2.s4 & 0x30)     )) - 32.f) * cs.s0 * shared_y; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s5 & 0x0F00) >>  8) | ((bits2.s5 & 0x30)     )) - 32.f) * cs.s2 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s3, 1); \
)"
R"(    total_sum.s0 += ((float)(((bits4.s4 & 0xF000) >> 12) | ((bits2.s4 & 0xC0) >> 2)) - 32.f) * cs.s0 * shared_y; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s5 & 0xF000) >> 12) | ((bits2.s5 & 0xC0) >> 2)) - 32.f) * cs.s2 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s4, 1); \
)"
R"(    total_sum.s0 += ((float)(((bits4.s6 & 0x000F)      ) | ((bits2.s6 & 0x03) << 4)) - 32.f) * cs.s0 * shared_y; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s7 & 0x000F)      ) | ((bits2.s7 & 0x03) << 4)) - 32.f) * cs.s2 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s5, 1); \
)"
R"(    total_sum.s0 += ((float)(((bits4.s6 & 0x00F0) >>  4) | ((bits2.s6 & 0x0C) << 2)) - 32.f) * cs.s0 * shared_y; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s7 & 0x00F0) >>  4) | ((bits2.s7 & 0x0C) << 2)) - 32.f) * cs.s2 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s6, 1); \
)"
R"(    total_sum.s0 += ((float)(((bits4.s6 & 0x0F00) >>  8) | ((bits2.s6 & 0x30)     )) - 32.f) * cs.s0 * shared_y; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s7 & 0x0F00) >>  8) | ((bits2.s7 & 0x30)     )) - 32.f) * cs.s2 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s7, 1); \
)"
R"(    total_sum.s0 += ((float)(((bits4.s6 & 0xF000) >> 12) | ((bits2.s6 & 0xC0) >> 2)) - 32.f) * cs.s0 * shared_y; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s7 & 0xF000) >> 12) | ((bits2.s7 & 0xC0) >> 2)) - 32.f) * cs.s2 * shared_y; \
)"
R"(
)"
R"(#define dequantize_block_acc_bcast_1_lo(total_sum, bits4, bits2, cs, y) \
)"
R"(    shared_y = SGB_BC(y.s0, 2); \
)"
R"(    total_sum.s0 += ((float)(((bits4.s0 & 0x000F)      ) | ((bits2.s0 & 0x03) << 4)) - 32.f) * cs.s1 * shared_y; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s1 & 0x000F)      ) | ((bits2.s1 & 0x03) << 4)) - 32.f) * cs.s3 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s1, 2); \
)"
R"(    total_sum.s0 += ((float)(((bits4.s0 & 0x00F0) >>  4) | ((bits2.s0 & 0x0C) << 2)) - 32.f) * cs.s1 * shared_y; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s1 & 0x00F0) >>  4) | ((bits2.s1 & 0x0C) << 2)) - 32.f) * cs.s3 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s2, 2); \
)"
R"(    total_sum.s0 += ((float)(((bits4.s0 & 0x0F00) >>  8) | ((bits2.s0 & 0x30)     )) - 32.f) * cs.s1 * shared_y; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s1 & 0x0F00) >>  8) | ((bits2.s1 & 0x30)     )) - 32.f) * cs.s3 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s3, 2); \
)"
R"(    total_sum.s0 += ((float)(((bits4.s0 & 0xF000) >> 12) | ((bits2.s0 & 0xC0) >> 2)) - 32.f) * cs.s1 * shared_y; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s1 & 0xF000) >> 12) | ((bits2.s1 & 0xC0) >> 2)) - 32.f) * cs.s3 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s4, 2); \
)"
R"(    total_sum.s0 += ((float)(((bits4.s2 & 0x000F)      ) | ((bits2.s2 & 0x03) << 4)) - 32.f) * cs.s1 * shared_y; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s3 & 0x000F)      ) | ((bits2.s3 & 0x03) << 4)) - 32.f) * cs.s3 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s5, 2); \
)"
R"(    total_sum.s0 += ((float)(((bits4.s2 & 0x00F0) >>  4) | ((bits2.s2 & 0x0C) << 2)) - 32.f) * cs.s1 * shared_y; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s3 & 0x00F0) >>  4) | ((bits2.s3 & 0x0C) << 2)) - 32.f) * cs.s3 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s6, 2); \
)"
R"(    total_sum.s0 += ((float)(((bits4.s2 & 0x0F00) >>  8) | ((bits2.s2 & 0x30)     )) - 32.f) * cs.s1 * shared_y; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s3 & 0x0F00) >>  8) | ((bits2.s3 & 0x30)     )) - 32.f) * cs.s3 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s7, 2); \
)"
R"(    total_sum.s0 += ((float)(((bits4.s2 & 0xF000) >> 12) | ((bits2.s2 & 0xC0) >> 2)) - 32.f) * cs.s1 * shared_y; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s3 & 0xF000) >> 12) | ((bits2.s3 & 0xC0) >> 2)) - 32.f) * cs.s3 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s0, 3); \
)"
R"(    total_sum.s0 += ((float)(((bits4.s4 & 0x000F)      ) | ((bits2.s4 & 0x03) << 4)) - 32.f) * cs.s1 * shared_y; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s5 & 0x000F)      ) | ((bits2.s5 & 0x03) << 4)) - 32.f) * cs.s3 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s1, 3); \
)"
R"(    total_sum.s0 += ((float)(((bits4.s4 & 0x00F0) >>  4) | ((bits2.s4 & 0x0C) << 2)) - 32.f) * cs.s1 * shared_y; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s5 & 0x00F0) >>  4) | ((bits2.s5 & 0x0C) << 2)) - 32.f) * cs.s3 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s2, 3); \
)"
R"(    total_sum.s0 += ((float)(((bits4.s4 & 0x0F00) >>  8) | ((bits2.s4 & 0x30)     )) - 32.f) * cs.s1 * shared_y; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s5 & 0x0F00) >>  8) | ((bits2.s5 & 0x30)     )) - 32.f) * cs.s3 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s3, 3); \
)"
R"(    total_sum.s0 += ((float)(((bits4.s4 & 0xF000) >> 12) | ((bits2.s4 & 0xC0) >> 2)) - 32.f) * cs.s1 * shared_y; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s5 & 0xF000) >> 12) | ((bits2.s5 & 0xC0) >> 2)) - 32.f) * cs.s3 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s4, 3); \
)"
R"(    total_sum.s0 += ((float)(((bits4.s6 & 0x000F)      ) | ((bits2.s6 & 0x03) << 4)) - 32.f) * cs.s1 * shared_y; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s7 & 0x000F)      ) | ((bits2.s7 & 0x03) << 4)) - 32.f) * cs.s3 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s5, 3); \
)"
R"(    total_sum.s0 += ((float)(((bits4.s6 & 0x00F0) >>  4) | ((bits2.s6 & 0x0C) << 2)) - 32.f) * cs.s1 * shared_y; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s7 & 0x00F0) >>  4) | ((bits2.s7 & 0x0C) << 2)) - 32.f) * cs.s3 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s6, 3); \
)"
R"(    total_sum.s0 += ((float)(((bits4.s6 & 0x0F00) >>  8) | ((bits2.s6 & 0x30)     )) - 32.f) * cs.s1 * shared_y; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s7 & 0x0F00) >>  8) | ((bits2.s7 & 0x30)     )) - 32.f) * cs.s3 * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s7, 3); \
)"
R"(    total_sum.s0 += ((float)(((bits4.s6 & 0xF000) >> 12) | ((bits2.s6 & 0xC0) >> 2)) - 32.f) * cs.s1 * shared_y; \
)"
R"(    total_sum.s1 += ((float)(((bits4.s7 & 0xF000) >> 12) | ((bits2.s7 & 0xC0) >> 2)) - 32.f) * cs.s3 * shared_y; \
)"
R"(
)"
R"(#if defined(ADRENO_GPU)
)"
R"(REQD_SUBGROUP_SIZE_64
)"
R"(#endif
)"
R"(// Q6K_O4_GLOBAL: read the (read-once-per-token, no-reuse) lm_head/embed weights
)"
R"(// from __global coalesced instead of image1d_buffer. The texture cache caps the
)"
R"(// streaming (no-reuse) lm_head read bandwidth; global coalesced reaches the
)"
R"(// higher rate the rest of the model gets. src1 (activation) stays an image (it IS reused via
)"
R"(// the cross-subgroup broadcast).
)"
R"(#ifdef Q6K_O4_GLOBAL
)"
R"(#define Q6K_O4_NAME kernel_gemv_noshuffle_q6_K_f32_o4_global
)"
R"(#define QL_ARG __global uint * src0_ql
)"
R"(#define QH_ARG __global half * src0_qh
)"
R"(#define RD_QL(b,i) (b[i])
)"
R"(#define RD_QH(b,i) as_ushort(b[i])
)"
R"(#else
)"
R"(#define Q6K_O4_NAME kernel_gemv_noshuffle_q6_K_f32_o4
)"
R"(#define QL_ARG read_only image1d_buffer_t src0_ql
)"
R"(#define QH_ARG read_only image1d_buffer_t src0_qh
)"
R"(#define RD_QL(b,i) (read_imageui(b,i).x)
)"
R"(#define RD_QH(b,i) as_ushort(read_imageh(b,i).x)
)"
R"(#endif
)"
R"(kernel void Q6K_O4_NAME(
)"
R"(    QL_ARG,
)"
R"(    QH_ARG,
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
R"(    int gid = get_global_id(0);              // 4-output-quad index
)"
R"(    ushort slid = get_sub_group_local_id();
)"
R"(
)"
R"(    // Map quad index to the two pair-indices the existing 2-output access
)"
R"(    // pattern uses (consecutive output pairs along ne01). NB: the two pairs are
)"
R"(    // kept ADJACENT (gid*2, gid*2+1) on purpose -- a "stride-1" split (pairs
)"
R"(    // ne01/4 apart) is slower because two distant cache-line streams have worse
)"
R"(    // locality than the adjacent pair whose reads interleave into the same lines
)"
R"(    // each iteration.
)"
R"(    // Keep tail lanes active for subgroup ops, but read valid weight pairs.
)"
R"(    int gid_a = min(gid * 2,     ne01 / 2 - 1);
)"
R"(    int gid_b = min(gid * 2 + 1, ne01 / 2 - 1);
)"
R"(
)"
R"(    int nb = ne00 / 32;
)"
R"(
)"
R"(    uint4   reg_a_l_a, reg_a_l_b;
)"
R"(    ushort4 reg_a_h_a, reg_a_h_b;
)"
R"(    half2   reg_d_a,   reg_d_b;
)"
R"(    char4   reg_s_a,   reg_s_b;
)"
R"(    float8  reg_b;
)"
R"(
)"
R"(    float2 total_sum_a = 0.0f;
)"
R"(    float2 total_sum_b = 0.0f;
)"
R"(
)"
R"(    int line_stride_a = ne01 / 2;
)"
R"(    int block_stride_a = NSUBGROUPS * ne01;
)"
R"(
)"
R"(    for (int k = grp; k < nb; k += NSUBGROUPS) {
)"
R"(        reg_d_a = src0_d[gid_a + k/8 * line_stride_a];
)"
R"(        reg_d_b = src0_d[gid_b + k/8 * line_stride_a];
)"
R"(        reg_s_a = as_char4(src0_s[gid_a + k * line_stride_a]);
)"
R"(        reg_s_b = as_char4(src0_s[gid_b + k * line_stride_a]);
)"
R"(        // Precompute the loop-invariant combined scale (sub-block scale * super-block d)
)"
R"(        // once per pair instead of re-multiplying it for every one of the 256 elements.
)"
R"(        float4 cs_a = (float4)((float)reg_s_a.s0*(float)reg_d_a.s0, (float)reg_s_a.s1*(float)reg_d_a.s0,
)"
R"(                               (float)reg_s_a.s2*(float)reg_d_a.s1, (float)reg_s_a.s3*(float)reg_d_a.s1);
)"
R"(        float4 cs_b = (float4)((float)reg_s_b.s0*(float)reg_d_b.s0, (float)reg_s_b.s1*(float)reg_d_b.s0,
)"
R"(                               (float)reg_s_b.s2*(float)reg_d_b.s1, (float)reg_s_b.s3*(float)reg_d_b.s1);
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
R"(        // Pair a (output rows gid_a*2, gid_a*2+1): read hi+lo then dequant
)"
R"(        // both in one block so the `_lo` macro can see the `shared_y` that
)"
R"(        // `_hi` declared. Pair b follows in its own block — fresh shared_y.
)"
R"(        {
)"
R"(            reg_a_l_a.s0 = RD_QL(src0_ql, gid_a + k*block_stride_a + line_stride_a*0);
)"
R"(            reg_a_l_a.s1 = RD_QL(src0_ql, gid_a + k*block_stride_a + line_stride_a*1);
)"
R"(            reg_a_l_a.s2 = RD_QL(src0_ql, gid_a + k*block_stride_a + line_stride_a*2);
)"
R"(            reg_a_l_a.s3 = RD_QL(src0_ql, gid_a + k*block_stride_a + line_stride_a*3);
)"
R"(            reg_a_h_a.s0 = RD_QH(src0_qh, gid_a + k*block_stride_a + line_stride_a*0);
)"
R"(            reg_a_h_a.s1 = RD_QH(src0_qh, gid_a + k*block_stride_a + line_stride_a*1);
)"
R"(            reg_a_h_a.s2 = RD_QH(src0_qh, gid_a + k*block_stride_a + line_stride_a*2);
)"
R"(            reg_a_h_a.s3 = RD_QH(src0_qh, gid_a + k*block_stride_a + line_stride_a*3);
)"
R"(#ifdef VECTOR_SUB_GROUP_BROADCAT
)"
R"(            dequantize_block_acc_bcast_8_hi(total_sum_a, as_ushort8(reg_a_l_a), as_uchar8(reg_a_h_a), cs_a, reg_b);
)"
R"(#else
)"
R"(            dequantize_block_acc_bcast_1_hi(total_sum_a, as_ushort8(reg_a_l_a), as_uchar8(reg_a_h_a), cs_a, reg_b);
)"
R"(#endif
)"
R"(
)"
R"(            reg_a_l_a.s0 = RD_QL(src0_ql, gid_a + k*block_stride_a + line_stride_a*4);
)"
R"(            reg_a_l_a.s1 = RD_QL(src0_ql, gid_a + k*block_stride_a + line_stride_a*5);
)"
R"(            reg_a_l_a.s2 = RD_QL(src0_ql, gid_a + k*block_stride_a + line_stride_a*6);
)"
R"(            reg_a_l_a.s3 = RD_QL(src0_ql, gid_a + k*block_stride_a + line_stride_a*7);
)"
R"(            reg_a_h_a.s0 = RD_QH(src0_qh, gid_a + k*block_stride_a + line_stride_a*4);
)"
R"(            reg_a_h_a.s1 = RD_QH(src0_qh, gid_a + k*block_stride_a + line_stride_a*5);
)"
R"(            reg_a_h_a.s2 = RD_QH(src0_qh, gid_a + k*block_stride_a + line_stride_a*6);
)"
R"(            reg_a_h_a.s3 = RD_QH(src0_qh, gid_a + k*block_stride_a + line_stride_a*7);
)"
R"(#ifdef VECTOR_SUB_GROUP_BROADCAT
)"
R"(            dequantize_block_acc_bcast_8_lo(total_sum_a, as_ushort8(reg_a_l_a), as_uchar8(reg_a_h_a), cs_a, reg_b);
)"
R"(#else
)"
R"(            dequantize_block_acc_bcast_1_lo(total_sum_a, as_ushort8(reg_a_l_a), as_uchar8(reg_a_h_a), cs_a, reg_b);
)"
R"(#endif
)"
R"(        }
)"
R"(
)"
R"(        {
)"
R"(            reg_a_l_b.s0 = RD_QL(src0_ql, gid_b + k*block_stride_a + line_stride_a*0);
)"
R"(            reg_a_l_b.s1 = RD_QL(src0_ql, gid_b + k*block_stride_a + line_stride_a*1);
)"
R"(            reg_a_l_b.s2 = RD_QL(src0_ql, gid_b + k*block_stride_a + line_stride_a*2);
)"
R"(            reg_a_l_b.s3 = RD_QL(src0_ql, gid_b + k*block_stride_a + line_stride_a*3);
)"
R"(            reg_a_h_b.s0 = RD_QH(src0_qh, gid_b + k*block_stride_a + line_stride_a*0);
)"
R"(            reg_a_h_b.s1 = RD_QH(src0_qh, gid_b + k*block_stride_a + line_stride_a*1);
)"
R"(            reg_a_h_b.s2 = RD_QH(src0_qh, gid_b + k*block_stride_a + line_stride_a*2);
)"
R"(            reg_a_h_b.s3 = RD_QH(src0_qh, gid_b + k*block_stride_a + line_stride_a*3);
)"
R"(#ifdef VECTOR_SUB_GROUP_BROADCAT
)"
R"(            dequantize_block_acc_bcast_8_hi(total_sum_b, as_ushort8(reg_a_l_b), as_uchar8(reg_a_h_b), cs_b, reg_b);
)"
R"(#else
)"
R"(            dequantize_block_acc_bcast_1_hi(total_sum_b, as_ushort8(reg_a_l_b), as_uchar8(reg_a_h_b), cs_b, reg_b);
)"
R"(#endif
)"
R"(
)"
R"(            reg_a_l_b.s0 = RD_QL(src0_ql, gid_b + k*block_stride_a + line_stride_a*4);
)"
R"(            reg_a_l_b.s1 = RD_QL(src0_ql, gid_b + k*block_stride_a + line_stride_a*5);
)"
R"(            reg_a_l_b.s2 = RD_QL(src0_ql, gid_b + k*block_stride_a + line_stride_a*6);
)"
R"(            reg_a_l_b.s3 = RD_QL(src0_ql, gid_b + k*block_stride_a + line_stride_a*7);
)"
R"(            reg_a_h_b.s0 = RD_QH(src0_qh, gid_b + k*block_stride_a + line_stride_a*4);
)"
R"(            reg_a_h_b.s1 = RD_QH(src0_qh, gid_b + k*block_stride_a + line_stride_a*5);
)"
R"(            reg_a_h_b.s2 = RD_QH(src0_qh, gid_b + k*block_stride_a + line_stride_a*6);
)"
R"(            reg_a_h_b.s3 = RD_QH(src0_qh, gid_b + k*block_stride_a + line_stride_a*7);
)"
R"(#ifdef VECTOR_SUB_GROUP_BROADCAT
)"
R"(            dequantize_block_acc_bcast_8_lo(total_sum_b, as_ushort8(reg_a_l_b), as_uchar8(reg_a_h_b), cs_b, reg_b);
)"
R"(#else
)"
R"(            dequantize_block_acc_bcast_1_lo(total_sum_b, as_ushort8(reg_a_l_b), as_uchar8(reg_a_h_b), cs_b, reg_b);
)"
R"(#endif
)"
R"(        }
)"
R"(    }
)"
R"(
)"
R"(    // Cross-subgroup reduce. Same shape as the 2-output kernel but with the
)"
R"(    // pair-a and pair-b accumulators concatenated into a single float4.
)"
R"(    local float4 reduce_lm[SUBGROUP_SIZE * 3];
)"
R"(    float4 acc = (float4)(total_sum_a.s0, total_sum_a.s1, total_sum_b.s0, total_sum_b.s1);
)"
R"(    if (grp == 1) { reduce_lm[SUBGROUP_SIZE*0 + slid] = acc; }
)"
R"(    if (grp == 2) { reduce_lm[SUBGROUP_SIZE*1 + slid] = acc; }
)"
R"(    if (grp == 3) { reduce_lm[SUBGROUP_SIZE*2 + slid] = acc; }
)"
R"(
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(    if (grp == 0) {
)"
R"(        acc += reduce_lm[SUBGROUP_SIZE*0 + slid];
)"
R"(        acc += reduce_lm[SUBGROUP_SIZE*1 + slid];
)"
R"(        acc += reduce_lm[SUBGROUP_SIZE*2 + slid];
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
