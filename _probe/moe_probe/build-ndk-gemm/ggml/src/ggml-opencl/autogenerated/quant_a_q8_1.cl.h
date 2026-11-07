R"(#pragma OPENCL EXTENSION cl_khr_fp16 : enable
)"
R"(
)"
R"(// Quantize a contiguous [N, K] f32 activation buffer (token-major, K contiguous
)"
R"(// per token) into q8_1 blocks of 32: int8 quants + per-block scale d + per-block
)"
R"(// sum s (= d * Sum(qs)). Consumed by kernel_gemm_noshuffle_q4_k_q8_1_dp4a for the
)"
R"(// dp4a (int8) dense q4_K prefill GEMM. One work-item per 32-element block.
)"
R"(__kernel void kernel_quant_a_q8_1(
)"
R"(        __global const float * src,   // [N * K]
)"
R"(        __global       char  * qa,    // [N * K]
)"
R"(        __global       half  * da,    // [N * (K/32)]
)"
R"(        __global       half  * sa,    // [N * (K/32)]
)"
R"(        int total_blocks              // N * (K/32)
)"
R"() {
)"
R"(    const int blk = get_global_id(0);
)"
R"(    if (blk >= total_blocks) {
)"
R"(        return;
)"
R"(    }
)"
R"(
)"
R"(    const int base = blk * 32;
)"
R"(
)"
R"(    float v[32];
)"
R"(    float amax = 0.0f;
)"
R"(    #pragma unroll
)"
R"(    for (int i = 0; i < 32; ++i) {
)"
R"(        v[i] = src[base + i];
)"
R"(        amax = fmax(amax, fabs(v[i]));
)"
R"(    }
)"
R"(
)"
R"(    const float d  = amax / 127.0f;
)"
R"(    const float id = (amax > 0.0f) ? (127.0f / amax) : 0.0f;
)"
R"(
)"
R"(    int sum = 0;
)"
R"(    #pragma unroll
)"
R"(    for (int i = 0; i < 32; ++i) {
)"
R"(        const int q = (int)rint(v[i] * id);
)"
R"(        qa[base + i] = (char)q;
)"
R"(        sum += q;
)"
R"(    }
)"
R"(
)"
R"(    da[blk] = (half)d;
)"
R"(    sa[blk] = (half)(d * (float)sum);
)"
R"(}
)"
