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
R"(// [dspark 2026-10-14] Batched MUL_MAT_ID for q3_K MoE (#28, v0.3.2): the q3_K
)"
R"(// twin of kernel_mul_mat_id_q4_0_f32_batched, following the validated q4_K
)"
R"(// batched-dodge recipe — ALL scale decoding happens on the host, the kernel
)"
R"(// consumes pre-decoded planes so its scale path is structurally identical to
)"
R"(// the (NMSE=0 on 825/830) q4_0 batched kernel.
)"
R"(//
)"
R"(// q3_K superblock (256 elements) bit layout (ggml-quants.c
)"
R"(// dequantize_row_q3_K): value = d * (sc - 32) * (code2 - (hm ? 0 : 4)) with
)"
R"(//   code2 = 2 bits, hmask = 1 bit/elem, sc = 16 4-bit scales (aux32 shuffle).
)"
R"(// The host folds the aux32 shuffle and d*(sc-32) into fp16 effective-scale
)"
R"(// planes, and re-packs the 2-bit codes / hmask bits into a dense uint plane:
)"
R"(//
)"
R"(//   q image (E layers, uint pixels), per (row-pair rp, 32-block k) 6 uints at
)"
R"(//     pixel rp + j*(M/2) + k*(3*M), j = 0..5:
)"
R"(//       j0: row(2rp)   codes elements 0..15  (element l -> bits 2l)
)"
R"(//       j1: row(2rp)   codes elements 16..31 (element l -> bits 2(l-16))
)"
R"(//       j2: row(2rp)   hmask bits (bit l = element l, 0 = subtract 4)
)"
R"(//       j3/j4/j5: row(2rp+1) same
)"
R"(//   se0 (E layers): per (k, rp) one half2 at rp + k*(M/2):
)"
R"(//       (row 2rp   dl for elements 0..15, row 2rp   dl for elements 16..31)
)"
R"(//   se1 (E layers): same for row 2rp+1.
)"
R"(//   dl = fp16(d * (sc - 32)); the kernel computes w = (code3 - 4) * dl with
)"
R"(//   code3 = code2 | (hm << 2)  (hm=1 -> w = code2, i.e. subtract 0;
)"
R"(//                               hm=0 -> w = code2 - 4), matching the
)"
R"(//   (q >> shift) & 3 minus (hm ? 0 : 4) form of dequantize_row_q3_K.
)"
R"(//
)"
R"(// Requires (host-checked): K % 256 == 0 (superblock scale indexing),
)"
R"(// M % 128 == 0 (no row-pair padding), ids in [0, E).
)"
R"(#define QK_K 256
)"
R"(#define NSUBGROUPS 4
)"
R"(#define SUBGROUP_SIZE 64
)"
R"(
)"
R"(// one element: dequant + accumulate. qsh = 2*elem-in-16 group, hsh = elem bit,
)"
R"(// se = the element's fp16 effective scale, yv = regB component, ln = its lane.
)"
R"(#define BMO_Q3K_ELM(tsx, qq, hh, qsh, hsh, se, yv, ln, yy) \
)"
R"(    shared_y = SGB_BC((yy).s##yv, ln); \
)"
R"(    tsx += (float)((int)((((qq) >> (qsh)) & 3u) | ((((hh) >> (hsh)) & 1u) << 2)) - 4) * (float)(se) * shared_y;
)"
R"(
)"
R"(// elements 0..15 (activations from lanes 0 and 1): row A = ts.s0 (seA.s0),
)"
R"(// row B = ts.s1 (seB.s0)
)"
R"(#define BMO_Q3K_HI(ts, qA0, qA1, hmA, qB0, qB1, hmB, seA, seB, y) \
)"
R"(    float shared_y; \
)"
R"(    BMO_Q3K_ELM((ts).s0, qA0, hmA,  0,  0, (seA).s0, 0, 0, y) \
)"
R"(    BMO_Q3K_ELM((ts).s1, qB0, hmB,  0,  0, (seB).s0, 0, 0, y) \
)"
R"(    BMO_Q3K_ELM((ts).s0, qA0, hmA,  2,  1, (seA).s0, 1, 0, y) \
)"
R"(    BMO_Q3K_ELM((ts).s1, qB0, hmB,  2,  1, (seB).s0, 1, 0, y) \
)"
R"(    BMO_Q3K_ELM((ts).s0, qA0, hmA,  4,  2, (seA).s0, 2, 0, y) \
)"
R"(    BMO_Q3K_ELM((ts).s1, qB0, hmB,  4,  2, (seB).s0, 2, 0, y) \
)"
R"(    BMO_Q3K_ELM((ts).s0, qA0, hmA,  6,  3, (seA).s0, 3, 0, y) \
)"
R"(    BMO_Q3K_ELM((ts).s1, qB0, hmB,  6,  3, (seB).s0, 3, 0, y) \
)"
R"(    BMO_Q3K_ELM((ts).s0, qA0, hmA,  8,  4, (seA).s0, 4, 0, y) \
)"
R"(    BMO_Q3K_ELM((ts).s1, qB0, hmB,  8,  4, (seB).s0, 4, 0, y) \
)"
R"(    BMO_Q3K_ELM((ts).s0, qA0, hmA, 10,  5, (seA).s0, 5, 0, y) \
)"
R"(    BMO_Q3K_ELM((ts).s1, qB0, hmB, 10,  5, (seB).s0, 5, 0, y) \
)"
R"(    BMO_Q3K_ELM((ts).s0, qA0, hmA, 12,  6, (seA).s0, 6, 0, y) \
)"
R"(    BMO_Q3K_ELM((ts).s1, qB0, hmB, 12,  6, (seB).s0, 6, 0, y) \
)"
R"(    BMO_Q3K_ELM((ts).s0, qA0, hmA, 14,  7, (seA).s0, 7, 0, y) \
)"
R"(    BMO_Q3K_ELM((ts).s1, qB0, hmB, 14,  7, (seB).s0, 7, 0, y) \
)"
R"(    BMO_Q3K_ELM((ts).s0, qA0, hmA, 16,  8, (seA).s0, 0, 1, y) \
)"
R"(    BMO_Q3K_ELM((ts).s1, qB0, hmB, 16,  8, (seB).s0, 0, 1, y) \
)"
R"(    BMO_Q3K_ELM((ts).s0, qA0, hmA, 18,  9, (seA).s0, 1, 1, y) \
)"
R"(    BMO_Q3K_ELM((ts).s1, qB0, hmB, 18,  9, (seB).s0, 1, 1, y) \
)"
R"(    BMO_Q3K_ELM((ts).s0, qA0, hmA, 20, 10, (seA).s0, 2, 1, y) \
)"
R"(    BMO_Q3K_ELM((ts).s1, qB0, hmB, 20, 10, (seB).s0, 2, 1, y) \
)"
R"(    BMO_Q3K_ELM((ts).s0, qA0, hmA, 22, 11, (seA).s0, 3, 1, y) \
)"
R"(    BMO_Q3K_ELM((ts).s1, qB0, hmB, 22, 11, (seB).s0, 3, 1, y) \
)"
R"(    BMO_Q3K_ELM((ts).s0, qA0, hmA, 24, 12, (seA).s0, 4, 1, y) \
)"
R"(    BMO_Q3K_ELM((ts).s1, qB0, hmB, 24, 12, (seB).s0, 4, 1, y) \
)"
R"(    BMO_Q3K_ELM((ts).s0, qA0, hmA, 26, 13, (seA).s0, 5, 1, y) \
)"
R"(    BMO_Q3K_ELM((ts).s1, qB0, hmB, 26, 13, (seB).s0, 5, 1, y) \
)"
R"(    BMO_Q3K_ELM((ts).s0, qA0, hmA, 28, 14, (seA).s0, 6, 1, y) \
)"
R"(    BMO_Q3K_ELM((ts).s1, qB0, hmB, 28, 14, (seB).s0, 6, 1, y) \
)"
R"(    BMO_Q3K_ELM((ts).s0, qA0, hmA, 30, 15, (seA).s0, 7, 1, y) \
)"
R"(    BMO_Q3K_ELM((ts).s1, qB0, hmB, 30, 15, (seB).s0, 7, 1, y)
)"
R"(
)"
R"(// elements 16..31 (activations from lanes 2 and 3): codes from qA1/qB1
)"
R"(// (element l -> bit 2(l-16)), hmask bit l; scales seA.s1 / seB.s1
)"
R"(#define BMO_Q3K_LO(ts, qA0, qA1, hmA, qB0, qB1, hmB, seA, seB, y) \
)"
R"(    shared_y = SGB_BC((y).s0, 2); \
)"
R"(    BMO_Q3K_ELM((ts).s0, qA1, hmA,  0, 16, (seA).s1, 0, 2, y) \
)"
R"(    BMO_Q3K_ELM((ts).s1, qB1, hmB,  0, 16, (seB).s1, 0, 2, y) \
)"
R"(    BMO_Q3K_ELM((ts).s0, qA1, hmA,  2, 17, (seA).s1, 1, 2, y) \
)"
R"(    BMO_Q3K_ELM((ts).s1, qB1, hmB,  2, 17, (seB).s1, 1, 2, y) \
)"
R"(    BMO_Q3K_ELM((ts).s0, qA1, hmA,  4, 18, (seA).s1, 2, 2, y) \
)"
R"(    BMO_Q3K_ELM((ts).s1, qB1, hmB,  4, 18, (seB).s1, 2, 2, y) \
)"
R"(    BMO_Q3K_ELM((ts).s0, qA1, hmA,  6, 19, (seA).s1, 3, 2, y) \
)"
R"(    BMO_Q3K_ELM((ts).s1, qB1, hmB,  6, 19, (seB).s1, 3, 2, y) \
)"
R"(    BMO_Q3K_ELM((ts).s0, qA1, hmA,  8, 20, (seA).s1, 4, 2, y) \
)"
R"(    BMO_Q3K_ELM((ts).s1, qB1, hmB,  8, 20, (seB).s1, 4, 2, y) \
)"
R"(    BMO_Q3K_ELM((ts).s0, qA1, hmA, 10, 21, (seA).s1, 5, 2, y) \
)"
R"(    BMO_Q3K_ELM((ts).s1, qB1, hmB, 10, 21, (seB).s1, 5, 2, y) \
)"
R"(    BMO_Q3K_ELM((ts).s0, qA1, hmA, 12, 22, (seA).s1, 6, 2, y) \
)"
R"(    BMO_Q3K_ELM((ts).s1, qB1, hmB, 12, 22, (seB).s1, 6, 2, y) \
)"
R"(    BMO_Q3K_ELM((ts).s0, qA1, hmA, 14, 23, (seA).s1, 7, 2, y) \
)"
R"(    BMO_Q3K_ELM((ts).s1, qB1, hmB, 14, 23, (seB).s1, 7, 2, y) \
)"
R"(    shared_y = SGB_BC((y).s0, 3); \
)"
R"(    BMO_Q3K_ELM((ts).s0, qA1, hmA, 16, 24, (seA).s1, 0, 3, y) \
)"
R"(    BMO_Q3K_ELM((ts).s1, qB1, hmB, 16, 24, (seB).s1, 0, 3, y) \
)"
R"(    BMO_Q3K_ELM((ts).s0, qA1, hmA, 18, 25, (seA).s1, 1, 3, y) \
)"
R"(    BMO_Q3K_ELM((ts).s1, qB1, hmB, 18, 25, (seB).s1, 1, 3, y) \
)"
R"(    BMO_Q3K_ELM((ts).s0, qA1, hmA, 20, 26, (seA).s1, 2, 3, y) \
)"
R"(    BMO_Q3K_ELM((ts).s1, qB1, hmB, 20, 26, (seB).s1, 2, 3, y) \
)"
R"(    BMO_Q3K_ELM((ts).s0, qA1, hmA, 22, 27, (seA).s1, 3, 3, y) \
)"
R"(    BMO_Q3K_ELM((ts).s1, qB1, hmB, 22, 27, (seB).s1, 3, 3, y) \
)"
R"(    BMO_Q3K_ELM((ts).s0, qA1, hmA, 24, 28, (seA).s1, 4, 3, y) \
)"
R"(    BMO_Q3K_ELM((ts).s1, qB1, hmB, 24, 28, (seB).s1, 4, 3, y) \
)"
R"(    BMO_Q3K_ELM((ts).s0, qA1, hmA, 26, 29, (seA).s1, 5, 3, y) \
)"
R"(    BMO_Q3K_ELM((ts).s1, qB1, hmB, 26, 29, (seB).s1, 5, 3, y) \
)"
R"(    BMO_Q3K_ELM((ts).s0, qA1, hmA, 28, 30, (seA).s1, 6, 3, y) \
)"
R"(    BMO_Q3K_ELM((ts).s1, qB1, hmB, 28, 30, (seB).s1, 6, 3, y) \
)"
R"(    BMO_Q3K_ELM((ts).s0, qA1, hmA, 30, 31, (seA).s1, 7, 3, y) \
)"
R"(    BMO_Q3K_ELM((ts).s1, qB1, hmB, 30, 31, (seB).s1, 7, 3, y)
)"
R"(
)"
R"(#ifdef ADRENO_GPU
)"
R"(REQD_SUBGROUP_SIZE_64
)"
R"(#endif
)"
R"(__kernel void kernel_mul_mat_id_q3_k_f32_batched(
)"
R"(        read_only  image1d_buffer_t src0_q,   // E transposed q3_K expert layers
)"
R"(        global half2  * src0_se0,             // E layers of row-even fp16 dl pairs
)"
R"(        global half2  * src0_se1,             // E layers of row-odd  fp16 dl pairs
)"
R"(        read_only  image1d_buffer_t src1,     // B: ne11*n_tok columns of K floats
)"
R"(        global int    * ids,                  // MUL_MAT_ID ids tensor (I32)
)"
R"(        int ids_elem_off,                     // element offset of ids base
)"
R"(        global int    * perm,                 // [n_cols] expert-sorted column order (P3); 0 => identity
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
R"(        ulong se_layer_bytes,                 // per-expert se0/se1 stride (bytes)
)"
R"(        ulong es_base)                        // [dspark M2] view slot offset: ids select
)"
R"(                                              // slots within the view; planes are indexed
)"
R"(                                              // by base slot = es + es_base
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
R"(    // P3 expert-sorted column order (see kernel_mul_mat_id_q4_0_f32_batched)
)"
R"(    uint col = (perm != (global int *)0) ? (uint)perm[colp] : colp;
)"
R"(
)"
R"(    uint t = col / (uint)n_used;
)"
R"(    uint js = col - t * (uint)n_used;              // expert slot
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
R"(    uint BLOCK_STRIDE_A = 3 * M;                   // 6 uints per (rp, k) = 6*M/2
)"
R"(
)"
R"(    const ulong esb = (ulong)es + es_base;
)"
R"(    global half2  * se0row = (global half2 *)((global char *)src0_se0 + esb * se_layer_bytes);
)"
R"(    global half2  * se1row = (global half2 *)((global char *)src0_se1 + esb * se_layer_bytes);
)"
R"(    int qbase = (int)(esb * q_layer_pix);
)"
R"(    int bbase = (int)((ulong)((js % (uint)ne11) + t * (uint)ne11) * (K / 4));
)"
R"(    global float * dstc = (global float *)((global char *)dst + offsetd
)"
R"(                            + (ulong)js * dst_nb1 + (ulong)t * dst_nb2);
)"
R"(
)"
R"(    private uint   qA0, qA1, hmA, qB0, qB1, hmB;
)"
R"(    private half2  regS, regM;
)"
R"(    private float8 regB;
)"
R"(
)"
R"(    private float2 totalSum = (float2)(0.0f);
)"
R"(
)"
R"(    for (uint k = groupId; k < (K / 32); k += NSUBGROUPS) {
)"
R"(        regS = se0row[rp + k * M2];   // row 2rp:   (dl elem 0..15, dl elem 16..31)
)"
R"(        regM = se1row[rp + k * M2];   // row 2rp+1: same
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
R"(        qA0 = read_imageui(src0_q, (int)(rp + qbase + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 0)).x;
)"
R"(        qA1 = read_imageui(src0_q, (int)(rp + qbase + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 1)).x;
)"
R"(        hmA = read_imageui(src0_q, (int)(rp + qbase + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 2)).x;
)"
R"(        qB0 = read_imageui(src0_q, (int)(rp + qbase + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 3)).x;
)"
R"(        qB1 = read_imageui(src0_q, (int)(rp + qbase + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 4)).x;
)"
R"(        hmB = read_imageui(src0_q, (int)(rp + qbase + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 5)).x;
)"
R"(
)"
R"(        BMO_Q3K_HI(totalSum, qA0, qA1, hmA, qB0, qB1, hmB, regS, regM, regB);
)"
R"(        BMO_Q3K_LO(totalSum, qA0, qA1, hmA, qB0, qB1, hmB, regS, regM, regB);
)"
R"(    }
)"
R"(
)"
R"(    // reduction in local memory, assumes #wave=4
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
