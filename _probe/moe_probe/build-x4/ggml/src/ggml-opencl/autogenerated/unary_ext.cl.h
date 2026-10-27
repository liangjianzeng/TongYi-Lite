R"(#pragma OPENCL EXTENSION cl_khr_fp16 : enable
)"
R"(
)"
R"(//------------------------------------------------------------------------------
)"
R"(// Extended elementwise unary ops, same variant shape as abs.cl:
)"
R"(//   f32, f32_4 (vec4), f16, f16_4 (vec4), f32_nc, f16_nc (stride-addressed).
)"
R"(//
)"
R"(//   sgn, step, elu, hardswish, hardsigmoid, floor, ceil, round, trunc.
)"
R"(//
)"
R"(// Semantics match the ggml CPU reference (ggml.c). Values are computed in float
)"
R"(// (the f16 variants read/write half and convert), so the conditional ops match
)"
R"(// the CPU bit-for-bit within tolerance. SEXPR is the scalar form, VEXPR the
)"
R"(// float4 form (vector ternaries need select()).
)"
R"(//------------------------------------------------------------------------------
)"
R"(
)"
R"(#define UNARY_EXT(NAME, SEXPR, VEXPR)                                           \
)"
R"(kernel void kernel_##NAME##_f32(                                               \
)"
R"(        global const float * src0, ulong offset0,                             \
)"
R"(        global       float * dst,  ulong offsetd) {                           \
)"
R"(    src0 = (global float*)((global char*)src0 + offset0);                     \
)"
R"(    dst  = (global float*)((global char*)dst  + offsetd);                     \
)"
R"(    float x = src0[get_global_id(0)];                                         \
)"
R"(    dst[get_global_id(0)] = (SEXPR);                                          \
)"
R"(}                                                                             \
)"
R"(kernel void kernel_##NAME##_f32_4(                                            \
)"
R"(        global const float4 * src0, ulong offset0,                           \
)"
R"(        global       float4 * dst,  ulong offsetd) {                         \
)"
R"(    src0 = (global float4*)((global char*)src0 + offset0);                   \
)"
R"(    dst  = (global float4*)((global char*)dst  + offsetd);                   \
)"
R"(    float4 x = src0[get_global_id(0)];                                       \
)"
R"(    dst[get_global_id(0)] = (VEXPR);                                         \
)"
R"(}                                                                             \
)"
R"(kernel void kernel_##NAME##_f16(                                             \
)"
R"(        global const half * src0, ulong offset0,                            \
)"
R"(        global       half * dst,  ulong offsetd) {                          \
)"
R"(    src0 = (global half*)((global char*)src0 + offset0);                    \
)"
R"(    dst  = (global half*)((global char*)dst  + offsetd);                    \
)"
R"(    float x = src0[get_global_id(0)];                                       \
)"
R"(    dst[get_global_id(0)] = (SEXPR);                                        \
)"
R"(}                                                                            \
)"
R"(kernel void kernel_##NAME##_f16_4(                                          \
)"
R"(        global const half4 * src0, ulong offset0,                          \
)"
R"(        global       half4 * dst,  ulong offsetd) {                        \
)"
R"(    src0 = (global half4*)((global char*)src0 + offset0);                  \
)"
R"(    dst  = (global half4*)((global char*)dst  + offsetd);                  \
)"
R"(    float4 x = convert_float4(src0[get_global_id(0)]);                     \
)"
R"(    dst[get_global_id(0)] = convert_half4(VEXPR);                          \
)"
R"(}                                                                           \
)"
R"(kernel void kernel_##NAME##_f32_nc(                                         \
)"
R"(        global const char * src0, ulong offset0,                          \
)"
R"(        global       char * dst,  ulong offsetd,                          \
)"
R"(        int ne00, ulong nb00, ulong nb01, ulong nb02, ulong nb03,         \
)"
R"(        ulong nb0, ulong nb1, ulong nb2, ulong nb3) {                     \
)"
R"(    src0 = src0 + offset0; dst = dst + offsetd;                            \
)"
R"(    const int i3 = get_group_id(2);                                       \
)"
R"(    const int i2 = get_group_id(1);                                       \
)"
R"(    const int i1 = get_group_id(0);                                       \
)"
R"(    for (int i0 = get_local_id(0); i0 < ne00; i0 += get_local_size(0)) {  \
)"
R"(        float x = *(global const float *)(src0 + i3*nb03 + i2*nb02 + i1*nb01 + i0*nb00); \
)"
R"(        *(global float *)(dst + i3*nb3 + i2*nb2 + i1*nb1 + i0*nb0) = (SEXPR);            \
)"
R"(    }                                                                     \
)"
R"(}                                                                         \
)"
R"(kernel void kernel_##NAME##_f16_nc(                                       \
)"
R"(        global const char * src0, ulong offset0,                        \
)"
R"(        global       char * dst,  ulong offsetd,                        \
)"
R"(        int ne00, ulong nb00, ulong nb01, ulong nb02, ulong nb03,       \
)"
R"(        ulong nb0, ulong nb1, ulong nb2, ulong nb3) {                   \
)"
R"(    src0 = src0 + offset0; dst = dst + offsetd;                          \
)"
R"(    const int i3 = get_group_id(2);                                     \
)"
R"(    const int i2 = get_group_id(1);                                     \
)"
R"(    const int i1 = get_group_id(0);                                     \
)"
R"(    for (int i0 = get_local_id(0); i0 < ne00; i0 += get_local_size(0)) {\
)"
R"(        float x = *(global const half *)(src0 + i3*nb03 + i2*nb02 + i1*nb01 + i0*nb00); \
)"
R"(        *(global half *)(dst + i3*nb3 + i2*nb2 + i1*nb1 + i0*nb0) = (SEXPR);            \
)"
R"(    }                                                                   \
)"
R"(}
)"
R"(
)"
R"(UNARY_EXT(sgn,          sign(x),                                           sign(x))
)"
R"(UNARY_EXT(step,         x > 0.0f ? 1.0f : 0.0f,                            select((float4)0.0f, (float4)1.0f, x > 0.0f))
)"
R"(UNARY_EXT(elu,          x > 0.0f ? x : expm1(x),                           select(expm1(x), x, x > 0.0f))
)"
R"(UNARY_EXT(hardswish,    x * fmin(1.0f, fmax(0.0f, (x + 3.0f) / 6.0f)),     x * fmin((float4)1.0f, fmax((float4)0.0f, (x + 3.0f) / 6.0f)))
)"
R"(UNARY_EXT(hardsigmoid,  fmin(1.0f, fmax(0.0f, (x + 3.0f) / 6.0f)),         fmin((float4)1.0f, fmax((float4)0.0f, (x + 3.0f) / 6.0f)))
)"
R"(UNARY_EXT(floor,        floor(x),                                          floor(x))
)"
R"(UNARY_EXT(ceil,         ceil(x),                                           ceil(x))
)"
R"(UNARY_EXT(round,        round(x),                                          round(x))
)"
R"(UNARY_EXT(trunc,        trunc(x),                                          trunc(x))
)"
