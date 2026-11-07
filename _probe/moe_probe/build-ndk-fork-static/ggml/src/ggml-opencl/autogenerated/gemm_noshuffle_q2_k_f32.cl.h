R"(#pragma OPENCL EXTENSION cl_khr_fp16 : enable
)"
R"(
)"
R"(#ifdef cl_qcom_reqd_sub_group_size
)"
R"(#pragma OPENCL EXTENSION cl_qcom_reqd_sub_group_size : enable
)"
R"(__attribute__((qcom_reqd_sub_group_size("full")))
)"
R"(#endif
)"
R"(kernel void kernel_gemm_noshuffle_q2_k_f32(
)"
R"(    global const uchar * src0_qs,
)"
R"(    global const uchar * src0_sc,
)"
R"(    global const half  * src0_dm,
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
R"(    int n_no_padding
)"
R"() {
)"
R"(    dst = (global float *)((global char *)dst + offsetd);
)"
R"(    const int gy = get_global_id(0);
)"
R"(    const int row = get_global_id(1) * 4;
)"
R"(    const int n_4 = n / 4;
)"
R"(    if (row >= m) {
)"
R"(        return;
)"
R"(    }
)"
R"(
)"
R"(    half8 c0 = 0, c1 = 0, c2 = 0, c3 = 0;
)"
R"(    for (int i = 0; i < k; i += 16) {
)"
R"(        const half8 dm = vload8(0, src0_dm + 2 * (row + (i / 256) * m));
)"
R"(        const uchar4 sc = vload4(0, src0_sc + row + (i / 16) * m);
)"
R"(        const half4 scale = convert_half4(convert_float4(dm.s0246) * convert_float4(sc & (uchar4)(15)));
)"
R"(        const half4 mval  = convert_half4(convert_float4(dm.s1357) * convert_float4(sc >> (uchar4)(4)));
)"
R"(
)"
R"(        for (int l = 0; l < 16; l += 4) {
)"
R"(            const int ki = i + l;
)"
R"(            const uchar4 bits = vload4(0, src0_qs + row + (ki / 4) * m);
)"
R"(            #pragma unroll
)"
R"(            for (int j = 0; j < 4; ++j) {
)"
R"(                half8 b;
)"
R"(                b.s0123 = read_imageh(src1, gy * 2     + (ki + j) * n_4);
)"
R"(                b.s4567 = read_imageh(src1, gy * 2 + 1 + (ki + j) * n_4);
)"
R"(                const half4 w = convert_half4((bits >> (uchar4)(2 * j)) & (uchar4)(3)) * scale - mval;
)"
R"(                c0 += b * w.s0;
)"
R"(                c1 += b * w.s1;
)"
R"(                c2 += b * w.s2;
)"
R"(                c3 += b * w.s3;
)"
R"(            }
)"
R"(        }
)"
R"(    }
)"
R"(
)"
R"(    int idx = gy * 8 * m + row;
)"
R"(    if (idx + 3 < m * n_no_padding) {
)"
R"(        vstore4((float4)(c0.s0, c1.s0, c2.s0, c3.s0), 0, dst + idx);
)"
R"(        idx += m;
)"
R"(    }
)"
R"(    if (idx + 3 < m * n_no_padding) {
)"
R"(        vstore4((float4)(c0.s1, c1.s1, c2.s1, c3.s1), 0, dst + idx);
)"
R"(        idx += m;
)"
R"(    }
)"
R"(    if (idx + 3 < m * n_no_padding) {
)"
R"(        vstore4((float4)(c0.s2, c1.s2, c2.s2, c3.s2), 0, dst + idx);
)"
R"(        idx += m;
)"
R"(    }
)"
R"(    if (idx + 3 < m * n_no_padding) {
)"
R"(        vstore4((float4)(c0.s3, c1.s3, c2.s3, c3.s3), 0, dst + idx);
)"
R"(        idx += m;
)"
R"(    }
)"
R"(    if (idx + 3 < m * n_no_padding) {
)"
R"(        vstore4((float4)(c0.s4, c1.s4, c2.s4, c3.s4), 0, dst + idx);
)"
R"(        idx += m;
)"
R"(    }
)"
R"(    if (idx + 3 < m * n_no_padding) {
)"
R"(        vstore4((float4)(c0.s5, c1.s5, c2.s5, c3.s5), 0, dst + idx);
)"
R"(        idx += m;
)"
R"(    }
)"
R"(    if (idx + 3 < m * n_no_padding) {
)"
R"(        vstore4((float4)(c0.s6, c1.s6, c2.s6, c3.s6), 0, dst + idx);
)"
R"(        idx += m;
)"
R"(    }
)"
R"(    if (idx + 3 < m * n_no_padding) {
)"
R"(        vstore4((float4)(c0.s7, c1.s7, c2.s7, c3.s7), 0, dst + idx);
)"
R"(    }
)"
R"(}
)"
