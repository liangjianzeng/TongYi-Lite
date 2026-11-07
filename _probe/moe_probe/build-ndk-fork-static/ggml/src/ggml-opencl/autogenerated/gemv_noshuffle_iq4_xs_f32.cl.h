R"(#pragma OPENCL EXTENSION cl_khr_fp16 : enable
)"
R"(
)"
R"(#define QK_K 256
)"
R"(
)"
R"(#ifndef IQ4_XS_MV_NSG
)"
R"(#define IQ4_XS_MV_NSG 8
)"
R"(#endif
)"
R"(
)"
R"(inline float4 iq4_xs_vals(ushort q) {
)"
R"(    return (float4)((char)iq4_xs_code(q & 15), (char)iq4_xs_code((q >> 4) & 15),
)"
R"(                    (char)iq4_xs_code((q >> 8) & 15), (char)iq4_xs_code(q >> 12));
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_gemv_noshuffle_iq4_xs_f32(
)"
R"(        global const ushort * src0_qs,
)"
R"(        global const uint * src0_sl,
)"
R"(        global const ushort * src0_sh,
)"
R"(        global const half * src0_d,
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
R"(    dst = (global float *)((global char *)dst + offsetd);
)"
R"(
)"
R"(    const uint m = (uint)ne01;
)"
R"(    const uint mh = m >> 1;
)"
R"(    const uint lid = get_local_id(0);
)"
R"(    const uint sgi = get_local_id(1);
)"
R"(    const uint col = get_group_id(1);
)"
R"(    const uint j = get_group_id(0)*64u + lid;
)"
R"(    const uint row = j << 1;
)"
R"(    global const float * y = src1 + (ulong)col * (uint)ne10;
)"
R"(
)"
R"(    float sum0 = 0.0f, sum1 = 0.0f;
)"
R"(    if (j < mh) {
)"
R"(        global const uint * qs = (global const uint *)src0_qs;
)"
R"(        global const uint * sh = (global const uint *)src0_sh;
)"
R"(        for (uint ib = sgi; ib < (uint)ne00/QK_K; ib += IQ4_XS_MV_NSG) {
)"
R"(            const uint base = j + ib*mh;
)"
R"(            const uint2 sl = vload2(base, src0_sl);
)"
R"(            const uint shp = sh[base];
)"
R"(            const half2 d = vload2(base, src0_d);
)"
R"(            float acc0 = 0.0f, acc1 = 0.0f;
)"
R"(            for (uint sb = 0; sb < 8; ++sb) {
)"
R"(                const int ls0 = (int)(((sl.s0 >> (4*sb)) & 15u) | (((shp >> (2*sb)) & 3u) << 4)) - 32;
)"
R"(                const int ls1 = (int)(((sl.s1 >> (4*sb)) & 15u) | (((shp >> (16 + 2*sb)) & 3u) << 4)) - 32;
)"
R"(                float a0 = 0.0f, a1 = 0.0f;
)"
R"(                for (uint u = 0; u < 8; ++u) {
)"
R"(                    const uint group = ib*64 + sb*8 + u;
)"
R"(                    const uint q = qs[j + group*mh];
)"
R"(                    const float4 yv = vload4(group, y);
)"
R"(                    a0 += dot(yv, iq4_xs_vals((ushort)q));
)"
R"(                    a1 += dot(yv, iq4_xs_vals((ushort)(q >> 16)));
)"
R"(                }
)"
R"(                acc0 += (float)ls0*a0;
)"
R"(                acc1 += (float)ls1*a1;
)"
R"(            }
)"
R"(            sum0 += (float)d.s0*acc0;
)"
R"(            sum1 += (float)d.s1*acc1;
)"
R"(        }
)"
R"(    }
)"
R"(
)"
R"(#if IQ4_XS_MV_NSG > 1
)"
R"(    local float2 part[IQ4_XS_MV_NSG][64];
)"
R"(    part[sgi][lid] = (float2)(sum0, sum1);
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(    if (sgi != 0) {
)"
R"(        return;
)"
R"(    }
)"
R"(    for (uint s = 1; s < IQ4_XS_MV_NSG; ++s) {
)"
R"(        const float2 v = part[s][lid];
)"
R"(        sum0 += v.s0;
)"
R"(        sum1 += v.s1;
)"
R"(    }
)"
R"(#endif
)"
R"(    if (j < mh) {
)"
R"(        vstore2((float2)(sum0, sum1), 0, dst + (ulong)col*(uint)ne0 + row);
)"
R"(    }
)"
R"(}
)"
