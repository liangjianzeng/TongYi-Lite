#pragma OPENCL EXTENSION cl_khr_fp16 : enable

// Tiled GEMM for GGML_TYPE_PTQ1_0 (Prism ternary, group 128, 28 bytes per block).
// Raw block layout is used (same as the matvec path): no SoA conversion at upload.
//
// BK = 32 divides QK_PTQ1_0 = 128, so a K-tile never straddles a quant block
// (host gates ne00 % 128 == 0, which also makes batch_stride_a and stride_a
// multiples of 128, so the per-tile block pointer is exact integer division).

#define LOAD_VEC_A 8
#define LOAD_VEC_B 4

#define QK_PTQ1_0 128

#define BM 64
#define BN 64
#define BK 32
#define TM 4
#define TN 8

// Ternary block, 28 bytes / 128 values. qs holds 5 trits per byte for the
// first 120 values, qh holds 4 trits per byte for the last 8, both in the
// staged order of dequantize_row_ptq1_0.
typedef struct {
    uchar qs[24];
    uchar qh[2];
    half  d;
} block_ptq1_0;

// trit at element slot v (0..127) mapped back from the staged storage.
// pow3 is selected by ternary, not a __constant array: the Adreno compiler
// misindexes the 5th element (81), zeroing every n=4 slot to -1 on device.
inline float block_ptq1_0_value(global block_ptq1_0 * qb, int v) {
    uint t;
    if (v < 80) {
        const uint b = qb->qs[v & 15];
        const uint n = v >> 4;
        t = (b * ((n == 4) ? 81u : (n == 3) ? 27u : (n == 2) ? 9u : (n == 1) ? 3u : 1u)) & 0xFFU;
    } else if (v < 120) {
        const uint b = qb->qs[16 + ((v - 80) & 7)];
        const uint n = (v - 80) >> 3;
        t = (b * ((n == 4) ? 81u : (n == 3) ? 27u : (n == 2) ? 9u : (n == 1) ? 3u : 1u)) & 0xFFU;
    } else {
        const uint b = qb->qh[(v - 120) & 1];
        const uint n = (v - 120) >> 1;
        t = (b * ((n == 3) ? 27u : (n == 2) ? 9u : (n == 1) ? 3u : 1u)) & 0xFFU;
    }
    return (float) ((t * 3U) >> 8) - 1.0f;
}

