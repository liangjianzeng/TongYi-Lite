R"(#pragma OPENCL EXTENSION cl_khr_fp16 : enable
)"
R"(
)"
R"(#ifdef cl_intel_subgroups
)"
R"(#pragma OPENCL EXTENSION cl_intel_subgroups : enable
)"
R"(#elif defined(cl_khr_subgroups)
)"
R"(#pragma OPENCL EXTENSION cl_khr_subgroups : enable
)"
R"(#endif
)"
R"(// [dllm-lab K4#1 2026-10-31] the bare #else pragma above used to fail-closed on Adreno
)"
R"(// ("unsupported OpenCL extension 'cl_khr_subgroups'", BC-src-code:6) -- latent because this
)"
R"(// dead kernel is never built in production (lazy per-program compilation). Neither kernel in
)"
R"(// this file uses subgroup intrinsics (plain barrier() only), so enabling the extension is
)"
R"(// optional and now guarded by actual support.
)"
R"(
)"
R"(#ifdef cl_intel_required_subgroup_size
)"
R"(#pragma OPENCL EXTENSION cl_intel_required_subgroup_size : enable
)"
R"(#define INTEL_GPU 1
)"
R"(#define REQD_SUBGROUP_SIZE_16 __attribute__((intel_reqd_sub_group_size(16)))
)"
R"(#define REQD_SUBGROUP_SIZE_32 __attribute__((intel_reqd_sub_group_size(32)))
)"
R"(#elif defined(cl_qcom_reqd_sub_group_size)
)"
R"(#pragma OPENCL EXTENSION cl_qcom_reqd_sub_group_size : enable
)"
R"(#define ADRENO_GPU 1
)"
R"(#define REQD_SUBGROUP_SIZE_64  __attribute__((qcom_reqd_sub_group_size("half")))
)"
R"(#define REQD_SUBGROUP_SIZE_128 __attribute__((qcom_reqd_sub_group_size("full")))
)"
R"(#endif
)"
R"(
)"
R"(#define SWAP(x, y, T) { T tmp = (x); (x) = (y); (y) = tmp; }
)"
R"(
)"
R"(enum ggml_sort_order {
)"
R"(    GGML_SORT_ORDER_ASC,
)"
R"(    GGML_SORT_ORDER_DESC,
)"
R"(};
)"
R"(
)"
R"(kernel void kernel_argsort_f32_i32(
)"
R"(    global float * src0,
)"
R"(    ulong          offset0,
)"
R"(    global int   * dst,
)"
R"(    ulong          offsetd,
)"
R"(    const int      ne00,
)"
R"(    const int      ne00_pad,
)"
R"(    const int      order,
)"
R"(    local int    * dst_row
)"
R"() {
)"
R"(    // bitonic sort
)"
R"(    int col = get_local_id(0);
)"
R"(    int row = get_group_id(1);
)"
R"(
)"
R"(    if (col >= ne00_pad) {
)"
R"(        return;
)"
R"(    }
)"
R"(
)"
R"(    src0 = (global char  *)((global char *)src0 + offset0);
)"
R"(    dst  = (global float *)((global char *)dst  + offsetd);
)"
R"(
)"
R"(    global float * x_row = src0 + row * ne00;
)"
R"(
)"
R"(    // initialize indices
)"
R"(    dst_row[col] = col;
)"
R"(
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(    for (int k = 2; k <= ne00_pad; k *= 2) {
)"
R"(        for (int j = k / 2; j > 0; j /= 2) {
)"
R"(            int ixj = col ^ j;
)"
R"(            if (ixj > col) {
)"
R"(                if ((col & k) == 0) {
)"
R"(                    if (dst_row[col] >= ne00 ||
)"
R"(                        (dst_row[ixj] < ne00 && (order == GGML_SORT_ORDER_ASC ?
)"
R"(                            x_row[dst_row[col]] > x_row[dst_row[ixj]] :
)"
R"(                            x_row[dst_row[col]] < x_row[dst_row[ixj]]))
)"
R"(                    ) {
)"
R"(                        SWAP(dst_row[col], dst_row[ixj], int);
)"
R"(                    }
)"
R"(                } else {
)"
R"(                    if (dst_row[ixj] >= ne00 ||
)"
R"(                        (dst_row[col] < ne00 && (order == GGML_SORT_ORDER_ASC ?
)"
R"(                            x_row[dst_row[col]] < x_row[dst_row[ixj]] :
)"
R"(                            x_row[dst_row[col]] > x_row[dst_row[ixj]]))
)"
R"(                    ) {
)"
R"(                        SWAP(dst_row[col], dst_row[ixj], int);
)"
R"(                    }
)"
R"(                }
)"
R"(            }
)"
R"(            barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(        }
)"
R"(    }
)"
R"(
)"
R"(    // copy the result to dst without the padding
)"
R"(    if (col < ne00) {
)"
R"(        dst[row * ne00 + col] = dst_row[col];
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(// ---------------------------------------------------------------------------
)"
R"(// [dllm-lab K4#1 2026-10-31] tie-deterministic argsort: on equal values the
)"
R"(// LOWER element index wins ("同分小 ID 优先"), matching clover_sort_rows
)"
R"(// (src/models/clover-moe.cpp:119-121, PR #31306 @4838ffb0c) which the graph
)"
R"(// currently runs as a CPU-only island (clover_sort_rows / build_clover_top_k,
)"
R"(// >=2 islands per MoE layer -> L3b measured tg graph splits=82).
)"
R"(//
)"
R"(// kernel_argsort_f32_i32 above is left byte-identical (existing consumers'
)"
R"(// bit-exactness untouched). This kernel is additive and dead until a
)"
R"(// dispatcher gate (env-default-OFF, supports_op 通报 per FIREWALL 第1条) points
)"
R"(// ARGSORT DESC at it.
)"
R"(//
)"
R"(// Bitonic is permutation-sensitive, but with the index tie-break the
)"
R"(// comparator becomes a TOTAL order over distinct elements (ids are unique),
)"
R"(// so the network's output is deterministic and id-stable regardless of lane
)"
R"(// assignment. Padding entries (id >= ne00) are pushed to the tail and never
)"
R"(// participate in tie compares.
)"
R"(// ---------------------------------------------------------------------------
)"
R"(
)"
R"(static inline bool tie_idx_precedes(
)"
R"(        const int ea, const int eb, const int ne00,
)"
R"(        const int order, global const float * x_row) {
)"
R"(    if (ea >= ne00 || eb >= ne00) {
)"
R"(        return eb >= ne00 ? ea < ne00 : false;    // absent always last
)"
R"(    }
)"
R"(    const float va = x_row[ea];
)"
R"(    const float vb = x_row[eb];
)"
R"(    if (va != vb) {
)"
R"(        return order == GGML_SORT_ORDER_ASC ? va < vb : va > vb;
)"
R"(    }
)"
R"(    return ea < eb;                                // tie: lowest element id first
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_argsort_f32_i32_tie_idx(
)"
R"(    global float * src0,
)"
R"(    ulong          offset0,
)"
R"(    global int   * dst,
)"
R"(    ulong          offsetd,
)"
R"(    const int      ne00,
)"
R"(    const int      ne00_pad,
)"
R"(    const int      order,
)"
R"(    local int    * dst_row
)"
R"() {
)"
R"(    // bitonic sort with total-order comparator (DESC + tie->lower id for clover)
)"
R"(    int col = get_local_id(0);
)"
R"(    int row = get_group_id(1);
)"
R"(
)"
R"(    if (col >= ne00_pad) {
)"
R"(        return;
)"
R"(    }
)"
R"(
)"
R"(    src0 = (global char  *)((global char *)src0 + offset0);
)"
R"(    dst  = (global float *)((global char *)dst  + offsetd);
)"
R"(
)"
R"(    global float * x_row = src0 + row * ne00;
)"
R"(
)"
R"(    dst_row[col] = col;
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(    for (int k = 2; k <= ne00_pad; k *= 2) {
)"
R"(        for (int j = k / 2; j > 0; j /= 2) {
)"
R"(            int ixj = col ^ j;
)"
R"(            if (ixj > col) {
)"
R"(                if ((col & k) == 0) {
)"
R"(                    // ascending segment: swap if the ixj element must precede col's
)"
R"(                    if (tie_idx_precedes(dst_row[ixj], dst_row[col], ne00, order, x_row)) {
)"
R"(                        SWAP(dst_row[col], dst_row[ixj], int);
)"
R"(                    }
)"
R"(                } else {
)"
R"(                    // descending segment: swap if col's element must precede ixj's
)"
R"(                    if (tie_idx_precedes(dst_row[col], dst_row[ixj], ne00, order, x_row)) {
)"
R"(                        SWAP(dst_row[col], dst_row[ixj], int);
)"
R"(                    }
)"
R"(                }
)"
R"(            }
)"
R"(            barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(        }
)"
R"(    }
)"
R"(
)"
R"(    if (col < ne00) {
)"
R"(        dst[row * ne00 + col] = dst_row[col];
)"
R"(    }
)"
R"(}
)"
