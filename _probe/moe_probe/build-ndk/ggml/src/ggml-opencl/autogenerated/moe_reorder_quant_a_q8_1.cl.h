R"(#pragma OPENCL EXTENSION cl_khr_fp16 : enable
)"
R"(
)"
R"(// Fused MoE activation reorder + q8_1 quantization for the dp4a prefill GEMM.
)"
R"(// Combines kernel_moe_reorder_b (gather src1 rows per the post-router map) with
)"
R"(// the q8_1 quant pre-pass, so the f32 reordered-activation tile buffer is never
)"
R"(// materialised (saves a full write + read of [tok_slots * ne00] floats).
)"
R"(//
)"
R"(// One work-item per (token_slot, 32-block). Padding lanes (router 0xFFFFFFFF)
)"
R"(// emit d=0,s=0,qs=0 so they contribute nothing to the GEMM, exactly as the
)"
R"(// reorder zero-fill did. Output layout matches kernel_moe_quant_a_q8_1:
)"
R"(//   qa[token_slot*K + blk*32 + i], da/sa[token_slot*(K/32) + blk].
)"
R"(__kernel void kernel_moe_reorder_quant_a_q8_1(
)"
R"(        __global const float  * src,        // original activations (offset applied)
)"
R"(        __global const uint   * router,     // post-router indices [tok_slots]
)"
R"(        __global       char   * qa,
)"
R"(        __global       half   * da,
)"
R"(        __global       half   * sa,
)"
R"(        __global const int    * total_tiles,
)"
R"(        uint  K,
)"
R"(        ushort map_ratio,
)"
R"(        uint  tile_size,
)"
R"(        uint  n_kblocks                      // K / 32
)"
R"() {
)"
R"(    const uint blk = get_global_id(0);       // 32-block along K
)"
R"(    const uint tok = get_global_id(1);       // token slot (post_router_idx)
)"
R"(
)"
R"(    if (blk >= n_kblocks || tok >= (uint)total_tiles[0] * tile_size) {
)"
R"(        return;
)"
R"(    }
)"
R"(
)"
R"(    const uint out_base = tok * K + blk * 32;
)"
R"(    const uint bidx     = tok * n_kblocks + blk;
)"
R"(
)"
R"(    const uint router_idx = router[tok];
)"
R"(
)"
R"(    float v[32];
)"
R"(    float amax = 0.0f;
)"
R"(    if (router_idx == 0xFFFFFFFF) {
)"
R"(        #pragma unroll
)"
R"(        for (int i = 0; i < 32; ++i) v[i] = 0.0f;
)"
R"(    } else {
)"
R"(        const uint act_idx = router_idx / map_ratio;
)"
R"(        const uint in_base = act_idx * K + blk * 32;
)"
R"(        #pragma unroll
)"
R"(        for (int i = 0; i < 32; ++i) {
)"
R"(            v[i] = src[in_base + i];
)"
R"(            amax = fmax(amax, fabs(v[i]));
)"
R"(        }
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
R"(        qa[out_base + i] = (char)q;
)"
R"(        sum += q;
)"
R"(    }
)"
R"(
)"
R"(    da[bidx] = (half)d;
)"
R"(    sa[bidx] = (half)(d * (float)sum);
)"
R"(}
)"