kernel void kernel_mul_mm_ptq1_0_f32_l4_lm(
    global uchar  * src0,
    ulong          offset0,
    global float4 * src1,
    ulong          offset1,
    global float  * dst,
    ulong          offsetd,

    int ne00,
    int ne01,
    int ne02,
    int ne11,
    int ne12,

    int stride_a,
    int stride_b,
    int stride_d,

    int batch_stride_a,
    int batch_stride_b,
    int batch_stride_d,

    int r2,
    int r3
) {
    src1 = (global float4*)((global char*)src1 + offset1);
    dst  = (global float *)((global char*)dst  + offsetd);

    global block_ptq1_0 * blocks = (global block_ptq1_0 *)((global char*)src0 + offset0);

    local float buf_a[BM * BK];
    local float buf_b[BN * BK];

    const int batch_idx = get_global_id(2);

    const int i13 = batch_idx / ne12;
    const int i12 = batch_idx % ne12;

    const int i03 = i13 / r3;
    const int i02 = i12 / r2;

    const int batch_idx_a = i03 * ne02 + i02;

    const int ir = get_group_id(0);
    const int ic = get_group_id(1);

    const int tid = get_local_id(0);
    const int th_r  = tid % (BM / TM);
    const int th_c  = tid / (BM / TM);

    const int loadr_a = get_local_id(0) % (BK / LOAD_VEC_A);
    const int loadc_a = get_local_id(0) / (BK / LOAD_VEC_A);
    const int loadr_b = get_local_id(0) % (BK / LOAD_VEC_B);
    const int loadc_b = get_local_id(0) / (BK / LOAD_VEC_B);

    const int loadstride_a = get_local_size(0) * LOAD_VEC_A / BK;
    const int loadstride_b = get_local_size(0) * LOAD_VEC_B / BK;

    int pos_b = (batch_idx   * batch_stride_b + ic * BN * stride_b) / LOAD_VEC_B;

    float sums[TM * TN];
    float cache_a[TM];
    float cache_b[TN];

    for (int i = 0; i < TM * TN; i++) {
        sums[i] = 0.0f;
    }

    for (int block = 0; block < ne00; block += BK) {
        for (int l = 0; l < BM; l += loadstride_a) {
            if (ir*BM + loadc_a + l < ne01) {
                // Tile start in elements; multiple of BK = 32 and, because
                // stride_a % 128 == 0, always inside a single 128-value block.
                const int e0 = batch_idx_a * batch_stride_a + (ir*BM + loadc_a + l) * stride_a + block;

                global block_ptq1_0 * qb = blocks + e0 / QK_PTQ1_0;
                const float d = (float)qb->d;
                const int v0 = e0 % QK_PTQ1_0;
                const int kbase = loadr_a * LOAD_VEC_A;

                for (int b = 0; b < LOAD_VEC_A; ++b) {
                    buf_a[(kbase + b) * BM + loadc_a + l] = d * block_ptq1_0_value(qb, v0 + kbase + b);
                }
            } else {
                for (int b = 0; b < LOAD_VEC_A; ++b) {
                    buf_a[(loadr_a * LOAD_VEC_A + b) * BM + loadc_a + l] = 0.0f;
                }
            }
        }

        for (int l = 0; l < BN; l += loadstride_b) {
            if (ic*BN + loadc_b + l < ne11) {
                int idx = pos_b + (loadc_b + l) * stride_b / LOAD_VEC_B + loadr_b;
                buf_b[(loadr_b * LOAD_VEC_B + 0) * BN + loadc_b + l] = src1[idx].s0;
                buf_b[(loadr_b * LOAD_VEC_B + 1) * BN + loadc_b + l] = src1[idx].s1;
                buf_b[(loadr_b * LOAD_VEC_B + 2) * BN + loadc_b + l] = src1[idx].s2;
                buf_b[(loadr_b * LOAD_VEC_B + 3) * BN + loadc_b + l] = src1[idx].s3;
            } else {
                buf_b[(loadr_b * LOAD_VEC_B + 0) * BN + loadc_b + l] = 0.0f;
                buf_b[(loadr_b * LOAD_VEC_B + 1) * BN + loadc_b + l] = 0.0f;
                buf_b[(loadr_b * LOAD_VEC_B + 2) * BN + loadc_b + l] = 0.0f;
                buf_b[(loadr_b * LOAD_VEC_B + 3) * BN + loadc_b + l] = 0.0f;
            }
        }

        barrier(CLK_LOCAL_MEM_FENCE);

        pos_b += BK / LOAD_VEC_B;

        for (int i = 0; i < BK; i++) {
            for (int j = 0; j < TM; j++) {
                cache_a[j] = buf_a[(i) * BM + th_r * TM + j];
            }

            for (int j = 0; j < TN; j++) {
                cache_b[j] = buf_b[(i) * BN + th_c * TN + j];
            }

            for (int cc = 0; cc < TN; cc++) {
                for (int cr = 0; cr < TM; cr++) {
                    const int sums_idx = cc*TM + cr;
                    sums[sums_idx] = mad(cache_a[cr], cache_b[cc], sums[sums_idx]);
                }
            }
        }
        barrier(CLK_LOCAL_MEM_FENCE);
    }

    const int dr = ir * BM + th_r * TM;
    const int dc = ic * BN + th_c * TN;

    const int offsets = batch_idx * batch_stride_d;

    for (int cc = 0; cc < TN; cc++) {
        for (int cr = 0; cr < TM; cr++) {
            if (dr + cr < ne01 && dc + cc < ne11) {
                dst[offsets + (dc + cc) * stride_d + dr + cr] = sums[cc * TM + cr];
            }
        }
    }
}
