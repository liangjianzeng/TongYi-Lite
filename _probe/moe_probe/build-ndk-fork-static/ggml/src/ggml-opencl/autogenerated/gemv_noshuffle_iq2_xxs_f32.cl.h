R"(#pragma OPENCL EXTENSION cl_khr_fp16 : enable
)"
R"(
)"
R"(#define QK_K 256
)"
R"(
)"
R"(#ifndef IQ2_XXS_MV_NSG
)"
R"(#define IQ2_XXS_MV_NSG 4
)"
R"(#endif
)"
R"(
)"
R"(inline float4 iq2_xxs_vals(uint gv, uint sgv, uint base) {
)"
R"(    const uint  s   = sgv >> base;
)"
R"(    const uint4 sgn = (uint4)(s << 31, s << 30, s << 29, s << 28) & 0x80000000u;
)"
R"(    return as_float4(as_uint4(convert_float4(as_uchar4(gv))) ^ sgn);
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_gemv_noshuffle_iq2_xxs_f32(
)"
R"(        __read_only image1d_buffer_t grid_img,
)"
R"(        global const uchar * src0_qs,
)"
R"(        global const uint  * src0_sas,
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
R"(#define IQ2_XXS_GRID(i) (read_imageui(grid_img, (int)(i)).x)
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
R"(
)"
R"(        for (uint ib = sgi; ib < nsb; ib += IQ2_XXS_MV_NSG) {
)"
R"(            const half2 dh = vload2(j + ib * mh, src0_d);
)"
R"(            const float d0 = (float)dh.s0;
)"
R"(            const float d1 = (float)dh.s1;
)"
R"(
)"
R"(            float acc0 = 0.f, acc1 = 0.f;
)"
R"(            for (uint sb = 0; sb < 8u; ++sb) {
)"
R"(                const uint  sub = ib * 8u + sb;
)"
R"(                const uint2 aux = vload2(j + sub * mh, src0_sas);
)"
R"(
)"
R"(                const uint grp = sub * 4u;
)"
R"(                const uint qsb = j + grp * mh;
)"
R"(
)"
R"(                float a0 = 0.f, a1 = 0.f;
)"
R"(                for (uint u = 0; u < 4u; ++u) {
)"
R"(                    const uint qsv = (uint)qsu[qsb + u * mh];
)"
R"(                    const uint sg0 = iq2_xxs_signs((aux.s0 >> (7u * u)) & 127u);
)"
R"(                    const uint sg1 = iq2_xxs_signs((aux.s1 >> (7u * u)) & 127u);
)"
R"(
)"
R"(                    const uint g0 = ( qsv       & 0xFFu) << 1;
)"
R"(                    const uint g1 = ((qsv >> 8) & 0xFFu) << 1;
)"
R"(
)"
R"(                    const float4 yl = vload4(sub * 8u + u * 2u + 0u, y);
)"
R"(                    const float4 yh = vload4(sub * 8u + u * 2u + 1u, y);
)"
R"(
)"
R"(                    a0 += dot(yl, iq2_xxs_vals(IQ2_XXS_GRID(g0    ), sg0, 0u))
)"
R"(                        + dot(yh, iq2_xxs_vals(IQ2_XXS_GRID(g0 + 1), sg0, 4u));
)"
R"(                    a1 += dot(yl, iq2_xxs_vals(IQ2_XXS_GRID(g1    ), sg1, 0u))
)"
R"(                        + dot(yh, iq2_xxs_vals(IQ2_XXS_GRID(g1 + 1), sg1, 4u));
)"
R"(                }
)"
R"(                acc0 += (0.5f + (float)(aux.s0 >> 28)) * a0;
)"
R"(                acc1 += (0.5f + (float)(aux.s1 >> 28)) * a1;
)"
R"(            }
)"
R"(            sumf  += d0 * 0.25f * acc0;
)"
R"(            sumf1 += d1 * 0.25f * acc1;
)"
R"(        }
)"
R"(    }
)"
R"(
)"
R"(#if IQ2_XXS_MV_NSG > 1
)"
R"(    __local float2 part[IQ2_XXS_MV_NSG][64];
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
R"(    for (uint s = 1; s < IQ2_XXS_MV_NSG; ++s) {
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
R"(#undef IQ2_XXS_GRID
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_iq2_xxs_grid_export(global uint * out) {
)"
R"(    const uint i = get_global_id(0);
)"
R"(    if (i < 512u) {
)"
R"(        out[i] = iq2_xxs_grid[i];
)"
R"(    }
)"
R"(}
)"
