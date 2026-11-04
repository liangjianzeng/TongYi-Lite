#pragma OPENCL EXTENSION cl_khr_fp16 : enable

//------------------------------------------------------------------------------
// cpy
//------------------------------------------------------------------------------

kernel void kernel_cpy_f16_f16(
        global half * src0,
        ulong offset0,
        global half * dst,
        ulong offsetd,
        int ne00,
        int ne01,
        int ne02,
        int ne03,
        ulong nb00,
        ulong nb01,
        ulong nb02,
        ulong nb03,
        int ne0,
        int ne1,
        int ne2,
        int ne3,
        ulong nb0,
        ulong nb1,
        ulong nb2,
        ulong nb3
) {
    src0 = (global half*)((global char*)src0 + offset0);
    dst = (global half*)((global char*)dst + offsetd);

    int i03 = get_group_id(2);
    int i02 = get_group_id(1);
    int i01 = get_group_id(0);

    int n = i03*ne02*ne01*ne00 + i02*ne01*ne00 + i01*ne00;

    int i3 = n / (ne2*ne1*ne0);
    int i2 = (n - i3*ne2*ne1*ne0) / (ne1*ne0);
    int i1 = (n - i3*ne2*ne1*ne0 - i2*ne1*ne0) / ne0;
    int i0 = (n - i3*ne2*ne1*ne0 - i2*ne1*ne0 - i1*ne0);

    global half * dst_data = (global half *) ((global char *) dst + i3*nb3 + i2*nb2 + i1*nb1 + i0*nb0);

    for (int i00 = get_local_id(0); i00 < ne00; i00 += get_local_size(0)) {
        global const half * src = (global half *)((global char *) src0 + i03*nb03 + i02*nb02 + i01*nb01 + i00*nb00);
        dst_data[i00] = src[0];
    }
}

kernel void kernel_cpy_f16_f32(
        global half * src0,
        ulong offset0,
        global float * dst,
        ulong offsetd,
        int ne00,
        int ne01,
        int ne02,
        int ne03,
        ulong nb00,
        ulong nb01,
        ulong nb02,
        ulong nb03,
        int ne0,
        int ne1,
        int ne2,
        int ne3,
        ulong nb0,
        ulong nb1,
        ulong nb2,
        ulong nb3
) {

    src0 = (global half*)((global char*)src0 + offset0);
    dst = (global float*)((global char*)dst + offsetd);

    int i03 = get_group_id(2);
    int i02 = get_group_id(1);
    int i01 = get_group_id(0);

    int n = i03*ne02*ne01*ne00 + i02*ne01*ne00 + i01*ne00;

    int i3 = n / (ne2*ne1*ne0);
    int i2 = (n - i3*ne2*ne1*ne0) / (ne1*ne0);
    int i1 = (n - i3*ne2*ne1*ne0 - i2*ne1*ne0) / ne0;
    int i0 = (n - i3*ne2*ne1*ne0 - i2*ne1*ne0 - i1*ne0);

    global float * dst_data = (global float *) ((global char *) dst + i3*nb3 + i2*nb2 + i1*nb1 + i0*nb0);

    for (int i00 = get_local_id(0); i00 < ne00; i00 += get_local_size(0)) {
        global half * src = (global half *)((global char *) src0 + i03*nb03 + i02*nb02 + i01*nb01 + i00*nb00);
        dst_data[i00] = src[0];
    }
}

