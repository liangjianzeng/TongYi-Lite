#pragma OPENCL EXTENSION cl_khr_fp16 : enable

#ifdef cl_intel_subgroups
#pragma OPENCL EXTENSION cl_intel_subgroups : enable
#elif defined(cl_khr_subgroups)
#pragma OPENCL EXTENSION cl_khr_subgroups : enable
#endif
// [dllm-lab K4#1 2026-10-31] the bare #else pragma above used to fail-closed on Adreno
// ("unsupported OpenCL extension 'cl_khr_subgroups'", BC-src-code:6) -- latent because this
// dead kernel is never built in production (lazy per-program compilation). Neither kernel in
// this file uses subgroup intrinsics (plain barrier() only), so enabling the extension is
// optional and now guarded by actual support.

#ifdef cl_intel_required_subgroup_size
#pragma OPENCL EXTENSION cl_intel_required_subgroup_size : enable
#define INTEL_GPU 1
#define REQD_SUBGROUP_SIZE_16 __attribute__((intel_reqd_sub_group_size(16)))
#define REQD_SUBGROUP_SIZE_32 __attribute__((intel_reqd_sub_group_size(32)))
#elif defined(cl_qcom_reqd_sub_group_size)
#pragma OPENCL EXTENSION cl_qcom_reqd_sub_group_size : enable
#define ADRENO_GPU 1
#define REQD_SUBGROUP_SIZE_64  __attribute__((qcom_reqd_sub_group_size("half")))
#define REQD_SUBGROUP_SIZE_128 __attribute__((qcom_reqd_sub_group_size("full")))
#endif

#define SWAP(x, y, T) { T tmp = (x); (x) = (y); (y) = tmp; }

enum ggml_sort_order {
    GGML_SORT_ORDER_ASC,
    GGML_SORT_ORDER_DESC,
};

kernel void kernel_argsort_f32_i32(
    global float * src0,
    ulong          offset0,
    global int   * dst,
    ulong          offsetd,
    const int      ne00,
    const int      ne00_pad,
    const int      order,
    local int    * dst_row
) {
    // bitonic sort
    int col = get_local_id(0);
    int row = get_group_id(1);

    if (col >= ne00_pad) {
        return;
    }

    src0 = (global char  *)((global char *)src0 + offset0);
    dst  = (global float *)((global char *)dst  + offsetd);

    global float * x_row = src0 + row * ne00;

    // initialize indices
    dst_row[col] = col;

    barrier(CLK_LOCAL_MEM_FENCE);

    for (int k = 2; k <= ne00_pad; k *= 2) {
        for (int j = k / 2; j > 0; j /= 2) {
            int ixj = col ^ j;
            if (ixj > col) {
                if ((col & k) == 0) {
                    if (dst_row[col] >= ne00 ||
                        (dst_row[ixj] < ne00 && (order == GGML_SORT_ORDER_ASC ?
                            x_row[dst_row[col]] > x_row[dst_row[ixj]] :
                            x_row[dst_row[col]] < x_row[dst_row[ixj]]))
                    ) {
                        SWAP(dst_row[col], dst_row[ixj], int);
                    }
                } else {
                    if (dst_row[ixj] >= ne00 ||
                        (dst_row[col] < ne00 && (order == GGML_SORT_ORDER_ASC ?
                            x_row[dst_row[col]] < x_row[dst_row[ixj]] :
                            x_row[dst_row[col]] > x_row[dst_row[ixj]]))
                    ) {
                        SWAP(dst_row[col], dst_row[ixj], int);
                    }
                }
            }
            barrier(CLK_LOCAL_MEM_FENCE);
        }
    }

    // copy the result to dst without the padding
    if (col < ne00) {
        dst[row * ne00 + col] = dst_row[col];
    }
}

// ---------------------------------------------------------------------------
// [dllm-lab K4#1 2026-10-31] tie-deterministic argsort: on equal values the
// LOWER element index wins ("同分小 ID 优先"), matching clover_sort_rows
// (src/models/clover-moe.cpp:119-121, PR #31306 @4838ffb0c) which the graph
// currently runs as a CPU-only island (clover_sort_rows / build_clover_top_k,
// >=2 islands per MoE layer -> L3b measured tg graph splits=82).
//
// kernel_argsort_f32_i32 above is left byte-identical (existing consumers'
// bit-exactness untouched). This kernel is additive and dead until a
// dispatcher gate (env-default-OFF, supports_op 通报 per FIREWALL 第1条) points
// ARGSORT DESC at it.
//
// Bitonic is permutation-sensitive, but with the index tie-break the
// comparator becomes a TOTAL order over distinct elements (ids are unique),
// so the network's output is deterministic and id-stable regardless of lane
// assignment. Padding entries (id >= ne00) are pushed to the tail and never
// participate in tie compares.
// ---------------------------------------------------------------------------

static inline bool tie_idx_precedes(
        const int ea, const int eb, const int ne00,
        const int order, global const float * x_row) {
    if (ea >= ne00 || eb >= ne00) {
        return eb >= ne00 ? ea < ne00 : false;    // absent always last
    }
    const float va = x_row[ea];
    const float vb = x_row[eb];
    if (va != vb) {
        return order == GGML_SORT_ORDER_ASC ? va < vb : va > vb;
    }
    return ea < eb;                                // tie: lowest element id first
}

kernel void kernel_argsort_f32_i32_tie_idx(
    global float * src0,
    ulong          offset0,
    global int   * dst,
    ulong          offsetd,
    const int      ne00,
    const int      ne00_pad,
    const int      order,
    local int    * dst_row
) {
    // bitonic sort with total-order comparator (DESC + tie->lower id for clover)
    int col = get_local_id(0);
    int row = get_group_id(1);

    if (col >= ne00_pad) {
        return;
    }

    src0 = (global char  *)((global char *)src0 + offset0);
    dst  = (global float *)((global char *)dst  + offsetd);

    global float * x_row = src0 + row * ne00;

    dst_row[col] = col;
    barrier(CLK_LOCAL_MEM_FENCE);

    for (int k = 2; k <= ne00_pad; k *= 2) {
        for (int j = k / 2; j > 0; j /= 2) {
            int ixj = col ^ j;
            if (ixj > col) {
                if ((col & k) == 0) {
                    // ascending segment: swap if the ixj element must precede col's
                    if (tie_idx_precedes(dst_row[ixj], dst_row[col], ne00, order, x_row)) {
                        SWAP(dst_row[col], dst_row[ixj], int);
                    }
                } else {
                    // descending segment: swap if col's element must precede ixj's
                    if (tie_idx_precedes(dst_row[col], dst_row[ixj], ne00, order, x_row)) {
                        SWAP(dst_row[col], dst_row[ixj], int);
                    }
                }
            }
            barrier(CLK_LOCAL_MEM_FENCE);
        }
    }

    if (col < ne00) {
        dst[row * ne00 + col] = dst_row[col];
    }
}
