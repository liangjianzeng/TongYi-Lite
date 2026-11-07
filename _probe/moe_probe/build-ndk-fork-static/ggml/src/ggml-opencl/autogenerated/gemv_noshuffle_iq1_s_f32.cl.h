R"(#pragma OPENCL EXTENSION cl_khr_fp16 : enable
)"
R"(
)"
R"(#define QK_K 256
)"
R"(
)"
R"(#ifndef IQ1_S_MV_NSG
)"
R"(#define IQ1_S_MV_NSG 4
)"
R"(#endif
)"
R"(
)"
R"(inline float4 iq1_s_vals(uint g) {
)"
R"(    return (float4)((float)( g        & 0xFu), (float)((g >>  8) & 0xFu),
)"
R"(                    (float)((g >> 16) & 0xFu), (float)((g >> 24) & 0xFu));
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_gemv_noshuffle_iq1_s_f32(
)"
R"(        __read_only image1d_buffer_t grid_img,
)"
R"(        global const uchar  * src0_qs,
)"
R"(        global const ushort * src0_qh,
)"
R"(        global const half   * src0_d,
)"
R"(        global const float  * src1,
)"
R"(        ulong offset1,
)"
R"(        global float * dst,
)"
R"(        ulong offsetd,
)"
R"(        int ne00,
)"
R"(        int ne01,
)"
R"(        int ne10,
)"
R"(        int ne0
)"
R"() {
)"
R"(    src1 = (global const float *)((global const char *)src1 + offset1);
)"
R"(    dst  = (global float       *)((global char       *)dst  + offsetd);
)"
R"(
)"
R"(    const uint m   = (uint)ne01;
)"
R"(    const uint K   = (uint)ne00;
)"
R"(    const uint nsb = K / QK_K;
)"
R"(
)"
R"(    const uint lid = get_local_id(0);
)"
R"(    const uint sgi = get_local_id(1);
)"
R"(    const uint col = get_group_id(1);
)"
R"(
)"
R"(    global const float * y = src1 + (ulong)col * (uint)ne10;
)"
R"(
)"
R"(#define IQ1_S_GRID(i) (read_imageui(grid_img, (int)(i)).x)
)"
R"(
)"
R"(    const uint mh  = m >> 1;
)"
R"(    const uint j   = get_group_id(0) * 64u + lid;
)"
R"(    const uint row = j << 1;
)"
R"(
)"
R"(    float sumf = 0.f, sumf1 = 0.f;
)"
R"(
)"
R"(    if (j < mh) {
)"
R"(        global const ushort * qsu = (global const ushort *)src0_qs;
)"
R"(
)"
R"(        for (uint ib = sgi; ib < nsb; ib += IQ1_S_MV_NSG) {
)"
R"(            const half2 dh = vload2(j + ib * mh, src0_d);
)"
R"(
)"
R"(            float acc0 = 0.f, acc1 = 0.f;
)"
R"(            for (uint sb = 0; sb < 8u; ++sb) {
)"
R"(                const uint  sub = ib * 8u + sb;
)"
R"(                const ushort2 qhv = vload2(j + sub * mh, src0_qh);
)"
R"(                const uint  h0  = (uint)qhv.s0, h1 = (uint)qhv.s1;
)"
R"(
)"
R"(                const float s0  = (float)(2u * ((h0 >> 12) & 7u) + 1u);
)"
R"(                const float s1  = (float)(2u * ((h1 >> 12) & 7u) + 1u);
)"
R"(                const float t0  = ((h0 & 0x8000u) ? -0.125f : 0.125f) - 1.0f;
)"
R"(                const float t1  = ((h1 & 0x8000u) ? -0.125f : 0.125f) - 1.0f;
)"
R"(
)"
R"(                const uint gb  = j + (sub * 4u) * mh;
)"
R"(                const uint grp = sub * 8u;
)"
R"(
)"
R"(                float a0 = 0.f, a1 = 0.f;
)"
R"(                float4 as = (float4)(0.f);
)"
R"(                for (uint l = 0; l < 4u; ++l) {
)"
R"(                    const uint qsv = (uint)qsu[gb + l * mh];
)"
R"(                    const uint g0  = IQ1_S_GRID(( qsv       & 0xFFu) | ((((h0 >> (3u*l)) & 7u) << 8)));
)"
R"(                    const uint g1  = IQ1_S_GRID(((qsv >> 8) & 0xFFu) | ((((h1 >> (3u*l)) & 7u) << 8)));
)"
R"(
)"
R"(                    const float4 y0 = vload4(grp + 2u*l + 0u, y);
)"
R"(                    const float4 y1 = vload4(grp + 2u*l + 1u, y);
)"
R"(                    as += y0 + y1;
)"
R"(                    a0 += dot(y0, iq1_s_vals(g0)) + dot(y1, iq1_s_vals(g0 >> 4));
)"
R"(                    a1 += dot(y0, iq1_s_vals(g1)) + dot(y1, iq1_s_vals(g1 >> 4));
)"
R"(                }
)"
R"(
)"
R"(                const float asum = as.s0 + as.s1 + as.s2 + as.s3;
)"
R"(                acc0 += s0 * (a0 + t0 * asum);
)"
R"(                acc1 += s1 * (a1 + t1 * asum);
)"
R"(            }
)"
R"(            sumf  += (float)dh.s0 * acc0;
)"
R"(            sumf1 += (float)dh.s1 * acc1;
)"
R"(        }
)"
R"(    }
)"
R"(
)"
R"(#if IQ1_S_MV_NSG > 1
)"
R"(    __local float2 part[IQ1_S_MV_NSG][64];
)"
R"(    part[sgi][lid] = (float2)(sumf, sumf1);
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(    if (sgi != 0) {
)"
R"(        return;
)"
R"(    }
)"
R"(    for (uint s = 1; s < IQ1_S_MV_NSG; ++s) {
)"
R"(        const float2 p = part[s][lid];
)"
R"(        sumf  += p.s0;
)"
R"(        sumf1 += p.s1;
)"
R"(    }
)"
R"(#endif
)"
R"(
)"
R"(    if (j < mh) {
)"
R"(        vstore2((float2)(sumf, sumf1), 0, dst + (ulong)col * (uint)ne0 + row);
)"
R"(    }
)"
R"(#undef IQ1_S_GRID
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_iq1_s_grid_export(global uint * out) {
)"
R"(    const uint i = get_global_id(0);
)"
R"(    if (i < 2048u) {
)"
R"(        out[i] = iq1_s_grid[i];
)"
R"(    }
)"
R"(}
)"
