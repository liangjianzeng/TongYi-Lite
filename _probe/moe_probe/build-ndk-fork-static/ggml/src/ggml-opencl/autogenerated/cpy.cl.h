R"(#pragma OPENCL EXTENSION cl_khr_fp16 : enable
)"
R"(
)"
R"(//------------------------------------------------------------------------------
)"
R"(// cpy
)"
R"(//------------------------------------------------------------------------------
)"
R"(
)"
R"(kernel void kernel_cpy_f16_f16(
)"
R"(        global half * src0,
)"
R"(        ulong offset0,
)"
R"(        global half * dst,
)"
R"(        ulong offsetd,
)"
R"(        int ne00,
)"
R"(        int ne01,
)"
R"(        int ne02,
)"
R"(        int ne03,
)"
R"(        ulong nb00,
)"
R"(        ulong nb01,
)"
R"(        ulong nb02,
)"
R"(        ulong nb03,
)"
R"(        int ne0,
)"
R"(        int ne1,
)"
R"(        int ne2,
)"
R"(        int ne3,
)"
R"(        ulong nb0,
)"
R"(        ulong nb1,
)"
R"(        ulong nb2,
)"
R"(        ulong nb3
)"
R"() {
)"
R"(    src0 = (global half*)((global char*)src0 + offset0);
)"
R"(    dst = (global half*)((global char*)dst + offsetd);
)"
R"(
)"
R"(    int i03 = get_group_id(2);
)"
R"(    int i02 = get_group_id(1);
)"
R"(    int i01 = get_group_id(0);
)"
R"(
)"
R"(    int n = i03*ne02*ne01*ne00 + i02*ne01*ne00 + i01*ne00;
)"
R"(
)"
R"(    int i3 = n / (ne2*ne1*ne0);
)"
R"(    int i2 = (n - i3*ne2*ne1*ne0) / (ne1*ne0);
)"
R"(    int i1 = (n - i3*ne2*ne1*ne0 - i2*ne1*ne0) / ne0;
)"
R"(    int i0 = (n - i3*ne2*ne1*ne0 - i2*ne1*ne0 - i1*ne0);
)"
R"(
)"
R"(    global half * dst_data = (global half *) ((global char *) dst + i3*nb3 + i2*nb2 + i1*nb1 + i0*nb0);
)"
R"(
)"
R"(    for (int i00 = get_local_id(0); i00 < ne00; i00 += get_local_size(0)) {
)"
R"(        global const half * src = (global half *)((global char *) src0 + i03*nb03 + i02*nb02 + i01*nb01 + i00*nb00);
)"
R"(        dst_data[i00] = src[0];
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_cpy_f16_f32(
)"
R"(        global half * src0,
)"
R"(        ulong offset0,
)"
R"(        global float * dst,
)"
R"(        ulong offsetd,
)"
R"(        int ne00,
)"
R"(        int ne01,
)"
R"(        int ne02,
)"
R"(        int ne03,
)"
R"(        ulong nb00,
)"
R"(        ulong nb01,
)"
R"(        ulong nb02,
)"
R"(        ulong nb03,
)"
R"(        int ne0,
)"
R"(        int ne1,
)"
R"(        int ne2,
)"
R"(        int ne3,
)"
R"(        ulong nb0,
)"
R"(        ulong nb1,
)"
R"(        ulong nb2,
)"
R"(        ulong nb3
)"
R"() {
)"
R"(
)"
R"(    src0 = (global half*)((global char*)src0 + offset0);
)"
R"(    dst = (global float*)((global char*)dst + offsetd);
)"
R"(
)"
R"(    int i03 = get_group_id(2);
)"
R"(    int i02 = get_group_id(1);
)"
R"(    int i01 = get_group_id(0);
)"
R"(
)"
R"(    int n = i03*ne02*ne01*ne00 + i02*ne01*ne00 + i01*ne00;
)"
R"(
)"
R"(    int i3 = n / (ne2*ne1*ne0);
)"
R"(    int i2 = (n - i3*ne2*ne1*ne0) / (ne1*ne0);
)"
R"(    int i1 = (n - i3*ne2*ne1*ne0 - i2*ne1*ne0) / ne0;
)"
R"(    int i0 = (n - i3*ne2*ne1*ne0 - i2*ne1*ne0 - i1*ne0);
)"
R"(
)"
R"(    global float * dst_data = (global float *) ((global char *) dst + i3*nb3 + i2*nb2 + i1*nb1 + i0*nb0);
)"
R"(
)"
R"(    for (int i00 = get_local_id(0); i00 < ne00; i00 += get_local_size(0)) {
)"
R"(        global half * src = (global half *)((global char *) src0 + i03*nb03 + i02*nb02 + i01*nb01 + i00*nb00);
)"
R"(        dst_data[i00] = src[0];
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_cpy_f32_f16(
)"
R"(        global float * src0,
)"
R"(        ulong offset0,
)"
R"(        global half * dst,
)"
R"(        ulong offsetd,
)"
R"(        int ne00,
)"
R"(        int ne01,
)"
R"(        int ne02,
)"
R"(        int ne03,
)"
R"(        ulong nb00,
)"
R"(        ulong nb01,
)"
R"(        ulong nb02,
)"
R"(        ulong nb03,
)"
R"(        int ne0,
)"
R"(        int ne1,
)"
R"(        int ne2,
)"
R"(        int ne3,
)"
R"(        ulong nb0,
)"
R"(        ulong nb1,
)"
R"(        ulong nb2,
)"
R"(        ulong nb3
)"
R"() {
)"
R"(    src0 = (global float*)((global char*)src0 + offset0);
)"
R"(    dst = (global half*)((global char*)dst + offsetd);
)"
R"(
)"
R"(    int i03 = get_group_id(2);
)"
R"(    int i02 = get_group_id(1);
)"
R"(    int i01 = get_group_id(0);
)"
R"(
)"
R"(    int n = i03*ne02*ne01*ne00 + i02*ne01*ne00 + i01*ne00;
)"
R"(
)"
R"(    int i3 = n / (ne2*ne1*ne0);
)"
R"(    int i2 = (n - i3*ne2*ne1*ne0) / (ne1*ne0);
)"
R"(    int i1 = (n - i3*ne2*ne1*ne0 - i2*ne1*ne0) / ne0;
)"
R"(    int i0 = (n - i3*ne2*ne1*ne0 - i2*ne1*ne0 - i1*ne0);
)"
R"(
)"
R"(    global half * dst_data = (global half *) ((global char *) dst + i3*nb3 + i2*nb2 + i1*nb1 + i0*nb0);
)"
R"(
)"
R"(    for (int i00 = get_local_id(0); i00 < ne00; i00 += get_local_size(0)) {
)"
R"(        global const float * src = (global float *)((global char *) src0 + i03*nb03 + i02*nb02 + i01*nb01 + i00*nb00);
)"
R"(
)"
R"(        dst_data[i00] = src[0];
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_cpy_f32_f32(
)"
R"(        global float * src0,
)"
R"(        ulong offset0,
)"
R"(        global float * dst,
)"
R"(        ulong offsetd,
)"
R"(        int ne00,
)"
R"(        int ne01,
)"
R"(        int ne02,
)"
R"(        int ne03,
)"
R"(        ulong nb00,
)"
R"(        ulong nb01,
)"
R"(        ulong nb02,
)"
R"(        ulong nb03,
)"
R"(        int ne0,
)"
R"(        int ne1,
)"
R"(        int ne2,
)"
R"(        int ne3,
)"
R"(        ulong nb0,
)"
R"(        ulong nb1,
)"
R"(        ulong nb2,
)"
R"(        ulong nb3
)"
R"() {
)"
R"(    src0 = (global float*)((global char*)src0 + offset0);
)"
R"(    dst = (global float*)((global char*)dst + offsetd);
)"
R"(
)"
R"(    int i03 = get_group_id(2);
)"
R"(    int i02 = get_group_id(1);
)"
R"(    int i01 = get_group_id(0);
)"
R"(
)"
R"(    int n = i03*ne02*ne01*ne00 + i02*ne01*ne00 + i01*ne00;
)"
R"(
)"
R"(    int i3 = n / (ne2*ne1*ne0);
)"
R"(    int i2 = (n - i3*ne2*ne1*ne0) / (ne1*ne0);
)"
R"(    int i1 = (n - i3*ne2*ne1*ne0 - i2*ne1*ne0) / ne0;
)"
R"(    int i0 = (n - i3*ne2*ne1*ne0 - i2*ne1*ne0 - i1*ne0);
)"
R"(
)"
R"(    global float * dst_data = (global float *) ((global char *) dst + i3*nb3 + i2*nb2 + i1*nb1 + i0*nb0);
)"
R"(
)"
R"(    for (int i00 = get_local_id(0); i00 < ne00; i00 += get_local_size(0)) {
)"
R"(        global const float * src = (global float *)((global char *) src0 + i03*nb03 + i02*nb02 + i01*nb01 + i00*nb00);
)"
R"(
)"
R"(        dst_data[i00] = src[0];
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(#ifndef GGML_CL_NO_CPY_PACK
)"
R"(kernel void kernel_cpy_f32_f32_pack(
)"
R"(        global float * src0,
)"
R"(        ulong offset0,
)"
R"(        global float * dst,
)"
R"(        ulong offsetd,
)"
R"(        int ne00,
)"
R"(        int ne01,
)"
R"(        int ne02,
)"
R"(        int ne03,
)"
R"(        ulong nb00,
)"
R"(        ulong nb01,
)"
R"(        ulong nb02,
)"
R"(        ulong nb03,
)"
R"(        int ne0,
)"
R"(        int ne1,
)"
R"(        int ne2,
)"
R"(        int ne3,
)"
R"(        ulong nb0,
)"
R"(        ulong nb1,
)"
R"(        ulong nb2,
)"
R"(        ulong nb3
)"
R"() {
)"
R"(    src0 = (global float*)((global char*)src0 + offset0);
)"
R"(    dst = (global float*)((global char*)dst + offsetd);
)"
R"(
)"
R"(    int lsz = get_local_size(0);
)"
R"(    int tpr = min(ne00, lsz);          // threads per row
)"
R"(    int rpw = lsz / tpr;               // rows per workgroup
)"
R"(    int lid = get_local_id(0);
)"
R"(    int row = get_group_id(0)*rpw + lid / tpr;
)"
R"(    int lane = lid - (lid / tpr) * tpr;
)"
R"(
)"
R"(    int nrows = ne01*ne02*ne03;
)"
R"(    if (row >= nrows) {
)"
R"(        return;
)"
R"(    }
)"
R"(
)"
R"(    int i01 = row % ne01;
)"
R"(    int t   = row / ne01;
)"
R"(    int i02 = t % ne02;
)"
R"(    int i03 = t / ne02;
)"
R"(
)"
R"(    // linear index of the first element of this row, unflattened over dst dims
)"
R"(    long n  = (long)row * ne00;
)"
R"(    int i3  = (int)(n / ((long)ne2*ne1*ne0));
)"
R"(    long rm = n - (long)i3*ne2*ne1*ne0;
)"
R"(    int i2  = (int)(rm / ((long)ne1*ne0));
)"
R"(    rm     -= (long)i2*ne1*ne0;
)"
R"(    int i1  = (int)(rm / ne0);
)"
R"(    int i0  = (int)(rm - (long)i1*ne0);
)"
R"(
)"
R"(    global float * dst_data = (global float *) ((global char *) dst + i3*nb3 + i2*nb2 + i1*nb1 + i0*nb0);
)"
R"(
)"
R"(    for (int i00 = lane; i00 < ne00; i00 += tpr) {
)"
R"(        global const float * src = (global float *)((global char *) src0 + i03*nb03 + i02*nb02 + i01*nb01 + i00*nb00);
)"
R"(        dst_data[i00] = src[0];
)"
R"(    }
)"
R"(}
)"
R"(#endif // GGML_CL_NO_CPY_PACK
)"
R"(
)"
R"(kernel void kernel_cpy_i32_i32(
)"
R"(        global int * src0,
)"
R"(        ulong offset0,
)"
R"(        global int * dst,
)"
R"(        ulong offsetd,
)"
R"(        int ne00,
)"
R"(        int ne01,
)"
R"(        int ne02,
)"
R"(        int ne03,
)"
R"(        ulong nb00,
)"
R"(        ulong nb01,
)"
R"(        ulong nb02,
)"
R"(        ulong nb03,
)"
R"(        int ne0,
)"
R"(        int ne1,
)"
R"(        int ne2,
)"
R"(        int ne3,
)"
R"(        ulong nb0,
)"
R"(        ulong nb1,
)"
R"(        ulong nb2,
)"
R"(        ulong nb3
)"
R"() {
)"
R"(    src0 = (global int*)((global char*)src0 + offset0);
)"
R"(    dst = (global int*)((global char*)dst + offsetd);
)"
R"(
)"
R"(    int i03 = get_group_id(2);
)"
R"(    int i02 = get_group_id(1);
)"
R"(    int i01 = get_group_id(0);
)"
R"(
)"
R"(    int n = i03*ne02*ne01*ne00 + i02*ne01*ne00 + i01*ne00;
)"
R"(
)"
R"(    int i3 = n / (ne2*ne1*ne0);
)"
R"(    int i2 = (n - i3*ne2*ne1*ne0) / (ne1*ne0);
)"
R"(    int i1 = (n - i3*ne2*ne1*ne0 - i2*ne1*ne0) / ne0;
)"
R"(    int i0 = (n - i3*ne2*ne1*ne0 - i2*ne1*ne0 - i1*ne0);
)"
R"(
)"
R"(    global int * dst_data = (global int *) ((global char *) dst + i3*nb3 + i2*nb2 + i1*nb1 + i0*nb0);
)"
R"(
)"
R"(    for (int i00 = get_local_id(0); i00 < ne00; i00 += get_local_size(0)) {
)"
R"(        global const int * src = (global int *)((global char *) src0 + i03*nb03 + i02*nb02 + i01*nb01 + i00*nb00);
)"
R"(
)"
R"(        dst_data[i00] = src[0];
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(// Contiguous f32 copy, one work item per float4 over the whole tensor. The kernels above map
)"
R"(// one workgroup to each row, which leaves a tensor with few long rows on a single compute unit.
)"
R"(// vload4/vstore4 rather than a float4 cast: these buffers carry an arbitrary 4-byte view offset.
)"
R"(kernel void kernel_cpy_f32_f32_flat(
)"
R"(        global float * src0,
)"
R"(        ulong offset0,
)"
R"(        global float * dst,
)"
R"(        ulong offsetd,
)"
R"(        ulong ne,
)"
R"(        ulong n4
)"
R"() {
)"
R"(    src0 = (global float*)((global char*)src0 + offset0);
)"
R"(    dst  = (global float*)((global char*)dst  + offsetd);
)"
R"(
)"
R"(    const ulong i = get_global_id(0);
)"
R"(
)"
R"(    if (i < n4) {
)"
R"(        vstore4(vload4(i, src0), i, dst);
)"
R"(    } else if (i == n4) {
)"
R"(        for (ulong t = n4 * 4; t < ne; ++t) {
)"
R"(            dst[t] = src0[t];
)"
R"(        }
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(// [tongyi SSM state R-275 2026-11-04] Row-contiguous strided view -> contiguous dst, one work
)"
R"(// item per float4 over the WHOLE tensor. kernel_cpy_f32_f32_pack maps a workgroup to a few
)"
R"(// short rows and gathers with the row pitch — measured 60 MB/s on the 96KB GDN conv-state
)"
R"(// roll (src [3,8192] rows spaced 16B: 4-float token stride, keep 3). This shape keeps dst
)"
R"(// stores fully coalesced and reads short/regular; host gate: nb00==4, nb01%4==0, dst
)"
R"(// contiguous, short rows (ne00<32), equal element counts.
)"
R"(kernel void kernel_cpy_f32_f32_packflat(
)"
R"(        global float * src0,
)"
R"(        ulong offset0,
)"
R"(        global float * dst,
)"
R"(        ulong offsetd,
)"
R"(        int ne00,
)"
R"(        ulong nb01,
)"
R"(        ulong ne
)"
R"() {
)"
R"(    src0 = (global float*)((global char*)src0 + offset0);
)"
R"(    dst  = (global float*)((global char*)dst  + offsetd);
)"
R"(
)"
R"(    const ulong i  = get_global_id(0);
)"
R"(    const ulong n4 = ne / 4;
)"
R"(
)"
R"(    if (i < n4) {
)"
R"(        float v[4];
)"
R"(        #pragma unroll
)"
R"(        for (int k = 0; k < 4; ++k) {
)"
R"(            const ulong e   = i*4 + (ulong)k;
)"
R"(            const ulong row = e / (ulong)ne00;
)"
R"(            const ulong col = e - row*(ulong)ne00;
)"
R"(            v[k] = *(global const float*)((global const char*)src0 + row*nb01 + col*4);
)"
R"(        }
)"
R"(        vstore4((float4)(v[0], v[1], v[2], v[3]), i, dst);
)"
R"(    } else if (i == n4 && (ne & 3)) {
)"
R"(        for (ulong t = n4*4; t < ne; ++t) {
)"
R"(            const ulong row = t / (ulong)ne00;
)"
R"(            const ulong col = t - row*(ulong)ne00;
)"
R"(            dst[t] = *(global const float*)((global const char*)src0 + row*nb01 + col*4);
)"
R"(        }
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(// [tongyi M-R1 2026-10-25] f32 -> i32 numeric cast (ggml_cast wiring for the
)"
R"(// fused MoE router ids plane). Matches the CPU f32_to_i32 semantics
)"
R"(// (common.h: x -> (int32_t) x, truncation); exact for integral float values.
)"
R"(kernel void kernel_cpy_f32_i32(
)"
R"(        global float * src0,
)"
R"(        ulong offset0,
)"
R"(        global int * dst,
)"
R"(        ulong offsetd,
)"
R"(        int ne00,
)"
R"(        int ne01,
)"
R"(        int ne02,
)"
R"(        int ne03,
)"
R"(        ulong nb00,
)"
R"(        ulong nb01,
)"
R"(        ulong nb02,
)"
R"(        ulong nb03,
)"
R"(        int ne0,
)"
R"(        int ne1,
)"
R"(        int ne2,
)"
R"(        int ne3,
)"
R"(        ulong nb0,
)"
R"(        ulong nb1,
)"
R"(        ulong nb2,
)"
R"(        ulong nb3
)"
R"() {
)"
R"(    src0 = (global float*)((global char*)src0 + offset0);
)"
R"(    dst = (global int*)((global char*)dst + offsetd);
)"
R"(
)"
R"(    int i03 = get_group_id(2);
)"
R"(    int i02 = get_group_id(1);
)"
R"(    int i01 = get_group_id(0);
)"
R"(
)"
R"(    int n = i03*ne02*ne01*ne00 + i02*ne01*ne00 + i01*ne00;
)"
R"(
)"
R"(    int i3 = n / (ne2*ne1*ne0);
)"
R"(    int i2 = (n - i3*ne2*ne1*ne0) / (ne1*ne0);
)"
R"(    int i1 = (n - i3*ne2*ne1*ne0 - i2*ne1*ne0) / ne0;
)"
R"(    int i0 = (n - i3*ne2*ne1*ne0 - i2*ne1*ne0 - i1*ne0);
)"
R"(
)"
R"(    global int * dst_data = (global int *) ((global char *) dst + i3*nb3 + i2*nb2 + i1*nb1 + i0*nb0);
)"
R"(
)"
R"(    for (int i00 = get_local_id(0); i00 < ne00; i00 += get_local_size(0)) {
)"
R"(        global const float * src = (global float *)((global char *) src0 + i03*nb03 + i02*nb02 + i01*nb01 + i00*nb00);
)"
R"(
)"
R"(        dst_data[i00] = (int) src[0];
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(//------------------------------------------------------------------------------
)"
R"(// kernel_cpy_q4_0_f32_view_aos  /  kernel_cpy_f32_q4_0_view_aos
)"
R"(// ggml_cl_cpy path for the rope-shift chain on the q4_0 KV cache:
)"
R"(//   cast(cur_q4_0 -> f32)  ->  MUL_MAT(hadamard) ROPE MUL_MAT(hadamard)  ->  cur_f32 -> cpy back to q4_0
)"
R"(// The q4_0 KV cache stays AoS (see ggml.c:1879 nb[1]=nb[0]*(ne[0]/block_size),
)"
R"(// and ggml_opencl "KV-cache q4_0 stays AoS"). These kernels index blocks tightly
)"
R"(// within ne[0] and match the standard cpy 20-arg layout so ggml_cl_cpy can reuse
)"
R"(// its existing arg setup. Quantize is a bit-exact inverse of the CPU
)"
R"(// ggml_quantize_row_q4_0_ref so a dequant->matmul->dequant round-trip keeps the
)"
R"(// same q4_0 error profile.
)"
R"(//------------------------------------------------------------------------------
)"
R"(#define QK4_0_CPY 32
)"
R"(typedef struct {
)"
R"(    half d;
)"
R"(    uchar qs[QK4_0_CPY / 2];   // 高通驱动无 stdint：uchar 是 8 位标量，uint8 是向量类型
)"
R"(} block_q4_0_cpy;
)"
R"(
)"
R"(// q4_0 (AoS blocks) -> f32, view-aware, standard cpy arg layout.
)"
R"(kernel void kernel_cpy_q4_0_f32_view_aos(
)"
R"(        global char * src0,
)"
R"(        ulong         offset0,
)"
R"(        global float * dst,
)"
R"(        ulong         offsetd,
)"
R"(        int ne00,
)"
R"(        int ne01,
)"
R"(        int ne02,
)"
R"(        int ne03,
)"
R"(        ulong nb00,
)"
R"(        ulong nb01,
)"
R"(        ulong nb02,
)"
R"(        ulong nb03,
)"
R"(        int ne10,
)"
R"(        int ne11,
)"
R"(        int ne12,
)"
R"(        int ne13,
)"
R"(        ulong nb10,
)"
R"(        ulong nb11,
)"
R"(        ulong nb12,
)"
R"(        ulong nb13
)"
R"() {
)"
R"(    int blk_i0 = get_global_id(0);
)"
R"(    int i1     = get_global_id(1);
)"
R"(    int batch  = get_global_id(2);
)"
R"(
)"
R"(    if (blk_i0 >= ne00 / QK4_0_CPY) return;
)"
R"(    if (i1     >= ne01)             return;
)"
R"(
)"
R"(    int i2 = batch % ne02;
)"
R"(    int i3 = batch / ne02;
)"
R"(
)"
R"(    global block_q4_0_cpy * blk = (global block_q4_0_cpy *)((global char *)src0 + offset0
)"
R"(        + (ulong)i3 * nb03 + (ulong)i2 * nb02 + (ulong)i1 * nb01 + (ulong)blk_i0 * nb00);
)"
R"(
)"
R"(    global float * dstp = (global float *)((global char *)dst + offsetd
)"
R"(        + (ulong)i3 * nb13 + (ulong)i2 * nb12 + (ulong)i1 * nb11 + (ulong)blk_i0 * QK4_0_CPY * nb10);
)"
R"(
)"
R"(    float d = (float)blk->d;
)"
R"(    for (int i = 0; i < QK4_0_CPY / 2; ++i) {
)"
R"(        uchar byte = blk->qs[i];
)"
R"(        int q0 = (int)(byte & 0x0F) - 8;
)"
R"(        int q1 = (int)(byte >> 4)   - 8;
)"
R"(        dstp[i]            = d * (float)q0;
)"
R"(        dstp[i + QK4_0_CPY / 2]  = d * (float)q1;
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(// f32 -> q4_0 (AoS blocks), view-aware, standard cpy arg layout.
)"
R"(kernel void kernel_cpy_f32_q4_0_view_aos(
)"
R"(        global float * src0,
)"
R"(        ulong         offset0,
)"
R"(        global char * dst,
)"
R"(        ulong         offsetd,
)"
R"(        int ne00,
)"
R"(        int ne01,
)"
R"(        int ne02,
)"
R"(        int ne03,
)"
R"(        ulong nb00,
)"
R"(        ulong nb01,
)"
R"(        ulong nb02,
)"
R"(        ulong nb03,
)"
R"(        int ne10,
)"
R"(        int ne11,
)"
R"(        int ne12,
)"
R"(        int ne13,
)"
R"(        ulong nb10,
)"
R"(        ulong nb11,
)"
R"(        ulong nb12,
)"
R"(        ulong nb13
)"
R"() {
)"
R"(    int blk_i0 = get_global_id(0);
)"
R"(    int i1     = get_global_id(1);
)"
R"(    int batch  = get_global_id(2);
)"
R"(
)"
R"(    if (blk_i0 >= ne00 / QK4_0_CPY) return;
)"
R"(    if (i1     >= ne01)             return;
)"
R"(
)"
R"(    int i2 = batch % ne02;
)"
R"(    int i3 = batch / ne02;
)"
R"(
)"
R"(    global float * inp = (global float *)((global char *)src0 + offset0
)"
R"(        + (ulong)i3 * nb03 + (ulong)i2 * nb02 + (ulong)i1 * nb01 + (ulong)blk_i0 * QK4_0_CPY * nb00);
)"
R"(
)"
R"(    global block_q4_0_cpy * blk = (global block_q4_0_cpy *)((global char *)dst + offsetd
)"
R"(        + (ulong)i3 * nb13 + (ulong)i2 * nb12 + (ulong)i1 * nb11 + (ulong)blk_i0 * nb10);
)"
R"(
)"
R"(    // match CPU quantize_row_q4_0_ref: d = max/-8 where max is the largest-magnitude value
)"
R"(    float amax = 0.0f;
)"
R"(    float maxv = 0.0f;
)"
R"(    for (int i = 0; i < QK4_0_CPY; ++i) {
)"
R"(        float v = inp[i];
)"
R"(        float a = v < 0 ? -v : v;
)"
R"(        if (a > amax) { amax = a; maxv = v; }
)"
R"(    }
)"
R"(    float d  = maxv / -8.0f;
)"
R"(    float id = d != 0.0f ? 1.0f / d : 0.0f;
)"
R"(
)"
R"(    blk->d = (half)d;
)"
R"(    for (int i = 0; i < QK4_0_CPY / 2; ++i) {
)"
R"(        int xi0 = (int)(inp[i]      * id + 8.5f);
)"
R"(        int xi1 = (int)(inp[i + QK4_0_CPY / 2] * id + 8.5f);
)"
R"(        if (xi0 < 0)   xi0 = 0;
)"
R"(        if (xi1 < 0)   xi1 = 0;
)"
R"(        if (xi0 > 15)  xi0 = 15;
)"
R"(        if (xi1 > 15)  xi1 = 15;
)"
R"(        blk->qs[i] = (uchar)(xi0) | ((uchar)xi1 << 4);
)"
R"(    }
)"
R"(}
)"
