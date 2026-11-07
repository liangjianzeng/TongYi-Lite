R"(#pragma OPENCL EXTENSION cl_khr_fp16 : enable
)"
R"(#pragma OPENCL EXTENSION cl_khr_subgroups : enable
)"
R"(#pragma OPENCL EXTENSION cl_qcom_subgroup_uniform_load: enable
)"
R"(#pragma OPENCL EXTENSION cl_qcom_subgroup_constant_load: enable
)"
R"(#pragma OPENCL EXTENSION cl_qcom_extra_vector_types : enable
)"
R"(// [dspark 2026-10-16] generic backend (rusticl/freedreno): emulate the QCOM
)"
R"(// extra-vector-types float8/float32 with clang ext_vector_type (guarded by the
)"
R"(// host-injected GGML_GENERIC_SUBGROUP_SHUFFLE define; no-op on Adreno).
)"
R"(#ifdef GGML_GENERIC_SUBGROUP_SHUFFLE
)"
R"(typedef float __attribute__((ext_vector_type(8))) float8;
)"
R"(#ifndef GGML_MESA_SPIRV
)"
R"(typedef float __attribute__((ext_vector_type(32))) float32;
)"
R"(#endif
)"
R"(#endif
)"
R"(
)"
R"(// [dspark 2026-10-17] GGML_MESA_SPIRV: SPIR-V caps vectors at 16 components,
)"
R"(// so the 32-lane float32 accumulator cannot survive rusticl's SPIR-V path.
)"
R"(// Emulate it as a lo/hi float16 pair; every access site below (lo/hi
)"
R"(// quadrants + scalar lanes) maps 1:1, arithmetic is bit-identical.
)"
R"(#ifdef GGML_MESA_SPIRV
)"
R"(#define REGC_Q00 reg_c_lo.lo
)"
R"(#define REGC_Q01 reg_c_lo.hi
)"
R"(#define REGC_Q10 reg_c_hi.lo
)"
R"(#define REGC_Q11 reg_c_hi.hi
)"
R"(#define REGC_LO  reg_c_lo
)"
R"(#define REGC_HI  reg_c_hi
)"
R"(#else
)"
R"(#define REGC_Q00 reg_c.lo.lo
)"
R"(#define REGC_Q01 reg_c.lo.hi
)"
R"(#define REGC_Q10 reg_c.hi.lo
)"
R"(#define REGC_Q11 reg_c.hi.hi
)"
R"(#define REGC_LO  (reg_c.lo)
)"
R"(#define REGC_HI  (reg_c.hi)
)"
R"(#endif
)"
R"(
)"
R"(
)"
R"(
)"
R"(#define TILESIZE_K 16
)"
R"(#define TILESIZE_M 64
)"
R"(#define TILESIZE_N 32
)"
R"(
)"
R"(
)"
R"(static inline half8 mxfp4_to_fp16_packed8(ushort2 fp4x8) {
)"
R"(    ushort2 fp16_packed_a_0, fp16_packed_b_0, bias_a, bias_b, sign_a, sign_b;
)"
R"(    fp16_packed_a_0.lo = (fp4x8.s0 << 9) & 0x0E00;
)"
R"(    fp16_packed_a_0.hi = (fp4x8.s0 << 5) & 0x0E00;
)"
R"(    fp16_packed_b_0.lo = (fp4x8.s0 << 1) & 0x0E00;
)"
R"(    fp16_packed_b_0.hi = (fp4x8.s0 >> 3) & 0x0E00;
)"
R"(
)"
R"(    bias_a.lo = (fp16_packed_a_0.lo != 0) ? 0x3800 : 0x0;
)"
R"(    bias_a.hi = (fp16_packed_a_0.hi != 0) ? 0x3800 : 0x0;
)"
R"(    bias_b.lo = (fp16_packed_b_0.lo != 0) ? 0x3800 : 0x0;
)"
R"(    bias_b.hi = (fp16_packed_b_0.hi != 0) ? 0x3800 : 0x0;
)"
R"(
)"
R"(    fp16_packed_a_0.lo = (fp16_packed_a_0.lo != 0x0200) ? fp16_packed_a_0.lo : 0x0;
)"
R"(    fp16_packed_a_0.hi = (fp16_packed_a_0.hi != 0x0200) ? fp16_packed_a_0.hi : 0x0;
)"
R"(    fp16_packed_b_0.lo = (fp16_packed_b_0.lo != 0x0200) ? fp16_packed_b_0.lo : 0x0;
)"
R"(    fp16_packed_b_0.hi = (fp16_packed_b_0.hi != 0x0200) ? fp16_packed_b_0.hi : 0x0;
)"
R"(
)"
R"(    sign_a.lo = (fp4x8.s0 << 12) & 0x8000;
)"
R"(    sign_a.hi = (fp4x8.s0 << 8) & 0x8000;
)"
R"(    sign_b.lo = (fp4x8.s0 << 4) & 0x8000;
)"
R"(    sign_b.hi = fp4x8.s0 & 0x8000;
)"
R"(
)"
R"(    fp16_packed_a_0 = sign_a + bias_a + fp16_packed_a_0;
)"
R"(    fp16_packed_b_0 = sign_b + bias_b + fp16_packed_b_0;
)"
R"(
)"
R"(    ushort2 fp16_packed_a_1, fp16_packed_b_1;
)"
R"(    fp16_packed_a_1.lo = (fp4x8.s1 << 9) & 0x0E00;
)"
R"(    fp16_packed_a_1.hi = (fp4x8.s1 << 5) & 0x0E00;
)"
R"(    fp16_packed_b_1.lo = (fp4x8.s1 << 1) & 0x0E00;
)"
R"(    fp16_packed_b_1.hi = (fp4x8.s1 >> 3) & 0x0E00;
)"
R"(
)"
R"(    bias_a.lo = (fp16_packed_a_1.lo != 0) ? 0x3800 : 0x0;
)"
R"(    bias_a.hi = (fp16_packed_a_1.hi != 0) ? 0x3800 : 0x0;
)"
R"(    bias_b.lo = (fp16_packed_b_1.lo != 0) ? 0x3800 : 0x0;
)"
R"(    bias_b.hi = (fp16_packed_b_1.hi != 0) ? 0x3800 : 0x0;
)"
R"(
)"
R"(    fp16_packed_a_1.lo = (fp16_packed_a_1.lo != 0x0200) ? fp16_packed_a_1.lo : 0x0;
)"
R"(    fp16_packed_a_1.hi = (fp16_packed_a_1.hi != 0x0200) ? fp16_packed_a_1.hi : 0x0;
)"
R"(    fp16_packed_b_1.lo = (fp16_packed_b_1.lo != 0x0200) ? fp16_packed_b_1.lo : 0x0;
)"
R"(    fp16_packed_b_1.hi = (fp16_packed_b_1.hi != 0x0200) ? fp16_packed_b_1.hi : 0x0;
)"
R"(
)"
R"(    sign_a.lo = (fp4x8.s1 << 12) & 0x8000;
)"
R"(    sign_a.hi = (fp4x8.s1 << 8) & 0x8000;
)"
R"(    sign_b.lo = (fp4x8.s1 << 4) & 0x8000;
)"
R"(    sign_b.hi = fp4x8.s1 & 0x8000;
)"
R"(
)"
R"(    fp16_packed_a_1 = sign_a + bias_a + fp16_packed_a_1;
)"
R"(    fp16_packed_b_1 = sign_b + bias_b + fp16_packed_b_1;
)"
R"(
)"
R"(    return as_half8((ushort8)(fp16_packed_a_0, fp16_packed_b_0, fp16_packed_a_1, fp16_packed_b_1));
)"
R"(}
)"
R"(
)"
R"(
)"
R"(#define dotx16_reduce8(a_reg, b_lm, c_reg, lm_offset) \
)"
R"(    acc.s0 = dot(a_reg.s0123, b_lm[lm_offset + 0]); \
)"
R"(    acc.s1 = dot(a_reg.s0123, b_lm[lm_offset + 1]); \
)"
R"(    acc.s2 = dot(a_reg.s0123, b_lm[lm_offset + 2]); \
)"
R"(    acc.s3 = dot(a_reg.s0123, b_lm[lm_offset + 3]); \
)"
R"(    acc.s4 = dot(a_reg.s0123, b_lm[lm_offset + 4]); \
)"
R"(    acc.s5 = dot(a_reg.s0123, b_lm[lm_offset + 5]); \
)"
R"(    acc.s6 = dot(a_reg.s0123, b_lm[lm_offset + 6]); \
)"
R"(    acc.s7 = dot(a_reg.s0123, b_lm[lm_offset + 7]); \
)"
R"(    acc.s8 = dot(a_reg.s0123, b_lm[lm_offset + 8]); \
)"
R"(    acc.s9 = dot(a_reg.s0123, b_lm[lm_offset + 9]); \
)"
R"(    acc.sa = dot(a_reg.s0123, b_lm[lm_offset + 10]); \
)"
R"(    acc.sb = dot(a_reg.s0123, b_lm[lm_offset + 11]); \
)"
R"(    acc.sc = dot(a_reg.s0123, b_lm[lm_offset + 12]); \
)"
R"(    acc.sd = dot(a_reg.s0123, b_lm[lm_offset + 13]); \
)"
R"(    acc.se = dot(a_reg.s0123, b_lm[lm_offset + 14]); \
)"
R"(    acc.sf = dot(a_reg.s0123, b_lm[lm_offset + 15]); \
)"
R"(    acc.s0 += dot(a_reg.s4567, b_lm[lm_offset + 32]); \
)"
R"(    acc.s1 += dot(a_reg.s4567, b_lm[lm_offset + 33]); \
)"
R"(    acc.s2 += dot(a_reg.s4567, b_lm[lm_offset + 34]); \
)"
R"(    acc.s3 += dot(a_reg.s4567, b_lm[lm_offset + 35]); \
)"
R"(    acc.s4 += dot(a_reg.s4567, b_lm[lm_offset + 36]); \
)"
R"(    acc.s5 += dot(a_reg.s4567, b_lm[lm_offset + 37]); \
)"
R"(    acc.s6 += dot(a_reg.s4567, b_lm[lm_offset + 38]); \
)"
R"(    acc.s7 += dot(a_reg.s4567, b_lm[lm_offset + 39]); \
)"
R"(    acc.s8 += dot(a_reg.s4567, b_lm[lm_offset + 40]); \
)"
R"(    acc.s9 += dot(a_reg.s4567, b_lm[lm_offset + 41]); \
)"
R"(    acc.sa += dot(a_reg.s4567, b_lm[lm_offset + 42]); \
)"
R"(    acc.sb += dot(a_reg.s4567, b_lm[lm_offset + 43]); \
)"
R"(    acc.sc += dot(a_reg.s4567, b_lm[lm_offset + 44]); \
)"
R"(    acc.sd += dot(a_reg.s4567, b_lm[lm_offset + 45]); \
)"
R"(    acc.se += dot(a_reg.s4567, b_lm[lm_offset + 46]); \
)"
R"(    acc.sf += dot(a_reg.s4567, b_lm[lm_offset + 47]); \
)"
R"(    c_reg.lo += convert_float8(acc.lo); \
)"
R"(    c_reg.hi += convert_float8(acc.hi); \
)"
R"(    acc.s0 = dot(a_reg.s89ab, b_lm[lm_offset + 64]); \
)"
R"(    acc.s1 = dot(a_reg.s89ab, b_lm[lm_offset + 65]); \
)"
R"(    acc.s2 = dot(a_reg.s89ab, b_lm[lm_offset + 66]); \
)"
R"(    acc.s3 = dot(a_reg.s89ab, b_lm[lm_offset + 67]); \
)"
R"(    acc.s4 = dot(a_reg.s89ab, b_lm[lm_offset + 68]); \
)"
R"(    acc.s5 = dot(a_reg.s89ab, b_lm[lm_offset + 69]); \
)"
R"(    acc.s6 = dot(a_reg.s89ab, b_lm[lm_offset + 70]); \
)"
R"(    acc.s7 = dot(a_reg.s89ab, b_lm[lm_offset + 71]); \
)"
R"(    acc.s8 = dot(a_reg.s89ab, b_lm[lm_offset + 72]); \
)"
R"(    acc.s9 = dot(a_reg.s89ab, b_lm[lm_offset + 73]); \
)"
R"(    acc.sa = dot(a_reg.s89ab, b_lm[lm_offset + 74]); \
)"
R"(    acc.sb = dot(a_reg.s89ab, b_lm[lm_offset + 75]); \
)"
R"(    acc.sc = dot(a_reg.s89ab, b_lm[lm_offset + 76]); \
)"
R"(    acc.sd = dot(a_reg.s89ab, b_lm[lm_offset + 77]); \
)"
R"(    acc.se = dot(a_reg.s89ab, b_lm[lm_offset + 78]); \
)"
R"(    acc.sf = dot(a_reg.s89ab, b_lm[lm_offset + 79]); \
)"
R"(    acc.s0 += dot(a_reg.scdef, b_lm[lm_offset + 96]); \
)"
R"(    acc.s1 += dot(a_reg.scdef, b_lm[lm_offset + 97]); \
)"
R"(    acc.s2 += dot(a_reg.scdef, b_lm[lm_offset + 98]); \
)"
R"(    acc.s3 += dot(a_reg.scdef, b_lm[lm_offset + 99]); \
)"
R"(    acc.s4 += dot(a_reg.scdef, b_lm[lm_offset + 100]); \
)"
R"(    acc.s5 += dot(a_reg.scdef, b_lm[lm_offset + 101]); \
)"
R"(    acc.s6 += dot(a_reg.scdef, b_lm[lm_offset + 102]); \
)"
R"(    acc.s7 += dot(a_reg.scdef, b_lm[lm_offset + 103]); \
)"
R"(    acc.s8 += dot(a_reg.scdef, b_lm[lm_offset + 104]); \
)"
R"(    acc.s9 += dot(a_reg.scdef, b_lm[lm_offset + 105]); \
)"
R"(    acc.sa += dot(a_reg.scdef, b_lm[lm_offset + 106]); \
)"
R"(    acc.sb += dot(a_reg.scdef, b_lm[lm_offset + 107]); \
)"
R"(    acc.sc += dot(a_reg.scdef, b_lm[lm_offset + 108]); \
)"
R"(    acc.sd += dot(a_reg.scdef, b_lm[lm_offset + 109]); \
)"
R"(    acc.se += dot(a_reg.scdef, b_lm[lm_offset + 110]); \
)"
R"(    acc.sf += dot(a_reg.scdef, b_lm[lm_offset + 111]); \
)"
R"(    c_reg.lo += convert_float8(acc.lo); \
)"
R"(    c_reg.hi += convert_float8(acc.hi); \
)"
R"(
)"
R"(// Quarter-tile variant: computes 8 output columns (one skip-group) into a float8
)"
R"(// accumulator. Same reduction order / flush cadence as dotx16_reduce8, so the
)"
R"(// non-skipped path is byte-identical; it just lets the caller skip empty
)"
R"(// 8-column groups at finer granularity. Uses a private half8 `acc8`.
)"
R"(#define dotx8_reduce4(a_reg, b_lm, c_reg, lm_offset) \
)"
R"(    acc8.s0 = dot(a_reg.s0123, b_lm[lm_offset + 0]); \
)"
R"(    acc8.s1 = dot(a_reg.s0123, b_lm[lm_offset + 1]); \
)"
R"(    acc8.s2 = dot(a_reg.s0123, b_lm[lm_offset + 2]); \
)"
R"(    acc8.s3 = dot(a_reg.s0123, b_lm[lm_offset + 3]); \
)"
R"(    acc8.s4 = dot(a_reg.s0123, b_lm[lm_offset + 4]); \
)"
R"(    acc8.s5 = dot(a_reg.s0123, b_lm[lm_offset + 5]); \
)"
R"(    acc8.s6 = dot(a_reg.s0123, b_lm[lm_offset + 6]); \
)"
R"(    acc8.s7 = dot(a_reg.s0123, b_lm[lm_offset + 7]); \
)"
R"(    acc8.s0 += dot(a_reg.s4567, b_lm[lm_offset + 32]); \
)"
R"(    acc8.s1 += dot(a_reg.s4567, b_lm[lm_offset + 33]); \
)"
R"(    acc8.s2 += dot(a_reg.s4567, b_lm[lm_offset + 34]); \
)"
R"(    acc8.s3 += dot(a_reg.s4567, b_lm[lm_offset + 35]); \
)"
R"(    acc8.s4 += dot(a_reg.s4567, b_lm[lm_offset + 36]); \
)"
R"(    acc8.s5 += dot(a_reg.s4567, b_lm[lm_offset + 37]); \
)"
R"(    acc8.s6 += dot(a_reg.s4567, b_lm[lm_offset + 38]); \
)"
R"(    acc8.s7 += dot(a_reg.s4567, b_lm[lm_offset + 39]); \
)"
R"(    c_reg += convert_float8(acc8); \
)"
R"(    acc8.s0 = dot(a_reg.s89ab, b_lm[lm_offset + 64]); \
)"
R"(    acc8.s1 = dot(a_reg.s89ab, b_lm[lm_offset + 65]); \
)"
R"(    acc8.s2 = dot(a_reg.s89ab, b_lm[lm_offset + 66]); \
)"
R"(    acc8.s3 = dot(a_reg.s89ab, b_lm[lm_offset + 67]); \
)"
R"(    acc8.s4 = dot(a_reg.s89ab, b_lm[lm_offset + 68]); \
)"
R"(    acc8.s5 = dot(a_reg.s89ab, b_lm[lm_offset + 69]); \
)"
R"(    acc8.s6 = dot(a_reg.s89ab, b_lm[lm_offset + 70]); \
)"
R"(    acc8.s7 = dot(a_reg.s89ab, b_lm[lm_offset + 71]); \
)"
R"(    acc8.s0 += dot(a_reg.scdef, b_lm[lm_offset + 96]); \
)"
R"(    acc8.s1 += dot(a_reg.scdef, b_lm[lm_offset + 97]); \
)"
R"(    acc8.s2 += dot(a_reg.scdef, b_lm[lm_offset + 98]); \
)"
R"(    acc8.s3 += dot(a_reg.scdef, b_lm[lm_offset + 99]); \
)"
R"(    acc8.s4 += dot(a_reg.scdef, b_lm[lm_offset + 100]); \
)"
R"(    acc8.s5 += dot(a_reg.scdef, b_lm[lm_offset + 101]); \
)"
R"(    acc8.s6 += dot(a_reg.scdef, b_lm[lm_offset + 102]); \
)"
R"(    acc8.s7 += dot(a_reg.scdef, b_lm[lm_offset + 103]); \
)"
R"(    c_reg += convert_float8(acc8); \
)"
R"(
)"
R"(
)"
R"(static inline half e8m0_to_fp16(uchar x) {
)"
R"(    ushort bits;
)"
R"(    bits = (ushort)(x) - (ushort)(112);
)"
R"(    bits = ((bits & 0x00E0) != 0) ? 0x7C00 : (bits << 10);
)"
R"(    return as_half(bits);
)"
R"(}
)"
R"(
)"
R"(static inline float e8m0_to_fp32(uchar x) {
)"
R"(    int bits;
)"
R"(    bits = (x == 0) ? 0x00400000 : ((uint) x << 23);
)"
R"(    return as_float(bits);
)"
R"(}
)"
R"(
)"
R"(
)"
R"(__attribute__((qcom_wave_pair_mode(1))) // 1=force single 2=force pair
)"
R"(kernel void kernel_gemm_moe_mxfp4_f32_ns(
)"
R"(        __read_only  image1d_buffer_t src0_q,
)"
R"(        __global     uchar *          src0_d,
)"
R"(        __read_only  image1d_buffer_t src1,
)"
R"(        __global     uint *           src2,
)"
R"(        __global     ushort *         src2_emap,
)"
R"(        __write_only image1d_buffer_t dst,
)"
R"(        __global     int *            total_tiles,
)"
R"(        uint ne00,
)"
R"(        uint ne01,
)"
R"(        uint is_ragged,
)"
R"(        uint skip_gran
)"
R"() {
)"
R"(    uint block_id_m = get_global_id(1); // m_tile
)"
R"(    uint block_id_n = get_global_id(2); // n_tile
)"
R"(
)"
R"(    // Boundary check
)"
R"(    if (block_id_n >= total_tiles[0]) {
)"
R"(        return;
)"
R"(    }
)"
R"(
)"
R"(    // Ragged tile-skip: when is_ragged and the upper 16 token-slots of this tile are all
)"
R"(    // padding (router 0xFFFFFFFF), skip the second (REGC_HI) dotx16_reduce8 half -> ~half
)"
R"(    // the GEMM dot for sparse tiles. Numerically identical (the skipped lanes are padding).
)"
R"(    // Ragged tile-skip: tokens are packed contiguously per expert (moe_scatter fills
)"
R"(    // lanes 0..V-1, moe_fill pre-pads the rest), so router padding (0xFFFFFFFF) is always
)"
R"(    // trailing. Find the valid-token count V and round it UP to the skip granularity
)"
R"(    // skip_gran (columns per skip-group: 8 = quarter, 16 = half/legacy, 32 = disabled).
)"
R"(    // A 8-column group g is all-padding iff its first column (8*g) >= n_active, so its
)"
R"(    // dotx8_reduce4 is skipped. Numerically identical (skipped lanes are padding).
)"
R"(    uint n_active = TILESIZE_N;
)"
R"(    if (is_ragged && skip_gran < TILESIZE_N) {
)"
R"(        uint n_valid = TILESIZE_N;
)"
R"(        for (uint _t = 0; _t < TILESIZE_N; ++_t) {
)"
R"(            if (src2[block_id_n * TILESIZE_N + _t] == 0xFFFFFFFFu) { n_valid = _t; break; }
)"
R"(        }
)"
R"(        n_active = min((uint)TILESIZE_N, ((n_valid + skip_gran - 1) / skip_gran) * skip_gran);
)"
R"(    }
)"
R"(    // Group 0 (cols 0-7) always runs; groups 1-3 skip when fully padding.
)"
R"(    bool skip_g1 = (8u  >= n_active);
)"
R"(    bool skip_g2 = (16u >= n_active);
)"
R"(    bool skip_g3 = (24u >= n_active);
)"
R"(
)"
R"(    __private half16 reg_a;
)"
R"(    #ifdef GGML_MESA_SPIRV
)"
R"(    __private float16 reg_c_lo = (float16)(0);
)"
R"(    __private float16 reg_c_hi = (float16)(0);
)"
R"(    #else
)"
R"(    __private float32 reg_c = (float32)(0);
)"
R"(    #endif
)"
R"(    __local half4 shared_b[128];
)"
R"(
)"
R"(    const ushort expert_id = src2_emap[block_id_n];
)"
R"(
)"
R"(    const uint row = block_id_m * TILESIZE_M;
)"
R"(    const uint col = block_id_n * TILESIZE_N;
)"
R"(
)"
R"(    uint sub_block_id_m = get_local_id(0);
)"
R"(    uint2 b_global_offset;
)"
R"(    b_global_offset.x = ((sub_block_id_m & 3) << 2) + (sub_block_id_m >> 2) * ne00;
)"
R"(    b_global_offset.y = b_global_offset.x + (16 * ne00);
)"
R"(    uint2 b_local_offset;
)"
R"(    b_local_offset.x = (sub_block_id_m & 3) * 32 + (sub_block_id_m >> 2);
)"
R"(    b_local_offset.y = b_local_offset.x + 16;
)"
R"(
)"
R"(    // Loop along K axis, 32 elements (one block) for each iteration, divided into 2 sub-blocks
)"
R"(    for (uint step = 0; step < ne00; step += TILESIZE_K * 2) {
)"
R"(        // First sub-block
)"
R"(        uint q_sub_offset = row + ((ne01 * step) >> 3) + ((expert_id * ne00 * ne01) >> 3);
)"
R"(        uint s_sub_offset = row + ((ne01 * step) >> 5) + ((expert_id * ne00 * ne01) >> 5);
)"
R"(        uint b_sub_offset = col * ne00 + step;
)"
R"(
)"
R"(        // Load scale for current mxfp4 block
)"
R"(        uint s_offset = s_sub_offset + get_global_id(0);
)"
R"(        float s = e8m0_to_fp32(src0_d[s_offset]);
)"
R"(
)"
R"(        // Load 16 fp4 (64-bits) in transposed layout
)"
R"(        uint2 mxfp4x16;
)"
R"(        mxfp4x16.x = read_imageui(src0_q, q_sub_offset + sub_block_id_m).x;
)"
R"(        mxfp4x16.y = read_imageui(src0_q, q_sub_offset + sub_block_id_m + ne01).x;
)"
R"(
)"
R"(        // Load 16x32 floats from matrix B, each fiber out of 64 in a sub-group loads 8 elements
)"
R"(        float8 bx8_f32;
)"
R"(        bx8_f32.lo = read_imagef(src1, (b_sub_offset + b_global_offset.x) / 4);
)"
R"(        bx8_f32.hi = read_imagef(src1, (b_sub_offset + b_global_offset.y) / 4);
)"
R"(        // Convert to half and store to LM to share within the subgroup
)"
R"(        half8 bx8_f16 = convert_half8(bx8_f32);
)"
R"(        shared_b[b_local_offset.x] = bx8_f16.lo;
)"
R"(        shared_b[b_local_offset.y] = bx8_f16.hi;
)"
R"(
)"
R"(        // Dequantization
)"
R"(        // Cast the e8m0 scale to half to satisfy E17 compilers
)"
R"(        reg_a.lo = mxfp4_to_fp16_packed8(as_ushort2(mxfp4x16.lo)) * (half)s;
)"
R"(        reg_a.hi = mxfp4_to_fp16_packed8(as_ushort2(mxfp4x16.hi)) * (half)s;
)"
R"(
)"
R"(        sub_group_barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(        // 32 16x16 fp16 dot product with 8 elements reduction for better precision
)"
R"(        half8 acc8;
)"
R"(        dotx8_reduce4(reg_a, shared_b, REGC_Q00, 0);
)"
R"(        if (!skip_g1) { dotx8_reduce4(reg_a, shared_b, REGC_Q01, 8); }
)"
R"(        if (!skip_g2) { dotx8_reduce4(reg_a, shared_b, REGC_Q10, 16); }
)"
R"(        if (!skip_g3) { dotx8_reduce4(reg_a, shared_b, REGC_Q11, 24); }
)"
R"(
)"
R"(        // Repeat for second sub-block
)"
R"(        uint half_step = step + TILESIZE_K;
)"
R"(        q_sub_offset = row + ((ne01 * half_step) >> 3) + ((expert_id * ne00 * ne01) >> 3);
)"
R"(        b_sub_offset = col * ne00 + half_step;
)"
R"(
)"
R"(        // Load next 16 fp4 (64-bits) in transposed layout
)"
R"(        mxfp4x16.x = read_imageui(src0_q, q_sub_offset + sub_block_id_m).x;
)"
R"(        mxfp4x16.y = read_imageui(src0_q, q_sub_offset + sub_block_id_m + ne01).x;
)"
R"(
)"
R"(        // Load 16x32 floats from matrix B, each fiber out of 64 in a sub-group loads 8 elements
)"
R"(        bx8_f32.lo = read_imagef(src1, (b_sub_offset + b_global_offset.x) / 4);
)"
R"(        bx8_f32.hi = read_imagef(src1, (b_sub_offset + b_global_offset.y) / 4);
)"
R"(        // Convert to half and store to LM to share within the subgroup
)"
R"(        bx8_f16 = convert_half8(bx8_f32);
)"
R"(        shared_b[b_local_offset.x] = bx8_f16.lo;
)"
R"(        shared_b[b_local_offset.y] = bx8_f16.hi;
)"
R"(
)"
R"(        // Dequantization
)"
R"(        // Cast the e8m0 scale to half to satisfy E17 compilers
)"
R"(        reg_a.lo = mxfp4_to_fp16_packed8(as_ushort2(mxfp4x16.lo)) * (half)s;
)"
R"(        reg_a.hi = mxfp4_to_fp16_packed8(as_ushort2(mxfp4x16.hi)) * (half)s;
)"
R"(
)"
R"(        sub_group_barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(        // 32 16x16 fp16 dot product with 3-levels reduction for better precision
)"
R"(        dotx8_reduce4(reg_a, shared_b, REGC_Q00, 0);
)"
R"(        if (!skip_g1) { dotx8_reduce4(reg_a, shared_b, REGC_Q01, 8); }
)"
R"(        if (!skip_g2) { dotx8_reduce4(reg_a, shared_b, REGC_Q10, 16); }
)"
R"(        if (!skip_g3) { dotx8_reduce4(reg_a, shared_b, REGC_Q11, 24); }
)"
R"(    }
)"
R"(
)"
R"(    if ((get_global_id(0) + block_id_m * TILESIZE_M) >= ne01) {
)"
R"(        return;
)"
R"(    }
)"
R"(
)"
R"(    // Load poster router and share in LM
)"
R"(    __local uint out_idx[TILESIZE_N];
)"
R"(
)"
R"(    if (get_local_id(0) < TILESIZE_N) {
)"
R"(        uint idx = src2[block_id_n * TILESIZE_N + get_local_id(0)];
)"
R"(        if (idx == 0xFFFFFFFF) {
)"
R"(            idx = src2[block_id_n * TILESIZE_N + 0];
)"
R"(        }
)"
R"(        out_idx[get_local_id(0)] = idx * ne01;
)"
R"(    }
)"
R"(
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(    // Scatter results back to original position in output grid
)"
R"(    uint m_offset = row + get_local_id(0);
)"
R"(
)"
R"(    write_imagef(dst, out_idx[1] + m_offset, (float4)((REGC_LO.s1), 0.0f, 0.0f, 0.0f));
)"
R"(    write_imagef(dst, out_idx[2] + m_offset, (float4)((REGC_LO.s2), 0.0f, 0.0f, 0.0f));
)"
R"(    write_imagef(dst, out_idx[3] + m_offset, (float4)((REGC_LO.s3), 0.0f, 0.0f, 0.0f));
)"
R"(    write_imagef(dst, out_idx[4] + m_offset, (float4)((REGC_LO.s4), 0.0f, 0.0f, 0.0f));
)"
R"(    write_imagef(dst, out_idx[5] + m_offset, (float4)((REGC_LO.s5), 0.0f, 0.0f, 0.0f));
)"
R"(    write_imagef(dst, out_idx[6] + m_offset, (float4)((REGC_LO.s6), 0.0f, 0.0f, 0.0f));
)"
R"(    write_imagef(dst, out_idx[7] + m_offset, (float4)((REGC_LO.s7), 0.0f, 0.0f, 0.0f));
)"
R"(    write_imagef(dst, out_idx[8] + m_offset, (float4)((REGC_LO.s8), 0.0f, 0.0f, 0.0f));
)"
R"(    write_imagef(dst, out_idx[9] + m_offset, (float4)((REGC_LO.s9), 0.0f, 0.0f, 0.0f));
)"
R"(    write_imagef(dst, out_idx[10] + m_offset, (float4)((REGC_LO.sa), 0.0f, 0.0f, 0.0f));
)"
R"(    write_imagef(dst, out_idx[11] + m_offset, (float4)((REGC_LO.sb), 0.0f, 0.0f, 0.0f));
)"
R"(    write_imagef(dst, out_idx[12] + m_offset, (float4)((REGC_LO.sc), 0.0f, 0.0f, 0.0f));
)"
R"(    write_imagef(dst, out_idx[13] + m_offset, (float4)((REGC_LO.sd), 0.0f, 0.0f, 0.0f));
)"
R"(    write_imagef(dst, out_idx[14] + m_offset, (float4)((REGC_LO.se), 0.0f, 0.0f, 0.0f));
)"
R"(    write_imagef(dst, out_idx[15] + m_offset, (float4)((REGC_LO.sf), 0.0f, 0.0f, 0.0f));
)"
R"(    write_imagef(dst, out_idx[16] + m_offset, (float4)((REGC_HI.s0), 0.0f, 0.0f, 0.0f));
)"
R"(    write_imagef(dst, out_idx[17] + m_offset, (float4)((REGC_HI.s1), 0.0f, 0.0f, 0.0f));
)"
R"(    write_imagef(dst, out_idx[18] + m_offset, (float4)((REGC_HI.s2), 0.0f, 0.0f, 0.0f));
)"
R"(    write_imagef(dst, out_idx[19] + m_offset, (float4)((REGC_HI.s3), 0.0f, 0.0f, 0.0f));
)"
R"(    write_imagef(dst, out_idx[20] + m_offset, (float4)((REGC_HI.s4), 0.0f, 0.0f, 0.0f));
)"
R"(    write_imagef(dst, out_idx[21] + m_offset, (float4)((REGC_HI.s5), 0.0f, 0.0f, 0.0f));
)"
R"(    write_imagef(dst, out_idx[22] + m_offset, (float4)((REGC_HI.s6), 0.0f, 0.0f, 0.0f));
)"
R"(    write_imagef(dst, out_idx[23] + m_offset, (float4)((REGC_HI.s7), 0.0f, 0.0f, 0.0f));
)"
R"(    write_imagef(dst, out_idx[24] + m_offset, (float4)((REGC_HI.s8), 0.0f, 0.0f, 0.0f));
)"
R"(    write_imagef(dst, out_idx[25] + m_offset, (float4)((REGC_HI.s9), 0.0f, 0.0f, 0.0f));
)"
R"(    write_imagef(dst, out_idx[26] + m_offset, (float4)((REGC_HI.sa), 0.0f, 0.0f, 0.0f));
)"
R"(    write_imagef(dst, out_idx[27] + m_offset, (float4)((REGC_HI.sb), 0.0f, 0.0f, 0.0f));
)"
R"(    write_imagef(dst, out_idx[28] + m_offset, (float4)((REGC_HI.sc), 0.0f, 0.0f, 0.0f));
)"
R"(    write_imagef(dst, out_idx[29] + m_offset, (float4)((REGC_HI.sd), 0.0f, 0.0f, 0.0f));
)"
R"(    write_imagef(dst, out_idx[30] + m_offset, (float4)((REGC_HI.se), 0.0f, 0.0f, 0.0f));
)"
R"(    write_imagef(dst, out_idx[31] + m_offset, (float4)((REGC_HI.sf), 0.0f, 0.0f, 0.0f));
)"
R"(
)"
R"(    // Store zero padding parts to the index of first output in tile, override correct result in the end
)"
R"(    barrier(CLK_GLOBAL_MEM_FENCE);
)"
R"(    write_imagef(dst, out_idx[0] + m_offset, (float4)((REGC_LO.s0), 0.0f, 0.0f, 0.0f));
)"
R"(}
)"