kernel void kernel_cpy_f32_f16(
        global float * src0,
        ulong offset0,
        global half * dst,
        ulong offsetd,
        int ne00,
        int ne01,
        int ne02,
        int ne03,
        ulong nb00,
        ulong nb01,
        ulong nb02,
        ulong nb03,
        int ne0,
        int ne1,
        int ne2,
        int ne3,
        ulong nb0,
        ulong nb1,
        ulong nb2,
        ulong nb3
) {
    src0 = (global float*)((global char*)src0 + offset0);
    dst = (global half*)((global char*)dst + offsetd);

    int i03 = get_group_id(2);
    int i02 = get_group_id(1);
    int i01 = get_group_id(0);

    int n = i03*ne02*ne01*ne00 + i02*ne01*ne00 + i01*ne00;

    int i3 = n / (ne2*ne1*ne0);
    int i2 = (n - i3*ne2*ne1*ne0) / (ne1*ne0);
    int i1 = (n - i3*ne2*ne1*ne0 - i2*ne1*ne0) / ne0;
    int i0 = (n - i3*ne2*ne1*ne0 - i2*ne1*ne0 - i1*ne0);

    global half * dst_data = (global half *) ((global char *) dst + i3*nb3 + i2*nb2 + i1*nb1 + i0*nb0);

    for (int i00 = get_local_id(0); i00 < ne00; i00 += get_local_size(0)) {
        global const float * src = (global float *)((global char *) src0 + i03*nb03 + i02*nb02 + i01*nb01 + i00*nb00);

        dst_data[i00] = src[0];
    }
}

kernel void kernel_cpy_f32_f32(
        global float * src0,
        ulong offset0,
        global float * dst,
        ulong offsetd,
        int ne00,
        int ne01,
        int ne02,
        int ne03,
        ulong nb00,
        ulong nb01,
        ulong nb02,
        ulong nb03,
        int ne0,
        int ne1,
        int ne2,
        int ne3,
        ulong nb0,
        ulong nb1,
        ulong nb2,
        ulong nb3
) {
    src0 = (global float*)((global char*)src0 + offset0);
    dst = (global float*)((global char*)dst + offsetd);

    int i03 = get_group_id(2);
    int i02 = get_group_id(1);
    int i01 = get_group_id(0);

    int n = i03*ne02*ne01*ne00 + i02*ne01*ne00 + i01*ne00;

    int i3 = n / (ne2*ne1*ne0);
    int i2 = (n - i3*ne2*ne1*ne0) / (ne1*ne0);
    int i1 = (n - i3*ne2*ne1*ne0 - i2*ne1*ne0) / ne0;
    int i0 = (n - i3*ne2*ne1*ne0 - i2*ne1*ne0 - i1*ne0);

    global float * dst_data = (global float *) ((global char *) dst + i3*nb3 + i2*nb2 + i1*nb1 + i0*nb0);

    for (int i00 = get_local_id(0); i00 < ne00; i00 += get_local_size(0)) {
        global const float * src = (global float *)((global char *) src0 + i03*nb03 + i02*nb02 + i01*nb01 + i00*nb00);

        dst_data[i00] = src[0];
    }
}

#ifndef GGML_CL_NO_CPY_PACK
kernel void kernel_cpy_f32_f32_pack(
        global float * src0,
        ulong offset0,
        global float * dst,
        ulong offsetd,
        int ne00,
        int ne01,
        int ne02,
        int ne03,
        ulong nb00,
        ulong nb01,
        ulong nb02,
        ulong nb03,
        int ne0,
        int ne1,
        int ne2,
        int ne3,
        ulong nb0,
        ulong nb1,
        ulong nb2,
        ulong nb3
) {
    src0 = (global float*)((global char*)src0 + offset0);
    dst = (global float*)((global char*)dst + offsetd);

    int lsz = get_local_size(0);
    int tpr = min(ne00, lsz);          // threads per row
    int rpw = lsz / tpr;               // rows per workgroup
    int lid = get_local_id(0);
    int row = get_group_id(0)*rpw + lid / tpr;
    int lane = lid - (lid / tpr) * tpr;

    int nrows = ne01*ne02*ne03;
    if (row >= nrows) {
        return;
    }

    int i01 = row % ne01;
    int t   = row / ne01;
    int i02 = t % ne02;
    int i03 = t / ne02;

    // linear index of the first element of this row, unflattened over dst dims
    long n  = (long)row * ne00;
    int i3  = (int)(n / ((long)ne2*ne1*ne0));
    long rm = n - (long)i3*ne2*ne1*ne0;
    int i2  = (int)(rm / ((long)ne1*ne0));
    rm     -= (long)i2*ne1*ne0;
    int i1  = (int)(rm / ne0);
    int i0  = (int)(rm - (long)i1*ne0);

    global float * dst_data = (global float *) ((global char *) dst + i3*nb3 + i2*nb2 + i1*nb1 + i0*nb0);

    for (int i00 = lane; i00 < ne00; i00 += tpr) {
        global const float * src = (global float *)((global char *) src0 + i03*nb03 + i02*nb02 + i01*nb01 + i00*nb00);
        dst_data[i00] = src[0];
    }
}
#endif // GGML_CL_NO_CPY_PACK

