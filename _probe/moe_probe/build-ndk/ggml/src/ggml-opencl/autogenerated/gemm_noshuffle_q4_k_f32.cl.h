R"(#pragma OPENCL EXTENSION cl_khr_fp16 : enable
)"
R"(
)"
R"(#ifdef cl_qcom_reqd_sub_group_size
)"
R"(#pragma OPENCL EXTENSION cl_qcom_reqd_sub_group_size : enable
)"
R"(#define ADRENO_GPU 1
)"
R"(#define REQD_SUBGROUP_SIZE_128 __attribute__((qcom_reqd_sub_group_size("full")))
)"
R"(#define REQD_SUBGROUP_SIZE_64  __attribute__((qcom_reqd_sub_group_size("half")))
)"
R"(#endif
)"
R"(#define QK_K         256
)"
R"(#define K_SCALE_SIZE 12
)"
R"(
)"
R"(// scales are transposed: consecutive codes of a row are `stride` apart
)"
R"(inline void get_scale_min_k4(
)"
R"(    int j,
)"
R"(    global const uchar * q,
)"
R"(    int stride,
)"
R"(    uchar * d,
)"
R"(    uchar * m,
)"
R"(    uchar mask_d6,
)"
R"(    uchar mask_d4,
)"
R"(    uchar mask_hi2
)"
R"() {
)"
R"(    if (j < 4) {
)"
R"(        *d = q[j*stride]     & mask_d6;
)"
R"(        *m = q[(j+4)*stride] & mask_d6;
)"
R"(    } else {
)"
R"(        *d = (q[(j+4)*stride] & mask_d4) | ((q[(j-4)*stride] & mask_hi2) >> 2);
)"
R"(        *m = ((q[(j+4)*stride] >> 4) & mask_d4) | ((q[j*stride] & mask_hi2) >> 2);
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(#ifdef ADRENO_GPU
)"
R"(REQD_SUBGROUP_SIZE_128
)"
R"(#endif
)"
R"(kernel void kernel_gemm_noshuffle_q4_k_f32(
)"
R"(    global const ushort * src0_q,
)"
R"(    global const uchar  * src0_s,
)"
R"(    global const half   * src0_d,
)"
R"(    global const half   * src0_dm,
)"
R"(    read_only image1d_buffer_t src1,
)"
R"(    global float * dst,
)"
R"(    ulong offsetd,
)"
R"(    int m,
)"
R"(    int n,
)"
R"(    int k,
)"
R"(    int n_no_padding,
)"
R"(    uchar mask_d6,
)"
R"(    uchar mask_d4,
)"
R"(    uchar mask_hi2
)"
R"() {
)"
R"(    dst = (global float *)((global char *)dst + offsetd);
)"
R"(    int n_4 = n >> 2;
)"
R"(    int gy = get_global_id(0);
)"
R"(    int gx = get_global_id(1);
)"
R"(    int gx_2 = gx << 2;
)"
R"(
)"
R"(    half8 c0 = 0, c1 = 0, c2 = 0, c3 = 0;
)"
R"(    half8 B;
)"
R"(    half4 dequantized_weights;
)"
R"(
)"
R"(
)"
R"(    global const ushort * weight_ptr = src0_q + gx_2;
)"
R"(    global const half   * d_ptr      = src0_d  + gx_2;
)"
R"(    global const half   * dm_ptr     = src0_dm + gx_2;
)"
R"(
)"
R"(    for (int i = 0; i < k; i += 32) {
)"
R"(        int sb_idx  = i / QK_K;
)"
R"(        int sub_idx = (i / 32) % 8;
)"
R"(
)"
R"(        half4 d  = vload4(0, d_ptr  + sb_idx * m);
)"
R"(        half4 dm = vload4(0, dm_ptr + sb_idx * m);
)"
R"(
)"
R"(        global const uchar * sc0 = src0_s + sb_idx * K_SCALE_SIZE * m + (gx_2+0);
)"
R"(        global const uchar * sc1 = sc0 + 1;
)"
R"(        global const uchar * sc2 = sc0 + 2;
)"
R"(        global const uchar * sc3 = sc0 + 3;
)"
R"(
)"
R"(        uchar sv0, mn0, sv1, mn1, sv2, mn2, sv3, mn3;
)"
R"(        get_scale_min_k4(sub_idx, sc0, m, &sv0, &mn0, mask_d6, mask_d4, mask_hi2);
)"
R"(        get_scale_min_k4(sub_idx, sc1, m, &sv1, &mn1, mask_d6, mask_d4, mask_hi2);
)"
R"(        get_scale_min_k4(sub_idx, sc2, m, &sv2, &mn2, mask_d6, mask_d4, mask_hi2);
)"
R"(        get_scale_min_k4(sub_idx, sc3, m, &sv3, &mn3, mask_d6, mask_d4, mask_hi2);
)"
R"(
)"
R"(        half4 scale = convert_half4(convert_float4(d)  * convert_float4((uchar4)(sv0, sv1, sv2, sv3)));
)"
R"(        half4 mval  = convert_half4(convert_float4(dm) * convert_float4((uchar4)(mn0, mn1, mn2, mn3)));
)"
R"(
)"
R"(        for (int l = 0; l < 32; l += 4) {
)"
R"(            int ki = i + l;
)"
R"(            ushort4 bits4 = vload4(0, weight_ptr + (ki/4) * m);
)"
R"(
)"
R"(            // j=0
)"
R"(            B.s0123 = read_imageh(src1, gy*2   + (ki+0) * n_4);
)"
R"(            B.s4567 = read_imageh(src1, gy*2+1 + (ki+0) * n_4);
)"
R"(            dequantized_weights.s0 = (bits4.s0 & 0x000F) * scale.s0 - mval.s0;
)"
R"(            dequantized_weights.s1 = (bits4.s1 & 0x000F) * scale.s1 - mval.s1;
)"
R"(            dequantized_weights.s2 = (bits4.s2 & 0x000F) * scale.s2 - mval.s2;
)"
R"(            dequantized_weights.s3 = (bits4.s3 & 0x000F) * scale.s3 - mval.s3;
)"
R"(            c0 += B * dequantized_weights.s0;
)"
R"(            c1 += B * dequantized_weights.s1;
)"
R"(            c2 += B * dequantized_weights.s2;
)"
R"(            c3 += B * dequantized_weights.s3;
)"
R"(
)"
R"(            // j=1
)"
R"(            B.s0123 = read_imageh(src1, gy*2   + (ki+1) * n_4);
)"
R"(            B.s4567 = read_imageh(src1, gy*2+1 + (ki+1) * n_4);
)"
R"(            dequantized_weights.s0 = ((bits4.s0 & 0x00F0) >> 4) * scale.s0 - mval.s0;
)"
R"(            dequantized_weights.s1 = ((bits4.s1 & 0x00F0) >> 4) * scale.s1 - mval.s1;
)"
R"(            dequantized_weights.s2 = ((bits4.s2 & 0x00F0) >> 4) * scale.s2 - mval.s2;
)"
R"(            dequantized_weights.s3 = ((bits4.s3 & 0x00F0) >> 4) * scale.s3 - mval.s3;
)"
R"(            c0 += B * dequantized_weights.s0;
)"
R"(            c1 += B * dequantized_weights.s1;
)"
R"(            c2 += B * dequantized_weights.s2;
)"
R"(            c3 += B * dequantized_weights.s3;
)"
R"(
)"
R"(            // j=2
)"
R"(            B.s0123 = read_imageh(src1, gy*2   + (ki+2) * n_4);
)"
R"(            B.s4567 = read_imageh(src1, gy*2+1 + (ki+2) * n_4);
)"
R"(            dequantized_weights.s0 = ((bits4.s0 & 0x0F00) >> 8) * scale.s0 - mval.s0;
)"
R"(            dequantized_weights.s1 = ((bits4.s1 & 0x0F00) >> 8) * scale.s1 - mval.s1;
)"
R"(            dequantized_weights.s2 = ((bits4.s2 & 0x0F00) >> 8) * scale.s2 - mval.s2;
)"
R"(            dequantized_weights.s3 = ((bits4.s3 & 0x0F00) >> 8) * scale.s3 - mval.s3;
)"
R"(            c0 += B * dequantized_weights.s0;
)"
R"(            c1 += B * dequantized_weights.s1;
)"
R"(            c2 += B * dequantized_weights.s2;
)"
R"(            c3 += B * dequantized_weights.s3;
)"
R"(
)"
R"(            // j=3
)"
R"(            B.s0123 = read_imageh(src1, gy*2   + (ki+3) * n_4);
)"
R"(            B.s4567 = read_imageh(src1, gy*2+1 + (ki+3) * n_4);
)"
R"(            dequantized_weights.s0 = ((bits4.s0 & 0xF000) >> 12) * scale.s0 - mval.s0;
)"
R"(            dequantized_weights.s1 = ((bits4.s1 & 0xF000) >> 12) * scale.s1 - mval.s1;
)"
R"(            dequantized_weights.s2 = ((bits4.s2 & 0xF000) >> 12) * scale.s2 - mval.s2;
)"
R"(            dequantized_weights.s3 = ((bits4.s3 & 0xF000) >> 12) * scale.s3 - mval.s3;
)"
R"(            c0 += B * dequantized_weights.s0;
)"
R"(            c1 += B * dequantized_weights.s1;
)"
R"(            c2 += B * dequantized_weights.s2;
)"
R"(            c3 += B * dequantized_weights.s3;
)"
R"(        }
)"
R"(    }
)"
R"(
)"
R"(    int idx = (gy<<3)*m + (gx<<2);
)"
R"(
)"
R"(    if (idx+3 < m*n_no_padding) {
)"
R"(        vstore4((float4)(c0.s0, c1.s0, c2.s0, c3.s0), 0, dst + idx);
)"
R"(        idx += m;
)"
R"(    }
)"
R"(    if (idx+3 < m*n_no_padding) {
)"
R"(        vstore4((float4)(c0.s1, c1.s1, c2.s1, c3.s1), 0, dst + idx);
)"
R"(        idx += m;
)"
R"(    }
)"
R"(    if (idx+3 < m*n_no_padding) {
)"
R"(        vstore4((float4)(c0.s2, c1.s2, c2.s2, c3.s2), 0, dst + idx);
)"
R"(        idx += m;
)"
R"(    }
)"
R"(    if (idx+3 < m*n_no_padding) {
)"
R"(        vstore4((float4)(c0.s3, c1.s3, c2.s3, c3.s3), 0, dst + idx);
)"
R"(        idx += m;
)"
R"(    }
)"
R"(    if (idx+3 < m*n_no_padding) {
)"
R"(        vstore4((float4)(c0.s4, c1.s4, c2.s4, c3.s4), 0, dst + idx);
)"
R"(        idx += m;
)"
R"(    }
)"
R"(    if (idx+3 < m*n_no_padding) {
)"
R"(        vstore4((float4)(c0.s5, c1.s5, c2.s5, c3.s5), 0, dst + idx);
)"
R"(        idx += m;
)"
R"(    }
)"
R"(    if (idx+3 < m*n_no_padding) {
)"
R"(        vstore4((float4)(c0.s6, c1.s6, c2.s6, c3.s6), 0, dst + idx);
)"
R"(        idx += m;
)"
R"(    }
)"
R"(    if (idx+3 < m*n_no_padding) {
)"
R"(        vstore4((float4)(c0.s7, c1.s7, c2.s7, c3.s7), 0, dst + idx);
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(// 1x8 per-WI tile (1 output row x 8 output cols). For the small-batch
)"
R"(// (medium n_q, e.g. MTP/spec verify) path where the 2x8 kernel is starved:
)"
R"(// at ne1<=8 the grid is (1, ceil(M/2)) -> only ~M/256 workgroups, leaving
)"
R"(// the SP under-occupied. 1 row per WI doubles the M-axis workgroup count
)"
R"(// (ceil(M/1)/128 vs ceil(M/2)/128) AND collapses the accumulators to a
)"
R"(// single half8 (16 regs, no spill), so more waves co-reside. Same weight
)"
R"(// traffic as 2x8 (rows never share weights); the win is pure occupancy.
)"
R"(#ifdef ADRENO_GPU
)"
R"(REQD_SUBGROUP_SIZE_128
)"
R"(#endif
)"
R"(kernel void kernel_gemm_noshuffle_q4_k_f32_r1(
)"
R"(    global const ushort * src0_q,
)"
R"(    global const uchar  * src0_s,
)"
R"(    global const half   * src0_d,
)"
R"(    global const half   * src0_dm,
)"
R"(    read_only image1d_buffer_t src1,
)"
R"(    global float * dst,
)"
R"(    ulong offsetd,
)"
R"(    int m,
)"
R"(    int n,
)"
R"(    int k,
)"
R"(    int n_no_padding,
)"
R"(    uchar mask_d6,
)"
R"(    uchar mask_d4,
)"
R"(    uchar mask_hi2
)"
R"() {
)"
R"(    dst = (global float *)((global char *)dst + offsetd);
)"
R"(    int n_4 = n >> 2;
)"
R"(    int gy = get_global_id(0);
)"
R"(    int gx = get_global_id(1);       // 1 row per WI
)"
R"(
)"
R"(    half8 c0 = 0;
)"
R"(    half8 B;
)"
R"(    half dq;
)"
R"(
)"
R"(    int num_blocks_K = k / QK_K;
)"
R"(
)"
R"(    global const ushort * weight_ptr = src0_q + gx;
)"
R"(    global const half   * d_ptr      = src0_d  + gx;
)"
R"(    global const half   * dm_ptr     = src0_dm + gx;
)"
R"(
)"
R"(    for (int i = 0; i < k; i += 32) {
)"
R"(        int sb_idx  = i / QK_K;
)"
R"(        int sub_idx = (i / 32) % 8;
)"
R"(
)"
R"(        half dd  = d_ptr [sb_idx * m];
)"
R"(        half dmm = dm_ptr[sb_idx * m];
)"
R"(
)"
R"(        global const uchar * sc0 = src0_s + sb_idx * K_SCALE_SIZE * m + gx;
)"
R"(
)"
R"(        uchar sv0, mn0;
)"
R"(        get_scale_min_k4(sub_idx, sc0, m, &sv0, &mn0, mask_d6, mask_d4, mask_hi2);
)"
R"(
)"
R"(        half scale = convert_half(convert_float(dd)  * (float)sv0);
)"
R"(        half mval  = convert_half(convert_float(dmm) * (float)mn0);
)"
R"(
)"
R"(        for (int l = 0; l < 32; l += 4) {
)"
R"(            int ki = i + l;
)"
R"(            ushort bits = weight_ptr[(ki/4) * m];
)"
R"(
)"
R"(            B.s0123 = read_imageh(src1, gy*2   + (ki+0) * n_4);
)"
R"(            B.s4567 = read_imageh(src1, gy*2+1 + (ki+0) * n_4);
)"
R"(            dq = (bits & 0x000F) * scale - mval;
)"
R"(            c0 += B * dq;
)"
R"(
)"
R"(            B.s0123 = read_imageh(src1, gy*2   + (ki+1) * n_4);
)"
R"(            B.s4567 = read_imageh(src1, gy*2+1 + (ki+1) * n_4);
)"
R"(            dq = ((bits & 0x00F0) >> 4) * scale - mval;
)"
R"(            c0 += B * dq;
)"
R"(
)"
R"(            B.s0123 = read_imageh(src1, gy*2   + (ki+2) * n_4);
)"
R"(            B.s4567 = read_imageh(src1, gy*2+1 + (ki+2) * n_4);
)"
R"(            dq = ((bits & 0x0F00) >> 8) * scale - mval;
)"
R"(            c0 += B * dq;
)"
R"(
)"
R"(            B.s0123 = read_imageh(src1, gy*2   + (ki+3) * n_4);
)"
R"(            B.s4567 = read_imageh(src1, gy*2+1 + (ki+3) * n_4);
)"
R"(            dq = ((bits & 0xF000) >> 12) * scale - mval;
)"
R"(            c0 += B * dq;
)"
R"(        }
)"
R"(    }
)"
R"(
)"
R"(    // Output: 8 cols, 1 row per col-step. Scalar store, coalesced across
)"
R"(    // neighbouring WIs (consecutive gx -> consecutive dst addresses).
)"
R"(    int idx = (gy<<3)*m + gx;
)"
R"(    if (idx < m*n_no_padding) { dst[idx] = c0.s0; idx += m; }
)"
R"(    if (idx < m*n_no_padding) { dst[idx] = c0.s1; idx += m; }
)"
R"(    if (idx < m*n_no_padding) { dst[idx] = c0.s2; idx += m; }
)"
R"(    if (idx < m*n_no_padding) { dst[idx] = c0.s3; idx += m; }
)"
R"(    if (idx < m*n_no_padding) { dst[idx] = c0.s4; idx += m; }
)"
R"(    if (idx < m*n_no_padding) { dst[idx] = c0.s5; idx += m; }
)"
R"(    if (idx < m*n_no_padding) { dst[idx] = c0.s6; idx += m; }
)"
R"(    if (idx < m*n_no_padding) { dst[idx] = c0.s7; }
)"
R"(}
)"
R"(
)"
R"(// 2x8 tile, but weights read through an image1d_buffer (CL_R/UINT32 over the
)"
R"(// same packed-q buffer) instead of a plain global buffer. The ne1==1 GEMV
)"
R"(// already does this and is much faster per weight byte than this GEMM at
)"
R"(// small n_q; the structural difference is the image path hits the dedicated
)"
R"(// TPL1 weight cache (L1) while the global path only reaches L2. At small n_q
)"
R"(// the forward is weight-read-bound, so L1-cached weights is the lever.
)"
R"(// The 2 adjacent rows the 2x8 tile reads as a ushort2 are exactly one uint32,
)"
R"(// so the vload2 becomes a single read_imageui at index gx + (ki/4)*(m/2).
)"
R"(#ifdef ADRENO_GPU
)"
R"(REQD_SUBGROUP_SIZE_128
)"
R"(#endif
)"
R"(kernel void kernel_gemm_noshuffle_q4_k_f32_kimg(
)"
R"(    read_only image1d_buffer_t src0_q_img,
)"
R"(    global const uchar  * src0_s,
)"
R"(    global const half   * src0_d,
)"
R"(    global const half   * src0_dm,
)"
R"(    read_only image1d_buffer_t src1,
)"
R"(    global float * dst,
)"
R"(    ulong offsetd,
)"
R"(    int m,
)"
R"(    int n,
)"
R"(    int k,
)"
R"(    int n_no_padding,
)"
R"(    uchar mask_d6,
)"
R"(    uchar mask_d4,
)"
R"(    uchar mask_hi2
)"
R"() {
)"
R"(    dst = (global float *)((global char *)dst + offsetd);
)"
R"(    int n_4 = n >> 2;
)"
R"(    int m_2 = m >> 1;
)"
R"(    int gy = get_global_id(0);
)"
R"(    int gx = get_global_id(1);
)"
R"(    int gx_2 = gx << 1;
)"
R"(
)"
R"(    half8 c0 = 0, c1 = 0;
)"
R"(    half8 B;
)"
R"(    half2 dequantized_weights;
)"
R"(
)"
R"(    int num_blocks_K = k / QK_K;
)"
R"(
)"
R"(    global const half * d_ptr  = src0_d  + gx_2;
)"
R"(    global const half * dm_ptr = src0_dm + gx_2;
)"
R"(
)"
R"(    for (int i = 0; i < k; i += 32) {
)"
R"(        int sb_idx  = i / QK_K;
)"
R"(        int sub_idx = (i / 32) % 8;
)"
R"(
)"
R"(        half2 d  = vload2(0, d_ptr  + sb_idx * m);
)"
R"(        half2 dm = vload2(0, dm_ptr + sb_idx * m);
)"
R"(
)"
R"(        global const uchar * sc0 = src0_s + sb_idx * K_SCALE_SIZE * m + (gx_2+0);
)"
R"(        global const uchar * sc1 = sc0 + 1;
)"
R"(
)"
R"(        uchar sv0, mn0, sv1, mn1;
)"
R"(        get_scale_min_k4(sub_idx, sc0, m, &sv0, &mn0, mask_d6, mask_d4, mask_hi2);
)"
R"(        get_scale_min_k4(sub_idx, sc1, m, &sv1, &mn1, mask_d6, mask_d4, mask_hi2);
)"
R"(
)"
R"(        half2 scale = convert_half2(convert_float2(d)  * convert_float2((uchar2)(sv0, sv1)));
)"
R"(        half2 mval  = convert_half2(convert_float2(dm) * convert_float2((uchar2)(mn0, mn1)));
)"
R"(
)"
R"(        for (int l = 0; l < 32; l += 4) {
)"
R"(            int ki = i + l;
)"
R"(            uint wpacked = read_imageui(src0_q_img, gx + (ki/4) * m_2).x;
)"
R"(            ushort2 bits2 = (ushort2)((ushort)(wpacked & 0xFFFFu), (ushort)(wpacked >> 16));
)"
R"(
)"
R"(            // j=0
)"
R"(            B.s0123 = read_imageh(src1, gy*2   + (ki+0) * n_4);
)"
R"(            B.s4567 = read_imageh(src1, gy*2+1 + (ki+0) * n_4);
)"
R"(            dequantized_weights.s0 = (bits2.s0 & 0x000F) * scale.s0 - mval.s0;
)"
R"(            dequantized_weights.s1 = (bits2.s1 & 0x000F) * scale.s1 - mval.s1;
)"
R"(            c0 += B * dequantized_weights.s0;
)"
R"(            c1 += B * dequantized_weights.s1;
)"
R"(
)"
R"(            // j=1
)"
R"(            B.s0123 = read_imageh(src1, gy*2   + (ki+1) * n_4);
)"
R"(            B.s4567 = read_imageh(src1, gy*2+1 + (ki+1) * n_4);
)"
R"(            dequantized_weights.s0 = ((bits2.s0 & 0x00F0) >> 4) * scale.s0 - mval.s0;
)"
R"(            dequantized_weights.s1 = ((bits2.s1 & 0x00F0) >> 4) * scale.s1 - mval.s1;
)"
R"(            c0 += B * dequantized_weights.s0;
)"
R"(            c1 += B * dequantized_weights.s1;
)"
R"(
)"
R"(            // j=2
)"
R"(            B.s0123 = read_imageh(src1, gy*2   + (ki+2) * n_4);
)"
R"(            B.s4567 = read_imageh(src1, gy*2+1 + (ki+2) * n_4);
)"
R"(            dequantized_weights.s0 = ((bits2.s0 & 0x0F00) >> 8) * scale.s0 - mval.s0;
)"
R"(            dequantized_weights.s1 = ((bits2.s1 & 0x0F00) >> 8) * scale.s1 - mval.s1;
)"
R"(            c0 += B * dequantized_weights.s0;
)"
R"(            c1 += B * dequantized_weights.s1;
)"
R"(
)"
R"(            // j=3
)"
R"(            B.s0123 = read_imageh(src1, gy*2   + (ki+3) * n_4);
)"
R"(            B.s4567 = read_imageh(src1, gy*2+1 + (ki+3) * n_4);
)"
R"(            dequantized_weights.s0 = ((bits2.s0 & 0xF000) >> 12) * scale.s0 - mval.s0;
)"
R"(            dequantized_weights.s1 = ((bits2.s1 & 0xF000) >> 12) * scale.s1 - mval.s1;
)"
R"(            c0 += B * dequantized_weights.s0;
)"
R"(            c1 += B * dequantized_weights.s1;
)"
R"(        }
)"
R"(    }
)"
R"(
)"
R"(    int idx = (gy<<3)*m + (gx<<1);
)"
R"(    if (idx+1 < m*n_no_padding) { vstore2((float2)(c0.s0, c1.s0), 0, dst + idx); idx += m; }
)"
R"(    if (idx+1 < m*n_no_padding) { vstore2((float2)(c0.s1, c1.s1), 0, dst + idx); idx += m; }
)"
R"(    if (idx+1 < m*n_no_padding) { vstore2((float2)(c0.s2, c1.s2), 0, dst + idx); idx += m; }
)"
R"(    if (idx+1 < m*n_no_padding) { vstore2((float2)(c0.s3, c1.s3), 0, dst + idx); idx += m; }
)"
R"(    if (idx+1 < m*n_no_padding) { vstore2((float2)(c0.s4, c1.s4), 0, dst + idx); idx += m; }
)"
R"(    if (idx+1 < m*n_no_padding) { vstore2((float2)(c0.s5, c1.s5), 0, dst + idx); idx += m; }
)"
R"(    if (idx+1 < m*n_no_padding) { vstore2((float2)(c0.s6, c1.s6), 0, dst + idx); idx += m; }
)"
R"(    if (idx+1 < m*n_no_padding) { vstore2((float2)(c0.s7, c1.s7), 0, dst + idx); }
)"
R"(}
)"
R"(
)"
R"(// Cooperative-K GEMM for the small-batch (n_q in [2..8]) path. Mirrors the
)"
R"(// ne1==1 GEMV's structure: a WG is (COK_SG lanes x COK_NSG subgroups); each
)"
R"(// lane owns ONE output row and computes its 8 (padded) columns, and the
)"
R"(// COK_NSG subgroups SPLIT the K reduction round-robin, combining via a
)"
R"(// __local reduction. This is the thing the per-WI GEMM lacked — at small n_q
)"
R"(// the old kernel had ~M/256 workgroups each walking all of K serially; this
)"
R"(// has M/64 workgroups AND COK_NSG-way K parallelism. Uses REQD_SUBGROUP_SIZE_64
)"
R"(// + barrier (same safe reduction pattern as the GEMV; never sub_group_reduce
)"
R"(// at full width on X2 per the GDN miscompile note).
)"
R"(#define COK_NSG 8
)"
R"(#define COK_SG  64
)"
R"(#ifdef ADRENO_GPU
)"
R"(REQD_SUBGROUP_SIZE_64
)"
R"(#endif
)"
R"(kernel void kernel_gemm_noshuffle_q4_k_f32_cok(
)"
R"(    global const ushort * src0_q,
)"
R"(    global const uchar  * src0_s,
)"
R"(    global const half   * src0_d,
)"
R"(    global const half   * src0_dm,
)"
R"(    read_only image1d_buffer_t src1,
)"
R"(    global float * dst,
)"
R"(    ulong offsetd,
)"
R"(    int m,
)"
R"(    int n,
)"
R"(    int k,
)"
R"(    int n_no_padding,
)"
R"(    uchar mask_d6,
)"
R"(    uchar mask_d4,
)"
R"(    uchar mask_hi2
)"
R"() {
)"
R"(    dst = (global float *)((global char *)dst + offsetd);
)"
R"(    int n_4  = n >> 2;
)"
R"(    int gx   = get_global_id(0);     // output row
)"
R"(    int sg   = get_local_id(1);      // subgroup index (K-split lane)
)"
R"(    int lane = get_local_id(0);      // lane within subgroup (0..COK_SG-1)
)"
R"(
)"
R"(    int num_blocks_K = k / QK_K;
)"
R"(    int num_32blk    = k / 32;
)"
R"(
)"
R"(    global const ushort * weight_ptr = src0_q + gx;
)"
R"(    global const half   * d_ptr      = src0_d  + gx;
)"
R"(    global const half   * dm_ptr     = src0_dm + gx;
)"
R"(
)"
R"(    half8 acc = 0;
)"
R"(    half8 B;
)"
R"(    half  dq;
)"
R"(
)"
R"(    for (int blk = sg; blk < num_32blk; blk += COK_NSG) {
)"
R"(        int i       = blk << 5;       // blk * 32
)"
R"(        int sb_idx  = blk >> 3;       // (blk*32) / QK_K  (QK_K = 256 = 32*8)
)"
R"(        int sub_idx = blk & 7;        // (i/32) % 8
)"
R"(
)"
R"(        half dd  = d_ptr [sb_idx * m];
)"
R"(        half dmm = dm_ptr[sb_idx * m];
)"
R"(
)"
R"(        global const uchar * sc0 = src0_s + sb_idx * K_SCALE_SIZE * m + gx;
)"
R"(        uchar sv0, mn0;
)"
R"(        get_scale_min_k4(sub_idx, sc0, m, &sv0, &mn0, mask_d6, mask_d4, mask_hi2);
)"
R"(        half scale = convert_half(convert_float(dd)  * (float)sv0);
)"
R"(        half mval  = convert_half(convert_float(dmm) * (float)mn0);
)"
R"(
)"
R"(        for (int l = 0; l < 32; l += 4) {
)"
R"(            int ki = i + l;
)"
R"(            ushort bits = weight_ptr[(ki>>2) * m];
)"
R"(
)"
R"(            B.s0123 = read_imageh(src1,     (ki+0) * n_4);
)"
R"(            B.s4567 = read_imageh(src1, 1 + (ki+0) * n_4);
)"
R"(            dq = (bits & 0x000F) * scale - mval;
)"
R"(            acc += B * dq;
)"
R"(
)"
R"(            B.s0123 = read_imageh(src1,     (ki+1) * n_4);
)"
R"(            B.s4567 = read_imageh(src1, 1 + (ki+1) * n_4);
)"
R"(            dq = ((bits & 0x00F0) >> 4) * scale - mval;
)"
R"(            acc += B * dq;
)"
R"(
)"
R"(            B.s0123 = read_imageh(src1,     (ki+2) * n_4);
)"
R"(            B.s4567 = read_imageh(src1, 1 + (ki+2) * n_4);
)"
R"(            dq = ((bits & 0x0F00) >> 8) * scale - mval;
)"
R"(            acc += B * dq;
)"
R"(
)"
R"(            B.s0123 = read_imageh(src1,     (ki+3) * n_4);
)"
R"(            B.s4567 = read_imageh(src1, 1 + (ki+3) * n_4);
)"
R"(            dq = ((bits & 0xF000) >> 12) * scale - mval;
)"
R"(            acc += B * dq;
)"
R"(        }
)"
R"(    }
)"
R"(
)"
R"(    // cross-subgroup reduction over the K-split (float for accuracy)
)"
R"(    local float8 reduceLM[COK_SG * (COK_NSG - 1)];
)"
R"(    if (sg > 0) {
)"
R"(        reduceLM[(sg - 1) * COK_SG + lane] = convert_float8(acc);
)"
R"(    }
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(    if (sg == 0) {
)"
R"(        float8 sum = convert_float8(acc);
)"
R"(        for (int s = 0; s < COK_NSG - 1; s++) {
)"
R"(            sum += reduceLM[s * COK_SG + lane];
)"
R"(        }
)"
R"(        int idx = gx;
)"
R"(        if (idx < m*n_no_padding) { dst[idx] = sum.s0; idx += m; }
)"
R"(        if (idx < m*n_no_padding) { dst[idx] = sum.s1; idx += m; }
)"
R"(        if (idx < m*n_no_padding) { dst[idx] = sum.s2; idx += m; }
)"
R"(        if (idx < m*n_no_padding) { dst[idx] = sum.s3; idx += m; }
)"
R"(        if (idx < m*n_no_padding) { dst[idx] = sum.s4; idx += m; }
)"
R"(        if (idx < m*n_no_padding) { dst[idx] = sum.s5; idx += m; }
)"
R"(        if (idx < m*n_no_padding) { dst[idx] = sum.s6; idx += m; }
)"
R"(        if (idx < m*n_no_padding) { dst[idx] = sum.s7; }
)"
R"(    }
)"
R"(}
)"
