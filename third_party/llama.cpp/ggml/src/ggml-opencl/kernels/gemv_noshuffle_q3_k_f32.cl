#pragma OPENCL EXTENSION cl_khr_fp16 : enable
#pragma OPENCL EXTENSION cl_khr_subgroups : enable

// [dspark 2026-10-14] SGB bitcast shims. Host passes -DSGB_FLOAT_BROKEN when
// the driver's online compiler lacks float overloads of sub_group_broadcast
// (Adreno 740: only scalar uint/int/long/ulong exist). Bitcast float<->uint,
// broadcast as integer, cast back — bitwise identical, subgroup-uniform.
// [dspark 2026-10-14] Scalar-float subgroup broadcast. 740's online compiler
// lacks float overloads of sub_group_broadcast entirely -> host passes
// -DSGB_SCALAR_BROKEN and broadcasts go through the uint-bitcast shim.
// 830 (E031.47) has working float broadcast but miscompiles kernels whose
// broadcasts go through an inline wrapper, even in pass-through form
// (NMSE~2.2, 2026-10-14) -> uses the direct builtin. All call sites are
// per-component scalar: no vector broadcast anywhere.
#ifdef SGB_SCALAR_BROKEN
inline float sgb_f(float v, uint lid) {
    return as_float(sub_group_broadcast(as_uint(v), lid));
}
#define SGB_BC(v, lid) sgb_f(v, lid)
#else
#define SGB_BC(v, lid) sub_group_broadcast(v, lid)
#endif

#ifdef cl_qcom_reqd_sub_group_size
#pragma OPENCL EXTENSION cl_qcom_reqd_sub_group_size : enable
#define ADRENO_GPU 1
#define REQD_SUBGROUP_SIZE_64 __attribute__((qcom_reqd_sub_group_size("half")))
#endif

// [dspark 2026-10-14] Batched MUL_MAT_ID for q3_K MoE (#28, v0.3.2): the q3_K
// twin of kernel_mul_mat_id_q4_0_f32_batched, following the validated q4_K
// batched-dodge recipe — ALL scale decoding happens on the host, the kernel
// consumes pre-decoded planes so its scale path is structurally identical to
// the (NMSE=0 on 825/830) q4_0 batched kernel.
//
// q3_K superblock (256 elements) bit layout (ggml-quants.c
// dequantize_row_q3_K): value = d * (sc - 32) * (code2 - (hm ? 0 : 4)) with
//   code2 = 2 bits, hmask = 1 bit/elem, sc = 16 4-bit scales (aux32 shuffle).
// The host folds the aux32 shuffle and d*(sc-32) into fp16 effective-scale
// planes, and re-packs the 2-bit codes / hmask bits into a dense uint plane:
//
//   q image (E layers, uint pixels), per (row-pair rp, 32-block k) 6 uints at
//     pixel rp + j*(M/2) + k*(3*M), j = 0..5:
//       j0: row(2rp)   codes elements 0..15  (element l -> bits 2l)
//       j1: row(2rp)   codes elements 16..31 (element l -> bits 2(l-16))
//       j2: row(2rp)   hmask bits (bit l = element l, 0 = subtract 4)
//       j3/j4/j5: row(2rp+1) same
//   se0 (E layers): per (k, rp) one half2 at rp + k*(M/2):
//       (row 2rp   dl for elements 0..15, row 2rp   dl for elements 16..31)
//   se1 (E layers): same for row 2rp+1.
//   dl = fp16(d * (sc - 32)); the kernel computes w = (code3 - 4) * dl with
//   code3 = code2 | (hm << 2)  (hm=1 -> w = code2, i.e. subtract 0;
//                               hm=0 -> w = code2 - 4), matching the
//   (q >> shift) & 3 minus (hm ? 0 : 4) form of dequantize_row_q3_K.
//
// Requires (host-checked): K % 256 == 0 (superblock scale indexing),
// M % 128 == 0 (no row-pair padding), ids in [0, E).
#define QK_K 256
#define NSUBGROUPS 4
#define SUBGROUP_SIZE 64

