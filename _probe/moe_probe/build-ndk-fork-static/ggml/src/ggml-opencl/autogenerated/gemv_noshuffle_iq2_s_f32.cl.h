R"(#pragma OPENCL EXTENSION cl_khr_fp16 : enable
)"
R"(
)"
R"(#define QK_K 256
)"
R"(
)"
R"(#ifndef IQ2_S_MV_NSG
)"
R"(#define IQ2_S_MV_NSG 8
)"
R"(#endif
)"
R"(
)"
R"(inline float4 iq2_s_vals(uint gv, uint sg, uint base) {
)"
R"(
)"
R"(    const uint  s   = sg >> base;
)"
R"(    const uint4 sgn = (uint4)(s << 31, s << 30, s << 29, s << 28) & 0x80000000u;
)"
R"(    return as_float4(as_uint4(convert_float4(as_uchar4(gv))) ^ sgn);
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_iq2_s_grid_export(global uint * out) {
)"
R"(    out[get_global_id(0)] = iq2_s_grid[get_global_id(0)];
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_gemv_noshuffle_iq2_s_f32(
)"
R"(        read_only image1d_buffer_t grid_img,
)"
R"(        global const uchar * src0_qs,
)"
R"(        global const uchar * src0_sg,
)"
R"(        global const uchar * src0_qh,
)"
R"(        global const uchar * src0_sc,
)"
R"(        global const half  * src0_d,
)"
R"(        global const float * src1,
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
R"(#define IQ2_S_GRID(i) read_imageui(grid_img, (int)(i)).x
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
R"(        global const ushort * sgu = (global const ushort *)src0_sg;
)"
R"(        global const ushort * qhu = (global const ushort *)src0_qh;
)"
R"(        global const ushort * scu = (global const ushort *)src0_sc;
)"
R"(
)"
R"(        for (uint ib = sgi; ib < nsb; ib += IQ2_S_MV_NSG) {
)"
R"(            const half2 dh = vload2(j + ib * mh, src0_d);
)"
R"(
)"
R"(            float acc0 = 0.f, acc1 = 0.f;
)"
R"(            for (uint sb = 0; sb < 8u; ++sb) {
)"
R"(                const uint sub = ib * 8u + sb;
)"
R"(                const uint qhv = (uint)qhu[j + sub * mh];
)"
R"(                const uint scv = (uint)scu[j + sub * mh];
)"
R"(                const uint gb  = j + (sub * 4u) * mh;
)"
R"(
)"
R"(                for (uint h = 0; h < 2u; ++h) {
)"
R"(                    const uint n0 = (h == 0u) ? ( scv        & 0xFu) : (( scv        >> 4) & 0xFu);
)"
R"(                    const uint n1 = (h == 0u) ? ((scv >> 8)  & 0xFu) : (((scv >> 8)  >> 4) & 0xFu);
)"
R"(
)"
R"(                    float a0 = 0.f, a1 = 0.f;
)"
R"(                    for (uint t = 0; t < 2u; ++t) {
)"
R"(                        const uint l   = 2u*h + t;
)"
R"(                        const uint qsv = (uint)qsu[gb + l * mh];
)"
R"(                        const uint sgv = (uint)sgu[gb + l * mh];
)"
R"(                        const uint gi0 = ( qsv       & 0xFFu) | ((((qhv      ) >> (2u*l)) & 3u) << 8);
)"
R"(                        const uint gi1 = ((qsv >> 8) & 0xFFu) | ((((qhv >> 8) >> (2u*l)) & 3u) << 8);
)"
R"(                        const uint s0  =  sgv       & 0xFFu;
)"
R"(                        const uint s1  = (sgv >> 8) & 0xFFu;
)"
R"(
)"
R"(                        const uint grp = (ib * 64u + sb * 8u) + l * 2u;
)"
R"(                        const float4 y0 = vload4(grp + 0u, y);
)"
R"(                        const float4 y1 = vload4(grp + 1u, y);
)"
R"(                        a0 += dot(y0, iq2_s_vals(IQ2_S_GRID(2u*gi0 + 0u), s0, 0u));
)"
R"(                        a0 += dot(y1, iq2_s_vals(IQ2_S_GRID(2u*gi0 + 1u), s0, 4u));
)"
R"(                        a1 += dot(y0, iq2_s_vals(IQ2_S_GRID(2u*gi1 + 0u), s1, 0u));
)"
R"(                        a1 += dot(y1, iq2_s_vals(IQ2_S_GRID(2u*gi1 + 1u), s1, 4u));
)"
R"(                    }
)"
R"(                    acc0 += (0.5f + (float)n0) * a0;
)"
R"(                    acc1 += (0.5f + (float)n1) * a1;
)"
R"(                }
)"
R"(            }
)"
R"(            sumf  += (float)dh.s0 * 0.25f * acc0;
)"
R"(            sumf1 += (float)dh.s1 * 0.25f * acc1;
)"
R"(        }
)"
R"(    }
)"
R"(
)"
R"(#if IQ2_S_MV_NSG > 1
)"
R"(    __local float2 part[IQ2_S_MV_NSG][64];
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
R"(    for (uint s = 1; s < IQ2_S_MV_NSG; ++s) {
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
R"(#undef IQ2_S_GRID
)"
R"(}
)"
