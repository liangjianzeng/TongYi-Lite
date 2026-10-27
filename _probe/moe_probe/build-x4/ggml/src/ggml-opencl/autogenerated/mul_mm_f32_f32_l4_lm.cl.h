R"(#pragma OPENCL EXTENSION cl_khr_fp16 : enable
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
R"(#define BK 16
)"
R"(#define TM 4
)"
R"(#define TN 8
)"
R"(
)"
R"(kernel void kernel_mul_mm_f32_f32_l4_lm(
)"
R"(    global float4 * src0,
)"
R"(    ulong offset0,
)"
R"(    global float4 * src1,
)"
R"(    ulong offset1,
)"
R"(    global float * dst,
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
R"(    src0 = (global float4*)((global char*)src0 + offset0);
)"
R"(    src1 = (global float4*)((global char*)src1 + offset1);
)"
R"(    dst = (global float*)((global char*)dst + offsetd);
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
R"(    int pos_a = (batch_idx_a * batch_stride_a + ir * BM * stride_a) / LOAD_VEC_A;
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
R"(                const int idx = pos_a + (loadc_a + l) * stride_a / LOAD_VEC_A + loadr_a;
)"
R"(                buf_a[(loadr_a * LOAD_VEC_A + 0) * BM + loadc_a + l] = src0[idx].s0;
)"
R"(                buf_a[(loadr_a * LOAD_VEC_A + 1) * BM + loadc_a + l] = src0[idx].s1;
)"
R"(                buf_a[(loadr_a * LOAD_VEC_A + 2) * BM + loadc_a + l] = src0[idx].s2;
)"
R"(                buf_a[(loadr_a * LOAD_VEC_A + 3) * BM + loadc_a + l] = src0[idx].s3;
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
R"(                const int idx = pos_b + (loadc_b + l) * stride_b / LOAD_VEC_B + loadr_b;
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
R"(        pos_a += BK / LOAD_VEC_A;
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
R"(
)"
R"(// Multi-column f32 GEMV for the small-N (spec/MTP verify) batch. The tiled GEMM
)"
R"(// above always computes a full BM x BN = 64 x 64 output tile, so at ne11=3 with a
)"
R"(// skinny weight (e.g. GDN ssm_alpha/ssm_beta, M=32) it launches ONE under-occupied
)"
R"(// workgroup at ~2.3% tile utilization. This kernel assigns one 64-thread workgroup
)"
R"(// per output element (m,n): the 64 threads split the K reduction (float4) and
)"
R"(// tree-reduce in __local (no subgroup ops -> portable). ne01*ne11 workgroups.
)"
R"(// Weight row is re-read per column (N small -> negligible). Summation order differs
)"
R"(// from the tiled GEMM (lane-strided + tree) -> f32-exact-ish, not bit-identical.
)"
R"(kernel void kernel_gemv_f32_f32_mc(
)"
R"(    global float * src0, ulong offset0,   // weight: row m at m*stride_a (elements)
)"
R"(    global float * src1, ulong offset1,   // activations: col n at n*stride_b
)"
R"(    global float * dst,  ulong offsetd,   // dst [M x N] col-major: (m,n) at n*stride_d+m
)"
R"(    int ne00,        // K
)"
R"(    int ne01,        // M
)"
R"(    int ne11,        // N
)"
R"(    int stride_a,    // weight row stride (elements) = K
)"
R"(    int stride_b,    // activation col stride (elements) = K
)"
R"(    int stride_d)    // dst column stride (elements) = M
)"
R"({
)"
R"(    src0 = (global float*)((global char*)src0 + offset0);
)"
R"(    src1 = (global float*)((global char*)src1 + offset1);
)"
R"(    dst  = (global float*)((global char*)dst  + offsetd);
)"
R"(
)"
R"(    uint lane = get_local_id(0);            // 0..63
)"
R"(    uint out  = get_global_id(1);           // 0 .. ne01*ne11 - 1
)"
R"(    uint m = out % (uint)ne01;
)"
R"(    uint n = out / (uint)ne01;
)"
R"(
)"
R"(    global float4 * wrow = (global float4*)(src0 + (ulong)m * (uint)stride_a);
)"
R"(    global float4 * xcol = (global float4*)(src1 + (ulong)n * (uint)stride_b);
)"
R"(    uint k4 = (uint)ne00 >> 2;
)"
R"(
)"
R"(    float acc = 0.0f;
)"
R"(    for (uint k = lane; k < k4; k += 64) {
)"
R"(        float4 w = wrow[k];
)"
R"(        float4 x = xcol[k];
)"
R"(        acc += w.s0*x.s0 + w.s1*x.s1 + w.s2*x.s2 + w.s3*x.s3;
)"
R"(    }
)"
R"(
)"
R"(    local float red[64];
)"
R"(    red[lane] = acc;
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(    for (uint s = 32; s > 0; s >>= 1) {
)"
R"(        if (lane < s) red[lane] += red[lane + s];
)"
R"(        barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(    }
)"
R"(    if (lane == 0) dst[(ulong)n * (uint)stride_d + m] = red[0];
)"
R"(}
)"
