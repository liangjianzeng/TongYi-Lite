R"(#pragma OPENCL EXTENSION cl_khr_fp16 : enable
)"
R"(
)"
R"(#if Q2_0_MV_WIDE
)"
R"(#define Q2_0_MV_ROWS 8
)"
R"(#define Q2_0_MV_LOAD_D vload8
)"
R"(#define Q2_0_MV_STORE vstore8
)"
R"(#define Q2_0_MV_FLOAT convert_float8
)"
R"(typedef float8 q2_0_mv_acc_t;
)"
R"(typedef uchar8 q2_0_mv_quant_t;
)"
R"(#else
)"
R"(#define Q2_0_MV_ROWS 4
)"
R"(#define Q2_0_MV_LOAD_D vload4
)"
R"(#define Q2_0_MV_STORE vstore4
)"
R"(#define Q2_0_MV_FLOAT convert_float4
)"
R"(typedef float4 q2_0_mv_acc_t;
)"
R"(typedef uchar4 q2_0_mv_quant_t;
)"
R"(#endif
)"
R"(
)"
R"(kernel void kernel_gemv_noshuffle_q2_0_f32(
)"
R"(        global const uchar * src0_qs,
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
R"(    const uint mr = (uint)ne01/Q2_0_MV_ROWS;
)"
R"(    const uint lid = get_local_id(0);
)"
R"(    const uint sgi = get_local_id(1);
)"
R"(    const uint lanes = get_local_size(0);
)"
R"(    const uint nsg = get_local_size(1);
)"
R"(    const uint col = get_group_id(1);
)"
R"(    const uint j = get_group_id(0)*lanes + lid;
)"
R"(    global const float * y = src1 + (ulong)col * (uint)ne10;
)"
R"(
)"
R"(    q2_0_mv_acc_t sum = 0.0f;
)"
R"(    if (j < mr) {
)"
R"(        for (uint ib = sgi; ib < (uint)ne00/64; ib += nsg) {
)"
R"(            const q2_0_mv_acc_t d = Q2_0_MV_FLOAT(Q2_0_MV_LOAD_D(j + ib*mr, src0_d));
)"
R"(            q2_0_mv_acc_t acc = 0.0f;
)"
R"(            for (uint u = 0; u < 16; ++u) {
)"
R"(                const uint group = ib*16 + u;
)"
R"(#if Q2_0_MV_WIDE
)"
R"(                const uchar8 q = as_uchar8(((global const uint2 *)src0_qs)[j + group*mr]);
)"
R"(#else
)"
R"(                const uchar4 q = as_uchar4(((global const uint *)src0_qs)[j + group*mr]);
)"
R"(#endif
)"
R"(                const float4 yv = vload4(group, y);
)"
R"(                acc += (Q2_0_MV_FLOAT( q                          & (q2_0_mv_quant_t)(3)) - 1.0f)*yv.s0;
)"
R"(                acc += (Q2_0_MV_FLOAT((q >> (q2_0_mv_quant_t)(2)) & (q2_0_mv_quant_t)(3)) - 1.0f)*yv.s1;
)"
R"(                acc += (Q2_0_MV_FLOAT((q >> (q2_0_mv_quant_t)(4)) & (q2_0_mv_quant_t)(3)) - 1.0f)*yv.s2;
)"
R"(                acc += (Q2_0_MV_FLOAT( q >> (q2_0_mv_quant_t)(6))                          - 1.0f)*yv.s3;
)"
R"(            }
)"
R"(            sum += d*acc;
)"
R"(        }
)"
R"(    }
)"
R"(
)"
R"(    local q2_0_mv_acc_t part[512];
)"
R"(    part[sgi*lanes + lid] = sum;
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(    if (sgi != 0) {
)"
R"(        return;
)"
R"(    }
)"
R"(    for (uint s = 1; s < nsg; ++s) {
)"
R"(        sum += part[s*lanes + lid];
)"
R"(    }
)"
R"(    if (j < mr) {
)"
R"(        Q2_0_MV_STORE(sum, 0, dst + (ulong)col*(uint)ne0 + j*Q2_0_MV_ROWS);
)"
R"(    }
)"
R"(}
)"
