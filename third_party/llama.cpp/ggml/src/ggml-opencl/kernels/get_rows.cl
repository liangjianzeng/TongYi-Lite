#pragma OPENCL EXTENSION cl_khr_fp16 : enable

typedef char int8_t;
typedef uchar uint8_t;
typedef short int16_t;
typedef ushort uint16_t;
typedef int int32_t;
typedef uint uint32_t;

#define QK4_0                   32

//------------------------------------------------------------------------------
// block_q4_0
//------------------------------------------------------------------------------
struct block_q4_0
{
    half d;
    uint8_t qs[QK4_0 / 2];
};


//------------------------------------------------------------------------------
// dequantize_q4_0_f32, dequantize_q4_0_f16
//------------------------------------------------------------------------------
void dequantize_q4_0_f32(global struct block_q4_0 * xb, short il, float16 * reg) {
    global ushort * qs = ((global ushort *)xb + 1);
    float d1 = il ? (xb->d / 16.h) : xb->d;
    float d2 = d1 / 256.f;
    float md = -8.h * xb->d;
    ushort mask0 = il ? 0x00F0 : 0x000F;
    ushort mask1 = mask0 << 8;

    reg->s0 = d1 * (qs[0] & mask0) + md;
    reg->s1 = d2 * (qs[0] & mask1) + md;

    reg->s2 = d1 * (qs[1] & mask0) + md;
    reg->s3 = d2 * (qs[1] & mask1) + md;

    reg->s4 = d1 * (qs[2] & mask0) + md;
    reg->s5 = d2 * (qs[2] & mask1) + md;

    reg->s6 = d1 * (qs[3] & mask0) + md;
    reg->s7 = d2 * (qs[3] & mask1) + md;

    reg->s8 = d1 * (qs[4] & mask0) + md;
    reg->s9 = d2 * (qs[4] & mask1) + md;

    reg->sa = d1 * (qs[5] & mask0) + md;
    reg->sb = d2 * (qs[5] & mask1) + md;

    reg->sc = d1 * (qs[6] & mask0) + md;
    reg->sd = d2 * (qs[6] & mask1) + md;

    reg->se = d1 * (qs[7] & mask0) + md;
    reg->sf = d2 * (qs[7] & mask1) + md;
}


//------------------------------------------------------------------------------
// get_rows
//------------------------------------------------------------------------------
kernel void kernel_get_rows_f32(
        global void * src0,
        ulong offset0,
        global int * src1,
        ulong offset1,
        global float * dst,
        ulong offsetd,
        int ne00,
        ulong nb01,
        ulong nb02,
        ulong nb03,
        int ne10,
        ulong nb10,
        ulong nb11,
        ulong nb12,
        ulong nb1,
        ulong nb2,
        ulong nb3
) {
    src0 = (global void*)((global char*)src0 + offset0);
    src1 = (global int*)((global char*)src1 + offset1);
    dst = (global float*)((global char*)dst + offsetd);

    int nchunks = get_num_groups(0) / ne10;
    int g       = get_group_id(0);
    int i10     = g / nchunks;
    int chunk   = g - i10 * nchunks;
    int i11     = get_group_id(1);
    int i12     = get_group_id(2);

    int r = ((global int *) ((global char *) src1 + i12*nb12 + i11*nb11 + i10*nb10))[0];

    int i02 = i11;
    int i03 = i12;

    global float * dst_row = (global float *) ((global char *) dst  + i12*nb3 + i11*nb2 + i10*nb1);
    global float * src_row = (global float *) ((global char *) src0 + r*nb01 + i02*nb02 + i03*nb03);

    int span  = (ne00 + nchunks - 1) / nchunks;
    int start = chunk * span;
    int end   = min(start + span, ne00);

    for (int ind = start + get_local_id(0); ind < end; ind += get_local_size(0)) {
        dst_row[ind] = src_row[ind];
    }
}

kernel void kernel_get_rows_f16(
        global void * src0,
        ulong offset0,
        global int * src1,
        ulong offset1,
        global float * dst,
        ulong offsetd,
        int ne00,
        ulong nb01,
        ulong nb02,
        ulong nb03,
        int ne10,
        ulong nb10,
        ulong nb11,
        ulong nb12,
        ulong nb1,
        ulong nb2,
        ulong nb3
) {
    src0 = (global void*)((global char*)src0 + offset0);
    src1 = (global int*)((global char*)src1 + offset1);
    dst = (global float*)((global char*)dst + offsetd);

    int i10 = get_group_id(0);
    int i11 = get_group_id(1);
    int i12 = get_group_id(2);

    int r = ((global int32_t *) ((global char *) src1 + i12*nb12 + i11*nb11 + i10*nb10))[0];

    int i02 = i11;
    int i03 = i12;

    for (int ind = get_local_id(0); ind < ne00; ind += get_local_size(0)) {
        if (ind >= ne00) {
            return;
        }
        ((global float *) ((global char *) dst + i12*nb3 + i11*nb2 + i10*nb1))[ind] =
            ((global half *) ((global char *) src0 + r*nb01 + i02*nb02 + i03*nb03))[ind];
    }
}