kernel void kernel_cpy_i32_i32(
        global int * src0,
        ulong offset0,
        global int * dst,
        ulong offsetd,
        int ne00,
        int ne01,
        int ne02,
        int ne03,
        ulong nb00,
        ulong nb01,
        ulong nb02,
        ulong nb03,
        int ne0,
        int ne1,
        int ne2,
        int ne3,
        ulong nb0,
        ulong nb1,
        ulong nb2,
        ulong nb3
) {
    src0 = (global int*)((global char*)src0 + offset0);
    dst = (global int*)((global char*)dst + offsetd);

    int i03 = get_group_id(2);
    int i02 = get_group_id(1);
    int i01 = get_group_id(0);

    int n = i03*ne02*ne01*ne00 + i02*ne01*ne00 + i01*ne00;

    int i3 = n / (ne2*ne1*ne0);
    int i2 = (n - i3*ne2*ne1*ne0) / (ne1*ne0);
    int i1 = (n - i3*ne2*ne1*ne0 - i2*ne1*ne0) / ne0;
    int i0 = (n - i3*ne2*ne1*ne0 - i2*ne1*ne0 - i1*ne0);

    global int * dst_data = (global int *) ((global char *) dst + i3*nb3 + i2*nb2 + i1*nb1 + i0*nb0);

    for (int i00 = get_local_id(0); i00 < ne00; i00 += get_local_size(0)) {
        global const int * src = (global int *)((global char *) src0 + i03*nb03 + i02*nb02 + i01*nb01 + i00*nb00);

        dst_data[i00] = src[0];
    }
}

// Contiguous f32 copy, one work item per float4 over the whole tensor. The kernels above map
// one workgroup to each row, which leaves a tensor with few long rows on a single compute unit.
// vload4/vstore4 rather than a float4 cast: these buffers carry an arbitrary 4-byte view offset.
kernel void kernel_cpy_f32_f32_flat(
        global float * src0,
        ulong offset0,
        global float * dst,
        ulong offsetd,
        ulong ne,
        ulong n4
) {
    src0 = (global float*)((global char*)src0 + offset0);
    dst  = (global float*)((global char*)dst  + offsetd);

    const ulong i = get_global_id(0);

    if (i < n4) {
        vstore4(vload4(i, src0), i, dst);
    } else if (i == n4) {
        for (ulong t = n4 * 4; t < ne; ++t) {
            dst[t] = src0[t];
        }
    }
}

// [tongyi SSM state R-275 2026-11-04] Row-contiguous strided view -> contiguous dst, one work
// item per float4 over the WHOLE tensor. kernel_cpy_f32_f32_pack maps a workgroup to a few
// short rows and gathers with the row pitch — measured 60 MB/s on the 96KB GDN conv-state
// roll (src [3,8192] rows spaced 16B: 4-float token stride, keep 3). This shape keeps dst
// stores fully coalesced and reads short/regular; host gate: nb00==4, nb01%4==0, dst
// contiguous, short rows (ne00<32), equal element counts.
kernel void kernel_cpy_f32_f32_packflat(
        global float * src0,
        ulong offset0,
        global float * dst,
        ulong offsetd,
        int ne00,
        ulong nb01,
        ulong ne
) {
    src0 = (global float*)((global char*)src0 + offset0);
    dst  = (global float*)((global char*)dst  + offsetd);

    const ulong i  = get_global_id(0);
    const ulong n4 = ne / 4;

    if (i < n4) {
        float v[4];
        #pragma unroll
        for (int k = 0; k < 4; ++k) {
            const ulong e   = i*4 + (ulong)k;
            const ulong row = e / (ulong)ne00;
            const ulong col = e - row*(ulong)ne00;
            v[k] = *(global const float*)((global const char*)src0 + row*nb01 + col*4);
        }
        vstore4((float4)(v[0], v[1], v[2], v[3]), i, dst);
    } else if (i == n4 && (ne & 3)) {
        for (ulong t = n4*4; t < ne; ++t) {
            const ulong row = t / (ulong)ne00;
            const ulong col = t - row*(ulong)ne00;
            dst[t] = *(global const float*)((global const char*)src0 + row*nb01 + col*4);
        }
    }
}

