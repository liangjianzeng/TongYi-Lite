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
R"(kernel void kernel_gemm_noshuffle_iq1_s_f32(
)"
R"(    global const uchar * src0_qs,
)"
R"(    global const ushort * src0_qh,
)"
R"(    global const half  * src0_d,
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
R"(        const uint4 qh = convert_uint4(vload4(0, src0_qh + row + (i / 32) * m));
)"
R"(        const half4 d = vload4(0, src0_d + row + (i / 256) * m);
)"
R"(        const half4 scale = d * convert_half4(2*((qh >> (uint4)(12)) & (uint4)(7)) + 1);
)"
R"(        const float4 delta = select((float4)(-0.875f), (float4)(-1.125f), (qh & (uint4)(0x8000)) != 0);
)"
R"(
)"
R"(        for (int l = 0; l < 16; l += 4) {
)"
R"(            const int ki = i + l;
)"
R"(            const uint4 gi = convert_uint4(vload4(0, src0_qs + row + (ki / 8) * m))
)"
R"(                           | (((qh >> (uint4)(3*((ki / 8) & 3))) & (uint4)(7)) << (uint4)(8));
)"
R"(            const uint4 grid = (uint4)(iq1_s_grid[gi.s0], iq1_s_grid[gi.s1], iq1_s_grid[gi.s2], iq1_s_grid[gi.s3]);
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
R"(                const float4 magnitude = convert_float4((grid >> (uint4)(8*j + (ki & 4))) & (uint4)(15));
)"
R"(                const half4 w = convert_half4(magnitude + delta) * scale;
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