kernel void kernel_get_rows_q4_0(
        global void * src0,
        ulong offset0,
        global int * src1,
        ulong offset1,
        global float * dst,
        ulong offsetd,
        int ne00,
        ulong nb01,
        ulong nb02,
        ulong nb03,
        int ne10,
        ulong nb10,
        ulong nb11,
        ulong nb12,
        ulong nb1,
        ulong nb2,
        ulong nb3
) {
    src0 = (global void*)((global char*)src0 + offset0);
    src1 = (global int*)((global char*)src1 + offset1);
    dst = (global float*)((global char*)dst + offsetd);

    const int NL = 2;

    int i10 = get_group_id(0);
    int i11 = get_group_id(1);
    int i12 = get_group_id(2);

    int r = ((global int32_t *) ((global char *) src1 + i12*nb12 + i11*nb11 + i10*nb10))[0];

    int i02 = i11;
    int i03 = i12;

    for (int ind = get_local_id(0); ind < ne00/16; ind += get_local_size(0)) {
        float16 temp;
        if (ind >= ne00) {
            return;
        }
        dequantize_q4_0_f32(
            ((global struct block_q4_0 *) ((global char *) src0 + r*nb01 + i02*nb02 + i03*nb03)) + ind/NL, ind%NL, &temp);
        *(((global float16 *) ((global char *) dst + i12*nb3 + i11*nb2 + i10*nb1)) + ind) = temp;
    }
}

// [tongyi SSM state R-275 第二刀 2026-11-04] Contiguous dst + 1-D contiguous idx gather,
// one work item per float4 over the whole output. The row-mapped kernel spawns ne10*nth*nchunks
// workgroups (measured 65536 groups to move 1MB = 1.7 GB/s on the GDN state row-slices); this
// shape is a flat stream: idx row table read per item (L2-resident), src rows gathered, dst
// stores fully coalesced. Host gate: f32 src, dst & idx contiguous, dst=[ne00,ne10,1,1].
kernel void kernel_get_rows_f32_flat(
        global void * src0,
        ulong offset0,
        global int * src1,
        ulong offset1,
        global float * dst,
        ulong offsetd,
        int ne00,
        ulong nb01,
        int ne10,
        ulong nb10,
        ulong ne
) {
    src0 = (global void*)((global char*)src0 + offset0);
    src1 = (global int*)((global char*)src1 + offset1);
    dst  = (global float*)((global char*)dst + offsetd);

    const ulong i  = get_global_id(0);
    const ulong n4 = ne / 4;

    // [tongyi R-280] Single-row fast path (GDN recurrent-state copy: ne10==1, idx=[seq slot]):
    // zero 64-bit divides, zero row/col decomposition — one idx[0] L2 read for the row base,
    // then a pure linear memcpy. The multi-row flat path below loses to the row-mapped kernel
    // on ulong divides (R-276), but this shape has no divide to pay; measured 2MB single-row
    // copy at 3.2 GB/s on the row-mapped kernel (nth=1024 x nchunks=64).
    if (ne10 == 1) {
        const int r = src1[0];
        const global float * s = (global const float*)((global const char*)src0 + (ulong)r*nb01);
        if (i < n4) {
            float v[4];
            #pragma unroll
            for (int k = 0; k < 4; ++k) { v[k] = s[i*4 + k]; }
            vstore4((float4)(v[0], v[1], v[2], v[3]), i, dst);
        } else if (i == n4 && (ne & 3)) {
            for (ulong t = n4*4; t < ne; ++t) { dst[t] = s[t]; }
        }
        return;
    }

    if (i < n4) {
        // [R-275 v2] one 64-bit div per item (not per element): when the float4 sits
        // fully inside a row (ne00%4==0 makes this always true on the GDN path) do a
        // single idx read + 4 contiguous scalars. The per-element div version measured
        // 4x SLOWER than the row-mapped kernel it replaced (ulong div is micro-coded).
        const ulong base = i*4;
        const ulong row  = base / (ulong)ne00;
        const ulong col  = base - row*(ulong)ne00;
        if (col + 3 < (ulong)ne00) {
            const int r = *(global const int*)((global const char*)src1 + row*nb10);
            const global float * s = (global const float*)((global const char*)src0 + (ulong)r*nb01 + col*4);
            vstore4((float4)(s[0], s[1], s[2], s[3]), i, dst);
        } else {
            float v[4];
            #pragma unroll
            for (int k = 0; k < 4; ++k) {
                const ulong e   = base + (ulong)k;
                const ulong r2  = e / (ulong)ne00;
                const ulong c2  = e - r2*(ulong)ne00;
                const int   r   = *(global const int*)((global const char*)src1 + r2*nb10);
                v[k] = *(global const float*)((global const char*)src0 + (ulong)r*nb01 + c2*4);
            }
            vstore4((float4)(v[0], v[1], v[2], v[3]), i, dst);
        }
    } else if (i == n4 && (ne & 3)) {
        for (ulong t = n4*4; t < ne; ++t) {
            const ulong row = t / (ulong)ne00;
            const ulong col = t - row*(ulong)ne00;
            const int   r   = *(global const int*)((global const char*)src1 + row*nb10);
            dst[t] = *(global const float*)((global const char*)src0 + (ulong)r*nb01 + col*4);
        }
    }
}
