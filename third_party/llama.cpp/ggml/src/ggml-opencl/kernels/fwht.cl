#pragma OPENCL EXTENSION cl_khr_fp16 : enable

//------------------------------------------------------------------------------
// fwht
//
// MUL_MAT hadamard hint: dst = FWHT_rows(src1), row length n = src1->ne[0]
// (power of 2, <= 4096, gated host-side), rows = ne1*ne2*ne3. Row-major
// contiguous only. Matches ggml_compute_forward_fwht_impl: scale = 1/sqrt(n)
// at load, then butterfly len=1..n/2 with u+v / u-v. One workgroup per row.
//------------------------------------------------------------------------------

kernel void kernel_fwht_f32(
        global const float * src1,
        ulong                offset1,
        global       float * dst,
        ulong                offsetd,
        int                  n
) {
    src1 = (global float*)((global char*)src1 + offset1);
    dst  = (global float*)((global char*)dst  + offsetd);

    const int row = get_group_id(0);
    const int tid = get_local_id(0);
    const int lsz = get_local_size(0);

    __local float l[4096];

    const float scale = rsqrt((float)n);
    src1 += (long)row * n;
    dst  += (long)row * n;

    for (int i = tid; i < n; i += lsz) {
        l[i] = src1[i] * scale;
    }
    for (int log2len = 0, len = 1; len < n; len <<= 1, log2len++) {
        barrier(CLK_LOCAL_MEM_FENCE);
        for (int p = tid; p < (n >> 1); p += lsz) {
            const int a = ((p >> log2len) << (log2len + 1)) + (p & (len - 1));
            const float u = l[a];
            const float v = l[a + len];
            l[a]       = u + v;
            l[a + len] = u - v;
        }
    }
    barrier(CLK_LOCAL_MEM_FENCE);
    for (int i = tid; i < n; i += lsz) {
        dst[i] = l[i];
    }
}

kernel void kernel_fwht_f16(
        global const half * src1,
        ulong               offset1,
        global       float * dst,
        ulong                offsetd,
        int                  n
) {
    src1 = (global half*)((global char*)src1 + offset1);
    dst  = (global float*)((global char*)dst + offsetd);

    const int row = get_group_id(0);
    const int tid = get_local_id(0);
    const int lsz = get_local_size(0);

    __local float l[4096];

    const float scale = rsqrt((float)n);
    src1 += (long)row * n;
    dst  += (long)row * n;

    for (int i = tid; i < n; i += lsz) {
        l[i] = convert_float(src1[i]) * scale;
    }
    for (int log2len = 0, len = 1; len < n; len <<= 1, log2len++) {
        barrier(CLK_LOCAL_MEM_FENCE);
        for (int p = tid; p < (n >> 1); p += lsz) {
            const int a = ((p >> log2len) << (log2len + 1)) + (p & (len - 1));
            const float u = l[a];
            const float v = l[a + len];
            l[a]       = u + v;
            l[a + len] = u - v;
        }
    }
    barrier(CLK_LOCAL_MEM_FENCE);
    for (int i = tid; i < n; i += lsz) {
        dst[i] = l[i];
    }
}
