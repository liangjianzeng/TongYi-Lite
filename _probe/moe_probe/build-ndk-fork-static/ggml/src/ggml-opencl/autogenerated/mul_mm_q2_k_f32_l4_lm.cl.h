R"(#pragma OPENCL EXTENSION cl_khr_fp16 : enable
)"
R"(
)"
R"(#ifdef cl_intel_required_subgroup_size
)"
R"(#define INTEL_GPU 1
)"
R"(#endif
)"
R"(
)"
R"(#define QK_K 256
)"
R"(
)"
R"(struct block_q2_K {
)"
R"(    uchar scales[QK_K/16];
)"
R"(    uchar qs[QK_K/4];
)"
R"(    half  d;
)"
R"(    half  dmin;
)"
R"(};
)"
R"(
)"
R"(#define LOAD_VEC_A 4
)"
R"(#define LOAD_VEC_B 4
)"
R"(
)"
R"(#define BM 64
)"
R"(#define BN 64
)"
R"(#ifndef BK
)"
R"(#define BK 32
)"
R"(#endif
)"
R"(#ifdef INTEL_GPU
)"
R"(#define TM 8
)"
R"(#else
)"
R"(#define TM 4
)"
R"(#endif
)"
R"(#define TN 8
)"
R"(
)"
R"(#ifndef LM_HALF
)"
R"(#define LM_HALF 0
)"
R"(#endif
)"
R"(#if LM_HALF
)"
R"(typedef half lm_st;
)"
R"(#define LM_LD4(p, i) convert_float4(vload4((i), (p)))
)"
R"(#else
)"
R"(typedef float lm_st;
)"
R"(#define LM_LD4(p, i) vload4((i), (p))
)"
R"(#endif
)"
R"(
)"
R"(kernel void kernel_mul_mm_q2_k_f32_l4_lm(
)"
R"(    global uchar * src0_qs,
)"
R"(    global uchar * src0_sc,
)"
R"(    global half * src0_dm,
)"
R"(    ulong offset0,
)"
R"(    global float4 * src1,
)"
R"(    ulong offset1,
)"
R"(    global float  * dst,
)"
R"(    ulong offsetd,
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
R"(    local lm_st buf_a[BM * BK];
)"
R"(    local lm_st buf_b[BN * BK];
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
R"(    // pos_a counts elements, not blocks - one q2_K super block holds QK_K of them
)"
R"(    int pos_a = batch_idx_a * batch_stride_a + ir * BM * stride_a;
)"
R"(    int pos_b = (batch_idx   * batch_stride_b + ic * BN * stride_b) / LOAD_VEC_B;
)"
R"(
)"
R"(    float4 sums4[(TM/4) * TN];
)"
R"(    float4 cache_a4[TM/4];
)"
R"(
)"
R"(    for (int i = 0; i < (TM/4) * TN; i++) {
)"
R"(        sums4[i] = (float4)(0.0f);
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
R"(                int idx = pos_a + (loadc_a + l) * stride_a + loadr_a * LOAD_VEC_A;
)"
R"(                int ib  = idx / QK_K;
)"
R"(                ib += offset0/sizeof(struct block_q2_K);
)"
R"(                int e   = idx % QK_K;
)"
R"(
)"
R"(                // dequantize_row_q2_K walks 2 halves of 128, each as 4 shifts of
)"
R"(                // 2 groups of 16. Recover that position from the element index.
)"
R"(                int n     = e >> 7;
)"
R"(                int rem   = e & 127;
)"
R"(                int j     = rem >> 5;
)"
R"(                int s     = (rem >> 4) & 1;
)"
R"(                int l16   = rem & 15;
)"
R"(                int isc   = 8*n + 2*j + s;
)"
R"(                int shift = 2*j;
)"
R"(
)"
R"(                uchar sc = src0_sc[16*ib + isc];
)"
R"(                float d  =  (float)src0_dm[2*ib]    * (float)(sc & 0xF);
)"
R"(                float m  = -(float)src0_dm[2*ib + 1] * (float)(sc >> 4);
)"
R"(
)"
R"(                uchar4 q = vload4(0, src0_qs + 64*ib + 32*n + 16*s + l16);
)"
R"(                float4 v1 = convert_float4((uchar4)((q.s0 >> shift) & 3,
)"
R"(                                                    (q.s1 >> shift) & 3,
)"
R"(                                                    (q.s2 >> shift) & 3,
)"
R"(                                                    (q.s3 >> shift) & 3)) * d + m;
)"
R"(
)"
R"(                buf_a[(loadr_a * LOAD_VEC_A + 0) * BM + loadc_a + l] = v1.s0;
)"
R"(                buf_a[(loadr_a * LOAD_VEC_A + 1) * BM + loadc_a + l] = v1.s1;
)"
R"(                buf_a[(loadr_a * LOAD_VEC_A + 2) * BM + loadc_a + l] = v1.s2;
)"
R"(                buf_a[(loadr_a * LOAD_VEC_A + 3) * BM + loadc_a + l] = v1.s3;
)"
R"(            } else {
)"
R"(                buf_a[(loadr_a * LOAD_VEC_A + 0) * BM + loadc_a + l] = 0.0f;
)"
R"(                buf_a[(loadr_a * LOAD_VEC_A + 1) * BM + loadc_a + l] = 0.0f;
)"
R"(                buf_a[(loadr_a * LOAD_VEC_A + 2) * BM + loadc_a + l] = 0.0f;
)"
R"(                buf_a[(loadr_a * LOAD_VEC_A + 3) * BM + loadc_a + l] = 0.0f;
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
R"(        pos_a += BK;
)"
R"(        pos_b += BK / LOAD_VEC_B;
)"
R"(
)"
R"(        for (int i = 0; i < BK; i++) {
)"
R"(            for (int a = 0; a < TM/4; a++) {
)"
R"(                cache_a4[a] = LM_LD4(buf_a + (i) * BM + th_r * TM, a);
)"
R"(            }
)"
R"(
)"
R"(            for (int cc = 0; cc < TN; cc++) {
)"
R"(                const float cache_b = buf_b[(i) * BN + th_c * TN + cc];
)"
R"(                for (int a = 0; a < TM/4; a++) {
)"
R"(                    const int sums_idx = cc*(TM/4) + a;
)"
R"(                    sums4[sums_idx] = mad(cache_a4[a], (float4)cache_b, sums4[sums_idx]);
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
R"(    const ulong offsets = batch_idx * batch_stride_d;
)"
R"(
)"
R"(    for (int cc = 0; cc < TN; cc++) {
)"
R"(        for (int a = 0; a < TM/4; a++) {
)"
R"(            const float4 v = sums4[cc * (TM/4) + a];
)"
R"(            const float  vs[4] = { v.s0, v.s1, v.s2, v.s3 };
)"
R"(            for (int k = 0; k < 4; k++) {
)"
R"(                if (dr + 4*a + k < ne01 && dc + cc < ne11) {
)"
R"(                    dst[offsets + (dc + cc) * stride_d + dr + 4*a + k] = vs[k];
)"
R"(                }
)"
R"(            }
)"
R"(        }
)"
R"(    }
)"
R"(}
)"
