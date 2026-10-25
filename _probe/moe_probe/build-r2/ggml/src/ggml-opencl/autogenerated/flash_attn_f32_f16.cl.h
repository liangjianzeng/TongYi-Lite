R"(#pragma OPENCL EXTENSION cl_khr_fp16 : enable
)"
R"(
)"
R"(// NOTE: do NOT #define CLK_SUB_GROUP_SHUFFLE_WIDTH_WAVE_SIZE_QCOM here (or via
)"
R"(// -D); it must stay the enum constant declared by the compiler's header.
)"
R"(
)"
R"(#ifdef cl_intel_subgroups
)"
R"(#pragma OPENCL EXTENSION cl_intel_subgroups : enable
)"
R"(#else
)"
R"(#pragma OPENCL EXTENSION cl_khr_subgroups : enable
)"
R"(#endif
)"
R"(
)"
R"(#ifdef cl_qcom_reqd_sub_group_size
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
R"(// subgroup size for q1 kernels
)"
R"(#ifndef FA_SG
)"
R"(#define FA_SG 64
)"
R"(#endif
)"
R"(#ifdef cl_intel_required_subgroup_size
)"
R"(#pragma OPENCL EXTENSION cl_intel_required_subgroup_size : enable
)"
R"(#define REQD_FA_SG __attribute__((intel_reqd_sub_group_size(FA_SG)))
)"
R"(#else
)"
R"(#define REQD_FA_SG
)"
R"(#endif
)"
R"(
)"
R"(#ifdef cl_khr_subgroup_shuffle
)"
R"(#pragma OPENCL EXTENSION cl_khr_subgroup_shuffle : enable
)"
R"(#define HAS_SUBGROUP_SHUFFLE 1
)"
R"(#elif defined(cl_qcom_subgroup_shuffle)
)"
R"(#pragma OPENCL EXTENSION cl_qcom_subgroup_shuffle : enable
)"
R"(#define HAS_SUBGROUP_SHUFFLE 1
)"
R"(// Adreno compilers that expose only cl_qcom_subgroup_shuffle do not declare the KHR
)"
R"(// name, so calling it is an implicit declaration and the program fails to build.
)"
R"(// Route it to the qcom builtin.
)"
R"(#define sub_group_shuffle_xor(val, mask) qcom_sub_group_shuffle_xor((val), (mask), CLK_SUB_GROUP_SHUFFLE_WIDTH_WAVE_SIZE_QCOM, 0.0f)
)"
R"(#endif
)"
R"(
)"
R"(#define ACC_TYPE float
)"
R"(#define ACC_TYPE4 float4
)"
R"(#define Q_DATA_TYPE4 float4
)"
R"(#define KV_DATA_TYPE4 half4
)"
R"(#define O_DATA_TYPE4 float4
)"
R"(#define MASK_DATA_TYPE half
)"
R"(#define CONVERT_Q_ACC4(x) (x)
)"
R"(#define CONVERT_KV_ACC4(x) convert_float4(x)
)"
R"(#define CONVERT_O_DATA4(x) (x)
)"
R"(
)"
R"(#define DK_VEC (DK/4)
)"
R"(#define DV_VEC (DV/4)
)"
R"(
)"
R"(#ifndef FA_PARTIAL_FLOATS
)"
R"(#define FA_PARTIAL_FLOATS (2 + DV)
)"
R"(#endif
)"
R"(#define Q1_WG_SIZE FA_SG
)"
R"(
)"
R"(// The kernels are built with -cl-finite-math-only. On some older Adreno GPUs,
)"
R"(// infinite operand can cause undefined behavior and miscompilation for exp.
)"
R"(// Therefore, a large negative value is used instead.
)"
R"(#define FA_M_INIT (-3.0e38f)
)"
R"(
)"
R"(// Drop full unroll at DK>=192 — Adreno compiler host-memory budget.
)"
R"(#if DK >= 192
)"
R"(#define FA_UNROLL
)"
R"(#else
)"
R"(#define FA_UNROLL _Pragma("unroll")
)"
R"(#endif
)"
R"(
)"
R"(// N_SPLIT>1 splits DK/DV across threads to cut per-thread register use.
)"
R"(#ifndef N_SPLIT
)"
R"(#define N_SPLIT 1
)"
R"(#endif
)"
R"(
)"
R"(#define SPLIT_DK_VEC (DK_VEC / N_SPLIT)
)"
R"(#define SPLIT_DV_VEC (DV_VEC / N_SPLIT)
)"
R"(
)"
R"(#if N_SPLIT > 1
)"
R"(#define WG_SIZE (BLOCK_M * N_SPLIT)
)"
R"(#else
)"
R"(#define WG_SIZE (BLOCK_M)
)"
R"(#endif
)"
R"(
)"
R"(inline float get_alibi_slope(
)"
R"(    const float max_bias, const uint h, const uint n_head_log2, const float m0, const float m1
)"
R"() {
)"
R"(    if (max_bias <= 0.0f) {
)"
R"(        return 1.0f;
)"
R"(    }
)"
R"(    const float base = h < n_head_log2 ? m0 : m1;
)"
R"(    const int   exph = h < n_head_log2 ? h + 1 : 2*(h - n_head_log2) + 1;
)"
R"(
)"
R"(    return pow(base, exph);
)"
R"(}
)"
R"(
)"
R"(// Adreno compiler crashes when attempting to compile the entire program for DK=512,
)"
R"(// FA_DECODE_ONLY allows bypass the encoding kernel.
)"
R"(#if !defined(FA_DECODE_ONLY) && !defined(FA_MQ_ONLY)
)"
R"(#ifndef FA_TILE_NAME
)"
R"(#define FA_TILE_NAME flash_attn_f32_f16
)"
R"(#endif
)"
R"(__kernel void FA_TILE_NAME(
)"
R"(    const global void * q_void, ulong q_offset,
)"
R"(#ifdef FA_K_IMG
)"
R"(    __read_only image1d_buffer_t k_img, ulong k_offset_unused,
)"
R"(#else
)"
R"(    const global void * k_void, ulong k_offset,
)"
R"(#endif
)"
R"(    const global void * v_void, ulong v_offset,
)"
R"(    global void * o_void, ulong o_offset,
)"
R"(    const float scale,
)"
R"(    const int n_q,
)"
R"(    const int n_kv,
)"
R"(    const int is_causal,
)"
R"(    const int n_head,
)"
R"(    const ulong q_nb1, const ulong q_nb2, const ulong q_nb3,
)"
R"(    const ulong k_nb1, const ulong k_nb2, const ulong k_nb3,
)"
R"(    const ulong v_nb1, const ulong v_nb2, const ulong v_nb3,
)"
R"(    const ulong o_nb1, const ulong o_nb2, const ulong o_nb3,
)"
R"(    const float max_bias,
)"
R"(    const float m0,
)"
R"(    const float m1,
)"
R"(    const int n_head_log2,
)"
R"(    const float logit_softcap,
)"
R"(    const int n_head_kv,
)"
R"(    const global void* mask_void,
)"
R"(    const ulong mask_offset,
)"
R"(    const ulong mask_nb1,
)"
R"(    const ulong mask_nb2,
)"
R"(    const ulong mask_nb3,
)"
R"(    const int mask_ne2,
)"
R"(    const int mask_ne3,
)"
R"(    const global void* sinks_void,
)"
R"(    const ulong sinks_offset,
)"
R"(    const global void * k_pad_void,
)"
R"(    const global void * v_pad_void,
)"
R"(    const global void * mask_pad_void,
)"
R"(    const global char * blk,
)"
R"(    const int n_kv_blocks,
)"
R"(    const ulong mask_pad_nb1,
)"
R"(    const ulong mask_pad_nb2,
)"
R"(    const ulong mask_pad_nb3
)"
R"() {
)"
R"(    const int tid = get_local_id(0);
)"
R"(    const int block_q_idx = get_group_id(0);
)"
R"(    const int head_batch_idx = get_global_id(1);
)"
R"(
)"
R"(#if N_SPLIT > 1
)"
R"(    const int q_lane    = tid / N_SPLIT;
)"
R"(    const int split_idx = tid % N_SPLIT;
)"
R"(#else
)"
R"(    const int q_lane    = tid;
)"
R"(    const int split_idx = 0;
)"
R"(#endif
)"
R"(
)"
R"(    const int my_query_row = block_q_idx * BLOCK_M + q_lane;
)"
R"(    const int query_valid = my_query_row < n_q;
)"
R"(
)"
R"(    const int batch_idx = head_batch_idx / n_head;
)"
R"(    const int head_idx = head_batch_idx % n_head;
)"
R"(
)"
R"(    const int gqa_ratio = n_head / n_head_kv;
)"
R"(    const int head_kv_idx = head_idx / gqa_ratio;
)"
R"(    const int mask_head_idx = mask_void != NULL ? head_idx % mask_ne2 : 0;
)"
R"(    const int mask_batch_idx = mask_void != NULL ? batch_idx % mask_ne3 : 0;
)"
R"(
)"
R"(    const global char* q_base = (const global char*)q_void + q_offset;
)"
R"(#ifndef FA_K_IMG
)"
R"(    const global char* k_base = (const global char*)k_void + k_offset;
)"
R"(#endif
)"
R"(    const global char* v_base = (const global char*)v_void + v_offset;
)"
R"(    global char* o_base = (global char*)o_void + o_offset;
)"
R"(
)"
R"(    const global char* mask_base = NULL;
)"
R"(    if (mask_void != NULL) {
)"
R"(        mask_base = (const global char*)mask_void + mask_offset + mask_batch_idx * mask_nb3 + mask_head_idx * mask_nb2;
)"
R"(    }
)"
R"(    const global char* mask_pad_base = NULL;
)"
R"(    if (mask_pad_void != NULL) {
)"
R"(        mask_pad_base = (const global char*)mask_pad_void + mask_batch_idx * mask_pad_nb3 + mask_head_idx * mask_pad_nb2;
)"
R"(    }
)"
R"(    const global char* blk_base = NULL;
)"
R"(    if (blk != NULL) {
)"
R"(        const int n_q_blocks = (n_q + BLOCK_M - 1) / BLOCK_M;
)"
R"(        blk_base = blk + (((mask_batch_idx * mask_ne2) + mask_head_idx) * n_q_blocks + block_q_idx) * n_kv_blocks;
)"
R"(    }
)"
R"(
)"
R"(    ACC_TYPE4 q_priv[SPLIT_DK_VEC];
)"
R"(    const int dk_off = split_idx * SPLIT_DK_VEC;
)"
R"(    if (query_valid) {
)"
R"(        const ulong q_row_offset = batch_idx * q_nb3 + head_idx * q_nb2 + my_query_row * q_nb1;
)"
R"(        const global Q_DATA_TYPE4* q_ptr = (const global Q_DATA_TYPE4*)(q_base + q_row_offset);
)"
R"(        FA_UNROLL
)"
R"(        for (int i = 0; i < SPLIT_DK_VEC; ++i) {
)"
R"(            q_priv[i] = CONVERT_Q_ACC4(q_ptr[dk_off + i]);
)"
R"(        }
)"
R"(    } else {
)"
R"(        FA_UNROLL
)"
R"(        for (int i = 0; i < SPLIT_DK_VEC; ++i) {
)"
R"(            q_priv[i] = (ACC_TYPE4)(0.0f);
)"
R"(        }
)"
R"(    }
)"
R"(
)"
R"(    ACC_TYPE4 o_acc[SPLIT_DV_VEC];
)"
R"(    FA_UNROLL
)"
R"(    for (int i = 0; i < SPLIT_DV_VEC; ++i) {
)"
R"(        o_acc[i] = (ACC_TYPE4)(0.0f);
)"
R"(    }
)"
R"(
)"
R"(    ACC_TYPE m_i = FA_M_INIT;
)"
R"(    ACC_TYPE l_i = 0.0f;
)"
R"(
)"
R"(    float slope = get_alibi_slope(max_bias, head_idx, n_head_log2, m0, m1);
)"
R"(
)"
R"(#ifdef FA_K_LDS_T
)"
R"(    // K tile transposed: [dk vec][kv row] instead of [kv row][dk vec].
)"
R"(    //
)"
R"(    // The QK loop walks 2 or 4 KV rows at a time against the same dk element. Row-major
)"
R"(    // those are DK_VEC half4s apart, so each is its own 64-bit local read. Transposed they
)"
R"(    // are adjacent, so a pair is one 128-bit read -- half the LDS issues for the same bytes,
)"
R"(    // no extra registers, arithmetic untouched.
)"
R"(    //
)"
R"(    // This kernel looked like it should be FMA-bound (a half4 mad does ~4 ALU ops per LDS
)"
R"(    // read, unlike the 1:1 of the dp4a loop), but it is NOT: a wrong-math probe that kept
)"
R"(    // every FMA and removed the LDS reads ran it 38.6% faster (18.92 -> 11.62 ms/op).
)"
R"(    // Explicitly 16-byte aligned: FA_LK_PAIR below reads two adjacent half4 as one float4,
)"
R"(    // and the element type only obliges the compiler to align this array to 8. The indices
)"
R"(    // are even so the offset is a multiple of 16, but the base has to be too, and relying
)"
R"(    // on the compiler to over-align it is relying on luck.
)"
R"(    __local KV_DATA_TYPE4 l_k[DK_VEC][BLOCK_N] __attribute__((aligned(16)));
)"
R"(#define FA_LK(ROW, C) l_k[C][ROW]
)"
R"(    // Two adjacent KV rows as one 128-bit local read (half4 pair == 16 B). j is even and
)"
R"(    // BLOCK_N is even, so &l_k[c][j] is 16 B past a 16 B-aligned base.
)"
R"(#define FA_LK_PAIR(C, J) as_half8(*(__local const float4 *)(&l_k[C][J]))
)"
R"(#else
)"
R"(    __local KV_DATA_TYPE4 l_k[BLOCK_N][DK_VEC];
)"
R"(#define FA_LK(ROW, C) l_k[ROW][C]
)"
R"(#endif
)"
R"(    __local KV_DATA_TYPE4 l_v[BLOCK_N][DV_VEC];
)"
R"(
)"
R"(#if N_SPLIT > 1 && !defined(HAS_SUBGROUP_SHUFFLE)
)"
R"(    __local ACC_TYPE local_partial[BLOCK_N][WG_SIZE];
)"
R"(    __local ACC_TYPE local_p[BLOCK_M][BLOCK_N];
)"
R"(    __local ACC_TYPE local_softmax_scale[BLOCK_M];
)"
R"(    __local ACC_TYPE local_l_inv[BLOCK_M];
)"
R"(#endif
)"
R"(
)"
R"(    for (int k_start = 0; k_start < n_kv; k_start += BLOCK_N) {
)"
R"(        char blk_cur = 1;
)"
R"(        if (blk_base != NULL) {
)"
R"(            blk_cur = blk_base[k_start / BLOCK_N];
)"
R"(            if (blk_cur == 0) continue;
)"
R"(        }
)"
R"(
)"
R"(        const int use_kv_pad = k_pad_void != NULL && k_start + BLOCK_N > n_kv;
)"
R"(        const int k_tile_start = use_kv_pad ? 0 : k_start;
)"
R"(        const ulong k_tile_nb2 = use_kv_pad ? (ulong) BLOCK_N * k_nb1 : k_nb2;
)"
R"(        const ulong k_tile_nb3 = use_kv_pad ? (ulong) n_head_kv * k_tile_nb2 : k_nb3;
)"
R"(        const ulong v_tile_nb2 = use_kv_pad ? (ulong) BLOCK_N * v_nb1 : v_nb2;
)"
R"(        const ulong v_tile_nb3 = use_kv_pad ? (ulong) n_head_kv * v_tile_nb2 : v_nb3;
)"
R"(#ifdef FA_K_IMG
)"
R"(        // K via texture cache for the bulk (aligned) tiles; the ragged last
)"
R"(        // tile (use_kv_pad) still reads the f32-strided pad buffer from global.
)"
R"(        const global char* k_tile_base = use_kv_pad ? (const global char*) k_pad_void : (const global char*) 0;
)"
R"(        const int k_pitch_px_row   = (int)(k_nb1 >> 3);
)"
R"(        const int k_pitch_px_head  = (int)(k_nb2 >> 3);
)"
R"(        const int k_pitch_px_batch = (int)(k_nb3 >> 3);
)"
R"(#else
)"
R"(        const global char* k_tile_base = use_kv_pad ? (const global char*) k_pad_void : k_base;
)"
R"(#endif
)"
R"(        const global char* v_tile_base = use_kv_pad ? (const global char*) v_pad_void : v_base;
)"
R"(
)"
R"(        for (int i = tid; i < BLOCK_N * DK_VEC; i += WG_SIZE) {
)"
R"(            const int row = i / DK_VEC;
)"
R"(            const int col = i % DK_VEC;
)"
R"(            const int k_row_idx = k_tile_start + row;
)"
R"(            if (use_kv_pad || k_row_idx < n_kv) {
)"
R"(#ifdef FA_K_IMG
)"
R"(                if (use_kv_pad) {
)"
R"(                    const ulong k_row_offset = batch_idx * k_tile_nb3 + head_kv_idx * k_tile_nb2 + k_row_idx * k_nb1;
)"
R"(                    FA_LK(row, col) = ((__global KV_DATA_TYPE4*)(k_tile_base + k_row_offset))[col];
)"
R"(                } else {
)"
R"(                    const int k_row_px = batch_idx * k_pitch_px_batch + head_kv_idx * k_pitch_px_head + k_row_idx * k_pitch_px_row;
)"
R"(                    FA_LK(row, col) = read_imageh(k_img, k_row_px + col);
)"
R"(                }
)"
R"(#else
)"
R"(                const ulong k_row_offset = batch_idx * k_tile_nb3 + head_kv_idx * k_tile_nb2 + k_row_idx * k_nb1;
)"
R"(                FA_LK(row, col) = ((__global KV_DATA_TYPE4*)(k_tile_base + k_row_offset))[col];
)"
R"(#endif
)"
R"(            } else {
)"
R"(                FA_LK(row, col) = (KV_DATA_TYPE4)(0.0h);
)"
R"(            }
)"
R"(        }
)"
R"(        for (int i = tid; i < BLOCK_N * DV_VEC; i += WG_SIZE) {
)"
R"(            const int row = i / DV_VEC;
)"
R"(            const int col = i % DV_VEC;
)"
R"(            const int v_row_idx = k_tile_start + row;
)"
R"(            if (use_kv_pad || v_row_idx < n_kv) {
)"
R"(                const ulong v_row_offset = batch_idx * v_tile_nb3 + head_kv_idx * v_tile_nb2 + v_row_idx * v_nb1;
)"
R"(                l_v[row][col] = ((__global KV_DATA_TYPE4*)(v_tile_base + v_row_offset))[col];
)"
R"(            } else {
)"
R"(                l_v[row][col] = (KV_DATA_TYPE4)(0.0h);
)"
R"(            }
)"
R"(        }
)"
R"(        barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(#if N_SPLIT > 1 && defined(HAS_SUBGROUP_SHUFFLE)
)"
R"(        {
)"
R"(            const int dv_off = split_idx * SPLIT_DV_VEC;
)"
R"(            for (int j = 0; j < BLOCK_N; j += 2) {
)"
R"(                const int k_row0 = k_start + j;
)"
R"(                const int k_row1 = k_start + j + 1;
)"
R"(
)"
R"(                ACC_TYPE partial0 = 0.0f;
)"
R"(                ACC_TYPE partial1 = 0.0f;
)"
R"(                FA_UNROLL
)"
R"(                for (int k = 0; k < SPLIT_DK_VEC; k++) {
)"
R"(                    const ACC_TYPE4 qk = q_priv[k];
)"
R"(#if defined(FA_K_LDS_T)
)"
R"(                    // 2 KV rows adjacent in the transposed tile: one 128-bit local read.
)"
R"(                    const half8 kk = FA_LK_PAIR(dk_off + k, j);
)"
R"(                    ACC_TYPE4 dot0 = qk * CONVERT_KV_ACC4(kk.lo);
)"
R"(                    ACC_TYPE4 dot1 = qk * CONVERT_KV_ACC4(kk.hi);
)"
R"(#else
)"
R"(                    ACC_TYPE4 dot0 = qk * CONVERT_KV_ACC4(l_k[j  ][dk_off + k]);
)"
R"(                    ACC_TYPE4 dot1 = qk * CONVERT_KV_ACC4(l_k[j+1][dk_off + k]);
)"
R"(#endif
)"
R"(                    partial0 += dot0.s0 + dot0.s1 + dot0.s2 + dot0.s3;
)"
R"(                    partial1 += dot1.s0 + dot1.s1 + dot1.s2 + dot1.s3;
)"
R"(                }
)"
R"(
)"
R"(                FA_UNROLL
)"
R"(                for (int step = 1; step < N_SPLIT; step <<= 1) {
)"
R"(                    partial0 += sub_group_shuffle_xor(partial0, step);
)"
R"(                    partial1 += sub_group_shuffle_xor(partial1, step);
)"
R"(                }
)"
R"(
)"
R"(                ACC_TYPE score0 = partial0 * scale;
)"
R"(                ACC_TYPE score1 = partial1 * scale;
)"
R"(                if (logit_softcap > 0.0f) {
)"
R"(                    score0 = logit_softcap * tanh(score0 / logit_softcap);
)"
R"(                    score1 = logit_softcap * tanh(score1 / logit_softcap);
)"
R"(                }
)"
R"(
)"
R"(                if (!query_valid) { score0 = FA_M_INIT; score1 = FA_M_INIT; }
)"
R"(                if (is_causal) {
)"
R"(                    if (k_row0 > (n_kv - n_q + my_query_row)) score0 = FA_M_INIT;
)"
R"(                    if (k_row1 > (n_kv - n_q + my_query_row)) score1 = FA_M_INIT;
)"
R"(                }
)"
R"(                if (k_row0 >= n_kv) score0 = FA_M_INIT;
)"
R"(                if (k_row1 >= n_kv) score1 = FA_M_INIT;
)"
R"(
)"
R"(                if (query_valid && mask_base != NULL && blk_cur != 2) {
)"
R"(                    if (use_kv_pad && mask_pad_base != NULL) {
)"
R"(                        const global MASK_DATA_TYPE* mask_ptr =
)"
R"(                            (const global MASK_DATA_TYPE*)(mask_pad_base + my_query_row * mask_pad_nb1);
)"
R"(                        score0 += slope * (ACC_TYPE)mask_ptr[j];
)"
R"(                        score1 += slope * (ACC_TYPE)mask_ptr[j + 1];
)"
R"(                    } else {
)"
R"(                        const global MASK_DATA_TYPE* mask_ptr =
)"
R"(                            (const global MASK_DATA_TYPE*)(mask_base + my_query_row * mask_nb1);
)"
R"(                        if (k_row0 < n_kv) score0 += slope * (ACC_TYPE)mask_ptr[k_row0];
)"
R"(                        if (k_row1 < n_kv) score1 += slope * (ACC_TYPE)mask_ptr[k_row1];
)"
R"(                    }
)"
R"(                }
)"
R"(
)"
R"(                const ACC_TYPE m_new = max(m_i, max(score0, score1));
)"
R"(                // Whole tile masked (m_new == FA_M_INIT): force the exp() args
)"
R"(                // far negative so the tile contributes 0, not exp(0)=1.
)"
R"(                const ACC_TYPE m_exp = (m_new == FA_M_INIT) ? 0.0f : m_new;
)"
R"(                const ACC_TYPE sp    = native_exp(m_i - m_exp);
)"
R"(                const ACC_TYPE p0    = native_exp(score0 - m_exp);
)"
R"(                const ACC_TYPE p1    = native_exp(score1 - m_exp);
)"
R"(
)"
R"(                FA_UNROLL
)"
R"(                for (int i = 0; i < SPLIT_DV_VEC; ++i) {
)"
R"(                    o_acc[i] = o_acc[i] * sp
)"
R"(                             + p0 * CONVERT_KV_ACC4(l_v[j  ][dv_off + i])
)"
R"(                             + p1 * CONVERT_KV_ACC4(l_v[j+1][dv_off + i]);
)"
R"(                }
)"
R"(                l_i = l_i * sp + p0 + p1;
)"
R"(                m_i = m_new;
)"
R"(            }
)"
R"(        }
)"
R"(#elif N_SPLIT > 1
)"
R"(        // N_SPLIT>1 fallback (no shuffle): 3-phase local-memory reduction.
)"
R"(        // Phase 1 — partial dots for all BLOCK_N tokens.
)"
R"(        for (int j = 0; j < BLOCK_N; ++j) {
)"
R"(            ACC_TYPE4 dot_acc = (ACC_TYPE4)(0.0f);
)"
R"(            FA_UNROLL
)"
R"(            for (int k = 0; k < SPLIT_DK_VEC; k++) {
)"
R"(                dot_acc = mad(q_priv[k], CONVERT_KV_ACC4(FA_LK(j, dk_off + k)), dot_acc);
)"
R"(            }
)"
R"(            local_partial[j][tid] =
)"
R"(                dot_acc.s0 + dot_acc.s1 + dot_acc.s2 + dot_acc.s3;
)"
R"(        }
)"
R"(        barrier(CLK_LOCAL_MEM_FENCE);  // 1 barrier: partial dots visible
)"
R"(
)"
R"(        // Phase 2 — split_idx==0 reduces partial sums and computes block softmax.
)"
R"(        if (split_idx == 0) {
)"
R"(            if (query_valid) {
)"
R"(                ACC_TYPE m_new = m_i;
)"
R"(                for (int j = 0; j < BLOCK_N; ++j) {
)"
R"(                    const int k_row = k_start + j;
)"
R"(                    ACC_TYPE score = 0.0f;
)"
R"(                    FA_UNROLL
)"
R"(                    for (int s = 0; s < N_SPLIT; s++) {
)"
R"(                        score += local_partial[j][q_lane * N_SPLIT + s];
)"
R"(                    }
)"
R"(                    score *= scale;
)"
R"(                    if (logit_softcap > 0.0f) {
)"
R"(                        score = logit_softcap * tanh(score / logit_softcap);
)"
R"(                    }
)"
R"(
)"
R"(                    if (is_causal && k_row > (n_kv - n_q + my_query_row)) score = FA_M_INIT;
)"
R"(                    if (k_row >= n_kv) score = FA_M_INIT;
)"
R"(
)"
R"(                    if (mask_base != NULL && blk_cur != 2) {
)"
R"(                        if (use_kv_pad && mask_pad_base != NULL) {
)"
R"(                            const global MASK_DATA_TYPE* mask_ptr =
)"
R"(                                (const global MASK_DATA_TYPE*)(mask_pad_base + my_query_row * mask_pad_nb1);
)"
R"(                            score += slope * (ACC_TYPE)mask_ptr[j];
)"
R"(                        } else {
)"
R"(                            const global MASK_DATA_TYPE* mask_ptr =
)"
R"(                                (const global MASK_DATA_TYPE*)(mask_base + my_query_row * mask_nb1);
)"
R"(                            if (k_row < n_kv) score += slope * (ACC_TYPE)mask_ptr[k_row];
)"
R"(                        }
)"
R"(                    }
)"
R"(
)"
R"(                    m_new = max(m_new, score);
)"
R"(                    local_p[q_lane][j] = score;
)"
R"(                }
)"
R"(
)"
R"(                const ACC_TYPE m_exp = (m_new == FA_M_INIT) ? 0.0f : m_new;
)"
R"(                const ACC_TYPE sp = native_exp(m_i - m_exp);
)"
R"(                ACC_TYPE l_new = l_i * sp;
)"
R"(                for (int j = 0; j < BLOCK_N; ++j) {
)"
R"(                    const ACC_TYPE p = native_exp(local_p[q_lane][j] - m_exp);
)"
R"(                    local_p[q_lane][j] = p;
)"
R"(                    l_new += p;
)"
R"(                }
)"
R"(                local_softmax_scale[q_lane] = sp;
)"
R"(                l_i = l_new;
)"
R"(                m_i = m_new;
)"
R"(            } else {
)"
R"(                local_softmax_scale[q_lane] = 1.0f;
)"
R"(                for (int j = 0; j < BLOCK_N; ++j) local_p[q_lane][j] = 0.0f;
)"
R"(            }
)"
R"(        }
)"
R"(        barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(        // Phase 3 — V accumulate using broadcast probabilities.
)"
R"(        {
)"
R"(            const ACC_TYPE sp_block = local_softmax_scale[q_lane];
)"
R"(            const int dv_off = split_idx * SPLIT_DV_VEC;
)"
R"(            FA_UNROLL
)"
R"(            for (int i = 0; i < SPLIT_DV_VEC; ++i) {
)"
R"(                o_acc[i] *= sp_block;
)"
R"(            }
)"
R"(            for (int j = 0; j < BLOCK_N; ++j) {
)"
R"(                const ACC_TYPE p = local_p[q_lane][j];
)"
R"(                FA_UNROLL
)"
R"(                for (int i = 0; i < SPLIT_DV_VEC; ++i) {
)"
R"(                    o_acc[i] = mad(p, CONVERT_KV_ACC4(l_v[j][dv_off + i]), o_acc[i]);
)"
R"(                }
)"
R"(            }
)"
R"(        }
)"
R"(#else
)"
R"(        // N_SPLIT==1: j+=4 unroll. Requires BLOCK_N % 4 == 0.
)"
R"(        if (query_valid) {
)"
R"(            for (int j = 0; j < BLOCK_N; j += 4) {
)"
R"(                const int k_row0 = k_start + j;
)"
R"(                const int k_row1 = k_start + j + 1;
)"
R"(                const int k_row2 = k_start + j + 2;
)"
R"(                const int k_row3 = k_start + j + 3;
)"
R"(
)"
R"(                ACC_TYPE4 dot_acc0 = (ACC_TYPE4)(0.0f);
)"
R"(                ACC_TYPE4 dot_acc1 = (ACC_TYPE4)(0.0f);
)"
R"(                ACC_TYPE4 dot_acc2 = (ACC_TYPE4)(0.0f);
)"
R"(                ACC_TYPE4 dot_acc3 = (ACC_TYPE4)(0.0f);
)"
R"(                FA_UNROLL
)"
R"(                for (int k = 0; k < DK_VEC; k++) {
)"
R"(                    const ACC_TYPE4 qk = q_priv[k];
)"
R"(#if defined(FA_K_LDS_T)
)"
R"(                    // 4 KV rows adjacent in the transposed tile: two 128-bit local reads
)"
R"(                    // instead of four 64-bit ones.
)"
R"(                    const half8 kk01 = FA_LK_PAIR(k, j);
)"
R"(                    const half8 kk23 = FA_LK_PAIR(k, j + 2);
)"
R"(                    dot_acc0 = mad(qk, CONVERT_KV_ACC4(kk01.lo), dot_acc0);
)"
R"(                    dot_acc1 = mad(qk, CONVERT_KV_ACC4(kk01.hi), dot_acc1);
)"
R"(                    dot_acc2 = mad(qk, CONVERT_KV_ACC4(kk23.lo), dot_acc2);
)"
R"(                    dot_acc3 = mad(qk, CONVERT_KV_ACC4(kk23.hi), dot_acc3);
)"
R"(#else
)"
R"(                    dot_acc0 = mad(qk, CONVERT_KV_ACC4(l_k[j][k]),   dot_acc0);
)"
R"(                    dot_acc1 = mad(qk, CONVERT_KV_ACC4(l_k[j+1][k]), dot_acc1);
)"
R"(                    dot_acc2 = mad(qk, CONVERT_KV_ACC4(l_k[j+2][k]), dot_acc2);
)"
R"(                    dot_acc3 = mad(qk, CONVERT_KV_ACC4(l_k[j+3][k]), dot_acc3);
)"
R"(#endif
)"
R"(                }
)"
R"(                ACC_TYPE s0 = (dot_acc0.s0 + dot_acc0.s1 + dot_acc0.s2 + dot_acc0.s3) * scale;
)"
R"(                ACC_TYPE s1 = (dot_acc1.s0 + dot_acc1.s1 + dot_acc1.s2 + dot_acc1.s3) * scale;
)"
R"(                ACC_TYPE s2 = (dot_acc2.s0 + dot_acc2.s1 + dot_acc2.s2 + dot_acc2.s3) * scale;
)"
R"(                ACC_TYPE s3 = (dot_acc3.s0 + dot_acc3.s1 + dot_acc3.s2 + dot_acc3.s3) * scale;
)"
R"(                if (logit_softcap > 0.0f) {
)"
R"(                    s0 = logit_softcap * tanh(s0 / logit_softcap);
)"
R"(                    s1 = logit_softcap * tanh(s1 / logit_softcap);
)"
R"(                    s2 = logit_softcap * tanh(s2 / logit_softcap);
)"
R"(                    s3 = logit_softcap * tanh(s3 / logit_softcap);
)"
R"(                }
)"
R"(
)"
R"(                if (is_causal) {
)"
R"(                    const int causal_limit = n_kv - n_q + my_query_row;
)"
R"(                    if (k_row0 > causal_limit) s0 = FA_M_INIT;
)"
R"(                    if (k_row1 > causal_limit) s1 = FA_M_INIT;
)"
R"(                    if (k_row2 > causal_limit) s2 = FA_M_INIT;
)"
R"(                    if (k_row3 > causal_limit) s3 = FA_M_INIT;
)"
R"(                }
)"
R"(                if (k_row0 >= n_kv) s0 = FA_M_INIT;
)"
R"(                if (k_row1 >= n_kv) s1 = FA_M_INIT;
)"
R"(                if (k_row2 >= n_kv) s2 = FA_M_INIT;
)"
R"(                if (k_row3 >= n_kv) s3 = FA_M_INIT;
)"
R"(
)"
R"(                if (mask_base != NULL && blk_cur != 2) {
)"
R"(                    if (use_kv_pad && mask_pad_base != NULL) {
)"
R"(                        const global MASK_DATA_TYPE* mask_ptr = (const global MASK_DATA_TYPE*)(mask_pad_base + my_query_row * mask_pad_nb1);
)"
R"(                        s0 += slope * (ACC_TYPE)mask_ptr[j];
)"
R"(                        s1 += slope * (ACC_TYPE)mask_ptr[j + 1];
)"
R"(                        s2 += slope * (ACC_TYPE)mask_ptr[j + 2];
)"
R"(                        s3 += slope * (ACC_TYPE)mask_ptr[j + 3];
)"
R"(                    } else {
)"
R"(                        const global MASK_DATA_TYPE* mask_ptr = (const global MASK_DATA_TYPE*)(mask_base + my_query_row * mask_nb1);
)"
R"(                        if (k_row0 < n_kv) s0 += slope * (ACC_TYPE)mask_ptr[k_row0];
)"
R"(                        if (k_row1 < n_kv) s1 += slope * (ACC_TYPE)mask_ptr[k_row1];
)"
R"(                        if (k_row2 < n_kv) s2 += slope * (ACC_TYPE)mask_ptr[k_row2];
)"
R"(                        if (k_row3 < n_kv) s3 += slope * (ACC_TYPE)mask_ptr[k_row3];
)"
R"(                    }
)"
R"(                }
)"
R"(
)"
R"(                const ACC_TYPE m_new      = max(m_i, max(max(s0, s1), max(s2, s3)));
)"
R"(                // Whole tile masked (m_new == FA_M_INIT): force the exp() args
)"
R"(                // far negative so the tile contributes 0, not exp(0)=1.
)"
R"(                const ACC_TYPE m_exp      = (m_new == FA_M_INIT) ? 0.0f : m_new;
)"
R"(                const ACC_TYPE scale_prev = native_exp(m_i - m_exp);
)"
R"(                const ACC_TYPE p0         = native_exp(s0 - m_exp);
)"
R"(                const ACC_TYPE p1         = native_exp(s1 - m_exp);
)"
R"(                const ACC_TYPE p2         = native_exp(s2 - m_exp);
)"
R"(                const ACC_TYPE p3         = native_exp(s3 - m_exp);
)"
R"(
)"
R"(                FA_UNROLL
)"
R"(                for (int i = 0; i < DV_VEC; ++i) {
)"
R"(                    o_acc[i] = mad(p3, CONVERT_KV_ACC4(l_v[j+3][i]),
)"
R"(                               mad(p2, CONVERT_KV_ACC4(l_v[j+2][i]),
)"
R"(                               mad(p1, CONVERT_KV_ACC4(l_v[j+1][i]),
)"
R"(                               mad(p0, CONVERT_KV_ACC4(l_v[j][i]),
)"
R"(                               o_acc[i] * scale_prev))));
)"
R"(                }
)"
R"(                l_i = l_i * scale_prev + p0 + p1 + p2 + p3;
)"
R"(                m_i = m_new;
)"
R"(            }
)"
R"(        }
)"
R"(#endif
)"
R"(        // End of tile: every thread must finish reading l_k/l_v before the
)"
R"(        // next iteration's load overwrites them (WAR hazard on local memory).
)"
R"(        barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(    }
)"
R"(
)"
R"(    // Write output.
)"
R"(#if N_SPLIT > 1 && defined(HAS_SUBGROUP_SHUFFLE)
)"
R"(    if (query_valid) {
)"
R"(        ACC_TYPE sinks_sp = 1.0f;
)"
R"(        if (sinks_void != NULL) {
)"
R"(            const global ACC_TYPE* sinks_ptr = (const global ACC_TYPE*)((const global char*)sinks_void + sinks_offset);
)"
R"(            const ACC_TYPE m_sink  = sinks_ptr[head_idx];
)"
R"(            const ACC_TYPE m_final = max(m_i, m_sink);
)"
R"(            sinks_sp = exp(m_i - m_final);
)"
R"(            l_i = l_i * sinks_sp + exp(m_sink - m_final);
)"
R"(            m_i = m_final;
)"
R"(        }
)"
R"(        const ACC_TYPE l_inv = (l_i > 0.0f) ? (1.0f / l_i) : 0.0f;
)"
R"(        const int dv_off = split_idx * SPLIT_DV_VEC;
)"
R"(        const ulong o_row_offset = batch_idx * o_nb3 + my_query_row * o_nb2 + head_idx * o_nb1;
)"
R"(        global O_DATA_TYPE4 *o_row = (global O_DATA_TYPE4 *)(o_base + o_row_offset);
)"
R"(        if (l_inv > 0.0f) {
)"
R"(            FA_UNROLL
)"
R"(            for (int i = 0; i < SPLIT_DV_VEC; ++i) {
)"
R"(                o_row[dv_off + i] = CONVERT_O_DATA4(o_acc[i] * sinks_sp * l_inv);
)"
R"(            }
)"
R"(        } else {
)"
R"(            FA_UNROLL
)"
R"(            for (int i = 0; i < SPLIT_DV_VEC; ++i) {
)"
R"(                o_row[dv_off + i] = (O_DATA_TYPE4)(0.0f);
)"
R"(            }
)"
R"(        }
)"
R"(    }
)"
R"(#elif N_SPLIT > 1
)"
R"(    if (split_idx == 0) {
)"
R"(        ACC_TYPE sinks_sp = 1.0f;
)"
R"(        if (query_valid && sinks_void != NULL) {
)"
R"(            const global ACC_TYPE* sinks_ptr = (const global ACC_TYPE*)((const global char*)sinks_void + sinks_offset);
)"
R"(            const ACC_TYPE m_sink = sinks_ptr[head_idx];
)"
R"(            const ACC_TYPE m_final = max(m_i, m_sink);
)"
R"(            sinks_sp = exp(m_i - m_final);
)"
R"(            l_i = l_i * sinks_sp + exp(m_sink - m_final);
)"
R"(            m_i = m_final;
)"
R"(        }
)"
R"(        local_softmax_scale[q_lane] = sinks_sp;
)"
R"(        local_l_inv[q_lane] = (query_valid && l_i > 0.0f) ? (1.0f / l_i) : 0.0f;
)"
R"(    }
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(    if (query_valid) {
)"
R"(        const ACC_TYPE sinks_sp = local_softmax_scale[q_lane];
)"
R"(        const ACC_TYPE l_inv    = local_l_inv[q_lane];
)"
R"(        const int dv_off = split_idx * SPLIT_DV_VEC;
)"
R"(        const ulong o_row_offset = batch_idx * o_nb3 + my_query_row * o_nb2 + head_idx * o_nb1;
)"
R"(        global O_DATA_TYPE4 *o_row = (global O_DATA_TYPE4 *)(o_base + o_row_offset);
)"
R"(        if (l_inv > 0.0f) {
)"
R"(            FA_UNROLL
)"
R"(            for (int i = 0; i < SPLIT_DV_VEC; ++i) {
)"
R"(                o_row[dv_off + i] = CONVERT_O_DATA4(o_acc[i] * sinks_sp * l_inv);
)"
R"(            }
)"
R"(        } else {
)"
R"(            FA_UNROLL
)"
R"(            for (int i = 0; i < SPLIT_DV_VEC; ++i) {
)"
R"(                o_row[dv_off + i] = (O_DATA_TYPE4)(0.0f);
)"
R"(            }
)"
R"(        }
)"
R"(    }
)"
R"(#else
)"
R"(    if (query_valid) {
)"
R"(        if (sinks_void != NULL) {
)"
R"(            const global ACC_TYPE* sinks_ptr = (const global ACC_TYPE*)((const global char*)sinks_void + sinks_offset);
)"
R"(            const ACC_TYPE m_sink = sinks_ptr[head_idx];
)"
R"(            const ACC_TYPE m_final = max(m_i, m_sink);
)"
R"(
)"
R"(            const ACC_TYPE scale_o = exp(m_i - m_final);
)"
R"(            FA_UNROLL
)"
R"(            for (int i = 0; i < DV_VEC; ++i) {
)"
R"(                o_acc[i] *= scale_o;
)"
R"(            }
)"
R"(
)"
R"(            l_i = l_i * exp(m_i - m_final) + exp(m_sink - m_final);
)"
R"(        }
)"
R"(
)"
R"(        const ulong o_row_offset = batch_idx * o_nb3 + my_query_row * o_nb2 + head_idx * o_nb1;
)"
R"(        global O_DATA_TYPE4 *o_row = (global O_DATA_TYPE4 *)(o_base + o_row_offset);
)"
R"(        if (l_i > 0.0f) {
)"
R"(            const ACC_TYPE l_inv = 1.0f / l_i;
)"
R"(            FA_UNROLL
)"
R"(            for (int i = 0; i < DV_VEC; ++i) {
)"
R"(                o_row[i] = CONVERT_O_DATA4(o_acc[i] * l_inv);
)"
R"(            }
)"
R"(        } else {
)"
R"(            FA_UNROLL
)"
R"(            for (int i = 0; i < DV_VEC; ++i) {
)"
R"(                o_row[i] = (O_DATA_TYPE4)(0.0f);
)"
R"(            }
)"
R"(        }
)"
R"(    }
)"
R"(#endif
)"
R"(}
)"
R"(#endif  // !FA_DECODE_ONLY
)"
R"(
)"
R"(// allow bypassing decode kernels to avoid compiler crash for DK=512 on Adreno GPUs
)"
R"(#ifndef FA_PREFILL_ONLY
)"
R"(#if !defined(FA_MQ_ONLY) && !defined(FA_VEC_ONLY)
)"
R"(REQD_FA_SG
)"
R"(__kernel void flash_attn_f32_f16_q1(
)"
R"(    const global void * q_void, ulong q_offset,
)"
R"(    const global void * k_void, ulong k_offset,
)"
R"(    const global void * v_void, ulong v_offset,
)"
R"(    global void * o_void, ulong o_offset,
)"
R"(    const float scale,
)"
R"(    const int n_q,
)"
R"(    const int n_kv,
)"
R"(    const int is_causal,
)"
R"(    const int n_head,
)"
R"(    const ulong q_nb1, const ulong q_nb2, const ulong q_nb3,
)"
R"(    const ulong k_nb1, const ulong k_nb2, const ulong k_nb3,
)"
R"(    const ulong v_nb1, const ulong v_nb2, const ulong v_nb3,
)"
R"(    const ulong o_nb1, const ulong o_nb2, const ulong o_nb3,
)"
R"(    const float max_bias,
)"
R"(    const float m0,
)"
R"(    const float m1,
)"
R"(    const int n_head_log2,
)"
R"(    const float logit_softcap,
)"
R"(    const int n_head_kv,
)"
R"(    const global void* mask_void,
)"
R"(    const ulong mask_offset,
)"
R"(    const ulong mask_nb1,
)"
R"(    const ulong mask_nb2,
)"
R"(    const ulong mask_nb3,
)"
R"(    const int mask_ne2,
)"
R"(    const int mask_ne3,
)"
R"(    const global void* sinks_void,
)"
R"(    const ulong sinks_offset
)"
R"() {
)"
R"(    const int tid = get_local_id(0);
)"
R"(    const int head_batch_idx = get_global_id(1);
)"
R"(
)"
R"(    const int batch_idx = head_batch_idx / n_head;
)"
R"(    const int head_idx = head_batch_idx % n_head;
)"
R"(
)"
R"(    const int gqa_ratio = n_head / n_head_kv;
)"
R"(    const int head_kv_idx = head_idx / gqa_ratio;
)"
R"(
)"
R"(    const global char* q_base = (const global char*)q_void + q_offset;
)"
R"(#ifndef FA_K_IMG
)"
R"(    const global char* k_base = (const global char*)k_void + k_offset;
)"
R"(#endif
)"
R"(    const global char* v_base = (const global char*)v_void + v_offset;
)"
R"(    global char* o_base = (global char*)o_void + o_offset;
)"
R"(
)"
R"(    const global char* mask_base = NULL;
)"
R"(    if (mask_void != NULL) {
)"
R"(        const int mask_head_idx = head_idx % mask_ne2;
)"
R"(        const int mask_batch_idx = batch_idx % mask_ne3;
)"
R"(        mask_base = (const global char*)mask_void + mask_offset + mask_batch_idx * mask_nb3 + mask_head_idx * mask_nb2;
)"
R"(    }
)"
R"(
)"
R"(    // Q is uniform across WG threads (n_q=1). Share via local memory to
)"
R"(    // avoid per-thread q_priv[DK_VEC] dynamic-indexed private array that
)"
R"(    // spills to DDR on Adreno.
)"
R"(    __local ACC_TYPE4 q_shared[DK_VEC];
)"
R"(    const ulong q_row_offset = batch_idx * q_nb3 + head_idx * q_nb2;
)"
R"(    const global Q_DATA_TYPE4* q_ptr = (const global Q_DATA_TYPE4*)(q_base + q_row_offset);
)"
R"(    for (int i = tid; i < DK_VEC; i += Q1_WG_SIZE) {
)"
R"(        q_shared[i] = CONVERT_Q_ACC4(q_ptr[i]);
)"
R"(    }
)"
R"(    sub_group_barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(    float slope = get_alibi_slope(max_bias, head_idx, n_head_log2, m0, m1);
)"
R"(
)"
R"(    const global ACC_TYPE* sinks_ptr = NULL;
)"
R"(    if (sinks_void != NULL) {
)"
R"(        sinks_ptr = (const global ACC_TYPE*)((const global char*)sinks_void + sinks_offset);
)"
R"(    }
)"
R"(
)"
R"(    ACC_TYPE m_i = (sinks_ptr != NULL) ? sinks_ptr[head_idx] : FA_M_INIT;
)"
R"(    for (int k_idx = tid; k_idx < n_kv; k_idx += Q1_WG_SIZE) {
)"
R"(        const ulong k_row_offset = batch_idx * k_nb3 + head_kv_idx * k_nb2 + k_idx * k_nb1;
)"
R"(        const global KV_DATA_TYPE4* k_ptr = (const global KV_DATA_TYPE4*)(k_base + k_row_offset);
)"
R"(        ACC_TYPE4 dot_acc = (ACC_TYPE4)(0.0f);
)"
R"(        FA_UNROLL
)"
R"(        for (int k = 0; k < DK_VEC; k++) {
)"
R"(            dot_acc = mad(q_shared[k], CONVERT_KV_ACC4(k_ptr[k]), dot_acc);
)"
R"(        }
)"
R"(        ACC_TYPE score = (dot_acc.s0 + dot_acc.s1 + dot_acc.s2 + dot_acc.s3) * scale;
)"
R"(        if (logit_softcap > 0.0f) {
)"
R"(            score = logit_softcap * tanh(score / logit_softcap);
)"
R"(        }
)"
R"(        if (mask_base != NULL) {
)"
R"(            const global MASK_DATA_TYPE* mask_ptr = (const global MASK_DATA_TYPE*)(mask_base);
)"
R"(            score += slope * (ACC_TYPE)mask_ptr[k_idx];
)"
R"(        }
)"
R"(        m_i = max(m_i, score);
)"
R"(    }
)"
R"(
)"
R"(    const ACC_TYPE m_final = sub_group_reduce_max(m_i);
)"
R"(
)"
R"(    ACC_TYPE4 o_acc[DV_VEC];
)"
R"(    FA_UNROLL
)"
R"(    for (int i = 0; i < DV_VEC; ++i) o_acc[i] = (ACC_TYPE4)(0.0f);
)"
R"(    ACC_TYPE l_i = 0.0f;
)"
R"(
)"
R"(    for (int k_idx = tid; k_idx < n_kv; k_idx += Q1_WG_SIZE) {
)"
R"(        const ulong k_row_offset = batch_idx * k_nb3 + head_kv_idx * k_nb2 + k_idx * k_nb1;
)"
R"(        const ulong v_row_offset = batch_idx * v_nb3 + head_kv_idx * v_nb2 + k_idx * v_nb1;
)"
R"(        const global KV_DATA_TYPE4* k_ptr = (const global KV_DATA_TYPE4*)(k_base + k_row_offset);
)"
R"(        const global KV_DATA_TYPE4* v_ptr = (const global KV_DATA_TYPE4*)(v_base + v_row_offset);
)"
R"(        ACC_TYPE4 dot_acc = (ACC_TYPE4)(0.0f);
)"
R"(        FA_UNROLL
)"
R"(        for (int k = 0; k < DK_VEC; k++) {
)"
R"(            dot_acc = mad(q_shared[k], CONVERT_KV_ACC4(k_ptr[k]), dot_acc);
)"
R"(        }
)"
R"(        ACC_TYPE score = (dot_acc.s0 + dot_acc.s1 + dot_acc.s2 + dot_acc.s3) * scale;
)"
R"(        if (logit_softcap > 0.0f) {
)"
R"(            score = logit_softcap * tanh(score / logit_softcap);
)"
R"(        }
)"
R"(        if (mask_base != NULL) {
)"
R"(            const global MASK_DATA_TYPE* mask_ptr = (const global MASK_DATA_TYPE*)(mask_base);
)"
R"(            score += slope * (ACC_TYPE)mask_ptr[k_idx];
)"
R"(        }
)"
R"(        const ACC_TYPE p = exp(score - m_final);
)"
R"(        l_i += p;
)"
R"(        FA_UNROLL
)"
R"(        for (int i = 0; i < DV_VEC; i++) {
)"
R"(            o_acc[i] = mad(p, CONVERT_KV_ACC4(v_ptr[i]), o_acc[i]);
)"
R"(        }
)"
R"(    }
)"
R"(
)"
R"(    __local ACC_TYPE4 local_o_comp[Q1_WG_SIZE];
)"
R"(    const ACC_TYPE l_red = sub_group_reduce_add(l_i);
)"
R"(
)"
R"(    const ulong o_row_offset = batch_idx * o_nb3 + head_idx * o_nb1;
)"
R"(    global O_DATA_TYPE4 *o_row = (global O_DATA_TYPE4 *)(o_base + o_row_offset);
)"
R"(    ACC_TYPE l_final = l_red;
)"
R"(
)"
R"(    if (sinks_ptr != NULL) {
)"
R"(        l_final += exp(sinks_ptr[head_idx] - m_final);
)"
R"(    }
)"
R"(
)"
R"(    if (l_final > 0.0f) {
)"
R"(        const ACC_TYPE l_inv = 1.0f / l_final;
)"
R"(        for (int i = 0; i < DV_VEC; i++) {
)"
R"(            local_o_comp[tid] = o_acc[i];
)"
R"(            sub_group_barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(            FA_UNROLL
)"
R"(            for (int s = Q1_WG_SIZE / 2; s > 0; s >>= 1) {
)"
R"(                if (tid < s) local_o_comp[tid] += local_o_comp[tid + s];
)"
R"(                sub_group_barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(            }
)"
R"(            if (tid == 0) {
)"
R"(                o_row[i] = CONVERT_O_DATA4(local_o_comp[0] * l_inv);
)"
R"(            }
)"
R"(        }
)"
R"(    } else if (tid == 0) {
)"
R"(        FA_UNROLL
)"
R"(        for (int i = 0; i < DV_VEC; ++i) o_row[i] = (O_DATA_TYPE4)(0.0f);
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(#endif  // !FA_MQ_ONLY (q1)
)"
R"(// decode variant for large DV (e.g. Gemma-4 DK=DV=512 global layers).
)"
R"(#define VEC_NSG          4
)"
R"(#define VEC_WG_SIZE      (Q1_WG_SIZE * VEC_NSG)
)"
R"(#define Q1V_DV_PER_THREAD ((DV_VEC + Q1_WG_SIZE - 1) / Q1_WG_SIZE)
)"
R"(
)"
R"(// allow bypassing the kernel to avoid compiler crash for DK=512 on Adreno GPUs
)"
R"(#if !defined(FA_DECODE_MINIMAL) && !defined(FA_MQ_ONLY)
)"
R"(REQD_SUBGROUP_SIZE_64
)"
R"(__kernel void flash_attn_f32_f16_q1_vec(
)"
R"(    const global void * q_void, ulong q_offset,
)"
R"(    const global void * k_void, ulong k_offset,
)"
R"(    const global void * v_void, ulong v_offset,
)"
R"(    global void * o_void, ulong o_offset,
)"
R"(    const float scale,
)"
R"(    const int n_q,
)"
R"(    const int n_kv,
)"
R"(    const int is_causal,
)"
R"(    const int n_head,
)"
R"(    const ulong q_nb1, const ulong q_nb2, const ulong q_nb3,
)"
R"(    const ulong k_nb1, const ulong k_nb2, const ulong k_nb3,
)"
R"(    const ulong v_nb1, const ulong v_nb2, const ulong v_nb3,
)"
R"(    const ulong o_nb1, const ulong o_nb2, const ulong o_nb3,
)"
R"(    const float max_bias,
)"
R"(    const float m0,
)"
R"(    const float m1,
)"
R"(    const int n_head_log2,
)"
R"(    const float logit_softcap,
)"
R"(    const int n_head_kv,
)"
R"(    const global void* mask_void,
)"
R"(    const ulong mask_offset,
)"
R"(    const ulong mask_nb1,
)"
R"(    const ulong mask_nb2,
)"
R"(    const ulong mask_nb3,
)"
R"(    const int mask_ne2,
)"
R"(    const int mask_ne3,
)"
R"(    const global void* sinks_void,
)"
R"(    const ulong sinks_offset
)"
R"() {
)"
R"(    const int tid             = get_local_id(0);
)"
R"(    const int sgid            = tid / Q1_WG_SIZE;   // subgroup index (0..VEC_NSG-1)
)"
R"(    const int tid_sg          = tid % Q1_WG_SIZE;   // lane within subgroup
)"
R"(    const int head_batch_idx  = get_global_id(1);
)"
R"(
)"
R"(    const int batch_idx = head_batch_idx / n_head;
)"
R"(    const int head_idx  = head_batch_idx % n_head;
)"
R"(
)"
R"(    const int gqa_ratio   = n_head / n_head_kv;
)"
R"(    const int head_kv_idx = head_idx / gqa_ratio;
)"
R"(
)"
R"(    const global char * q_base = (const global char *) q_void + q_offset;
)"
R"(    const global char * k_base = (const global char *) k_void + k_offset;
)"
R"(    const global char * v_base = (const global char *) v_void + v_offset;
)"
R"(    global       char * o_base = (global       char *) o_void + o_offset;
)"
R"(
)"
R"(    const global char * mask_base = NULL;
)"
R"(    if (mask_void != NULL) {
)"
R"(        const int mask_head_idx  = head_idx  % mask_ne2;
)"
R"(        const int mask_batch_idx = batch_idx % mask_ne3;
)"
R"(        mask_base = (const global char *) mask_void + mask_offset +
)"
R"(                    mask_batch_idx * mask_nb3 + mask_head_idx * mask_nb2;
)"
R"(    }
)"
R"(
)"
R"(    // Q is uniform across the WG — stage in __local once. All WG threads load.
)"
R"(    __local ACC_TYPE4 q_shared[DK_VEC];
)"
R"(    {
)"
R"(        const ulong q_row_offset = batch_idx * q_nb3 + head_idx * q_nb2;
)"
R"(        const global Q_DATA_TYPE4 * q_ptr = (const global Q_DATA_TYPE4 *) (q_base + q_row_offset);
)"
R"(        for (int i = tid; i < DK_VEC; i += VEC_WG_SIZE) {
)"
R"(            q_shared[i] = CONVERT_Q_ACC4(q_ptr[i]);
)"
R"(        }
)"
R"(    }
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(    const float slope = get_alibi_slope(max_bias, head_idx, n_head_log2, m0, m1);
)"
R"(
)"
R"(    const global ACC_TYPE * sinks_ptr = NULL;
)"
R"(    if (sinks_void != NULL) {
)"
R"(        sinks_ptr = (const global ACC_TYPE *) ((const global char *) sinks_void + sinks_offset);
)"
R"(    }
)"
R"(
)"
R"(    // per-thread DV slice within its subgroup
)"
R"(    // DV=512 -> 2x float4 = 32 bytes; DV=256 -> 1x float4 - no spill
)"
R"(    ACC_TYPE4 o_acc[Q1V_DV_PER_THREAD];
)"
R"(    #pragma unroll
)"
R"(    for (int i = 0; i < Q1V_DV_PER_THREAD; ++i) o_acc[i] = (ACC_TYPE4)(0.0f);
)"
R"(
)"
R"(    // each subgroup independently runs the FA-2 online softmax over its slice of n_kv.
)"
R"(    // sinks are not folded into per-subgroup m_i — they're added once in
)"
R"(    // the cross-subgroup merge to avoid double-counting.
)"
R"(    ACC_TYPE m_i = FA_M_INIT;
)"
R"(    ACC_TYPE l_i = 0.0f;
)"
R"(
)"
R"(    const int kv_per_sg = (n_kv + VEC_NSG - 1) / VEC_NSG;
)"
R"(    const int kv_start  = sgid * kv_per_sg;
)"
R"(    const int kv_end    = min(n_kv, kv_start + kv_per_sg);
)"
R"(
)"
R"(    for (int k_idx = kv_start; k_idx < kv_end; ++k_idx) {
)"
R"(        const ulong k_row_off = batch_idx * k_nb3 + head_kv_idx * k_nb2 + k_idx * k_nb1;
)"
R"(        const ulong v_row_off = batch_idx * v_nb3 + head_kv_idx * v_nb2 + k_idx * v_nb1;
)"
R"(        const global KV_DATA_TYPE4 * k_ptr = (const global KV_DATA_TYPE4 *) (k_base + k_row_off);
)"
R"(        const global KV_DATA_TYPE4 * v_ptr = (const global KV_DATA_TYPE4 *) (v_base + v_row_off);
)"
R"(
)"
R"(        // Q*K^T: each thread accumulates its DK slice; subgroup-reduce the partial.
)"
R"(        ACC_TYPE4 dot4 = (ACC_TYPE4)(0.0f);
)"
R"(        for (int k = tid_sg; k < DK_VEC; k += Q1_WG_SIZE) {
)"
R"(            dot4 = mad(q_shared[k], CONVERT_KV_ACC4(k_ptr[k]), dot4);
)"
R"(        }
)"
R"(        ACC_TYPE dot_partial = dot4.s0 + dot4.s1 + dot4.s2 + dot4.s3;
)"
R"(        ACC_TYPE score = sub_group_reduce_add(dot_partial) * scale;
)"
R"(        if (logit_softcap > 0.0f) {
)"
R"(            score = logit_softcap * tanh(score / logit_softcap);
)"
R"(        }
)"
R"(
)"
R"(        if (mask_base != NULL) {
)"
R"(            const global MASK_DATA_TYPE * mask_ptr = (const global MASK_DATA_TYPE *) mask_base;
)"
R"(            score += slope * (ACC_TYPE) mask_ptr[k_idx];
)"
R"(        }
)"
R"(
)"
R"(        // FA-2 online update. All threads in the subgroup see the same score,
)"
R"(        // so m_i and l_i evolve identically across lanes within the subgroup.
)"
R"(        const ACC_TYPE m_new      = max(m_i, score);
)"
R"(        const ACC_TYPE scale_prev = native_exp(m_i - m_new);
)"
R"(        const ACC_TYPE p          = native_exp(score - m_new);
)"
R"(
)"
R"(        int idx = 0;
)"
R"(        for (int dv_idx = tid_sg; dv_idx < DV_VEC; dv_idx += Q1_WG_SIZE, ++idx) {
)"
R"(            o_acc[idx] = mad(p, CONVERT_KV_ACC4(v_ptr[dv_idx]), o_acc[idx] * scale_prev);
)"
R"(        }
)"
R"(        l_i = l_i * scale_prev + p;
)"
R"(        m_i = m_new;
)"
R"(    }
)"
R"(
)"
R"(    // Cross-subgroup merge via __local. Each subgroup publishes (m_i, l_i)
)"
R"(    // and its o_acc slice; subgroup 0 then folds them into the final norm
)"
R"(    // and writes the row.
)"
R"(    __local ACC_TYPE  sg_m[VEC_NSG];
)"
R"(    __local ACC_TYPE  sg_l[VEC_NSG];
)"
R"(    __local ACC_TYPE4 sg_o[VEC_NSG][DV_VEC];
)"
R"(
)"
R"(    if (tid_sg == 0) {
)"
R"(        sg_m[sgid] = m_i;
)"
R"(        sg_l[sgid] = l_i;
)"
R"(    }
)"
R"(    {
)"
R"(        int idx = 0;
)"
R"(        for (int dv_idx = tid_sg; dv_idx < DV_VEC; dv_idx += Q1_WG_SIZE, ++idx) {
)"
R"(            sg_o[sgid][dv_idx] = o_acc[idx];
)"
R"(        }
)"
R"(    }
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(    if (sgid == 0) {
)"
R"(        // m_final = max over all subgroups' m_i, plus the sink (if any).
)"
R"(        ACC_TYPE m_final = sg_m[0];
)"
R"(        #pragma unroll
)"
R"(        for (int s = 1; s < VEC_NSG; ++s) {
)"
R"(            m_final = max(m_final, sg_m[s]);
)"
R"(        }
)"
R"(        if (sinks_ptr != NULL) {
)"
R"(            m_final = max(m_final, sinks_ptr[head_idx]);
)"
R"(        }
)"
R"(
)"
R"(        ACC_TYPE l_final = 0.0f;
)"
R"(        #pragma unroll
)"
R"(        for (int s = 0; s < VEC_NSG; ++s) {
)"
R"(            l_final += sg_l[s] * native_exp(sg_m[s] - m_final);
)"
R"(        }
)"
R"(        if (sinks_ptr != NULL) {
)"
R"(            l_final += native_exp(sinks_ptr[head_idx] - m_final);
)"
R"(        }
)"
R"(        const ACC_TYPE l_inv = (l_final > 0.0f) ? (1.0f / l_final) : 0.0f;
)"
R"(
)"
R"(        const ulong o_row_offset = batch_idx * o_nb3 + head_idx * o_nb1;
)"
R"(        global O_DATA_TYPE4 * o_row = (global O_DATA_TYPE4 *) (o_base + o_row_offset);
)"
R"(
)"
R"(        // Each thread in subgroup 0 writes its DV slice, folding all subgroups'
)"
R"(        // contributions with the rescale factor.
)"
R"(        int idx = 0;
)"
R"(        for (int dv_idx = tid_sg; dv_idx < DV_VEC; dv_idx += Q1_WG_SIZE, ++idx) {
)"
R"(            ACC_TYPE4 o_merged = (ACC_TYPE4)(0.0f);
)"
R"(            #pragma unroll
)"
R"(            for (int s = 0; s < VEC_NSG; ++s) {
)"
R"(                const ACC_TYPE alpha = native_exp(sg_m[s] - m_final);
)"
R"(                o_merged = mad((ACC_TYPE4)(alpha), sg_o[s][dv_idx], o_merged);
)"
R"(            }
)"
R"(            o_row[dv_idx] = CONVERT_O_DATA4(o_merged * l_inv);
)"
R"(        }
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(#endif  // !FA_DECODE_MINIMAL
)"
R"(
)"
R"(#ifndef FA_DECODE_ONLY
)"
R"(
)"
R"(// flash_attn_f32_f16_q1_local_tile
)"
R"(// one WG per (q_idx, q_head)
)"
R"(
)"
R"(#define LT_KC 32
)"
R"(#define LT_WG 128
)"
R"(
)"
R"(#ifndef FA_MQ_ONLY  // q1_local_tile excluded from the MQ-only (g8) program
)"
R"(REQD_SUBGROUP_SIZE_64
)"
R"(__kernel void flash_attn_f32_f16_q1_local_tile(
)"
R"(    const global void * q_void, ulong q_offset,
)"
R"(    const global void * k_void, ulong k_offset,
)"
R"(    const global void * v_void, ulong v_offset,
)"
R"(    global void * o_void, ulong o_offset,
)"
R"(    const float scale,
)"
R"(    const int n_q,
)"
R"(    const int n_kv,
)"
R"(    const int is_causal,
)"
R"(    const int n_head,
)"
R"(    const ulong q_nb1, const ulong q_nb2, const ulong q_nb3,
)"
R"(    const ulong k_nb1, const ulong k_nb2, const ulong k_nb3,
)"
R"(    const ulong v_nb1, const ulong v_nb2, const ulong v_nb3,
)"
R"(    const ulong o_nb1, const ulong o_nb2, const ulong o_nb3,
)"
R"(    const float max_bias,
)"
R"(    const float m0,
)"
R"(    const float m1,
)"
R"(    const int n_head_log2,
)"
R"(    const float logit_softcap,
)"
R"(    const int n_head_kv,
)"
R"(    const global void * mask_void,
)"
R"(    const ulong mask_offset,
)"
R"(    const ulong mask_nb1,
)"
R"(    const ulong mask_nb2,
)"
R"(    const ulong mask_nb3,
)"
R"(    const int mask_ne2,
)"
R"(    const int mask_ne3,
)"
R"(    const global void * sinks_void,
)"
R"(    const ulong sinks_offset
)"
R"() {
)"
R"(    const int q_idx     = get_global_id(0) / LT_WG;
)"
R"(    const int head_idx  = get_global_id(1);
)"
R"(    const int batch_idx = get_global_id(2);
)"
R"(    const int tid       = get_local_id(0);
)"
R"(
)"
R"(    const int gqa_ratio   = n_head_kv > 0 ? (n_head / n_head_kv) : 1;
)"
R"(    const int head_kv_idx = head_idx / gqa_ratio;
)"
R"(
)"
R"(    const float slope = get_alibi_slope(max_bias, head_idx, n_head_log2, m0, m1);
)"
R"(
)"
R"(    __local half  k_tile[LT_KC * DK];   // 32*128*2 = 8 KB at DK=128
)"
R"(    __local half  v_tile[LT_KC * DV];   // 8 KB
)"
R"(    __local float red[LT_WG];           // 512 B reduction scratch
)"
R"(    __local float score_shared;         // broadcast score (each K-step)
)"
R"(
)"
R"(    // Each thread owns one float of Q at index `tid` (assumes LT_WG == DK).
)"
R"(    const global char * q_row_base = (const global char *) q_void + q_offset +
)"
R"(                                     batch_idx * q_nb3 + head_idx * q_nb2 + (ulong) q_idx * q_nb1;
)"
R"(    float q_val = ((const global float *) q_row_base)[tid];
)"
R"(
)"
R"(    const global char * mask_base = NULL;
)"
R"(    if (mask_void != NULL) {
)"
R"(        const int mask_head_idx  = head_idx  % mask_ne2;
)"
R"(        const int mask_batch_idx = batch_idx % mask_ne3;
)"
R"(        mask_base = (const global char *) mask_void + mask_offset +
)"
R"(                    mask_batch_idx * mask_nb3 + mask_head_idx * mask_nb2 +
)"
R"(                    (ulong) q_idx * mask_nb1;
)"
R"(    }
)"
R"(
)"
R"(    float o_val = 0.0f;
)"
R"(    float m_i = FA_M_INIT;
)"
R"(    float l_i = 0.0f;
)"
R"(
)"
R"(    for (int kb = 0; kb < n_kv; kb += LT_KC) {
)"
R"(        const int tile_len = min(LT_KC, n_kv - kb);
)"
R"(
)"
R"(        // Stage K and V tiles into __local.
)"
R"(        for (int i = tid; i < tile_len * DK; i += LT_WG) {
)"
R"(            const int j = i / DK;
)"
R"(            const int d = i % DK;
)"
R"(            const int kv_idx = kb + j;
)"
R"(            const global char * k_row = (const global char *) k_void + k_offset +
)"
R"(                                        batch_idx * k_nb3 + head_kv_idx * k_nb2 +
)"
R"(                                        (ulong) kv_idx * k_nb1;
)"
R"(            const global char * v_row = (const global char *) v_void + v_offset +
)"
R"(                                        batch_idx * v_nb3 + head_kv_idx * v_nb2 +
)"
R"(                                        (ulong) kv_idx * v_nb1;
)"
R"(            k_tile[j * DK + d] = ((const global half *) k_row)[d];
)"
R"(            v_tile[j * DV + d] = ((const global half *) v_row)[d];
)"
R"(        }
)"
R"(        barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(        for (int j = 0; j < tile_len; ++j) {
)"
R"(            const int kv_idx = kb + j;
)"
R"(
)"
R"(            // Q·K dot via __local tree-reduce.
)"
R"(            red[tid] = q_val * convert_float(k_tile[j * DK + tid]);
)"
R"(            barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(            for (int stride = LT_WG >> 1; stride > 0; stride >>= 1) {
)"
R"(                if (tid < stride) {
)"
R"(                    red[tid] += red[tid + stride];
)"
R"(                }
)"
R"(                barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(            }
)"
R"(
)"
R"(            if (tid == 0) {
)"
R"(                float s = red[0] * scale;
)"
R"(                if (logit_softcap > 0.0f) {
)"
R"(                    s = logit_softcap * tanh(s / logit_softcap);
)"
R"(                }
)"
R"(                if (mask_base != NULL) {
)"
R"(                    const global MASK_DATA_TYPE * mask_ptr = (const global MASK_DATA_TYPE *) mask_base;
)"
R"(                    s += slope * (float) mask_ptr[kv_idx];
)"
R"(                }
)"
R"(                score_shared = s;
)"
R"(            }
)"
R"(            barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(            const float s     = score_shared;
)"
R"(            const float m_new = fmax(m_i, s);
)"
R"(            const float alpha = native_exp(m_i - m_new);
)"
R"(            const float beta  = native_exp(s   - m_new);
)"
R"(
)"
R"(            o_val = o_val * alpha + beta * convert_float(v_tile[j * DV + tid]);
)"
R"(            l_i   = l_i   * alpha + beta;
)"
R"(            m_i   = m_new;
)"
R"(        }
)"
R"(        barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(    }
)"
R"(
)"
R"(    // Fold attention sinks into the running (m, l, o), if present.
)"
R"(    if (sinks_void != NULL) {
)"
R"(        const global float * sinks_ptr =
)"
R"(            (const global float *) ((const global char *) sinks_void + sinks_offset);
)"
R"(        const float m_sink = sinks_ptr[head_idx];
)"
R"(        const float m_new  = fmax(m_i, m_sink);
)"
R"(        const float alpha  = native_exp(m_i    - m_new);
)"
R"(        const float beta   = native_exp(m_sink - m_new);
)"
R"(        o_val = o_val * alpha;
)"
R"(        l_i   = l_i * alpha + beta;
)"
R"(        m_i   = m_new;
)"
R"(    }
)"
R"(
)"
R"(    const float l_inv = (l_i > 0.0f) ? (1.0f / l_i) : 0.0f;
)"
R"(    global float * o_row = (global float *) ((global char *) o_void + o_offset +
)"
R"(                                              batch_idx * o_nb3 + head_idx * o_nb1 +
)"
R"(                                              (ulong) q_idx * o_nb2);
)"
R"(    o_row[tid] = o_val * l_inv;
)"
R"(}
)"
R"(
)"
R"(// flash_attn_f32_f16_q1_local_mq_split
)"
R"(
)"
R"(#define LMQ_WG  64
)"
R"(#define LMQ_KC  32
)"
R"(#define LMQ_DPL 2   // DK / LMQ_WG at DK=128
)"
R"(
)"
R"(#endif  // !FA_MQ_ONLY (q1_local_tile)
)"
R"(#ifndef MQ_GQA
)"
R"(#define MQ_GQA 4
)"
R"(#endif
)"
R"(
)"
R"(#ifndef FA_PARTIAL_FLOATS
)"
R"(#define FA_PARTIAL_FLOATS (2 + DV)
)"
R"(#endif
)"
R"(
)"
R"(#ifndef FA_MQ_ONLY  // q1_local_mq_split excluded from the MQ-only (g8) program
)"
R"(REQD_SUBGROUP_SIZE_64
)"
R"(__kernel void flash_attn_f32_f16_q1_local_mq_split(
)"
R"(    const global void * q_void, ulong q_offset,
)"
R"(    const global void * k_void, ulong k_offset,
)"
R"(    const global void * v_void, ulong v_offset,
)"
R"(    const float scale,
)"
R"(    const int n_q,
)"
R"(    const int n_kv,
)"
R"(    const int n_head,
)"
R"(    const ulong q_nb1, const ulong q_nb2, const ulong q_nb3,
)"
R"(    const ulong k_nb1, const ulong k_nb2, const ulong k_nb3,
)"
R"(    const ulong v_nb1, const ulong v_nb2, const ulong v_nb3,
)"
R"(    const float max_bias,
)"
R"(    const float m0,
)"
R"(    const float m1,
)"
R"(    const int n_head_log2,
)"
R"(    const float logit_softcap,
)"
R"(    const int n_head_kv,
)"
R"(    const global void * mask_void,
)"
R"(    const ulong mask_offset,
)"
R"(    const ulong mask_nb1,
)"
R"(    const ulong mask_nb2,
)"
R"(    const ulong mask_nb3,
)"
R"(    const int mask_ne2,
)"
R"(    const int mask_ne3,
)"
R"(    global float * partial_void,
)"
R"(    const int n_splits,
)"
R"(    const int kv_per_split
)"
R"() {
)"
R"(    const int tid              = get_local_id(0);  // 0..LMQ_WG-1
)"
R"(    const int kvhead_batch_idx = get_global_id(1);
)"
R"(    const int split_q_idx      = get_global_id(2);
)"
R"(    const int split_idx        = split_q_idx % n_splits;
)"
R"(    const int q_idx            = split_q_idx / n_splits;
)"
R"(
)"
R"(    const int batch_idx   = kvhead_batch_idx / n_head_kv;
)"
R"(    const int head_kv_idx = kvhead_batch_idx % n_head_kv;
)"
R"(
)"
R"(    const int kv_start = split_idx * kv_per_split;
)"
R"(    const int kv_end   = min(kv_start + kv_per_split, n_kv);
)"
R"(
)"
R"(    const ulong record_stride = (ulong) FA_PARTIAL_FLOATS;
)"
R"(
)"
R"(    if (kv_start >= kv_end) {
)"
R"(        // Empty split — write sentinel for each Q-head so merge treats it as 0.
)"
R"(        if (tid == 0) {
)"
R"(            #pragma unroll
)"
R"(            for (int h = 0; h < MQ_GQA; ++h) {
)"
R"(                const int head_idx = head_kv_idx * MQ_GQA + h;
)"
R"(                const ulong rec_idx = ((((ulong) batch_idx * n_head + head_idx) * n_q + q_idx)
)"
R"(                                       * n_splits + split_idx);
)"
R"(                global float * rec = partial_void + rec_idx * record_stride;
)"
R"(                rec[0] = FA_M_INIT;
)"
R"(                rec[1] = 0.0f;
)"
R"(            }
)"
R"(        }
)"
R"(        return;
)"
R"(    }
)"
R"(
)"
R"(    const global char * q_base = (const global char *) q_void + q_offset;
)"
R"(    const global char * k_base = (const global char *) k_void + k_offset;
)"
R"(    const global char * v_base = (const global char *) v_void + v_offset;
)"
R"(
)"
R"(    // Stage MQ_GQA Q rows in __local (MQ_GQA × DK floats).
)"
R"(    __local float q_shared[MQ_GQA * DK];
)"
R"(    for (int i = tid; i < MQ_GQA * DK; i += LMQ_WG) {
)"
R"(        const int h        = i / DK;
)"
R"(        const int d        = i % DK;
)"
R"(        const int head_idx = head_kv_idx * MQ_GQA + h;
)"
R"(        const ulong q_row_off = batch_idx * q_nb3 + head_idx * q_nb2 + (ulong) q_idx * q_nb1;
)"
R"(        const global float * q_ptr = (const global float *) (q_base + q_row_off);
)"
R"(        q_shared[h * DK + d] = q_ptr[d];
)"
R"(    }
)"
R"(
)"
R"(    // K/V tile staging buffers (16 KB combined at DK=DV=128 KC=32).
)"
R"(    __local half k_tile[LMQ_KC * DK];
)"
R"(    __local half v_tile[LMQ_KC * DV];
)"
R"(
)"
R"(    // Per-h state held in private registers.
)"
R"(    float o_acc[MQ_GQA][LMQ_DPL];
)"
R"(    float m_i[MQ_GQA];
)"
R"(    float l_i[MQ_GQA];
)"
R"(    float slope[MQ_GQA];
)"
R"(    #pragma unroll
)"
R"(    for (int h = 0; h < MQ_GQA; ++h) {
)"
R"(        m_i[h] = FA_M_INIT;
)"
R"(        l_i[h] = 0.0f;
)"
R"(        slope[h] = get_alibi_slope(max_bias, head_kv_idx * MQ_GQA + h, n_head_log2, m0, m1);
)"
R"(        #pragma unroll
)"
R"(        for (int p = 0; p < LMQ_DPL; ++p) o_acc[h][p] = 0.0f;
)"
R"(    }
)"
R"(
)"
R"(    // Per-h mask pointers.
)"
R"(    const global char * mask_base[MQ_GQA];
)"
R"(    if (mask_void != NULL) {
)"
R"(        const int mask_batch_idx = batch_idx % mask_ne3;
)"
R"(        const global char * mask_base_b = (const global char *) mask_void + mask_offset +
)"
R"(                                          mask_batch_idx * mask_nb3 +
)"
R"(                                          (ulong) q_idx * mask_nb1;
)"
R"(        #pragma unroll
)"
R"(        for (int h = 0; h < MQ_GQA; ++h) {
)"
R"(            const int head_idx      = head_kv_idx * MQ_GQA + h;
)"
R"(            const int mask_head_idx = head_idx % mask_ne2;
)"
R"(            mask_base[h] = mask_base_b + mask_head_idx * mask_nb2;
)"
R"(        }
)"
R"(    } else {
)"
R"(        #pragma unroll
)"
R"(        for (int h = 0; h < MQ_GQA; ++h) mask_base[h] = NULL;
)"
R"(    }
)"
R"(
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);  // Ensure Q staged before first dot.
)"
R"(
)"
R"(    for (int kb = kv_start; kb < kv_end; kb += LMQ_KC) {
)"
R"(        const int tile_len = min((int) LMQ_KC, kv_end - kb);
)"
R"(
)"
R"(        // Cooperative load K + V tile.
)"
R"(        for (int i = tid; i < tile_len * DK; i += LMQ_WG) {
)"
R"(            const int j = i / DK;
)"
R"(            const int d = i % DK;
)"
R"(            const int kv_idx = kb + j;
)"
R"(            const global char * k_row = k_base + batch_idx * k_nb3 + head_kv_idx * k_nb2 + (ulong) kv_idx * k_nb1;
)"
R"(            const global char * v_row = v_base + batch_idx * v_nb3 + head_kv_idx * v_nb2 + (ulong) kv_idx * v_nb1;
)"
R"(            k_tile[j * DK + d] = ((const global half *) k_row)[d];
)"
R"(            v_tile[j * DV + d] = ((const global half *) v_row)[d];
)"
R"(        }
)"
R"(        barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(        // Process each cache row in the tile.
)"
R"(        for (int j = 0; j < tile_len; ++j) {
)"
R"(            const int kv_idx = kb + j;
)"
R"(
)"
R"(            // Dot product per h: lane owns LMQ_DPL D-elements at (tid*LMQ_DPL..).
)"
R"(            float score[MQ_GQA];
)"
R"(            #pragma unroll
)"
R"(            for (int h = 0; h < MQ_GQA; ++h) {
)"
R"(                float contrib = 0.0f;
)"
R"(                #pragma unroll
)"
R"(                for (int p = 0; p < LMQ_DPL; ++p) {
)"
R"(                    const int d = tid * LMQ_DPL + p;
)"
R"(                    contrib += q_shared[h * DK + d] * (float) k_tile[j * DK + d];
)"
R"(                }
)"
R"(                float s = sub_group_reduce_add(contrib) * scale;
)"
R"(                if (logit_softcap > 0.0f) {
)"
R"(                    s = logit_softcap * tanh(s / logit_softcap);
)"
R"(                }
)"
R"(                if (mask_base[h] != NULL) {
)"
R"(                    const global MASK_DATA_TYPE * mask_ptr = (const global MASK_DATA_TYPE *) mask_base[h];
)"
R"(                    s += slope[h] * (float) mask_ptr[kv_idx];
)"
R"(                }
)"
R"(                score[h] = s;
)"
R"(            }
)"
R"(
)"
R"(            // Online softmax update + V accumulation per h.
)"
R"(            float p_h[MQ_GQA];
)"
R"(            float sp_h[MQ_GQA];
)"
R"(            #pragma unroll
)"
R"(            for (int h = 0; h < MQ_GQA; ++h) {
)"
R"(                const float m_new = fmax(m_i[h], score[h]);
)"
R"(                sp_h[h] = native_exp(m_i[h] - m_new);
)"
R"(                p_h[h]  = native_exp(score[h] - m_new);
)"
R"(                l_i[h]  = l_i[h] * sp_h[h] + p_h[h];
)"
R"(                m_i[h]  = m_new;
)"
R"(            }
)"
R"(
)"
R"(            #pragma unroll
)"
R"(            for (int p = 0; p < LMQ_DPL; ++p) {
)"
R"(                const int d = tid * LMQ_DPL + p;
)"
R"(                const float v_val = (float) v_tile[j * DV + d];
)"
R"(                #pragma unroll
)"
R"(                for (int h = 0; h < MQ_GQA; ++h) {
)"
R"(                    o_acc[h][p] = o_acc[h][p] * sp_h[h] + p_h[h] * v_val;
)"
R"(                }
)"
R"(            }
)"
R"(        }
)"
R"(        barrier(CLK_LOCAL_MEM_FENCE);  // Before next tile load overwrites k/v_tile.
)"
R"(    }
)"
R"(
)"
R"(    // write partial records: one per (h, split)
)"
R"(    #pragma unroll
)"
R"(    for (int h = 0; h < MQ_GQA; ++h) {
)"
R"(        const int head_idx = head_kv_idx * MQ_GQA + h;
)"
R"(        const ulong rec_idx = ((((ulong) batch_idx * n_head + head_idx) * n_q + q_idx)
)"
R"(                               * n_splits + split_idx);
)"
R"(        global float * rec   = partial_void + rec_idx * record_stride;
)"
R"(        global float * rec_o = rec + 2;
)"
R"(
)"
R"(        if (tid == 0) {
)"
R"(            rec[0] = m_i[h];
)"
R"(            rec[1] = l_i[h];
)"
R"(        }
)"
R"(        #pragma unroll
)"
R"(        for (int p = 0; p < LMQ_DPL; ++p) {
)"
R"(            const int d = tid * LMQ_DPL + p;
)"
R"(            rec_o[d] = o_acc[h][p];
)"
R"(        }
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(#endif  // !FA_MQ_ONLY (q1_local_mq_split)
)"
R"(#ifndef MQ_NSG
)"
R"(#define MQ_NSG 4
)"
R"(#endif
)"
R"(#define MQ_WG_SIZE (Q1_WG_SIZE * MQ_NSG)
)"
R"(
)"
R"(#ifndef FA_MQ_SPLIT_ONLY
)"
R"(REQD_SUBGROUP_SIZE_64
)"
R"(__kernel void flash_attn_f32_f16_q1_vec_mq(
)"
R"(    const global void * q_void, ulong q_offset,
)"
R"(    const global void * k_void, ulong k_offset,
)"
R"(    const global void * v_void, ulong v_offset,
)"
R"(    global void * o_void, ulong o_offset,
)"
R"(    const float scale,
)"
R"(    const int n_q,
)"
R"(    const int n_kv,
)"
R"(    const int is_causal,
)"
R"(    const int n_head,
)"
R"(    const ulong q_nb1, const ulong q_nb2, const ulong q_nb3,
)"
R"(    const ulong k_nb1, const ulong k_nb2, const ulong k_nb3,
)"
R"(    const ulong v_nb1, const ulong v_nb2, const ulong v_nb3,
)"
R"(    const ulong o_nb1, const ulong o_nb2, const ulong o_nb3,
)"
R"(    const float max_bias,
)"
R"(    const float m0,
)"
R"(    const float m1,
)"
R"(    const int n_head_log2,
)"
R"(    const float logit_softcap,
)"
R"(    const int n_head_kv,
)"
R"(    const global void* mask_void,
)"
R"(    const ulong mask_offset,
)"
R"(    const ulong mask_nb1,
)"
R"(    const ulong mask_nb2,
)"
R"(    const ulong mask_nb3,
)"
R"(    const int mask_ne2,
)"
R"(    const int mask_ne3,
)"
R"(    const global void* sinks_void,
)"
R"(    const ulong sinks_offset
)"
R"() {
)"
R"(    const int tid              = get_local_id(0);
)"
R"(    const int sgid             = tid / Q1_WG_SIZE;   // subgroup 0..MQ_NSG-1
)"
R"(    const int tid_sg           = tid % Q1_WG_SIZE;   // lane 0..63
)"
R"(    const int kvhead_batch_idx = get_global_id(1);
)"
R"(
)"
R"(    const int batch_idx   = kvhead_batch_idx / n_head_kv;
)"
R"(    const int head_kv_idx = kvhead_batch_idx % n_head_kv;
)"
R"(
)"
R"(    const global char * q_base = (const global char *) q_void + q_offset;
)"
R"(    const global char * k_base = (const global char *) k_void + k_offset;
)"
R"(    const global char * v_base = (const global char *) v_void + v_offset;
)"
R"(    global       char * o_base = (global       char *) o_void + o_offset;
)"
R"(
)"
R"(    __local ACC_TYPE4 q_shared[MQ_GQA * DK_VEC];
)"
R"(    for (int i = tid; i < MQ_GQA * DK_VEC; i += MQ_WG_SIZE) {
)"
R"(        const int h        = i / DK_VEC;
)"
R"(        const int k        = i % DK_VEC;
)"
R"(        const int head_idx = head_kv_idx * MQ_GQA + h;
)"
R"(        const ulong q_row_offset = batch_idx * q_nb3 + head_idx * q_nb2;
)"
R"(        const global Q_DATA_TYPE4 * q_ptr = (const global Q_DATA_TYPE4 *) (q_base + q_row_offset);
)"
R"(        q_shared[h * DK_VEC + k] = CONVERT_Q_ACC4(q_ptr[k]);
)"
R"(    }
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(    // per-h ALiBi slope
)"
R"(    float slope[MQ_GQA];
)"
R"(    #pragma unroll
)"
R"(    for (int h = 0; h < MQ_GQA; ++h) {
)"
R"(        slope[h] = get_alibi_slope(max_bias, head_kv_idx * MQ_GQA + h, n_head_log2, m0, m1);
)"
R"(    }
)"
R"(
)"
R"(    // per-h mask row pointer
)"
R"(    const global char * mask_base[MQ_GQA];
)"
R"(    if (mask_void != NULL) {
)"
R"(        const int mask_batch_idx = batch_idx % mask_ne3;
)"
R"(        const global char * mask_base_b = (const global char *) mask_void + mask_offset +
)"
R"(                                          mask_batch_idx * mask_nb3;
)"
R"(        #pragma unroll
)"
R"(        for (int h = 0; h < MQ_GQA; ++h) {
)"
R"(            const int head_idx      = head_kv_idx * MQ_GQA + h;
)"
R"(            const int mask_head_idx = head_idx % mask_ne2;
)"
R"(            mask_base[h] = mask_base_b + mask_head_idx * mask_nb2;
)"
R"(        }
)"
R"(    } else {
)"
R"(        #pragma unroll
)"
R"(        for (int h = 0; h < MQ_GQA; ++h) mask_base[h] = NULL;
)"
R"(    }
)"
R"(
)"
R"(    const global ACC_TYPE * sinks_ptr = NULL;
)"
R"(    if (sinks_void != NULL) {
)"
R"(        sinks_ptr = (const global ACC_TYPE *) ((const global char *) sinks_void + sinks_offset);
)"
R"(    }
)"
R"(
)"
R"(    // per-thread per-h DV slice.
)"
R"(    ACC_TYPE4 o_acc[MQ_GQA][Q1V_DV_PER_THREAD];
)"
R"(    ACC_TYPE  m_i[MQ_GQA];
)"
R"(    ACC_TYPE  l_i[MQ_GQA];
)"
R"(    #pragma unroll
)"
R"(    for (int h = 0; h < MQ_GQA; ++h) {
)"
R"(        m_i[h] = FA_M_INIT;
)"
R"(        l_i[h] = 0.0f;
)"
R"(        #pragma unroll
)"
R"(        for (int i = 0; i < Q1V_DV_PER_THREAD; ++i) o_acc[h][i] = (ACC_TYPE4)(0.0f);
)"
R"(    }
)"
R"(
)"
R"(    // each subgroup independently sweeps its slice of n_kv.
)"
R"(    const int kv_per_sg = (n_kv + MQ_NSG - 1) / MQ_NSG;
)"
R"(    const int kv_start  = sgid * kv_per_sg;
)"
R"(    const int kv_end    = min(n_kv, kv_start + kv_per_sg);
)"
R"(
)"
R"(    for (int k_idx = kv_start; k_idx < kv_end; ++k_idx) {
)"
R"(        const ulong k_row_off = batch_idx * k_nb3 + head_kv_idx * k_nb2 + k_idx * k_nb1;
)"
R"(        const ulong v_row_off = batch_idx * v_nb3 + head_kv_idx * v_nb2 + k_idx * v_nb1;
)"
R"(        const global KV_DATA_TYPE4 * k_ptr = (const global KV_DATA_TYPE4 *) (k_base + k_row_off);
)"
R"(        const global KV_DATA_TYPE4 * v_ptr = (const global KV_DATA_TYPE4 *) (v_base + v_row_off);
)"
R"(
)"
R"(        // Q*K^T: load each K stride once, dot against all MQ_GQA Q rows.
)"
R"(        ACC_TYPE4 dot4[MQ_GQA];
)"
R"(        #pragma unroll
)"
R"(        for (int h = 0; h < MQ_GQA; ++h) dot4[h] = (ACC_TYPE4)(0.0f);
)"
R"(        for (int k = tid_sg; k < DK_VEC; k += Q1_WG_SIZE) {
)"
R"(            const ACC_TYPE4 k_vec = CONVERT_KV_ACC4(k_ptr[k]);
)"
R"(            #pragma unroll
)"
R"(            for (int h = 0; h < MQ_GQA; ++h) {
)"
R"(                dot4[h] = mad(q_shared[h * DK_VEC + k], k_vec, dot4[h]);
)"
R"(            }
)"
R"(        }
)"
R"(
)"
R"(        ACC_TYPE score[MQ_GQA];
)"
R"(        #pragma unroll
)"
R"(        for (int h = 0; h < MQ_GQA; ++h) {
)"
R"(            const ACC_TYPE dot_partial = dot4[h].s0 + dot4[h].s1 + dot4[h].s2 + dot4[h].s3;
)"
R"(            ACC_TYPE s = sub_group_reduce_add(dot_partial) * scale;
)"
R"(            if (logit_softcap > 0.0f) {
)"
R"(                s = logit_softcap * tanh(s / logit_softcap);
)"
R"(            }
)"
R"(            if (mask_base[h] != NULL) {
)"
R"(                const global MASK_DATA_TYPE * mask_ptr = (const global MASK_DATA_TYPE *) mask_base[h];
)"
R"(                s += slope[h] * (ACC_TYPE) mask_ptr[k_idx];
)"
R"(            }
)"
R"(            score[h] = s;
)"
R"(        }
)"
R"(
)"
R"(        // FA-2 online softmax update — V load amortized across MQ_GQA heads.
)"
R"(        // p, scale_prev are computed per h; the V vector is loaded once
)"
R"(        // per dv stride and reused MQ_GQA times.
)"
R"(        ACC_TYPE p_h[MQ_GQA];
)"
R"(        ACC_TYPE sp_h[MQ_GQA];
)"
R"(        #pragma unroll
)"
R"(        for (int h = 0; h < MQ_GQA; ++h) {
)"
R"(            const ACC_TYPE m_new = max(m_i[h], score[h]);
)"
R"(            sp_h[h] = native_exp(m_i[h] - m_new);
)"
R"(            p_h[h]  = native_exp(score[h] - m_new);
)"
R"(            l_i[h]  = l_i[h] * sp_h[h] + p_h[h];
)"
R"(            m_i[h]  = m_new;
)"
R"(        }
)"
R"(
)"
R"(        int idx = 0;
)"
R"(        for (int dv_idx = tid_sg; dv_idx < DV_VEC; dv_idx += Q1_WG_SIZE, ++idx) {
)"
R"(            const ACC_TYPE4 v_vec = CONVERT_KV_ACC4(v_ptr[dv_idx]);
)"
R"(            #pragma unroll
)"
R"(            for (int h = 0; h < MQ_GQA; ++h) {
)"
R"(                o_acc[h][idx] = mad(p_h[h], v_vec, o_acc[h][idx] * sp_h[h]);
)"
R"(            }
)"
R"(        }
)"
R"(    }
)"
R"(
)"
R"(    // cross subgroup merge
)"
R"(    __local ACC_TYPE  sg_m[MQ_GQA][MQ_NSG];
)"
R"(    __local ACC_TYPE  sg_l[MQ_GQA][MQ_NSG];
)"
R"(    __local ACC_TYPE4 sg_o[MQ_NSG][DV_VEC];
)"
R"(
)"
R"(    if (tid_sg == 0) {
)"
R"(        #pragma unroll
)"
R"(        for (int h = 0; h < MQ_GQA; ++h) {
)"
R"(            sg_m[h][sgid] = m_i[h];
)"
R"(            sg_l[h][sgid] = l_i[h];
)"
R"(        }
)"
R"(    }
)"
R"(
)"
R"(    #pragma unroll
)"
R"(    for (int h = 0; h < MQ_GQA; ++h) {
)"
R"(        // each subgroup publishes its o_acc slice for head h.
)"
R"(        {
)"
R"(            int idx = 0;
)"
R"(            for (int dv_idx = tid_sg; dv_idx < DV_VEC; dv_idx += Q1_WG_SIZE, ++idx) {
)"
R"(                sg_o[sgid][dv_idx] = o_acc[h][idx];
)"
R"(            }
)"
R"(        }
)"
R"(        barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(        if (sgid == 0) {
)"
R"(            const int head_idx = head_kv_idx * MQ_GQA + h;
)"
R"(
)"
R"(            ACC_TYPE m_final = sg_m[h][0];
)"
R"(            #pragma unroll
)"
R"(            for (int s = 1; s < MQ_NSG; ++s) {
)"
R"(                m_final = max(m_final, sg_m[h][s]);
)"
R"(            }
)"
R"(            if (sinks_ptr != NULL) {
)"
R"(                m_final = max(m_final, sinks_ptr[head_idx]);
)"
R"(            }
)"
R"(
)"
R"(            ACC_TYPE l_final = 0.0f;
)"
R"(            #pragma unroll
)"
R"(            for (int s = 0; s < MQ_NSG; ++s) {
)"
R"(                l_final += sg_l[h][s] * native_exp(sg_m[h][s] - m_final);
)"
R"(            }
)"
R"(            if (sinks_ptr != NULL) {
)"
R"(                l_final += native_exp(sinks_ptr[head_idx] - m_final);
)"
R"(            }
)"
R"(            const ACC_TYPE l_inv = (l_final > 0.0f) ? (1.0f / l_final) : 0.0f;
)"
R"(
)"
R"(            const ulong o_row_offset = batch_idx * o_nb3 + head_idx * o_nb1;
)"
R"(            global O_DATA_TYPE4 * o_row = (global O_DATA_TYPE4 *) (o_base + o_row_offset);
)"
R"(            for (int dv_idx = tid_sg; dv_idx < DV_VEC; dv_idx += Q1_WG_SIZE) {
)"
R"(                ACC_TYPE4 o_merged = (ACC_TYPE4)(0.0f);
)"
R"(                #pragma unroll
)"
R"(                for (int s = 0; s < MQ_NSG; ++s) {
)"
R"(                    const ACC_TYPE alpha = native_exp(sg_m[h][s] - m_final);
)"
R"(                    o_merged = mad((ACC_TYPE4)(alpha), sg_o[s][dv_idx], o_merged);
)"
R"(                }
)"
R"(                o_row[dv_idx] = CONVERT_O_DATA4(o_merged * l_inv);
)"
R"(            }
)"
R"(        }
)"
R"(        // Barrier guards next h's overwrite of sg_o.
)"
R"(        barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(#endif  // !FA_MQ_SPLIT_ONLY
)"
R"(
)"
R"(#ifndef MQ_NSG_SPLIT
)"
R"(#define MQ_NSG_SPLIT 4
)"
R"(#endif
)"
R"(#define MQ_SPLIT_WG_SIZE (Q1_WG_SIZE * MQ_NSG_SPLIT)
)"
R"(
)"
R"(#ifndef FA_PARTIAL_FLOATS
)"
R"(#define FA_PARTIAL_FLOATS (2 + DV)
)"
R"(#endif
)"
R"(
)"
R"(#ifndef FA_HEAD_SUB
)"
R"(#define FA_HEAD_SUB 1
)"
R"(#endif
)"
R"(
)"
R"(REQD_SUBGROUP_SIZE_64
)"
R"(__kernel void flash_attn_f32_f16_q1_vec_mq_split(
)"
R"(    const global void * q_void, ulong q_offset,
)"
R"(    const global void * k_void, ulong k_offset,
)"
R"(    const global void * v_void, ulong v_offset,
)"
R"(    const float scale,
)"
R"(    const int n_q,
)"
R"(    const int n_kv,
)"
R"(    const int n_head,
)"
R"(    const ulong q_nb1, const ulong q_nb2, const ulong q_nb3,
)"
R"(    const ulong k_nb1, const ulong k_nb2, const ulong k_nb3,
)"
R"(    const ulong v_nb1, const ulong v_nb2, const ulong v_nb3,
)"
R"(    const float max_bias,
)"
R"(    const float m0,
)"
R"(    const float m1,
)"
R"(    const int n_head_log2,
)"
R"(    const float logit_softcap,
)"
R"(    const int n_head_kv,
)"
R"(    const global void * mask_void,
)"
R"(    const ulong mask_offset,
)"
R"(    const ulong mask_nb1,
)"
R"(    const ulong mask_nb2,
)"
R"(    const ulong mask_nb3,
)"
R"(    const int mask_ne2,
)"
R"(    const int mask_ne3,
)"
R"(    global float * partial_void,
)"
R"(    const int n_splits,
)"
R"(    const int kv_per_split
)"
R"() {
)"
R"(    const int tid              = get_local_id(0);
)"
R"(    const int sgid             = tid / Q1_WG_SIZE;
)"
R"(    const int tid_sg           = tid % Q1_WG_SIZE;
)"
R"(    const int kvhead_batch_idx = get_global_id(1);
)"
R"(    const int split_q_idx      = get_global_id(2);
)"
R"(    const int split_idx        = split_q_idx % n_splits;
)"
R"(    const int q_idx            = split_q_idx / n_splits;
)"
R"(
)"
R"(    const int hgroups     = n_head_kv * FA_HEAD_SUB;
)"
R"(    const int batch_idx   = kvhead_batch_idx / hgroups;
)"
R"(    const int hg          = kvhead_batch_idx % hgroups;
)"
R"(    const int head_kv_idx = hg / FA_HEAD_SUB;
)"
R"(    const int head_sub    = hg % FA_HEAD_SUB;
)"
R"(#define FA_MQS_HEAD_IDX(h) (head_kv_idx * (MQ_GQA * FA_HEAD_SUB) + head_sub * MQ_GQA + (h))
)"
R"(
)"
R"(    const int kv_start = split_idx * kv_per_split;
)"
R"(    const int kv_end   = min(kv_start + kv_per_split, n_kv);
)"
R"(
)"
R"(    const ulong record_stride = (ulong) FA_PARTIAL_FLOATS;
)"
R"(
)"
R"(    if (kv_start >= kv_end) {
)"
R"(        // write sentinel for each of the MQ_GQA Q-heads so the
)"
R"(        // merge pass treats this slot as dropped
)"
R"(        if (tid == 0) {
)"
R"(            #pragma unroll
)"
R"(            for (int h = 0; h < MQ_GQA; ++h) {
)"
R"(                const int head_idx = FA_MQS_HEAD_IDX(h);
)"
R"(                const ulong rec_idx = ((((ulong) batch_idx * n_head + head_idx) * n_q + q_idx)
)"
R"(                                       * n_splits + split_idx);
)"
R"(                global float * rec = partial_void + rec_idx * record_stride;
)"
R"(                rec[0] = FA_M_INIT;
)"
R"(                rec[1] = 0.0f;
)"
R"(            }
)"
R"(        }
)"
R"(        return;
)"
R"(    }
)"
R"(
)"
R"(    const global char * q_base = (const global char *) q_void + q_offset;
)"
R"(    const global char * k_base = (const global char *) k_void + k_offset;
)"
R"(    const global char * v_base = (const global char *) v_void + v_offset;
)"
R"(
)"
R"(#ifdef FA_Q1_Q_REG
)"
R"(    ACC_TYPE4 q_reg[MQ_GQA];
)"
R"(    #pragma unroll
)"
R"(    for (int h = 0; h < MQ_GQA; ++h) {
)"
R"(        const int head_idx = FA_MQS_HEAD_IDX(h);
)"
R"(        const ulong q_row_offset = batch_idx * q_nb3 + head_idx * q_nb2 + (ulong) q_idx * q_nb1;
)"
R"(        const global Q_DATA_TYPE4 * q_ptr = (const global Q_DATA_TYPE4 *) (q_base + q_row_offset);
)"
R"(        q_reg[h] = (tid_sg < DK_VEC) ? CONVERT_Q_ACC4(q_ptr[tid_sg]) : (ACC_TYPE4)(0.0f);
)"
R"(    }
)"
R"(#else
)"
R"(    // stage MQ_GQA Q rows in __local once (uniform across WG)
)"
R"(    __local ACC_TYPE4 q_shared[MQ_GQA * DK_VEC];
)"
R"(    for (int i = tid; i < MQ_GQA * DK_VEC; i += MQ_SPLIT_WG_SIZE) {
)"
R"(        const int h        = i / DK_VEC;
)"
R"(        const int k        = i % DK_VEC;
)"
R"(        const int head_idx = FA_MQS_HEAD_IDX(h);
)"
R"(        const ulong q_row_offset = batch_idx * q_nb3 + head_idx * q_nb2 + (ulong) q_idx * q_nb1;
)"
R"(        const global Q_DATA_TYPE4 * q_ptr = (const global Q_DATA_TYPE4 *) (q_base + q_row_offset);
)"
R"(        q_shared[h * DK_VEC + k] = CONVERT_Q_ACC4(q_ptr[k]);
)"
R"(    }
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(#endif
)"
R"(
)"
R"(    float slope[MQ_GQA];
)"
R"(    #pragma unroll
)"
R"(    for (int h = 0; h < MQ_GQA; ++h) {
)"
R"(        slope[h] = get_alibi_slope(max_bias, FA_MQS_HEAD_IDX(h), n_head_log2, m0, m1);
)"
R"(    }
)"
R"(
)"
R"(    const global char * mask_base[MQ_GQA];
)"
R"(    if (mask_void != NULL) {
)"
R"(        const int mask_batch_idx = batch_idx % mask_ne3;
)"
R"(        const global char * mask_base_b = (const global char *) mask_void + mask_offset +
)"
R"(                                          mask_batch_idx * mask_nb3 +
)"
R"(                                          (ulong) q_idx * mask_nb1;
)"
R"(        #pragma unroll
)"
R"(        for (int h = 0; h < MQ_GQA; ++h) {
)"
R"(            const int head_idx      = FA_MQS_HEAD_IDX(h);
)"
R"(            const int mask_head_idx = head_idx % mask_ne2;
)"
R"(            mask_base[h] = mask_base_b + mask_head_idx * mask_nb2;
)"
R"(        }
)"
R"(    } else {
)"
R"(        #pragma unroll
)"
R"(        for (int h = 0; h < MQ_GQA; ++h) mask_base[h] = NULL;
)"
R"(    }
)"
R"(
)"
R"(    ACC_TYPE4 o_acc[MQ_GQA][Q1V_DV_PER_THREAD];
)"
R"(    ACC_TYPE  m_i[MQ_GQA];
)"
R"(    ACC_TYPE  l_i[MQ_GQA];
)"
R"(    #pragma unroll
)"
R"(    for (int h = 0; h < MQ_GQA; ++h) {
)"
R"(        m_i[h] = FA_M_INIT;
)"
R"(        l_i[h] = 0.0f;
)"
R"(        #pragma unroll
)"
R"(        for (int i = 0; i < Q1V_DV_PER_THREAD; ++i) o_acc[h][i] = (ACC_TYPE4)(0.0f);
)"
R"(    }
)"
R"(
)"
R"(    // each subgroup independently sweeps its slice of the split's kv range.
)"
R"(    const int kv_len   = kv_end - kv_start;
)"
R"(    const int kv_per_sg = (kv_len + MQ_NSG_SPLIT - 1) / MQ_NSG_SPLIT;
)"
R"(    const int kv_lo    = kv_start + sgid * kv_per_sg;
)"
R"(    const int kv_hi    = min(kv_end, kv_lo + kv_per_sg);
)"
R"(
)"
R"(    for (int k_idx = kv_lo; k_idx < kv_hi; ++k_idx) {
)"
R"(        const ulong k_row_off = batch_idx * k_nb3 + head_kv_idx * k_nb2 + k_idx * k_nb1;
)"
R"(        const ulong v_row_off = batch_idx * v_nb3 + head_kv_idx * v_nb2 + k_idx * v_nb1;
)"
R"(        const global KV_DATA_TYPE4 * k_ptr = (const global KV_DATA_TYPE4 *) (k_base + k_row_off);
)"
R"(        const global KV_DATA_TYPE4 * v_ptr = (const global KV_DATA_TYPE4 *) (v_base + v_row_off);
)"
R"(
)"
R"(        ACC_TYPE4 dot4[MQ_GQA];
)"
R"(        #pragma unroll
)"
R"(        for (int h = 0; h < MQ_GQA; ++h) dot4[h] = (ACC_TYPE4)(0.0f);
)"
R"(#ifdef FA_Q1_Q_REG
)"
R"(        if (tid_sg < DK_VEC) {
)"
R"(            const ACC_TYPE4 k_vec = CONVERT_KV_ACC4(k_ptr[tid_sg]);
)"
R"(            #pragma unroll
)"
R"(            for (int h = 0; h < MQ_GQA; ++h) {
)"
R"(                dot4[h] = mad(q_reg[h], k_vec, dot4[h]);
)"
R"(            }
)"
R"(        }
)"
R"(#else
)"
R"(        for (int k = tid_sg; k < DK_VEC; k += Q1_WG_SIZE) {
)"
R"(            const ACC_TYPE4 k_vec = CONVERT_KV_ACC4(k_ptr[k]);
)"
R"(            #pragma unroll
)"
R"(            for (int h = 0; h < MQ_GQA; ++h) {
)"
R"(                dot4[h] = mad(q_shared[h * DK_VEC + k], k_vec, dot4[h]);
)"
R"(            }
)"
R"(        }
)"
R"(#endif
)"
R"(
)"
R"(        ACC_TYPE score[MQ_GQA];
)"
R"(        #pragma unroll
)"
R"(        for (int h = 0; h < MQ_GQA; ++h) {
)"
R"(            const ACC_TYPE dot_partial = dot4[h].s0 + dot4[h].s1 + dot4[h].s2 + dot4[h].s3;
)"
R"(            ACC_TYPE s = sub_group_reduce_add(dot_partial) * scale;
)"
R"(            if (logit_softcap > 0.0f) {
)"
R"(                s = logit_softcap * tanh(s / logit_softcap);
)"
R"(            }
)"
R"(            if (mask_base[h] != NULL) {
)"
R"(                const global MASK_DATA_TYPE * mask_ptr = (const global MASK_DATA_TYPE *) mask_base[h];
)"
R"(                s += slope[h] * (ACC_TYPE) mask_ptr[k_idx];
)"
R"(            }
)"
R"(            score[h] = s;
)"
R"(        }
)"
R"(
)"
R"(        ACC_TYPE p_h[MQ_GQA];
)"
R"(        ACC_TYPE sp_h[MQ_GQA];
)"
R"(        #pragma unroll
)"
R"(        for (int h = 0; h < MQ_GQA; ++h) {
)"
R"(            const ACC_TYPE m_new = max(m_i[h], score[h]);
)"
R"(            sp_h[h] = native_exp(m_i[h] - m_new);
)"
R"(            p_h[h]  = native_exp(score[h] - m_new);
)"
R"(            l_i[h]  = l_i[h] * sp_h[h] + p_h[h];
)"
R"(            m_i[h]  = m_new;
)"
R"(        }
)"
R"(
)"
R"(        int idx = 0;
)"
R"(        for (int dv_idx = tid_sg; dv_idx < DV_VEC; dv_idx += Q1_WG_SIZE, ++idx) {
)"
R"(            const ACC_TYPE4 v_vec = CONVERT_KV_ACC4(v_ptr[dv_idx]);
)"
R"(            #pragma unroll
)"
R"(            for (int h = 0; h < MQ_GQA; ++h) {
)"
R"(                o_acc[h][idx] = mad(p_h[h], v_vec, o_acc[h][idx] * sp_h[h]);
)"
R"(            }
)"
R"(        }
)"
R"(    }
)"
R"(
)"
R"(    // per-h cross-subgroup merge
)"
R"(    __local ACC_TYPE  sg_m[MQ_GQA][MQ_NSG_SPLIT];
)"
R"(    __local ACC_TYPE  sg_l[MQ_GQA][MQ_NSG_SPLIT];
)"
R"(    __local ACC_TYPE4 sg_o[MQ_NSG_SPLIT][DV_VEC];
)"
R"(
)"
R"(    if (tid_sg == 0) {
)"
R"(        #pragma unroll
)"
R"(        for (int h = 0; h < MQ_GQA; ++h) {
)"
R"(            sg_m[h][sgid] = m_i[h];
)"
R"(            sg_l[h][sgid] = l_i[h];
)"
R"(        }
)"
R"(    }
)"
R"(
)"
R"(    #pragma unroll
)"
R"(    for (int h = 0; h < MQ_GQA; ++h) {
)"
R"(        {
)"
R"(            int idx = 0;
)"
R"(            for (int dv_idx = tid_sg; dv_idx < DV_VEC; dv_idx += Q1_WG_SIZE, ++idx) {
)"
R"(                sg_o[sgid][dv_idx] = o_acc[h][idx];
)"
R"(            }
)"
R"(        }
)"
R"(        barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(        if (sgid == 0) {
)"
R"(            const int head_idx = FA_MQS_HEAD_IDX(h);
)"
R"(
)"
R"(            // fold per-subgroup (m, l) into split-level (m_c, l_c)
)"
R"(            ACC_TYPE m_c = sg_m[h][0];
)"
R"(            #pragma unroll
)"
R"(            for (int s = 1; s < MQ_NSG_SPLIT; ++s) {
)"
R"(                m_c = max(m_c, sg_m[h][s]);
)"
R"(            }
)"
R"(            ACC_TYPE l_c = 0.0f;
)"
R"(            #pragma unroll
)"
R"(            for (int s = 0; s < MQ_NSG_SPLIT; ++s) {
)"
R"(                l_c += sg_l[h][s] * native_exp(sg_m[h][s] - m_c);
)"
R"(            }
)"
R"(
)"
R"(            const ulong rec_idx = ((((ulong) batch_idx * n_head + head_idx) * n_q + q_idx)
)"
R"(                                   * n_splits + split_idx);
)"
R"(            global float  * rec   = partial_void + rec_idx * record_stride;
)"
R"(            global float4 * rec_o = (global float4 *) (rec + 2);
)"
R"(
)"
R"(            if (tid_sg == 0) {
)"
R"(                rec[0] = (float) m_c;
)"
R"(                rec[1] = (float) l_c;
)"
R"(            }
)"
R"(            // each thread writes its DV slice of the merged O.
)"
R"(            for (int dv_idx = tid_sg; dv_idx < DV_VEC; dv_idx += Q1_WG_SIZE) {
)"
R"(                ACC_TYPE4 o_merged = (ACC_TYPE4)(0.0f);
)"
R"(                #pragma unroll
)"
R"(                for (int s = 0; s < MQ_NSG_SPLIT; ++s) {
)"
R"(                    const ACC_TYPE alpha = native_exp(sg_m[h][s] - m_c);
)"
R"(                    o_merged = mad((ACC_TYPE4)(alpha), sg_o[s][dv_idx], o_merged);
)"
R"(                }
)"
R"(                rec_o[dv_idx] = o_merged;
)"
R"(            }
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
R"(#undef FA_MQS_HEAD_IDX
)"
R"(
)"
R"(#ifndef FA_MQ_SPLIT_ONLY
)"
R"(// Cluster-parallel variant of _q1_vec_mq_split
)"
R"(//
)"
R"(// Tthe baseline keeps one 256B K row in flight per subgroup (32 lanes cooperate
)"
R"(// on one position, serialized by the reduce+exp chain). This kernel
)"
R"(// takes q1_split's memory-level parallelism at MQ's read-once traffic:
)"
R"(//   - the 64-lane subgroup is split into FA_CL_NCL clusters of FA_CL_C lanes;
)"
R"(//   - each cluster owns its own KV position stream (positions strided by
)"
R"(//     FA_CL_NCL) with private per-cluster online-softmax state, hence FA_CL_NCL
)"
R"(//     independent K rows in flight per subgroup, no cross-cluster serial chain;
)"
R"(//   - within a cluster, lanes split DK for the dot (cluster-reduce via
)"
R"(//     sub_group_shuffle_xor, steps < FA_CL_C stay inside the cluster) and
)"
R"(//     split DV for o_acc (each lane owns dv indices {lic + FA_CL_C*i} — the
)"
R"(//     same slice for every position, so accumulation is lane-local);
)"
R"(//   - merge stage 1 folds the FA_CL_NCL cluster partials with cross-cluster
)"
R"(//     shuffles (distances >= FA_CL_C); stage 2 is the baseline cross-subgroup
)"
R"(//     LDS merge (o published by cluster 0's lanes, layout-identical to the
)"
R"(//     baseline's sg_o).
)"
R"(// The KV sweep runs a UNIFORM trip count (max over clusters) with a clamped
)"
R"(// row address + FA_M_INIT score on the tail — keeps every shuffle convergent
)"
R"(// (p = exp(FA_M_INIT - m) underflows to 0, so clamped-row reads are inert).
)"
R"(// Register cost vs baseline: o_acc grows from DV_VEC/64 to DV_VEC/FA_CL_C
)"
R"(// float4 per lane per head — FA_CL_C=8 / MQ_GQA=4 => 16 float4 (256B).
)"
R"(
)"
R"(#ifdef HAS_SUBGROUP_SHUFFLE  // cluster reduce/merge needs shuffles; absent -> kernel dropped, dispatch falls back
)"
R"(
)"
R"(#ifndef FA_CL_C
)"
R"(#define FA_CL_C 8
)"
R"(#endif
)"
R"(
)"
R"(// The lane striping requires DK/DV to divide evenly across the cluster;
)"
R"(// otherwise (e.g. DK=40 with FA_CL_C=16 -> zero-size arrays) compile the
)"
R"(// kernel out — host soft-create falls back silently.
)"
R"(#if (DK_VEC % FA_CL_C) == 0 && (DV_VEC % FA_CL_C) == 0
)"
R"(#define FA_CL_NCL (Q1_WG_SIZE / FA_CL_C)   // clusters (position streams) per subgroup
)"
R"(#define FA_CL_DK  (DK_VEC / FA_CL_C)       // half4s of K per lane per row
)"
R"(#define FA_CL_DV  (DV_VEC / FA_CL_C)       // float4s of o_acc per lane per head
)"
R"(
)"
R"(// explicit "half" sub-group attribute routes this fp16-heavy kernel to a slow
)"
R"(// codegen path on the X1 compiler. X2 keeps the pin: its driver miscompile
)"
R"(// without it.
)"
R"(#ifdef FA_C8_NO_SG_PIN
)"
R"(#define FA_C8_SG_ATTR
)"
R"(#else
)"
R"(// REQD_FA_SG pins the HW subgroup on Intel (intel_reqd_sub_group_size(FA_SG),
)"
R"(// host passes -D FA_SG=32); empty on Adreno. REQD_SUBGROUP_SIZE_64 pins 64 on
)"
R"(// Adreno; empty on Intel.
)"
R"(#define FA_C8_SG_ATTR REQD_FA_SG REQD_SUBGROUP_SIZE_64
)"
R"(#endif
)"
R"(
)"
R"(FA_C8_SG_ATTR
)"
R"(__kernel void flash_attn_f32_f16_q1_vec_mq_split_c8(
)"
R"(    const global void * q_void, ulong q_offset,
)"
R"(    const global void * k_void, ulong k_offset,
)"
R"(    const global void * v_void, ulong v_offset,
)"
R"(    const float scale,
)"
R"(    const int n_q,
)"
R"(    const int n_kv,
)"
R"(    const int n_head,
)"
R"(    const ulong q_nb1, const ulong q_nb2, const ulong q_nb3,
)"
R"(    const ulong k_nb1, const ulong k_nb2, const ulong k_nb3,
)"
R"(    const ulong v_nb1, const ulong v_nb2, const ulong v_nb3,
)"
R"(    const float max_bias,
)"
R"(    const float m0,
)"
R"(    const float m1,
)"
R"(    const int n_head_log2,
)"
R"(    const float logit_softcap,
)"
R"(    const int n_head_kv,
)"
R"(    const global void * mask_void,
)"
R"(    const ulong mask_offset,
)"
R"(    const ulong mask_nb1,
)"
R"(    const ulong mask_nb2,
)"
R"(    const ulong mask_nb3,
)"
R"(    const int mask_ne2,
)"
R"(    const int mask_ne3,
)"
R"(    global float * partial_void,
)"
R"(    const int n_splits,
)"
R"(    const int kv_per_split
)"
R"() {
)"
R"(    const int tid              = get_local_id(0);
)"
R"(    const int sgid             = tid / Q1_WG_SIZE;
)"
R"(    const int tid_sg           = tid % Q1_WG_SIZE;
)"
R"(    const int cl               = tid_sg / FA_CL_C;   // cluster id
)"
R"(    const int lic              = tid_sg % FA_CL_C;   // lane in cluster
)"
R"(    const int kvhead_batch_idx = get_global_id(1);
)"
R"(    const int split_q_idx      = get_global_id(2);
)"
R"(    const int split_idx        = split_q_idx % n_splits;
)"
R"(    const int q_idx            = split_q_idx / n_splits;
)"
R"(
)"
R"(    const int hgroups     = n_head_kv * FA_HEAD_SUB;
)"
R"(    const int batch_idx   = kvhead_batch_idx / hgroups;
)"
R"(    const int hg          = kvhead_batch_idx % hgroups;
)"
R"(    const int head_kv_idx = hg / FA_HEAD_SUB;
)"
R"(    const int head_sub    = hg % FA_HEAD_SUB;
)"
R"(#define FA_HEAD_IDX(h) (head_kv_idx * (MQ_GQA * FA_HEAD_SUB) + head_sub * MQ_GQA + (h))
)"
R"(
)"
R"(    const int kv_start = split_idx * kv_per_split;
)"
R"(    const int kv_end   = min(kv_start + kv_per_split, n_kv);
)"
R"(
)"
R"(    const ulong record_stride = (ulong) FA_PARTIAL_FLOATS;
)"
R"(
)"
R"(    if (kv_start >= kv_end) {
)"
R"(        if (tid == 0) {
)"
R"(            #pragma unroll
)"
R"(            for (int h = 0; h < MQ_GQA; ++h) {
)"
R"(                const int head_idx = FA_HEAD_IDX(h);
)"
R"(                const ulong rec_idx = ((((ulong) batch_idx * n_head + head_idx) * n_q + q_idx)
)"
R"(                                       * n_splits + split_idx);
)"
R"(                global float * rec = partial_void + rec_idx * record_stride;
)"
R"(                rec[0] = FA_M_INIT;
)"
R"(                rec[1] = 0.0f;
)"
R"(            }
)"
R"(        }
)"
R"(        return;
)"
R"(    }
)"
R"(
)"
R"(    const global char * q_base = (const global char *) q_void + q_offset;
)"
R"(    const global char * k_base = (const global char *) k_void + k_offset;
)"
R"(    const global char * v_base = (const global char *) v_void + v_offset;
)"
R"(
)"
R"(    // Stage MQ_GQA Q rows in __local once (uniform across WG).
)"
R"(    __local ACC_TYPE4 q_shared[MQ_GQA * DK_VEC];
)"
R"(    for (int i = tid; i < MQ_GQA * DK_VEC; i += MQ_SPLIT_WG_SIZE) {
)"
R"(        const int h        = i / DK_VEC;
)"
R"(        const int k        = i % DK_VEC;
)"
R"(        const int head_idx = FA_HEAD_IDX(h);
)"
R"(        const ulong q_row_offset = batch_idx * q_nb3 + head_idx * q_nb2 + (ulong) q_idx * q_nb1;
)"
R"(        const global Q_DATA_TYPE4 * q_ptr = (const global Q_DATA_TYPE4 *) (q_base + q_row_offset);
)"
R"(        q_shared[h * DK_VEC + k] = CONVERT_Q_ACC4(q_ptr[k]);
)"
R"(    }
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(    float slope[MQ_GQA];
)"
R"(    #pragma unroll
)"
R"(    for (int h = 0; h < MQ_GQA; ++h) {
)"
R"(        slope[h] = get_alibi_slope(max_bias, FA_HEAD_IDX(h), n_head_log2, m0, m1);
)"
R"(    }
)"
R"(
)"
R"(#ifdef FA_CL_MASK_BCAST
)"
R"(    const global char * mask_base_b = NULL;
)"
R"(    if (mask_void != NULL) {
)"
R"(        mask_base_b = (const global char *) mask_void + mask_offset +
)"
R"(                      (batch_idx % mask_ne3) * mask_nb3 + (ulong) q_idx * mask_nb1;
)"
R"(    }
)"
R"(    const int mask_bcast = mask_base_b != NULL && mask_ne2 == 1;
)"
R"(#else
)"
R"(    const global char * mask_base[MQ_GQA];
)"
R"(    if (mask_void != NULL) {
)"
R"(        const int mask_batch_idx = batch_idx % mask_ne3;
)"
R"(        const global char * mask_base_b = (const global char *) mask_void + mask_offset +
)"
R"(                                          mask_batch_idx * mask_nb3 +
)"
R"(                                          (ulong) q_idx * mask_nb1;
)"
R"(        #pragma unroll
)"
R"(        for (int h = 0; h < MQ_GQA; ++h) {
)"
R"(            const int head_idx      = FA_HEAD_IDX(h);
)"
R"(            const int mask_head_idx = head_idx % mask_ne2;
)"
R"(            mask_base[h] = mask_base_b + mask_head_idx * mask_nb2;
)"
R"(        }
)"
R"(    } else {
)"
R"(        #pragma unroll
)"
R"(        for (int h = 0; h < MQ_GQA; ++h) mask_base[h] = NULL;
)"
R"(    }
)"
R"(#endif
)"
R"(
)"
R"(    // Per-CLUSTER online-softmax state (uniform across the cluster's lanes);
)"
R"(    // o_acc holds this lane's DV slice {lic + FA_CL_C*i}.
)"
R"(    ACC_TYPE4 o_acc[MQ_GQA][FA_CL_DV];
)"
R"(    ACC_TYPE  m_i[MQ_GQA];
)"
R"(    ACC_TYPE  l_i[MQ_GQA];
)"
R"(    #pragma unroll
)"
R"(    for (int h = 0; h < MQ_GQA; ++h) {
)"
R"(        m_i[h] = FA_M_INIT;
)"
R"(        l_i[h] = 0.0f;
)"
R"(        #pragma unroll
)"
R"(        for (int i = 0; i < FA_CL_DV; ++i) o_acc[h][i] = (ACC_TYPE4)(0.0f);
)"
R"(    }
)"
R"(
)"
R"(    const int kv_len    = kv_end - kv_start;
)"
R"(    const int kv_per_sg = (kv_len + MQ_NSG_SPLIT - 1) / MQ_NSG_SPLIT;
)"
R"(    const int kv_lo     = kv_start + sgid * kv_per_sg;
)"
R"(    const int kv_hi     = min(kv_end, kv_lo + kv_per_sg);
)"
R"(
)"
R"(    // Uniform trip count across the subgroup: every cluster runs n_iter
)"
R"(    // iterations; tail positions clamp the row address and drop the score to
)"
R"(    // FA_M_INIT so shuffles stay convergent and the contribution is exactly 0.
)"
R"(    const int n_iter = (kv_hi - kv_lo + FA_CL_NCL - 1) / FA_CL_NCL;
)"
R"(    const ulong kv_row_base = batch_idx * k_nb3 + head_kv_idx * k_nb2;
)"
R"(    const ulong v_row_base  = batch_idx * v_nb3 + head_kv_idx * v_nb2;
)"
R"(
)"
R"(    for (int it = 0; it < n_iter; ++it) {
)"
R"(        const int k_idx = kv_lo + cl + it * FA_CL_NCL;
)"
R"(        const int valid = k_idx < kv_hi;
)"
R"(        const int k_safe = valid ? k_idx : (kv_hi - 1);
)"
R"(
)"
R"(        const global KV_DATA_TYPE4 * k_ptr = (const global KV_DATA_TYPE4 *) (k_base + kv_row_base + (ulong) k_safe * k_nb1);
)"
R"(        const global KV_DATA_TYPE4 * v_ptr = (const global KV_DATA_TYPE4 *) (v_base + v_row_base  + (ulong) k_safe * v_nb1);
)"
R"(
)"
R"(#if defined(FA_CL_MHRED) && MQ_GQA == 4 && FA_CL_C == 16 && FA_CL_DK == 1 && FA_CL_DV == 1
)"
R"(        ACC_TYPE mask_val = 0.0f;
)"
R"(        if (mask_bcast) {
)"
R"(            mask_val = (ACC_TYPE) ((const global MASK_DATA_TYPE *) mask_base_b)[k_safe];
)"
R"(        }
)"
R"(        const ACC_TYPE4 k_vec_1 = CONVERT_KV_ACC4(k_ptr[lic]);
)"
R"(        const ACC_TYPE4 v_vec_1 = CONVERT_KV_ACC4(v_ptr[lic]);
)"
R"(
)"
R"(        // Reduce four heads with eight shuffles and keep each head's summation order.
)"
R"(        const int mh_b0 = lic & 1;
)"
R"(        const int mh_b1 = lic & 2;
)"
R"(
)"
R"(        ACC_TYPE mh_p[MQ_GQA];
)"
R"(        #pragma unroll
)"
R"(        for (int h = 0; h < MQ_GQA; ++h) {
)"
R"(            const ACC_TYPE4 d4 = mad(q_shared[h * DK_VEC + lic], k_vec_1, (ACC_TYPE4)(0.0f));
)"
R"(            mh_p[h] = d4.s0 + d4.s1 + d4.s2 + d4.s3;
)"
R"(        }
)"
R"(
)"
R"(        ACC_TYPE mh_r2[2];
)"
R"(        #pragma unroll
)"
R"(        for (int j = 0; j < 2; ++j) {
)"
R"(            const ACC_TYPE keep = mh_b0 ? mh_p[j + 2] : mh_p[j];
)"
R"(            const ACC_TYPE send = mh_b0 ? mh_p[j]     : mh_p[j + 2];
)"
R"(            mh_r2[j] = keep + sub_group_shuffle_xor(send, 1);
)"
R"(        }
)"
R"(        ACC_TYPE mh_r1 = (mh_b1 ? mh_r2[1] : mh_r2[0]) +
)"
R"(                         sub_group_shuffle_xor(mh_b1 ? mh_r2[0] : mh_r2[1], 2);
)"
R"(        mh_r1 += sub_group_shuffle_xor(mh_r1, 4);
)"
R"(        mh_r1 += sub_group_shuffle_xor(mh_r1, 8);
)"
R"(
)"
R"(        ACC_TYPE mh_e2[2];
)"
R"(        {
)"
R"(            const ACC_TYPE other = sub_group_shuffle_xor(mh_r1, 2);
)"
R"(            mh_e2[0] = mh_b1 ? other  : mh_r1;
)"
R"(            mh_e2[1] = mh_b1 ? mh_r1  : other;
)"
R"(        }
)"
R"(        ACC_TYPE mh_s[MQ_GQA];
)"
R"(        #pragma unroll
)"
R"(        for (int j = 0; j < 2; ++j) {
)"
R"(            const ACC_TYPE other = sub_group_shuffle_xor(mh_e2[j], 1);
)"
R"(            mh_s[j]     = mh_b0 ? other     : mh_e2[j];
)"
R"(            mh_s[j + 2] = mh_b0 ? mh_e2[j]  : other;
)"
R"(        }
)"
R"(
)"
R"(        #pragma unroll
)"
R"(        for (int h = 0; h < MQ_GQA; ++h) {
)"
R"(            ACC_TYPE s = mh_s[h] * scale;
)"
R"(            if (logit_softcap > 0.0f) {
)"
R"(                s = logit_softcap * tanh(s / logit_softcap);
)"
R"(            }
)"
R"(            if (mask_bcast) {
)"
R"(                s += slope[h] * mask_val;
)"
R"(            } else if (mask_base_b != NULL) {
)"
R"(                const int mask_head_idx = FA_HEAD_IDX(h) % mask_ne2;
)"
R"(                const global MASK_DATA_TYPE * mask_ptr = (const global MASK_DATA_TYPE *) (mask_base_b + mask_head_idx * mask_nb2);
)"
R"(                s += slope[h] * (ACC_TYPE) mask_ptr[k_safe];
)"
R"(            }
)"
R"(            const ACC_TYPE sc    = valid ? s : FA_M_INIT;
)"
R"(            const ACC_TYPE m_new = max(m_i[h], sc);
)"
R"(            const ACC_TYPE sp    = native_exp(m_i[h] - m_new);
)"
R"(            const ACC_TYPE p     = native_exp(sc - m_new);
)"
R"(            l_i[h] = l_i[h] * sp + p;
)"
R"(            m_i[h] = m_new;
)"
R"(            o_acc[h][0] = mad(p, v_vec_1, o_acc[h][0] * sp);
)"
R"(        }
)"
R"(#else
)"
R"(        // Dot: this lane covers DK elements {lic + FA_CL_C*i} of the cluster's row.
)"
R"(        ACC_TYPE4 dot4[MQ_GQA];
)"
R"(        #pragma unroll
)"
R"(        for (int h = 0; h < MQ_GQA; ++h) dot4[h] = (ACC_TYPE4)(0.0f);
)"
R"(        #pragma unroll
)"
R"(        for (int i = 0; i < FA_CL_DK; ++i) {
)"
R"(            const int kk = lic + FA_CL_C * i;
)"
R"(            const ACC_TYPE4 k_vec = CONVERT_KV_ACC4(k_ptr[kk]);
)"
R"(            #pragma unroll
)"
R"(            for (int h = 0; h < MQ_GQA; ++h) {
)"
R"(                dot4[h] = mad(q_shared[h * DK_VEC + kk], k_vec, dot4[h]);
)"
R"(            }
)"
R"(        }
)"
R"(
)"
R"(        // Cluster-reduce (xor steps < FA_CL_C stay inside the cluster) + score.
)"
R"(        ACC_TYPE score[MQ_GQA];
)"
R"(        #pragma unroll
)"
R"(        for (int h = 0; h < MQ_GQA; ++h) {
)"
R"(            ACC_TYPE s = dot4[h].s0 + dot4[h].s1 + dot4[h].s2 + dot4[h].s3;
)"
R"(            #pragma unroll
)"
R"(            for (int step = 1; step < FA_CL_C; step <<= 1) {
)"
R"(                s += sub_group_shuffle_xor(s, step);
)"
R"(            }
)"
R"(            s *= scale;
)"
R"(            if (logit_softcap > 0.0f) {
)"
R"(                s = logit_softcap * tanh(s / logit_softcap);
)"
R"(            }
)"
R"(            if (mask_base[h] != NULL) {
)"
R"(                const global MASK_DATA_TYPE * mask_ptr = (const global MASK_DATA_TYPE *) mask_base[h];
)"
R"(                s += slope[h] * (ACC_TYPE) mask_ptr[k_safe];
)"
R"(            }
)"
R"(            score[h] = valid ? s : FA_M_INIT;
)"
R"(        }
)"
R"(
)"
R"(        // Per-cluster online update — identical math to the baseline, but the
)"
R"(        // serial chain is per cluster (depth n_iter, not kv_per_sg).
)"
R"(        ACC_TYPE p_h[MQ_GQA];
)"
R"(        ACC_TYPE sp_h[MQ_GQA];
)"
R"(        #pragma unroll
)"
R"(        for (int h = 0; h < MQ_GQA; ++h) {
)"
R"(            const ACC_TYPE m_new = max(m_i[h], score[h]);
)"
R"(            sp_h[h] = native_exp(m_i[h] - m_new);
)"
R"(            p_h[h]  = native_exp(score[h] - m_new);
)"
R"(            l_i[h]  = l_i[h] * sp_h[h] + p_h[h];
)"
R"(            m_i[h]  = m_new;
)"
R"(        }
)"
R"(
)"
R"(        // V accumulate on this lane's DV slice (p = 0 on tail -> inert).
)"
R"(        #pragma unroll
)"
R"(        for (int i = 0; i < FA_CL_DV; ++i) {
)"
R"(            const ACC_TYPE4 v_vec = CONVERT_KV_ACC4(v_ptr[lic + FA_CL_C * i]);
)"
R"(            #pragma unroll
)"
R"(            for (int h = 0; h < MQ_GQA; ++h) {
)"
R"(                o_acc[h][i] = mad(p_h[h], v_vec, o_acc[h][i] * sp_h[h]);
)"
R"(            }
)"
R"(        }
)"
R"(#endif
)"
R"(    }
)"
R"(
)"
R"(    // Merge stage 1: fold the FA_CL_NCL cluster partials inside the subgroup.
)"
R"(    // Lanes with equal lic across clusters hold the SAME dv slice, so a
)"
R"(    // cross-cluster xor-reduce (distances FA_CL_C..Q1_WG_SIZE/2) sums o
)"
R"(    // slice-wise; m/l fold the same way. All shuffles are subgroup-convergent.
)"
R"(    #pragma unroll
)"
R"(    for (int h = 0; h < MQ_GQA; ++h) {
)"
R"(        ACC_TYPE m_c = m_i[h];
)"
R"(        #pragma unroll
)"
R"(        for (int step = FA_CL_C; step < Q1_WG_SIZE; step <<= 1) {
)"
R"(            m_c = max(m_c, sub_group_shuffle_xor(m_c, step));
)"
R"(        }
)"
R"(        const ACC_TYPE alpha = native_exp(m_i[h] - m_c);
)"
R"(        ACC_TYPE l_c = l_i[h] * alpha;
)"
R"(        #pragma unroll
)"
R"(        for (int step = FA_CL_C; step < Q1_WG_SIZE; step <<= 1) {
)"
R"(            l_c += sub_group_shuffle_xor(l_c, step);
)"
R"(        }
)"
R"(        #pragma unroll
)"
R"(        for (int i = 0; i < FA_CL_DV; ++i) {
)"
R"(            ACC_TYPE4 o = o_acc[h][i] * alpha;
)"
R"(            #pragma unroll
)"
R"(            for (int step = FA_CL_C; step < Q1_WG_SIZE; step <<= 1) {
)"
R"(                o.s0 += sub_group_shuffle_xor(o.s0, step);
)"
R"(                o.s1 += sub_group_shuffle_xor(o.s1, step);
)"
R"(                o.s2 += sub_group_shuffle_xor(o.s2, step);
)"
R"(                o.s3 += sub_group_shuffle_xor(o.s3, step);
)"
R"(            }
)"
R"(            o_acc[h][i] = o;
)"
R"(        }
)"
R"(        m_i[h] = m_c;
)"
R"(        l_i[h] = l_c;
)"
R"(    }
)"
R"(
)"
R"(    // Merge stage 2: baseline cross-subgroup LDS merge. Cluster 0's lanes hold
)"
R"(    // the subgroup's merged o (dv indices {lic + FA_CL_C*i}) — same sg_o layout
)"
R"(    // and fold loop as q1_vec_mq_split.
)"
R"(    __local ACC_TYPE  sg_m[MQ_GQA][MQ_NSG_SPLIT];
)"
R"(    __local ACC_TYPE  sg_l[MQ_GQA][MQ_NSG_SPLIT];
)"
R"(    __local ACC_TYPE4 sg_o[MQ_NSG_SPLIT][DV_VEC];
)"
R"(
)"
R"(    if (tid_sg == 0) {
)"
R"(        #pragma unroll
)"
R"(        for (int h = 0; h < MQ_GQA; ++h) {
)"
R"(            sg_m[h][sgid] = m_i[h];
)"
R"(            sg_l[h][sgid] = l_i[h];
)"
R"(        }
)"
R"(    }
)"
R"(
)"
R"(    #pragma unroll
)"
R"(    for (int h = 0; h < MQ_GQA; ++h) {
)"
R"(        if (cl == 0) {
)"
R"(            #pragma unroll
)"
R"(            for (int i = 0; i < FA_CL_DV; ++i) {
)"
R"(                sg_o[sgid][lic + FA_CL_C * i] = o_acc[h][i];
)"
R"(            }
)"
R"(        }
)"
R"(        barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(        if (sgid == 0) {
)"
R"(            const int head_idx = FA_HEAD_IDX(h);
)"
R"(
)"
R"(            ACC_TYPE m_c = sg_m[h][0];
)"
R"(            #pragma unroll
)"
R"(            for (int s = 1; s < MQ_NSG_SPLIT; ++s) {
)"
R"(                m_c = max(m_c, sg_m[h][s]);
)"
R"(            }
)"
R"(            ACC_TYPE l_c = 0.0f;
)"
R"(            #pragma unroll
)"
R"(            for (int s = 0; s < MQ_NSG_SPLIT; ++s) {
)"
R"(                l_c += sg_l[h][s] * native_exp(sg_m[h][s] - m_c);
)"
R"(            }
)"
R"(
)"
R"(            const ulong rec_idx = ((((ulong) batch_idx * n_head + head_idx) * n_q + q_idx)
)"
R"(                                   * n_splits + split_idx);
)"
R"(            global float  * rec   = partial_void + rec_idx * record_stride;
)"
R"(            global float4 * rec_o = (global float4 *) (rec + 2);
)"
R"(
)"
R"(            if (tid_sg == 0) {
)"
R"(                rec[0] = (float) m_c;
)"
R"(                rec[1] = (float) l_c;
)"
R"(            }
)"
R"(            for (int dv_idx = tid_sg; dv_idx < DV_VEC; dv_idx += Q1_WG_SIZE) {
)"
R"(                ACC_TYPE4 o_merged = (ACC_TYPE4)(0.0f);
)"
R"(                #pragma unroll
)"
R"(                for (int s = 0; s < MQ_NSG_SPLIT; ++s) {
)"
R"(                    const ACC_TYPE alpha = native_exp(sg_m[h][s] - m_c);
)"
R"(                    o_merged = mad((ACC_TYPE4)(alpha), sg_o[s][dv_idx], o_merged);
)"
R"(                }
)"
R"(                rec_o[dv_idx] = o_merged;
)"
R"(            }
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
R"(#undef FA_HEAD_IDX
)"
R"(
)"
R"(#endif  // DK_VEC/DV_VEC divisible by FA_CL_C
)"
R"(#endif  // HAS_SUBGROUP_SHUFFLE (q1_vec_mq_split_c8)
)"
R"(
)"
R"(REQD_SUBGROUP_SIZE_64
)"
R"(__kernel void flash_attn_f32_f16_q1_vec_mq_split_k_img(
)"
R"(    const global void * q_void, ulong q_offset,
)"
R"(    __read_only image1d_buffer_t k_img,
)"
R"(    const global void * v_void, ulong v_offset,
)"
R"(    const float scale,
)"
R"(    const int n_q,
)"
R"(    const int n_kv,
)"
R"(    const int n_head,
)"
R"(    const ulong q_nb1, const ulong q_nb2, const ulong q_nb3,
)"
R"(    const ulong k_nb1, const ulong k_nb2, const ulong k_nb3,
)"
R"(    const ulong v_nb1, const ulong v_nb2, const ulong v_nb3,
)"
R"(    const float max_bias,
)"
R"(    const float m0,
)"
R"(    const float m1,
)"
R"(    const int n_head_log2,
)"
R"(    const float logit_softcap,
)"
R"(    const int n_head_kv,
)"
R"(    const global void * mask_void,
)"
R"(    const ulong mask_offset,
)"
R"(    const ulong mask_nb1,
)"
R"(    const ulong mask_nb2,
)"
R"(    const ulong mask_nb3,
)"
R"(    const int mask_ne2,
)"
R"(    const int mask_ne3,
)"
R"(    global float * partial_void,
)"
R"(    const int n_splits,
)"
R"(    const int kv_per_split
)"
R"() {
)"
R"(    const int tid              = get_local_id(0);
)"
R"(    const int sgid             = tid / Q1_WG_SIZE;
)"
R"(    const int tid_sg           = tid % Q1_WG_SIZE;
)"
R"(    const int kvhead_batch_idx = get_global_id(1);
)"
R"(    const int split_q_idx      = get_global_id(2);
)"
R"(    const int split_idx        = split_q_idx % n_splits;
)"
R"(    const int q_idx            = split_q_idx / n_splits;
)"
R"(
)"
R"(    const int batch_idx   = kvhead_batch_idx / n_head_kv;
)"
R"(    const int head_kv_idx = kvhead_batch_idx % n_head_kv;
)"
R"(
)"
R"(    const int kv_start = split_idx * kv_per_split;
)"
R"(    const int kv_end   = min(kv_start + kv_per_split, n_kv);
)"
R"(
)"
R"(    const ulong record_stride = (ulong) FA_PARTIAL_FLOATS;
)"
R"(
)"
R"(    if (kv_start >= kv_end) {
)"
R"(        if (tid == 0) {
)"
R"(            #pragma unroll
)"
R"(            for (int h = 0; h < MQ_GQA; ++h) {
)"
R"(                const int head_idx = head_kv_idx * MQ_GQA + h;
)"
R"(                const ulong rec_idx = ((((ulong) batch_idx * n_head + head_idx) * n_q + q_idx)
)"
R"(                                       * n_splits + split_idx);
)"
R"(                global float * rec = partial_void + rec_idx * record_stride;
)"
R"(                rec[0] = FA_M_INIT;
)"
R"(                rec[1] = 0.0f;
)"
R"(            }
)"
R"(        }
)"
R"(        return;
)"
R"(    }
)"
R"(
)"
R"(    const global char * q_base = (const global char *) q_void + q_offset;
)"
R"(    const global char * v_base = (const global char *) v_void + v_offset;
)"
R"(
)"
R"(    __local ACC_TYPE4 q_shared[MQ_GQA * DK_VEC];
)"
R"(    for (int i = tid; i < MQ_GQA * DK_VEC; i += MQ_SPLIT_WG_SIZE) {
)"
R"(        const int h        = i / DK_VEC;
)"
R"(        const int k        = i % DK_VEC;
)"
R"(        const int head_idx = head_kv_idx * MQ_GQA + h;
)"
R"(        const ulong q_row_offset = batch_idx * q_nb3 + head_idx * q_nb2 + (ulong) q_idx * q_nb1;
)"
R"(        const global Q_DATA_TYPE4 * q_ptr = (const global Q_DATA_TYPE4 *) (q_base + q_row_offset);
)"
R"(        q_shared[h * DK_VEC + k] = CONVERT_Q_ACC4(q_ptr[k]);
)"
R"(    }
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(    float slope[MQ_GQA];
)"
R"(    #pragma unroll
)"
R"(    for (int h = 0; h < MQ_GQA; ++h) {
)"
R"(        slope[h] = get_alibi_slope(max_bias, head_kv_idx * MQ_GQA + h, n_head_log2, m0, m1);
)"
R"(    }
)"
R"(
)"
R"(    const global char * mask_base[MQ_GQA];
)"
R"(    if (mask_void != NULL) {
)"
R"(        const int mask_batch_idx = batch_idx % mask_ne3;
)"
R"(        const global char * mask_base_b = (const global char *) mask_void + mask_offset +
)"
R"(                                          mask_batch_idx * mask_nb3 +
)"
R"(                                          (ulong) q_idx * mask_nb1;
)"
R"(        #pragma unroll
)"
R"(        for (int h = 0; h < MQ_GQA; ++h) {
)"
R"(            const int head_idx      = head_kv_idx * MQ_GQA + h;
)"
R"(            const int mask_head_idx = head_idx % mask_ne2;
)"
R"(            mask_base[h] = mask_base_b + mask_head_idx * mask_nb2;
)"
R"(        }
)"
R"(    } else {
)"
R"(        #pragma unroll
)"
R"(        for (int h = 0; h < MQ_GQA; ++h) mask_base[h] = NULL;
)"
R"(    }
)"
R"(
)"
R"(    ACC_TYPE4 o_acc[MQ_GQA][Q1V_DV_PER_THREAD];
)"
R"(    ACC_TYPE  m_i[MQ_GQA];
)"
R"(    ACC_TYPE  l_i[MQ_GQA];
)"
R"(    #pragma unroll
)"
R"(    for (int h = 0; h < MQ_GQA; ++h) {
)"
R"(        m_i[h] = FA_M_INIT;
)"
R"(        l_i[h] = 0.0f;
)"
R"(        #pragma unroll
)"
R"(        for (int i = 0; i < Q1V_DV_PER_THREAD; ++i) o_acc[h][i] = (ACC_TYPE4)(0.0f);
)"
R"(    }
)"
R"(
)"
R"(    // K pitches in pixel units, pixel = 1 half4 = 8 B -> byte_stride >> 3.
)"
R"(    const int pitch_px_row   = (int)(k_nb1 >> 3);
)"
R"(    const int pitch_px_head  = (int)(k_nb2 >> 3);
)"
R"(    const int pitch_px_batch = (int)(k_nb3 >> 3);
)"
R"(
)"
R"(    const int kv_len    = kv_end - kv_start;
)"
R"(    const int kv_per_sg = (kv_len + MQ_NSG_SPLIT - 1) / MQ_NSG_SPLIT;
)"
R"(    const int kv_lo     = kv_start + sgid * kv_per_sg;
)"
R"(    const int kv_hi     = min(kv_end, kv_lo + kv_per_sg);
)"
R"(
)"
R"(    for (int k_idx = kv_lo; k_idx < kv_hi; ++k_idx) {
)"
R"(        const int k_row_px = batch_idx * pitch_px_batch +
)"
R"(                             head_kv_idx * pitch_px_head +
)"
R"(                             k_idx * pitch_px_row;
)"
R"(
)"
R"(        const ulong v_row_off = batch_idx * v_nb3 + head_kv_idx * v_nb2 + k_idx * v_nb1;
)"
R"(        const global KV_DATA_TYPE4 * v_ptr = (const global KV_DATA_TYPE4 *) (v_base + v_row_off);
)"
R"(
)"
R"(        ACC_TYPE4 dot4[MQ_GQA];
)"
R"(        #pragma unroll
)"
R"(        for (int h = 0; h < MQ_GQA; ++h) dot4[h] = (ACC_TYPE4)(0.0f);
)"
R"(        for (int k = tid_sg; k < DK_VEC; k += Q1_WG_SIZE) {
)"
R"(            const half4     k_h4  = read_imageh(k_img, k_row_px + k);
)"
R"(            const ACC_TYPE4 k_vec = CONVERT_KV_ACC4(k_h4);
)"
R"(            #pragma unroll
)"
R"(            for (int h = 0; h < MQ_GQA; ++h) {
)"
R"(                dot4[h] = mad(q_shared[h * DK_VEC + k], k_vec, dot4[h]);
)"
R"(            }
)"
R"(        }
)"
R"(
)"
R"(        ACC_TYPE score[MQ_GQA];
)"
R"(        #pragma unroll
)"
R"(        for (int h = 0; h < MQ_GQA; ++h) {
)"
R"(            const ACC_TYPE dot_partial = dot4[h].s0 + dot4[h].s1 + dot4[h].s2 + dot4[h].s3;
)"
R"(            ACC_TYPE s = sub_group_reduce_add(dot_partial) * scale;
)"
R"(            if (logit_softcap > 0.0f) {
)"
R"(                s = logit_softcap * tanh(s / logit_softcap);
)"
R"(            }
)"
R"(            if (mask_base[h] != NULL) {
)"
R"(                const global MASK_DATA_TYPE * mask_ptr = (const global MASK_DATA_TYPE *) mask_base[h];
)"
R"(                s += slope[h] * (ACC_TYPE) mask_ptr[k_idx];
)"
R"(            }
)"
R"(            score[h] = s;
)"
R"(        }
)"
R"(
)"
R"(        ACC_TYPE p_h[MQ_GQA];
)"
R"(        ACC_TYPE sp_h[MQ_GQA];
)"
R"(        #pragma unroll
)"
R"(        for (int h = 0; h < MQ_GQA; ++h) {
)"
R"(            const ACC_TYPE m_new = max(m_i[h], score[h]);
)"
R"(            sp_h[h] = native_exp(m_i[h] - m_new);
)"
R"(            p_h[h]  = native_exp(score[h] - m_new);
)"
R"(            l_i[h]  = l_i[h] * sp_h[h] + p_h[h];
)"
R"(            m_i[h]  = m_new;
)"
R"(        }
)"
R"(
)"
R"(        int idx = 0;
)"
R"(        for (int dv_idx = tid_sg; dv_idx < DV_VEC; dv_idx += Q1_WG_SIZE, ++idx) {
)"
R"(            const ACC_TYPE4 v_vec = CONVERT_KV_ACC4(v_ptr[dv_idx]);
)"
R"(            #pragma unroll
)"
R"(            for (int h = 0; h < MQ_GQA; ++h) {
)"
R"(                o_acc[h][idx] = mad(p_h[h], v_vec, o_acc[h][idx] * sp_h[h]);
)"
R"(            }
)"
R"(        }
)"
R"(    }
)"
R"(
)"
R"(    __local ACC_TYPE  sg_m[MQ_GQA][MQ_NSG_SPLIT];
)"
R"(    __local ACC_TYPE  sg_l[MQ_GQA][MQ_NSG_SPLIT];
)"
R"(    __local ACC_TYPE4 sg_o[MQ_NSG_SPLIT][DV_VEC];
)"
R"(
)"
R"(    if (tid_sg == 0) {
)"
R"(        #pragma unroll
)"
R"(        for (int h = 0; h < MQ_GQA; ++h) {
)"
R"(            sg_m[h][sgid] = m_i[h];
)"
R"(            sg_l[h][sgid] = l_i[h];
)"
R"(        }
)"
R"(    }
)"
R"(
)"
R"(    #pragma unroll
)"
R"(    for (int h = 0; h < MQ_GQA; ++h) {
)"
R"(        {
)"
R"(            int idx = 0;
)"
R"(            for (int dv_idx = tid_sg; dv_idx < DV_VEC; dv_idx += Q1_WG_SIZE, ++idx) {
)"
R"(                sg_o[sgid][dv_idx] = o_acc[h][idx];
)"
R"(            }
)"
R"(        }
)"
R"(        barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(        if (sgid == 0) {
)"
R"(            const int head_idx = head_kv_idx * MQ_GQA + h;
)"
R"(
)"
R"(            ACC_TYPE m_c = sg_m[h][0];
)"
R"(            #pragma unroll
)"
R"(            for (int s = 1; s < MQ_NSG_SPLIT; ++s) {
)"
R"(                m_c = max(m_c, sg_m[h][s]);
)"
R"(            }
)"
R"(            ACC_TYPE l_c = 0.0f;
)"
R"(            #pragma unroll
)"
R"(            for (int s = 0; s < MQ_NSG_SPLIT; ++s) {
)"
R"(                l_c += sg_l[h][s] * native_exp(sg_m[h][s] - m_c);
)"
R"(            }
)"
R"(
)"
R"(            const ulong rec_idx = ((((ulong) batch_idx * n_head + head_idx) * n_q + q_idx)
)"
R"(                                   * n_splits + split_idx);
)"
R"(            global float  * rec   = partial_void + rec_idx * record_stride;
)"
R"(            global float4 * rec_o = (global float4 *) (rec + 2);
)"
R"(
)"
R"(            if (tid_sg == 0) {
)"
R"(                rec[0] = (float) m_c;
)"
R"(                rec[1] = (float) l_c;
)"
R"(            }
)"
R"(            for (int dv_idx = tid_sg; dv_idx < DV_VEC; dv_idx += Q1_WG_SIZE) {
)"
R"(                ACC_TYPE4 o_merged = (ACC_TYPE4)(0.0f);
)"
R"(                #pragma unroll
)"
R"(                for (int s = 0; s < MQ_NSG_SPLIT; ++s) {
)"
R"(                    const ACC_TYPE alpha = native_exp(sg_m[h][s] - m_c);
)"
R"(                    o_merged = mad((ACC_TYPE4)(alpha), sg_o[s][dv_idx], o_merged);
)"
R"(                }
)"
R"(                rec_o[dv_idx] = o_merged;
)"
R"(            }
)"
R"(        }
)"
R"(        barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(    }
)"
R"(}
)"
R"(#endif  // !FA_MQ_SPLIT_ONLY
)"
R"(#endif  // !FA_DECODE_ONLY
)"
R"(
)"
R"(#ifndef FA_MQ_ONLY  // q1_split + merge excluded from the MQ-only (g8) program
)"
R"(#ifndef FA_VEC_ONLY
)"
R"(__kernel void flash_attn_f32_f16_q1_split(
)"
R"(    const global void * q_void, ulong q_offset,
)"
R"(    const global void * k_void, ulong k_offset,
)"
R"(    const global void * v_void, ulong v_offset,
)"
R"(    const float scale,
)"
R"(    const int n_q,
)"
R"(    const int n_kv,
)"
R"(    const int n_head,
)"
R"(    const ulong q_nb1, const ulong q_nb2, const ulong q_nb3,
)"
R"(    const ulong k_nb1, const ulong k_nb2, const ulong k_nb3,
)"
R"(    const ulong v_nb1, const ulong v_nb2, const ulong v_nb3,
)"
R"(    const float max_bias,
)"
R"(    const float m0,
)"
R"(    const float m1,
)"
R"(    const int n_head_log2,
)"
R"(    const float logit_softcap,
)"
R"(    const int n_head_kv,
)"
R"(    const global void * mask_void,
)"
R"(    const ulong mask_offset,
)"
R"(    const ulong mask_nb1,
)"
R"(    const ulong mask_nb2,
)"
R"(    const ulong mask_nb3,
)"
R"(    const int mask_ne2,
)"
R"(    const int mask_ne3,
)"
R"(    global float * partial_void,
)"
R"(    const int n_splits,
)"
R"(    const int kv_per_split
)"
R"() {
)"
R"(    const int tid              = get_local_id(0);
)"
R"(    const int head_batch_idx   = get_global_id(1);
)"
R"(    const int split_q_idx      = get_global_id(2);
)"
R"(    const int split_idx        = split_q_idx % n_splits;
)"
R"(    const int q_idx            = split_q_idx / n_splits;
)"
R"(    const int batch_idx        = head_batch_idx / n_head;
)"
R"(    const int head_idx         = head_batch_idx % n_head;
)"
R"(    const int gqa_ratio        = n_head / n_head_kv;
)"
R"(    const int head_kv_idx      = head_idx / gqa_ratio;
)"
R"(
)"
R"(    const int kv_start = split_idx * kv_per_split;
)"
R"(    const int kv_end   = min(kv_start + kv_per_split, n_kv);
)"
R"(
)"
R"(    const ulong record_stride = (ulong) FA_PARTIAL_FLOATS;
)"
R"(    const ulong record_idx    = ((((ulong) batch_idx * n_head + head_idx) * n_q + q_idx)
)"
R"(                                 * n_splits + split_idx);
)"
R"(    global float  * rec       = partial_void + record_idx * record_stride;
)"
R"(    global float4 * rec_o     = (global float4 *) (rec + 2);
)"
R"(
)"
R"(    if (kv_start >= kv_end) {
)"
R"(        // Empty split: leave sentinel partial for merge.
)"
R"(        if (tid == 0) {
)"
R"(            rec[0] = FA_M_INIT;
)"
R"(            rec[1] = 0.0f;
)"
R"(        }
)"
R"(        return;
)"
R"(    }
)"
R"(
)"
R"(    const global char * q_base = (const global char *) q_void + q_offset;
)"
R"(    const global char * k_base = (const global char *) k_void + k_offset;
)"
R"(    const global char * v_base = (const global char *) v_void + v_offset;
)"
R"(
)"
R"(    const global char * mask_base = NULL;
)"
R"(    if (mask_void != NULL) {
)"
R"(        const int mask_head_idx  = head_idx  % mask_ne2;
)"
R"(        const int mask_batch_idx = batch_idx % mask_ne3;
)"
R"(        mask_base = (const global char *) mask_void + mask_offset +
)"
R"(                    mask_batch_idx * mask_nb3 + mask_head_idx * mask_nb2 +
)"
R"(                    (ulong) q_idx * mask_nb1;
)"
R"(    }
)"
R"(
)"
R"(    // share Q via local memory (n_q=1 per split -> uniform across WG).
)"
R"(    __local ACC_TYPE4 q_shared[DK_VEC];
)"
R"(    const ulong q_row_offset = batch_idx * q_nb3 + head_idx * q_nb2 + (ulong) q_idx * q_nb1;
)"
R"(    const global Q_DATA_TYPE4 * q_ptr = (const global Q_DATA_TYPE4 *) (q_base + q_row_offset);
)"
R"(    for (int i = tid; i < DK_VEC; i += Q1_WG_SIZE) {
)"
R"(        q_shared[i] = CONVERT_Q_ACC4(q_ptr[i]);
)"
R"(    }
)"
R"(    sub_group_barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(    const float slope = get_alibi_slope(max_bias, head_idx, n_head_log2, m0, m1);
)"
R"(
)"
R"(    // pass 1a — split-local max.
)"
R"(    ACC_TYPE m_i = FA_M_INIT;
)"
R"(    for (int k_idx = kv_start + tid; k_idx < kv_end; k_idx += Q1_WG_SIZE) {
)"
R"(        const ulong k_row_offset = batch_idx * k_nb3 + head_kv_idx * k_nb2 + k_idx * k_nb1;
)"
R"(        const global KV_DATA_TYPE4 * k_ptr = (const global KV_DATA_TYPE4 *) (k_base + k_row_offset);
)"
R"(        ACC_TYPE4 dot_acc = (ACC_TYPE4)(0.0f);
)"
R"(        #pragma unroll
)"
R"(        for (int k = 0; k < DK_VEC; ++k) {
)"
R"(            dot_acc = mad(q_shared[k], CONVERT_KV_ACC4(k_ptr[k]), dot_acc);
)"
R"(        }
)"
R"(        ACC_TYPE score = (dot_acc.s0 + dot_acc.s1 + dot_acc.s2 + dot_acc.s3) * scale;
)"
R"(        if (logit_softcap > 0.0f) {
)"
R"(            score = logit_softcap * tanh(score / logit_softcap);
)"
R"(        }
)"
R"(        if (mask_base != NULL) {
)"
R"(            const global MASK_DATA_TYPE * mask_ptr = (const global MASK_DATA_TYPE *) (mask_base);
)"
R"(            score += slope * (ACC_TYPE) mask_ptr[k_idx];
)"
R"(        }
)"
R"(        m_i = max(m_i, score);
)"
R"(    }
)"
R"(
)"
R"(    const ACC_TYPE m_c = sub_group_reduce_max(m_i);
)"
R"(
)"
R"(    // pass 1b — softmax-weighted V accumulate.
)"
R"(    ACC_TYPE4 o_acc[DV_VEC];
)"
R"(    #pragma unroll
)"
R"(    for (int i = 0; i < DV_VEC; ++i) o_acc[i] = (ACC_TYPE4)(0.0f);
)"
R"(    ACC_TYPE l_i = 0.0f;
)"
R"(
)"
R"(    for (int k_idx = kv_start + tid; k_idx < kv_end; k_idx += Q1_WG_SIZE) {
)"
R"(        const ulong k_row_offset = batch_idx * k_nb3 + head_kv_idx * k_nb2 + k_idx * k_nb1;
)"
R"(        const ulong v_row_offset = batch_idx * v_nb3 + head_kv_idx * v_nb2 + k_idx * v_nb1;
)"
R"(        const global KV_DATA_TYPE4 * k_ptr = (const global KV_DATA_TYPE4 *) (k_base + k_row_offset);
)"
R"(        const global KV_DATA_TYPE4 * v_ptr = (const global KV_DATA_TYPE4 *) (v_base + v_row_offset);
)"
R"(        ACC_TYPE4 dot_acc = (ACC_TYPE4)(0.0f);
)"
R"(        #pragma unroll
)"
R"(        for (int k = 0; k < DK_VEC; ++k) {
)"
R"(            dot_acc = mad(q_shared[k], CONVERT_KV_ACC4(k_ptr[k]), dot_acc);
)"
R"(        }
)"
R"(        ACC_TYPE score = (dot_acc.s0 + dot_acc.s1 + dot_acc.s2 + dot_acc.s3) * scale;
)"
R"(        if (logit_softcap > 0.0f) {
)"
R"(            score = logit_softcap * tanh(score / logit_softcap);
)"
R"(        }
)"
R"(        if (mask_base != NULL) {
)"
R"(            const global MASK_DATA_TYPE * mask_ptr = (const global MASK_DATA_TYPE *) (mask_base);
)"
R"(            score += slope * (ACC_TYPE) mask_ptr[k_idx];
)"
R"(        }
)"
R"(        const ACC_TYPE p = exp(score - m_c);
)"
R"(        l_i += p;
)"
R"(        #pragma unroll
)"
R"(        for (int i = 0; i < DV_VEC; ++i) {
)"
R"(            o_acc[i] = mad(p, CONVERT_KV_ACC4(v_ptr[i]), o_acc[i]);
)"
R"(        }
)"
R"(    }
)"
R"(
)"
R"(    __local ACC_TYPE4 local_o[Q1_WG_SIZE];
)"
R"(    const ACC_TYPE l_c = sub_group_reduce_add(l_i);
)"
R"(
)"
R"(    if (tid == 0) {
)"
R"(        rec[0] = (float) m_c;
)"
R"(        rec[1] = (float) l_c;
)"
R"(    }
)"
R"(    for (int i = 0; i < DV_VEC; ++i) {
)"
R"(        local_o[tid] = o_acc[i];
)"
R"(        sub_group_barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(        #pragma unroll
)"
R"(        for (int s = Q1_WG_SIZE / 2; s > 0; s >>= 1) {
)"
R"(            if (tid < s) local_o[tid] += local_o[tid + s];
)"
R"(            sub_group_barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(        }
)"
R"(        if (tid == 0) {
)"
R"(            rec_o[i] = local_o[0];
)"
R"(        }
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(#endif  // !FA_VEC_ONLY
)"
R"(
)"
R"(// FD Pass 2: merge per-split partials into final O
)"
R"(// empty splits drop via exp(-INF)=0.
)"
R"(__kernel void flash_attn_f32_merge(
)"
R"(    const global float * partial_void,
)"
R"(    global void * o_void,
)"
R"(    const ulong o_offset,
)"
R"(    const int n_head,
)"
R"(    const int n_splits,
)"
R"(    const ulong o_nb1, const ulong o_nb2, const ulong o_nb3,
)"
R"(    const global void * sinks_void,
)"
R"(    const ulong sinks_offset,
)"
R"(    const int n_q
)"
R"() {
)"
R"(    const int lane           = get_local_id(0);  // 0..DV_VEC-1
)"
R"(    const int head_batch_idx = get_global_id(1);
)"
R"(    const int q_idx          = get_global_id(2);
)"
R"(    const int batch_idx      = head_batch_idx / n_head;
)"
R"(    const int head_idx       = head_batch_idx % n_head;
)"
R"(
)"
R"(    const ulong record_stride = (ulong) FA_PARTIAL_FLOATS;
)"
R"(    const ulong record_idx_0  = (((ulong) batch_idx * n_head + head_idx) * n_q + q_idx) * n_splits;
)"
R"(    const global float * rec0 = partial_void + record_idx_0 * record_stride;
)"
R"(
)"
R"(    __local ACC_TYPE m_final_shared;
)"
R"(    __local ACC_TYPE l_final_shared;
)"
R"(    if (lane == 0) {
)"
R"(        ACC_TYPE m = FA_M_INIT;
)"
R"(        for (int c = 0; c < n_splits; ++c) {
)"
R"(            const ACC_TYPE m_c = rec0[c * record_stride + 0];
)"
R"(            m = max(m, m_c);
)"
R"(        }
)"
R"(        ACC_TYPE m_sink = 0.0f;
)"
R"(        bool has_sink = false;
)"
R"(        if (sinks_void != NULL) {
)"
R"(            const global ACC_TYPE * sinks_ptr =
)"
R"(                (const global ACC_TYPE *) ((const global char *) sinks_void + sinks_offset);
)"
R"(            m_sink = sinks_ptr[head_idx];
)"
R"(            has_sink = true;
)"
R"(            m = max(m, m_sink);
)"
R"(        }
)"
R"(        ACC_TYPE l = 0.0f;
)"
R"(        for (int c = 0; c < n_splits; ++c) {
)"
R"(            const ACC_TYPE m_c = rec0[c * record_stride + 0];
)"
R"(            const ACC_TYPE l_c = rec0[c * record_stride + 1];
)"
R"(            if (m_c > FA_M_INIT) {
)"
R"(                l += l_c * exp(m_c - m);
)"
R"(            }
)"
R"(        }
)"
R"(        if (has_sink) {
)"
R"(            l += exp(m_sink - m);
)"
R"(        }
)"
R"(        m_final_shared = m;
)"
R"(        l_final_shared = l;
)"
R"(    }
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(    const ACC_TYPE m_final = m_final_shared;
)"
R"(    const ACC_TYPE l_final = l_final_shared;
)"
R"(    const ACC_TYPE l_inv   = (l_final > 0.0f) ? (1.0f / l_final) : 0.0f;
)"
R"(
)"
R"(    ACC_TYPE4 o = (ACC_TYPE4)(0.0f);
)"
R"(    for (int c = 0; c < n_splits; ++c) {
)"
R"(        const global float * rec_c   = rec0 + c * record_stride;
)"
R"(        const ACC_TYPE       m_c     = rec_c[0];
)"
R"(        if (m_c <= FA_M_INIT) continue;
)"
R"(        const global float4 * rec_oc = (const global float4 *) (rec_c + 2);
)"
R"(        const ACC_TYPE scale_c = exp(m_c - m_final);
)"
R"(        o = mad((ACC_TYPE4)(scale_c), rec_oc[lane], o);
)"
R"(    }
)"
R"(    o = o * l_inv;
)"
R"(
)"
R"(    const ulong o_row_offset = (ulong) batch_idx * o_nb3 + (ulong) q_idx * o_nb2 + (ulong) head_idx * o_nb1;
)"
R"(    global O_DATA_TYPE4 * o_row = (global O_DATA_TYPE4 *) ((global char *) o_void + o_offset + o_row_offset);
)"
R"(    o_row[lane] = CONVERT_O_DATA4(o);
)"
R"(}
)"
R"(#endif  // !FA_MQ_ONLY (q1_split + merge)
)"
R"(#endif  // !FA_PREFILL_ONLY (decode kernels)
)"