// [tongyi M-R1 2026-10-25] f32 -> i32 numeric cast (ggml_cast wiring for the
// fused MoE router ids plane). Matches the CPU f32_to_i32 semantics
// (common.h: x -> (int32_t) x, truncation); exact for integral float values.
kernel void kernel_cpy_f32_i32(
        global float * src0,
        ulong offset0,
        global int * dst,
        ulong offsetd,
        int ne00,
        int ne01,
        int ne02,
        int ne03,
        ulong nb00,
        ulong nb01,
        ulong nb02,
        ulong nb03,
        int ne0,
        int ne1,
        int ne2,
        int ne3,
        ulong nb0,
        ulong nb1,
        ulong nb2,
        ulong nb3
) {
    src0 = (global float*)((global char*)src0 + offset0);
    dst = (global int*)((global char*)dst + offsetd);

    int i03 = get_group_id(2);
    int i02 = get_group_id(1);
    int i01 = get_group_id(0);

    int n = i03*ne02*ne01*ne00 + i02*ne01*ne00 + i01*ne00;

    int i3 = n / (ne2*ne1*ne0);
    int i2 = (n - i3*ne2*ne1*ne0) / (ne1*ne0);
    int i1 = (n - i3*ne2*ne1*ne0 - i2*ne1*ne0) / ne0;
    int i0 = (n - i3*ne2*ne1*ne0 - i2*ne1*ne0 - i1*ne0);

    global int * dst_data = (global int *) ((global char *) dst + i3*nb3 + i2*nb2 + i1*nb1 + i0*nb0);

    for (int i00 = get_local_id(0); i00 < ne00; i00 += get_local_size(0)) {
        global const float * src = (global float *)((global char *) src0 + i03*nb03 + i02*nb02 + i01*nb01 + i00*nb00);

        dst_data[i00] = (int) src[0];
    }
}

//------------------------------------------------------------------------------
// kernel_cpy_q4_0_f32_view_aos  /  kernel_cpy_f32_q4_0_view_aos
// ggml_cl_cpy path for the rope-shift chain on the q4_0 KV cache:
//   cast(cur_q4_0 -> f32)  ->  MUL_MAT(hadamard) ROPE MUL_MAT(hadamard)  ->  cur_f32 -> cpy back to q4_0
// The q4_0 KV cache stays AoS (see ggml.c:1879 nb[1]=nb[0]*(ne[0]/block_size),
// and ggml_opencl "KV-cache q4_0 stays AoS"). These kernels index blocks tightly
// within ne[0] and match the standard cpy 20-arg layout so ggml_cl_cpy can reuse
// its existing arg setup. Quantize is a bit-exact inverse of the CPU
// ggml_quantize_row_q4_0_ref so a dequant->matmul->dequant round-trip keeps the
// same q4_0 error profile.
//------------------------------------------------------------------------------
#define QK4_0_CPY 32
typedef struct {
    half d;
    uchar qs[QK4_0_CPY / 2];   // 高通驱动无 stdint：uchar 是 8 位标量，uint8 是向量类型
} block_q4_0_cpy;

