R"(#pragma OPENCL EXTENSION cl_khr_fp16 : enable
)"
R"(// write_imageh into image3d_t needs this enabled; the Adreno 650 vendor compiler rejects it
)"
R"(// otherwise and the model fails to load. Both stacks advertise the extension.
)"
R"(#pragma OPENCL EXTENSION cl_khr_3d_image_writes : enable
)"
R"(
)"
R"(__kernel void kernel_repack_mask_for_wmm(
)"
R"(    const global half* mask_buf,
)"
R"(    const ulong mask_nb1,
)"
R"(    const ulong mask_nb2,
)"
R"(    const ulong mask_nb3,
)"
R"(    const int mask_ne2,
)"
R"(    global half* mask_buf_padded,
)"
R"(    const ulong mask_nb1_padded,
)"
R"(    const ulong mask_nb2_padded,
)"
R"(    const ulong mask_nb3_padded
)"
R"() {
)"
R"(    int col   = get_global_id(0);   // 0 .. n_kv
)"
R"(    int row   = get_global_id(1);   // 0 .. n_q
)"
R"(    int slice = get_global_id(2);   // 0 .. (n_head * n_batch)
)"
R"(
)"
R"(    int head_idx  = slice % mask_ne2;
)"
R"(    int batch_idx = slice / mask_ne2;
)"
R"(
)"
R"(    ulong src_off = (ulong)batch_idx * mask_nb3 + (ulong)head_idx * mask_nb2 + (ulong)row * mask_nb1;
)"
R"(    ulong dst_off = (ulong)batch_idx * mask_nb3_padded + (ulong)head_idx * mask_nb2_padded + (ulong)row * mask_nb1_padded;
)"
R"(
)"
R"(    mask_buf_padded[dst_off / 2 + col] = mask_buf[src_off / 2 + col];
)"
R"(}
)"
R"(
)"
R"(__kernel void kernel_repack_q_for_wmm(
)"
R"(    const global float* q_buf,
)"
R"(    const ulong q_nb1,
)"
R"(    const ulong q_nb2,
)"
R"(    const ulong q_nb3,
)"
R"(    const int n_head,
)"
R"(    __write_only image3d_t img_q_wmm
)"
R"() {
)"
R"(    int k4    = get_global_id(0);
)"
R"(    int row   = get_global_id(1);
)"
R"(    int slice = get_global_id(2);
)"
R"(    int batch_idx = slice / n_head;
)"
R"(    int head_idx  = slice % n_head;
)"
R"(
)"
R"(
)"
R"(    ulong elem_off = (batch_idx * q_nb3 + head_idx * q_nb2 + row * q_nb1) / 4 + (ulong)k4 * 4;
)"
R"(    float4 v = vload4(elem_off / 4, q_buf);
)"
R"(
)"
R"(    write_imageh(img_q_wmm, (int4)(row, slice, k4, 0), convert_half4(v));
)"
R"(}
)"
R"(
)"
R"(__kernel void kernel_repack_k_for_wmm(
)"
R"(    const global half* k_buf,
)"
R"(    const ulong k_nb1,
)"
R"(    const ulong k_nb2,
)"
R"(    const ulong k_nb3,
)"
R"(    const int n_head_kv,
)"
R"(    const int n_kv,
)"
R"(    __write_only image3d_t img_k_wmm
)"
R"() {
)"
R"(    int kk    = get_global_id(0);
)"
R"(    int row4  = get_global_id(1);
)"
R"(    int slice = get_global_id(2);
)"
R"(    int batch_idx   = slice / n_head_kv;
)"
R"(    int head_kv_idx = slice % n_head_kv;
)"
R"(
)"
R"(    ulong base = batch_idx * k_nb3 + head_kv_idx * k_nb2;
)"
R"(    int row0 = row4 * 4;
)"
R"(    half4 v;
)"
R"(    v.x = (row0 + 0 < n_kv) ? k_buf[(base + (ulong)(row0 + 0) * k_nb1) / 2 + kk] : (half)0;
)"
R"(    v.y = (row0 + 1 < n_kv) ? k_buf[(base + (ulong)(row0 + 1) * k_nb1) / 2 + kk] : (half)0;
)"
R"(    v.z = (row0 + 2 < n_kv) ? k_buf[(base + (ulong)(row0 + 2) * k_nb1) / 2 + kk] : (half)0;
)"
R"(    v.w = (row0 + 3 < n_kv) ? k_buf[(base + (ulong)(row0 + 3) * k_nb1) / 2 + kk] : (half)0;
)"
R"(
)"
R"(    write_imageh(img_k_wmm, (int4)(kk, row4, slice, 0), v);
)"
R"(}
)"
R"(
)"
R"(__kernel void kernel_repack_v_for_wmm(
)"
R"(      const global half* v_buf,
)"
R"(      const ulong v_nb1,
)"
R"(      const ulong v_nb2,
)"
R"(      const ulong v_nb3,
)"
R"(      const int n_head_kv,
)"
R"(      __write_only image3d_t img_v_wmm
)"
R"() {
)"
R"(    int hdim4   = get_global_id(0);   // now fastest — walks contiguous memory
)"
R"(    int row     = get_global_id(1);
)"
R"(    int slice   = get_global_id(2);
)"
R"(    int batch_idx   = slice / n_head_kv;
)"
R"(    int head_kv_idx = slice % n_head_kv;
)"
R"(
)"
R"(    ulong row_off = batch_idx * v_nb3 + head_kv_idx * v_nb2 + (ulong)row * v_nb1;
)"
R"(    half4 v = vload4((row_off / 2 + (ulong)hdim4 * 4) / 4, v_buf);
)"
R"(
)"
R"(    write_imageh(img_v_wmm, (int4)(row, hdim4, slice, 0), v);
)"
R"(}
)"
