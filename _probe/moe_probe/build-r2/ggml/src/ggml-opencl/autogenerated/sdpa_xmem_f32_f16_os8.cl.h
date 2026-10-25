R"(#pragma OPENCL EXTENSION cl_khr_fp16 : enable
)"
R"(#pragma OPENCL EXTENSION cl_qcom_subgroup_uniform_load : enable
)"
R"(#pragma OPENCL EXTENSION cl_qcom_subgroup_constant_load : enable
)"
R"(// image3d_t writes need this enabled; the Adreno 650 (K40) vendor compiler rejects them
)"
R"(// otherwise and the model fails to load. Same fix as flash_attn_repack.cl.
)"
R"(#pragma OPENCL EXTENSION cl_khr_3d_image_writes : enable
)"
R"(
)"
R"(#define bool2 uchar2
)"
R"(#define bool3 uchar3
)"
R"(#define bool4 uchar4
)"
R"(
)"
R"(__constant sampler_t smp_none = CLK_NORMALIZED_COORDS_FALSE | CLK_ADDRESS_NONE | CLK_FILTER_NEAREST;
)"
R"(__constant sampler_t smp_zero = CLK_NORMALIZED_COORDS_FALSE | CLK_ADDRESS_CLAMP | CLK_FILTER_NEAREST;
)"
R"(
)"
R"(__kernel void adreno_xmem_attn_q_f32_to_img_scaled(const global void *  src_void,
)"
R"(                                                   ulong                src_offset,
)"
R"(                                                   write_only image2d_t dst_image2d,
)"
R"(                                                   const float          scale,
)"
R"(                                                   const int            d_head,
)"
R"(                                                   const int            n_q,
)"
R"(                                                   const int            n_head,
)"
R"(                                                   const int            n_head_kv,
)"
R"(                                                   const int            n_batch,
)"
R"(                                                   const ulong          src_nb1,
)"
R"(                                                   const ulong          src_nb2,
)"
R"(                                                   const ulong          src_nb3) {
)"
R"(    const int x      = get_global_id(0);
)"
R"(    const int flat_h = get_global_id(1);
)"
R"(    const int d      = get_global_id(2);
)"
R"(
)"
R"(    const int heads_total = n_head * n_batch;
)"
R"(    const int kpack       = d_head / 4;
)"
R"(
)"
R"(    if (x >= n_q || flat_h >= heads_total || d >= kpack) {
)"
R"(        return;
)"
R"(    }
)"
R"(
)"
R"(    const int batch = flat_h / n_head;
)"
R"(    const int head  = flat_h % n_head;
)"
R"(    const int gqa   = n_head / n_head_kv;
)"
R"(    const int head_kv = head / gqa;
)"
R"(    const int head_group = head - head_kv * gqa;
)"
R"(    const int compact_h = batch * n_head_kv + head_kv;
)"
R"(    const int compact_x = head_group * n_q + x;
)"
R"(    const int c     = d * 4;
)"
R"(
)"
R"(    const global char *  src_base = (const global char *) src_void + src_offset;
)"
R"(    const global float * row_ptr  = (const global float *) (src_base + batch * src_nb3 + head * src_nb2 + x * src_nb1);
)"
R"(
)"
R"(    half4 out = (half4) (0.0h);
)"
R"(    out.x     = convert_half(row_ptr[c + 0] * scale);
)"
R"(    if (c + 1 < d_head) {
)"
R"(        out.y = convert_half(row_ptr[c + 1] * scale);
)"
R"(    }
)"
R"(    if (c + 2 < d_head) {
)"
R"(        out.z = convert_half(row_ptr[c + 2] * scale);
)"
R"(    }
)"
R"(    if (c + 3 < d_head) {
)"
R"(        out.w = convert_half(row_ptr[c + 3] * scale);
)"
R"(    }
)"
R"(
)"
R"(    write_imageh(dst_image2d, (int2) (compact_x, compact_h * kpack + d), out);
)"
R"(}
)"
R"(
)"
R"(__kernel void adreno_xmem_attn_kv_f32_to_img_gqa(const global void *  src_void,
)"
R"(                                                 ulong                src_offset,
)"
R"(                                                 write_only image2d_t dst_image2d,
)"
R"(                                                 const int            d_head,
)"
R"(                                                 const int            n_kv,
)"
R"(                                                 const int            n_kv_padded,
)"
R"(                                                 const int            n_head_kv,
)"
R"(                                                 const int            n_batch,
)"
R"(                                                 const ulong          src_nb1,
)"
R"(                                                 const ulong          src_nb2,
)"
R"(                                                 const ulong          src_nb3) {
)"
R"(    const int x      = get_global_id(0);
)"
R"(    const int flat_h = get_global_id(1);
)"
R"(    const int d      = get_global_id(2);
)"
R"(
)"
R"(    const int kv_heads_total = n_head_kv * n_batch;
)"
R"(    const int kpack          = d_head / 4;
)"
R"(
)"
R"(    if (x >= n_kv_padded || flat_h >= kv_heads_total || d >= kpack) {
)"
R"(        return;
)"
R"(    }
)"
R"(
)"
R"(    const int batch   = flat_h / n_head_kv;
)"
R"(    const int head_kv = flat_h % n_head_kv;
)"
R"(    const int c       = d * 4;
)"
R"(
)"
R"(    half4 out = (half4) (0.0h);
)"
R"(    if (x < n_kv) {
)"
R"(        const global char *  src_base = (const global char *) src_void + src_offset;
)"
R"(        const global float * row_ptr =
)"
R"(            (const global float *) (src_base + batch * src_nb3 + head_kv * src_nb2 + x * src_nb1);
)"
R"(        out.x = convert_half(row_ptr[c + 0]);
)"
R"(        if (c + 1 < d_head) {
)"
R"(            out.y = convert_half(row_ptr[c + 1]);
)"
R"(        }
)"
R"(        if (c + 2 < d_head) {
)"
R"(            out.z = convert_half(row_ptr[c + 2]);
)"
R"(        }
)"
R"(        if (c + 3 < d_head) {
)"
R"(            out.w = convert_half(row_ptr[c + 3]);
)"
R"(        }
)"
R"(    }
)"
R"(
)"
R"(    write_imageh(dst_image2d, (int2) (x, flat_h * kpack + d), out);
)"
R"(}
)"
R"(
)"
R"(__kernel void adreno_xmem_attn_kv_f16_to_img_gqa(const global void *  src_void,
)"
R"(                                                 ulong                src_offset,
)"
R"(                                                 write_only image2d_t dst_image2d,
)"
R"(                                                 const int            d_head,
)"
R"(                                                 const int            n_kv,
)"
R"(                                                 const int            n_kv_padded,
)"
R"(                                                 const int            n_head_kv,
)"
R"(                                                 const int            n_batch,
)"
R"(                                                 const ulong          src_nb1,
)"
R"(                                                 const ulong          src_nb2,
)"
R"(                                                 const ulong          src_nb3) {
)"
R"(    const int x      = get_global_id(0);
)"
R"(    const int flat_h = get_global_id(1);
)"
R"(    const int d      = get_global_id(2);
)"
R"(
)"
R"(    const int kv_heads_total = n_head_kv * n_batch;
)"
R"(    const int kpack          = d_head / 4;
)"
R"(
)"
R"(    if (x >= n_kv_padded || flat_h >= kv_heads_total || d >= kpack) {
)"
R"(        return;
)"
R"(    }
)"
R"(
)"
R"(    const int batch   = flat_h / n_head_kv;
)"
R"(    const int head_kv = flat_h % n_head_kv;
)"
R"(    const int c       = d * 4;
)"
R"(
)"
R"(    half4 out = (half4) (0.0h);
)"
R"(    if (x < n_kv) {
)"
R"(        const global char * src_base = (const global char *) src_void + src_offset;
)"
R"(        const global half * row_ptr =
)"
R"(            (const global half *) (src_base + batch * src_nb3 + head_kv * src_nb2 + x * src_nb1);
)"
R"(        out.x = row_ptr[c + 0];
)"
R"(        if (c + 1 < d_head) {
)"
R"(            out.y = row_ptr[c + 1];
)"
R"(        }
)"
R"(        if (c + 2 < d_head) {
)"
R"(            out.z = row_ptr[c + 2];
)"
R"(        }
)"
R"(        if (c + 3 < d_head) {
)"
R"(            out.w = row_ptr[c + 3];
)"
R"(        }
)"
R"(    }
)"
R"(
)"
R"(    write_imageh(dst_image2d, (int2) (x, flat_h * kpack + d), out);
)"
R"(}
)"
R"(
)"
R"(__kernel void adreno_xmem_attn_img_to_f32(global void *       dst_void,
)"
R"(                                          ulong               dst_offset,
)"
R"(                                          read_only image2d_t src_image2d,
)"
R"(                                          const int           d_head,
)"
R"(                                          const int           n_q,
)"
R"(                                          const int           n_head,
)"
R"(                                          const int           n_head_kv,
)"
R"(                                          const int           n_batch,
)"
R"(                                          const ulong         dst_nb1,
)"
R"(                                          const ulong         dst_nb2,
)"
R"(                                          const ulong         dst_nb3) {
)"
R"(    const int x      = get_global_id(0);
)"
R"(    const int flat_h = get_global_id(1);
)"
R"(    const int d      = get_global_id(2);
)"
R"(
)"
R"(    const int heads_total = n_head * n_batch;
)"
R"(    const int kpack       = d_head / 4;
)"
R"(
)"
R"(    if (x >= n_q || flat_h >= heads_total || d >= kpack) {
)"
R"(        return;
)"
R"(    }
)"
R"(
)"
R"(    const int batch = flat_h / n_head;
)"
R"(    const int head  = flat_h % n_head;
)"
R"(    const int gqa   = n_head / n_head_kv;
)"
R"(    const int head_kv = head / gqa;
)"
R"(    const int head_group = head - head_kv * gqa;
)"
R"(    const int compact_h = batch * n_head_kv + head_kv;
)"
R"(    const int compact_x = head_group * n_q + x;
)"
R"(    const int c     = d * 4;
)"
R"(
)"
R"(    global char *  dst_base = (global char *) dst_void + dst_offset;
)"
R"(    global float * row_ptr  = (global float *) (dst_base + batch * dst_nb3 + x * dst_nb2 + head * dst_nb1);
)"
R"(
)"
R"(    const half4 in_value = read_imageh(src_image2d, smp_zero, (int2) (compact_x, compact_h * kpack + d));
)"
R"(    row_ptr[c + 0]       = convert_float(in_value.x);
)"
R"(    if (c + 1 < d_head) {
)"
R"(        row_ptr[c + 1] = convert_float(in_value.y);
)"
R"(    }
)"
R"(    if (c + 2 < d_head) {
)"
R"(        row_ptr[c + 2] = convert_float(in_value.z);
)"
R"(    }
)"
R"(    if (c + 3 < d_head) {
)"
R"(        row_ptr[c + 3] = convert_float(in_value.w);
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(__kernel void adreno_xmem_attn_k_gather(global half4 *      dst_tensor_buffer,
)"
R"(                                        read_only image2d_t src_tensor_image2d,
)"
R"(                                        const int4          shared_int4_0,
)"
R"(                                        const int4          shared_int4_1) {
)"
R"(    int X = get_global_id(0);
)"
R"(    int Y = get_global_id(1);
)"
R"(    int S = get_global_id(2);
)"
R"(    if (X >= shared_int4_0.w || Y >= shared_int4_0.y || S >= shared_int4_0.z) {
)"
R"(        return;
)"
R"(    }
)"
R"(    half temps[4];
)"
R"(    temps[0] = (half) (0.f);
)"
R"(    temps[1] = (half) (0.f);
)"
R"(    temps[2] = (half) (0.f);
)"
R"(    temps[3] = (half) (0.f);
)"
R"(    for (int i = 0; i < 4; ++i) {
)"
R"(        int dst_channel = S * 4 + i;
)"
R"(        if (dst_channel < shared_int4_0.x) {
)"
R"(            int s_y = Y;
)"
R"(            int s_x = dst_channel;
)"
R"(            int s_c = X;
)"
R"(            {
)"
R"(                int   slice_coord_TMP  = (s_c) / 4;
)"
R"(                int   sub_ch_coord_TMP = (s_c) % 4;
)"
R"(                half4 src_TMP          = read_imageh(src_tensor_image2d, smp_zero,
)"
R"(                                                     (int2) ((s_x), ((s_y) *shared_int4_1.x + (slice_coord_TMP))));
)"
R"(                temps[i]               = (half[4]){ src_TMP.x, src_TMP.y, src_TMP.z, src_TMP.w }[sub_ch_coord_TMP];
)"
R"(            };
)"
R"(        }
)"
R"(    }
)"
R"(    half4 result;
)"
R"(    result.x                                                                  = temps[0];
)"
R"(    result.y                                                                  = temps[1];
)"
R"(    result.z                                                                  = temps[2];
)"
R"(    result.w                                                                  = temps[3];
)"
R"(    dst_tensor_buffer[(((S) *shared_int4_0.y + (Y)) * shared_int4_0.w + (X))] = result;
)"
R"(}
)"
R"(
)"
R"(__kernel void adreno_xmem_attn_pack_k(global half4 *             dst_tensor_buffer,
)"
R"(                                      read_only image1d_buffer_t src_image_buffer,
)"
R"(                                      const int4                 shared_int4_0,
)"
R"(                                      const int4                 shared_int4_1,
)"
R"(                                      const int4                 shared_int4_2) {
)"
R"(    int linear_index = get_global_id(0);
)"
R"(    if (linear_index >= shared_int4_0.y) {
)"
R"(        return;
)"
R"(    }
)"
R"(    if (get_global_id(1) != 0) {
)"
R"(        return;
)"
R"(    }
)"
R"(    if (get_global_id(2) != 0) {
)"
R"(        return;
)"
R"(    }
)"
R"(    int   dst_o_sp_i_ogroup = linear_index;
)"
R"(    int   dst_ogroup        = dst_o_sp_i_ogroup % shared_int4_0.x;
)"
R"(    int   dst_o_sp_i        = dst_o_sp_i_ogroup / shared_int4_0.x;
)"
R"(    int   dst_i             = dst_o_sp_i % shared_int4_0.z;
)"
R"(    int   dst_o_sp          = dst_o_sp_i / shared_int4_0.z;
)"
R"(    int   dst_sp            = dst_o_sp % shared_int4_1.x;
)"
R"(    int   dst_o             = dst_o_sp / shared_int4_1.x;
)"
R"(    int   i_slice           = dst_i;
)"
R"(    int   o_slice           = dst_o * shared_int4_0.x + dst_ogroup;
)"
R"(    int   spatial_linear    = dst_sp;
)"
R"(    int   W                 = spatial_linear % shared_int4_1.y;
)"
R"(    int   H                 = spatial_linear / shared_int4_1.y;
)"
R"(    half4 w0                = (half4) (0);
)"
R"(    half4 w1                = (half4) (0);
)"
R"(    half4 w2                = (half4) (0);
)"
R"(    half4 w3                = (half4) (0);
)"
R"(
)"
R"(    if (i_slice * 4 < shared_int4_0.w && o_slice < shared_int4_1.w) {
)"
R"(        w0 = read_imageh(src_image_buffer, (((o_slice) *shared_int4_1.z + (W)) * shared_int4_2.x + (i_slice * 4)));
)"
R"(    }
)"
R"(    if (i_slice * 4 + 1 < shared_int4_0.w && o_slice < shared_int4_1.w) {
)"
R"(        w1 = read_imageh(src_image_buffer, (((o_slice) *shared_int4_1.z + (W)) * shared_int4_2.x + (i_slice * 4 + 1)));
)"
R"(    }
)"
R"(    if (i_slice * 4 + 2 < shared_int4_0.w && o_slice < shared_int4_1.w) {
)"
R"(        w2 = read_imageh(src_image_buffer, (((o_slice) *shared_int4_1.z + (W)) * shared_int4_2.x + (i_slice * 4 + 2)));
)"
R"(    }
)"
R"(    if (i_slice * 4 + 3 < shared_int4_0.w && o_slice < shared_int4_1.w) {
)"
R"(        w3 = read_imageh(src_image_buffer, (((o_slice) *shared_int4_1.z + (W)) * shared_int4_2.x + (i_slice * 4 + 3)));
)"
R"(    }
)"
R"(    half4 r0                                = w0;
)"
R"(    half4 r1                                = w1;
)"
R"(    half4 r2                                = w2;
)"
R"(    half4 r3                                = w3;
)"
R"(    dst_tensor_buffer[linear_index * 4 + 0] = r0;
)"
R"(    dst_tensor_buffer[linear_index * 4 + 1] = r1;
)"
R"(    dst_tensor_buffer[linear_index * 4 + 2] = r2;
)"
R"(    dst_tensor_buffer[linear_index * 4 + 3] = r3;
)"
R"(}
)"
R"(
)"
R"(__attribute__((qcom_max_concurrent_subgroups(12))) __kernel void adreno_xmem_attn_qk_gemm(
)"
R"(    global half4 *      dst_tensor_buffer,
)"
R"(    constant half8 *    weights_buffer __attribute__((sub_group_uniform)),
)"
R"(    constant half8 *    xmem_buffer __attribute__((max_constant_size((6144)))),
)"
R"(    read_only image2d_t src_tensor_image2d,
)"
R"(    const int4          shared_int4_0,
)"
R"(    const int4          shared_int4_1,
)"
R"(    const int4          shared_int4_2) {
)"
R"(    int X = get_group_id(1) * get_local_size(0) + get_local_id(0);
)"
R"(    int Y = get_group_id(2) * get_local_size(1) + get_local_id(1);
)"
R"(    int Z = get_group_id(0) * get_local_size(2) + get_local_id(2);
)"
R"(    if (X >= shared_int4_0.z || Y >= shared_int4_0.x) {
)"
R"(        return;
)"
R"(    }
)"
R"(    if (Z * 8 >= shared_int4_0.y) {
)"
R"(        return;
)"
R"(    }
)"
R"(
)"
R"(    half4 r0      = (half4) (0.f);
)"
R"(    half4 r1      = (half4) (0.f);
)"
R"(    half4 r2      = (half4) (0.f);
)"
R"(    half4 r3      = (half4) (0.f);
)"
R"(    half4 r4      = (half4) (0.f);
)"
R"(    half4 r5      = (half4) (0.f);
)"
R"(    half4 r6      = (half4) (0.f);
)"
R"(    half4 r7      = (half4) (0.f);
)"
R"(    int   x_coord = mad24(X, shared_int4_2.y, shared_int4_1.y);
)"
R"(    int   y_coord = mad24(Y, shared_int4_2.z, shared_int4_1.z);
)"
R"(    int   coord_x, coord_y, coord_s;
)"
R"(    int   f_offset = (Z * shared_int4_1.w + Y) * shared_int4_1.x * 32;
)"
R"(
)"
R"(    int subgroup_id                   = (int) ((0x1F & qcom_get_physical_sub_group_id()));
)"
R"(    subgroup_id                       = subgroup_id % 12;
)"
R"(    int                 c_offset      = mul24(subgroup_id, shared_int4_0.w);
)"
R"(    __constant half16 * weights_cache = (__constant half16 *) &xmem_buffer[c_offset];
)"
R"(    coord_y                           = Y;
)"
R"(    coord_x                           = X;
)"
R"(    coord_s                           = 0;
)"
R"(    do {
)"
R"(        half4 src0 =
)"
R"(            read_imageh(src_tensor_image2d, smp_zero, (int2) ((coord_x), ((coord_y) *shared_int4_2.x + (coord_s))));
)"
R"(        coord_s++;
)"
R"(        half4 src1 =
)"
R"(            read_imageh(src_tensor_image2d, smp_zero, (int2) ((coord_x), ((coord_y) *shared_int4_2.x + (coord_s))));
)"
R"(        coord_s++;
)"
R"(        qcom_sub_group_constant_load8(xmem_buffer, weights_buffer, c_offset, f_offset >> 1, 32);
)"
R"(        f_offset += 64;
)"
R"(        qcom_sub_group_sync(QCOM_CLK_CONST_LOAD_SYNC);
)"
R"(        r0 += src0.x * weights_cache[0].s0123;
)"
R"(        r0 += src0.y * weights_cache[0].s4567;
)"
R"(        r0 += src0.z * weights_cache[0].s89ab;
)"
R"(        r0 += src0.w * weights_cache[0].scdef;
)"
R"(        r1 += src0.x * weights_cache[1].s0123;
)"
R"(        r1 += src0.y * weights_cache[1].s4567;
)"
R"(        r1 += src0.z * weights_cache[1].s89ab;
)"
R"(        r1 += src0.w * weights_cache[1].scdef;
)"
R"(        r2 += src0.x * weights_cache[2].s0123;
)"
R"(        r2 += src0.y * weights_cache[2].s4567;
)"
R"(        r2 += src0.z * weights_cache[2].s89ab;
)"
R"(        r2 += src0.w * weights_cache[2].scdef;
)"
R"(        r3 += src0.x * weights_cache[3].s0123;
)"
R"(        r3 += src0.y * weights_cache[3].s4567;
)"
R"(        r3 += src0.z * weights_cache[3].s89ab;
)"
R"(        r3 += src0.w * weights_cache[3].scdef;
)"
R"(        r4 += src0.x * weights_cache[4].s0123;
)"
R"(        r4 += src0.y * weights_cache[4].s4567;
)"
R"(        r4 += src0.z * weights_cache[4].s89ab;
)"
R"(        r4 += src0.w * weights_cache[4].scdef;
)"
R"(        r5 += src0.x * weights_cache[5].s0123;
)"
R"(        r5 += src0.y * weights_cache[5].s4567;
)"
R"(        r5 += src0.z * weights_cache[5].s89ab;
)"
R"(        r5 += src0.w * weights_cache[5].scdef;
)"
R"(        r6 += src0.x * weights_cache[6].s0123;
)"
R"(        r6 += src0.y * weights_cache[6].s4567;
)"
R"(        r6 += src0.z * weights_cache[6].s89ab;
)"
R"(        r6 += src0.w * weights_cache[6].scdef;
)"
R"(        r7 += src0.x * weights_cache[7].s0123;
)"
R"(        r7 += src0.y * weights_cache[7].s4567;
)"
R"(        r7 += src0.z * weights_cache[7].s89ab;
)"
R"(        r7 += src0.w * weights_cache[7].scdef;
)"
R"(        r0 += src1.x * weights_cache[8].s0123;
)"
R"(        r0 += src1.y * weights_cache[8].s4567;
)"
R"(        r0 += src1.z * weights_cache[8].s89ab;
)"
R"(        r0 += src1.w * weights_cache[8].scdef;
)"
R"(        r1 += src1.x * weights_cache[9].s0123;
)"
R"(        r1 += src1.y * weights_cache[9].s4567;
)"
R"(        r1 += src1.z * weights_cache[9].s89ab;
)"
R"(        r1 += src1.w * weights_cache[9].scdef;
)"
R"(        r2 += src1.x * weights_cache[10].s0123;
)"
R"(        r2 += src1.y * weights_cache[10].s4567;
)"
R"(        r2 += src1.z * weights_cache[10].s89ab;
)"
R"(        r2 += src1.w * weights_cache[10].scdef;
)"
R"(        r3 += src1.x * weights_cache[11].s0123;
)"
R"(        r3 += src1.y * weights_cache[11].s4567;
)"
R"(        r3 += src1.z * weights_cache[11].s89ab;
)"
R"(        r3 += src1.w * weights_cache[11].scdef;
)"
R"(        r4 += src1.x * weights_cache[12].s0123;
)"
R"(        r4 += src1.y * weights_cache[12].s4567;
)"
R"(        r4 += src1.z * weights_cache[12].s89ab;
)"
R"(        r4 += src1.w * weights_cache[12].scdef;
)"
R"(        r5 += src1.x * weights_cache[13].s0123;
)"
R"(        r5 += src1.y * weights_cache[13].s4567;
)"
R"(        r5 += src1.z * weights_cache[13].s89ab;
)"
R"(        r5 += src1.w * weights_cache[13].scdef;
)"
R"(        r6 += src1.x * weights_cache[14].s0123;
)"
R"(        r6 += src1.y * weights_cache[14].s4567;
)"
R"(        r6 += src1.z * weights_cache[14].s89ab;
)"
R"(        r6 += src1.w * weights_cache[14].scdef;
)"
R"(        r7 += src1.x * weights_cache[15].s0123;
)"
R"(        r7 += src1.y * weights_cache[15].s4567;
)"
R"(        r7 += src1.z * weights_cache[15].s89ab;
)"
R"(        r7 += src1.w * weights_cache[15].scdef;
)"
R"(    } while (coord_s < shared_int4_2.x);
)"
R"(
)"
R"(    coord_s = mul24(Z, 8);
)"
R"(    coord_x = X;
)"
R"(    coord_y = Y;
)"
R"(    if (coord_s < shared_int4_0.y) {
)"
R"(        half4 res = convert_half4(r0);
)"
R"(        if (coord_s < 0) {
)"
R"(            res += read_imageh(src_tensor_image2d, smp_zero, (int2) ((0), ((0) * shared_int4_2.x + (0))));
)"
R"(        }
)"
R"(        dst_tensor_buffer[(((coord_s) *shared_int4_0.x + (coord_y)) * shared_int4_0.z + (coord_x))] = res;
)"
R"(        coord_s++;
)"
R"(    }
)"
R"(    if (coord_s < shared_int4_0.y) {
)"
R"(        half4 res = convert_half4(r1);
)"
R"(        if (coord_s < 0) {
)"
R"(            res += read_imageh(src_tensor_image2d, smp_zero, (int2) ((0), ((0) * shared_int4_2.x + (0))));
)"
R"(        }
)"
R"(        dst_tensor_buffer[(((coord_s) *shared_int4_0.x + (coord_y)) * shared_int4_0.z + (coord_x))] = res;
)"
R"(        coord_s++;
)"
R"(    }
)"
R"(    if (coord_s < shared_int4_0.y) {
)"
R"(        half4 res = convert_half4(r2);
)"
R"(        if (coord_s < 0) {
)"
R"(            res += read_imageh(src_tensor_image2d, smp_zero, (int2) ((0), ((0) * shared_int4_2.x + (0))));
)"
R"(        }
)"
R"(        dst_tensor_buffer[(((coord_s) *shared_int4_0.x + (coord_y)) * shared_int4_0.z + (coord_x))] = res;
)"
R"(        coord_s++;
)"
R"(    }
)"
R"(    if (coord_s < shared_int4_0.y) {
)"
R"(        half4 res = convert_half4(r3);
)"
R"(        if (coord_s < 0) {
)"
R"(            res += read_imageh(src_tensor_image2d, smp_zero, (int2) ((0), ((0) * shared_int4_2.x + (0))));
)"
R"(        }
)"
R"(        dst_tensor_buffer[(((coord_s) *shared_int4_0.x + (coord_y)) * shared_int4_0.z + (coord_x))] = res;
)"
R"(        coord_s++;
)"
R"(    }
)"
R"(    if (coord_s < shared_int4_0.y) {
)"
R"(        half4 res = convert_half4(r4);
)"
R"(        if (coord_s < 0) {
)"
R"(            res += read_imageh(src_tensor_image2d, smp_zero, (int2) ((0), ((0) * shared_int4_2.x + (0))));
)"
R"(        }
)"
R"(        dst_tensor_buffer[(((coord_s) *shared_int4_0.x + (coord_y)) * shared_int4_0.z + (coord_x))] = res;
)"
R"(        coord_s++;
)"
R"(    }
)"
R"(    if (coord_s < shared_int4_0.y) {
)"
R"(        half4 res = convert_half4(r5);
)"
R"(        if (coord_s < 0) {
)"
R"(            res += read_imageh(src_tensor_image2d, smp_zero, (int2) ((0), ((0) * shared_int4_2.x + (0))));
)"
R"(        }
)"
R"(        dst_tensor_buffer[(((coord_s) *shared_int4_0.x + (coord_y)) * shared_int4_0.z + (coord_x))] = res;
)"
R"(        coord_s++;
)"
R"(    }
)"
R"(    if (coord_s < shared_int4_0.y) {
)"
R"(        half4 res = convert_half4(r6);
)"
R"(        if (coord_s < 0) {
)"
R"(            res += read_imageh(src_tensor_image2d, smp_zero, (int2) ((0), ((0) * shared_int4_2.x + (0))));
)"
R"(        }
)"
R"(        dst_tensor_buffer[(((coord_s) *shared_int4_0.x + (coord_y)) * shared_int4_0.z + (coord_x))] = res;
)"
R"(        coord_s++;
)"
R"(    }
)"
R"(    if (coord_s < shared_int4_0.y) {
)"
R"(        half4 res = convert_half4(r7);
)"
R"(        if (coord_s < 0) {
)"
R"(            res += read_imageh(src_tensor_image2d, smp_zero, (int2) ((0), ((0) * shared_int4_2.x + (0))));
)"
R"(        }
)"
R"(        dst_tensor_buffer[(((coord_s) *shared_int4_0.x + (coord_y)) * shared_int4_0.z + (coord_x))] = res;
)"
R"(        coord_s++;
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(__kernel void adreno_xmem_attn_softmax_reduce_basic(read_only image1d_buffer_t src_tensor_image_buffer,
)"
R"(                                                    write_only image2d_t       dst_tensor_image2d,
)"
R"(                                                    const int4                 shared_int4_0,
)"
R"(                                                    const int4                 shared_int4_1) {
)"
R"(    int X = get_global_id(0);
)"
R"(    int Y = get_global_id(1);
)"
R"(    if (X >= shared_int4_0.z || Y >= shared_int4_0.x) {
)"
R"(        return;
)"
R"(    }
)"
R"(    float sum                     = 0.0f;
)"
R"(    int   end_channel             = shared_int4_0.w;
)"
R"(    int   end_slice               = (end_channel + 3) / 4;
)"
R"(    int   start_channel           = 0;
)"
R"(    int   start_slice             = start_channel / 4;
)"
R"(    bool  need_per_channels_check = start_channel % 4 != 0 || end_channel % 4 != 0;
)"
R"(    float maximum;
)"
R"(    {
)"
R"(        int    slice_coord_TMP  = (start_channel) / 4;
)"
R"(        int    sub_ch_coord_TMP = (start_channel) % 4;
)"
R"(        float4 src_TMP          = convert_float4(
)"
R"(            read_imageh(src_tensor_image_buffer, ((slice_coord_TMP) *shared_int4_1.x + (Y)) * shared_int4_1.y + (X)));
)"
R"(        maximum = (float[4]){ src_TMP.x, src_TMP.y, src_TMP.z, src_TMP.w }[sub_ch_coord_TMP];
)"
R"(    };
)"
R"(    for (int d = start_slice; d < end_slice; d += 1) {
)"
R"(        float4 mask_dot = (float4) (1.f);
)"
R"(        float4 src =
)"
R"(            convert_float4(read_imageh(src_tensor_image_buffer, ((d) *shared_int4_1.x + (Y)) * shared_int4_1.y + (X)));
)"
R"(        if (need_per_channels_check && (d == start_slice || d == end_slice - 1)) {
)"
R"(            if (d * 4 + 0 < start_channel || d * 4 + 0 >= end_channel) {
)"
R"(                mask_dot.x = 0.f;
)"
R"(                src.x      = maximum;
)"
R"(            }
)"
R"(            if (d * 4 + 1 < start_channel || d * 4 + 1 >= end_channel) {
)"
R"(                mask_dot.y = 0.f;
)"
R"(                src.y      = maximum;
)"
R"(            }
)"
R"(            if (d * 4 + 2 < start_channel || d * 4 + 2 >= end_channel) {
)"
R"(                mask_dot.z = 0.f;
)"
R"(                src.z      = maximum;
)"
R"(            }
)"
R"(            if (d * 4 + 3 < start_channel || d * 4 + 3 >= end_channel) {
)"
R"(                mask_dot.w = 0.f;
)"
R"(                src.w      = maximum;
)"
R"(            }
)"
R"(        }
)"
R"(        float new_max = max(src.x, src.y);
)"
R"(        new_max       = max(new_max, src.z);
)"
R"(        new_max       = max(new_max, src.w);
)"
R"(        new_max       = max(new_max, maximum);
)"
R"(        float scale   = native_exp(maximum - new_max);
)"
R"(        maximum       = new_max;
)"
R"(        sum *= scale;
)"
R"(        float4 exp_res = native_exp(src - maximum);
)"
R"(        sum += dot(mask_dot, exp_res);
)"
R"(    }
)"
R"(    if (!isfinite(maximum) || sum == 0.0f) {
)"
R"(        write_imageh(dst_tensor_image2d, (int2) (X, Y), (half4) (0.0h));
)"
R"(        return;
)"
R"(    }
)"
R"(    write_imageh(dst_tensor_image2d, (int2) (X, Y),
)"
R"(                 (half4) (convert_half(1.0f / sum), convert_half(maximum), 0.0h, 0.0h));
)"
R"(}
)"
R"(
)"
R"(__kernel void adreno_xmem_attn_softmax_apply_basic(global half4 *             dst_tensor_buffer,
)"
R"(                                                   read_only image1d_buffer_t src_tensor_image_buffer,
)"
R"(                                                   read_only image2d_t        src_tensor_1_image2d,
)"
R"(                                                   const int4                 shared_int4_0,
)"
R"(                                                   const int4                 shared_int4_1) {
)"
R"(    int X = get_global_id(0);
)"
R"(    int Y = get_global_id(1);
)"
R"(    int Z = get_global_id(2);
)"
R"(    if (X >= shared_int4_0.z || Y >= shared_int4_0.x || Z >= shared_int4_0.y) {
)"
R"(        return;
)"
R"(    }
)"
R"(    half4 src = read_imageh(src_tensor_image_buffer, ((Z) *shared_int4_1.x + (Y)) * shared_int4_1.y + (X));
)"
R"(    {
)"
R"(        half4 src_final;
)"
R"(        {
)"
R"(            {
)"
R"(                half4 exp_val = read_imageh(src_tensor_1_image2d, smp_zero, (int2) (X, Y));
)"
R"(                src_final = exp(src - exp_val.y) * exp_val.x;
)"
R"(                const int k = Z * 4;
)"
R"(                const int n_kv = shared_int4_1.z;
)"
R"(                if (k + 0 >= n_kv) {
)"
R"(                    src_final.x = 0.0h;
)"
R"(                }
)"
R"(                if (k + 1 >= n_kv) {
)"
R"(                    src_final.y = 0.0h;
)"
R"(                }
)"
R"(                if (k + 2 >= n_kv) {
)"
R"(                    src_final.z = 0.0h;
)"
R"(                }
)"
R"(                if (k + 3 >= n_kv) {
)"
R"(                    src_final.w = 0.0h;
)"
R"(                }
)"
R"(            }
)"
R"(        }
)"
R"(        dst_tensor_buffer[(((Z) *shared_int4_0.x + (Y)) * shared_int4_0.z + (X))] = src_final;
)"
R"(    };
)"
R"(}
)"
R"(
)"
R"(__kernel void adreno_xmem_attn_mask_scores(global half4 *             dst_score_tensor_buffer,
)"
R"(                                           read_only image1d_buffer_t src_score_image_buffer,
)"
R"(                                           const global half *        mask,
)"
R"(                                           const ulong                mask_offset,
)"
R"(                                           const int                  q_width,
)"
R"(                                           const int                  n_q,
)"
R"(                                           const int                  n_kv,
)"
R"(                                           const int                  n_kv_padded,
)"
R"(                                           const int                  kv_heads_total,
)"
R"(                                           const int                  n_head,
)"
R"(                                           const int                  n_head_kv,
)"
R"(                                           const ulong                mask_nb1,
)"
R"(                                           const ulong                mask_nb2,
)"
R"(                                           const ulong                mask_nb3,
)"
R"(                                           const int                  mask_ne2,
)"
R"(                                           const int                  mask_ne3) {
)"
R"(    const int X     = get_global_id(0);
)"
R"(    const int Y     = get_global_id(1);
)"
R"(    const int Z     = get_global_id(2);
)"
R"(    const int npack = n_kv_padded / 4;
)"
R"(    if (X >= q_width || Y >= kv_heads_total || Z >= npack) {
)"
R"(        return;
)"
R"(    }
)"
R"(
)"
R"(    const int           gqa            = n_head / n_head_kv;
)"
R"(    const int           head_kv        = Y % n_head_kv;
)"
R"(    const int           batch          = Y / n_head_kv;
)"
R"(    const int           head_group     = X / n_q;
)"
R"(    const int           q              = X - head_group * n_q;
)"
R"(    const int           head           = head_kv * gqa + head_group;
)"
R"(    const int           mask_head_idx  = head % mask_ne2;
)"
R"(    const int           mask_batch_idx = batch % mask_ne3;
)"
R"(    const global char *  mask_base      = (const global char *) mask + mask_offset;
)"
R"(    const global half *  mask_row       = (const global half *) (mask_base + mask_batch_idx * mask_nb3 +
)"
R"(                                                                 mask_head_idx * mask_nb2 + q * mask_nb1);
)"
R"(
)"
R"(    const half4 score   = read_imageh(src_score_image_buffer, ((Z * kv_heads_total + Y) * q_width + X));
)"
R"(    float       vals[4] = {
)"
R"(        convert_float(score.x),
)"
R"(        convert_float(score.y),
)"
R"(        convert_float(score.z),
)"
R"(        convert_float(score.w),
)"
R"(    };
)"
R"(
)"
R"(    for (int lane = 0; lane < 4; ++lane) {
)"
R"(        const int k_idx = Z * 4 + lane;
)"
R"(        if (k_idx >= n_kv) {
)"
R"(            vals[lane] = -INFINITY;
)"
R"(        } else {
)"
R"(            vals[lane] += convert_float(mask_row[k_idx]);
)"
R"(        }
)"
R"(    }
)"
R"(
)"
R"(    dst_score_tensor_buffer[((Z * kv_heads_total + Y) * q_width + X)] =
)"
R"(        (half4) (convert_half(vals[0]), convert_half(vals[1]), convert_half(vals[2]), convert_half(vals[3]));
)"
R"(}
)"
R"(
)"
R"(__kernel void adreno_xmem_attn_pack_v(global half4 *      dst_tensor_buffer,
)"
R"(                                      read_only image2d_t src_image2d,
)"
R"(                                      const int4          shared_int4_0,
)"
R"(                                      const int4          shared_int4_1) {
)"
R"(    int linear_index = get_global_id(0);
)"
R"(    if (linear_index >= shared_int4_0.y) {
)"
R"(        return;
)"
R"(    }
)"
R"(    if (get_global_id(1) != 0) {
)"
R"(        return;
)"
R"(    }
)"
R"(    if (get_global_id(2) != 0) {
)"
R"(        return;
)"
R"(    }
)"
R"(    int   dst_o_sp_i_ogroup = linear_index;
)"
R"(    int   dst_ogroup        = dst_o_sp_i_ogroup % shared_int4_0.x;
)"
R"(    int   dst_o_sp_i        = dst_o_sp_i_ogroup / shared_int4_0.x;
)"
R"(    int   dst_i             = dst_o_sp_i % shared_int4_0.z;
)"
R"(    int   dst_o_sp          = dst_o_sp_i / shared_int4_0.z;
)"
R"(    int   dst_sp            = dst_o_sp % shared_int4_1.x;
)"
R"(    int   dst_o             = dst_o_sp / shared_int4_1.x;
)"
R"(    int   i_slice           = dst_i;
)"
R"(    int   o_slice           = dst_o * shared_int4_0.x + dst_ogroup;
)"
R"(    int   spatial_linear    = dst_sp;
)"
R"(    int   W                 = spatial_linear % shared_int4_1.y;
)"
R"(    int   H                 = spatial_linear / shared_int4_1.y;
)"
R"(    half4 w0                = (half4) (0);
)"
R"(    half4 w1                = (half4) (0);
)"
R"(    half4 w2                = (half4) (0);
)"
R"(    half4 w3                = (half4) (0);
)"
R"(
)"
R"(    if (i_slice * 4 < shared_int4_0.w && o_slice < shared_int4_1.z) {
)"
R"(        w0 = read_imageh(src_image2d, smp_zero, (int2) ((i_slice * 4), ((W) *shared_int4_1.z + (o_slice))));
)"
R"(    }
)"
R"(    if (i_slice * 4 + 1 < shared_int4_0.w && o_slice < shared_int4_1.z) {
)"
R"(        w1 = read_imageh(src_image2d, smp_zero, (int2) ((i_slice * 4 + 1), ((W) *shared_int4_1.z + (o_slice))));
)"
R"(    }
)"
R"(    if (i_slice * 4 + 2 < shared_int4_0.w && o_slice < shared_int4_1.z) {
)"
R"(        w2 = read_imageh(src_image2d, smp_zero, (int2) ((i_slice * 4 + 2), ((W) *shared_int4_1.z + (o_slice))));
)"
R"(    }
)"
R"(    if (i_slice * 4 + 3 < shared_int4_0.w && o_slice < shared_int4_1.z) {
)"
R"(        w3 = read_imageh(src_image2d, smp_zero, (int2) ((i_slice * 4 + 3), ((W) *shared_int4_1.z + (o_slice))));
)"
R"(    }
)"
R"(    half4 r0                                = w0;
)"
R"(    half4 r1                                = w1;
)"
R"(    half4 r2                                = w2;
)"
R"(    half4 r3                                = w3;
)"
R"(    dst_tensor_buffer[linear_index * 4 + 0] = r0;
)"
R"(    dst_tensor_buffer[linear_index * 4 + 1] = r1;
)"
R"(    dst_tensor_buffer[linear_index * 4 + 2] = r2;
)"
R"(    dst_tensor_buffer[linear_index * 4 + 3] = r3;
)"
R"(}
)"
R"(
)"
R"(__attribute__((qcom_max_concurrent_subgroups(12))) __kernel void adreno_xmem_attn_pv_gemm(
)"
R"(    constant half8 *           weights_buffer __attribute__((sub_group_uniform)),
)"
R"(    constant half8 *           xmem_buffer __attribute__((max_constant_size((6144)))),
)"
R"(    read_only image1d_buffer_t src_tensor_image_buffer,
)"
R"(    write_only image2d_t       dst_tensor_image2d,
)"
R"(    const int4                 shared_int4_0,
)"
R"(    const int4                 shared_int4_1,
)"
R"(    const int4                 shared_int4_2,
)"
R"(    const int4                 shared_int4_3) {
)"
R"(    int X = get_group_id(1) * get_local_size(0) + get_local_id(0);
)"
R"(    int Y = get_group_id(2) * get_local_size(1) + get_local_id(1);
)"
R"(    int Z = get_group_id(0) * get_local_size(2) + get_local_id(2);
)"
R"(    if (X >= shared_int4_0.z || Y >= shared_int4_0.x) {
)"
R"(        return;
)"
R"(    }
)"
R"(    if (Z * 8 >= shared_int4_0.y) {
)"
R"(        return;
)"
R"(    }
)"
R"(
)"
R"(    half4 r0      = (half4) (0.f);
)"
R"(    half4 r1      = (half4) (0.f);
)"
R"(    half4 r2      = (half4) (0.f);
)"
R"(    half4 r3      = (half4) (0.f);
)"
R"(    half4 r4      = (half4) (0.f);
)"
R"(    half4 r5      = (half4) (0.f);
)"
R"(    half4 r6      = (half4) (0.f);
)"
R"(    half4 r7      = (half4) (0.f);
)"
R"(    int   x_coord = mad24(X, shared_int4_2.w, shared_int4_1.y);
)"
R"(    int   y_coord = mad24(Y, shared_int4_3.x, shared_int4_1.z);
)"
R"(    int   coord_x, coord_y, coord_s;
)"
R"(    int   f_offset = (Z * shared_int4_1.w + Y) * shared_int4_1.x * 32;
)"
R"(
)"
R"(    int subgroup_id                   = (int) ((0x1F & qcom_get_physical_sub_group_id()));
)"
R"(    subgroup_id                       = subgroup_id % 12;
)"
R"(    int                 c_offset      = mul24(subgroup_id, shared_int4_0.w);
)"
R"(    __constant half16 * weights_cache = (__constant half16 *) &xmem_buffer[c_offset];
)"
R"(    coord_y                           = Y;
)"
R"(    coord_x                           = X;
)"
R"(    int addr                          = (((0) * shared_int4_1.w + (coord_y)) * shared_int4_2.z + (coord_x));
)"
R"(    int dz                            = shared_int4_2.x;
)"
R"(    coord_s                           = 0;
)"
R"(    do {
)"
R"(        half4 src0 = read_imageh(src_tensor_image_buffer, addr);
)"
R"(        addr += dz;
)"
R"(        coord_s++;
)"
R"(        half4 src1 = read_imageh(src_tensor_image_buffer, addr);
)"
R"(        addr += dz;
)"
R"(        coord_s++;
)"
R"(        qcom_sub_group_constant_load8(xmem_buffer, weights_buffer, c_offset, f_offset >> 1, 32);
)"
R"(        f_offset += 64;
)"
R"(        qcom_sub_group_sync(QCOM_CLK_CONST_LOAD_SYNC);
)"
R"(        r0 += src0.x * weights_cache[0].s0123;
)"
R"(        r0 += src0.y * weights_cache[0].s4567;
)"
R"(        r0 += src0.z * weights_cache[0].s89ab;
)"
R"(        r0 += src0.w * weights_cache[0].scdef;
)"
R"(        r1 += src0.x * weights_cache[1].s0123;
)"
R"(        r1 += src0.y * weights_cache[1].s4567;
)"
R"(        r1 += src0.z * weights_cache[1].s89ab;
)"
R"(        r1 += src0.w * weights_cache[1].scdef;
)"
R"(        r2 += src0.x * weights_cache[2].s0123;
)"
R"(        r2 += src0.y * weights_cache[2].s4567;
)"
R"(        r2 += src0.z * weights_cache[2].s89ab;
)"
R"(        r2 += src0.w * weights_cache[2].scdef;
)"
R"(        r3 += src0.x * weights_cache[3].s0123;
)"
R"(        r3 += src0.y * weights_cache[3].s4567;
)"
R"(        r3 += src0.z * weights_cache[3].s89ab;
)"
R"(        r3 += src0.w * weights_cache[3].scdef;
)"
R"(        r4 += src0.x * weights_cache[4].s0123;
)"
R"(        r4 += src0.y * weights_cache[4].s4567;
)"
R"(        r4 += src0.z * weights_cache[4].s89ab;
)"
R"(        r4 += src0.w * weights_cache[4].scdef;
)"
R"(        r5 += src0.x * weights_cache[5].s0123;
)"
R"(        r5 += src0.y * weights_cache[5].s4567;
)"
R"(        r5 += src0.z * weights_cache[5].s89ab;
)"
R"(        r5 += src0.w * weights_cache[5].scdef;
)"
R"(        r6 += src0.x * weights_cache[6].s0123;
)"
R"(        r6 += src0.y * weights_cache[6].s4567;
)"
R"(        r6 += src0.z * weights_cache[6].s89ab;
)"
R"(        r6 += src0.w * weights_cache[6].scdef;
)"
R"(        r7 += src0.x * weights_cache[7].s0123;
)"
R"(        r7 += src0.y * weights_cache[7].s4567;
)"
R"(        r7 += src0.z * weights_cache[7].s89ab;
)"
R"(        r7 += src0.w * weights_cache[7].scdef;
)"
R"(        r0 += src1.x * weights_cache[8].s0123;
)"
R"(        r0 += src1.y * weights_cache[8].s4567;
)"
R"(        r0 += src1.z * weights_cache[8].s89ab;
)"
R"(        r0 += src1.w * weights_cache[8].scdef;
)"
R"(        r1 += src1.x * weights_cache[9].s0123;
)"
R"(        r1 += src1.y * weights_cache[9].s4567;
)"
R"(        r1 += src1.z * weights_cache[9].s89ab;
)"
R"(        r1 += src1.w * weights_cache[9].scdef;
)"
R"(        r2 += src1.x * weights_cache[10].s0123;
)"
R"(        r2 += src1.y * weights_cache[10].s4567;
)"
R"(        r2 += src1.z * weights_cache[10].s89ab;
)"
R"(        r2 += src1.w * weights_cache[10].scdef;
)"
R"(        r3 += src1.x * weights_cache[11].s0123;
)"
R"(        r3 += src1.y * weights_cache[11].s4567;
)"
R"(        r3 += src1.z * weights_cache[11].s89ab;
)"
R"(        r3 += src1.w * weights_cache[11].scdef;
)"
R"(        r4 += src1.x * weights_cache[12].s0123;
)"
R"(        r4 += src1.y * weights_cache[12].s4567;
)"
R"(        r4 += src1.z * weights_cache[12].s89ab;
)"
R"(        r4 += src1.w * weights_cache[12].scdef;
)"
R"(        r5 += src1.x * weights_cache[13].s0123;
)"
R"(        r5 += src1.y * weights_cache[13].s4567;
)"
R"(        r5 += src1.z * weights_cache[13].s89ab;
)"
R"(        r5 += src1.w * weights_cache[13].scdef;
)"
R"(        r6 += src1.x * weights_cache[14].s0123;
)"
R"(        r6 += src1.y * weights_cache[14].s4567;
)"
R"(        r6 += src1.z * weights_cache[14].s89ab;
)"
R"(        r6 += src1.w * weights_cache[14].scdef;
)"
R"(        r7 += src1.x * weights_cache[15].s0123;
)"
R"(        r7 += src1.y * weights_cache[15].s4567;
)"
R"(        r7 += src1.z * weights_cache[15].s89ab;
)"
R"(        r7 += src1.w * weights_cache[15].scdef;
)"
R"(    } while (coord_s < shared_int4_2.y);
)"
R"(
)"
R"(    coord_s = mul24(Z, 8);
)"
R"(    coord_x = X;
)"
R"(    coord_y = Y;
)"
R"(    if (coord_s < shared_int4_0.y) {
)"
R"(        half4 res = convert_half4(r0);
)"
R"(        if (coord_s < 0) {
)"
R"(            res += read_imageh(src_tensor_image_buffer, ((0) * shared_int4_1.w + (0)) * shared_int4_2.z + (0));
)"
R"(        }
)"
R"(        write_imageh(dst_tensor_image2d, (int2) ((coord_x), ((coord_y) *shared_int4_0.y + (coord_s))), res);
)"
R"(        coord_s++;
)"
R"(    }
)"
R"(    if (coord_s < shared_int4_0.y) {
)"
R"(        half4 res = convert_half4(r1);
)"
R"(        if (coord_s < 0) {
)"
R"(            res += read_imageh(src_tensor_image_buffer, ((0) * shared_int4_1.w + (0)) * shared_int4_2.z + (0));
)"
R"(        }
)"
R"(        write_imageh(dst_tensor_image2d, (int2) ((coord_x), ((coord_y) *shared_int4_0.y + (coord_s))), res);
)"
R"(        coord_s++;
)"
R"(    }
)"
R"(    if (coord_s < shared_int4_0.y) {
)"
R"(        half4 res = convert_half4(r2);
)"
R"(        if (coord_s < 0) {
)"
R"(            res += read_imageh(src_tensor_image_buffer, ((0) * shared_int4_1.w + (0)) * shared_int4_2.z + (0));
)"
R"(        }
)"
R"(        write_imageh(dst_tensor_image2d, (int2) ((coord_x), ((coord_y) *shared_int4_0.y + (coord_s))), res);
)"
R"(        coord_s++;
)"
R"(    }
)"
R"(    if (coord_s < shared_int4_0.y) {
)"
R"(        half4 res = convert_half4(r3);
)"
R"(        if (coord_s < 0) {
)"
R"(            res += read_imageh(src_tensor_image_buffer, ((0) * shared_int4_1.w + (0)) * shared_int4_2.z + (0));
)"
R"(        }
)"
R"(        write_imageh(dst_tensor_image2d, (int2) ((coord_x), ((coord_y) *shared_int4_0.y + (coord_s))), res);
)"
R"(        coord_s++;
)"
R"(    }
)"
R"(    if (coord_s < shared_int4_0.y) {
)"
R"(        half4 res = convert_half4(r4);
)"
R"(        if (coord_s < 0) {
)"
R"(            res += read_imageh(src_tensor_image_buffer, ((0) * shared_int4_1.w + (0)) * shared_int4_2.z + (0));
)"
R"(        }
)"
R"(        write_imageh(dst_tensor_image2d, (int2) ((coord_x), ((coord_y) *shared_int4_0.y + (coord_s))), res);
)"
R"(        coord_s++;
)"
R"(    }
)"
R"(    if (coord_s < shared_int4_0.y) {
)"
R"(        half4 res = convert_half4(r5);
)"
R"(        if (coord_s < 0) {
)"
R"(            res += read_imageh(src_tensor_image_buffer, ((0) * shared_int4_1.w + (0)) * shared_int4_2.z + (0));
)"
R"(        }
)"
R"(        write_imageh(dst_tensor_image2d, (int2) ((coord_x), ((coord_y) *shared_int4_0.y + (coord_s))), res);
)"
R"(        coord_s++;
)"
R"(    }
)"
R"(    if (coord_s < shared_int4_0.y) {
)"
R"(        half4 res = convert_half4(r6);
)"
R"(        if (coord_s < 0) {
)"
R"(            res += read_imageh(src_tensor_image_buffer, ((0) * shared_int4_1.w + (0)) * shared_int4_2.z + (0));
)"
R"(        }
)"
R"(        write_imageh(dst_tensor_image2d, (int2) ((coord_x), ((coord_y) *shared_int4_0.y + (coord_s))), res);
)"
R"(        coord_s++;
)"
R"(    }
)"
R"(    if (coord_s < shared_int4_0.y) {
)"
R"(        half4 res = convert_half4(r7);
)"
R"(        if (coord_s < 0) {
)"
R"(            res += read_imageh(src_tensor_image_buffer, ((0) * shared_int4_1.w + (0)) * shared_int4_2.z + (0));
)"
R"(        }
)"
R"(        write_imageh(dst_tensor_image2d, (int2) ((coord_x), ((coord_y) *shared_int4_0.y + (coord_s))), res);
)"
R"(        coord_s++;
)"
R"(    }
)"
R"(}
)"
