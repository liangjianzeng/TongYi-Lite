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
R"(#define QK_K 256
)"
R"(#define K_SCALE_SIZE 12
)"
R"(
)"
R"(inline void get_scale_min_k4(
)"
R"(    int j,
)"
R"(    global const uchar * q,
)"
R"(    uchar * d,
)"
R"(    uchar * m
)"
R"() {
)"
R"(    if (j < 4) {
)"
R"(        *d = q[j]   & 63;
)"
R"(        *m = q[j+4] & 63;
)"
R"(    } else {
)"
R"(        *d = (q[j+4] & 0x0F) | ((q[j-4] & 0xC0) >> 2);
)"
R"(        *m = ((q[j+4] >> 4) & 0x0F) | ((q[j]   & 0xC0) >> 2);
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(#define dequantize_q4_k(q4, a_f16, scale, minv) \
)"
R"(    a_f16.s0 = (half)((float)(q4.s0 & 0x000F) * scale - minv); \
)"
R"(    a_f16.s1 = (half)((float)((q4.s0 & 0x00F0) >> 4) * scale - minv); \
)"
R"(    a_f16.s2 = (half)((float)((q4.s0 & 0x0F00) >> 8) * scale - minv); \
)"
R"(    a_f16.s3 = (half)((float)((q4.s0 & 0xF000) >> 12) * scale - minv); \
)"
R"(    a_f16.s4 = (half)((float)(q4.s1 & 0x000F) * scale - minv); \
)"
R"(    a_f16.s5 = (half)((float)((q4.s1 & 0x00F0) >> 4) * scale - minv); \
)"
R"(    a_f16.s6 = (half)((float)((q4.s1 & 0x0F00) >> 8) * scale - minv); \
)"
R"(    a_f16.s7 = (half)((float)((q4.s1 & 0xF000) >> 12) * scale - minv); \
)"
R"(    a_f16.s8 = (half)((float)(q4.s2 & 0x000F) * scale - minv); \
)"
R"(    a_f16.s9 = (half)((float)((q4.s2 & 0x00F0) >> 4) * scale - minv); \
)"
R"(    a_f16.sa = (half)((float)((q4.s2 & 0x0F00) >> 8) * scale - minv); \
)"
R"(    a_f16.sb = (half)((float)((q4.s2 & 0xF000) >> 12) * scale - minv); \
)"
R"(    a_f16.sc = (half)((float)(q4.s3 & 0x000F) * scale - minv); \
)"
R"(    a_f16.sd = (half)((float)((q4.s3 & 0x00F0) >> 4) * scale - minv); \
)"
R"(    a_f16.se = (half)((float)((q4.s3 & 0x0F00) >> 8) * scale - minv); \
)"
R"(    a_f16.sf = (half)((float)((q4.s3 & 0xF000) >> 12) * scale - minv); \
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
R"(__attribute__((qcom_wave_pair_mode(1)))
)"
R"(kernel void kernel_gemm_moe_q4_k_f32_ns(
)"
R"(        __read_only  image1d_buffer_t src0_q,
)"
R"(        __global     half *           src0_d,
)"
R"(        __global     half *           src0_dm,
)"
R"(        __global     uchar *          src0_s,
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
R"(    uint num_superblocks = ne00 / QK_K;
)"
R"(    uint scales_per_row = num_superblocks * K_SCALE_SIZE;
)"
R"(    uint row_idx = row + get_global_id(0);
)"
R"(
)"
R"(    // Loop along K axis, 32 elements per iteration (one sub-block), divided into 2 halves of 16
)"
R"(    for (uint step = 0; step < ne00; step += TILESIZE_K * 2) {
)"
R"(        uint sub = step / 32;
)"
R"(        uint sb = sub / 8;
)"
R"(        uint j = sub % 8;
)"
R"(
)"
R"(        // Load d and dm for super-block
)"
R"(        uint d_offset = row + sb * ne01 + expert_id * num_superblocks * ne01 + get_global_id(0);
)"
R"(        half d_val = src0_d[d_offset];
)"
R"(        half dm_val = src0_dm[d_offset];
)"
R"(
)"
R"(        // Load sub-block scale and min
)"
R"(        global const uchar * sc = src0_s + (expert_id * ne01 + row_idx) * scales_per_row + sb * K_SCALE_SIZE;
)"
R"(        uchar sv, mn;
)"
R"(        get_scale_min_k4(j, sc, &sv, &mn);
)"
R"(
)"
R"(        float scale = (float)d_val * (float)sv;
)"
R"(        float minv = (float)dm_val * (float)mn;
)"
R"(
)"
R"(        // First sub-block (16 elements)
)"
R"(        uint q_sub_offset = row + ((ne01 * step) >> 3) + ((expert_id * ne00 * ne01) >> 3);
)"
R"(        uint b_sub_offset = col * ne00 + step;
)"
R"(
)"
R"(        // Load 16 q (64-bits) in transposed layout
)"
R"(        uint2 q4x16;
)"
R"(        q4x16.x = read_imageui(src0_q, q_sub_offset + sub_block_id_m).x;
)"
R"(        q4x16.y = read_imageui(src0_q, q_sub_offset + sub_block_id_m + ne01).x;
)"
R"(
)"
R"(        // Load 16x32 floats from matrix B
)"
R"(        float8 bx8_f32;
)"
R"(        bx8_f32.lo = read_imagef(src1, (b_sub_offset + b_global_offset.x) / 4);
)"
R"(        bx8_f32.hi = read_imagef(src1, (b_sub_offset + b_global_offset.y) / 4);
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
R"(        dequantize_q4_k(as_ushort4(q4x16), reg_a, scale, minv);
)"
R"(
)"
R"(        sub_group_barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
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
R"(        // Second half (next 16 elements, same sub-block scale)
)"
R"(        uint half_step = step + TILESIZE_K;
)"
R"(        q_sub_offset = row + ((ne01 * half_step) >> 3) + ((expert_id * ne00 * ne01) >> 3);
)"
R"(        b_sub_offset = col * ne00 + half_step;
)"
R"(
)"
R"(        q4x16.x = read_imageui(src0_q, q_sub_offset + sub_block_id_m).x;
)"
R"(        q4x16.y = read_imageui(src0_q, q_sub_offset + sub_block_id_m + ne01).x;
)"
R"(
)"
R"(        bx8_f32.lo = read_imagef(src1, (b_sub_offset + b_global_offset.x) / 4);
)"
R"(        bx8_f32.hi = read_imagef(src1, (b_sub_offset + b_global_offset.y) / 4);
)"
R"(        bx8_f16 = convert_half8(bx8_f32);
)"
R"(        shared_b[b_local_offset.x] = bx8_f16.lo;
)"
R"(        shared_b[b_local_offset.y] = bx8_f16.hi;
)"
R"(
)"
R"(        dequantize_q4_k(as_ushort4(q4x16), reg_a, scale, minv);
)"
R"(
)"
R"(        sub_group_barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
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
R"(    // Load post router and share in LM
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
R"(    // Store zero padding parts to the index of first output in tile
)"
R"(    barrier(CLK_GLOBAL_MEM_FENCE);
)"
R"(    write_imagef(dst, out_idx[0] + m_offset, (float4)((REGC_LO.s0), 0.0f, 0.0f, 0.0f));
)"
R"(}
)"