// one element: dequant + accumulate. qsh = 2*elem-in-16 group, hsh = elem bit,
// se = the element's fp16 effective scale, yv = regB component, ln = its lane.
#define BMO_Q3K_ELM(tsx, qq, hh, qsh, hsh, se, yv, ln, yy) \
    shared_y = SGB_BC((yy).s##yv, ln); \
    tsx += (float)((int)((((qq) >> (qsh)) & 3u) | ((((hh) >> (hsh)) & 1u) << 2)) - 4) * (float)(se) * shared_y;

// elements 0..15 (activations from lanes 0 and 1): row A = ts.s0 (seA.s0),
// row B = ts.s1 (seB.s0)
#define BMO_Q3K_HI(ts, qA0, qA1, hmA, qB0, qB1, hmB, seA, seB, y) \
    float shared_y; \
    BMO_Q3K_ELM((ts).s0, qA0, hmA,  0,  0, (seA).s0, 0, 0, y) \
    BMO_Q3K_ELM((ts).s1, qB0, hmB,  0,  0, (seB).s0, 0, 0, y) \
    BMO_Q3K_ELM((ts).s0, qA0, hmA,  2,  1, (seA).s0, 1, 0, y) \
    BMO_Q3K_ELM((ts).s1, qB0, hmB,  2,  1, (seB).s0, 1, 0, y) \
    BMO_Q3K_ELM((ts).s0, qA0, hmA,  4,  2, (seA).s0, 2, 0, y) \
    BMO_Q3K_ELM((ts).s1, qB0, hmB,  4,  2, (seB).s0, 2, 0, y) \
    BMO_Q3K_ELM((ts).s0, qA0, hmA,  6,  3, (seA).s0, 3, 0, y) \
    BMO_Q3K_ELM((ts).s1, qB0, hmB,  6,  3, (seB).s0, 3, 0, y) \
    BMO_Q3K_ELM((ts).s0, qA0, hmA,  8,  4, (seA).s0, 4, 0, y) \
    BMO_Q3K_ELM((ts).s1, qB0, hmB,  8,  4, (seB).s0, 4, 0, y) \
    BMO_Q3K_ELM((ts).s0, qA0, hmA, 10,  5, (seA).s0, 5, 0, y) \
    BMO_Q3K_ELM((ts).s1, qB0, hmB, 10,  5, (seB).s0, 5, 0, y) \
    BMO_Q3K_ELM((ts).s0, qA0, hmA, 12,  6, (seA).s0, 6, 0, y) \
    BMO_Q3K_ELM((ts).s1, qB0, hmB, 12,  6, (seB).s0, 6, 0, y) \
    BMO_Q3K_ELM((ts).s0, qA0, hmA, 14,  7, (seA).s0, 7, 0, y) \
    BMO_Q3K_ELM((ts).s1, qB0, hmB, 14,  7, (seB).s0, 7, 0, y) \
    BMO_Q3K_ELM((ts).s0, qA0, hmA, 16,  8, (seA).s0, 0, 1, y) \
    BMO_Q3K_ELM((ts).s1, qB0, hmB, 16,  8, (seB).s0, 0, 1, y) \
    BMO_Q3K_ELM((ts).s0, qA0, hmA, 18,  9, (seA).s0, 1, 1, y) \
    BMO_Q3K_ELM((ts).s1, qB0, hmB, 18,  9, (seB).s0, 1, 1, y) \
    BMO_Q3K_ELM((ts).s0, qA0, hmA, 20, 10, (seA).s0, 2, 1, y) \
    BMO_Q3K_ELM((ts).s1, qB0, hmB, 20, 10, (seB).s0, 2, 1, y) \
    BMO_Q3K_ELM((ts).s0, qA0, hmA, 22, 11, (seA).s0, 3, 1, y) \
    BMO_Q3K_ELM((ts).s1, qB0, hmB, 22, 11, (seB).s0, 3, 1, y) \
    BMO_Q3K_ELM((ts).s0, qA0, hmA, 24, 12, (seA).s0, 4, 1, y) \
    BMO_Q3K_ELM((ts).s1, qB0, hmB, 24, 12, (seB).s0, 4, 1, y) \
    BMO_Q3K_ELM((ts).s0, qA0, hmA, 26, 13, (seA).s0, 5, 1, y) \
    BMO_Q3K_ELM((ts).s1, qB0, hmB, 26, 13, (seB).s0, 5, 1, y) \
    BMO_Q3K_ELM((ts).s0, qA0, hmA, 28, 14, (seA).s0, 6, 1, y) \
    BMO_Q3K_ELM((ts).s1, qB0, hmB, 28, 14, (seB).s0, 6, 1, y) \
    BMO_Q3K_ELM((ts).s0, qA0, hmA, 30, 15, (seA).s0, 7, 1, y) \
    BMO_Q3K_ELM((ts).s1, qB0, hmB, 30, 15, (seB).s0, 7, 1, y)

// elements 16..31 (activations from lanes 2 and 3): codes from qA1/qB1
// (element l -> bit 2(l-16)), hmask bit l; scales seA.s1 / seB.s1
#define BMO_Q3K_LO(ts, qA0, qA1, hmA, qB0, qB1, hmB, seA, seB, y) \
    shared_y = SGB_BC((y).s0, 2); \
    BMO_Q3K_ELM((ts).s0, qA1, hmA,  0, 16, (seA).s1, 0, 2, y) \
    BMO_Q3K_ELM((ts).s1, qB1, hmB,  0, 16, (seB).s1, 0, 2, y) \
    BMO_Q3K_ELM((ts).s0, qA1, hmA,  2, 17, (seA).s1, 1, 2, y) \
    BMO_Q3K_ELM((ts).s1, qB1, hmB,  2, 17, (seB).s1, 1, 2, y) \
    BMO_Q3K_ELM((ts).s0, qA1, hmA,  4, 18, (seA).s1, 2, 2, y) \
    BMO_Q3K_ELM((ts).s1, qB1, hmB,  4, 18, (seB).s1, 2, 2, y) \
    BMO_Q3K_ELM((ts).s0, qA1, hmA,  6, 19, (seA).s1, 3, 2, y) \
    BMO_Q3K_ELM((ts).s1, qB1, hmB,  6, 19, (seB).s1, 3, 2, y) \
    BMO_Q3K_ELM((ts).s0, qA1, hmA,  8, 20, (seA).s1, 4, 2, y) \
    BMO_Q3K_ELM((ts).s1, qB1, hmB,  8, 20, (seB).s1, 4, 2, y) \
    BMO_Q3K_ELM((ts).s0, qA1, hmA, 10, 21, (seA).s1, 5, 2, y) \
    BMO_Q3K_ELM((ts).s1, qB1, hmB, 10, 21, (seB).s1, 5, 2, y) \
    BMO_Q3K_ELM((ts).s0, qA1, hmA, 12, 22, (seA).s1, 6, 2, y) \
    BMO_Q3K_ELM((ts).s1, qB1, hmB, 12, 22, (seB).s1, 6, 2, y) \
    BMO_Q3K_ELM((ts).s0, qA1, hmA, 14, 23, (seA).s1, 7, 2, y) \
    BMO_Q3K_ELM((ts).s1, qB1, hmB, 14, 23, (seB).s1, 7, 2, y) \
    shared_y = SGB_BC((y).s0, 3); \
    BMO_Q3K_ELM((ts).s0, qA1, hmA, 16, 24, (seA).s1, 0, 3, y) \
    BMO_Q3K_ELM((ts).s1, qB1, hmB, 16, 24, (seB).s1, 0, 3, y) \
    BMO_Q3K_ELM((ts).s0, qA1, hmA, 18, 25, (seA).s1, 1, 3, y) \
    BMO_Q3K_ELM((ts).s1, qB1, hmB, 18, 25, (seB).s1, 1, 3, y) \
    BMO_Q3K_ELM((ts).s0, qA1, hmA, 20, 26, (seA).s1, 2, 3, y) \
    BMO_Q3K_ELM((ts).s1, qB1, hmB, 20, 26, (seB).s1, 2, 3, y) \
    BMO_Q3K_ELM((ts).s0, qA1, hmA, 22, 27, (seA).s1, 3, 3, y) \
    BMO_Q3K_ELM((ts).s1, qB1, hmB, 22, 27, (seB).s1, 3, 3, y) \
    BMO_Q3K_ELM((ts).s0, qA1, hmA, 24, 28, (seA).s1, 4, 3, y) \
    BMO_Q3K_ELM((ts).s1, qB1, hmB, 24, 28, (seB).s1, 4, 3, y) \
    BMO_Q3K_ELM((ts).s0, qA1, hmA, 26, 29, (seA).s1, 5, 3, y) \
    BMO_Q3K_ELM((ts).s1, qB1, hmB, 26, 29, (seB).s1, 5, 3, y) \
    BMO_Q3K_ELM((ts).s0, qA1, hmA, 28, 30, (seA).s1, 6, 3, y) \
    BMO_Q3K_ELM((ts).s1, qB1, hmB, 28, 30, (seB).s1, 6, 3, y) \
    BMO_Q3K_ELM((ts).s0, qA1, hmA, 30, 31, (seA).s1, 7, 3, y) \
    BMO_Q3K_ELM((ts).s1, qB1, hmB, 30, 31, (seB).s1, 7, 3, y)

#ifdef ADRENO_GPU
REQD_SUBGROUP_SIZE_64
#endif
__kernel void kernel_mul_mat_id_q3_k_f32_batched(
        read_only  image1d_buffer_t src0_q,   // E transposed q3_K expert layers
        global half2  * src0_se0,             // E layers of row-even fp16 dl pairs
        global half2  * src0_se1,             // E layers of row-odd  fp16 dl pairs
        read_only  image1d_buffer_t src1,     // B: ne11*n_tok columns of K floats
        global int    * ids,                  // MUL_MAT_ID ids tensor (I32)
        int ids_elem_off,                     // element offset of ids base
        global int    * perm,                 // [n_cols] expert-sorted column order (P3); 0 => identity
        global float * dst,                   // destination buffer
        ulong offsetd,                        // byte offset of dst base
        int ne00,                             // K
        int ne01,                             // M (output rows)
        int n_used,                           // expert slots per token
        int n_tok,                            // tokens
        int ne11,                             // src1 columns (1 => broadcast)
        int n_expert,                         // E
        int ids_row,                          // ids row stride in elements
        ulong dst_nb1,                        // dst->nb[1] bytes
        ulong dst_nb2,                        // dst->nb[2] bytes
        int grid_x_per_col,                   // CEIL_DIV(M/2, 64) * 64 (== M/2 when M%128==0)
        ulong q_layer_pix,                    // per-expert q stride (uint pixels)
        ulong se_layer_bytes,                 // per-expert se0/se1 stride (bytes)
        ulong es_base)                        // [dspark M2] view slot offset: ids select
                                              // slots within the view; planes are indexed
                                              // by base slot = es + es_base
{
    uint gid     = get_global_id(0);
    uint slid    = get_sub_group_local_id();
    uint groupId = get_local_id(1);

    uint K  = (uint)ne00;
    uint M  = (uint)ne01;
    uint M2 = M / 2;

    uint colp = gid / (uint)grid_x_per_col;
    uint rp   = gid - colp * (uint)grid_x_per_col;   // row-pair index, rp < M2 (no padding)

    // P3 expert-sorted column order (see kernel_mul_mat_id_q4_0_f32_batched)
    uint col = (perm != (global int *)0) ? (uint)perm[colp] : colp;

    uint t = col / (uint)n_used;
    uint js = col - t * (uint)n_used;              // expert slot

    int e = ids[ids_elem_off + (int)t * ids_row + (int)js];
    bool valid = (e >= 0) && (e < n_expert);
    int  es    = valid ? e : 0;   // safe reads; invalid ids write zeros

    uint LINE_STRIDE_A  = M / 2;
    uint BLOCK_STRIDE_A = 3 * M;                   // 6 uints per (rp, k) = 6*M/2

    const ulong esb = (ulong)es + es_base;
    global half2  * se0row = (global half2 *)((global char *)src0_se0 + esb * se_layer_bytes);
    global half2  * se1row = (global half2 *)((global char *)src0_se1 + esb * se_layer_bytes);
    int qbase = (int)(esb * q_layer_pix);
    int bbase = (int)((ulong)((js % (uint)ne11) + t * (uint)ne11) * (K / 4));
    global float * dstc = (global float *)((global char *)dst + offsetd
                            + (ulong)js * dst_nb1 + (ulong)t * dst_nb2);

    private uint   qA0, qA1, hmA, qB0, qB1, hmB;
    private half2  regS, regM;
    private float8 regB;

    private float2 totalSum = (float2)(0.0f);

    for (uint k = groupId; k < (K / 32); k += NSUBGROUPS) {
        regS = se0row[rp + k * M2];   // row 2rp:   (dl elem 0..15, dl elem 16..31)
        regM = se1row[rp + k * M2];   // row 2rp+1: same

        if (slid < 4) {
            regB.s0123 = read_imagef(src1, bbase + (int)(slid * 2 + k * 8));
            regB.s4567 = read_imagef(src1, bbase + (int)(1 + slid * 2 + k * 8));
        }

        qA0 = read_imageui(src0_q, (int)(rp + qbase + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 0)).x;
        qA1 = read_imageui(src0_q, (int)(rp + qbase + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 1)).x;
        hmA = read_imageui(src0_q, (int)(rp + qbase + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 2)).x;
        qB0 = read_imageui(src0_q, (int)(rp + qbase + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 3)).x;
        qB1 = read_imageui(src0_q, (int)(rp + qbase + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 4)).x;
        hmB = read_imageui(src0_q, (int)(rp + qbase + k * BLOCK_STRIDE_A + LINE_STRIDE_A * 5)).x;

        BMO_Q3K_HI(totalSum, qA0, qA1, hmA, qB0, qB1, hmB, regS, regM, regB);
        BMO_Q3K_LO(totalSum, qA0, qA1, hmA, qB0, qB1, hmB, regS, regM, regB);
    }

    // reduction in local memory, assumes #wave=4
    local float2 reduceLM[SUBGROUP_SIZE * 3];
    if (groupId == 1) reduceLM[SUBGROUP_SIZE * 0 + slid] = totalSum;
    if (groupId == 2) reduceLM[SUBGROUP_SIZE * 1 + slid] = totalSum;
    if (groupId == 3) reduceLM[SUBGROUP_SIZE * 2 + slid] = totalSum;
    barrier(CLK_LOCAL_MEM_FENCE);
    if (groupId == 0) {
        totalSum += reduceLM[SUBGROUP_SIZE * 0 + slid];
        totalSum += reduceLM[SUBGROUP_SIZE * 1 + slid];
        totalSum += reduceLM[SUBGROUP_SIZE * 2 + slid];
        if (valid) {
            if (rp * 2 + 0 < M) dstc[rp * 2 + 0] = totalSum.s0;
            if (rp * 2 + 1 < M) dstc[rp * 2 + 1] = totalSum.s1;
        } else {
            if (rp * 2 + 0 < M) dstc[rp * 2 + 0] = 0.0f;
            if (rp * 2 + 1 < M) dstc[rp * 2 + 1] = 0.0f;
        }
    }
}