// q4_0 (AoS blocks) -> f32, view-aware, standard cpy arg layout.
kernel void kernel_cpy_q4_0_f32_view_aos(
        global char * src0,
        ulong         offset0,
        global float * dst,
        ulong         offsetd,
        int ne00,
        int ne01,
        int ne02,
        int ne03,
        ulong nb00,
        ulong nb01,
        ulong nb02,
        ulong nb03,
        int ne10,
        int ne11,
        int ne12,
        int ne13,
        ulong nb10,
        ulong nb11,
        ulong nb12,
        ulong nb13
) {
    int blk_i0 = get_global_id(0);
    int i1     = get_global_id(1);
    int batch  = get_global_id(2);

    if (blk_i0 >= ne00 / QK4_0_CPY) return;
    if (i1     >= ne01)             return;

    int i2 = batch % ne02;
    int i3 = batch / ne02;

    global block_q4_0_cpy * blk = (global block_q4_0_cpy *)((global char *)src0 + offset0
        + (ulong)i3 * nb03 + (ulong)i2 * nb02 + (ulong)i1 * nb01 + (ulong)blk_i0 * nb00);

    global float * dstp = (global float *)((global char *)dst + offsetd
        + (ulong)i3 * nb13 + (ulong)i2 * nb12 + (ulong)i1 * nb11 + (ulong)blk_i0 * QK4_0_CPY * nb10);

    float d = (float)blk->d;
    for (int i = 0; i < QK4_0_CPY / 2; ++i) {
        uchar byte = blk->qs[i];
        int q0 = (int)(byte & 0x0F) - 8;
        int q1 = (int)(byte >> 4)   - 8;
        dstp[i]            = d * (float)q0;
        dstp[i + QK4_0_CPY / 2]  = d * (float)q1;
    }
}

// f32 -> q4_0 (AoS blocks), view-aware, standard cpy arg layout.
kernel void kernel_cpy_f32_q4_0_view_aos(
        global float * src0,
        ulong         offset0,
        global char * dst,
        ulong         offsetd,
        int ne00,
        int ne01,
        int ne02,
        int ne03,
        ulong nb00,
        ulong nb01,
        ulong nb02,
        ulong nb03,
        int ne10,
        int ne11,
        int ne12,
        int ne13,
        ulong nb10,
        ulong nb11,
        ulong nb12,
        ulong nb13
) {
    int blk_i0 = get_global_id(0);
    int i1     = get_global_id(1);
    int batch  = get_global_id(2);

    if (blk_i0 >= ne00 / QK4_0_CPY) return;
    if (i1     >= ne01)             return;

    int i2 = batch % ne02;
    int i3 = batch / ne02;

    global float * inp = (global float *)((global char *)src0 + offset0
        + (ulong)i3 * nb03 + (ulong)i2 * nb02 + (ulong)i1 * nb01 + (ulong)blk_i0 * QK4_0_CPY * nb00);

    global block_q4_0_cpy * blk = (global block_q4_0_cpy *)((global char *)dst + offsetd
        + (ulong)i3 * nb13 + (ulong)i2 * nb12 + (ulong)i1 * nb11 + (ulong)blk_i0 * nb10);

    // match CPU quantize_row_q4_0_ref: d = max/-8 where max is the largest-magnitude value
    float amax = 0.0f;
    float maxv = 0.0f;
    for (int i = 0; i < QK4_0_CPY; ++i) {
        float v = inp[i];
        float a = v < 0 ? -v : v;
        if (a > amax) { amax = a; maxv = v; }
    }
    float d  = maxv / -8.0f;
    float id = d != 0.0f ? 1.0f / d : 0.0f;

    blk->d = (half)d;
    for (int i = 0; i < QK4_0_CPY / 2; ++i) {
        int xi0 = (int)(inp[i]      * id + 8.5f);
        int xi1 = (int)(inp[i + QK4_0_CPY / 2] * id + 8.5f);
        if (xi0 < 0)   xi0 = 0;
        if (xi1 < 0)   xi1 = 0;
        if (xi0 > 15)  xi0 = 15;
        if (xi1 > 15)  xi1 = 15;
        blk->qs[i] = (uchar)(xi0) | ((uchar)xi1 << 4);
    }
}
