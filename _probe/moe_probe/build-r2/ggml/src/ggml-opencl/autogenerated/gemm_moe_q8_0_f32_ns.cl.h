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
R"(// q8_0: 16 signed int8 weights (one uint4 = 16 chars) -> half16, scaled.
)"
R"(#define dequantize_q8_0(q4, a_f16, scale) \
)"
R"(    a_f16 = convert_half16(as_char16(q4)) * scale;
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
R"(
)"
R"(__attribute__((qcom_wave_pair_mode(1)))
)"
R"(kernel void kernel_gemm_moe_q8_0_f32_ns(
)"
R"(        __global     char *           src0_q,   // flat q8_0 quants  [n_expert*ne01*ne00]
)"
R"(        __global     half *           src0_d,   // flat q8_0 scales  [n_expert*ne01*nb]
)"
R"(        __read_only  image1d_buffer_t src1,     // reordered activations (f32)
)"
R"(        __global     uint *           src2,     // post-router out indices
)"
R"(        __global     ushort *         src2_emap,// expert per tile
)"
R"(        __write_only image1d_buffer_t dst,
)"
R"(        __global     int *            total_tiles,
)"
R"(        uint ne00,
)"
R"(        uint ne01
)"
R"() {
)"
R"(    uint block_id_m = get_global_id(1); // m_tile
)"
R"(    uint block_id_n = get_global_id(2); // n_tile
)"
R"(
)"
R"(    if (block_id_n >= total_tiles[0]) {
)"
R"(        return;
)"
R"(    }
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
R"(    const uint nb = ne00 >> 5;                 // blocks per row (ne00/32)
)"
R"(    const uint w_row = expert_id * ne01 + row + get_local_id(0); // this lane's output row
)"
R"(    __global char * w_q = src0_q + (ulong)w_row * ne00;          // char base for the row
)"
R"(    __global half * w_d = src0_d + (ulong)w_row * nb;            // scale base for the row
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
R"(    // Loop along K axis, 32 elements per iteration, split into 2 sub-blocks.
)"
R"(    for (uint step = 0; step < ne00; step += TILESIZE_K * 2) {
)"
R"(        half s = w_d[step >> 5];               // one q8_0 scale per 32-element block
)"
R"(
)"
R"(        // First sub-block: 16 weights (16 chars = one uint4) at K=step
)"
R"(        uint4 q8x16 = *((__global uint4 *)(w_q + step));
)"
R"(
)"
R"(        uint b_sub_offset = col * ne00 + step;
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
R"(        dequantize_q8_0(q8x16, reg_a, s);
)"
R"(
)"
R"(        sub_group_barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(        half16 acc;
)"
R"(        dotx16_reduce8(reg_a, shared_b, REGC_LO, 0);
)"
R"(        dotx16_reduce8(reg_a, shared_b, REGC_HI, 16);
)"
R"(
)"
R"(        // Second sub-block: next 16 weights at K=step+16
)"
R"(        uint half_step = step + TILESIZE_K;
)"
R"(        q8x16 = *((__global uint4 *)(w_q + half_step));
)"
R"(        b_sub_offset = col * ne00 + half_step;
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
R"(        dequantize_q8_0(q8x16, reg_a, s);
)"
R"(
)"
R"(        sub_group_barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(        dotx16_reduce8(reg_a, shared_b, REGC_LO, 0);
)"
R"(        dotx16_reduce8(reg_a, shared_b, REGC_HI, 16);
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
R"(    barrier(CLK_GLOBAL_MEM_FENCE);
)"
R"(    write_imagef(dst, out_idx[0] + m_offset, (float4)((REGC_LO.s0), 0.0f, 0.0f, 0.0f));
)"
R"(}
)"
