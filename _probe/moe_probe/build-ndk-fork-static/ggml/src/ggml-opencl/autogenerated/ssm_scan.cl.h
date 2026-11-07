R"(// Mamba2 fused SSM scan kernel. One workgroup per (head, dim, seq); WG size =
)"
R"(// 64 threads. Each thread owns c_factor = d_state/64 state elements in
)"
R"(// private registers; the state stays resident across the n_tokens t-loop
)"
R"(//
)"
R"(// References:
)"
R"(//   ggml/src/ggml-cuda/ssm-scan.cu:117 ssm_scan_f32_group
)"
R"(//   ggml/src/ggml-cpu/ops.cpp:9368 ggml_compute_forward_ssm_scan_f32
)"
R"(
)"
R"(#pragma OPENCL EXTENSION cl_khr_fp16 : enable
)"
R"(
)"
R"(#ifdef cl_khr_subgroups
)"
R"(#pragma OPENCL EXTENSION cl_khr_subgroups : enable
)"
R"(#endif
)"
R"(
)"
R"(#if defined(cl_qcom_reqd_sub_group_size)
)"
R"(#pragma OPENCL EXTENSION cl_qcom_reqd_sub_group_size : enable
)"
R"(#define REQD_SUBGROUP_SIZE_64 __attribute__((qcom_reqd_sub_group_size("half")))
)"
R"(#else
)"
R"(#define REQD_SUBGROUP_SIZE_64
)"
R"(#endif
)"
R"(
)"
R"(inline float softplus_f32(float x) {
)"
R"(    return (x <= 20.0f) ? log(1.0f + exp(x)) : x;
)"
R"(}
)"
R"(
)"
R"(// d_state = 128 (most Mamba-2 models, e.g. mamba2-2.7B, Codestral-Mamba).
)"
R"(// WG = 64 threads, each holds 2 state elements (tid and tid+64).
)"
R"(REQD_SUBGROUP_SIZE_64
)"
R"(kernel void kernel_ssm_scan_f32_mamba2_d128(
)"
R"(    global const char * src0_base, ulong src0_off,
)"
R"(    global const char * src1_base, ulong src1_off,
)"
R"(    global const char * src2_base, ulong src2_off,
)"
R"(    global const char * src3_base, ulong src3_off,
)"
R"(    global const char * src4_base, ulong src4_off,
)"
R"(    global const char * src5_base, ulong src5_off,
)"
R"(    global const char * src6_base, ulong src6_off,
)"
R"(    global       char * dst_base,  ulong dst_off,
)"
R"(    ulong s0_nb2, ulong s0_nb3,
)"
R"(    ulong x_nb2,  ulong x_nb3,
)"
R"(    ulong dt_nb1, ulong dt_nb2,
)"
R"(    ulong A_nb1,
)"
R"(    ulong B_nb2,  ulong B_nb3,
)"
R"(    ulong C_nb2,  ulong C_nb3,
)"
R"(    ulong s_off_bytes,
)"
R"(    int   head_dim, int n_head, int n_group, int n_tokens
)"
R"() {
)"
R"(    const int d_state = 128;
)"
R"(
)"
R"(    const int tid     = (int) get_local_id(0);
)"
R"(    const int wg_x    = (int) get_group_id(0);
)"
R"(    const int seq_id  = (int) get_group_id(1);
)"
R"(
)"
R"(    const int head_id = wg_x / head_dim;
)"
R"(    const int dim_id  = wg_x - head_id * head_dim;
)"
R"(    const int g       = head_id / (n_head / n_group);
)"
R"(
)"
R"(    src0_base += src0_off;
)"
R"(    src1_base += src1_off;
)"
R"(    src2_base += src2_off;
)"
R"(    src3_base += src3_off;
)"
R"(    src4_base += src4_off;
)"
R"(    src5_base += src5_off;
)"
R"(    src6_base += src6_off;
)"
R"(    dst_base  += dst_off;
)"
R"(
)"
R"(    const int seq_slot = ((global const int *) src6_base)[seq_id];
)"
R"(
)"
R"(    const ulong state_base_off = (ulong)seq_slot * s0_nb3 + (ulong)head_id * s0_nb2
)"
R"(                                + (ulong)dim_id * d_state * sizeof(float);
)"
R"(    global const float * s0_warp = (global const float *)(src0_base + state_base_off);
)"
R"(    const ulong state_out_off = (ulong)seq_id * s0_nb3 + (ulong)head_id * s0_nb2
)"
R"(                              + (ulong)dim_id * d_state * sizeof(float);
)"
R"(    global float * s_warp = (global float *)(dst_base + s_off_bytes + state_out_off);
)"
R"(
)"
R"(    global const char * x_seq  = src1_base + (ulong)seq_id * x_nb3;
)"
R"(    global const char * dt_seq = src2_base + (ulong)seq_id * dt_nb2;
)"
R"(    global const char * B_seq  = src4_base + (ulong)seq_id * B_nb3 + (ulong)g * d_state * sizeof(float);
)"
R"(    global const char * C_seq  = src5_base + (ulong)seq_id * C_nb3 + (ulong)g * d_state * sizeof(float);
)"
R"(
)"
R"(    const ulong y_dim_total = (ulong)n_head * head_dim;
)"
R"(    global float * y_seq = (global float *)dst_base
)"
R"(                           + (ulong)seq_id * (ulong)n_tokens * y_dim_total;
)"
R"(
)"
R"(    const float A_val = ((global const float *)src3_base)[(ulong)head_id * A_nb1 / sizeof(float)];
)"
R"(
)"
R"(    // c_factor = 2: each thread owns 2 state elements (tid and tid+64).
)"
R"(    float state0 = s0_warp[tid];
)"
R"(    float state1 = s0_warp[tid + 64];
)"
R"(
)"
R"(    for (int t = 0; t < n_tokens; ++t) {
)"
R"(        const float dt_h        = ((global const float *)(dt_seq + (ulong)t * dt_nb1))[head_id];
)"
R"(        const float dt_softplus = softplus_f32(dt_h);
)"
R"(        const float dA          = exp(dt_softplus * A_val);
)"
R"(        const float x_val       = ((global const float *)(x_seq + (ulong)t * x_nb2))[(ulong)head_id * head_dim + dim_id];
)"
R"(        const float x_dt        = x_val * dt_softplus;
)"
R"(
)"
R"(        const float B0 = ((global const float *)(B_seq + (ulong)t * B_nb2))[tid];
)"
R"(        const float B1 = ((global const float *)(B_seq + (ulong)t * B_nb2))[tid + 64];
)"
R"(        const float C0 = ((global const float *)(C_seq + (ulong)t * C_nb2))[tid];
)"
R"(        const float C1 = ((global const float *)(C_seq + (ulong)t * C_nb2))[tid + 64];
)"
R"(
)"
R"(        state0 = state0 * dA + B0 * x_dt;
)"
R"(        state1 = state1 * dA + B1 * x_dt;
)"
R"(        const float partial = state0 * C0 + state1 * C1;
)"
R"(
)"
R"(        const float sum = sub_group_reduce_add(partial);
)"
R"(        if (tid == 0) {
)"
R"(            y_seq[(ulong)t * y_dim_total + (ulong)head_id * head_dim + dim_id] = sum;
)"
R"(        }
)"
R"(    }
)"
R"(
)"
R"(    s_warp[tid]      = state0;
)"
R"(    s_warp[tid + 64] = state1;
)"
R"(}
)"
R"(
)"
R"(// d_state = 256 (Falcon-H1). WG = 64 threads, each holds 4 state elements.
)"
R"(REQD_SUBGROUP_SIZE_64
)"
R"(kernel void kernel_ssm_scan_f32_mamba2_d256(
)"
R"(    global const char * src0_base, ulong src0_off,
)"
R"(    global const char * src1_base, ulong src1_off,
)"
R"(    global const char * src2_base, ulong src2_off,
)"
R"(    global const char * src3_base, ulong src3_off,
)"
R"(    global const char * src4_base, ulong src4_off,
)"
R"(    global const char * src5_base, ulong src5_off,
)"
R"(    global const char * src6_base, ulong src6_off,
)"
R"(    global       char * dst_base,  ulong dst_off,
)"
R"(    ulong s0_nb2, ulong s0_nb3,
)"
R"(    ulong x_nb2,  ulong x_nb3,
)"
R"(    ulong dt_nb1, ulong dt_nb2,
)"
R"(    ulong A_nb1,
)"
R"(    ulong B_nb2,  ulong B_nb3,
)"
R"(    ulong C_nb2,  ulong C_nb3,
)"
R"(    ulong s_off_bytes,
)"
R"(    int   head_dim, int n_head, int n_group, int n_tokens
)"
R"() {
)"
R"(    const int d_state = 256;
)"
R"(
)"
R"(    const int tid     = (int) get_local_id(0);
)"
R"(    const int wg_x    = (int) get_group_id(0);
)"
R"(    const int seq_id  = (int) get_group_id(1);
)"
R"(
)"
R"(    const int head_id = wg_x / head_dim;
)"
R"(    const int dim_id  = wg_x - head_id * head_dim;
)"
R"(    const int g       = head_id / (n_head / n_group);
)"
R"(
)"
R"(    src0_base += src0_off;
)"
R"(    src1_base += src1_off;
)"
R"(    src2_base += src2_off;
)"
R"(    src3_base += src3_off;
)"
R"(    src4_base += src4_off;
)"
R"(    src5_base += src5_off;
)"
R"(    src6_base += src6_off;
)"
R"(    dst_base  += dst_off;
)"
R"(
)"
R"(    const int seq_slot = ((global const int *) src6_base)[seq_id];
)"
R"(
)"
R"(    const ulong state_base_off = (ulong)seq_slot * s0_nb3 + (ulong)head_id * s0_nb2
)"
R"(                                + (ulong)dim_id * d_state * sizeof(float);
)"
R"(    global const float * s0_warp = (global const float *)(src0_base + state_base_off);
)"
R"(    const ulong state_out_off = (ulong)seq_id * s0_nb3 + (ulong)head_id * s0_nb2
)"
R"(                              + (ulong)dim_id * d_state * sizeof(float);
)"
R"(    global float * s_warp = (global float *)(dst_base + s_off_bytes + state_out_off);
)"
R"(
)"
R"(    global const char * x_seq  = src1_base + (ulong)seq_id * x_nb3;
)"
R"(    global const char * dt_seq = src2_base + (ulong)seq_id * dt_nb2;
)"
R"(    global const char * B_seq  = src4_base + (ulong)seq_id * B_nb3 + (ulong)g * d_state * sizeof(float);
)"
R"(    global const char * C_seq  = src5_base + (ulong)seq_id * C_nb3 + (ulong)g * d_state * sizeof(float);
)"
R"(
)"
R"(    const ulong y_dim_total = (ulong)n_head * head_dim;
)"
R"(    global float * y_seq = (global float *)dst_base
)"
R"(                           + (ulong)seq_id * (ulong)n_tokens * y_dim_total;
)"
R"(
)"
R"(    const float A_val = ((global const float *)src3_base)[(ulong)head_id * A_nb1 / sizeof(float)];
)"
R"(
)"
R"(    // c_factor = 4: each thread owns 4 state elements.
)"
R"(    float state0 = s0_warp[tid];
)"
R"(    float state1 = s0_warp[tid + 64];
)"
R"(    float state2 = s0_warp[tid + 128];
)"
R"(    float state3 = s0_warp[tid + 192];
)"
R"(
)"
R"(    for (int t = 0; t < n_tokens; ++t) {
)"
R"(        const float dt_h        = ((global const float *)(dt_seq + (ulong)t * dt_nb1))[head_id];
)"
R"(        const float dt_softplus = softplus_f32(dt_h);
)"
R"(        const float dA          = exp(dt_softplus * A_val);
)"
R"(        const float x_val       = ((global const float *)(x_seq + (ulong)t * x_nb2))[(ulong)head_id * head_dim + dim_id];
)"
R"(        const float x_dt        = x_val * dt_softplus;
)"
R"(
)"
R"(        global const float * B_t = (global const float *)(B_seq + (ulong)t * B_nb2);
)"
R"(        global const float * C_t = (global const float *)(C_seq + (ulong)t * C_nb2);
)"
R"(
)"
R"(        const float B0 = B_t[tid];
)"
R"(        const float B1 = B_t[tid + 64];
)"
R"(        const float B2 = B_t[tid + 128];
)"
R"(        const float B3 = B_t[tid + 192];
)"
R"(        const float C0 = C_t[tid];
)"
R"(        const float C1 = C_t[tid + 64];
)"
R"(        const float C2 = C_t[tid + 128];
)"
R"(        const float C3 = C_t[tid + 192];
)"
R"(
)"
R"(        state0 = state0 * dA + B0 * x_dt;
)"
R"(        state1 = state1 * dA + B1 * x_dt;
)"
R"(        state2 = state2 * dA + B2 * x_dt;
)"
R"(        state3 = state3 * dA + B3 * x_dt;
)"
R"(        const float partial = state0 * C0 + state1 * C1 + state2 * C2 + state3 * C3;
)"
R"(
)"
R"(        const float sum = sub_group_reduce_add(partial);
)"
R"(        if (tid == 0) {
)"
R"(            y_seq[(ulong)t * y_dim_total + (ulong)head_id * head_dim + dim_id] = sum;
)"
R"(        }
)"
R"(    }
)"
R"(
)"
R"(    s_warp[tid]       = state0;
)"
R"(    s_warp[tid + 64]  = state1;
)"
R"(    s_warp[tid + 128] = state2;
)"
R"(    s_warp[tid + 192] = state3;
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_ssm_scan_f32(
)"
R"(        global const char * s_buf,
)"
R"(        ulong               s_off,
)"
R"(        global const char * x_buf,
)"
R"(        ulong               x_off,
)"
R"(        global const char * dt_buf,
)"
R"(        ulong               dt_off,
)"
R"(        global const char * A_buf,
)"
R"(        ulong               A_off,
)"
R"(        global const char * B_buf,
)"
R"(        ulong               B_off,
)"
R"(        global const char * C_buf,
)"
R"(        ulong               C_off,
)"
R"(        global const char * ids_buf,
)"
R"(        ulong               ids_off,
)"
R"(        global       char * dst_buf,
)"
R"(        ulong               dst_off,
)"
R"(        ulong               s_nb2,
)"
R"(        ulong               s_nb3,
)"
R"(        ulong               x_nb2,
)"
R"(        ulong               x_nb3,
)"
R"(        ulong               dt_nb1,
)"
R"(        ulong               dt_nb2,
)"
R"(        ulong               A_nb1,
)"
R"(        ulong               B_nb2,
)"
R"(        ulong               B_nb3,
)"
R"(        ulong               C_nb2,
)"
R"(        ulong               C_nb3,
)"
R"(        ulong               state_off,
)"
R"(        int                 head_dim,
)"
R"(        int                 n_head,
)"
R"(        int                 n_group,
)"
R"(        int                 n_tokens,
)"
R"(        ulong               s_nb1,
)"
R"(        ulong               x_nb1,
)"
R"(        ulong               B_nb1,
)"
R"(        ulong               C_nb1,
)"
R"(        uint                A_ne0,
)"
R"(        uint                d_state,
)"
R"(        uint                n_seqs,
)"
R"(        uint                K,
)"
R"(        local        float * reduce
)"
R"() {
)"
R"(    global const char * s_data   = s_buf   + s_off;
)"
R"(    global const char * x_data   = x_buf   + x_off;
)"
R"(    global const char * dt_data  = dt_buf  + dt_off;
)"
R"(    global const char * A_data   = A_buf   + A_off;
)"
R"(    global const char * B_data   = B_buf   + B_off;
)"
R"(    global const char * C_data   = C_buf   + C_off;
)"
R"(    global const int  * ids_data = (global const int *) (ids_buf + ids_off);
)"
R"(    global       float * dst     = (global float *) (dst_buf + dst_off);
)"
R"(    const uint y_elems = state_off / sizeof(float);
)"
R"(
)"
R"(    const uint tid       = get_local_id(0);
)"
R"(    const uint inner_idx = get_group_id(0);
)"
R"(    const uint seq_idx   = get_group_id(1);
)"
R"(    const uint head_idx  = inner_idx / head_dim;
)"
R"(    const uint dim_idx   = inner_idx - head_idx * head_dim;
)"
R"(    const uint group_idx = head_idx / (n_head / n_group);
)"
R"(    const uint state_slot = (uint) ids_data[seq_idx];
)"
R"(
)"
R"(    const ulong s_idx = (ulong) state_slot * s_nb3 +
)"
R"(                        (ulong) head_idx * s_nb2 +
)"
R"(                        (ulong) dim_idx * s_nb1 +
)"
R"(                        (ulong) tid * sizeof(float);
)"
R"(    float state = *((global const float *) (s_data + s_idx));
)"
R"(
)"
R"(    const ulong A_idx = (ulong) head_idx * A_nb1 +
)"
R"(                        (ulong) (tid % A_ne0) * sizeof(float);
)"
R"(    const float A_value = *((global const float *) (A_data + A_idx));
)"
R"(
)"
R"(    for (int token_idx = 0; token_idx < n_tokens; ++token_idx) {
)"
R"(        const ulong x_idx = (ulong) head_idx * x_nb1 +
)"
R"(                            (ulong) token_idx * x_nb2 +
)"
R"(                            (ulong) seq_idx * x_nb3 +
)"
R"(                            (ulong) dim_idx * sizeof(float);
)"
R"(        const ulong dt_idx = (ulong) token_idx * dt_nb1 +
)"
R"(                             (ulong) seq_idx * dt_nb2 +
)"
R"(                             (ulong) head_idx * sizeof(float);
)"
R"(        const ulong B_idx = (ulong) group_idx * B_nb1 +
)"
R"(                            (ulong) token_idx * B_nb2 +
)"
R"(                            (ulong) seq_idx * B_nb3 +
)"
R"(                            (ulong) tid * sizeof(float);
)"
R"(        const ulong C_idx = (ulong) group_idx * C_nb1 +
)"
R"(                            (ulong) token_idx * C_nb2 +
)"
R"(                            (ulong) seq_idx * C_nb3 +
)"
R"(                            (ulong) tid * sizeof(float);
)"
R"(
)"
R"(        const float x_value  = *((global const float *) (x_data  + x_idx));
)"
R"(        const float dt_value = *((global const float *) (dt_data + dt_idx));
)"
R"(        const float B_value  = *((global const float *) (B_data  + B_idx));
)"
R"(        const float C_value  = *((global const float *) (C_data  + C_idx));
)"
R"(        const float dt_soft_plus = dt_value > 20.0f ? dt_value : log(1.0f + exp(dt_value));
)"
R"(        const float dA = exp(dt_soft_plus * A_value);
)"
R"(        const float x_dt = x_value * dt_soft_plus;
)"
R"(
)"
R"(        state = mad(state, dA, B_value * x_dt);
)"
R"(        reduce[tid] = state * C_value;
)"
R"(        barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(        for (uint stride = d_state / 2; stride > 0; stride >>= 1) {
)"
R"(            if (tid < stride) {
)"
R"(                reduce[tid] += reduce[tid + stride];
)"
R"(            }
)"
R"(            barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(        }
)"
R"(
)"
R"(        if (tid == 0) {
)"
R"(            const uint y_idx = dim_idx + head_idx * head_dim +
)"
R"(                               token_idx * n_head * head_dim +
)"
R"(                               seq_idx * n_tokens * n_head * head_dim;
)"
R"(            dst[y_idx] = reduce[0];
)"
R"(        }
)"
R"(
)"
R"(        const uint snapshot_slot = n_tokens - 1 - token_idx;
)"
R"(        if (snapshot_slot > 0 && snapshot_slot < K) {
)"
R"(            const uint snapshot_idx = y_elems + tid + dim_idx * d_state +
)"
R"(                                      head_idx * d_state * head_dim +
)"
R"(                                      (snapshot_slot * n_seqs + seq_idx) * d_state * head_dim * n_head;
)"
R"(            dst[snapshot_idx] = state;
)"
R"(        }
)"
R"(        barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(    }
)"
R"(
)"
R"(    const uint state_idx = y_elems + tid + dim_idx * d_state +
)"
R"(                           head_idx * d_state * head_dim +
)"
R"(                           seq_idx * d_state * head_dim * n_head;
)"
R"(    dst[state_idx] = state;
)"
R"(}
)"
