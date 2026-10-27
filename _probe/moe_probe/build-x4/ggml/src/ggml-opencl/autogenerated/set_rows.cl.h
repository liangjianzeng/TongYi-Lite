R"(#pragma OPENCL EXTENSION cl_khr_fp16 : enable
)"
R"(
)"
R"(// v = { mp, L, d }
)"
R"(inline uint fastdiv(uint n, uint4 v) {
)"
R"(    uint msbs;
)"
R"(    msbs = mul_hi(n, v.s0);
)"
R"(    return (msbs + n) >> v.s1;
)"
R"(}
)"
R"(inline uint fastmod(uint n, uint4 v) {
)"
R"(    uint q = fastdiv(n, v);
)"
R"(    return n - q * v.s2;
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_set_rows_f32_i64(
)"
R"(        global char * src0,
)"
R"(        ulong         offset0,
)"
R"(        global char * src1,
)"
R"(        ulong         offset1,
)"
R"(        global char * dst,
)"
R"(        ulong         offsetd,
)"
R"(        int           ne01,
)"
R"(        ulong         nb01,
)"
R"(        ulong         nb02,
)"
R"(        ulong         nb03,
)"
R"(        uint4         ne11,
)"
R"(        uint4         ne12,
)"
R"(        ulong         nb10,
)"
R"(        ulong         nb11,
)"
R"(        ulong         nb12,
)"
R"(        int           nblk0,
)"
R"(        ulong         nb1,
)"
R"(        ulong         nb2,
)"
R"(        ulong         nb3
)"
R"() {
)"
R"(    src0 = src0 + offset0;
)"
R"(    src1 = src1 + offset1;
)"
R"(    dst  = dst  + offsetd;
)"
R"(
)"
R"(    int i03 = get_group_id(2);
)"
R"(    int i02 = get_group_id(1);
)"
R"(    int i01 = get_group_id(0)*get_local_size(1) + get_local_id(1);
)"
R"(
)"
R"(    if (i01 >= ne01) {
)"
R"(        return;
)"
R"(    }
)"
R"(
)"
R"(    //int i12 = i03%ne12;
)"
R"(    //int i11 = i02%ne11;
)"
R"(    int i12 = fastmod(i03, ne12);
)"
R"(    int i11 = fastmod(i02, ne11);
)"
R"(
)"
R"(    int i10 = i01;
)"
R"(    long i1 = ((global long *)(src1 + i10*nb10 + i11*nb11 + i12*nb12))[0];
)"
R"(
)"
R"(    global float * dst_row = (global float *) (dst  +  i1*nb1  + i02*nb2  + i03*nb3);
)"
R"(    global float * src_row = (global float *) (src0 + i01*nb01 + i02*nb02 + i03*nb03);
)"
R"(
)"
R"(    for (int ind = get_local_id(0); ind < nblk0; ind += get_local_size(0)) {
)"
R"(        dst_row[ind] = (float)src_row[ind];
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_set_rows_f16_i64(
)"
R"(        global char * src0,
)"
R"(        ulong         offset0,
)"
R"(        global char * src1,
)"
R"(        ulong         offset1,
)"
R"(        global char * dst,
)"
R"(        ulong         offsetd,
)"
R"(        int           ne01,
)"
R"(        ulong         nb01,
)"
R"(        ulong         nb02,
)"
R"(        ulong         nb03,
)"
R"(        uint4         ne11,
)"
R"(        uint4         ne12,
)"
R"(        ulong         nb10,
)"
R"(        ulong         nb11,
)"
R"(        ulong         nb12,
)"
R"(        int           nblk0,
)"
R"(        ulong         nb1,
)"
R"(        ulong         nb2,
)"
R"(        ulong         nb3
)"
R"() {
)"
R"(    src0 = src0 + offset0;
)"
R"(    src1 = src1 + offset1;
)"
R"(    dst  = dst  + offsetd;
)"
R"(
)"
R"(    int i03 = get_group_id(2);
)"
R"(    int i02 = get_group_id(1);
)"
R"(    int i01 = get_group_id(0)*get_local_size(1) + get_local_id(1);
)"
R"(
)"
R"(    if (i01 >= ne01) {
)"
R"(        return;
)"
R"(    }
)"
R"(
)"
R"(    //int i12 = i03%ne12;
)"
R"(    //int i11 = i02%ne11;
)"
R"(    int i12 = fastmod(i03, ne12);
)"
R"(    int i11 = fastmod(i02, ne11);
)"
R"(
)"
R"(    int i10 = i01;
)"
R"(    long i1 = ((global long *)(src1 + i10*nb10 + i11*nb11 + i12*nb12))[0];
)"
R"(
)"
R"(    global half  * dst_row = (global half  *) (dst  +  i1*nb1  + i02*nb2  + i03*nb3);
)"
R"(    global float * src_row = (global float *) (src0 + i01*nb01 + i02*nb02 + i03*nb03);
)"
R"(
)"
R"(    for (int ind = get_local_id(0); ind < nblk0; ind += get_local_size(0)) {
)"
R"(        dst_row[ind] = src_row[ind];
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_set_rows_f32_i32(
)"
R"(        global char * src0,
)"
R"(        ulong         offset0,
)"
R"(        global char * src1,
)"
R"(        ulong         offset1,
)"
R"(        global char * dst,
)"
R"(        ulong         offsetd,
)"
R"(        int           ne01,
)"
R"(        ulong         nb01,
)"
R"(        ulong         nb02,
)"
R"(        ulong         nb03,
)"
R"(        uint4         ne11,
)"
R"(        uint4         ne12,
)"
R"(        ulong         nb10,
)"
R"(        ulong         nb11,
)"
R"(        ulong         nb12,
)"
R"(        int           nblk0,
)"
R"(        ulong         nb1,
)"
R"(        ulong         nb2,
)"
R"(        ulong         nb3
)"
R"() {
)"
R"(    src0 = src0 + offset0;
)"
R"(    src1 = src1 + offset1;
)"
R"(    dst  = dst  + offsetd;
)"
R"(
)"
R"(    int i03 = get_group_id(2);
)"
R"(    int i02 = get_group_id(1);
)"
R"(    int i01 = get_group_id(0)*get_local_size(1) + get_local_id(1);
)"
R"(
)"
R"(    if (i01 >= ne01) {
)"
R"(        return;
)"
R"(    }
)"
R"(
)"
R"(    //int i12 = i03%ne12;
)"
R"(    //int i11 = i02%ne11;
)"
R"(    int i12 = fastmod(i03, ne12);
)"
R"(    int i11 = fastmod(i02, ne11);
)"
R"(
)"
R"(    int i10 = i01;
)"
R"(    int i1  = ((global int *)(src1 + i10*nb10 + i11*nb11 + i12*nb12))[0];
)"
R"(
)"
R"(    global float * dst_row = (global float *) (dst  +  i1*nb1  + i02*nb2  + i03*nb3);
)"
R"(    global float * src_row = (global float *) (src0 + i01*nb01 + i02*nb02 + i03*nb03);
)"
R"(
)"
R"(    for (int ind = get_local_id(0); ind < nblk0; ind += get_local_size(0)) {
)"
R"(        dst_row[ind] = (float)src_row[ind];
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(// f32 -> q8_0 quantize set_rows. Block = half d + char qs[32].
)"
R"(#define QK8_0 32
)"
R"(
)"
R"(inline void quantize_q8_0_block(global float * x, global char * qs, global half * d_out) {
)"
R"(    float amax = 0.0f;
)"
R"(    for (int j = 0; j < QK8_0; j++) {
)"
R"(        amax = fmax(amax, fabs(x[j]));
)"
R"(    }
)"
R"(
)"
R"(    float d  = amax / 127.0f;
)"
R"(    float id = (d != 0.0f) ? 127.0f / amax : 0.0f;
)"
R"(
)"
R"(    vstore_half(d, 0, d_out);
)"
R"(
)"
R"(    for (int j = 0; j < QK8_0; j++) {
)"
R"(        qs[j] = (char)((int)round(x[j] * id));
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_set_rows_q8_0_i64(
)"
R"(        global char * src0,
)"
R"(        ulong         offset0,
)"
R"(        global char * src1,
)"
R"(        ulong         offset1,
)"
R"(        global char * dst,
)"
R"(        ulong         offsetd,
)"
R"(        int           ne01,
)"
R"(        ulong         nb01,
)"
R"(        ulong         nb02,
)"
R"(        ulong         nb03,
)"
R"(        uint4         ne11,
)"
R"(        uint4         ne12,
)"
R"(        ulong         nb10,
)"
R"(        ulong         nb11,
)"
R"(        ulong         nb12,
)"
R"(        int           nblk0,
)"
R"(        ulong         nb1,
)"
R"(        ulong         nb2,
)"
R"(        ulong         nb3
)"
R"() {
)"
R"(    src0 = src0 + offset0;
)"
R"(    src1 = src1 + offset1;
)"
R"(    dst  = dst  + offsetd;
)"
R"(
)"
R"(    int i03 = get_group_id(2);
)"
R"(    int i02 = get_group_id(1);
)"
R"(    int i01 = get_group_id(0)*get_local_size(1) + get_local_id(1);
)"
R"(
)"
R"(    if (i01 >= ne01) {
)"
R"(        return;
)"
R"(    }
)"
R"(
)"
R"(    int i12 = fastmod(i03, ne12);
)"
R"(    int i11 = fastmod(i02, ne11);
)"
R"(
)"
R"(    int i10 = i01;
)"
R"(    long i1 = ((global long *)(src1 + i10*nb10 + i11*nb11 + i12*nb12))[0];
)"
R"(
)"
R"(    global char  * dst_row = (global char  *) (dst  +  i1*nb1  + i02*nb2  + i03*nb3);
)"
R"(    global float * src_row = (global float *) (src0 + i01*nb01 + i02*nb02 + i03*nb03);
)"
R"(
)"
R"(    for (int blk = get_local_id(0); blk < nblk0; blk += get_local_size(0)) {
)"
R"(        global float * x = src_row + blk * QK8_0;
)"
R"(        global char  * y = dst_row + blk * (2 + QK8_0);
)"
R"(
)"
R"(        quantize_q8_0_block(x, y + 2, (global half *)y);
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_set_rows_q8_0_i32(
)"
R"(        global char * src0,
)"
R"(        ulong         offset0,
)"
R"(        global char * src1,
)"
R"(        ulong         offset1,
)"
R"(        global char * dst,
)"
R"(        ulong         offsetd,
)"
R"(        int           ne01,
)"
R"(        ulong         nb01,
)"
R"(        ulong         nb02,
)"
R"(        ulong         nb03,
)"
R"(        uint4         ne11,
)"
R"(        uint4         ne12,
)"
R"(        ulong         nb10,
)"
R"(        ulong         nb11,
)"
R"(        ulong         nb12,
)"
R"(        int           nblk0,
)"
R"(        ulong         nb1,
)"
R"(        ulong         nb2,
)"
R"(        ulong         nb3
)"
R"() {
)"
R"(    src0 = src0 + offset0;
)"
R"(    src1 = src1 + offset1;
)"
R"(    dst  = dst  + offsetd;
)"
R"(
)"
R"(    int i03 = get_group_id(2);
)"
R"(    int i02 = get_group_id(1);
)"
R"(    int i01 = get_group_id(0)*get_local_size(1) + get_local_id(1);
)"
R"(
)"
R"(    if (i01 >= ne01) {
)"
R"(        return;
)"
R"(    }
)"
R"(
)"
R"(    int i12 = fastmod(i03, ne12);
)"
R"(    int i11 = fastmod(i02, ne11);
)"
R"(
)"
R"(    int i10 = i01;
)"
R"(    int i1  = ((global int *)(src1 + i10*nb10 + i11*nb11 + i12*nb12))[0];
)"
R"(
)"
R"(    global char  * dst_row = (global char  *) (dst  +  i1*nb1  + i02*nb2  + i03*nb3);
)"
R"(    global float * src_row = (global float *) (src0 + i01*nb01 + i02*nb02 + i03*nb03);
)"
R"(
)"
R"(    for (int blk = get_local_id(0); blk < nblk0; blk += get_local_size(0)) {
)"
R"(        global float * x = src_row + blk * QK8_0;
)"
R"(        global char  * y = dst_row + blk * (2 + QK8_0);
)"
R"(
)"
R"(        quantize_q8_0_block(x, y + 2, (global half *)y);
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(// SoA q8_0 variants. dst_q: int8[QK8_0] per block; dst_d: fp16 scale per block.
)"
R"(// Layout matches kernel_convert_block_q8_0; block index follows dst element order.
)"
R"(kernel void kernel_set_rows_q8_0_soa_i64(
)"
R"(        global char * src0,
)"
R"(        ulong         offset0,
)"
R"(        global char * src1,
)"
R"(        ulong         offset1,
)"
R"(        global char * dst_q,
)"
R"(        ulong         offset_q,
)"
R"(        global char * dst_d,
)"
R"(        ulong         offset_d,
)"
R"(        int           ne01,
)"
R"(        ulong         nb01,
)"
R"(        ulong         nb02,
)"
R"(        ulong         nb03,
)"
R"(        uint4         ne11,
)"
R"(        uint4         ne12,
)"
R"(        ulong         nb10,
)"
R"(        ulong         nb11,
)"
R"(        ulong         nb12,
)"
R"(        int           nblk0,
)"
R"(        int           ne1_dst,
)"
R"(        int           ne2_dst,
)"
R"(        int           ne3_dst
)"
R"() {
)"
R"(    src0  = src0  + offset0;
)"
R"(    src1  = src1  + offset1;
)"
R"(    dst_q = dst_q + offset_q;
)"
R"(    dst_d = dst_d + offset_d;
)"
R"(
)"
R"(    int i03 = get_group_id(2);
)"
R"(    int i02 = get_group_id(1);
)"
R"(    int i01 = get_group_id(0)*get_local_size(1) + get_local_id(1);
)"
R"(
)"
R"(    if (i01 >= ne01) {
)"
R"(        return;
)"
R"(    }
)"
R"(
)"
R"(    int i12 = fastmod(i03, ne12);
)"
R"(    int i11 = fastmod(i02, ne11);
)"
R"(
)"
R"(    int i10 = i01;
)"
R"(    long i1 = ((global long *)(src1 + i10*nb10 + i11*nb11 + i12*nb12))[0];
)"
R"(
)"
R"(    long row_blk_base = ((long)i03 * ne2_dst * ne1_dst + (long)i02 * ne1_dst + i1) * nblk0;
)"
R"(
)"
R"(    global half  * d_row = (global half  *)(dst_d) + row_blk_base;
)"
R"(    global char  * q_row = (global char  *)(dst_q) + row_blk_base * QK8_0;
)"
R"(    global float * src_row = (global float *)(src0 + i01*nb01 + i02*nb02 + i03*nb03);
)"
R"(
)"
R"(    for (int blk = get_local_id(0); blk < nblk0; blk += get_local_size(0)) {
)"
R"(        global float * x = src_row + blk * QK8_0;
)"
R"(        global char  * q = q_row + blk * QK8_0;
)"
R"(
)"
R"(        quantize_q8_0_block(x, q, d_row + blk);
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_set_rows_q8_0_soa_i32(
)"
R"(        global char * src0,
)"
R"(        ulong         offset0,
)"
R"(        global char * src1,
)"
R"(        ulong         offset1,
)"
R"(        global char * dst_q,
)"
R"(        ulong         offset_q,
)"
R"(        global char * dst_d,
)"
R"(        ulong         offset_d,
)"
R"(        int           ne01,
)"
R"(        ulong         nb01,
)"
R"(        ulong         nb02,
)"
R"(        ulong         nb03,
)"
R"(        uint4         ne11,
)"
R"(        uint4         ne12,
)"
R"(        ulong         nb10,
)"
R"(        ulong         nb11,
)"
R"(        ulong         nb12,
)"
R"(        int           nblk0,
)"
R"(        int           ne1_dst,
)"
R"(        int           ne2_dst,
)"
R"(        int           ne3_dst
)"
R"() {
)"
R"(    src0  = src0  + offset0;
)"
R"(    src1  = src1  + offset1;
)"
R"(    dst_q = dst_q + offset_q;
)"
R"(    dst_d = dst_d + offset_d;
)"
R"(
)"
R"(    int i03 = get_group_id(2);
)"
R"(    int i02 = get_group_id(1);
)"
R"(    int i01 = get_group_id(0)*get_local_size(1) + get_local_id(1);
)"
R"(
)"
R"(    if (i01 >= ne01) {
)"
R"(        return;
)"
R"(    }
)"
R"(
)"
R"(    int i12 = fastmod(i03, ne12);
)"
R"(    int i11 = fastmod(i02, ne11);
)"
R"(
)"
R"(    int i10 = i01;
)"
R"(    int i1  = ((global int *)(src1 + i10*nb10 + i11*nb11 + i12*nb12))[0];
)"
R"(
)"
R"(    long row_blk_base = ((long)i03 * ne2_dst * ne1_dst + (long)i02 * ne1_dst + i1) * nblk0;
)"
R"(
)"
R"(    global half  * d_row = (global half  *)(dst_d) + row_blk_base;
)"
R"(    global char  * q_row = (global char  *)(dst_q) + row_blk_base * QK8_0;
)"
R"(    global float * src_row = (global float *)(src0 + i01*nb01 + i02*nb02 + i03*nb03);
)"
R"(
)"
R"(    for (int blk = get_local_id(0); blk < nblk0; blk += get_local_size(0)) {
)"
R"(        global float * x = src_row + blk * QK8_0;
)"
R"(        global char  * q = q_row + blk * QK8_0;
)"
R"(
)"
R"(        quantize_q8_0_block(x, q, d_row + blk);
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_set_rows_f16_i32(
)"
R"(        global char * src0,
)"
R"(        ulong         offset0,
)"
R"(        global char * src1,
)"
R"(        ulong         offset1,
)"
R"(        global char * dst,
)"
R"(        ulong         offsetd,
)"
R"(        int           ne01,
)"
R"(        ulong         nb01,
)"
R"(        ulong         nb02,
)"
R"(        ulong         nb03,
)"
R"(        uint4         ne11,
)"
R"(        uint4         ne12,
)"
R"(        ulong         nb10,
)"
R"(        ulong         nb11,
)"
R"(        ulong         nb12,
)"
R"(        int           nblk0,
)"
R"(        ulong         nb1,
)"
R"(        ulong         nb2,
)"
R"(        ulong         nb3
)"
R"() {
)"
R"(    src0 = src0 + offset0;
)"
R"(    src1 = src1 + offset1;
)"
R"(    dst  = dst  + offsetd;
)"
R"(
)"
R"(    int i03 = get_group_id(2);
)"
R"(    int i02 = get_group_id(1);
)"
R"(    int i01 = get_group_id(0)*get_local_size(1) + get_local_id(1);
)"
R"(
)"
R"(    if (i01 >= ne01) {
)"
R"(        return;
)"
R"(    }
)"
R"(
)"
R"(    //int i12 = i03%ne12;
)"
R"(    //int i11 = i02%ne11;
)"
R"(    int i12 = fastmod(i03, ne12);
)"
R"(    int i11 = fastmod(i02, ne11);
)"
R"(
)"
R"(    int i10 = i01;
)"
R"(    int i1  = ((global int *)(src1 + i10*nb10 + i11*nb11 + i12*nb12))[0];
)"
R"(
)"
R"(    global half  * dst_row = (global half  *) (dst  +  i1*nb1  + i02*nb2  + i03*nb3);
)"
R"(    global float * src_row = (global float *) (src0 + i01*nb01 + i02*nb02 + i03*nb03);
)"
R"(
)"
R"(    for (int ind = get_local_id(0); ind < nblk0; ind += get_local_size(0)) {
)"
R"(        dst_row[ind] = src_row[ind];
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(// f32 -> q4_0 quantize set_rows. Block = half d + uchar qs[16] (shuffled
)"
R"(// nibbles: qs[j] low/high = elem j / j+16).
)"
R"(// Dequant: val[i] = d * (nibble_i - 8)
)"
R"(// nblk0 = number of q4_0 blocks per row = ne00 / 32.
)"
R"(#define QK4_0 32
)"
R"(#define Q4_0_BLOCK_SIZE 18
)"
R"(
)"
R"(inline void quantize_q4_0_block(global float * x, global uchar * qs, global half * d_out) {
)"
R"(    // Find the signed value with the largest absolute magnitude (matches ggml ref).
)"
R"(    float max  = 0.0f;
)"
R"(    float amax = 0.0f;
)"
R"(    for (int j = 0; j < QK4_0; j++) {
)"
R"(        float v = x[j];
)"
R"(        float a = fabs(v);
)"
R"(        if (a > amax) {
)"
R"(            amax = a;
)"
R"(            max  = v;
)"
R"(        }
)"
R"(    }
)"
R"(
)"
R"(    float d  = max / -8.0f;
)"
R"(    float id = (d != 0.0f) ? 1.0f / d : 0.0f;
)"
R"(
)"
R"(    vstore_half(d, 0, d_out);
)"
R"(
)"
R"(    for (int j = 0; j < QK4_0/2; j++) {
)"
R"(        float x0 = x[j]           * id;
)"
R"(        float x1 = x[j + QK4_0/2] * id;
)"
R"(
)"
R"(        int i0 = (int)(x0 + 8.5f);
)"
R"(        int i1 = (int)(x1 + 8.5f);
)"
R"(        if (i0 < 0)  i0 = 0;
)"
R"(        if (i0 > 15) i0 = 15;
)"
R"(        if (i1 < 0)  i1 = 0;
)"
R"(        if (i1 > 15) i1 = 15;
)"
R"(
)"
R"(        qs[j] = (uchar)i0 | ((uchar)i1 << 4);
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_set_rows_q4_0_i64(
)"
R"(        global char * src0,
)"
R"(        ulong         offset0,
)"
R"(        global char * src1,
)"
R"(        ulong         offset1,
)"
R"(        global char * dst,
)"
R"(        ulong         offsetd,
)"
R"(        int           ne01,
)"
R"(        ulong         nb01,
)"
R"(        ulong         nb02,
)"
R"(        ulong         nb03,
)"
R"(        uint4         ne11,
)"
R"(        uint4         ne12,
)"
R"(        ulong         nb10,
)"
R"(        ulong         nb11,
)"
R"(        ulong         nb12,
)"
R"(        int           nblk0,
)"
R"(        ulong         nb1,
)"
R"(        ulong         nb2,
)"
R"(        ulong         nb3
)"
R"() {
)"
R"(    src0 = src0 + offset0;
)"
R"(    src1 = src1 + offset1;
)"
R"(    dst  = dst  + offsetd;
)"
R"(
)"
R"(    int i03 = get_group_id(2);
)"
R"(    int i02 = get_group_id(1);
)"
R"(    int i01 = get_group_id(0)*get_local_size(1) + get_local_id(1);
)"
R"(
)"
R"(    if (i01 >= ne01) {
)"
R"(        return;
)"
R"(    }
)"
R"(
)"
R"(    int i12 = fastmod(i03, ne12);
)"
R"(    int i11 = fastmod(i02, ne11);
)"
R"(
)"
R"(    int i10 = i01;
)"
R"(    long i1 = ((global long *)(src1 + i10*nb10 + i11*nb11 + i12*nb12))[0];
)"
R"(
)"
R"(    global char  * dst_row = (global char  *) (dst  +  i1*nb1  + i02*nb2  + i03*nb3);
)"
R"(    global float * src_row = (global float *) (src0 + i01*nb01 + i02*nb02 + i03*nb03);
)"
R"(
)"
R"(    for (int blk = get_local_id(0); blk < nblk0; blk += get_local_size(0)) {
)"
R"(        global float * x    = src_row + blk * QK4_0;
)"
R"(        global char  * y    = dst_row + blk * Q4_0_BLOCK_SIZE;
)"
R"(        global half  * yd   = (global half  *)(y);
)"
R"(        global uchar * yqs  = (global uchar *)(y + 2);
)"
R"(
)"
R"(        quantize_q4_0_block(x, yqs, yd);
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_set_rows_q4_0_i32(
)"
R"(        global char * src0,
)"
R"(        ulong         offset0,
)"
R"(        global char * src1,
)"
R"(        ulong         offset1,
)"
R"(        global char * dst,
)"
R"(        ulong         offsetd,
)"
R"(        int           ne01,
)"
R"(        ulong         nb01,
)"
R"(        ulong         nb02,
)"
R"(        ulong         nb03,
)"
R"(        uint4         ne11,
)"
R"(        uint4         ne12,
)"
R"(        ulong         nb10,
)"
R"(        ulong         nb11,
)"
R"(        ulong         nb12,
)"
R"(        int           nblk0,
)"
R"(        ulong         nb1,
)"
R"(        ulong         nb2,
)"
R"(        ulong         nb3
)"
R"() {
)"
R"(    src0 = src0 + offset0;
)"
R"(    src1 = src1 + offset1;
)"
R"(    dst  = dst  + offsetd;
)"
R"(
)"
R"(    int i03 = get_group_id(2);
)"
R"(    int i02 = get_group_id(1);
)"
R"(    int i01 = get_group_id(0)*get_local_size(1) + get_local_id(1);
)"
R"(
)"
R"(    if (i01 >= ne01) {
)"
R"(        return;
)"
R"(    }
)"
R"(
)"
R"(    int i12 = fastmod(i03, ne12);
)"
R"(    int i11 = fastmod(i02, ne11);
)"
R"(
)"
R"(    int i10 = i01;
)"
R"(    int i1  = ((global int *)(src1 + i10*nb10 + i11*nb11 + i12*nb12))[0];
)"
R"(
)"
R"(    global char  * dst_row = (global char  *) (dst  +  i1*nb1  + i02*nb2  + i03*nb3);
)"
R"(    global float * src_row = (global float *) (src0 + i01*nb01 + i02*nb02 + i03*nb03);
)"
R"(
)"
R"(    for (int blk = get_local_id(0); blk < nblk0; blk += get_local_size(0)) {
)"
R"(        global float * x    = src_row + blk * QK4_0;
)"
R"(        global char  * y    = dst_row + blk * Q4_0_BLOCK_SIZE;
)"
R"(        global half  * yd   = (global half  *)(y);
)"
R"(        global uchar * yqs  = (global uchar *)(y + 2);
)"
R"(
)"
R"(        quantize_q4_0_block(x, yqs, yd);
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(// SoA variants for q4_0 dst. Used when the backend has split block_q4_0 records
)"
R"(// into separate quant (dst_q) and scale (dst_d) sub-buffers — same pattern as
)"
R"(// the q8_0 SoA variants above.
)"
R"(//
)"
R"(// Layout (matches kernel_convert_block_q4_0, the "shuffled" variant):
)"
R"(//   dst_q: contiguous 16 packed nibbles per block, block i at offset i * 16 bytes.
)"
R"(//   dst_d: contiguous fp16 scales, block i at offset i * 2 bytes.
)"
R"(// Nibble layout inside each byte is unchanged from AoS: qs[j] low nibble = element j,
)"
R"(// qs[j] high nibble = element j+16. kernel_restore_block_q4_0 copies bytes as-is.
)"
R"(kernel void kernel_set_rows_q4_0_soa_i64(
)"
R"(        global char * src0,
)"
R"(        ulong         offset0,
)"
R"(        global char * src1,
)"
R"(        ulong         offset1,
)"
R"(        global char * dst_q,
)"
R"(        ulong         offset_q,
)"
R"(        global char * dst_d,
)"
R"(        ulong         offset_d,
)"
R"(        int           ne01,
)"
R"(        ulong         nb01,
)"
R"(        ulong         nb02,
)"
R"(        ulong         nb03,
)"
R"(        uint4         ne11,
)"
R"(        uint4         ne12,
)"
R"(        ulong         nb10,
)"
R"(        ulong         nb11,
)"
R"(        ulong         nb12,
)"
R"(        int           nblk0,
)"
R"(        int           ne1_dst,
)"
R"(        int           ne2_dst,
)"
R"(        int           ne3_dst
)"
R"() {
)"
R"(    src0  = src0  + offset0;
)"
R"(    src1  = src1  + offset1;
)"
R"(    dst_q = dst_q + offset_q;
)"
R"(    dst_d = dst_d + offset_d;
)"
R"(
)"
R"(    int i03 = get_group_id(2);
)"
R"(    int i02 = get_group_id(1);
)"
R"(    int i01 = get_group_id(0)*get_local_size(1) + get_local_id(1);
)"
R"(
)"
R"(    if (i01 >= ne01) {
)"
R"(        return;
)"
R"(    }
)"
R"(
)"
R"(    int i12 = fastmod(i03, ne12);
)"
R"(    int i11 = fastmod(i02, ne11);
)"
R"(
)"
R"(    int i10 = i01;
)"
R"(    long i1 = ((global long *)(src1 + i10*nb10 + i11*nb11 + i12*nb12))[0];
)"
R"(
)"
R"(    long row_blk_base = ((long)i03 * ne2_dst * ne1_dst + (long)i02 * ne1_dst + i1) * nblk0;
)"
R"(
)"
R"(    global half  * d_row   = (global half  *)(dst_d) + row_blk_base;
)"
R"(    global uchar * q_row   = (global uchar *)(dst_q) + row_blk_base * (QK4_0/2);
)"
R"(    global float * src_row = (global float *)(src0 + i01*nb01 + i02*nb02 + i03*nb03);
)"
R"(
)"
R"(    for (int blk = get_local_id(0); blk < nblk0; blk += get_local_size(0)) {
)"
R"(        global float * x    = src_row + blk * QK4_0;
)"
R"(        global uchar * qs   = q_row   + blk * (QK4_0/2);
)"
R"(        global half  * d_bk = d_row   + blk;
)"
R"(
)"
R"(        quantize_q4_0_block(x, qs, d_bk);
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_set_rows_q4_0_soa_i32(
)"
R"(        global char * src0,
)"
R"(        ulong         offset0,
)"
R"(        global char * src1,
)"
R"(        ulong         offset1,
)"
R"(        global char * dst_q,
)"
R"(        ulong         offset_q,
)"
R"(        global char * dst_d,
)"
R"(        ulong         offset_d,
)"
R"(        int           ne01,
)"
R"(        ulong         nb01,
)"
R"(        ulong         nb02,
)"
R"(        ulong         nb03,
)"
R"(        uint4         ne11,
)"
R"(        uint4         ne12,
)"
R"(        ulong         nb10,
)"
R"(        ulong         nb11,
)"
R"(        ulong         nb12,
)"
R"(        int           nblk0,
)"
R"(        int           ne1_dst,
)"
R"(        int           ne2_dst,
)"
R"(        int           ne3_dst
)"
R"() {
)"
R"(    src0  = src0  + offset0;
)"
R"(    src1  = src1  + offset1;
)"
R"(    dst_q = dst_q + offset_q;
)"
R"(    dst_d = dst_d + offset_d;
)"
R"(
)"
R"(    int i03 = get_group_id(2);
)"
R"(    int i02 = get_group_id(1);
)"
R"(    int i01 = get_group_id(0)*get_local_size(1) + get_local_id(1);
)"
R"(
)"
R"(    if (i01 >= ne01) {
)"
R"(        return;
)"
R"(    }
)"
R"(
)"
R"(    int i12 = fastmod(i03, ne12);
)"
R"(    int i11 = fastmod(i02, ne11);
)"
R"(
)"
R"(    int i10 = i01;
)"
R"(    int i1  = ((global int *)(src1 + i10*nb10 + i11*nb11 + i12*nb12))[0];
)"
R"(
)"
R"(    long row_blk_base = ((long)i03 * ne2_dst * ne1_dst + (long)i02 * ne1_dst + i1) * nblk0;
)"
R"(
)"
R"(    global half  * d_row   = (global half  *)(dst_d) + row_blk_base;
)"
R"(    global uchar * q_row   = (global uchar *)(dst_q) + row_blk_base * (QK4_0/2);
)"
R"(    global float * src_row = (global float *)(src0 + i01*nb01 + i02*nb02 + i03*nb03);
)"
R"(
)"
R"(    for (int blk = get_local_id(0); blk < nblk0; blk += get_local_size(0)) {
)"
R"(        global float * x    = src_row + blk * QK4_0;
)"
R"(        global uchar * qs   = q_row   + blk * (QK4_0/2);
)"
R"(        global half  * d_bk = d_row   + blk;
)"
R"(
)"
R"(        quantize_q4_0_block(x, qs, d_bk);
)"
R"(    }
)"
R"(}
)"
