R"(#pragma OPENCL EXTENSION cl_khr_fp16 : enable
)"
R"(
)"
R"(__kernel void kernel_moe_histogram(
)"
R"(    __global const int * input,
)"
R"(    __global int * hist,
)"
R"(    uint N,
)"
R"(    uint topK,
)"
R"(    uint n_experts,
)"
R"(    ulong offset
)"
R"() {
)"
R"(    input = (__global const int *)((__global const char *)input + offset);
)"
R"(
)"
R"(    uint n = get_global_id(0);
)"
R"(    uint k = get_global_id(1);
)"
R"(
)"
R"(    if (n >= N || k >= topK) {
)"
R"(        return;
)"
R"(    }
)"
R"(
)"
R"(    int expert_id = input[n * n_experts + k];
)"
R"(    atomic_inc(&hist[expert_id]);
)"
R"(}
)"
R"(
)"
R"(__kernel void kernel_moe_scan(
)"
R"(    __global int * hist,
)"
R"(    __global int * tile_offset,
)"
R"(    __global int * total_tiles,
)"
R"(    __global int * slot_counter,
)"
R"(    int tile_size,
)"
R"(    uint n_experts
)"
R"() {
)"
R"(    int offset = 0;
)"
R"(    for (int v = 0; v < n_experts; v++) {
)"
R"(        int count = hist[v];
)"
R"(        int tiles = (count + tile_size - 1) / tile_size;
)"
R"(        tile_offset[v] = offset;
)"
R"(        offset += tiles;
)"
R"(        hist[v] = 0;
)"
R"(        slot_counter[v] = 0;
)"
R"(    }
)"
R"(
)"
R"(    *total_tiles = offset;
)"
R"(}
)"
R"(
)"
R"(__kernel void kernel_moe_scatter(
)"
R"(    __global const int * input,
)"
R"(    __global int * post_router,
)"
R"(    __global ushort * emap,
)"
R"(    __global const int * tile_offset,
)"
R"(    __global int * slot_counter,
)"
R"(    int N,
)"
R"(    int topK,
)"
R"(    uint n_experts,
)"
R"(    ulong offset
)"
R"() {
)"
R"(    input = (__global const int *)((__global const char *)input + offset);
)"
R"(
)"
R"(    uint n = get_global_id(0);
)"
R"(    uint k = get_global_id(1);
)"
R"(
)"
R"(    if (n >= N || k >= topK) {
)"
R"(        return;
)"
R"(    }
)"
R"(
)"
R"(    int val = input[n * n_experts + k];
)"
R"(
)"
R"(    int local_slot = atomic_inc(&slot_counter[val]);
)"
R"(
)"
R"(    int tile_idx  = tile_offset[val] + (local_slot / 32);
)"
R"(    int lane      = local_slot % 32;
)"
R"(    int out_pos   = tile_idx * 32 + lane;
)"
R"(
)"
R"(    post_router[out_pos] = n * topK + k;
)"
R"(    emap[tile_idx] = val;
)"
R"(}
)"
R"(
)"
R"(// Deterministic replacement for kernel_moe_scatter.
)"
R"(//
)"
R"(// kernel_moe_scatter takes each token's slot from atomic_inc(slot_counter[expert]),
)"
R"(// so the token -> slot packing inside an expert depends on which work-item wins the
)"
R"(// atomic and changes from run to run. The ragged prefill GEMM path is sensitive to
)"
R"(// that packing (the non-ragged path is not, since its padded slots alias slot 0 and
)"
R"(// are overwritten last), which makes MoE prompt processing non-reproducible: the same
)"
R"(// binary on the same prompt returns one of several outputs.
)"
R"(//
)"
R"(// Here the slot is the token's rank in flat (n, k) order among the tokens routed to
)"
R"(// the same expert - a fixed function of the routing input. One workgroup per expert
)"
R"(// walks the flat routing list in blocks of 64 and ranks its own tokens with a
)"
R"(// workgroup scan, carrying a running count between blocks. Cost is one pass over the
)"
R"(// routing list per expert; the list is a few KiB and stays in cache.
)"
R"(__kernel void kernel_moe_scatter_stable(
)"
R"(    __global const int * input,
)"
R"(    __global int * post_router,
)"
R"(    __global ushort * emap,
)"
R"(    __global const int * tile_offset,
)"
R"(    int N,
)"
R"(    int topK,
)"
R"(    uint n_experts,
)"
R"(    ulong offset
)"
R"() {
)"
R"(    input = (__global const int *)((__global const char *)input + offset);
)"
R"(
)"
R"(    const int e   = get_group_id(1);
)"
R"(    const int lid = get_local_id(0);
)"
R"(    const int M   = N * topK;
)"
R"(
)"
R"(    __local int scan[64];
)"
R"(    __local int running;
)"
R"(
)"
R"(    if (lid == 0) {
)"
R"(        running = 0;
)"
R"(    }
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(    for (int base = 0; base < M; base += 64) {
)"
R"(        const int j = base + lid;
)"
R"(
)"
R"(        int pred = 0;
)"
R"(        if (j < M) {
)"
R"(            const int n = j / topK;
)"
R"(            const int k = j - n * topK;
)"
R"(            pred = (input[n * (int)n_experts + k] == e) ? 1 : 0;
)"
R"(        }
)"
R"(
)"
R"(        scan[lid] = pred;
)"
R"(        barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(        // Hillis-Steele inclusive scan over the 64 lanes
)"
R"(        for (int off = 1; off < 64; off <<= 1) {
)"
R"(            int add = (lid >= off) ? scan[lid - off] : 0;
)"
R"(            barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(            scan[lid] += add;
)"
R"(            barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(        }
)"
R"(
)"
R"(        if (pred) {
)"
R"(            const int local_slot = running + (scan[lid] - 1);   // exclusive rank
)"
R"(            const int tile_idx   = tile_offset[e] + (local_slot >> 5);
)"
R"(            const int lane       = local_slot & 31;
)"
R"(
)"
R"(            post_router[tile_idx * 32 + lane] = j;
)"
R"(            emap[tile_idx] = (ushort)e;
)"
R"(        }
)"
R"(
)"
R"(        barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(        if (lid == 63) {
)"
R"(            running += scan[63];
)"
R"(        }
)"
R"(        barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(__kernel void kernel_moe_fill(
)"
R"(    __global int * post_router,
)"
R"(    __global int * total_tiles,
)"
R"(    int tile_size
)"
R"() {
)"
R"(    int tile_id = get_global_id(0);
)"
R"(    int vec_id_in_tile = get_global_id(1);
)"
R"(
)"
R"(    if (tile_id < total_tiles[0]) {
)"
R"(        post_router[tile_id * tile_size + vec_id_in_tile] = 0xFFFFFFFF;
)"
R"(    }
)"
R"(}
)"
