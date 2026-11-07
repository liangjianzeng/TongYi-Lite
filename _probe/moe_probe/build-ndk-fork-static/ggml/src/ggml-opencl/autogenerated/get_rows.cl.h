R"(#pragma OPENCL EXTENSION cl_khr_fp16 : enable
)"
R"(
)"
R"(typedef char int8_t;
)"
R"(typedef uchar uint8_t;
)"
R"(typedef short int16_t;
)"
R"(typedef ushort uint16_t;
)"
R"(typedef int int32_t;
)"
R"(typedef uint uint32_t;
)"
R"(
)"
R"(#define QK4_0                   32
)"
R"(
)"
R"(//------------------------------------------------------------------------------
)"
R"(// block_q4_0
)"
R"(//------------------------------------------------------------------------------
)"
R"(struct block_q4_0
)"
R"({
)"
R"(    half d;
)"
R"(    uint8_t qs[QK4_0 / 2];
)"
R"(};
)"
R"(
)"
R"(
)"
R"(//------------------------------------------------------------------------------
)"
R"(// dequantize_q4_0_f32, dequantize_q4_0_f16
)"
R"(//------------------------------------------------------------------------------
)"
R"(void dequantize_q4_0_f32(global struct block_q4_0 * xb, short il, float16 * reg) {
)"
R"(    global ushort * qs = ((global ushort *)xb + 1);
)"
R"(    float d1 = il ? (xb->d / 16.h) : xb->d;
)"
R"(    float d2 = d1 / 256.f;
)"
R"(    float md = -8.h * xb->d;
)"
R"(    ushort mask0 = il ? 0x00F0 : 0x000F;
)"
R"(    ushort mask1 = mask0 << 8;
)"
R"(
)"
R"(    reg->s0 = d1 * (qs[0] & mask0) + md;
)"
R"(    reg->s1 = d2 * (qs[0] & mask1) + md;
)"
R"(
)"
R"(    reg->s2 = d1 * (qs[1] & mask0) + md;
)"
R"(    reg->s3 = d2 * (qs[1] & mask1) + md;
)"
R"(
)"
R"(    reg->s4 = d1 * (qs[2] & mask0) + md;
)"
R"(    reg->s5 = d2 * (qs[2] & mask1) + md;
)"
R"(
)"
R"(    reg->s6 = d1 * (qs[3] & mask0) + md;
)"
R"(    reg->s7 = d2 * (qs[3] & mask1) + md;
)"
R"(
)"
R"(    reg->s8 = d1 * (qs[4] & mask0) + md;
)"
R"(    reg->s9 = d2 * (qs[4] & mask1) + md;
)"
R"(
)"
R"(    reg->sa = d1 * (qs[5] & mask0) + md;
)"
R"(    reg->sb = d2 * (qs[5] & mask1) + md;
)"
R"(
)"
R"(    reg->sc = d1 * (qs[6] & mask0) + md;
)"
R"(    reg->sd = d2 * (qs[6] & mask1) + md;
)"
R"(
)"
R"(    reg->se = d1 * (qs[7] & mask0) + md;
)"
R"(    reg->sf = d2 * (qs[7] & mask1) + md;
)"
R"(}
)"
R"(
)"
R"(
)"
R"(//------------------------------------------------------------------------------
)"
R"(// get_rows
)"
R"(//------------------------------------------------------------------------------
)"
R"(kernel void kernel_get_rows_f32(
)"
R"(        global void * src0,
)"
R"(        ulong offset0,
)"
R"(        global int * src1,
)"
R"(        ulong offset1,
)"
R"(        global float * dst,
)"
R"(        ulong offsetd,
)"
R"(        int ne00,
)"
R"(        ulong nb01,
)"
R"(        ulong nb02,
)"
R"(        ulong nb03,
)"
R"(        int ne10,
)"
R"(        ulong nb10,
)"
R"(        ulong nb11,
)"
R"(        ulong nb12,
)"
R"(        ulong nb1,
)"
R"(        ulong nb2,
)"
R"(        ulong nb3
)"
R"() {
)"
R"(    src0 = (global void*)((global char*)src0 + offset0);
)"
R"(    src1 = (global int*)((global char*)src1 + offset1);
)"
R"(    dst = (global float*)((global char*)dst + offsetd);
)"
R"(
)"
R"(    int nchunks = get_num_groups(0) / ne10;
)"
R"(    int g       = get_group_id(0);
)"
R"(    int i10     = g / nchunks;
)"
R"(    int chunk   = g - i10 * nchunks;
)"
R"(    int i11     = get_group_id(1);
)"
R"(    int i12     = get_group_id(2);
)"
R"(
)"
R"(    int r = ((global int *) ((global char *) src1 + i12*nb12 + i11*nb11 + i10*nb10))[0];
)"
R"(
)"
R"(    int i02 = i11;
)"
R"(    int i03 = i12;
)"
R"(
)"
R"(    global float * dst_row = (global float *) ((global char *) dst  + i12*nb3 + i11*nb2 + i10*nb1);
)"
R"(    global float * src_row = (global float *) ((global char *) src0 + r*nb01 + i02*nb02 + i03*nb03);
)"
R"(
)"
R"(    int span  = (ne00 + nchunks - 1) / nchunks;
)"
R"(    int start = chunk * span;
)"
R"(    int end   = min(start + span, ne00);
)"
R"(
)"
R"(    for (int ind = start + get_local_id(0); ind < end; ind += get_local_size(0)) {
)"
R"(        dst_row[ind] = src_row[ind];
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_get_rows_f16(
)"
R"(        global void * src0,
)"
R"(        ulong offset0,
)"
R"(        global int * src1,
)"
R"(        ulong offset1,
)"
R"(        global float * dst,
)"
R"(        ulong offsetd,
)"
R"(        int ne00,
)"
R"(        ulong nb01,
)"
R"(        ulong nb02,
)"
R"(        ulong nb03,
)"
R"(        int ne10,
)"
R"(        ulong nb10,
)"
R"(        ulong nb11,
)"
R"(        ulong nb12,
)"
R"(        ulong nb1,
)"
R"(        ulong nb2,
)"
R"(        ulong nb3
)"
R"() {
)"
R"(    src0 = (global void*)((global char*)src0 + offset0);
)"
R"(    src1 = (global int*)((global char*)src1 + offset1);
)"
R"(    dst = (global float*)((global char*)dst + offsetd);
)"
R"(
)"
R"(    int i10 = get_group_id(0);
)"
R"(    int i11 = get_group_id(1);
)"
R"(    int i12 = get_group_id(2);
)"
R"(
)"
R"(    int r = ((global int32_t *) ((global char *) src1 + i12*nb12 + i11*nb11 + i10*nb10))[0];
)"
R"(
)"
R"(    int i02 = i11;
)"
R"(    int i03 = i12;
)"
R"(
)"
R"(    for (int ind = get_local_id(0); ind < ne00; ind += get_local_size(0)) {
)"
R"(        if (ind >= ne00) {
)"
R"(            return;
)"
R"(        }
)"
R"(        ((global float *) ((global char *) dst + i12*nb3 + i11*nb2 + i10*nb1))[ind] =
)"
R"(            ((global half *) ((global char *) src0 + r*nb01 + i02*nb02 + i03*nb03))[ind];
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_get_rows_q4_0(
)"
R"(        global void * src0,
)"
R"(        ulong offset0,
)"
R"(        global int * src1,
)"
R"(        ulong offset1,
)"
R"(        global float * dst,
)"
R"(        ulong offsetd,
)"
R"(        int ne00,
)"
R"(        ulong nb01,
)"
R"(        ulong nb02,
)"
R"(        ulong nb03,
)"
R"(        int ne10,
)"
R"(        ulong nb10,
)"
R"(        ulong nb11,
)"
R"(        ulong nb12,
)"
R"(        ulong nb1,
)"
R"(        ulong nb2,
)"
R"(        ulong nb3
)"
R"() {
)"
R"(    src0 = (global void*)((global char*)src0 + offset0);
)"
R"(    src1 = (global int*)((global char*)src1 + offset1);
)"
R"(    dst = (global float*)((global char*)dst + offsetd);
)"
R"(
)"
R"(    const int NL = 2;
)"
R"(
)"
R"(    int i10 = get_group_id(0);
)"
R"(    int i11 = get_group_id(1);
)"
R"(    int i12 = get_group_id(2);
)"
R"(
)"
R"(    int r = ((global int32_t *) ((global char *) src1 + i12*nb12 + i11*nb11 + i10*nb10))[0];
)"
R"(
)"
R"(    int i02 = i11;
)"
R"(    int i03 = i12;
)"
R"(
)"
R"(    for (int ind = get_local_id(0); ind < ne00/16; ind += get_local_size(0)) {
)"
R"(        float16 temp;
)"
R"(        if (ind >= ne00) {
)"
R"(            return;
)"
R"(        }
)"
R"(        dequantize_q4_0_f32(
)"
R"(            ((global struct block_q4_0 *) ((global char *) src0 + r*nb01 + i02*nb02 + i03*nb03)) + ind/NL, ind%NL, &temp);
)"
R"(        *(((global float16 *) ((global char *) dst + i12*nb3 + i11*nb2 + i10*nb1)) + ind) = temp;
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(// [tongyi SSM state R-275 第二刀 2026-11-04] Contiguous dst + 1-D contiguous idx gather,
)"
R"(// one work item per float4 over the whole output. The row-mapped kernel spawns ne10*nth*nchunks
)"
R"(// workgroups (measured 65536 groups to move 1MB = 1.7 GB/s on the GDN state row-slices); this
)"
R"(// shape is a flat stream: idx row table read per item (L2-resident), src rows gathered, dst
)"
R"(// stores fully coalesced. Host gate: f32 src, dst & idx contiguous, dst=[ne00,ne10,1,1].
)"
R"(kernel void kernel_get_rows_f32_flat(
)"
R"(        global void * src0,
)"
R"(        ulong offset0,
)"
R"(        global int * src1,
)"
R"(        ulong offset1,
)"
R"(        global float * dst,
)"
R"(        ulong offsetd,
)"
R"(        int ne00,
)"
R"(        ulong nb01,
)"
R"(        int ne10,
)"
R"(        ulong nb10,
)"
R"(        ulong ne
)"
R"() {
)"
R"(    src0 = (global void*)((global char*)src0 + offset0);
)"
R"(    src1 = (global int*)((global char*)src1 + offset1);
)"
R"(    dst  = (global float*)((global char*)dst + offsetd);
)"
R"(
)"
R"(    const ulong i  = get_global_id(0);
)"
R"(    const ulong n4 = ne / 4;
)"
R"(
)"
R"(    // [tongyi R-280] Single-row fast path (GDN recurrent-state copy: ne10==1, idx=[seq slot]):
)"
R"(    // zero 64-bit divides, zero row/col decomposition — one idx[0] L2 read for the row base,
)"
R"(    // then a pure linear memcpy. The multi-row flat path below loses to the row-mapped kernel
)"
R"(    // on ulong divides (R-276), but this shape has no divide to pay; measured 2MB single-row
)"
R"(    // copy at 3.2 GB/s on the row-mapped kernel (nth=1024 x nchunks=64).
)"
R"(    if (ne10 == 1) {
)"
R"(        const int r = src1[0];
)"
R"(        const global float * s = (global const float*)((global const char*)src0 + (ulong)r*nb01);
)"
R"(        if (i < n4) {
)"
R"(            float v[4];
)"
R"(            #pragma unroll
)"
R"(            for (int k = 0; k < 4; ++k) { v[k] = s[i*4 + k]; }
)"
R"(            vstore4((float4)(v[0], v[1], v[2], v[3]), i, dst);
)"
R"(        } else if (i == n4 && (ne & 3)) {
)"
R"(            for (ulong t = n4*4; t < ne; ++t) { dst[t] = s[t]; }
)"
R"(        }
)"
R"(        return;
)"
R"(    }
)"
R"(
)"
R"(    if (i < n4) {
)"
R"(        // [R-275 v2] one 64-bit div per item (not per element): when the float4 sits
)"
R"(        // fully inside a row (ne00%4==0 makes this always true on the GDN path) do a
)"
R"(        // single idx read + 4 contiguous scalars. The per-element div version measured
)"
R"(        // 4x SLOWER than the row-mapped kernel it replaced (ulong div is micro-coded).
)"
R"(        const ulong base = i*4;
)"
R"(        const ulong row  = base / (ulong)ne00;
)"
R"(        const ulong col  = base - row*(ulong)ne00;
)"
R"(        if (col + 3 < (ulong)ne00) {
)"
R"(            const int r = *(global const int*)((global const char*)src1 + row*nb10);
)"
R"(            const global float * s = (global const float*)((global const char*)src0 + (ulong)r*nb01 + col*4);
)"
R"(            vstore4((float4)(s[0], s[1], s[2], s[3]), i, dst);
)"
R"(        } else {
)"
R"(            float v[4];
)"
R"(            #pragma unroll
)"
R"(            for (int k = 0; k < 4; ++k) {
)"
R"(                const ulong e   = base + (ulong)k;
)"
R"(                const ulong r2  = e / (ulong)ne00;
)"
R"(                const ulong c2  = e - r2*(ulong)ne00;
)"
R"(                const int   r   = *(global const int*)((global const char*)src1 + r2*nb10);
)"
R"(                v[k] = *(global const float*)((global const char*)src0 + (ulong)r*nb01 + c2*4);
)"
R"(            }
)"
R"(            vstore4((float4)(v[0], v[1], v[2], v[3]), i, dst);
)"
R"(        }
)"
R"(    } else if (i == n4 && (ne & 3)) {
)"
R"(        for (ulong t = n4*4; t < ne; ++t) {
)"
R"(            const ulong row = t / (ulong)ne00;
)"
R"(            const ulong col = t - row*(ulong)ne00;
)"
R"(            const int   r   = *(global const int*)((global const char*)src1 + row*nb10);
)"
R"(            dst[t] = *(global const float*)((global const char*)src0 + (ulong)r*nb01 + col*4);
)"
R"(        }
)"
R"(    }
)"
R"(}
)"
