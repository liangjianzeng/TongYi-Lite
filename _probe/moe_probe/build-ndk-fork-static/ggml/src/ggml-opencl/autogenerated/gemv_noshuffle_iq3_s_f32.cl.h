R"(#pragma OPENCL EXTENSION cl_khr_fp16 : enable
)"
R"(
)"
R"(#define QK_K 256
)"
R"(
)"
R"(#ifndef IQ3_S_MV_NSG
)"
R"(#define IQ3_S_MV_NSG 4
)"
R"(#endif
)"
R"(
)"
R"(inline float4 iq3_s_vals(uint gv, uint sg, uint base) {
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
R"(kernel void kernel_gemv_noshuffle_iq3_s_f32(
)"
R"(        __read_only image1d_buffer_t grid_img,
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
R"(#define IQ3_S_GRID(i) (read_imageui(grid_img, (int)(i)).x)
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
R"(    float sumf  = 0.f;
)"
R"(    float sumf1 = 0.f;
)"
R"(
)"
R"(    if (j < mh) {
)"
R"(        global const ushort * qsu = (global const ushort *)src0_qs;
)"
R"(        global const ushort * qhu = (global const ushort *)src0_qh;
)"
R"(        global const ushort * sgu = (global const ushort *)src0_sg;
)"
R"(        global const ushort * scu = (global const ushort *)src0_sc;
)"
R"(
)"
R"(        for (uint ib = sgi; ib < nsb; ib += IQ3_S_MV_NSG) {
)"
R"(            const half2 dh = vload2(j + ib * mh, src0_d);
)"
R"(            const float d0 = (float)dh.s0;
)"
R"(            const float d1 = (float)dh.s1;
)"
R"(
)"
R"(            const uint scbase = j + ib * 4u * mh;
)"
R"(            ushort sc4[4];
)"
R"(            sc4[0] = scu[scbase + 0u * mh];
)"
R"(            sc4[1] = scu[scbase + 1u * mh];
)"
R"(            sc4[2] = scu[scbase + 2u * mh];
)"
R"(            sc4[3] = scu[scbase + 3u * mh];
)"
R"(
)"
R"(            float acc0 = 0.f, acc1 = 0.f;
)"
R"(            for (uint sb = 0; sb < 8u; ++sb) {
)"
R"(                const uint scv  = (uint)sc4[sb >> 1];
)"
R"(                const uint nib0 = (sb & 1u) ? ((scv >>  4) & 0xFu) : ( scv        & 0xFu);
)"
R"(                const uint nib1 = (sb & 1u) ? ((scv >> 12) & 0xFu) : ((scv >>  8) & 0xFu);
)"
R"(
)"
R"(                const uint qhv = (uint)qhu[j + (ib * 8u + sb) * mh];
)"
R"(                const uint qh0 = qhv & 0xFFu;
)"
R"(                const uint qh1 = qhv >> 8;
)"
R"(
)"
R"(                const uint grp = ib * 64u + sb * 8u;
)"
R"(                const uint qsb = j + grp * mh;
)"
R"(                const uint sgb = j + (ib * 32u + sb * 4u) * mh;
)"
R"(
)"
R"(                float a0 = 0.f, a1 = 0.f;
)"
R"(                for (uint u = 0; u < 8u; ++u) {
)"
R"(                    const uint qsv = (uint)qsu[qsb + u * mh];
)"
R"(                    const uint sgv = (uint)sgu[sgb + (u >> 1) * mh];
)"
R"(                    const uint g0  = ( qsv       & 0xFFu) | (((qh0 >> u) & 1u) << 8);
)"
R"(                    const uint g1  = ((qsv >> 8) & 0xFFu) | (((qh1 >> u) & 1u) << 8);
)"
R"(                    const uint base = (u & 1u) * 4u;
)"
R"(                    const float4 yv = vload4(grp + u, y);
)"
R"(                    const uint gw0 = IQ3_S_GRID(g0);
)"
R"(                    const uint gw1 = IQ3_S_GRID(g1);
)"
R"(                    a0 += dot(yv, iq3_s_vals(gw0,  sgv       & 0xFFu, base));
)"
R"(                    a1 += dot(yv, iq3_s_vals(gw1, (sgv >> 8) & 0xFFu, base));
)"
R"(                }
)"
R"(                acc0 += (float)(1u + 2u * nib0) * a0;
)"
R"(                acc1 += (float)(1u + 2u * nib1) * a1;
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
R"(#if IQ3_S_MV_NSG > 1
)"
R"(    __local float2 part[IQ3_S_MV_NSG][64];
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
R"(    for (uint s = 1; s < IQ3_S_MV_NSG; ++s) {
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
R"(}
)"
R"(
)"
R"(kernel void kernel_iq3_s_grid_export(global uint * out) {
)"
R"(    out[get_global_id(0)] = iq3_s_grid[get_global_id(0)];
)"
R"(}
)"
