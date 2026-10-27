R"(#pragma OPENCL EXTENSION cl_khr_fp16 : enable
)"
R"(#pragma OPENCL EXTENSION cl_qcom_reqd_sub_group_size : enable
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
R"(
)"
R"(#ifdef ADRENO_GPU
)"
R"(REQD_SUBGROUP_SIZE_128
)"
R"(#endif
)"
R"(kernel void kernel_gemm_noshuffle_q6_K_f32(
)"
R"(        global const ushort * src0_ql,
)"
R"(        global const uchar  * src0_qh,
)"
R"(        global const ushort * src0_s,
)"
R"(        global const half   * src0_d,
)"
R"(        read_only image1d_buffer_t src1,
)"
R"(        global float * dst,
)"
R"(        ulong offsetd,
)"
R"(        int m,
)"
R"(        int n,
)"
R"(        int k,
)"
R"(        int n_no_padding,
)"
R"(        ushort mask_f000,
)"
R"(        uchar  mask_c0
)"
R"() {
)"
R"(    dst = (global float *)( (global char *)dst + offsetd );
)"
R"(
)"
R"(    int m_4 = m >> 2;
)"
R"(    int n_4 = n >> 2;
)"
R"(
)"
R"(    int gy = get_global_id(0); // n
)"
R"(    int gx = get_global_id(1); // m
)"
R"(    int gx_2 = gx << 2;
)"
R"(
)"
R"(    // [dspark 2026-10-14] fp16 accumulators drift ~1.5-2% at K=4096 on A830
)"
R"(    // (probe6 rel_err 0.022 vs q4_K 0.005; e2e greedy diverges). Accumulate in
)"
R"(    // fp32; the per-term products stay half as before.
)"
R"(    float8 c0 = 0, c1 = 0, c2 = 0, c3 = 0;
)"
R"(    half8 B;
)"
R"(    half4 dequantized_weights;
)"
R"(
)"
R"(    global const ushort * ptr_ql = src0_ql + gx_2;
)"
R"(    global const uchar  * ptr_qh = src0_qh + gx_2;
)"
R"(    global const ushort * ptr_s  = src0_s  + gx_2;
)"
R"(    global const half   * ptr_d  = src0_d  + gx_2;
)"
R"(
)"
R"(    for (int i = 0; i < k; i += 4) {
)"
R"(        // load 4x elements (ushort) of ql on M, each ushort contains 4 weights
)"
R"(        // 4x ushort correspons to 4 rows on M
)"
R"(        ushort4 bits4 = vload4(0, ptr_ql + (i/4)*m); // ql packed in 4s in ushort
)"
R"(        uchar4  bits2 = vload4(0, ptr_qh + (i/4)*m); // qh packed in 4s in uchar
)"
R"(
)"
R"(        // load 4 consecutive scales
)"
R"(        char8 scale_s_8 = as_char8(vload4(0, ptr_s + (i/16/2)*m)); // 1 char scale every 16 elements, packed in 2s
)"
R"(        char4   scale_s = ((i/16) % 2) == 0 ? scale_s_8.s0246 : scale_s_8.s1357; // transposed as ushort, 2 blocks
)"
R"(        half4   scale_d = vload4(0, ptr_d + (i/256)*m);  // 1 half scale every 256 elements
)"
R"(
)"
R"(        // j=0
)"
R"(        // load 2x 4 elements of activations on N, corresponding to 8 rows on N
)"
R"(        B.s0123 = read_imageh(src1, gy*2 + (i + 0)*n_4 + 0);
)"
R"(        B.s4567 = read_imageh(src1, gy*2 + (i + 0)*n_4 + 1);
)"
R"(        dequantized_weights.s0 = (convert_half((bits4.s0 & 0x000F) | ((bits2.s0 & 0x03) << 4)) - 32.f) * scale_s.s0 * scale_d.s0;
)"
R"(        dequantized_weights.s1 = (convert_half((bits4.s1 & 0x000F) | ((bits2.s1 & 0x03) << 4)) - 32.f) * scale_s.s1 * scale_d.s1;
)"
R"(        dequantized_weights.s2 = (convert_half((bits4.s2 & 0x000F) | ((bits2.s2 & 0x03) << 4)) - 32.f) * scale_s.s2 * scale_d.s2;
)"
R"(        dequantized_weights.s3 = (convert_half((bits4.s3 & 0x000F) | ((bits2.s3 & 0x03) << 4)) - 32.f) * scale_s.s3 * scale_d.s3;
)"
R"(        c0 += convert_float8(B) * (float)dequantized_weights.s0;
)"
R"(        c1 += convert_float8(B) * (float)dequantized_weights.s1;
)"
R"(        c2 += convert_float8(B) * (float)dequantized_weights.s2;
)"
R"(        c3 += convert_float8(B) * (float)dequantized_weights.s3;
)"
R"(
)"
R"(        // j=1
)"
R"(        B.s0123 = read_imageh(src1, gy*2 + (i + 1)*n_4 + 0);
)"
R"(        B.s4567 = read_imageh(src1, gy*2 + (i + 1)*n_4 + 1);
)"
R"(        dequantized_weights.s0 = (convert_half((((bits4.s0 & 0x00F0) >> 4) | ((bits2.s0 & 0x0C) << 2))) - 32.f) * scale_s.s0 * scale_d.s0;
)"
R"(        dequantized_weights.s1 = (convert_half((((bits4.s1 & 0x00F0) >> 4) | ((bits2.s1 & 0x0C) << 2))) - 32.f) * scale_s.s1 * scale_d.s1;
)"
R"(        dequantized_weights.s2 = (convert_half((((bits4.s2 & 0x00F0) >> 4) | ((bits2.s2 & 0x0C) << 2))) - 32.f) * scale_s.s2 * scale_d.s2;
)"
R"(        dequantized_weights.s3 = (convert_half((((bits4.s3 & 0x00F0) >> 4) | ((bits2.s3 & 0x0C) << 2))) - 32.f) * scale_s.s3 * scale_d.s3;
)"
R"(        c0 += convert_float8(B) * (float)dequantized_weights.s0;
)"
R"(        c1 += convert_float8(B) * (float)dequantized_weights.s1;
)"
R"(        c2 += convert_float8(B) * (float)dequantized_weights.s2;
)"
R"(        c3 += convert_float8(B) * (float)dequantized_weights.s3;
)"
R"(
)"
R"(        // j=2
)"
R"(        B.s0123 = read_imageh(src1, gy*2 + (i + 2)*n_4 + 0);
)"
R"(        B.s4567 = read_imageh(src1, gy*2 + (i + 2)*n_4 + 1);
)"
R"(        dequantized_weights.s0 = (convert_half((((bits4.s0 & 0x0F00) >> 8) | (bits2.s0 & 0x30))) - 32.f) * scale_s.s0 * scale_d.s0;
)"
R"(        dequantized_weights.s1 = (convert_half((((bits4.s1 & 0x0F00) >> 8) | (bits2.s1 & 0x30))) - 32.f) * scale_s.s1 * scale_d.s1;
)"
R"(        dequantized_weights.s2 = (convert_half((((bits4.s2 & 0x0F00) >> 8) | (bits2.s2 & 0x30))) - 32.f) * scale_s.s2 * scale_d.s2;
)"
R"(        dequantized_weights.s3 = (convert_half((((bits4.s3 & 0x0F00) >> 8) | (bits2.s3 & 0x30))) - 32.f) * scale_s.s3 * scale_d.s3;
)"
R"(        c0 += convert_float8(B) * (float)dequantized_weights.s0;
)"
R"(        c1 += convert_float8(B) * (float)dequantized_weights.s1;
)"
R"(        c2 += convert_float8(B) * (float)dequantized_weights.s2;
)"
R"(        c3 += convert_float8(B) * (float)dequantized_weights.s3;
)"
R"(
)"
R"(        // j=3
)"
R"(        B.s0123 = read_imageh(src1, gy*2 + (i + 3)*n_4 + 0);
)"
R"(        B.s4567 = read_imageh(src1, gy*2 + (i + 3)*n_4 + 1);
)"
R"(        dequantized_weights.s0 = (convert_half((((bits4.s0 & mask_f000) >> 12) | ((bits2.s0 & mask_c0) >> 2))) - 32.f) * scale_s.s0 * scale_d.s0;
)"
R"(        dequantized_weights.s1 = (convert_half((((bits4.s1 & mask_f000) >> 12) | ((bits2.s1 & mask_c0) >> 2))) - 32.f) * scale_s.s1 * scale_d.s1;
)"
R"(        dequantized_weights.s2 = (convert_half((((bits4.s2 & mask_f000) >> 12) | ((bits2.s2 & mask_c0) >> 2))) - 32.f) * scale_s.s2 * scale_d.s2;
)"
R"(        dequantized_weights.s3 = (convert_half((((bits4.s3 & mask_f000) >> 12) | ((bits2.s3 & mask_c0) >> 2))) - 32.f) * scale_s.s3 * scale_d.s3;
)"
R"(        c0 += convert_float8(B) * (float)dequantized_weights.s0;
)"
R"(        c1 += convert_float8(B) * (float)dequantized_weights.s1;
)"
R"(        c2 += convert_float8(B) * (float)dequantized_weights.s2;
)"
R"(        c3 += convert_float8(B) * (float)dequantized_weights.s3;
)"
R"(    }
)"
R"(
)"
R"(    int idx = (gy<<3)*m + (gx<<2);
)"
R"(
)"
R"(    if(idx+3 < m*n_no_padding){
)"
R"(        vstore4((float4)(c0.s0, c1.s0, c2.s0, c3.s0), 0, dst + idx);
)"
R"(        idx += m;
)"
R"(    }
)"
R"(    if(idx+3 < m*n_no_padding){
)"
R"(        vstore4((float4)(c0.s1, c1.s1, c2.s1, c3.s1), 0, dst + idx);
)"
R"(        idx += m;
)"
R"(    }
)"
R"(    if(idx+3 < m*n_no_padding){
)"
R"(        vstore4((float4)(c0.s2, c1.s2, c2.s2, c3.s2), 0, dst + idx);
)"
R"(        idx += m;
)"
R"(    }
)"
R"(    if(idx+3 < m*n_no_padding){
)"
R"(        vstore4((float4)(c0.s3, c1.s3, c2.s3, c3.s3), 0, dst + idx);
)"
R"(        idx += m;
)"
R"(    }
)"
R"(    if(idx+3 < m*n_no_padding){
)"
R"(        vstore4((float4)(c0.s4, c1.s4, c2.s4, c3.s4), 0, dst + idx);
)"
R"(        idx += m;
)"
R"(    }
)"
R"(    if(idx+3 < m*n_no_padding){
)"
R"(        vstore4((float4)(c0.s5, c1.s5, c2.s5, c3.s5), 0, dst + idx);
)"
R"(        idx += m;
)"
R"(    }
)"
R"(    if(idx+3 < m*n_no_padding){
)"
R"(        vstore4((float4)(c0.s6, c1.s6, c2.s6, c3.s6), 0, dst + idx);
)"
R"(        idx += m;
)"
R"(    }
)"
R"(    if(idx+3 < m*n_no_padding){
)"
R"(        vstore4((float4)(c0.s7, c1.s7, c2.s7, c3.s7), 0, dst + idx);
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(// Cooperative-K q6_K GEMM for the small-batch (n_q in [2..8]) path. Same idea
)"
R"(// as the q4_K _cok kernel: WG = (COK_SG lanes x COK_NSG subgroups), each lane
)"
R"(// owns ONE output row (half8 over the 8 padded cols), and the COK_NSG
)"
R"(// subgroups split the K iterations round-robin and combine via a __local
)"
R"(// reduction. Replaces the default 4-row-per-WI tile that walked all of K alone
)"
R"(// (~M/512 WGs + serial reduction) at small n_q. REQD_SUBGROUP_SIZE_64 +
)"
R"(// barrier (never sub_group_reduce at full width on X2).
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
R"(kernel void kernel_gemm_noshuffle_q6_K_f32_cok(
)"
R"(        global const ushort * src0_ql,
)"
R"(        global const uchar  * src0_qh,
)"
R"(        global const ushort * src0_s,
)"
R"(        global const half   * src0_d,
)"
R"(        read_only image1d_buffer_t src1,
)"
R"(        global float * dst,
)"
R"(        ulong offsetd,
)"
R"(        int m,
)"
R"(        int n,
)"
R"(        int k,
)"
R"(        int n_no_padding,
)"
R"(        ushort mask_f000,
)"
R"(        uchar  mask_c0
)"
R"() {
)"
R"(    dst = (global float *)( (global char *)dst + offsetd );
)"
R"(
)"
R"(    int n_4  = n >> 2;
)"
R"(    int gx   = get_global_id(0);     // output row
)"
R"(    int sg   = get_local_id(1);      // subgroup index (K-split)
)"
R"(    int lane = get_local_id(0);      // lane within subgroup
)"
R"(
)"
R"(    global const ushort * ptr_ql = src0_ql + gx;
)"
R"(    global const uchar  * ptr_qh = src0_qh + gx;
)"
R"(    global const ushort * ptr_s  = src0_s  + gx;
)"
R"(    global const half   * ptr_d  = src0_d  + gx;
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
R"(    int num_iter = k >> 2;   // k/4 iterations, 4 k-values each
)"
R"(
)"
R"(    for (int ib = sg; ib < num_iter; ib += COK_NSG) {
)"
R"(        int i = ib << 2;     // ib * 4
)"
R"(
)"
R"(        ushort bits4 = ptr_ql[ib * m];          // ql for row gx at this 4-block
)"
R"(        uchar  bits2 = ptr_qh[ib * m];          // qh
)"
R"(
)"
R"(        ushort s_packed = ptr_s[(i >> 5) * m];  // (i/16/2) = i/32
)"
R"(        char2  sc2      = as_char2(s_packed);
)"
R"(        char   scale_s  = (((i >> 4) & 1) == 0) ? sc2.s0 : sc2.s1; // (i/16)%2
)"
R"(        half   scale_d  = ptr_d[(i >> 8) * m];  // i/256
)"
R"(
)"
R"(        // j=0
)"
R"(        B.s0123 = read_imageh(src1, (i + 0)*n_4 + 0);
)"
R"(        B.s4567 = read_imageh(src1, (i + 0)*n_4 + 1);
)"
R"(        dq = (convert_half((bits4 & 0x000F) | ((bits2 & 0x03) << 4)) - 32.f) * scale_s * scale_d;
)"
R"(        acc += B * dq;
)"
R"(
)"
R"(        // j=1
)"
R"(        B.s0123 = read_imageh(src1, (i + 1)*n_4 + 0);
)"
R"(        B.s4567 = read_imageh(src1, (i + 1)*n_4 + 1);
)"
R"(        dq = (convert_half(((bits4 & 0x00F0) >> 4) | ((bits2 & 0x0C) << 2)) - 32.f) * scale_s * scale_d;
)"
R"(        acc += B * dq;
)"
R"(
)"
R"(        // j=2
)"
R"(        B.s0123 = read_imageh(src1, (i + 2)*n_4 + 0);
)"
R"(        B.s4567 = read_imageh(src1, (i + 2)*n_4 + 1);
)"
R"(        dq = (convert_half(((bits4 & 0x0F00) >> 8) | (bits2 & 0x30)) - 32.f) * scale_s * scale_d;
)"
R"(        acc += B * dq;
)"
R"(
)"
R"(        // j=3
)"
R"(        B.s0123 = read_imageh(src1, (i + 3)*n_4 + 0);
)"
R"(        B.s4567 = read_imageh(src1, (i + 3)*n_4 + 1);
)"
R"(        dq = (convert_half(((bits4 & mask_f000) >> 12) | ((bits2 & mask_c0) >> 2)) - 32.f) * scale_s * scale_d;
)"
R"(        acc += B * dq;
)"
R"(    }
)"
R"(
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
