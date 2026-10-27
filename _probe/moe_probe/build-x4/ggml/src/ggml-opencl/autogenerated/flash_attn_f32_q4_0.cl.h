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
R"(#ifdef cl_khr_integer_dot_product
)"
R"(#pragma OPENCL EXTENSION cl_khr_integer_dot_product : enable
)"
R"(#define FA_HAVE_INT_DOT 1
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
R"(// Flash attention: Q=f32, K=q4_0, V=q4_0.
)"
R"(// Block = half d + uchar qs[16]; qs[j] low/high nibble -> elem j / j+16.
)"
R"(// Dequant: val[i] = d * (nibble_i - 8). dp4a path runs on raw 0..15 nibbles
)"
R"(// and applies the -8*sum(q) correction once per block (needs Q q_sum).
)"
R"(
)"
R"(#define ACC_TYPE float
)"
R"(#define ACC_TYPE4 float4
)"
R"(#define Q_DATA_TYPE4 float4
)"
R"(#define O_DATA_TYPE4 float4
)"
R"(#define MASK_DATA_TYPE half
)"
R"(#define CONVERT_Q_ACC4(x) (x)
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
R"(#ifndef FA_SG
)"
R"(#define FA_SG 64
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
R"(#define QK4_0 32
)"
R"(#define Q4_0_BLOCK_SIZE 18
)"
R"(
)"
R"(#define DK_Q4_BLOCKS (DK / QK4_0)
)"
R"(#define DV_Q4_BLOCKS (DV / QK4_0)
)"
R"(
)"
R"(inline float dot_q4_0_f32(const global char * block_ptr, ACC_TYPE4 * q_slice) {
)"
R"(    float d = vload_half(0, (const global half *)block_ptr);
)"
R"(    const global uchar * qs = (const global uchar *)(block_ptr + 2);
)"
R"(
)"
R"(    float sum = 0.0f;
)"
R"(    // Low nibbles -> elems 0..15.
)"
R"(    #pragma unroll
)"
R"(    for (int g = 0; g < 4; ++g) {
)"
R"(        float4 nv = (float4)((float)(int)(qs[g*4 + 0] & 0x0F) - 8.0f,
)"
R"(                             (float)(int)(qs[g*4 + 1] & 0x0F) - 8.0f,
)"
R"(                             (float)(int)(qs[g*4 + 2] & 0x0F) - 8.0f,
)"
R"(                             (float)(int)(qs[g*4 + 3] & 0x0F) - 8.0f);
)"
R"(        sum += dot(q_slice[g], nv);
)"
R"(    }
)"
R"(    // High nibbles -> elems 16..31.
)"
R"(    #pragma unroll
)"
R"(    for (int g = 0; g < 4; ++g) {
)"
R"(        float4 nv = (float4)((float)(int)(qs[g*4 + 0] >> 4) - 8.0f,
)"
R"(                             (float)(int)(qs[g*4 + 1] >> 4) - 8.0f,
)"
R"(                             (float)(int)(qs[g*4 + 2] >> 4) - 8.0f,
)"
R"(                             (float)(int)(qs[g*4 + 3] >> 4) - 8.0f);
)"
R"(        sum += dot(q_slice[4 + g], nv);
)"
R"(    }
)"
R"(    return sum * d;
)"
R"(}
)"
R"(
)"
R"(#ifdef FA_HAVE_INT_DOT
)"
R"(inline uint pack_i8x4(char a, char b, char c, char d) {
)"
R"(    return ((uint)(uchar)a)       |
)"
R"(           ((uint)(uchar)b) <<  8  |
)"
R"(           ((uint)(uchar)c) << 16  |
)"
R"(           ((uint)(uchar)d) << 24;
)"
R"(}
)"
R"(
)"
R"(// Returns (qd, q_sum); q_sum feeds the -8*sum(q) bias correction.
)"
R"(typedef struct {
)"
R"(    float qd;
)"
R"(    int   q_sum;
)"
R"(} q4_q_block_info;
)"
R"(
)"
R"(inline q4_q_block_info quant_q_block_int8_packed_q4(const ACC_TYPE4 * q_block,
)"
R"(                                                    uint *            out_packed) {
)"
R"(    float amax = 0.0f;
)"
R"(    #pragma unroll
)"
R"(    for (int i = 0; i < 8; ++i) {
)"
R"(        float4 av = fabs(q_block[i]);
)"
R"(        amax = fmax(amax, fmax(fmax(av.s0, av.s1), fmax(av.s2, av.s3)));
)"
R"(    }
)"
R"(    float qd  = amax / 127.0f;
)"
R"(    float qid = (amax > 0.0f) ? 127.0f / amax : 0.0f;
)"
R"(
)"
R"(    int q_sum = 0;
)"
R"(    #pragma unroll
)"
R"(    for (int i = 0; i < 8; ++i) {
)"
R"(        float4 v = q_block[i] * qid;
)"
R"(        char a = (char)((int)round(v.s0));
)"
R"(        char b = (char)((int)round(v.s1));
)"
R"(        char c = (char)((int)round(v.s2));
)"
R"(        char d = (char)((int)round(v.s3));
)"
R"(        out_packed[i] = pack_i8x4(a, b, c, d);
)"
R"(        q_sum += (int)a + (int)b + (int)c + (int)d;
)"
R"(    }
)"
R"(    q4_q_block_info info = { qd, q_sum };
)"
R"(    return info;
)"
R"(}
)"
R"(
)"
R"(// k_packed[0..3] = low nibbles (Q elems 0..15), k_packed[4..7] = high (16..31).
)"
R"(inline void pack_q4_0_nibbles(const global uchar * qs, uint * k_packed) {
)"
R"(    #pragma unroll
)"
R"(    for (int g = 0; g < 4; ++g) {
)"
R"(        uchar b0 = qs[g*4 + 0];
)"
R"(        uchar b1 = qs[g*4 + 1];
)"
R"(        uchar b2 = qs[g*4 + 2];
)"
R"(        uchar b3 = qs[g*4 + 3];
)"
R"(        k_packed[g] =
)"
R"(              ((uint)(b0 & 0x0F))       |
)"
R"(              ((uint)(b1 & 0x0F)) <<  8 |
)"
R"(              ((uint)(b2 & 0x0F)) << 16 |
)"
R"(              ((uint)(b3 & 0x0F)) << 24;
)"
R"(        k_packed[4 + g] =
)"
R"(              ((uint)(b0 >> 4))         |
)"
R"(              ((uint)(b1 >> 4)) <<  8   |
)"
R"(              ((uint)(b2 >> 4)) << 16   |
)"
R"(              ((uint)(b3 >> 4)) << 24;
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(inline float dot_q4_0_int(const global char * k_block_ptr,
)"
R"(                          const uint *        q_packed,
)"
R"(                          float               q_d,
)"
R"(                          int                 q_sum) {
)"
R"(    float kd = vload_half(0, (const global half *)k_block_ptr);
)"
R"(    const global uchar * k_qs = (const global uchar *)(k_block_ptr + 2);
)"
R"(
)"
R"(    uint k_packed[8];
)"
R"(    pack_q4_0_nibbles(k_qs, k_packed);
)"
R"(
)"
R"(    int sum = 0;
)"
R"(    #pragma unroll
)"
R"(    for (int i = 0; i < 8; ++i) {
)"
R"(        sum = dot_acc_sat_4x8packed_ss_int(q_packed[i], k_packed[i], sum);
)"
R"(    }
)"
R"(    // Correct raw-nibble sum: (nibble - 8) bias -> subtract 8 * q_sum.
)"
R"(    return (float)(sum - 8 * q_sum) * q_d * kd;
)"
R"(}
)"
R"(#endif // FA_HAVE_INT_DOT
)"
R"(
)"
R"(inline void dequant_q4_0_f32(const global char * block_ptr, ACC_TYPE4 * out) {
)"
R"(    float d = vload_half(0, (const global half *)block_ptr);
)"
R"(    const global uchar * qs = (const global uchar *)(block_ptr + 2);
)"
R"(
)"
R"(    #pragma unroll
)"
R"(    for (int g = 0; g < 4; ++g) {
)"
R"(        out[g] = d * (float4)((float)(int)(qs[g*4 + 0] & 0x0F) - 8.0f,
)"
R"(                              (float)(int)(qs[g*4 + 1] & 0x0F) - 8.0f,
)"
R"(                              (float)(int)(qs[g*4 + 2] & 0x0F) - 8.0f,
)"
R"(                              (float)(int)(qs[g*4 + 3] & 0x0F) - 8.0f);
)"
R"(    }
)"
R"(    #pragma unroll
)"
R"(    for (int g = 0; g < 4; ++g) {
)"
R"(        out[4 + g] = d * (float4)((float)(int)(qs[g*4 + 0] >> 4) - 8.0f,
)"
R"(                                  (float)(int)(qs[g*4 + 1] >> 4) - 8.0f,
)"
R"(                                  (float)(int)(qs[g*4 + 2] >> 4) - 8.0f,
)"
R"(                                  (float)(int)(qs[g*4 + 3] >> 4) - 8.0f);
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(// max_bias<=0 returns 1.0 so score += 1.0 * mask[k] stays a no-op multiplier.
)"
R"(inline float get_alibi_slope(float max_bias, int head_idx, int n_head_log2, float m0, float m1) {
)"
R"(    if (max_bias <= 0.0f) return 1.0f;
)"
R"(    float base = (head_idx < n_head_log2) ? m0 : m1;
)"
R"(    int   exph = (head_idx < n_head_log2) ? (head_idx + 1) : (2*(head_idx - n_head_log2) + 1);
)"
R"(    return pow(base, (float)exph);
)"
R"(}
)"
R"(
)"
R"(// q1 decode: one query row per WG, threads sweep KV positions.
)"
R"(__kernel void flash_attn_f32_q4_0_q1(
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
R"(    const global char* k_base = (const global char*)k_void + k_offset;
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
R"(    ACC_TYPE4 q_priv[DK_VEC];
)"
R"(    const ulong q_row_offset = batch_idx * q_nb3 + head_idx * q_nb2;
)"
R"(    const global Q_DATA_TYPE4* q_ptr = (const global Q_DATA_TYPE4*)(q_base + q_row_offset);
)"
R"(    #pragma unroll
)"
R"(    for (int i = 0; i < DK_VEC; ++i) {
)"
R"(        q_priv[i] = CONVERT_Q_ACC4(q_ptr[i]);
)"
R"(    }
)"
R"(
)"
R"(#ifdef FA_HAVE_INT_DOT
)"
R"(    // Quantise Q once per thread: 8 uints + qd + q_sum per block.
)"
R"(    uint  q_packed[DK_Q4_BLOCKS * 8];
)"
R"(    float q_d_scale[DK_Q4_BLOCKS];
)"
R"(    int   q_sum_arr[DK_Q4_BLOCKS];
)"
R"(    #pragma unroll
)"
R"(    for (int b = 0; b < DK_Q4_BLOCKS; ++b) {
)"
R"(        q4_q_block_info info = quant_q_block_int8_packed_q4(&q_priv[b * 8], &q_packed[b * 8]);
)"
R"(        q_d_scale[b] = info.qd;
)"
R"(        q_sum_arr[b] = info.q_sum;
)"
R"(    }
)"
R"(#endif
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
R"(    // One-pass online softmax (FA-2): single sweep over kv positions,
)"
R"(    // updating per-thread (m_i, l_i, o_acc) per K. Eliminates the second
)"
R"(    // K read of the original two-pass implementation.
)"
R"(    ACC_TYPE m_i = (sinks_ptr != NULL) ? sinks_ptr[head_idx] : FA_M_INIT;
)"
R"(    ACC_TYPE l_i = 0.0f;
)"
R"(    ACC_TYPE4 o_acc[DV_VEC];
)"
R"(    #pragma unroll
)"
R"(    for (int i = 0; i < DV_VEC; ++i) o_acc[i] = (ACC_TYPE4)(0.0f);
)"
R"(
)"
R"(    for (int k_idx = tid; k_idx < n_kv; k_idx += Q1_WG_SIZE) {
)"
R"(        const global char* k_row = k_base + batch_idx * k_nb3 + head_kv_idx * k_nb2 + k_idx * k_nb1;
)"
R"(        const global char* v_row = v_base + batch_idx * v_nb3 + head_kv_idx * v_nb2 + k_idx * v_nb1;
)"
R"(
)"
R"(        ACC_TYPE score = 0.0f;
)"
R"(        #pragma unroll
)"
R"(        for (int b = 0; b < DK_Q4_BLOCKS; b++) {
)"
R"(#ifdef FA_HAVE_INT_DOT
)"
R"(            score += dot_q4_0_int(k_row + b * Q4_0_BLOCK_SIZE,
)"
R"(                                   &q_packed[b * 8], q_d_scale[b], q_sum_arr[b]);
)"
R"(#else
)"
R"(            score += dot_q4_0_f32(k_row + b * Q4_0_BLOCK_SIZE, &q_priv[b * 8]);
)"
R"(#endif
)"
R"(        }
)"
R"(        score *= scale;
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
R"(            const global MASK_DATA_TYPE* mask_ptr = (const global MASK_DATA_TYPE*)(mask_base);
)"
R"(            score += slope * (ACC_TYPE)mask_ptr[k_idx];
)"
R"(        }
)"
R"(
)"
R"(        // Online softmax step.
)"
R"(        const ACC_TYPE m_new = max(m_i, score);
)"
R"(        const ACC_TYPE alpha = exp(m_i  - m_new);
)"
R"(        const ACC_TYPE p     = exp(score - m_new);
)"
R"(
)"
R"(        l_i = alpha * l_i + p;
)"
R"(        #pragma unroll
)"
R"(        for (int i = 0; i < DV_VEC; ++i) o_acc[i] *= alpha;
)"
R"(
)"
R"(        #pragma unroll
)"
R"(        for (int b = 0; b < DV_Q4_BLOCKS; b++) {
)"
R"(            ACC_TYPE4 v_dequant[8];
)"
R"(            dequant_q4_0_f32(v_row + b * Q4_0_BLOCK_SIZE, v_dequant);
)"
R"(            #pragma unroll
)"
R"(            for (int i = 0; i < 8; i++) {
)"
R"(                o_acc[b * 8 + i] = mad(p, v_dequant[i], o_acc[b * 8 + i]);
)"
R"(            }
)"
R"(        }
)"
R"(
)"
R"(        m_i = m_new;
)"
R"(    }
)"
R"(
)"
R"(    // Cross-thread reduce: max(m_i) -> m_final, rescale per-thread l_i and
)"
R"(    // o_acc by alpha = exp(m_i_thread - m_final) before sum-reduce.
)"
R"(    __local ACC_TYPE local_m[Q1_WG_SIZE];
)"
R"(    local_m[tid] = m_i;
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(    #pragma unroll
)"
R"(    for (int s = Q1_WG_SIZE / 2; s > 0; s >>= 1) {
)"
R"(        if (tid < s) local_m[tid] = max(local_m[tid], local_m[tid + s]);
)"
R"(        barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(    }
)"
R"(    const ACC_TYPE m_final = local_m[0];
)"
R"(
)"
R"(    const ACC_TYPE alpha_final = exp(m_i - m_final);
)"
R"(    l_i *= alpha_final;
)"
R"(    #pragma unroll
)"
R"(    for (int i = 0; i < DV_VEC; ++i) o_acc[i] *= alpha_final;
)"
R"(
)"
R"(    __local ACC_TYPE local_l[Q1_WG_SIZE];
)"
R"(    __local ACC_TYPE4 local_o_comp[Q1_WG_SIZE];
)"
R"(    local_l[tid] = l_i;
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(    #pragma unroll
)"
R"(    for (int s = Q1_WG_SIZE / 2; s > 0; s >>= 1) {
)"
R"(        if (tid < s) local_l[tid] += local_l[tid + s];
)"
R"(        barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(    }
)"
R"(
)"
R"(    const ulong o_row_offset = batch_idx * o_nb3 + head_idx * o_nb1;
)"
R"(    global O_DATA_TYPE4 *o_row = (global O_DATA_TYPE4 *)(o_base + o_row_offset);
)"
R"(    ACC_TYPE l_final = local_l[0];
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
R"(            barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(            #pragma unroll
)"
R"(            for (int s = Q1_WG_SIZE / 2; s > 0; s >>= 1) {
)"
R"(                if (tid < s) local_o_comp[tid] += local_o_comp[tid + s];
)"
R"(                barrier(CLK_LOCAL_MEM_FENCE);
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
R"(        #pragma unroll
)"
R"(        for (int i = 0; i < DV_VEC; ++i) o_row[i] = (O_DATA_TYPE4)(0.0f);
)"
R"(    }
)"
R"(}
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
R"(#define VEC_NSG          4
)"
R"(#define VEC_WG_SIZE      (Q1_WG_SIZE * VEC_NSG)
)"
R"(#define Q1V_DV_PER_THREAD ((DV_VEC + Q1_WG_SIZE - 1) / Q1_WG_SIZE)
)"
R"(
)"
R"(// Dequant one float4 lane (0..7) from a q4_0 block.
)"
R"(// Lanes 0..3 → low nibbles of qs[0..15], lanes 4..7 → high nibbles.
)"
R"(inline float4 dequant_q4_0_lane(const global char * block_ptr, int lane) {
)"
R"(    const float d = vload_half(0, (const global half *)block_ptr);
)"
R"(    const global uchar * qs = (const global uchar *)(block_ptr + 2);
)"
R"(    const int g     = lane & 3;
)"
R"(    const int shift = (lane < 4) ? 0 : 4;
)"
R"(    return d * (float4)((float)((qs[g*4+0] >> shift) & 0x0F) - 8.0f,
)"
R"(                        (float)((qs[g*4+1] >> shift) & 0x0F) - 8.0f,
)"
R"(                        (float)((qs[g*4+2] >> shift) & 0x0F) - 8.0f,
)"
R"(                        (float)((qs[g*4+3] >> shift) & 0x0F) - 8.0f);
)"
R"(}
)"
R"(
)"
R"(REQD_SUBGROUP_SIZE_64
)"
R"(__kernel void flash_attn_f32_q4_0_q1_vec(
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
R"(    const int sgid            = tid / Q1_WG_SIZE;
)"
R"(    const int tid_sg          = tid % Q1_WG_SIZE;
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
R"(#ifdef FA_HAVE_INT_DOT
)"
R"(    // quantize Q to int8-packed uints + per-block (qd, q_sum) once per WG for dp4a
)"
R"(    // one thread per Q block, remaining threads idle this step
)"
R"(    __local uint  q_packed_shared[DK_Q4_BLOCKS * 8];
)"
R"(    __local float q_d_shared[DK_Q4_BLOCKS];
)"
R"(    __local int   q_sum_shared[DK_Q4_BLOCKS];
)"
R"(    if (tid < DK_Q4_BLOCKS) {
)"
R"(        ACC_TYPE4 q_block[8];
)"
R"(        #pragma unroll
)"
R"(        for (int i = 0; i < 8; ++i) q_block[i] = q_shared[tid * 8 + i];
)"
R"(        uint packed[8];
)"
R"(        q4_q_block_info info = quant_q_block_int8_packed_q4(q_block, packed);
)"
R"(        #pragma unroll
)"
R"(        for (int i = 0; i < 8; ++i) q_packed_shared[tid * 8 + i] = packed[i];
)"
R"(        q_d_shared[tid]   = info.qd;
)"
R"(        q_sum_shared[tid] = info.q_sum;
)"
R"(    }
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(#endif
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
R"(    ACC_TYPE4 o_acc[Q1V_DV_PER_THREAD];
)"
R"(    #pragma unroll
)"
R"(    for (int i = 0; i < Q1V_DV_PER_THREAD; ++i) o_acc[i] = (ACC_TYPE4)(0.0f);
)"
R"(
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
R"(        const global char * k_row = k_base + batch_idx * k_nb3 + head_kv_idx * k_nb2 + k_idx * k_nb1;
)"
R"(        const global char * v_row = v_base + batch_idx * v_nb3 + head_kv_idx * v_nb2 + k_idx * v_nb1;
)"
R"(
)"
R"(#ifdef FA_HAVE_INT_DOT
)"
R"(        // per-lane dp4a: each lane packs 4 raw q4_0 nibbles into a uint,
)"
R"(        // then dot_acc_sat_4x8packed_ss_int against the matching uint.
)"
R"(        ACC_TYPE lane_contrib = 0.0f;
)"
R"(        for (int qk = tid_sg; qk < DK_VEC; qk += Q1_WG_SIZE) {
)"
R"(            const int block_idx     = qk / 8;
)"
R"(            const int lane_in_block = qk % 8;
)"
R"(            const int g             = lane_in_block & 3;
)"
R"(            const int shift         = (lane_in_block < 4) ? 0 : 4;
)"
R"(            const global char *  k_block = k_row + block_idx * Q4_0_BLOCK_SIZE;
)"
R"(            const float kd = vload_half(0, (const global half *)k_block);
)"
R"(            const global uchar * k_qs = (const global uchar *)(k_block + 2);
)"
R"(            const uchar b0 = k_qs[g*4 + 0];
)"
R"(            const uchar b1 = k_qs[g*4 + 1];
)"
R"(            const uchar b2 = k_qs[g*4 + 2];
)"
R"(            const uchar b3 = k_qs[g*4 + 3];
)"
R"(            const uint k_packed = ((uint)((b0 >> shift) & 0x0F))       |
)"
R"(                                  ((uint)((b1 >> shift) & 0x0F)) <<  8 |
)"
R"(                                  ((uint)((b2 >> shift) & 0x0F)) << 16 |
)"
R"(                                  ((uint)((b3 >> shift) & 0x0F)) << 24;
)"
R"(            const uint q_packed_lane = q_packed_shared[block_idx * 8 + lane_in_block];
)"
R"(            const int  raw_dot = dot_acc_sat_4x8packed_ss_int(q_packed_lane, k_packed, 0);
)"
R"(            const float qd          = q_d_shared[block_idx];
)"
R"(            const float block_scale = qd * kd;
)"
R"(            float contrib = (float)raw_dot * block_scale;
)"
R"(            if (lane_in_block == 0) {
)"
R"(                // block bias correction is per-block
)"
R"(                const int q_sum_b = q_sum_shared[block_idx];
)"
R"(                contrib -= 8.0f * block_scale * (float)q_sum_b;
)"
R"(            }
)"
R"(            lane_contrib += contrib;
)"
R"(        }
)"
R"(        ACC_TYPE score = sub_group_reduce_add(lane_contrib) * scale;
)"
R"(#else
)"
R"(        ACC_TYPE4 dot4 = (ACC_TYPE4)(0.0f);
)"
R"(        for (int qk = tid_sg; qk < DK_VEC; qk += Q1_WG_SIZE) {
)"
R"(            const int block_idx = qk / 8;
)"
R"(            const int lane      = qk % 8;
)"
R"(            const float4 k_v = dequant_q4_0_lane(k_row + block_idx * Q4_0_BLOCK_SIZE, lane);
)"
R"(            dot4 = mad(q_shared[qk], k_v, dot4);
)"
R"(        }
)"
R"(        ACC_TYPE dot_partial = dot4.s0 + dot4.s1 + dot4.s2 + dot4.s3;
)"
R"(        ACC_TYPE score = sub_group_reduce_add(dot_partial) * scale;
)"
R"(#endif
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
R"(        for (int dv = tid_sg; dv < DV_VEC; dv += Q1_WG_SIZE, ++idx) {
)"
R"(            const int block_idx = dv / 8;
)"
R"(            const int lane      = dv % 8;
)"
R"(            const float4 v_v = dequant_q4_0_lane(v_row + block_idx * Q4_0_BLOCK_SIZE, lane);
)"
R"(            o_acc[idx] = mad(p, v_v, o_acc[idx] * scale_prev);
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
R"(        for (int dv = tid_sg; dv < DV_VEC; dv += Q1_WG_SIZE, ++idx) {
)"
R"(            sg_o[sgid][dv] = o_acc[idx];
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
R"(        int idx = 0;
)"
R"(        for (int dv = tid_sg; dv < DV_VEC; dv += Q1_WG_SIZE, ++idx) {
)"
R"(            ACC_TYPE4 o_merged = (ACC_TYPE4)(0.0f);
)"
R"(            #pragma unroll
)"
R"(            for (int s = 0; s < VEC_NSG; ++s) {
)"
R"(                const ACC_TYPE alpha = native_exp(sg_m[s] - m_final);
)"
R"(                o_merged = mad((ACC_TYPE4)(alpha), sg_o[s][dv], o_merged);
)"
R"(            }
)"
R"(            o_row[dv] = CONVERT_O_DATA4(o_merged * l_inv);
)"
R"(        }
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(// Flash-decoding split pass for q4_0 KV. Merge kernel is type-agnostic and
)"
R"(// shared with the f16/q8_0 FA kernels.
)"
R"(#define FA_PARTIAL_FLOATS (2 + DV)
)"
R"(
)"
R"(__kernel void flash_attn_f32_q4_0_q1_split(
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
R"(    const int tid            = get_local_id(0);
)"
R"(    const int head_batch_idx = get_global_id(1);
)"
R"(    const int split_q_idx    = get_global_id(2);
)"
R"(    const int split_idx      = split_q_idx % n_splits;
)"
R"(    const int q_idx          = split_q_idx / n_splits;
)"
R"(    const int batch_idx      = head_batch_idx / n_head;
)"
R"(    const int head_idx       = head_batch_idx % n_head;
)"
R"(    const int gqa_ratio      = n_head / n_head_kv;
)"
R"(    const int head_kv_idx    = head_idx / gqa_ratio;
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
R"(    ACC_TYPE4 q_priv[DK_VEC];
)"
R"(    const ulong q_row_offset = batch_idx * q_nb3 + head_idx * q_nb2 + (ulong) q_idx * q_nb1;
)"
R"(    const global Q_DATA_TYPE4 * q_ptr = (const global Q_DATA_TYPE4 *) (q_base + q_row_offset);
)"
R"(    #pragma unroll
)"
R"(    for (int i = 0; i < DK_VEC; ++i) {
)"
R"(        q_priv[i] = CONVERT_Q_ACC4(q_ptr[i]);
)"
R"(    }
)"
R"(
)"
R"(#ifdef FA_HAVE_INT_DOT
)"
R"(    uint  q_packed[DK_Q4_BLOCKS * 8];
)"
R"(    float q_d_scale[DK_Q4_BLOCKS];
)"
R"(    int   q_sum_arr[DK_Q4_BLOCKS];
)"
R"(    #pragma unroll
)"
R"(    for (int b = 0; b < DK_Q4_BLOCKS; ++b) {
)"
R"(        q4_q_block_info info = quant_q_block_int8_packed_q4(&q_priv[b * 8], &q_packed[b * 8]);
)"
R"(        q_d_scale[b] = info.qd;
)"
R"(        q_sum_arr[b] = info.q_sum;
)"
R"(    }
)"
R"(#endif
)"
R"(
)"
R"(    const float slope = get_alibi_slope(max_bias, head_idx, n_head_log2, m0, m1);
)"
R"(
)"
R"(    // One-pass online softmax (FA-2): single sweep over the split's K range.
)"
R"(    ACC_TYPE m_i = FA_M_INIT;
)"
R"(    ACC_TYPE l_i = 0.0f;
)"
R"(    ACC_TYPE4 o_acc[DV_VEC];
)"
R"(    #pragma unroll
)"
R"(    for (int i = 0; i < DV_VEC; ++i) o_acc[i] = (ACC_TYPE4)(0.0f);
)"
R"(
)"
R"(    for (int k_idx = kv_start + tid; k_idx < kv_end; k_idx += Q1_WG_SIZE) {
)"
R"(        const global char * k_row = k_base + batch_idx * k_nb3 + head_kv_idx * k_nb2 + k_idx * k_nb1;
)"
R"(        const global char * v_row = v_base + batch_idx * v_nb3 + head_kv_idx * v_nb2 + k_idx * v_nb1;
)"
R"(        ACC_TYPE score = 0.0f;
)"
R"(        #pragma unroll
)"
R"(        for (int b = 0; b < DK_Q4_BLOCKS; ++b) {
)"
R"(#ifdef FA_HAVE_INT_DOT
)"
R"(            score += dot_q4_0_int(k_row + b * Q4_0_BLOCK_SIZE,
)"
R"(                                   &q_packed[b * 8], q_d_scale[b], q_sum_arr[b]);
)"
R"(#else
)"
R"(            score += dot_q4_0_f32(k_row + b * Q4_0_BLOCK_SIZE, &q_priv[b * 8]);
)"
R"(#endif
)"
R"(        }
)"
R"(        score *= scale;
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
R"(
)"
R"(        // Online softmax step.
)"
R"(        const ACC_TYPE m_new = max(m_i, score);
)"
R"(        const ACC_TYPE alpha = exp(m_i  - m_new);
)"
R"(        const ACC_TYPE p     = exp(score - m_new);
)"
R"(
)"
R"(        l_i = alpha * l_i + p;
)"
R"(        #pragma unroll
)"
R"(        for (int i = 0; i < DV_VEC; ++i) o_acc[i] *= alpha;
)"
R"(
)"
R"(        #pragma unroll
)"
R"(        for (int b = 0; b < DV_Q4_BLOCKS; ++b) {
)"
R"(            ACC_TYPE4 v_dequant[8];
)"
R"(            dequant_q4_0_f32(v_row + b * Q4_0_BLOCK_SIZE, v_dequant);
)"
R"(            #pragma unroll
)"
R"(            for (int i = 0; i < 8; ++i) {
)"
R"(                o_acc[b * 8 + i] = mad(p, v_dequant[i], o_acc[b * 8 + i]);
)"
R"(            }
)"
R"(        }
)"
R"(
)"
R"(        m_i = m_new;
)"
R"(    }
)"
R"(
)"
R"(    // Cross-thread reduce: max(m_i) -> m_c, rescale per-thread l_i and o_acc
)"
R"(    // by alpha = exp(m_i_thread - m_c) before sum-reduce.
)"
R"(    __local ACC_TYPE local_m[Q1_WG_SIZE];
)"
R"(    local_m[tid] = m_i;
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(    #pragma unroll
)"
R"(    for (int s = Q1_WG_SIZE / 2; s > 0; s >>= 1) {
)"
R"(        if (tid < s) local_m[tid] = max(local_m[tid], local_m[tid + s]);
)"
R"(        barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(    }
)"
R"(    const ACC_TYPE m_c = local_m[0];
)"
R"(
)"
R"(    const ACC_TYPE alpha_final = exp(m_i - m_c);
)"
R"(    l_i *= alpha_final;
)"
R"(    #pragma unroll
)"
R"(    for (int i = 0; i < DV_VEC; ++i) o_acc[i] *= alpha_final;
)"
R"(
)"
R"(    __local ACC_TYPE  local_l[Q1_WG_SIZE];
)"
R"(    __local ACC_TYPE4 local_o[Q1_WG_SIZE];
)"
R"(    local_l[tid] = l_i;
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(    #pragma unroll
)"
R"(    for (int s = Q1_WG_SIZE / 2; s > 0; s >>= 1) {
)"
R"(        if (tid < s) local_l[tid] += local_l[tid + s];
)"
R"(        barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(    }
)"
R"(    const ACC_TYPE l_c = local_l[0];
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
R"(        barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(        #pragma unroll
)"
R"(        for (int s = Q1_WG_SIZE / 2; s > 0; s >>= 1) {
)"
R"(            if (tid < s) local_o[tid] += local_o[tid + s];
)"
R"(            barrier(CLK_LOCAL_MEM_FENCE);
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
R"(// Prefill: q4_0 K/V, n_q > 1. BLOCK_M × BLOCK_N tiling.
)"
R"(// K in local as packed nibbles + per-block scale; V dequant -> half in local.
)"
R"(// Requires DK % QK4_0 == 0 and DV % QK4_0 == 0.
)"
R"(#define KV_DATA_TYPE4 half4
)"
R"(#define CONVERT_KV_ACC4(x) convert_float4(x)
)"
R"(
)"
R"(#define DK_Q4_BLOCKS_PREFILL (DK / QK4_0)
)"
R"(#define DV_Q4_BLOCKS_PREFILL (DV / QK4_0)
)"
R"(
)"
R"(// N_SPLIT>1 splits DK/DV across N_SPLIT threads per query row; needs
)"
R"(// sub_group_shuffle_xor and DK_Q4_BLOCKS_PREFILL % N_SPLIT == 0.
)"
R"(#ifndef N_SPLIT
)"
R"(#define N_SPLIT 1
)"
R"(#endif
)"
R"(
)"
R"(#if N_SPLIT > 1
)"
R"(#define SPLIT_DK_VEC        (DK_VEC / N_SPLIT)
)"
R"(#define SPLIT_DV_VEC        (DV_VEC / N_SPLIT)
)"
R"(#define SPLIT_DK_Q4_BLOCKS  (DK_Q4_BLOCKS_PREFILL / N_SPLIT)
)"
R"(#define WG_SIZE             (BLOCK_M * N_SPLIT)
)"
R"(#else
)"
R"(#define SPLIT_DK_VEC        DK_VEC
)"
R"(#define SPLIT_DV_VEC        DV_VEC
)"
R"(#define SPLIT_DK_Q4_BLOCKS  DK_Q4_BLOCKS_PREFILL
)"
R"(#define WG_SIZE             BLOCK_M
)"
R"(#endif
)"
R"(
)"
R"(#ifndef MQ_GQA
)"
R"(#define MQ_GQA 4
)"
R"(#endif
)"
R"(#ifndef MQ_NSG_SPLIT
)"
R"(#define MQ_NSG_SPLIT 4
)"
R"(#endif
)"
R"(#define MQ_SPLIT_WG_SIZE_Q4 (Q1_WG_SIZE * MQ_NSG_SPLIT)
)"
R"(
)"
R"(REQD_SUBGROUP_SIZE_64
)"
R"(__kernel void flash_attn_f32_q4_0_q1_vec_mq_split(
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
R"(    const global char * k_base = (const global char *) k_void + k_offset;
)"
R"(    const global char * v_base = (const global char *) v_void + v_offset;
)"
R"(
)"
R"(    __local ACC_TYPE4 q_shared[MQ_GQA * DK_VEC];
)"
R"(    for (int i = tid; i < MQ_GQA * DK_VEC; i += MQ_SPLIT_WG_SIZE_Q4) {
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
R"(#ifdef FA_HAVE_INT_DOT
)"
R"(    __local uint  q_packed_shared[MQ_GQA * DK_Q4_BLOCKS * 8];
)"
R"(    __local float q_d_shared[MQ_GQA * DK_Q4_BLOCKS];
)"
R"(    __local int   q_sum_shared[MQ_GQA * DK_Q4_BLOCKS];
)"
R"(    {
)"
R"(        const int active = MQ_GQA * DK_Q4_BLOCKS;
)"
R"(        if (tid < active) {
)"
R"(            const int h        = tid / DK_Q4_BLOCKS;
)"
R"(            const int block_id = tid % DK_Q4_BLOCKS;
)"
R"(            ACC_TYPE4 q_block[8];
)"
R"(            #pragma unroll
)"
R"(            for (int i = 0; i < 8; ++i) q_block[i] = q_shared[h * DK_VEC + block_id * 8 + i];
)"
R"(            uint packed[8];
)"
R"(            q4_q_block_info info = quant_q_block_int8_packed_q4(q_block, packed);
)"
R"(            #pragma unroll
)"
R"(            for (int i = 0; i < 8; ++i) q_packed_shared[(h * DK_Q4_BLOCKS + block_id) * 8 + i] = packed[i];
)"
R"(            q_d_shared[h * DK_Q4_BLOCKS + block_id]   = info.qd;
)"
R"(            q_sum_shared[h * DK_Q4_BLOCKS + block_id] = info.q_sum;
)"
R"(        }
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
R"(        const global char * k_row = k_base + batch_idx * k_nb3 + head_kv_idx * k_nb2 + k_idx * k_nb1;
)"
R"(        const global char * v_row = v_base + batch_idx * v_nb3 + head_kv_idx * v_nb2 + k_idx * v_nb1;
)"
R"(
)"
R"(#ifdef FA_HAVE_INT_DOT
)"
R"(        ACC_TYPE lane_contrib[MQ_GQA];
)"
R"(        #pragma unroll
)"
R"(        for (int h = 0; h < MQ_GQA; ++h) lane_contrib[h] = 0.0f;
)"
R"(
)"
R"(        for (int qk = tid_sg; qk < DK_VEC; qk += Q1_WG_SIZE) {
)"
R"(            const int block_idx     = qk / 8;
)"
R"(            const int lane_in_block = qk % 8;
)"
R"(            const int g             = lane_in_block & 3;
)"
R"(            const int shift         = (lane_in_block < 4) ? 0 : 4;
)"
R"(            const global char *  k_block = k_row + block_idx * Q4_0_BLOCK_SIZE;
)"
R"(            const float kd = vload_half(0, (const global half *)k_block);
)"
R"(            const global uchar * k_qs = (const global uchar *)(k_block + 2);
)"
R"(            const uchar b0 = k_qs[g*4 + 0];
)"
R"(            const uchar b1 = k_qs[g*4 + 1];
)"
R"(            const uchar b2 = k_qs[g*4 + 2];
)"
R"(            const uchar b3 = k_qs[g*4 + 3];
)"
R"(            const uint k_packed = ((uint)((b0 >> shift) & 0x0F))       |
)"
R"(                                  ((uint)((b1 >> shift) & 0x0F)) <<  8 |
)"
R"(                                  ((uint)((b2 >> shift) & 0x0F)) << 16 |
)"
R"(                                  ((uint)((b3 >> shift) & 0x0F)) << 24;
)"
R"(            #pragma unroll
)"
R"(            for (int h = 0; h < MQ_GQA; ++h) {
)"
R"(                const uint  q_packed_lane = q_packed_shared[(h * DK_Q4_BLOCKS + block_idx) * 8 + lane_in_block];
)"
R"(                const int   raw_dot       = dot_acc_sat_4x8packed_ss_int(q_packed_lane, k_packed, 0);
)"
R"(                const float qd            = q_d_shared[h * DK_Q4_BLOCKS + block_idx];
)"
R"(                const float block_scale   = qd * kd;
)"
R"(                float contrib = (float) raw_dot * block_scale;
)"
R"(                if (lane_in_block == 0) {
)"
R"(                    const int q_sum_b = q_sum_shared[h * DK_Q4_BLOCKS + block_idx];
)"
R"(                    contrib -= 8.0f * block_scale * (float) q_sum_b;
)"
R"(                }
)"
R"(                lane_contrib[h] += contrib;
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
R"(            ACC_TYPE s = sub_group_reduce_add(lane_contrib[h]) * scale;
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
R"(#else
)"
R"(        // fallback float-dequant K dot
)"
R"(        ACC_TYPE4 dot4[MQ_GQA];
)"
R"(        #pragma unroll
)"
R"(        for (int h = 0; h < MQ_GQA; ++h) dot4[h] = (ACC_TYPE4)(0.0f);
)"
R"(
)"
R"(        for (int qk = tid_sg; qk < DK_VEC; qk += Q1_WG_SIZE) {
)"
R"(            const int block_idx = qk / 8;
)"
R"(            const int lane      = qk % 8;
)"
R"(            const float4 k_v = dequant_q4_0_lane(k_row + block_idx * Q4_0_BLOCK_SIZE, lane);
)"
R"(            #pragma unroll
)"
R"(            for (int h = 0; h < MQ_GQA; ++h) {
)"
R"(                dot4[h] = mad(q_shared[h * DK_VEC + qk], k_v, dot4[h]);
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
R"(#endif
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
R"(        for (int dv = tid_sg; dv < DV_VEC; dv += Q1_WG_SIZE, ++idx) {
)"
R"(            const int block_idx = dv / 8;
)"
R"(            const int lane      = dv % 8;
)"
R"(            const float4 v_v = dequant_q4_0_lane(v_row + block_idx * Q4_0_BLOCK_SIZE, lane);
)"
R"(            #pragma unroll
)"
R"(            for (int h = 0; h < MQ_GQA; ++h) {
)"
R"(                o_acc[h][idx] = mad(p_h[h], v_v, o_acc[h][idx] * sp_h[h]);
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
R"(
)"
R"(// flash_attn_f32_q4_0_q1_vec_mq_split_c8 — cluster-parallel variant of the MQ
)"
R"(// split, port of flash_attn_f32_f16_q1_vec_mq_split_c8
)"
R"(// Requires dp4a + subgroup shuffles
)"
R"(
)"
R"(#if defined(FA_HAVE_INT_DOT) && defined(HAS_SUBGROUP_SHUFFLE)
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
R"(// Lane striping requires DK/DV to divide across the cluster (see f16 c8).
)"
R"(#if (DK_VEC % FA_CL_C) == 0 && (DV_VEC % FA_CL_C) == 0
)"
R"(#define FA_CL_NCL  (Q1_WG_SIZE / FA_CL_C)   // clusters (position streams) per subgroup
)"
R"(#define FA_CL_DKQ  (DK_VEC / FA_CL_C)       // K quartets per lane per row
)"
R"(#define FA_CL_DVQ  (DV_VEC / FA_CL_C)       // V quartets (o_acc float4s) per lane per head
)"
R"(
)"
R"(#ifdef FA_C8_NO_SG_PIN
)"
R"(#define FA_C8_SG_ATTR_Q4
)"
R"(#else
)"
R"(#define FA_C8_SG_ATTR_Q4 REQD_SUBGROUP_SIZE_64
)"
R"(#endif
)"
R"(
)"
R"(FA_C8_SG_ATTR_Q4
)"
R"(__kernel void flash_attn_f32_q4_0_q1_vec_mq_split_c8(
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
R"(    const global char * k_base = (const global char *) k_void + k_offset;
)"
R"(    const global char * v_base = (const global char *) v_void + v_offset;
)"
R"(
)"
R"(    // Stage MQ_GQA Q rows in __local as float4 (source for the quantize pass).
)"
R"(    __local ACC_TYPE4 q_shared[MQ_GQA * DK_VEC];
)"
R"(    for (int i = tid; i < MQ_GQA * DK_VEC; i += MQ_SPLIT_WG_SIZE_Q4) {
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
R"(    // Per-(h, block) int8-packed Q + (qd, q_sum), quantized once per WG.
)"
R"(    __local uint  q_packed_shared[MQ_GQA * DK_Q4_BLOCKS * 8];
)"
R"(    __local float q_d_shared[MQ_GQA * DK_Q4_BLOCKS];
)"
R"(    __local int   q_sum_shared[MQ_GQA * DK_Q4_BLOCKS];
)"
R"(    {
)"
R"(        const int active = MQ_GQA * DK_Q4_BLOCKS;
)"
R"(        if (tid < active) {
)"
R"(            const int h        = tid / DK_Q4_BLOCKS;
)"
R"(            const int block_id = tid % DK_Q4_BLOCKS;
)"
R"(            ACC_TYPE4 q_block[8];
)"
R"(            #pragma unroll
)"
R"(            for (int i = 0; i < 8; ++i) q_block[i] = q_shared[h * DK_VEC + block_id * 8 + i];
)"
R"(            uint packed[8];
)"
R"(            q4_q_block_info info = quant_q_block_int8_packed_q4(q_block, packed);
)"
R"(            #pragma unroll
)"
R"(            for (int i = 0; i < 8; ++i) q_packed_shared[(h * DK_Q4_BLOCKS + block_id) * 8 + i] = packed[i];
)"
R"(            q_d_shared[h * DK_Q4_BLOCKS + block_id]   = info.qd;
)"
R"(            q_sum_shared[h * DK_Q4_BLOCKS + block_id] = info.q_sum;
)"
R"(        }
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
R"(    // Per-CLUSTER online state; o_acc holds this lane's V quartets {lic + FA_CL_C*i}.
)"
R"(    ACC_TYPE4 o_acc[MQ_GQA][FA_CL_DVQ];
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
R"(        for (int i = 0; i < FA_CL_DVQ; ++i) o_acc[h][i] = (ACC_TYPE4)(0.0f);
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
R"(    // Uniform trip count; tail clamps the row address and drops the score to
)"
R"(    // FA_M_INIT (p underflows to 0) so shuffles stay convergent.
)"
R"(    const int n_iter = (kv_hi - kv_lo + FA_CL_NCL - 1) / FA_CL_NCL;
)"
R"(    const ulong k_row_base = batch_idx * k_nb3 + head_kv_idx * k_nb2;
)"
R"(    const ulong v_row_base = batch_idx * v_nb3 + head_kv_idx * v_nb2;
)"
R"(
)"
R"(    for (int it = 0; it < n_iter; ++it) {
)"
R"(        const int k_idx  = kv_lo + cl + it * FA_CL_NCL;
)"
R"(        const int valid  = k_idx < kv_hi;
)"
R"(        const int k_safe = valid ? k_idx : (kv_hi - 1);
)"
R"(
)"
R"(        const global char * k_row = k_base + k_row_base + (ulong) k_safe * k_nb1;
)"
R"(        const global char * v_row = v_base + v_row_base + (ulong) k_safe * v_nb1;
)"
R"(
)"
R"(        // dp4a K dot over this lane's quartets of the cluster's row.
)"
R"(        ACC_TYPE lane_contrib[MQ_GQA];
)"
R"(        #pragma unroll
)"
R"(        for (int h = 0; h < MQ_GQA; ++h) lane_contrib[h] = 0.0f;
)"
R"(
)"
R"(        #pragma unroll
)"
R"(        for (int i = 0; i < FA_CL_DKQ; ++i) {
)"
R"(            const int qk            = lic + FA_CL_C * i;
)"
R"(            const int block_idx     = qk / 8;
)"
R"(            const int lane_in_block = qk % 8;
)"
R"(            const int g             = lane_in_block & 3;
)"
R"(            const int shift         = (lane_in_block < 4) ? 0 : 4;
)"
R"(            const global char *  k_block = k_row + block_idx * Q4_0_BLOCK_SIZE;
)"
R"(            const float kd = vload_half(0, (const global half *)k_block);
)"
R"(            const global uchar * k_qs = (const global uchar *)(k_block + 2);
)"
R"(            const uchar b0 = k_qs[g*4 + 0];
)"
R"(            const uchar b1 = k_qs[g*4 + 1];
)"
R"(            const uchar b2 = k_qs[g*4 + 2];
)"
R"(            const uchar b3 = k_qs[g*4 + 3];
)"
R"(            const uint k_packed = ((uint)((b0 >> shift) & 0x0F))       |
)"
R"(                                  ((uint)((b1 >> shift) & 0x0F)) <<  8 |
)"
R"(                                  ((uint)((b2 >> shift) & 0x0F)) << 16 |
)"
R"(                                  ((uint)((b3 >> shift) & 0x0F)) << 24;
)"
R"(            #pragma unroll
)"
R"(            for (int h = 0; h < MQ_GQA; ++h) {
)"
R"(                const uint  q_packed_lane = q_packed_shared[(h * DK_Q4_BLOCKS + block_idx) * 8 + lane_in_block];
)"
R"(                const int   raw_dot       = dot_acc_sat_4x8packed_ss_int(q_packed_lane, k_packed, 0);
)"
R"(                const float qd            = q_d_shared[h * DK_Q4_BLOCKS + block_idx];
)"
R"(                const float block_scale   = qd * kd;
)"
R"(                float contrib = (float) raw_dot * block_scale;
)"
R"(                if (lane_in_block == 0) {
)"
R"(                    const int q_sum_b = q_sum_shared[h * DK_Q4_BLOCKS + block_idx];
)"
R"(                    contrib -= 8.0f * block_scale * (float) q_sum_b;
)"
R"(                }
)"
R"(                lane_contrib[h] += contrib;
)"
R"(            }
)"
R"(        }
)"
R"(
)"
R"(        // Cluster-reduce + score.
)"
R"(        ACC_TYPE score[MQ_GQA];
)"
R"(        #pragma unroll
)"
R"(        for (int h = 0; h < MQ_GQA; ++h) {
)"
R"(            ACC_TYPE s = lane_contrib[h];
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
R"(        // Per-cluster online update (serial chain depth n_iter, not kv_per_sg).
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
R"(        // V accumulate on this lane's quartets (p = 0 on tail -> inert).
)"
R"(        #pragma unroll
)"
R"(        for (int i = 0; i < FA_CL_DVQ; ++i) {
)"
R"(            const int dv = lic + FA_CL_C * i;
)"
R"(            const float4 v_v = dequant_q4_0_lane(v_row + (dv / 8) * Q4_0_BLOCK_SIZE, dv % 8);
)"
R"(            #pragma unroll
)"
R"(            for (int h = 0; h < MQ_GQA; ++h) {
)"
R"(                o_acc[h][i] = mad(p_h[h], v_v, o_acc[h][i] * sp_h[h]);
)"
R"(            }
)"
R"(        }
)"
R"(    }
)"
R"(
)"
R"(    // Merge stage 1: fold cluster partials inside the subgroup via shuffles.
)"
R"(    // Lanes with equal lic across clusters hold the SAME dv slice.
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
R"(        for (int i = 0; i < FA_CL_DVQ; ++i) {
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
R"(    // Merge stage 2: baseline cross-subgroup LDS merge (o published by
)"
R"(    // cluster 0's lanes; layout identical to the baseline sg_o).
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
R"(            for (int i = 0; i < FA_CL_DVQ; ++i) {
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
R"(
)"
R"(#endif  // DK_VEC/DV_VEC divisible by FA_CL_C
)"
R"(#endif  // FA_HAVE_INT_DOT && HAS_SUBGROUP_SHUFFLE (q1_vec_mq_split_c8)
)"
R"(
)"
R"(__kernel void flash_attn_f32_q4_0(
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
R"(    const ulong sinks_offset,
)"
R"(    // blk: per-(qblock,kvblock) class from flash_attn_blk_f16
)"
R"(    // (0=masked, 1=mixed, 2=unmasked). NULL disables the prepass opt.
)"
R"(    const global void * blk_void
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
R"(    const int my_query_row = block_q_idx * BLOCK_M + q_lane;
)"
R"(    const int query_valid = my_query_row < n_q;
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
R"(    const int mask_head_idx  = mask_void != NULL ? head_idx  % mask_ne2 : 0;
)"
R"(    const int mask_batch_idx = mask_void != NULL ? batch_idx % mask_ne3 : 0;
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
R"(        mask_base = (const global char *) mask_void + mask_offset +
)"
R"(                    mask_batch_idx * mask_nb3 + mask_head_idx * mask_nb2;
)"
R"(    }
)"
R"(
)"
R"(    // BLK_PREPASS_BM may differ from this kernel's BLOCK_M; scale q-block idx.
)"
R"(    #ifndef BLK_PREPASS_BM
)"
R"(    #define BLK_PREPASS_BM BLOCK_M
)"
R"(    #endif
)"
R"(    const global char * blk_base = NULL;
)"
R"(    int n_kv_blocks = 0;
)"
R"(    if (blk_void != NULL) {
)"
R"(        n_kv_blocks = (n_kv + BLOCK_N - 1) / BLOCK_N;
)"
R"(        const int n_q_blocks_prepass = (n_q + BLK_PREPASS_BM - 1) / BLK_PREPASS_BM;
)"
R"(        const int prepass_q_block    = (block_q_idx * BLOCK_M) / BLK_PREPASS_BM;
)"
R"(        blk_base = (const global char *) blk_void +
)"
R"(                   (((mask_batch_idx * mask_ne2) + mask_head_idx) * n_q_blocks_prepass + prepass_q_block) * n_kv_blocks;
)"
R"(    }
)"
R"(
)"
R"(    const int dk_off_vec = split_idx * SPLIT_DK_VEC;
)"
R"(    ACC_TYPE4 q_priv[SPLIT_DK_VEC];
)"
R"(    if (query_valid) {
)"
R"(        const ulong q_row_offset = batch_idx * q_nb3 + head_idx * q_nb2 + my_query_row * q_nb1;
)"
R"(        const global float4 * q_ptr = (const global float4 *) (q_base + q_row_offset);
)"
R"(        #pragma unroll
)"
R"(        for (int i = 0; i < SPLIT_DK_VEC; ++i) {
)"
R"(            q_priv[i] = q_ptr[dk_off_vec + i];
)"
R"(        }
)"
R"(    } else {
)"
R"(        #pragma unroll
)"
R"(        for (int i = 0; i < SPLIT_DK_VEC; ++i) q_priv[i] = (ACC_TYPE4)(0.0f);
)"
R"(    }
)"
R"(
)"
R"(#ifdef FA_HAVE_INT_DOT
)"
R"(    uint  q_packed_pf[SPLIT_DK_Q4_BLOCKS * 8];
)"
R"(    float q_d_pf[SPLIT_DK_Q4_BLOCKS];
)"
R"(    int   q_sum_pf[SPLIT_DK_Q4_BLOCKS];
)"
R"(    #pragma unroll
)"
R"(    for (int b = 0; b < SPLIT_DK_Q4_BLOCKS; ++b) {
)"
R"(        q4_q_block_info info = quant_q_block_int8_packed_q4(&q_priv[b * 8], &q_packed_pf[b * 8]);
)"
R"(        q_d_pf[b]   = info.qd;
)"
R"(        q_sum_pf[b] = info.q_sum;
)"
R"(    }
)"
R"(#endif
)"
R"(
)"
R"(    const int dv_off_vec = split_idx * SPLIT_DV_VEC;
)"
R"(    ACC_TYPE4 o_acc[SPLIT_DV_VEC];
)"
R"(    #pragma unroll
)"
R"(    for (int i = 0; i < SPLIT_DV_VEC; ++i) o_acc[i] = (ACC_TYPE4)(0.0f);
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
R"(#ifdef FA_HAVE_INT_DOT
)"
R"(// Accessors so the staging code is layout-agnostic.
)"
R"(#ifdef FA_K_LDS_T
)"
R"(#define FA_K_PACKED(ROW, IDX) l_k_packed[IDX][ROW]
)"
R"(#define FA_K_SCALE(ROW, BLK)  l_k_scale[BLK][ROW]
)"
R"(#else
)"
R"(#define FA_K_PACKED(ROW, IDX) l_k_packed[ROW][IDX]
)"
R"(#define FA_K_SCALE(ROW, BLK)  l_k_scale[ROW][BLK]
)"
R"(#endif
)"
R"(
)"
R"(#ifdef FA_K_LDS_T
)"
R"(    // K tile transposed: the 4 KV rows the QK loop walks together become adjacent, so each
)"
R"(    // (block, group) step is ONE 128-bit local read instead of four 32-bit ones. The QK
)"
R"(    // loop is LDS-read-issue-bound.
)"
R"(    __local uint  l_k_packed[DK_Q4_BLOCKS_PREFILL * 8][BLOCK_N];
)"
R"(    __local float l_k_scale [DK_Q4_BLOCKS_PREFILL][BLOCK_N];
)"
R"(#else
)"
R"(    __local uint  l_k_packed[BLOCK_N][DK_Q4_BLOCKS_PREFILL * 8];
)"
R"(    __local float l_k_scale [BLOCK_N][DK_Q4_BLOCKS_PREFILL];
)"
R"(#endif
)"
R"(#else
)"
R"(    __local half4 l_k[BLOCK_N][DK_VEC];
)"
R"(#endif
)"
R"(
)"
R"(    __local half4 l_v[BLOCK_N][DV_VEC];
)"
R"(
)"
R"(    for (int k_start = 0; k_start < n_kv; k_start += BLOCK_N) {
)"
R"(        // Skip fully-masked KV tiles (uniform branch across WG).
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
R"(        {
)"
R"(#ifdef FA_HAVE_INT_DOT
)"
R"(            const int k_blocks_per_row = DK_Q4_BLOCKS_PREFILL;
)"
R"(            const int n_blocks_total = BLOCK_N * k_blocks_per_row;
)"
R"(            for (int i = tid; i < n_blocks_total; i += WG_SIZE) {
)"
R"(                const int row = i / k_blocks_per_row;
)"
R"(                const int blk = i % k_blocks_per_row;
)"
R"(                const int k_row_idx = k_start + row;
)"
R"(                if (k_row_idx < n_kv) {
)"
R"(                    const ulong k_row_off = batch_idx * k_nb3 + head_kv_idx * k_nb2 + k_row_idx * k_nb1;
)"
R"(                    const global char * blk_ptr = k_base + k_row_off + blk * Q4_0_BLOCK_SIZE;
)"
R"(                    const float df = (float) vload_half(0, (const global half *) blk_ptr);
)"
R"(                    const global uchar * qs = (const global uchar *)(blk_ptr + 2);
)"
R"(                    FA_K_SCALE(row, blk) = df;
)"
R"(                    uint k_packed[8];
)"
R"(                    pack_q4_0_nibbles(qs, k_packed);
)"
R"(                    #pragma unroll
)"
R"(                    for (int j = 0; j < 8; ++j) {
)"
R"(                        FA_K_PACKED(row, blk * 8 + j) = k_packed[j];
)"
R"(                    }
)"
R"(                } else {
)"
R"(                    FA_K_SCALE(row, blk) = 0.0f;
)"
R"(                    #pragma unroll
)"
R"(                    for (int j = 0; j < 8; ++j) FA_K_PACKED(row, blk * 8 + j) = 0u;
)"
R"(                }
)"
R"(            }
)"
R"(#else
)"
R"(            // Fallback: dequant q4_0 -> half in local memory.
)"
R"(            const int k_blocks_per_row = DK_Q4_BLOCKS_PREFILL;
)"
R"(            const int n_blocks_total = BLOCK_N * k_blocks_per_row;
)"
R"(            for (int i = tid; i < n_blocks_total; i += WG_SIZE) {
)"
R"(                const int row = i / k_blocks_per_row;
)"
R"(                const int blk = i % k_blocks_per_row;
)"
R"(                const int k_row_idx = k_start + row;
)"
R"(                if (k_row_idx < n_kv) {
)"
R"(                    const ulong k_row_off = batch_idx * k_nb3 + head_kv_idx * k_nb2 + k_row_idx * k_nb1;
)"
R"(                    const global char * blk_ptr = k_base + k_row_off + blk * Q4_0_BLOCK_SIZE;
)"
R"(                    const float df = (float) vload_half(0, (const global half *) blk_ptr);
)"
R"(                    const global uchar * qs = (const global uchar *)(blk_ptr + 2);
)"
R"(                    #pragma unroll
)"
R"(                    for (int g = 0; g < 4; ++g) {
)"
R"(                        float4 vlo = df * (float4)((float)(int)(qs[g*4 + 0] & 0x0F) - 8.0f,
)"
R"(                                                   (float)(int)(qs[g*4 + 1] & 0x0F) - 8.0f,
)"
R"(                                                   (float)(int)(qs[g*4 + 2] & 0x0F) - 8.0f,
)"
R"(                                                   (float)(int)(qs[g*4 + 3] & 0x0F) - 8.0f);
)"
R"(                        float4 vhi = df * (float4)((float)(int)(qs[g*4 + 0] >> 4) - 8.0f,
)"
R"(                                                   (float)(int)(qs[g*4 + 1] >> 4) - 8.0f,
)"
R"(                                                   (float)(int)(qs[g*4 + 2] >> 4) - 8.0f,
)"
R"(                                                   (float)(int)(qs[g*4 + 3] >> 4) - 8.0f);
)"
R"(                        l_k[row][blk * 8 + g    ] = (half4)((half)vlo.s0, (half)vlo.s1, (half)vlo.s2, (half)vlo.s3);
)"
R"(                        l_k[row][blk * 8 + 4 + g] = (half4)((half)vhi.s0, (half)vhi.s1, (half)vhi.s2, (half)vhi.s3);
)"
R"(                    }
)"
R"(                } else {
)"
R"(                    #pragma unroll
)"
R"(                    for (int j = 0; j < 8; ++j) l_k[row][blk * 8 + j] = (half4)(0.0h);
)"
R"(                }
)"
R"(            }
)"
R"(#endif
)"
R"(        }
)"
R"(        // V tile load — dequant V -> half in local memory.
)"
R"(        {
)"
R"(            const int v_blocks_per_row = DV_Q4_BLOCKS_PREFILL;
)"
R"(            const int n_blocks_total = BLOCK_N * v_blocks_per_row;
)"
R"(            for (int i = tid; i < n_blocks_total; i += WG_SIZE) {
)"
R"(                const int row = i / v_blocks_per_row;
)"
R"(                const int blk = i % v_blocks_per_row;
)"
R"(                const int v_row_idx = k_start + row;
)"
R"(                if (v_row_idx < n_kv) {
)"
R"(                    const ulong v_row_off = batch_idx * v_nb3 + head_kv_idx * v_nb2 + v_row_idx * v_nb1;
)"
R"(                    const global char * blk_ptr = v_base + v_row_off + blk * Q4_0_BLOCK_SIZE;
)"
R"(                    const float df = (float) vload_half(0, (const global half *) blk_ptr);
)"
R"(                    const global uchar * qs = (const global uchar *)(blk_ptr + 2);
)"
R"(                    #pragma unroll
)"
R"(                    for (int g = 0; g < 4; ++g) {
)"
R"(                        float4 vlo = df * (float4)((float)(int)(qs[g*4 + 0] & 0x0F) - 8.0f,
)"
R"(                                                   (float)(int)(qs[g*4 + 1] & 0x0F) - 8.0f,
)"
R"(                                                   (float)(int)(qs[g*4 + 2] & 0x0F) - 8.0f,
)"
R"(                                                   (float)(int)(qs[g*4 + 3] & 0x0F) - 8.0f);
)"
R"(                        float4 vhi = df * (float4)((float)(int)(qs[g*4 + 0] >> 4) - 8.0f,
)"
R"(                                                   (float)(int)(qs[g*4 + 1] >> 4) - 8.0f,
)"
R"(                                                   (float)(int)(qs[g*4 + 2] >> 4) - 8.0f,
)"
R"(                                                   (float)(int)(qs[g*4 + 3] >> 4) - 8.0f);
)"
R"(                        l_v[row][blk * 8 + g    ] = (half4)((half)vlo.s0, (half)vlo.s1, (half)vlo.s2, (half)vlo.s3);
)"
R"(                        l_v[row][blk * 8 + 4 + g] = (half4)((half)vhi.s0, (half)vhi.s1, (half)vhi.s2, (half)vhi.s3);
)"
R"(                    }
)"
R"(                } else {
)"
R"(                    #pragma unroll
)"
R"(                    for (int j = 0; j < 8; ++j) l_v[row][blk * 8 + j] = (half4)(0.0h);
)"
R"(                }
)"
R"(            }
)"
R"(        }
)"
R"(        barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(
)"
R"(        // QK dot + online softmax. N_SPLIT>1 reduces per-thread partials via shuffle_xor.
)"
R"(#if N_SPLIT > 1
)"
R"(        {
)"
R"(#else
)"
R"(        if (query_valid) {
)"
R"(#endif
)"
R"(            const int k_blk_base = split_idx * SPLIT_DK_Q4_BLOCKS;
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
R"(                ACC_TYPE s0, s1, s2, s3;
)"
R"(#ifdef FA_HAVE_INT_DOT
)"
R"(                s0 = 0.0f; s1 = 0.0f; s2 = 0.0f; s3 = 0.0f;
)"
R"(                #pragma unroll
)"
R"(                for (int b_local = 0; b_local < SPLIT_DK_Q4_BLOCKS; ++b_local) {
)"
R"(                    const int b = k_blk_base + b_local;
)"
R"(                    int sum0 = 0, sum1 = 0, sum2 = 0, sum3 = 0;
)"
R"(#ifdef FA_K_LDS_T
)"
R"(                    // 4 KV rows are adjacent in the transposed tile: one 128-bit local
)"
R"(                    // read per (block, group) instead of four 32-bit ones.
)"
R"(                    #pragma unroll
)"
R"(                    for (int g = 0; g < 8; ++g) {
)"
R"(                        const uint  qp  = q_packed_pf[b_local * 8 + g];
)"
R"(                        const uint4 kq4 = vload4(0, &l_k_packed[b * 8 + g][j]);
)"
R"(                        sum0 = dot_acc_sat_4x8packed_ss_int(qp, kq4.s0, sum0);
)"
R"(                        sum1 = dot_acc_sat_4x8packed_ss_int(qp, kq4.s1, sum1);
)"
R"(                        sum2 = dot_acc_sat_4x8packed_ss_int(qp, kq4.s2, sum2);
)"
R"(                        sum3 = dot_acc_sat_4x8packed_ss_int(qp, kq4.s3, sum3);
)"
R"(                    }
)"
R"(#else
)"
R"(                    #pragma unroll
)"
R"(                    for (int g = 0; g < 8; ++g) {
)"
R"(                        const uint qp = q_packed_pf[b_local * 8 + g];
)"
R"(                        sum0 = dot_acc_sat_4x8packed_ss_int(qp, l_k_packed[j  ][b * 8 + g], sum0);
)"
R"(                        sum1 = dot_acc_sat_4x8packed_ss_int(qp, l_k_packed[j+1][b * 8 + g], sum1);
)"
R"(                        sum2 = dot_acc_sat_4x8packed_ss_int(qp, l_k_packed[j+2][b * 8 + g], sum2);
)"
R"(                        sum3 = dot_acc_sat_4x8packed_ss_int(qp, l_k_packed[j+3][b * 8 + g], sum3);
)"
R"(                    }
)"
R"(#endif
)"
R"(                    const float qd    = q_d_pf[b_local];
)"
R"(                    const int   q_sum = q_sum_pf[b_local];
)"
R"(#ifdef FA_K_LDS_T
)"
R"(                    const float4 ks4 = vload4(0, &l_k_scale[b][j]);
)"
R"(                    s0 += (float)(sum0 - 8 * q_sum) * qd * ks4.s0;
)"
R"(                    s1 += (float)(sum1 - 8 * q_sum) * qd * ks4.s1;
)"
R"(                    s2 += (float)(sum2 - 8 * q_sum) * qd * ks4.s2;
)"
R"(                    s3 += (float)(sum3 - 8 * q_sum) * qd * ks4.s3;
)"
R"(#else
)"
R"(                    s0 += (float)(sum0 - 8 * q_sum) * qd * l_k_scale[j  ][b];
)"
R"(                    s1 += (float)(sum1 - 8 * q_sum) * qd * l_k_scale[j+1][b];
)"
R"(                    s2 += (float)(sum2 - 8 * q_sum) * qd * l_k_scale[j+2][b];
)"
R"(                    s3 += (float)(sum3 - 8 * q_sum) * qd * l_k_scale[j+3][b];
)"
R"(#endif
)"
R"(                }
)"
R"(#else
)"
R"(                ACC_TYPE4 dot_acc0 = (ACC_TYPE4)(0.0f);
)"
R"(                ACC_TYPE4 dot_acc1 = (ACC_TYPE4)(0.0f);
)"
R"(                ACC_TYPE4 dot_acc2 = (ACC_TYPE4)(0.0f);
)"
R"(                ACC_TYPE4 dot_acc3 = (ACC_TYPE4)(0.0f);
)"
R"(                #pragma unroll
)"
R"(                for (int k = 0; k < SPLIT_DK_VEC; ++k) {
)"
R"(                    const ACC_TYPE4 qk = q_priv[k];
)"
R"(                    const int k_abs = dk_off_vec + k;
)"
R"(                    dot_acc0 = mad(qk, CONVERT_KV_ACC4(l_k[j  ][k_abs]), dot_acc0);
)"
R"(                    dot_acc1 = mad(qk, CONVERT_KV_ACC4(l_k[j+1][k_abs]), dot_acc1);
)"
R"(                    dot_acc2 = mad(qk, CONVERT_KV_ACC4(l_k[j+2][k_abs]), dot_acc2);
)"
R"(                    dot_acc3 = mad(qk, CONVERT_KV_ACC4(l_k[j+3][k_abs]), dot_acc3);
)"
R"(                }
)"
R"(                s0 = dot_acc0.s0 + dot_acc0.s1 + dot_acc0.s2 + dot_acc0.s3;
)"
R"(                s1 = dot_acc1.s0 + dot_acc1.s1 + dot_acc1.s2 + dot_acc1.s3;
)"
R"(                s2 = dot_acc2.s0 + dot_acc2.s1 + dot_acc2.s2 + dot_acc2.s3;
)"
R"(                s3 = dot_acc3.s0 + dot_acc3.s1 + dot_acc3.s2 + dot_acc3.s3;
)"
R"(#endif
)"
R"(
)"
R"(#if N_SPLIT > 1
)"
R"(                // Power-of-2 N_SPLIT: shuffle_xor butterfly. N_SPLIT=3 (DK=96):
)"
R"(                // explicit 3-lane shuffle.
)"
R"(                #if (N_SPLIT & (N_SPLIT - 1)) == 0
)"
R"(                    #pragma unroll
)"
R"(                    for (int step = 1; step < N_SPLIT; step <<= 1) {
)"
R"(                        s0 += sub_group_shuffle_xor(s0, step);
)"
R"(                        s1 += sub_group_shuffle_xor(s1, step);
)"
R"(                        s2 += sub_group_shuffle_xor(s2, step);
)"
R"(                        s3 += sub_group_shuffle_xor(s3, step);
)"
R"(                    }
)"
R"(                #else
)"
R"(                    const uint tri_base = (get_sub_group_local_id() / N_SPLIT) * N_SPLIT;
)"
R"(                    s0 = sub_group_shuffle(s0, tri_base + 0) + sub_group_shuffle(s0, tri_base + 1) + sub_group_shuffle(s0, tri_base + 2);
)"
R"(                    s1 = sub_group_shuffle(s1, tri_base + 0) + sub_group_shuffle(s1, tri_base + 1) + sub_group_shuffle(s1, tri_base + 2);
)"
R"(                    s2 = sub_group_shuffle(s2, tri_base + 0) + sub_group_shuffle(s2, tri_base + 1) + sub_group_shuffle(s2, tri_base + 2);
)"
R"(                    s3 = sub_group_shuffle(s3, tri_base + 0) + sub_group_shuffle(s3, tri_base + 1) + sub_group_shuffle(s3, tri_base + 2);
)"
R"(                #endif
)"
R"(#endif
)"
R"(                s0 *= scale; s1 *= scale; s2 *= scale; s3 *= scale;
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
R"(                if (!query_valid) { s0 = FA_M_INIT; s1 = FA_M_INIT; s2 = FA_M_INIT; s3 = FA_M_INIT; }
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
R"(                if (query_valid && mask_base != NULL && blk_cur != 2) {
)"
R"(                    const global MASK_DATA_TYPE * mask_ptr =
)"
R"(                        (const global MASK_DATA_TYPE *) (mask_base + my_query_row * mask_nb1);
)"
R"(                    if (k_row0 < n_kv) s0 += slope * (ACC_TYPE) mask_ptr[k_row0];
)"
R"(                    if (k_row1 < n_kv) s1 += slope * (ACC_TYPE) mask_ptr[k_row1];
)"
R"(                    if (k_row2 < n_kv) s2 += slope * (ACC_TYPE) mask_ptr[k_row2];
)"
R"(                    if (k_row3 < n_kv) s3 += slope * (ACC_TYPE) mask_ptr[k_row3];
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
R"(                #pragma unroll
)"
R"(                for (int i = 0; i < SPLIT_DV_VEC; ++i) {
)"
R"(                    const int i_abs = dv_off_vec + i;
)"
R"(                    o_acc[i] = mad(p3, CONVERT_KV_ACC4(l_v[j+3][i_abs]),
)"
R"(                               mad(p2, CONVERT_KV_ACC4(l_v[j+2][i_abs]),
)"
R"(                               mad(p1, CONVERT_KV_ACC4(l_v[j+1][i_abs]),
)"
R"(                               mad(p0, CONVERT_KV_ACC4(l_v[j  ][i_abs]),
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
R"(        barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(    }
)"
R"(
)"
R"(    // Write output.
)"
R"(    if (query_valid) {
)"
R"(        if (sinks_void != NULL) {
)"
R"(            const global ACC_TYPE * sinks_ptr =
)"
R"(                (const global ACC_TYPE *) ((const global char *) sinks_void + sinks_offset);
)"
R"(            const ACC_TYPE m_sink  = sinks_ptr[head_idx];
)"
R"(            const ACC_TYPE m_final = max(m_i, m_sink);
)"
R"(            const ACC_TYPE scale_o = exp(m_i - m_final);
)"
R"(            #pragma unroll
)"
R"(            for (int i = 0; i < SPLIT_DV_VEC; ++i) o_acc[i] *= scale_o;
)"
R"(            l_i = l_i * scale_o + exp(m_sink - m_final);
)"
R"(            m_i = m_final;
)"
R"(        }
)"
R"(        const ACC_TYPE l_inv = (l_i > 0.0f) ? (1.0f / l_i) : 0.0f;
)"
R"(        const ulong o_row_offset = batch_idx * o_nb3 + my_query_row * o_nb2 + head_idx * o_nb1;
)"
R"(        global float4 * o_row = (global float4 *) (o_base + o_row_offset);
)"
R"(        if (l_inv > 0.0f) {
)"
R"(            #pragma unroll
)"
R"(            for (int i = 0; i < SPLIT_DV_VEC; ++i) o_row[dv_off_vec + i] = o_acc[i] * l_inv;
)"
R"(        } else {
)"
R"(            #pragma unroll
)"
R"(            for (int i = 0; i < SPLIT_DV_VEC; ++i) o_row[dv_off_vec + i] = (float4)(0.0f);
)"
R"(        }
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(// FD Pass 2: merge split partials. Identical across q4_0/q8_0/f16; each FA
)"
R"(// source owns a copy since kernels compile per-source-program.
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
R"(    const int lane           = get_local_id(0);
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
