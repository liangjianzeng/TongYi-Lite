R"(#pragma OPENCL EXTENSION cl_khr_fp16 : enable
)"
R"(
)"
R"(#define QK_K 256
)"
R"(
)"
R"(#ifndef Q2_K_MV_NSG
)"
R"(#define Q2_K_MV_NSG 8
)"
R"(#endif
)"
R"(
)"
R"(#ifndef Q2_K_MV_R
)"
R"(#define Q2_K_MV_R 4
)"
R"(#endif
)"
R"(
)"
R"(inline float4 q2_k_vals(uint pk) {
)"
R"(    return (float4)((float)( pk       & 3u), (float)((pk >> 2) & 3u),
)"
R"(                    (float)((pk >> 4) & 3u), (float)((pk >> 6) & 3u));
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_gemv_noshuffle_q2_k_f32(
)"
R"(        global const uchar * src0_qs,
)"
R"(        global const uchar * src0_sc,
)"
R"(        global const half  * src0_dm,
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
R"(        int ne10,      // activation row stride, == K
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
R"(    const uint mr  = m / Q2_K_MV_R;                  // row groups
)"
R"(    const uint j   = get_group_id(0) * 64u + lid;   // row group this lane owns
)"
R"(    const uint row = j * Q2_K_MV_R;
)"
R"(
)"
R"(#if Q2_K_MV_R == 4
)"
R"(    float sumf0 = 0.f;
)"
R"(    float sumf1 = 0.f;
)"
R"(    float sumf2 = 0.f;
)"
R"(    float sumf3 = 0.f;
)"
R"(
)"
R"(    if (j < mr) {
)"
R"(        global const uint * qsu = (global const uint *)src0_qs;
)"
R"(        global const uint * scu = (global const uint *)src0_sc;
)"
R"(
)"
R"(        for (uint ib = sgi; ib < nsb; ib += Q2_K_MV_NSG) {
)"
R"(            const half4 dma = vload4(2u*(j + ib*mr) + 0u, src0_dm);  // d0, dmin0, d1, dmin1
)"
R"(            const half4 dmb = vload4(2u*(j + ib*mr) + 1u, src0_dm);  // d2, dmin2, d3, dmin3
)"
R"(
)"
R"(            float ad0 = 0.f, am0 = 0.f, ad1 = 0.f, am1 = 0.f;
)"
R"(            float ad2 = 0.f, am2 = 0.f, ad3 = 0.f, am3 = 0.f;
)"
R"(
)"
R"(            for (uint sb = 0; sb < 8u; ++sb) {
)"
R"(                const uint grp = ib * 64u + sb * 8u;
)"
R"(                const uint qsb = j + grp * mr;
)"
R"(
)"
R"(                for (uint h = 0; h < 2u; ++h) {
)"
R"(                    const uint scv = scu[j + (2u * (ib * 8u + sb) + h) * mr];
)"
R"(
)"
R"(                    float a0 = 0.f, a1 = 0.f, a2 = 0.f, a3 = 0.f;
)"
R"(                    float4 as = (float4)(0.f);
)"
R"(                    for (uint u = 0; u < 4u; ++u) {
)"
R"(                        const uint gg  = 4u*h + u;
)"
R"(                        const uint qsv = qsu[qsb + gg * mr];   // four rows, one load
)"
R"(                        const float4 yv = vload4(grp + gg, y);
)"
R"(                        as += yv;
)"
R"(                        a0 += dot(yv, q2_k_vals( qsv        & 0xFFu));
)"
R"(                        a1 += dot(yv, q2_k_vals((qsv >>  8) & 0xFFu));
)"
R"(                        a2 += dot(yv, q2_k_vals((qsv >> 16) & 0xFFu));
)"
R"(                        a3 += dot(yv, q2_k_vals((qsv >> 24) & 0xFFu));
)"
R"(                    }
)"
R"(                    const float asum = as.s0 + as.s1 + as.s2 + as.s3;
)"
R"(
)"
R"(                    const uint s0 =  scv        & 0xFFu;
)"
R"(                    const uint s1 = (scv >>  8) & 0xFFu;
)"
R"(                    const uint s2 = (scv >> 16) & 0xFFu;
)"
R"(                    const uint s3 = (scv >> 24) & 0xFFu;
)"
R"(                    ad0 += (float)(s0 & 0xFu) * a0;   am0 += (float)(s0 >> 4) * asum;
)"
R"(                    ad1 += (float)(s1 & 0xFu) * a1;   am1 += (float)(s1 >> 4) * asum;
)"
R"(                    ad2 += (float)(s2 & 0xFu) * a2;   am2 += (float)(s2 >> 4) * asum;
)"
R"(                    ad3 += (float)(s3 & 0xFu) * a3;   am3 += (float)(s3 >> 4) * asum;
)"
R"(                }
)"
R"(            }
)"
R"(            sumf0 += (float)dma.s0 * ad0 - (float)dma.s1 * am0;
)"
R"(            sumf1 += (float)dma.s2 * ad1 - (float)dma.s3 * am1;
)"
R"(            sumf2 += (float)dmb.s0 * ad2 - (float)dmb.s1 * am2;
)"
R"(            sumf3 += (float)dmb.s2 * ad3 - (float)dmb.s3 * am3;
)"
R"(        }
)"
R"(    }
)"
R"(
)"
R"(#if Q2_K_MV_NSG > 1
)"
R"(    __local float4 part[Q2_K_MV_NSG][64];
)"
R"(    part[sgi][lid] = (float4)(sumf0, sumf1, sumf2, sumf3);
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(    if (sgi != 0) {
)"
R"(        return;
)"
R"(    }
)"
R"(    for (uint s = 1; s < Q2_K_MV_NSG; ++s) {
)"
R"(        const float4 p = part[s][lid];
)"
R"(        sumf0 += p.s0;
)"
R"(        sumf1 += p.s1;
)"
R"(        sumf2 += p.s2;
)"
R"(        sumf3 += p.s3;
)"
R"(    }
)"
R"(#endif
)"
R"(
)"
R"(    if (j < mr) {
)"
R"(        global float * o = dst + (ulong)col * (uint)ne0 + row;
)"
R"(        o[0] = sumf0; o[1] = sumf1; o[2] = sumf2; o[3] = sumf3;
)"
R"(    }
)"
R"(
)"
R"(#elif Q2_K_MV_R == 2
)"
R"(    float sumf0 = 0.f;
)"
R"(    float sumf1 = 0.f;
)"
R"(
)"
R"(    if (j < mr) {
)"
R"(        global const ushort * qsu = (global const ushort *)src0_qs;
)"
R"(        global const ushort * scu = (global const ushort *)src0_sc;
)"
R"(
)"
R"(        for (uint ib = sgi; ib < nsb; ib += Q2_K_MV_NSG) {
)"
R"(            const half4 dm = vload4(j + ib * mr, src0_dm);  // d0, dmin0, d1, dmin1
)"
R"(
)"
R"(            float ad0 = 0.f, am0 = 0.f, ad1 = 0.f, am1 = 0.f;
)"
R"(            for (uint sb = 0; sb < 8u; ++sb) {
)"
R"(                const uint grp = ib * 64u + sb * 8u;
)"
R"(                const uint qsb = j + grp * mr;
)"
R"(
)"
R"(                for (uint h = 0; h < 2u; ++h) {
)"
R"(                    const uint scv = (uint)scu[j + (2u * (ib * 8u + sb) + h) * mr];
)"
R"(                    const uint s0  = scv & 0xFFu;
)"
R"(                    const uint s1  = scv >> 8;
)"
R"(
)"
R"(                    float a0 = 0.f, a1 = 0.f;
)"
R"(                    float4 as = (float4)(0.f);
)"
R"(                    for (uint u = 0; u < 4u; ++u) {
)"
R"(                        const uint gg  = 4u*h + u;
)"
R"(                        const uint qsv = (uint)qsu[qsb + gg * mr];
)"
R"(                        const float4 yv = vload4(grp + gg, y);
)"
R"(                        as += yv;
)"
R"(                        a0 += dot(yv, q2_k_vals( qsv       & 0xFFu));
)"
R"(                        a1 += dot(yv, q2_k_vals((qsv >> 8) & 0xFFu));
)"
R"(                    }
)"
R"(                    const float asum = as.s0 + as.s1 + as.s2 + as.s3;
)"
R"(                    ad0 += (float)(s0 & 0xFu) * a0;   am0 += (float)(s0 >> 4) * asum;
)"
R"(                    ad1 += (float)(s1 & 0xFu) * a1;   am1 += (float)(s1 >> 4) * asum;
)"
R"(                }
)"
R"(            }
)"
R"(            sumf0 += (float)dm.s0 * ad0 - (float)dm.s1 * am0;
)"
R"(            sumf1 += (float)dm.s2 * ad1 - (float)dm.s3 * am1;
)"
R"(        }
)"
R"(    }
)"
R"(
)"
R"(#if Q2_K_MV_NSG > 1
)"
R"(    __local float2 part[Q2_K_MV_NSG][64];
)"
R"(    part[sgi][lid] = (float2)(sumf0, sumf1);
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(    if (sgi != 0) {
)"
R"(        return;
)"
R"(    }
)"
R"(    for (uint s = 1; s < Q2_K_MV_NSG; ++s) {
)"
R"(        const float2 p = part[s][lid];
)"
R"(        sumf0 += p.s0;
)"
R"(        sumf1 += p.s1;
)"
R"(    }
)"
R"(#endif
)"
R"(
)"
R"(    if (j < mr) {
)"
R"(        vstore2((float2)(sumf0, sumf1), 0, dst + (ulong)col * (uint)ne0 + row);
)"
R"(    }
)"
R"(
)"
R"(#else
)"
R"(    float sumf0 = 0.f;
)"
R"(
)"
R"(    if (j < mr) {
)"
R"(        for (uint ib = sgi; ib < nsb; ib += Q2_K_MV_NSG) {
)"
R"(            const half2 dm = vload2(row + ib * m, src0_dm);
)"
R"(
)"
R"(            float ad = 0.f, am = 0.f;
)"
R"(            for (uint sb = 0; sb < 8u; ++sb) {
)"
R"(                const uint grp = ib * 64u + sb * 8u;
)"
R"(                const uint qsb = row + grp * m;
)"
R"(
)"
R"(                for (uint h = 0; h < 2u; ++h) {
)"
R"(                    const uint sc = (uint)src0_sc[row + (2u * (ib * 8u + sb) + h) * m];
)"
R"(
)"
R"(                    float a = 0.f;
)"
R"(                    float4 as = (float4)(0.f);
)"
R"(                    for (uint u = 0; u < 4u; ++u) {
)"
R"(                        const uint gg = 4u*h + u;
)"
R"(                        const float4 yv = vload4(grp + gg, y);
)"
R"(                        as += yv;
)"
R"(                        const uint pkv = (uint)src0_qs[qsb + gg * m];
)"
R"(                        a += dot(yv, q2_k_vals(pkv));
)"
R"(                    }
)"
R"(                    const float asum = as.s0 + as.s1 + as.s2 + as.s3;
)"
R"(                    ad += (float)(sc & 0xFu) * a;   am += (float)(sc >> 4) * asum;
)"
R"(                }
)"
R"(            }
)"
R"(            sumf0 += (float)dm.s0 * ad - (float)dm.s1 * am;
)"
R"(        }
)"
R"(    }
)"
R"(
)"
R"(#if Q2_K_MV_NSG > 1
)"
R"(    __local float part[Q2_K_MV_NSG][64];
)"
R"(    part[sgi][lid] = sumf0;
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(    if (sgi != 0) {
)"
R"(        return;
)"
R"(    }
)"
R"(    for (uint s = 1; s < Q2_K_MV_NSG; ++s) {
)"
R"(        sumf0 += part[s][lid];
)"
R"(    }
)"
R"(#endif
)"
R"(
)"
R"(    if (j < mr) {
)"
R"(        dst[(ulong)col * (uint)ne0 + row] = sumf0;
)"
R"(    }
)"
R"(#endif
)"
R"(}
)"
