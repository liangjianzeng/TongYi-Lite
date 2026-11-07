R"(#pragma OPENCL EXTENSION cl_khr_fp16 : enable
)"
R"(#pragma OPENCL EXTENSION cl_khr_subgroups : enable
)"
R"(
)"
R"(#define tile_size 32
)"
R"(
)"
R"(kernel void kernel_transpose_activation_q8(
)"
R"(        __global uint * src1_qa,
)"
R"(        __global uint * src1_qa_trans,
)"
R"(        __global half * src1_sa,
)"
R"(        __global float * src1_sa_trans,
)"
R"(        __global const int * total_tiles,
)"
R"(        uint  K
)"
R"() {
)"
R"(    uint row_in_tile = get_global_id(0);
)"
R"(    uint blk_k = get_group_id(1);
)"
R"(    uint col_in_tile = get_local_id(1);
)"
R"(    uint tile_n = get_global_id(2);
)"
R"(
)"
R"(    if (blk_k >= (K / tile_size) || tile_n >= (uint)total_tiles[0]) {
)"
R"(        return;
)"
R"(    }
)"
R"(
)"
R"(    uint src_idx = (tile_n * tile_size + row_in_tile) * K / 4 + blk_k * 8 + col_in_tile;
)"
R"(    uint dst_idx = tile_n * tile_size * K / 4 + (blk_k * 8 + col_in_tile) * tile_size + row_in_tile;
)"
R"(
)"
R"(    src1_qa_trans[dst_idx] = src1_qa[src_idx];
)"
R"(
)"
R"(    if (col_in_tile == 0) {
)"
R"(        src_idx = (tile_n * tile_size + row_in_tile) * K / 32 + blk_k;
)"
R"(        dst_idx = tile_n * tile_size * K / 32 + blk_k * tile_size + row_in_tile;
)"
R"(
)"
R"(        src1_sa_trans[dst_idx] = (float)(src1_sa[src_idx]);
)"
R"(    }
)"
R"(
)"
R"(}
)"
