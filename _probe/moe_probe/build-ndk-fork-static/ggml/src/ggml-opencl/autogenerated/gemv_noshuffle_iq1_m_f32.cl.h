R"(#pragma OPENCL EXTENSION cl_khr_fp16 : enable
)"
R"(
)"
R"(#define QK_K 256
)"
R"(#define IQ1_M_DELTA 0.125f
)"
R"(
)"
R"(#ifndef IQ1_M_MV_NSG
)"
R"(#define IQ1_M_MV_NSG 4
)"
R"(#endif
)"
R"(
)"
R"(inline float4 iq1_m_vals(uint g) {
)"
R"(    return (float4)((float)( g        & 0xFu), (float)((g >>  8) & 0xFu),
)"
R"(                    (float)((g >> 16) & 0xFu), (float)((g >> 24) & 0xFu));
)"
R"(}
)"
R"(
)"
R"(inline float iq1_m_super(uint w0, uint w1, uint w2, uint w3) {
)"
R"(    const ushort u16 = (ushort)(((w0 >> 12)) | ((w1 >> 8) & 0x00f0u)
)"
R"(                              | ((w2 >> 4) & 0x0f00u) | (w3 & 0xf000u));
)"
R"(    return (float)as_half(u16);
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_gemv_noshuffle_iq1_m_f32(
)"
R"(        __read_only image1d_buffer_t grid_img,
)"
R"(        global const uchar  * src0_qs,
)"
R"(        global const uchar  * src0_qh,
)"
R"(        global const ushort * src0_sc,
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
R"(#define IQ1_M_GRID(i) (read_imageui(grid_img, (int)(i)).x)
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
R"(        global const ushort * qhu = (global const ushort *)src0_qh;
)"
R"(        global const uint   * scu = (global const uint   *)src0_sc;
)"
R"(
)"
R"(        for (uint ib = sgi; ib < nsb; ib += IQ1_M_MV_NSG) {
)"
R"(            const uint sb = j + (ib * 4u) * mh;
)"
R"(            const uint w0 = scu[sb + 0u * mh];
)"
R"(            const uint w1 = scu[sb + 1u * mh];
)"
R"(            const uint w2 = scu[sb + 2u * mh];
)"
R"(            const uint w3 = scu[sb + 3u * mh];
)"
R"(            const float d0 = iq1_m_super( w0        & 0xFFFFu,  w1        & 0xFFFFu,
)"
R"(                                         w2        & 0xFFFFu,  w3        & 0xFFFFu);
)"
R"(            const float d1 = iq1_m_super((w0 >> 16) & 0xFFFFu, (w1 >> 16) & 0xFFFFu,
)"
R"(                                        (w2 >> 16) & 0xFFFFu, (w3 >> 16) & 0xFFFFu);
)"
R"(
)"
R"(            float acc0 = 0.f, acc1 = 0.f;
)"
R"(
)"
R"(            for (uint sub_l = 0; sub_l < 8u; ++sub_l) {
)"
R"(                const uint sub = ib * 8u + sub_l;
)"
R"(                const uint scw = scu[j + (ib * 4u + (sub_l >> 1)) * mh];
)"
R"(                const uint grp = sub * 8u;
)"
R"(                const uint shb = 3u * (2u * (sub_l & 1u));
)"
R"(
)"
R"(                for (uint l = 0; l < 4u; ++l) {
)"
R"(                    const uint sh  = shb + 3u * (l >> 1);
)"
R"(                    const float s0 = (float)(2u * (((scw       ) >> sh) & 7u) + 1u);
)"
R"(                    const float s1 = (float)(2u * (((scw >> 16) >> sh) & 7u) + 1u);
)"
R"(
)"
R"(                    const uint qhv = (uint)qhu[j + (sub * 2u + (l >> 1)) * mh];
)"
R"(                    const uint h0  =  qhv       & 0xFFu;
)"
R"(                    const uint h1  = (qhv >> 8) & 0xFFu;
)"
R"(                    const uint qsv = (uint)qsu[j + (sub * 4u + l) * mh];
)"
R"(
)"
R"(                    const uint msk = 0x08u << (4u * (l & 1u));
)"
R"(                    const float t0 = (h0 & msk) ? (-1.f - IQ1_M_DELTA) : (-1.f + IQ1_M_DELTA);
)"
R"(                    const float t1 = (h1 & msk) ? (-1.f - IQ1_M_DELTA) : (-1.f + IQ1_M_DELTA);
)"
R"(
)"
R"(                    const uint g0 = IQ1_M_GRID(( qsv       & 0xFFu)
)"
R"(                                              | ((((h0 >> (4u*(l & 1u))) & 7u) << 8)));
)"
R"(                    const uint g1 = IQ1_M_GRID(((qsv >> 8) & 0xFFu)
)"
R"(                                              | ((((h1 >> (4u*(l & 1u))) & 7u) << 8)));
)"
R"(
)"
R"(                    const float4 y0 = vload4(grp + 2u*l + 0u, y);
)"
R"(                    const float4 y1 = vload4(grp + 2u*l + 1u, y);
)"
R"(
)"
R"(                    const float4 ys = y0 + y1;
)"
R"(                    const float  as = ys.s0 + ys.s1 + ys.s2 + ys.s3;
)"
R"(
)"
R"(                    const float a0 = dot(y0, iq1_m_vals(g0)) + dot(y1, iq1_m_vals(g0 >> 4));
)"
R"(                    const float a1 = dot(y0, iq1_m_vals(g1)) + dot(y1, iq1_m_vals(g1 >> 4));
)"
R"(                    acc0 += s0 * (a0 + t0 * as);
)"
R"(                    acc1 += s1 * (a1 + t1 * as);
)"
R"(                }
)"
R"(            }
)"
R"(            sumf  += d0 * acc0;
)"
R"(            sumf1 += d1 * acc1;
)"
R"(        }
)"
R"(    }
)"
R"(
)"
R"(#if IQ1_M_MV_NSG > 1
)"
R"(    __local float2 part[IQ1_M_MV_NSG][64];
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
R"(    for (uint s = 1; s < IQ1_M_MV_NSG; ++s) {
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
R"(#undef IQ1_M_GRID
)"
R"(}
)"
