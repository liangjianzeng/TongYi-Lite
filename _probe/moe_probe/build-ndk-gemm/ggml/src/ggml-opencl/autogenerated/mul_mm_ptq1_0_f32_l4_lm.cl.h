R"(#pragma OPENCL EXTENSION cl_khr_fp16 : enable
)"
R"(
)"
R"(// Tiled GEMM for GGML_TYPE_PTQ1_0 (Prism ternary, group 128, 28 bytes per block).
)"
R"(// Raw block layout is used (same as the matvec path): no SoA conversion at upload.
)"
R"(//
)"
R"(// BK = 32 divides QK_PTQ1_0 = 128, so a K-tile never straddles a quant block
)"
R"(// (host gates ne00 % 128 == 0, which also makes batch_stride_a and stride_a
)"
R"(// multiples of 128, so the per-tile block pointer is exact integer division).
)"
R"(
)"
R"(#define LOAD_VEC_A 8
)"
R"(#define LOAD_VEC_B 4
)"
R"(
)"
R"(#define QK_PTQ1_0 128
)"
R"(
)"
R"(#define BM 64
)"
R"(#define BN 64
)"
R"(#define BK 32
)"
R"(#define TM 4
)"
R"(#define TN 8
)"
R"(
)"
R"(// Ternary block, 28 bytes / 128 values. qs holds 5 trits per byte for the
)"
R"(// first 120 values, qh holds 4 trits per byte for the last 8, both in the
)"
R"(// staged order of dequantize_row_ptq1_0.
)"
R"(typedef struct {
)"
R"(    uchar qs[24];
)"
R"(    uchar qh[2];
)"
R"(    half  d;
)"
R"(} block_ptq1_0;
)"
R"(
)"
R"(// trit at element slot v (0..127) mapped back from the staged storage.
)"
R"(// pow3 is selected by ternary, not a __constant array: the Adreno compiler
)"
R"(// misindexes the 5th element (81), zeroing every n=4 slot to -1 on device.
)"
R"(inline float block_ptq1_0_value(global block_ptq1_0 * qb, int v) {
)"
R"(    uint t;
)"
R"(    if (v < 80) {
)"
R"(        const uint b = qb->qs[v & 15];
)"
R"(        const uint n = v >> 4;
)"
R"(        t = (b * ((n == 4) ? 81u : (n == 3) ? 27u : (n == 2) ? 9u : (n == 1) ? 3u : 1u)) & 0xFFU;
)"
R"(    } else if (v < 120) {
)"
R"(        const uint b = qb->qs[16 + ((v - 80) & 7)];
)"
R"(        const uint n = (v - 80) >> 3;
)"
R"(        t = (b * ((n == 4) ? 81u : (n == 3) ? 27u : (n == 2) ? 9u : (n == 1) ? 3u : 1u)) & 0xFFU;
)"
R"(    } else {
)"
R"(        const uint b = qb->qh[(v - 120) & 1];
)"
R"(        const uint n = (v - 120) >> 1;
)"
R"(        t = (b * ((n == 3) ? 27u : (n == 2) ? 9u : (n == 1) ? 3u : 1u)) & 0xFFU;
)"
R"(    }
)"
R"(    return (float) ((t * 3U) >> 8) - 1.0f;
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_mul_mm_ptq1_0_f32_l4_lm(
)"
R"(    global uchar  * src0,
)"
R"(    ulong          offset0,
)"
R"(    global float4 * src1,
)"
R"(    ulong          offset1,
)"
R"(    global float  * dst,
)"
R"(    ulong          offsetd,
)"
R"(
)"
R"(    int ne00,
)"
R"(    int ne01,
)"
R"(    int ne02,
)"
R"(    int ne11,
)"
R"(    int ne12,
)"
R"(
)"
R"(    int stride_a,
)"
R"(    int stride_b,
)"
R"(    int stride_d,
)"
R"(
)"
R"(    int batch_stride_a,
)"
R"(    int batch_stride_b,
)"
R"(    int batch_stride_d,
)"
R"(
)"
R"(    int r2,
)"
R"(    int r3
)"
R"() {
)"
R"(    src1 = (global float4*)((global char*)src1 + offset1);
)"
R"(    dst  = (global float *)((global char*)dst  + offsetd);
)"
R"(
)"
R"(    global block_ptq1_0 * blocks = (global block_ptq1_0 *)((global char*)src0 + offset0);
)"
R"(
)"
R"(    local float buf_a[BM * BK];
)"
R"(    local float buf_b[BN * BK];
)"
R"(
)"
R"(    const int batch_idx = get_global_id(2);
)"
R"(
)"
R"(    const int i13 = batch_idx / ne12;
)"
R"(    const int i12 = batch_idx % ne12;
)"
R"(
)"
R"(    const int i03 = i13 / r3;
)"
R"(    const int i02 = i12 / r2;
)"
R"(
)"
R"(    const int batch_idx_a = i03 * ne02 + i02;
)"
R"(
)"
R"(    const int ir = get_group_id(0);
)"
R"(    const int ic = get_group_id(1);
)"
R"(
)"
R"(    const int tid = get_local_id(0);
)"
R"(    const int th_r  = tid % (BM / TM);
)"
R"(    const int th_c  = tid / (BM / TM);
)"
R"(
)"
R"(    const int loadr_a = get_local_id(0) % (BK / LOAD_VEC_A);
)"
R"(    const int loadc_a = get_local_id(0) / (BK / LOAD_VEC_A);
)"
R"(    const int loadr_b = get_local_id(0) % (BK / LOAD_VEC_B);
)"
R"(    const int loadc_b = get_local_id(0) / (BK / LOAD_VEC_B);
)"
R"(
)"
R"(    const int loadstride_a = get_local_size(0) * LOAD_VEC_A / BK;
)"
R"(    const int loadstride_b = get_local_size(0) * LOAD_VEC_B / BK;
)"
R"(
)"
R"(    int pos_b = (batch_idx   * batch_stride_b + ic * BN * stride_b) / LOAD_VEC_B;
)"
R"(
)"
R"(    float sums[TM * TN];
)"
R"(    float cache_a[TM];
)"
R"(    float cache_b[TN];
)"
R"(
)"
R"(    for (int i = 0; i < TM * TN; i++) {
)"
R"(        sums[i] = 0.0f;
)"
R"(    }
)"
R"(
)"
R"(    for (int block = 0; block < ne00; block += BK) {
)"
R"(        for (int l = 0; l < BM; l += loadstride_a) {
)"
R"(            if (ir*BM + loadc_a + l < ne01) {
)"
R"(                // Tile start in elements; multiple of BK = 32 and, because
)"
R"(                // stride_a % 128 == 0, always inside a single 128-value block.
)"
R"(                const int e0 = batch_idx_a * batch_stride_a + (ir*BM + loadc_a + l) * stride_a + block;
)"
R"(
)"
R"(                global block_ptq1_0 * qb = blocks + e0 / QK_PTQ1_0;
)"
R"(                const float d = (float)qb->d;
)"
R"(                const int v0 = e0 % QK_PTQ1_0;
)"
R"(                const int kbase = loadr_a * LOAD_VEC_A;
)"
R"(
)"
R"(                for (int b = 0; b < LOAD_VEC_A; ++b) {
)"
R"(                    buf_a[(kbase + b) * BM + loadc_a + l] = d * block_ptq1_0_value(qb, v0 + kbase + b);
)"
R"(                }
)"
R"(            } else {
)"
R"(                for (int b = 0; b < LOAD_VEC_A; ++b) {
)"
R"(                    buf_a[(loadr_a * LOAD_VEC_A + b) * BM + loadc_a + l] = 0.0f;
)"
R"(                }
)"
R"(            }
)"
R"(        }
)"
R"(
)"
R"(        for (int l = 0; l < BN; l += loadstride_b) {
)"
R"(            if (ic*BN + loadc_b + l < ne11) {
)"
R"(                int idx = pos_b + (loadc_b + l) * stride_b / LOAD_VEC_B + loadr_b;
)"
R"(                buf_b[(loadr_b * LOAD_VEC_B + 0) * BN + loadc_b + l] = src1[idx].s0;
)"
R"(                buf_b[(loadr_b * LOAD_VEC_B + 1) * BN + loadc_b + l] = src1[idx].s1;
)"
R"(                buf_b[(loadr_b * LOAD_VEC_B + 2) * BN + loadc_b + l] = src1[idx].s2;
)"
R"(                buf_b[(loadr_b * LOAD_VEC_B + 3) * BN + loadc_b + l] = src1[idx].s3;
)"
R"(            } else {
)"
R"(                buf_b[(loadr_b * LOAD_VEC_B + 0) * BN + loadc_b + l] = 0.0f;
)"
R"(                buf_b[(loadr_b * LOAD_VEC_B + 1) * BN + loadc_b + l] = 0.0f;
)"
R"(                buf_b[(loadr_b * LOAD_VEC_B + 2) * BN + loadc_b + l] = 0.0f;
)"
R"(                buf_b[(loadr_b * LOAD_VEC_B + 3) * BN + loadc_b + l] = 0.0f;
)"
R"(            }
)"
R"(        }
)"
R"(
)"
R"(        barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(        pos_b += BK / LOAD_VEC_B;
)"
R"(
)"
R"(        for (int i = 0; i < BK; i++) {
)"
R"(            for (int j = 0; j < TM; j++) {
)"
R"(                cache_a[j] = buf_a[(i) * BM + th_r * TM + j];
)"
R"(            }
)"
R"(
)"
R"(            for (int j = 0; j < TN; j++) {
)"
R"(                cache_b[j] = buf_b[(i) * BN + th_c * TN + j];
)"
R"(            }
)"
R"(
)"
R"(            for (int cc = 0; cc < TN; cc++) {
)"
R"(                for (int cr = 0; cr < TM; cr++) {
)"
R"(                    const int sums_idx = cc*TM + cr;
)"
R"(                    sums[sums_idx] = mad(cache_a[cr], cache_b[cc], sums[sums_idx]);
)"
R"(                }
)"
R"(            }
)"
R"(        }
)"
R"(        barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(    }
)"
R"(
)"
R"(    const int dr = ir * BM + th_r * TM;
)"
R"(    const int dc = ic * BN + th_c * TN;
)"
R"(
)"
R"(    const int offsets = batch_idx * batch_stride_d;
)"
R"(
)"
R"(    for (int cc = 0; cc < TN; cc++) {
)"
R"(        for (int cr = 0; cr < TM; cr++) {
)"
R"(            if (dr + cr < ne01 && dc + cc < ne11) {
)"
R"(                dst[offsets + (dc + cc) * stride_d + dr + cr] = sums[cc * TM + cr];
)"
R"(            }
)"
R"(        }
)"
R"(    }
)"
R"(}
)"
