R"(#pragma OPENCL EXTENSION cl_khr_fp16 : enable
)"
R"(
)"
R"(#define QK_K 256
)"
R"(
)"
R"(#ifndef Q3_K_MV_NSG
)"
R"(#define Q3_K_MV_NSG 8
)"
R"(#endif
)"
R"(
)"
R"(#ifndef Q3_K_MV_R
)"
R"(#define Q3_K_MV_R 2
)"
R"(#endif
)"
R"(
)"
R"(inline int q3_k_scale(uint sc0, uint sc1, uint sc2, uint is) {
)"
R"(    const uint w  = is >> 2;
)"
R"(    const uint sh = 8u * (is & 3u);
)"
R"(    const uint tb = (sc2 >> sh) & 0xFFu;
)"
R"(    uint v;
)"
R"(    if      (w == 0u) { v = ( (sc0 >> sh)       & 0xFu) | (((tb >> 0) & 3u) << 4); }
)"
R"(    else if (w == 1u) { v = ( (sc1 >> sh)       & 0xFu) | (((tb >> 2) & 3u) << 4); }
)"
R"(    else if (w == 2u) { v = (((sc0 >> sh) >> 4) & 0xFu) | (((tb >> 4) & 3u) << 4); }
)"
R"(    else              { v = (((sc1 >> sh) >> 4) & 0xFu) | (((tb >> 6) & 3u) << 4); }
)"
R"(    return (int)v - 32;
)"
R"(}
)"
R"(
)"
R"(inline float4 q3_k_vals(uint pk, uint hb) {
)"
R"(    float4 v;
)"
R"(    v.s0 = (float)((int)((pk      ) & 3u) - 4 + 4*(int)((hb     ) & 1u));
)"
R"(    v.s1 = (float)((int)((pk >> 2) & 3u) - 4 + 4*(int)((hb >> 1) & 1u));
)"
R"(    v.s2 = (float)((int)((pk >> 4) & 3u) - 4 + 4*(int)((hb >> 2) & 1u));
)"
R"(    v.s3 = (float)((int)((pk >> 6) & 3u) - 4 + 4*(int)((hb >> 3) & 1u));
)"
R"(    return v;
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_gemv_noshuffle_q3_k_f32(
)"
R"(        global const uchar * src0_qs,
)"
R"(        global const uchar * src0_hm,
)"
R"(        global const uint  * src0_sc,
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
R"(        int ne00,      // K
)"
R"(        int ne01,      // M
)"
R"(        int ne10,      // activation row stride
)"
R"(        int ne0        // dst row stride
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
R"(#if Q3_K_MV_R == 4
)"
R"(    const uint mq  = m >> 2;
)"
R"(    const uint j   = get_group_id(0) * 64u + lid;
)"
R"(    const uint row = j << 2;
)"
R"(
)"
R"(    float sumf = 0.f, sumf1 = 0.f, sumf2 = 0.f, sumf3 = 0.f;
)"
R"(
)"
R"(    if (j < mq) {
)"
R"(        global const uint * qsw = (global const uint *)src0_qs;
)"
R"(        global const uint * hmw = (global const uint *)src0_hm;
)"
R"(
)"
R"(        for (uint ib = sgi; ib < nsb; ib += Q3_K_MV_NSG) {
)"
R"(            const half4 dh = vload4(j + ib * mq, src0_d);
)"
R"(            const uint4 s0 = vload4(j + (3u * ib + 0u) * mq, src0_sc);
)"
R"(            const uint4 s1 = vload4(j + (3u * ib + 1u) * mq, src0_sc);
)"
R"(            const uint4 s2 = vload4(j + (3u * ib + 2u) * mq, src0_sc);
)"
R"(
)"
R"(            float acc0 = 0.f, acc1 = 0.f, acc2 = 0.f, acc3 = 0.f;
)"
R"(            for (uint sb = 0; sb < 8u; ++sb) {
)"
R"(                const uint grp = ib * 64u + sb * 8u;
)"
R"(                const uint qsb = j + grp * mq;
)"
R"(                const uint hmb = j + (grp >> 1) * mq;
)"
R"(
)"
R"(                for (uint h = 0; h < 2u; ++h) {         // two 16-weight halves
)"
R"(                    const int l0 = q3_k_scale(s0.s0, s1.s0, s2.s0, 2u*sb + h);
)"
R"(                    const int l1 = q3_k_scale(s0.s1, s1.s1, s2.s1, 2u*sb + h);
)"
R"(                    const int l2 = q3_k_scale(s0.s2, s1.s2, s2.s2, 2u*sb + h);
)"
R"(                    const int l3 = q3_k_scale(s0.s3, s1.s3, s2.s3, 2u*sb + h);
)"
R"(
)"
R"(                    float a0 = 0.f, a1 = 0.f, a2 = 0.f, a3 = 0.f;
)"
R"(                    for (uint u = 0; u < 4u; ++u) {
)"
R"(                        const uint gg  = 4u*h + u;
)"
R"(                        const uint qsv = qsw[qsb + gg * mq];        // four rows, one load
)"
R"(                        const uint hmv = hmw[hmb + (gg >> 1) * mq];
)"
R"(                        const uint hsh = 4u * (gg & 1u);
)"
R"(                        const float4 yv = vload4(grp + gg, y);      // shared by all four
)"
R"(                        a0 += dot(yv, q3_k_vals((qsv      ) & 0xFFu, ((hmv      ) >> hsh) & 0xFu));
)"
R"(                        a1 += dot(yv, q3_k_vals((qsv >>  8) & 0xFFu, ((hmv >>  8) >> hsh) & 0xFu));
)"
R"(                        a2 += dot(yv, q3_k_vals((qsv >> 16) & 0xFFu, ((hmv >> 16) >> hsh) & 0xFu));
)"
R"(                        a3 += dot(yv, q3_k_vals((qsv >> 24) & 0xFFu, ((hmv >> 24) >> hsh) & 0xFu));
)"
R"(                    }
)"
R"(                    acc0 += (float)l0 * a0;
)"
R"(                    acc1 += (float)l1 * a1;
)"
R"(                    acc2 += (float)l2 * a2;
)"
R"(                    acc3 += (float)l3 * a3;
)"
R"(                }
)"
R"(            }
)"
R"(            sumf  += (float)dh.s0 * acc0;
)"
R"(            sumf1 += (float)dh.s1 * acc1;
)"
R"(            sumf2 += (float)dh.s2 * acc2;
)"
R"(            sumf3 += (float)dh.s3 * acc3;
)"
R"(        }
)"
R"(    }
)"
R"(#elif Q3_K_MV_R == 2
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
R"(        global const ushort * hmu = (global const ushort *)src0_hm;
)"
R"(
)"
R"(        for (uint ib = sgi; ib < nsb; ib += Q3_K_MV_NSG) {
)"
R"(            const half2 dh = vload2(j + ib * mh, src0_d);
)"
R"(            const uint2 s0 = vload2(j + (3u * ib + 0u) * mh, src0_sc);
)"
R"(            const uint2 s1 = vload2(j + (3u * ib + 1u) * mh, src0_sc);
)"
R"(            const uint2 s2 = vload2(j + (3u * ib + 2u) * mh, src0_sc);
)"
R"(
)"
R"(            float acc0 = 0.f, acc1 = 0.f;
)"
R"(            for (uint sb = 0; sb < 8u; ++sb) {
)"
R"(                const uint grp = ib * 64u + sb * 8u;
)"
R"(                const uint qsb = j + grp * mh;
)"
R"(                const uint hmb = j + (grp >> 1) * mh;
)"
R"(
)"
R"(                for (uint h = 0; h < 2u; ++h) {         // two 16-weight halves
)"
R"(                    const int l0 = q3_k_scale(s0.s0, s1.s0, s2.s0, 2u*sb + h);
)"
R"(                    const int l1 = q3_k_scale(s0.s1, s1.s1, s2.s1, 2u*sb + h);
)"
R"(
)"
R"(                    float a0 = 0.f, a1 = 0.f;
)"
R"(                    for (uint u = 0; u < 4u; ++u) {
)"
R"(                        const uint gg  = 4u*h + u;
)"
R"(                        const uint qsv = (uint)qsu[qsb + gg * mh];
)"
R"(                        const uint hmv = (uint)hmu[hmb + (gg >> 1) * mh];
)"
R"(                        const uint hsh = 4u * (gg & 1u);
)"
R"(                        const float4 yv = vload4(grp + gg, y);
)"
R"(                        a0 += dot(yv, q3_k_vals( qsv       & 0xFFu, ( hmv        >> hsh) & 0xFu));
)"
R"(                        a1 += dot(yv, q3_k_vals((qsv >> 8) & 0xFFu, ((hmv >> 8)  >> hsh) & 0xFu));
)"
R"(                    }
)"
R"(                    acc0 += (float)l0 * a0;
)"
R"(                    acc1 += (float)l1 * a1;
)"
R"(                }
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
R"(#else
)"
R"(    const uint row = get_group_id(0) * 64u + lid;
)"
R"(
)"
R"(    float sumf = 0.f;
)"
R"(
)"
R"(    if (row < m) {
)"
R"(        for (uint ib = sgi; ib < nsb; ib += Q3_K_MV_NSG) {
)"
R"(            const float d  = (float)src0_d[row + ib * m];
)"
R"(            const uint  s0 = src0_sc[row + (3u * ib + 0u) * m];
)"
R"(            const uint  s1 = src0_sc[row + (3u * ib + 1u) * m];
)"
R"(            const uint  s2 = src0_sc[row + (3u * ib + 2u) * m];
)"
R"(
)"
R"(            float acc = 0.f;
)"
R"(            for (uint sb = 0; sb < 8u; ++sb) {
)"
R"(                const uint grp = ib * 64u + sb * 8u;
)"
R"(                const uint qsb = row + grp * m;
)"
R"(                const uint hmb = row + (grp >> 1) * m;
)"
R"(
)"
R"(                for (uint h = 0; h < 2u; ++h) {
)"
R"(                    const int l = q3_k_scale(s0, s1, s2, 2u*sb + h);
)"
R"(                    float a = 0.f;
)"
R"(                    for (uint u = 0; u < 4u; ++u) {
)"
R"(                        const uint gg  = 4u*h + u;
)"
R"(                        const uint qsv = (uint)src0_qs[qsb + gg * m];
)"
R"(                        const uint hmv = (uint)src0_hm[hmb + (gg >> 1) * m];
)"
R"(                        const float4 yv = vload4(grp + gg, y);
)"
R"(                        a += dot(yv, q3_k_vals(qsv, (hmv >> (4u * (gg & 1u))) & 0xFu));
)"
R"(                    }
)"
R"(                    acc += (float)l * a;
)"
R"(                }
)"
R"(            }
)"
R"(            sumf += d * acc;
)"
R"(        }
)"
R"(    }
)"
R"(#endif
)"
R"(
)"
R"(#if Q3_K_MV_NSG > 1
)"
R"(#if Q3_K_MV_R == 4
)"
R"(    __local float4 part[Q3_K_MV_NSG][64];
)"
R"(    part[sgi][lid] = (float4)(sumf, sumf1, sumf2, sumf3);
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(    if (sgi != 0) {
)"
R"(        return;
)"
R"(    }
)"
R"(    for (uint s = 1; s < Q3_K_MV_NSG; ++s) {
)"
R"(        const float4 p = part[s][lid];
)"
R"(        sumf  += p.s0;
)"
R"(        sumf1 += p.s1;
)"
R"(        sumf2 += p.s2;
)"
R"(        sumf3 += p.s3;
)"
R"(    }
)"
R"(#elif Q3_K_MV_R == 2
)"
R"(    __local float2 part[Q3_K_MV_NSG][64];
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
R"(    for (uint s = 1; s < Q3_K_MV_NSG; ++s) {
)"
R"(        const float2 p = part[s][lid];
)"
R"(        sumf  += p.s0;
)"
R"(        sumf1 += p.s1;
)"
R"(    }
)"
R"(#else
)"
R"(    __local float part[Q3_K_MV_NSG][64];
)"
R"(    part[sgi][lid] = sumf;
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(    if (sgi != 0) {
)"
R"(        return;
)"
R"(    }
)"
R"(    for (uint s = 1; s < Q3_K_MV_NSG; ++s) {
)"
R"(        sumf += part[s][lid];
)"
R"(    }
)"
R"(#endif
)"
R"(#endif
)"
R"(
)"
R"(#if Q3_K_MV_R == 4
)"
R"(    if (j < mq) {
)"
R"(        vstore4((float4)(sumf, sumf1, sumf2, sumf3), 0, dst + (ulong)col * (uint)ne0 + row);
)"
R"(    }
)"
R"(#elif Q3_K_MV_R == 2
)"
R"(    if (j < mh) {
)"
R"(        vstore2((float2)(sumf, sumf1), 0, dst + (ulong)col * (uint)ne0 + row);
)"
R"(    }
)"
R"(#else
)"
R"(    if (row < m) {
)"
R"(        dst[(ulong)col * (uint)ne0 + row] = sumf;
)"
R"(    }
)"
R"(#endif
)"
R"(}
)"
