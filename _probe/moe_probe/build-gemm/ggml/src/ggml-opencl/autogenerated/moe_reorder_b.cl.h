R"(#pragma OPENCL EXTENSION cl_khr_fp16 : enable
)"
R"(
)"
R"(#define QK4_0 32
)"
R"(
)"
R"(kernel void kernel_moe_reorder_b(
)"
R"(    global float4 * src,
)"
R"(    global uint * router,
)"
R"(    global float4 * dst,
)"
R"(    global int * total_tiles,
)"
R"(    uint K,
)"
R"(    ushort map_ratio,
)"
R"(    uint tile_size
)"
R"() {
)"
R"(    uint k_4 = get_global_id(0);
)"
R"(    uint post_router_idx = get_global_id(1);
)"
R"(
)"
R"(    if ((k_4 >= (K / 4)) || (post_router_idx >= total_tiles[0] * tile_size)) {
)"
R"(        return;
)"
R"(    }
)"
R"(
)"
R"(    uint router_idx = router[post_router_idx];
)"
R"(
)"
R"(    // Padded slots need not be written at all. The MoE GEMMs accumulate per output
)"
R"(    // column and scatter only the real columns, so whatever sits in a padded slot
)"
R"(    // never reaches dst
)"
R"(    if (router_idx == 0xFFFFFFFF) {
)"
R"(        return;
)"
R"(    }
)"
R"(
)"
R"(    ushort activation_idx = router_idx / map_ratio;
)"
R"(    dst[post_router_idx * K / 4 + k_4] = src[activation_idx * K / 4 + k_4];
)"
R"(}
)"
