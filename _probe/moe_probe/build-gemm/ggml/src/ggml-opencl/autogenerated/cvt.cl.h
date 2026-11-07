R"(//------------------------------------------------------------------------------
)"
R"(// This file is contains kernels for data conversion.
)"
R"(// These kernels are used when loading the model, so its performance is less
)"
R"(// important.
)"
R"(//------------------------------------------------------------------------------
)"
R"(#pragma OPENCL EXTENSION cl_khr_fp16 : enable
)"
R"(
)"
R"(#ifdef cl_intel_required_subgroup_size
)"
R"(#pragma OPENCL EXTENSION cl_intel_required_subgroup_size : enable
)"
R"(#define INTEL_GPU 1
)"
R"(#define REQD_SUBGROUP_SIZE_16 __attribute__((intel_reqd_sub_group_size(16)))
)"
R"(#define REQD_SUBGROUP_SIZE_32 __attribute__((intel_reqd_sub_group_size(32)))
)"
R"(#elif defined(cl_qcom_reqd_sub_group_size)
)"
R"(#pragma OPENCL EXTENSION cl_qcom_reqd_sub_group_size : enable
)"
R"(#define ADRENO_GPU 1
)"
R"(#define REQD_SUBGROUP_SIZE_64  __attribute__((qcom_reqd_sub_group_size("half")))
)"
R"(#define REQD_SUBGROUP_SIZE_128 __attribute__((qcom_reqd_sub_group_size("full")))
)"
R"(#endif
)"
R"(
)"
R"(#define QK4_0                   32
)"
R"(#define QR4_0                   2
)"
R"(#define QK4_1                   32
)"
R"(#define QR4_1                   2
)"
R"(#define QK5_0                   32
)"
R"(#define QR5_0                   2
)"
R"(#define QK5_1                   32
)"
R"(#define QR5_1                   2
)"
R"(#define QK8_0                   32
)"
R"(#define QR8_0                   1
)"
R"(#define QK1_0                   128
)"
R"(#define QR1_0                   1
)"
R"(#define QK_K                    256
)"
R"(#define K_SCALE_SIZE            (3 * QK_K / 64)
)"
R"(#define K_QUANTS_PER_ITERATION  2
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
R"(//------------------------------------------------------------------------------
)"
R"(// block_q1_0
)"
R"(//------------------------------------------------------------------------------
)"
R"(typedef struct {
)"
R"(    half d;             // delta
)"
R"(    uchar qs[QK1_0/8];  // 1-bit signs (16 bytes)
)"
R"(} block_q1_0;
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
R"(//------------------------------------------------------------------------------
)"
R"(// block_q4_1
)"
R"(//------------------------------------------------------------------------------
)"
R"(struct block_q4_1 {
)"
R"(    half d; // delta
)"
R"(    half m; // min
)"
R"(    uchar qs[QK4_1 / 2]; // nibbles / quants
)"
R"(};
)"
R"(
)"
R"(//------------------------------------------------------------------------------
)"
R"(// block_q5_0
)"
R"(//------------------------------------------------------------------------------
)"
R"(struct block_q5_0 {
)"
R"(    half d; // delta
)"
R"(    uchar qh[4]; // 5-th bit of quants
)"
R"(    uchar qs[QK5_0 / 2]; // nibbles / quants
)"
R"(};
)"
R"(
)"
R"(//------------------------------------------------------------------------------
)"
R"(// block_q5_1
)"
R"(//------------------------------------------------------------------------------
)"
R"(struct block_q5_1 {
)"
R"(    half d; // delta
)"
R"(    half m; // min
)"
R"(    uchar qh[4]; // 5-th bit of quants
)"
R"(    uchar qs[QK5_1 / 2]; // nibbles / quants
)"
R"(};
)"
R"(
)"
R"(//------------------------------------------------------------------------------
)"
R"(// block_q4_k
)"
R"(//------------------------------------------------------------------------------
)"
R"(struct block_q4_K {
)"
R"(    half d; // delta
)"
R"(    half dm; // min
)"
R"(    uchar s[K_SCALE_SIZE];
)"
R"(    uchar q[QK_K / 2]; // nibbles / quants
)"
R"(};
)"
R"(
)"
R"(//------------------------------------------------------------------------------
)"
R"(// block_q5_k
)"
R"(//------------------------------------------------------------------------------
)"
R"(struct block_q5_K {
)"
R"(    half d; // delta
)"
R"(    half dm; // min
)"
R"(    uchar s[K_SCALE_SIZE];
)"
R"(    uchar qh[QK_K / 8];
)"
R"(    uchar qs[QK_K / 2]; // nibbles / quants
)"
R"(};
)"
R"(
)"
R"(//------------------------------------------------------------------------------
)"
R"(// block_q6_K
)"
R"(//------------------------------------------------------------------------------
)"
R"(struct block_q6_K {
)"
R"(    uint8_t ql[QK_K/2];      // quants, lower 4 bits
)"
R"(    uint8_t qh[QK_K/4];      // quants, upper 2 bits
)"
R"(    int8_t  scales[QK_K/16]; // scales, quantized with 8 bits
)"
R"(    half d;                  // super-block scale
)"
R"(};
)"
R"(
)"
R"(//------------------------------------------------------------------------------
)"
R"(// block_iq4_nl
)"
R"(//------------------------------------------------------------------------------
)"
R"(#define QK4_NL 32
)"
R"(
)"
R"(struct block_iq4_nl
)"
R"({
)"
R"(    half d;
)"
R"(    uint8_t qs[QK4_NL / 2];
)"
R"(};
)"
R"(
)"
R"(//------------------------------------------------------------------------------
)"
R"(// bf16 to f16
)"
R"(//------------------------------------------------------------------------------
)"
R"(kernel void kernel_convert_bf16_to_f16(
)"
R"(    global const ushort * src,
)"
R"(    global half * dst,
)"
R"(    ulong off_dst,
)"
R"(    ulong n
)"
R"() {
)"
R"(    uint i = get_global_id(0);
)"
R"(    if (i >= n) {
)"
R"(        return;
)"
R"(    }
)"
R"(
)"
R"(    dst[i + off_dst] = (half) as_float((uint) src[i] << 16);
)"
R"(}
)"
R"(
)"
R"(//------------------------------------------------------------------------------
)"
R"(// f16 to bf16
)"
R"(//------------------------------------------------------------------------------
)"
R"(kernel void kernel_convert_f16_to_bf16(
)"
R"(    global const half * src,
)"
R"(    ulong off_src,
)"
R"(    global ushort * dst,
)"
R"(    ulong n
)"
R"() {
)"
R"(    uint i = get_global_id(0);
)"
R"(    if (i >= n) {
)"
R"(        return;
)"
R"(    }
)"
R"(
)"
R"(    float f = (float) src[i + off_src];
)"
R"(    uint bits = as_uint(f);
)"
R"(    if ((bits & 0x7fffffffu) > 0x7f800000u) {
)"
R"(        // nan to quiet nan
)"
R"(        dst[i] = (ushort)((bits >> 16) | 0x40u);
)"
R"(    } else {
)"
R"(        uint rounded = bits + 0x7fffu + ((bits >> 16) & 1u);
)"
R"(        dst[i] = (ushort)(rounded >> 16);
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(//------------------------------------------------------------------------------
)"
R"(// kernel_convert_block_q1_0
)"
R"(// Convert block_q1_0 (AOS) to 2 separate arrays (SOA): quant bytes + scales.
)"
R"(// q1_0 bits are stored in natural order (bit j of byte i -> weight 8*i + j)
)"
R"(//------------------------------------------------------------------------------
)"
R"(kernel void kernel_convert_block_q1_0(
)"
R"(    global block_q1_0 * src0,
)"
R"(    global uchar * dst_q,
)"
R"(    global half  * dst_d
)"
R"() {
)"
R"(    global block_q1_0 * b = (global block_q1_0 *) src0 + get_global_id(0);
)"
R"(    global uchar      * q = (global uchar *) dst_q + (QK1_0/8)*get_global_id(0);
)"
R"(    global half       * d = (global half *) dst_d + get_global_id(0);
)"
R"(
)"
R"(    *d = b->d;
)"
R"(
)"
R"(    for (int i = 0; i < QK1_0/8; ++i) {
)"
R"(        q[i] = b->qs[i];
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_restore_block_q1_0(
)"
R"(    global uchar * src_q,
)"
R"(    global half  * src_d,
)"
R"(    global block_q1_0 * dst
)"
R"() {
)"
R"(    global block_q1_0 * b = (global block_q1_0 *) dst + get_global_id(0);
)"
R"(    global uchar      * q = (global uchar *) src_q + (QK1_0/8)*get_global_id(0);
)"
R"(    global half       * d = (global half *) src_d + get_global_id(0);
)"
R"(
)"
R"(    b->d = *d;
)"
R"(    for (int i = 0; i < QK1_0/8; ++i) {
)"
R"(        b->qs[i] = q[i];
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(//------------------------------------------------------------------------------
)"
R"(// kernel_convert_block_q4_0
)"
R"(// Convert the block_q4_0 format to 2 separate arrays (AOS -> SOA).
)"
R"(// This kernel does not deshuffle the bits.
)"
R"(//------------------------------------------------------------------------------
)"
R"(kernel void kernel_convert_block_q4_0(
)"
R"(    global struct block_q4_0 * src0,
)"
R"(    global uchar * dst_q,
)"
R"(    global half  * dst_d
)"
R"() {
)"
R"(    global struct block_q4_0 * b = (global struct block_q4_0 *) src0 + get_global_id(0);
)"
R"(    global uchar * q = (global uchar *) dst_q + QK4_0/2*get_global_id(0);
)"
R"(    global half  * d = (global half *) dst_d + get_global_id(0);
)"
R"(
)"
R"(    *d = b->d;
)"
R"(
)"
R"(    for (int i = 0; i < QK4_0/2; ++i) {
)"
R"(        q[i] = b->qs[i];
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_restore_block_q4_0(
)"
R"(    global uchar * src_q,
)"
R"(    global half  * src_d,
)"
R"(    global struct block_q4_0 * dst
)"
R"() {
)"
R"(    global struct block_q4_0 * b = (global struct block_q4_0 *) dst + get_global_id(0);
)"
R"(    global uchar * q = (global uchar *) src_q + QK4_0/2*get_global_id(0);
)"
R"(    global half  * d = (global half *) src_d + get_global_id(0);
)"
R"(
)"
R"(    b->d = *d;
)"
R"(    for (int i = 0; i < QK4_0/2; ++i) {
)"
R"(        b->qs[i] = q[i];
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(//------------------------------------------------------------------------------
)"
R"(// kernel_convert_block_q4_0_noshuffle
)"
R"(// Flatten q4_0 weights and unshuffle the bits
)"
R"(//------------------------------------------------------------------------------
)"
R"(
)"
R"(kernel void kernel_convert_block_q4_0_noshuffle(
)"
R"(    global struct block_q4_0 * src0,
)"
R"(    global uchar * dst_q,
)"
R"(    global half  * dst_d
)"
R"() {
)"
R"(    global struct block_q4_0 * b = (global struct block_q4_0 *) src0 + get_global_id(0);
)"
R"(    global uchar * q = (global uchar *) dst_q + QK4_0/2*get_global_id(0);
)"
R"(    global half  * d = (global half *) dst_d + get_global_id(0);
)"
R"(
)"
R"(    *d = b->d;
)"
R"(    for (int i = 0; i < QK4_0/4; ++i) {
)"
R"(        uchar x0 = b->qs[2*i + 0];
)"
R"(        uchar x1 = b->qs[2*i + 1];
)"
R"(
)"
R"(        q[i + 0      ] = convert_uchar(x0 & 0x0F) | convert_uchar((x1 & 0x0F) << 4);
)"
R"(        q[i + QK4_0/4] = convert_uchar((x0 & 0xF0) >> 4) | convert_uchar(x1 & 0xF0);
)"
R"(
)"
R"(// [dspark 2026-10-19] printf hack removed under rusticl (FAKE_QCOM): it is a QC
)"
R"(// online-compiler workaround only; on rusticl/clang the never-firing printf makes
)"
R"(// NIR allocate a device printf buffer whose uninitialized header is read back by
)"
R"(// the host as a bogus length -> Rust range panic -> process abort (K40 a650).
)"
R"(#if defined(ADRENO_GPU) && !defined(GGML_NO_ADRENO_PRINTF_HACK)
)"
R"(        if (get_global_id(0) == 65536*4096) {
)"
R"(            printf("%04x - %02x\n", *(global ushort*)d, ((x0 & 0xF0) >> 4) | (x1 & 0xF0));
)"
R"(        }
)"
R"(#endif
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_restore_block_q4_0_noshuffle(
)"
R"(    global uchar * src_q,
)"
R"(    global half  * src_d,
)"
R"(    global struct block_q4_0 * dst,
)"
R"(    uchar mask_0F,
)"
R"(    uchar mask_F0
)"
R"() {
)"
R"(    global struct block_q4_0 * b = (global struct block_q4_0 *) dst + get_global_id(0);
)"
R"(    global uchar * q = (global uchar *) src_q + QK4_0/2*get_global_id(0);
)"
R"(    global half  * d = (global half *) src_d + get_global_id(0);
)"
R"(
)"
R"(    b->d = *d;
)"
R"(    for (int i = 0; i < QK4_0/4; ++i) {
)"
R"(        uchar x0 = q[i + 0      ] ;
)"
R"(        uchar x1 = q[i + QK4_0/4];
)"
R"(
)"
R"(        b->qs[2*i + 0] = convert_uchar((x0 & mask_0F) | ((x1 & mask_0F) << 4));
)"
R"(        b->qs[2*i + 1] = convert_uchar(((x0 & mask_F0) >> 4) | (x1 & mask_F0));
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_convert_block_q4_0_trans4_ns(
)"
R"(    global struct block_q4_0 * src0,
)"
R"(    __global uint * dst_q,
)"
R"(    __global half * dst_d,
)"
R"(    uint ne00,
)"
R"(    uint ne01
)"
R"() {
)"
R"(    uint i00 = get_global_id(1);
)"
R"(    uint i01 = get_global_id(0);
)"
R"(    uint i02 = get_global_id(2);
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
R"(    uint ne00_blk = ne00 / QK4_0;
)"
R"(    uint src_blk_offset = i00 + i01 * ne00_blk + i02 * ne00_blk * ne01;
)"
R"(    uint dst_blk_offset = i01 + i00 * ne01 + i02 * ne00_blk * ne01;
)"
R"(
)"
R"(    global struct block_q4_0 * b = src0 + src_blk_offset;
)"
R"(    dst_d[dst_blk_offset] = b->d;
)"
R"(
)"
R"(    // extract quantization and unshuffle
)"
R"(    // [dspark 2026-10-13] Do NOT alias private vectors through uchar* here.
)"
R"(    // Qualcomm Adreno compilers have been observed to miscompile exactly this
)"
R"(    // pattern (use_adreno_moe_kernels excludes A6x/A7x upstream for precisely
)"
R"(    // these *_trans4_ns repack kernels; E031.47.18.49 on Adreno 830 shows the
)"
R"(    // same corruption: on-device probe rel err ~0.2-0.3 for q4_0, output =
)"
R"(    // correct value x wrong constant for q4_K, garbage logits in real models).
)"
R"(    // Build the packed words explicitly with shifts instead.
)"
R"(    global uchar * qs = b->qs;
)"
R"(    uint wx = 0, wy = 0, wz = 0, ww = 0;
)"
R"(    for (int i = 0; i < QK4_0 / 4; ++i) {
)"
R"(        uchar x0 = qs[2*i + 0];
)"
R"(        uchar x1 = qs[2*i + 1];
)"
R"(
)"
R"(        uchar lo = convert_uchar(x0 & 0x0F) | convert_uchar((x1 & 0x0F) << 4);
)"
R"(        uchar hi = convert_uchar((x0 & 0xF0) >> 4) | convert_uchar(x1 & 0xF0);
)"
R"(
)"
R"(        if (i < 4) {
)"
R"(            wx |= ((uint)lo) << (i * 8);
)"
R"(            wz |= ((uint)hi) << (i * 8);
)"
R"(        } else {
)"
R"(            wy |= ((uint)lo) << ((i - 4) * 8);
)"
R"(            ww |= ((uint)hi) << ((i - 4) * 8);
)"
R"(        }
)"
R"(    }
)"
R"(    uint4 q_block = (uint4)(wx, wy, wz, ww);
)"
R"(
)"
R"(    uint offset = i02 * ne00_blk * ne01 * 4 + i00 * ne01 * 4 + i01;
)"
R"(    dst_q[offset] = q_block.x;
)"
R"(    dst_q[offset + ne01] = q_block.y;
)"
R"(    dst_q[offset + ne01 * 2] = q_block.z;
)"
R"(    dst_q[offset + ne01 * 3] = q_block.w;
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_restore_block_q4_0_trans4_ns(
)"
R"(    __global uint * src_q,
)"
R"(    __global half * src_d,
)"
R"(    __global struct block_q4_0 * dst0,
)"
R"(    uint ne00,
)"
R"(    uint ne01
)"
R"() {
)"
R"(    uint i00 = get_global_id(1);
)"
R"(    uint i01 = get_global_id(0);
)"
R"(    uint i02 = get_global_id(2);
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
R"(    uint ne00_blk = ne00 / QK4_0;
)"
R"(    uint dst_blk_offset = i00 + i01 * ne00_blk + i02 * ne00_blk * ne01;
)"
R"(    uint src_d_offset = i01 + i00 * ne01 + i02 * ne00_blk * ne01;
)"
R"(
)"
R"(    __global struct block_q4_0 * b = dst0 + dst_blk_offset;
)"
R"(    b->d = src_d[src_d_offset];
)"
R"(
)"
R"(    // collect transposed quantization parts for a block
)"
R"(    uint src_q_offset = i02 * ne00_blk * ne01 * 4 + i00 * ne01 * 4 + i01;
)"
R"(    uint4 q_block;
)"
R"(    q_block.x = src_q[src_q_offset];
)"
R"(    q_block.y = src_q[src_q_offset + ne01];
)"
R"(    q_block.z = src_q[src_q_offset + ne01 * 2];
)"
R"(    q_block.w = src_q[src_q_offset + ne01 * 3];
)"
R"(
)"
R"(    // [dspark 2026-10-13] Same anti-aliasing rewrite as the convert kernel:
)"
R"(    // no private-vector-through-uchar* access (miscompiled by some Adreno
)"
R"(    // compilers, see kernel_convert_block_q4_0_trans4_ns note).
)"
R"(    global uchar * qs_dst = b->qs;
)"
R"(    for (int i = 0; i < QK4_0 / 4; ++i) {
)"
R"(        // post bytes: lo pair byte (values 2i, 2i+1), hi pair byte (values 2i+16, 2i+17)
)"
R"(        uchar x0, x1;
)"
R"(        if (i < 4) {
)"
R"(            x0 = (uchar)((q_block.x >> (i * 8)) & 0xFF);
)"
R"(            x1 = (uchar)((q_block.z >> (i * 8)) & 0xFF);
)"
R"(        } else {
)"
R"(            x0 = (uchar)((q_block.y >> ((i - 4) * 8)) & 0xFF);
)"
R"(            x1 = (uchar)((q_block.w >> ((i - 4) * 8)) & 0xFF);
)"
R"(        }
)"
R"(        // re-shuffle into ggml q4_0 byte order: byte j holds v(j) | v(j+16) << 4
)"
R"(        qs_dst[2*i + 0] = convert_uchar(x0 & 0x0F) | convert_uchar((x1 & 0x0F) << 4);
)"
R"(        qs_dst[2*i + 1] = convert_uchar((x0 & 0xF0) >> 4) | convert_uchar(x1 & 0xF0);
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(//------------------------------------------------------------------------------
)"
R"(// kernel_convert_block_q4_1
)"
R"(// Convert the block_q4_1 format to 2 separate arrays (AOS -> SOA).
)"
R"(// This kernel does not deshuffle the bits.
)"
R"(//------------------------------------------------------------------------------
)"
R"(kernel void kernel_convert_block_q4_1(
)"
R"(    global struct block_q4_1 * src0,
)"
R"(    global uchar * dst_q,
)"
R"(    global half  * dst_d,
)"
R"(    global half  * dst_m
)"
R"() {
)"
R"(    global struct block_q4_1 * b = (global struct block_q4_1 *) src0 + get_global_id(0);
)"
R"(    global uchar * q = (global uchar *) dst_q + QK4_1/2*get_global_id(0);
)"
R"(    global half  * d = (global half *) dst_d + get_global_id(0);
)"
R"(    global half  * m = (global half *) dst_m + get_global_id(0);
)"
R"(
)"
R"(    *d = b->d;
)"
R"(    *m = b->m;
)"
R"(
)"
R"(    for (int i = 0; i < QK4_1/2; ++i) {
)"
R"(        q[i] = b->qs[i];
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_restore_block_q4_1(
)"
R"(    global uchar * src_q,
)"
R"(    global half  * src_d,
)"
R"(    global half  * src_m,
)"
R"(    global struct block_q4_1 * dst
)"
R"() {
)"
R"(    global struct block_q4_1 * b = (global struct block_q4_1 *) dst + get_global_id(0);
)"
R"(    global uchar * q = (global uchar *) src_q + QK4_1/2*get_global_id(0);
)"
R"(    global half  * d = (global half *) src_d + get_global_id(0);
)"
R"(    global half  * m = (global half *) src_m + get_global_id(0);
)"
R"(
)"
R"(    b->d = *d;
)"
R"(    b->m = *m;
)"
R"(    for (int i = 0; i < QK4_1/2; ++i) {
)"
R"(        b->qs[i] = q[i];
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_convert_block_q4_1_noshuffle(
)"
R"(    global struct block_q4_1 * src0,
)"
R"(    global uchar * dst_q,
)"
R"(    global half  * dst_d,
)"
R"(    global half  * dst_m
)"
R"() {
)"
R"(    global struct block_q4_1 * b = (global struct block_q4_1 *) src0 + get_global_id(0);
)"
R"(    global uchar * q = (global uchar *) dst_q + QK4_1/2*get_global_id(0);
)"
R"(    global half  * d = (global half *) dst_d + get_global_id(0);
)"
R"(    global half  * m = (global half *) dst_m + get_global_id(0);
)"
R"(
)"
R"(    *d = b->d;
)"
R"(    *m = b->m;
)"
R"(    for (int i = 0; i < QK4_1/4; ++i) {
)"
R"(        uchar x0 = b->qs[2*i + 0];
)"
R"(        uchar x1 = b->qs[2*i + 1];
)"
R"(
)"
R"(        q[i + 0      ] = convert_uchar(x0 & 0x0F) | convert_uchar((x1 & 0x0F) << 4);
)"
R"(        q[i + QK4_1/4] = convert_uchar((x0 & 0xF0) >> 4) | convert_uchar(x1 & 0xF0);
)"
R"(
)"
R"(#if defined(ADRENO_GPU) && !defined(GGML_NO_ADRENO_PRINTF_HACK)
)"
R"(        if (get_global_id(0) == 65536*4096) {
)"
R"(            printf("%04x - %02x\n", *(global ushort*)d, ((x0 & 0xF0) >> 4) | (x1 & 0xF0));
)"
R"(        }
)"
R"(#endif
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_restore_block_q4_1_noshuffle(
)"
R"(    global uchar * src_q,
)"
R"(    global half  * src_d,
)"
R"(    global half  * src_m,
)"
R"(    global struct block_q4_1 * dst,
)"
R"(    uchar mask_0F,
)"
R"(    uchar mask_F0
)"
R"() {
)"
R"(    global struct block_q4_1 * b = (global struct block_q4_1 *) dst + get_global_id(0);
)"
R"(    global uchar * q = (global uchar *) src_q + QK4_1/2*get_global_id(0);
)"
R"(    global half  * d = (global half *) src_d + get_global_id(0);
)"
R"(    global half  * m = (global half *) src_m + get_global_id(0);
)"
R"(
)"
R"(    b->d = *d;
)"
R"(    b->m = *m;
)"
R"(    for (int i = 0; i < QK4_1/4; ++i) {
)"
R"(        uchar x0 = q[i + 0      ] ;
)"
R"(        uchar x1 = q[i + QK4_1/4];
)"
R"(
)"
R"(        b->qs[2*i + 0] = convert_uchar((x0 & mask_0F) | ((x1 & mask_0F) << 4));
)"
R"(        b->qs[2*i + 1] = convert_uchar(((x0 & mask_F0) >> 4) | (x1 & mask_F0));
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_convert_block_q4_1_trans4_ns(
)"
R"(    __global struct block_q4_1 * src0,
)"
R"(    __global uint * dst_q,
)"
R"(    __global half * dst_d,
)"
R"(    __global half * dst_m,
)"
R"(    uint ne00,
)"
R"(    uint ne01
)"
R"() {
)"
R"(    uint i00 = get_global_id(1);
)"
R"(    uint i01 = get_global_id(0);
)"
R"(    uint i02 = get_global_id(2);
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
R"(    uint ne00_blk = ne00 / QK4_1;
)"
R"(    uint src_blk_offset = i00 + i01 * ne00_blk + i02 * ne00_blk * ne01;
)"
R"(    uint dst_blk_offset = i01 + i00 * ne01 + i02 * ne00_blk * ne01;
)"
R"(
)"
R"(    global struct block_q4_1 * b = src0 + src_blk_offset;
)"
R"(    dst_d[dst_blk_offset] = b->d;
)"
R"(    dst_m[dst_blk_offset] = b->m;
)"
R"(
)"
R"(    // extract quantization and unshuffle
)"
R"(    ushort8 pre_block = ((global ushort8 *)(&(b->qs[0])))[0];
)"
R"(
)"
R"(    ushort8 post_block = (ushort8)(0);
)"
R"(
)"
R"(    uchar * pre_block_ptr = (uchar *)(&pre_block);
)"
R"(    uchar * post_block_ptr = (uchar *)(&post_block);
)"
R"(
)"
R"(    for (int i = 0; i < QK4_1 / 4; ++i) {
)"
R"(        uchar x0 = pre_block_ptr[2*i + 0];
)"
R"(        uchar x1 = pre_block_ptr[2*i + 1];
)"
R"(
)"
R"(        post_block_ptr[i + 0        ] = convert_uchar(x0 & 0x0F) | convert_uchar((x1 & 0x0F) << 4);
)"
R"(        post_block_ptr[i + QK4_1 / 4] = convert_uchar((x0 & 0xF0) >> 4) | convert_uchar(x1 & 0xF0);
)"
R"(    }
)"
R"(
)"
R"(    uint4 q_block = as_uint4(post_block);
)"
R"(
)"
R"(    uint offset = i02 * ne00_blk * ne01 * 4 + i00 * ne01 * 4 + i01;
)"
R"(    dst_q[offset] = q_block.x;
)"
R"(    dst_q[offset + ne01] = q_block.y;
)"
R"(    dst_q[offset + ne01 * 2] = q_block.z;
)"
R"(    dst_q[offset + ne01 * 3] = q_block.w;
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_restore_block_q4_1_trans4_ns(
)"
R"(    __global uint * src_q,
)"
R"(    __global half * src_d,
)"
R"(    __global half * src_m,
)"
R"(    __global struct block_q4_1 * dst0,
)"
R"(    uint ne00,
)"
R"(    uint ne01
)"
R"() {
)"
R"(    int i00 = get_global_id(1);
)"
R"(    uint i01 = get_global_id(0);
)"
R"(    uint i02 = get_global_id(2);
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
R"(    uint ne00_blk = ne00 / QK4_1;
)"
R"(    uint dst_blk_offset = i00 + i01 * ne00_blk + i02 * ne00_blk * ne01;
)"
R"(    uint src_dm_offset = i01 + i00 * ne01 + i02 * ne00_blk * ne01;
)"
R"(
)"
R"(    __global struct block_q4_1 * b = dst0 + dst_blk_offset;
)"
R"(    b->d = src_d[src_dm_offset];
)"
R"(    b->m = src_m[src_dm_offset];
)"
R"(
)"
R"(    // collect transposed quantization parts for a block
)"
R"(    uint src_q_offset = i02 * ne00_blk * ne01 * 4 + i00 * ne01 * 4 + i01;
)"
R"(    uint4 q_block;
)"
R"(    q_block.x = src_q[src_q_offset];
)"
R"(    q_block.y = src_q[src_q_offset + ne01];
)"
R"(    q_block.z = src_q[src_q_offset + ne01 * 2];
)"
R"(    q_block.w = src_q[src_q_offset + ne01 * 3];
)"
R"(
)"
R"(    // [dspark 2026-10-13] Same anti-aliasing rewrite as the convert kernel:
)"
R"(    // no private-vector-through-uchar* access (miscompiled by some Adreno
)"
R"(    // compilers, see kernel_convert_block_q4_0_trans4_ns note).
)"
R"(    global uchar * qs_dst = b->qs;
)"
R"(    for (int i = 0; i < QK4_0 / 4; ++i) {
)"
R"(        // post bytes: lo pair byte (values 2i, 2i+1), hi pair byte (values 2i+16, 2i+17)
)"
R"(        uchar x0, x1;
)"
R"(        if (i < 4) {
)"
R"(            x0 = (uchar)((q_block.x >> (i * 8)) & 0xFF);
)"
R"(            x1 = (uchar)((q_block.z >> (i * 8)) & 0xFF);
)"
R"(        } else {
)"
R"(            x0 = (uchar)((q_block.y >> ((i - 4) * 8)) & 0xFF);
)"
R"(            x1 = (uchar)((q_block.w >> ((i - 4) * 8)) & 0xFF);
)"
R"(        }
)"
R"(        // re-shuffle into ggml q4_0 byte order: byte j holds v(j) | v(j+16) << 4
)"
R"(        qs_dst[2*i + 0] = convert_uchar(x0 & 0x0F) | convert_uchar((x1 & 0x0F) << 4);
)"
R"(        qs_dst[2*i + 1] = convert_uchar((x0 & 0xF0) >> 4) | convert_uchar(x1 & 0xF0);
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(//------------------------------------------------------------------------------
)"
R"(// kernel_convert_block_q5_0
)"
R"(// Convert the block_q5_0 format to 3 separate arrays (AOS -> SOA).
)"
R"(// This kernel does not deshuffle the bits.
)"
R"(//------------------------------------------------------------------------------
)"
R"(kernel void kernel_convert_block_q5_0(
)"
R"(    global struct block_q5_0 * src0,
)"
R"(    global uchar * dst_qs,
)"
R"(    global uint  * dst_qh,
)"
R"(    global half  * dst_d,
)"
R"(    ulong n_blk
)"
R"() {
)"
R"(    if (get_global_id(0) >= n_blk) {
)"
R"(        return;
)"
R"(    }
)"
R"(
)"
R"(    global struct block_q5_0 * b = (global struct block_q5_0 *) src0 + get_global_id(0);
)"
R"(    global uchar * qs = (global uchar *) dst_qs + (QK5_0/2)*get_global_id(0);
)"
R"(    global uint  * qh = (global uint  *) dst_qh + get_global_id(0);
)"
R"(    global half  * d  = (global half  *) dst_d  + get_global_id(0);
)"
R"(
)"
R"(    *d = b->d;
)"
R"(    *qh = *((global uint *)(b->qh));
)"
R"(
)"
R"(    for (int i = 0; i < QK5_0/2; ++i) {
)"
R"(        qs[i] = b->qs[i];
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_restore_block_q5_0(
)"
R"(    global uchar * src_qs,
)"
R"(    global uint  * src_qh,
)"
R"(    global half  * src_d,
)"
R"(    global struct block_q5_0 * dst
)"
R"() {
)"
R"(    global struct block_q5_0 * b = (global struct block_q5_0 *) dst + get_global_id(0);
)"
R"(    global uchar * qs = (global uchar *) src_qs + (QK5_0/2)*get_global_id(0);
)"
R"(    global uint  * qh = (global uint  *) src_qh + get_global_id(0);
)"
R"(    global half  * d  = (global half  *) src_d  + get_global_id(0);
)"
R"(
)"
R"(    b->d = *d;
)"
R"(    *((global uint *)(b->qh)) = *qh;
)"
R"(    for (int i = 0; i < QK5_0/2; ++i) {
)"
R"(        b->qs[i] = qs[i];
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_convert_block_q5_0_noshuffle(
)"
R"(    global struct block_q5_0 * src0,
)"
R"(    global uchar * dst_q,
)"
R"(    global uint  * dst_qh,
)"
R"(    global half  * dst_d
)"
R"() {
)"
R"(    global struct block_q5_0 * b = (global struct block_q5_0 *) src0 + get_global_id(0);
)"
R"(    global uchar * q  = (global uchar *) dst_q + QK5_0/2*get_global_id(0);
)"
R"(    global uint  * qh = (global uint  *) dst_qh + get_global_id(0);
)"
R"(    global half  * d  = (global half  *) dst_d  + get_global_id(0);
)"
R"(
)"
R"(    *d = b->d;
)"
R"(    *qh = *((global uint *)(b->qh));
)"
R"(
)"
R"(    for (int i = 0; i < QK5_0/4; ++i) {
)"
R"(        uchar x0 = b->qs[2*i + 0];
)"
R"(        uchar x1 = b->qs[2*i + 1];
)"
R"(
)"
R"(        q[i + 0      ] = convert_uchar(x0 & 0x0F) | convert_uchar((x1 & 0x0F) << 4);
)"
R"(        q[i + QK5_0/4] = convert_uchar((x0 & 0xF0) >> 4) | convert_uchar(x1 & 0xF0);
)"
R"(
)"
R"(#if defined(ADRENO_GPU) && !defined(GGML_NO_ADRENO_PRINTF_HACK)
)"
R"(        if (get_global_id(0) == 65536*4096) {
)"
R"(            printf("%04x - %02x\n", *(global ushort*)d, ((x0 & 0xF0) >> 4) | (x1 & 0xF0));
)"
R"(        }
)"
R"(#endif
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_restore_block_q5_0_noshuffle(
)"
R"(    global uchar * src_q,
)"
R"(    global uint  * src_qh,
)"
R"(    global half  * src_d,
)"
R"(    global struct block_q5_0 * dst,
)"
R"(    uchar mask_0F,
)"
R"(    uchar mask_F0
)"
R"() {
)"
R"(    global struct block_q5_0 * b = (global struct block_q5_0 *) dst + get_global_id(0);
)"
R"(    global uchar * q  = (global uchar *) src_q + QK5_0/2*get_global_id(0);
)"
R"(    global uint  * qh = (global uint  *) src_qh + get_global_id(0);
)"
R"(    global half  * d  = (global half  *) src_d  + get_global_id(0);
)"
R"(
)"
R"(    b->d = *d;
)"
R"(    *((global uint *)(b->qh)) = *qh;
)"
R"(
)"
R"(    for (int i = 0; i < QK5_0/4; ++i) {
)"
R"(        uchar x0 = q[i + 0      ];
)"
R"(        uchar x1 = q[i + QK5_0/4];
)"
R"(
)"
R"(        b->qs[2*i + 0] = convert_uchar((x0 & mask_0F) | ((x1 & mask_0F) << 4));
)"
R"(        b->qs[2*i + 1] = convert_uchar(((x0 & mask_F0) >> 4) | (x1 & mask_F0));
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_convert_block_q5_0_trans4_ns(
)"
R"(    __global struct block_q5_0 * src0,
)"
R"(    __global uint * dst_qs,
)"
R"(    __global uint * dst_qh,
)"
R"(    __global half * dst_d,
)"
R"(    uint ne00,
)"
R"(    uint ne01
)"
R"() {
)"
R"(    uint i00 = get_global_id(1);
)"
R"(    uint i01 = get_global_id(0);
)"
R"(    uint i02 = get_global_id(2);
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
R"(    uint ne00_blk = ne00 / QK5_0;
)"
R"(    uint src_blk_offset = i00 + i01 * ne00_blk + i02 * ne00_blk * ne01;
)"
R"(    uint dst_blk_offset = i01 + i00 * ne01 + i02 * ne00_blk * ne01;
)"
R"(
)"
R"(    global struct block_q5_0 * b = src0 + src_blk_offset;
)"
R"(    dst_d[dst_blk_offset] = b->d;
)"
R"(
)"
R"(    dst_qh[dst_blk_offset] = ((global uint *)(&(b->qh[0])))[0];
)"
R"(
)"
R"(    // extract quantization and unshuffle
)"
R"(    ushort8 pre_block = ((global ushort8 *)(&(b->qs[0])))[0];
)"
R"(    ushort8 post_block = (ushort8)(0);
)"
R"(
)"
R"(    uchar * pre_block_ptr = (uchar *)(&pre_block);
)"
R"(    uchar * post_block_ptr = (uchar *)(&post_block);
)"
R"(
)"
R"(    for (int i = 0; i < QK5_0 / 4; ++i) {
)"
R"(        uchar x0 = pre_block_ptr[2*i + 0];
)"
R"(        uchar x1 = pre_block_ptr[2*i + 1];
)"
R"(
)"
R"(        post_block_ptr[i + 0        ] = convert_uchar(x0 & 0x0F) | convert_uchar((x1 & 0x0F) << 4);
)"
R"(        post_block_ptr[i + QK5_0 / 4] = convert_uchar((x0 & 0xF0) >> 4) | convert_uchar(x1 & 0xF0);
)"
R"(    }
)"
R"(
)"
R"(    uint4 q_block = as_uint4(post_block);
)"
R"(
)"
R"(    uint offset = i02 * ne00_blk * ne01 * 4 + i00 * ne01 * 4 + i01;
)"
R"(    dst_qs[offset] = q_block.x;
)"
R"(    dst_qs[offset + ne01] = q_block.y;
)"
R"(    dst_qs[offset + ne01 * 2] = q_block.z;
)"
R"(    dst_qs[offset + ne01 * 3] = q_block.w;
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_restore_block_q5_0_trans4_ns(
)"
R"(    __global uint * src_qs,
)"
R"(    __global uint * src_qh,
)"
R"(    __global half * src_d,
)"
R"(    __global struct block_q5_0 * dst0,
)"
R"(    uint ne00,
)"
R"(    uint ne01
)"
R"() {
)"
R"(    int i00 = get_global_id(1);
)"
R"(    uint i01 = get_global_id(0);
)"
R"(    uint i02 = get_global_id(2);
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
R"(    uint ne00_blk = ne00 / QK5_0;
)"
R"(    uint dst_blk_offset = i00 + i01 * ne00_blk + i02 * ne00_blk * ne01;
)"
R"(    uint src_blk_offset = i01 + i00 * ne01 + i02 * ne00_blk * ne01;
)"
R"(
)"
R"(    __global struct block_q5_0 * b = dst0 + dst_blk_offset;
)"
R"(    b->d = src_d[src_blk_offset];
)"
R"(
)"
R"(    ((__global uint *)(&(b->qh[0])))[0] = src_qh[src_blk_offset];
)"
R"(
)"
R"(    // collect transposed quantization parts for a block
)"
R"(    uint src_q_offset = i02 * ne00_blk * ne01 * 4 + i00 * ne01 * 4 + i01;
)"
R"(    uint4 q_block;
)"
R"(    q_block.x = src_qs[src_q_offset];
)"
R"(    q_block.y = src_qs[src_q_offset + ne01];
)"
R"(    q_block.z = src_qs[src_q_offset + ne01 * 2];
)"
R"(    q_block.w = src_qs[src_q_offset + ne01 * 3];
)"
R"(
)"
R"(    ushort8 post_block = as_ushort8(q_block);
)"
R"(    ushort8 pre_block = (ushort8)(0);
)"
R"(
)"
R"(    uchar * pre_block_ptr = (uchar *)(&pre_block);
)"
R"(    uchar * post_block_ptr = (uchar *)(&post_block);
)"
R"(
)"
R"(    for (int i = 0; i < QK5_0 / 4; ++i) {
)"
R"(        uchar x0 = post_block_ptr[i + 0];
)"
R"(        uchar x1 = post_block_ptr[i + QK5_0 / 4];
)"
R"(
)"
R"(        pre_block_ptr[2 * i + 0] = convert_uchar(x0 & 0x0F) | convert_uchar((x1 & 0x0F) << 4);
)"
R"(        pre_block_ptr[2 * i + 1] = convert_uchar((x0 & 0xF0) >> 4) | convert_uchar(x1 & 0xF0);
)"
R"(    }
)"
R"(
)"
R"(    ((__global ushort8 *)(&(b->qs[0])))[0] = pre_block;
)"
R"(}
)"
R"(
)"
R"(//------------------------------------------------------------------------------
)"
R"(// kernel_convert_block_q5_1
)"
R"(// Convert the block_q5_1 format to 4 separate arrays (AOS -> SOA).
)"
R"(// This kernel does not deshuffle the bits.
)"
R"(//------------------------------------------------------------------------------
)"
R"(kernel void kernel_convert_block_q5_1(
)"
R"(    global struct block_q5_1 * src0,
)"
R"(    global uchar * dst_qs,
)"
R"(    global uint  * dst_qh,
)"
R"(    global half  * dst_d,
)"
R"(    global half  * dst_m,
)"
R"(    ulong n_blk
)"
R"() {
)"
R"(    if (get_global_id(0) >= n_blk) {
)"
R"(        return;
)"
R"(    }
)"
R"(
)"
R"(    global struct block_q5_1 * b = (global struct block_q5_1 *) src0 + get_global_id(0);
)"
R"(    global uchar * qs = (global uchar *) dst_qs + (QK5_1/2)*get_global_id(0);
)"
R"(    global uint  * qh = (global uint  *) dst_qh + get_global_id(0);
)"
R"(    global half  * d  = (global half  *) dst_d  + get_global_id(0);
)"
R"(    global half  * m  = (global half  *) dst_m  + get_global_id(0);
)"
R"(
)"
R"(    *d = b->d;
)"
R"(    *m = b->m;
)"
R"(    *qh = *((global uint *)(b->qh));
)"
R"(
)"
R"(    for (int i = 0; i < QK5_1/2; ++i) {
)"
R"(        qs[i] = b->qs[i];
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_restore_block_q5_1(
)"
R"(    global uchar * src_qs,
)"
R"(    global uint  * src_qh,
)"
R"(    global half  * src_d,
)"
R"(    global half  * src_m,
)"
R"(    global struct block_q5_1 * dst
)"
R"() {
)"
R"(    global struct block_q5_1 * b = (global struct block_q5_1 *) dst + get_global_id(0);
)"
R"(    global uchar * qs = (global uchar *) src_qs + (QK5_1/2)*get_global_id(0);
)"
R"(    global uint  * qh = (global uint  *) src_qh + get_global_id(0);
)"
R"(    global half  * d  = (global half  *) src_d  + get_global_id(0);
)"
R"(    global half  * m  = (global half  *) src_m  + get_global_id(0);
)"
R"(
)"
R"(    b->d = *d;
)"
R"(    b->m = *m;
)"
R"(    *((global uint *)(b->qh)) = *qh;
)"
R"(    for (int i = 0; i < QK5_1/2; ++i) {
)"
R"(        b->qs[i] = qs[i];
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_convert_block_q5_1_noshuffle(
)"
R"(    global struct block_q5_1 * src0,
)"
R"(    global uchar * dst_q,
)"
R"(    global uint  * dst_qh,
)"
R"(    global half  * dst_d,
)"
R"(    global half  * dst_m
)"
R"() {
)"
R"(    global struct block_q5_1 * b = (global struct block_q5_1 *) src0 + get_global_id(0);
)"
R"(    global uchar * q  = (global uchar *) dst_q + QK5_1/2*get_global_id(0);
)"
R"(    global uint  * qh = (global uint  *) dst_qh + get_global_id(0);
)"
R"(    global half  * d  = (global half  *) dst_d  + get_global_id(0);
)"
R"(    global half  * m  = (global half  *) dst_m  + get_global_id(0);
)"
R"(
)"
R"(    *d = b->d;
)"
R"(    *m = b->m;
)"
R"(    *qh = *((global uint *)(b->qh));
)"
R"(
)"
R"(    for (int i = 0; i < QK5_1/4; ++i) {
)"
R"(        uchar x0 = b->qs[2*i + 0];
)"
R"(        uchar x1 = b->qs[2*i + 1];
)"
R"(
)"
R"(        q[i + 0      ] = convert_uchar(x0 & 0x0F) | convert_uchar((x1 & 0x0F) << 4);
)"
R"(        q[i + QK5_1/4] = convert_uchar((x0 & 0xF0) >> 4) | convert_uchar(x1 & 0xF0);
)"
R"(
)"
R"(#if defined(ADRENO_GPU) && !defined(GGML_NO_ADRENO_PRINTF_HACK)
)"
R"(        if (get_global_id(0) == 65536*4096) {
)"
R"(            printf("%04x - %02x\n", *(global ushort*)d, ((x0 & 0xF0) >> 4) | (x1 & 0xF0));
)"
R"(        }
)"
R"(#endif
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_restore_block_q5_1_noshuffle(
)"
R"(    global uchar * src_q,
)"
R"(    global uint  * src_qh,
)"
R"(    global half  * src_d,
)"
R"(    global half  * src_m,
)"
R"(    global struct block_q5_1 * dst,
)"
R"(    uchar mask_0F,
)"
R"(    uchar mask_F0
)"
R"() {
)"
R"(    global struct block_q5_1 * b = (global struct block_q5_1 *) dst + get_global_id(0);
)"
R"(    global uchar * q  = (global uchar *) src_q + QK5_1/2*get_global_id(0);
)"
R"(    global uint  * qh = (global uint  *) src_qh + get_global_id(0);
)"
R"(    global half  * d  = (global half  *) src_d  + get_global_id(0);
)"
R"(    global half  * m  = (global half  *) src_m  + get_global_id(0);
)"
R"(
)"
R"(    b->d = *d;
)"
R"(    b->m = *m;
)"
R"(    *((global uint *)(b->qh)) = *qh;
)"
R"(
)"
R"(    for (int i = 0; i < QK5_1/4; ++i) {
)"
R"(        uchar x0 = q[i + 0      ];
)"
R"(        uchar x1 = q[i + QK5_1/4];
)"
R"(
)"
R"(        b->qs[2*i + 0] = convert_uchar((x0 & mask_0F) | ((x1 & mask_0F) << 4));
)"
R"(        b->qs[2*i + 1] = convert_uchar(((x0 & mask_F0) >> 4) | (x1 & mask_F0));
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_convert_block_q5_1_trans4_ns(
)"
R"(    __global struct block_q5_1 * src0,
)"
R"(    __global uint * dst_qs,
)"
R"(    __global uint * dst_qh,
)"
R"(    __global half * dst_d,
)"
R"(    __global half * dst_m,
)"
R"(    uint ne00,
)"
R"(    uint ne01
)"
R"() {
)"
R"(    uint i00 = get_global_id(1);
)"
R"(    uint i01 = get_global_id(0);
)"
R"(    uint i02 = get_global_id(2);
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
R"(    uint ne00_blk = ne00 / QK5_1;
)"
R"(    uint src_blk_offset = i00 + i01 * ne00_blk + i02 * ne00_blk * ne01;
)"
R"(    uint dst_blk_offset = i01 + i00 * ne01 + i02 * ne00_blk * ne01;
)"
R"(
)"
R"(    global struct block_q5_1 * b = src0 + src_blk_offset;
)"
R"(    dst_d[dst_blk_offset] = b->d;
)"
R"(    dst_m[dst_blk_offset] = b->m;
)"
R"(
)"
R"(    dst_qh[dst_blk_offset] = ((global uint *)(&(b->qh[0])))[0];
)"
R"(
)"
R"(    // extract quantization and unshuffle
)"
R"(    ushort8 pre_block = ((global ushort8 *)(&(b->qs[0])))[0];
)"
R"(    ushort8 post_block = (ushort8)(0);
)"
R"(
)"
R"(    uchar * pre_block_ptr = (uchar *)(&pre_block);
)"
R"(    uchar * post_block_ptr = (uchar *)(&post_block);
)"
R"(
)"
R"(    for (int i = 0; i < QK5_1 / 4; ++i) {
)"
R"(        uchar x0 = pre_block_ptr[2*i + 0];
)"
R"(        uchar x1 = pre_block_ptr[2*i + 1];
)"
R"(
)"
R"(        post_block_ptr[i + 0        ] = convert_uchar(x0 & 0x0F) | convert_uchar((x1 & 0x0F) << 4);
)"
R"(        post_block_ptr[i + QK5_1 / 4] = convert_uchar((x0 & 0xF0) >> 4) | convert_uchar(x1 & 0xF0);
)"
R"(    }
)"
R"(
)"
R"(    uint4 q_block = as_uint4(post_block);
)"
R"(
)"
R"(    uint offset = i02 * ne00_blk * ne01 * 4 + i00 * ne01 * 4 + i01;
)"
R"(    dst_qs[offset] = q_block.x;
)"
R"(    dst_qs[offset + ne01] = q_block.y;
)"
R"(    dst_qs[offset + ne01 * 2] = q_block.z;
)"
R"(    dst_qs[offset + ne01 * 3] = q_block.w;
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_restore_block_q5_1_trans4_ns(
)"
R"(    __global uint * src_qs,
)"
R"(    __global uint * src_qh,
)"
R"(    __global half * src_d,
)"
R"(    __global half * src_m,
)"
R"(    __global struct block_q5_1 * dst0,
)"
R"(    uint ne00,
)"
R"(    uint ne01
)"
R"() {
)"
R"(    int i00 = get_global_id(1);
)"
R"(    uint i01 = get_global_id(0);
)"
R"(    uint i02 = get_global_id(2);
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
R"(    uint ne00_blk = ne00 / QK5_1;
)"
R"(    uint dst_blk_offset = i00 + i01 * ne00_blk + i02 * ne00_blk * ne01;
)"
R"(    uint src_blk_offset = i01 + i00 * ne01 + i02 * ne00_blk * ne01;
)"
R"(
)"
R"(    __global struct block_q5_1 * b = dst0 + dst_blk_offset;
)"
R"(    b->d = src_d[src_blk_offset];
)"
R"(    b->m = src_m[src_blk_offset];
)"
R"(
)"
R"(    ((__global uint *)(&(b->qh[0])))[0] = src_qh[src_blk_offset];
)"
R"(
)"
R"(    // collect transposed quantization parts for a block
)"
R"(    uint src_q_offset = i02 * ne00_blk * ne01 * 4 + i00 * ne01 * 4 + i01;
)"
R"(    uint4 q_block;
)"
R"(    q_block.x = src_qs[src_q_offset];
)"
R"(    q_block.y = src_qs[src_q_offset + ne01];
)"
R"(    q_block.z = src_qs[src_q_offset + ne01 * 2];
)"
R"(    q_block.w = src_qs[src_q_offset + ne01 * 3];
)"
R"(
)"
R"(    ushort8 post_block = as_ushort8(q_block);
)"
R"(    ushort8 pre_block = (ushort8)(0);
)"
R"(
)"
R"(    uchar * pre_block_ptr = (uchar *)(&pre_block);
)"
R"(    uchar * post_block_ptr = (uchar *)(&post_block);
)"
R"(
)"
R"(    for (int i = 0; i < QK5_1 / 4; ++i) {
)"
R"(        uchar x0 = post_block_ptr[i + 0];
)"
R"(        uchar x1 = post_block_ptr[i + QK5_1 / 4];
)"
R"(
)"
R"(        pre_block_ptr[2 * i + 0] = convert_uchar(x0 & 0x0F) | convert_uchar((x1 & 0x0F) << 4);
)"
R"(        pre_block_ptr[2 * i + 1] = convert_uchar((x0 & 0xF0) >> 4) | convert_uchar(x1 & 0xF0);
)"
R"(    }
)"
R"(    ((__global ushort8 *)(&(b->qs[0])))[0] = pre_block;
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_convert_block_q4_k_trans4_ns(
)"
R"(    __global struct block_q4_K * src0,
)"
R"(    __global uint  * dst_q,
)"
R"(    __global half  * dst_d,
)"
R"(    __global half  * dst_dm,
)"
R"(    __global uchar * dst_s,
)"
R"(    uint ne00,
)"
R"(    uint ne01,
)"
R"(    uchar mask_0F,
)"
R"(    uchar mask_F0
)"
R"() {
)"
R"(    uint i00 = get_global_id(1);
)"
R"(    uint i01 = get_global_id(0);
)"
R"(    uint i02 = get_global_id(2);
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
R"(    uint ne00_blk = ne00 / QK_K;
)"
R"(    uint src_blk_offset = i00 + i01 * ne00_blk + i02 * ne00_blk * ne01;
)"
R"(    uint dst_blk_offset = i01 + i00 * ne01     + i02 * ne00_blk * ne01;
)"
R"(
)"
R"(    __global struct block_q4_K * b = src0 + src_blk_offset;
)"
R"(
)"
R"(    dst_d [dst_blk_offset] = b->d;
)"
R"(    dst_dm[dst_blk_offset] = b->dm;
)"
R"(
)"
R"(    // [dspark 2026-10-13] No private-vector-through-uchar* aliasing here
)"
R"(    // (miscompiled by some Adreno compilers, see
)"
R"(    // kernel_convert_block_q4_0_trans4_ns note). Plain scalar word array,
)"
R"(    // fully unrolled so all accesses resolve to registers.
)"
R"(    uint qv_w[32];
)"
R"(    #pragma unroll
)"
R"(    for (int w = 0; w < 32; ++w) {
)"
R"(        qv_w[w] = 0;
)"
R"(    }
)"
R"(    #pragma unroll
)"
R"(    for (int i = 0; i < QK_K / 64; ++i) {
)"
R"(        #pragma unroll
)"
R"(        for (int j = 0; j < 16; ++j) {
)"
R"(            uchar x0 = b->q[i*32 + 2*j];
)"
R"(            uchar x1 = b->q[i*32 + 2*j + 1];
)"
R"(
)"
R"(            uchar lo = convert_uchar(x0 & mask_0F) | convert_uchar((x1 & mask_0F) << 4);
)"
R"(            uchar hi = convert_uchar((x0 & mask_F0) >> 4) | convert_uchar(x1 & mask_F0);
)"
R"(
)"
R"(            qv_w[i*8 + (j >> 2)]     |= ((uint)lo) << ((j & 3) * 8);
)"
R"(            qv_w[i*8 + 4 + (j >> 2)] |= ((uint)hi) << ((j & 3) * 8);
)"
R"(        }
)"
R"(    }
)"
R"(
)"
R"(    uint base = i02 * ne00_blk * ne01 * 32 + i00 * ne01 * 32 + i01;
)"
R"(    #pragma unroll
)"
R"(    for (int p = 0; p < 8; ++p) {
)"
R"(        dst_q[base + (p * 4 + 0) * ne01] = qv_w[p*4 + 0];
)"
R"(        dst_q[base + (p * 4 + 1) * ne01] = qv_w[p*4 + 1];
)"
R"(        dst_q[base + (p * 4 + 2) * ne01] = qv_w[p*4 + 2];
)"
R"(        dst_q[base + (p * 4 + 3) * ne01] = qv_w[p*4 + 3];
)"
R"(    }
)"
R"(
)"
R"(    __global uchar * s_dst = dst_s + (i02 * ne01 + i01) * ne00_blk * K_SCALE_SIZE + i00 * K_SCALE_SIZE;
)"
R"(    #pragma unroll
)"
R"(    for (int i = 0; i < K_SCALE_SIZE; ++i) {
)"
R"(        s_dst[i] = b->s[i];
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_restore_block_q4_k_trans4_ns(
)"
R"(    __global uint  * src_q,
)"
R"(    __global half  * src_d,
)"
R"(    __global half  * src_dm,
)"
R"(    __global uchar * src_s,
)"
R"(    __global struct block_q4_K * dst0,
)"
R"(    uint ne00,
)"
R"(    uint ne01,
)"
R"(    uchar mask_0F,
)"
R"(    uchar mask_F0
)"
R"() {
)"
R"(    uint i00 = get_global_id(1);  // block index along K
)"
R"(    uint i01 = get_global_id(0);  // row index
)"
R"(    uint i02 = get_global_id(2);  // batch index
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
R"(    uint ne00_blk = ne00 / QK_K;
)"
R"(
)"
R"(    uint src_blk_offset = i01 + i00 * ne01 + i02 * ne00_blk * ne01;
)"
R"(    uint dst_blk_offset = i00 + i01 * ne00_blk + i02 * ne00_blk * ne01;
)"
R"(
)"
R"(    __global struct block_q4_K * b = dst0 + dst_blk_offset;
)"
R"(
)"
R"(    b->d  = src_d[src_blk_offset];
)"
R"(    b->dm = src_dm[src_blk_offset];
)"
R"(
)"
R"(    __global uchar * s_src = src_s + (i02 * ne01 + i01) * ne00_blk * K_SCALE_SIZE + i00 * K_SCALE_SIZE;
)"
R"(    for (int i = 0; i < K_SCALE_SIZE; ++i) {
)"
R"(        b->s[i] = s_src[i];
)"
R"(    }
)"
R"(
)"
R"(    uint base = i02 * ne00_blk * ne01 * 32 + i00 * ne01 * 32 + i01;
)"
R"(
)"
R"(    uint4 qv[8];
)"
R"(    for (int p = 0; p < 8; ++p) {
)"
R"(        qv[p].x = src_q[base + (p * 4 + 0) * ne01];
)"
R"(        qv[p].y = src_q[base + (p * 4 + 1) * ne01];
)"
R"(        qv[p].z = src_q[base + (p * 4 + 2) * ne01];
)"
R"(        qv[p].w = src_q[base + (p * 4 + 3) * ne01];
)"
R"(    }
)"
R"(
)"
R"(    // [dspark 2026-10-13] No private-vector-through-uchar* aliasing here
)"
R"(    // (miscompiled by some Adreno compilers, see
)"
R"(    // kernel_convert_block_q4_0_trans4_ns note). Flatten to a scalar word
)"
R"(    // array (fully unrolled) and read bytes via shifts.
)"
R"(    uint qv_w[32];
)"
R"(    #pragma unroll
)"
R"(    for (int k = 0; k < 8; ++k) {
)"
R"(        qv_w[k*4 + 0] = qv[k].x;
)"
R"(        qv_w[k*4 + 1] = qv[k].y;
)"
R"(        qv_w[k*4 + 2] = qv[k].z;
)"
R"(        qv_w[k*4 + 3] = qv[k].w;
)"
R"(    }
)"
R"(    global uchar * q_dst = b->q;
)"
R"(    #pragma unroll
)"
R"(    for (int i = 0; i < QK_K / 64; ++i) {
)"
R"(        #pragma unroll
)"
R"(        for (int j = 0; j < 16; ++j) {
)"
R"(            uint wl = qv_w[i*8 + (j >> 2)];      // lo byte word
)"
R"(            uint wh = qv_w[i*8 + 4 + (j >> 2)];  // hi byte word (+16 bytes)
)"
R"(            uchar lo = (uchar)((wl >> ((j & 3) * 8)) & 0xFF);
)"
R"(            uchar hi = (uchar)((wh >> ((j & 3) * 8)) & 0xFF);
)"
R"(            q_dst[i*32 + 2*j]     = convert_uchar((lo & mask_0F) | ((hi & mask_0F) << 4));
)"
R"(            q_dst[i*32 + 2*j + 1] = convert_uchar(((lo & mask_F0) >> 4) | (hi & mask_F0));
)"
R"(        }
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(//------------------------------------------------------------------------------
)"
R"(// kernel_convert_block_q4_k_tiled_ns
)"
R"(//
)"
R"(// Tiled-wide layout for the long-vocab q4_K lm_head/embed GEMV (decode path).
)"
R"(// Mirror of kernel_convert_block_q6_k_tiled_ns: recovers each weight's 4-bit
)"
R"(// code in CANONICAL ggml element order (e in [0,256)) and re-packs into 32 uints
)"
R"(// (8 codes/uint), stored TILED by 64 output rows so the matching GEMV
)"
R"(// (gemv_noshuffle_q4_k_f32_tiled) coalesces every weight load. The 12-byte
)"
R"(// packed scale block `s` and d/dm are stored per (row, K-block) tiled; the GEMV
)"
R"(// re-derives the 8 (scale,min) pairs via get_scale_min_k4, exactly like the o4
)"
R"(// kernel. Both ends owned here -> correct by construction vs the reference q4_K
)"
R"(// dequant. Requires ne01 % 64 == 0 (gated host-side). Buffer sizes identical to
)"
R"(// the trans4_ns layout.
)"
R"(//
)"
R"(//   q  uint4 granule g of (row r, K-block sb): idx = ((rt*ne00_blk+sb)*8 + g)*64 + rit
)"
R"(//   s  (12 bytes) of (r, sb):                  idx = (rt*ne00_blk+sb)*64 + rit, *12
)"
R"(//   d/dm (half)  of (r, sb):                   idx = (rt*ne00_blk+sb)*64 + rit
)"
R"(//   where rt = r/64, rit = r%64.
)"
R"(//------------------------------------------------------------------------------
)"
R"(kernel void kernel_convert_block_q4_k_tiled_ns(
)"
R"(    __global struct block_q4_K * src0,
)"
R"(    __global uint  * dst_q,    // 32 uints / superblock (4-bit codes, 8 codes/uint)
)"
R"(    __global half  * dst_d,    // 1 half  / superblock
)"
R"(    __global half  * dst_dm,   // 1 half  / superblock
)"
R"(    __global uchar * dst_s,    // K_SCALE_SIZE (12) bytes / superblock
)"
R"(    uint ne00,
)"
R"(    uint ne01
)"
R"() {
)"
R"(    uint i00 = get_global_id(1);   // K-block index (superblock along ne00)
)"
R"(    uint i01 = get_global_id(0);   // output row index (along ne01)
)"
R"(    uint i02 = get_global_id(2);   // batch
)"
R"(
)"
R"(    uint ne00_blk = ne00 / QK_K;
)"
R"(
)"
R"(    uint src_blk_offset = i00 + i01 * ne00_blk + i02 * ne00_blk * ne01;
)"
R"(    __global struct block_q4_K * b = src0 + src_blk_offset;
)"
R"(
)"
R"(    uint rt  = i01 / 64;
)"
R"(    uint rit = i01 % 64;
)"
R"(    uint tile_blk = (i02 * (ne01 / 64) + rt) * ne00_blk + i00;
)"
R"(
)"
R"(    // --- recover canonical 4-bit codes in e-order, pack 8 codes/uint ---
)"
R"(    uint qw[32] = {0};
)"
R"(    for (uint e = 0; e < 256; ++e) {
)"
R"(        uint g    = e >> 6;           // group 0..3 (q advances 32 bytes/group)
)"
R"(        uint within = e & 63u;
)"
R"(        uint hlf  = within >> 5;      // 0 = low nibble, 1 = high nibble
)"
R"(        uint l    = within & 31u;     // 0..31
)"
R"(        uchar byte = b->q[g * 32u + l];
)"
R"(        uint code = (hlf == 0u) ? (uint)(byte & 0x0F) : (uint)(byte >> 4);
)"
R"(        qw[e >> 3] |= code << ((e & 7u) * 4u);
)"
R"(    }
)"
R"(
)"
R"(    for (uint gr = 0; gr < 8; ++gr) {
)"
R"(        uint base = (tile_blk * 8u + gr) * 64u + rit;   // uint4 index
)"
R"(        dst_q[base * 4u + 0u] = qw[gr * 4u + 0u];
)"
R"(        dst_q[base * 4u + 1u] = qw[gr * 4u + 1u];
)"
R"(        dst_q[base * 4u + 2u] = qw[gr * 4u + 2u];
)"
R"(        dst_q[base * 4u + 3u] = qw[gr * 4u + 3u];
)"
R"(    }
)"
R"(
)"
R"(    // packed scales (12 bytes), tiled per (row, block)
)"
R"(    __global uchar * s_dst = dst_s + (tile_blk * 64u + rit) * K_SCALE_SIZE;
)"
R"(    #pragma unroll
)"
R"(    for (int i = 0; i < K_SCALE_SIZE; ++i) {
)"
R"(        s_dst[i] = b->s[i];
)"
R"(    }
)"
R"(
)"
R"(    dst_d [tile_blk * 64u + rit] = b->d;
)"
R"(    dst_dm[tile_blk * 64u + rit] = b->dm;
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_convert_block_q5_k_trans4_ns(
)"
R"(    __global struct block_q5_K * src0,
)"
R"(    __global uint  * dst_qs,
)"
R"(    __global uint  * dst_qh,
)"
R"(    __global half  * dst_d,
)"
R"(    __global half  * dst_dm,
)"
R"(    __global uchar * dst_s,
)"
R"(    uint ne00,
)"
R"(    uint ne01,
)"
R"(    uchar mask_0F,
)"
R"(    uchar mask_F0
)"
R"() {
)"
R"(    uint i00 = get_global_id(1);
)"
R"(    uint i01 = get_global_id(0);
)"
R"(    uint i02 = get_global_id(2);
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
R"(    uint ne00_blk = ne00 / QK_K;
)"
R"(    uint src_blk_offset = i00 + i01 * ne00_blk + i02 * ne00_blk * ne01;
)"
R"(    uint dst_blk_offset = i01 + i00 * ne01     + i02 * ne00_blk * ne01;
)"
R"(
)"
R"(    __global struct block_q5_K * b = src0 + src_blk_offset;
)"
R"(
)"
R"(    dst_d [dst_blk_offset] = b->d;
)"
R"(    dst_dm[dst_blk_offset] = b->dm;
)"
R"(
)"
R"(    for (int k = 0; k < 8; k++) {
)"
R"(        uchar b0 = 0, b1 = 0, b2 = 0, b3 = 0;
)"
R"(        for (int bit = 0; bit < 8; bit++) {
)"
R"(            b0 |= (uchar)(((b->qh[bit]      >> k) & 1) << bit);
)"
R"(            b1 |= (uchar)(((b->qh[8  + bit] >> k) & 1) << bit);
)"
R"(            b2 |= (uchar)(((b->qh[16 + bit] >> k) & 1) << bit);
)"
R"(            b3 |= (uchar)(((b->qh[24 + bit] >> k) & 1) << bit);
)"
R"(        }
)"
R"(        uint packed = (uint)b0 | ((uint)b1 << 8) | ((uint)b2 << 16) | ((uint)b3 << 24);
)"
R"(        dst_qh[i01 + (i00 * 8 + k) * ne01 + i02 * ne00_blk * 8 * ne01] = packed;
)"
R"(    }
)"
R"(
)"
R"(    uint4 qv[8];
)"
R"(    uchar * qv_bytes = (uchar *)qv;
)"
R"(    for (int i = 0; i < QK_K / 64; ++i) {
)"
R"(        for (int j = 0; j < 16; ++j) {
)"
R"(            uchar x0 = b->qs[i*32 + 2*j];
)"
R"(            uchar x1 = b->qs[i*32 + 2*j + 1];
)"
R"(
)"
R"(            qv_bytes[i*32 + j     ] = convert_uchar(x0 & mask_0F) | convert_uchar((x1 & mask_0F) << 4);
)"
R"(            qv_bytes[i*32 + j + 16] = convert_uchar((x0 & mask_F0) >> 4) | convert_uchar(x1 & mask_F0);
)"
R"(        }
)"
R"(    }
)"
R"(
)"
R"(    uint base = i02 * ne00_blk * ne01 * 32 + i00 * ne01 * 32 + i01;
)"
R"(    #pragma unroll
)"
R"(    for (int p = 0; p < 8; ++p) {
)"
R"(        uint4 v = qv[p];
)"
R"(        dst_qs[base + (p * 4 + 0) * ne01] = v.x;
)"
R"(        dst_qs[base + (p * 4 + 1) * ne01] = v.y;
)"
R"(        dst_qs[base + (p * 4 + 2) * ne01] = v.z;
)"
R"(        dst_qs[base + (p * 4 + 3) * ne01] = v.w;
)"
R"(    }
)"
R"(
)"
R"(    __global uchar * s_dst = dst_s + (i02 * ne01 + i01) * ne00_blk * K_SCALE_SIZE + i00 * K_SCALE_SIZE;
)"
R"(    #pragma unroll
)"
R"(    for (int i = 0; i < K_SCALE_SIZE; ++i) {
)"
R"(        s_dst[i] = b->s[i];
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_restore_block_q5_k_trans4_ns(
)"
R"(    __global uint  * src_qs,
)"
R"(    __global uint  * src_qh,
)"
R"(    __global half  * src_d,
)"
R"(    __global half  * src_dm,
)"
R"(    __global uchar * src_s,
)"
R"(    __global struct block_q5_K * dst0,
)"
R"(    uint ne00,
)"
R"(    uint ne01,
)"
R"(    uchar mask_0F,
)"
R"(    uchar mask_F0
)"
R"() {
)"
R"(    uint i00 = get_global_id(1);  // block index along K
)"
R"(    uint i01 = get_global_id(0);  // row index
)"
R"(    uint i02 = get_global_id(2);  // batch index
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
R"(    uint ne00_blk = ne00 / QK_K;
)"
R"(
)"
R"(    uint src_blk_offset = i01 + i00 * ne01 + i02 * ne00_blk * ne01;
)"
R"(    uint dst_blk_offset = i00 + i01 * ne00_blk + i02 * ne00_blk * ne01;
)"
R"(
)"
R"(    __global struct block_q5_K * b = dst0 + dst_blk_offset;
)"
R"(
)"
R"(    b->d  = src_d[src_blk_offset];
)"
R"(    b->dm = src_dm[src_blk_offset];
)"
R"(
)"
R"(    for (int j = 0; j < 32; j++) b->qh[j] = 0;
)"
R"(    for (int k = 0; k < 8; k++) {
)"
R"(        uint packed = src_qh[i01 + (i00 * 8 + k) * ne01 + i02 * ne00_blk * 8 * ne01];
)"
R"(        uchar b0 = (uchar)(packed & 0xFF);
)"
R"(        uchar b1 = (uchar)((packed >> 8) & 0xFF);
)"
R"(        uchar b2 = (uchar)((packed >> 16) & 0xFF);
)"
R"(        uchar b3 = (uchar)((packed >> 24) & 0xFF);
)"
R"(        for (int bit = 0; bit < 8; bit++) {
)"
R"(            b->qh[bit]      |= (uchar)(((b0 >> bit) & 1) << k);
)"
R"(            b->qh[8  + bit] |= (uchar)(((b1 >> bit) & 1) << k);
)"
R"(            b->qh[16 + bit] |= (uchar)(((b2 >> bit) & 1) << k);
)"
R"(            b->qh[24 + bit] |= (uchar)(((b3 >> bit) & 1) << k);
)"
R"(        }
)"
R"(    }
)"
R"(
)"
R"(    __global uchar * s_src = src_s + (i02 * ne01 + i01) * ne00_blk * K_SCALE_SIZE + i00 * K_SCALE_SIZE;
)"
R"(    for (int i = 0; i < K_SCALE_SIZE; ++i) {
)"
R"(        b->s[i] = s_src[i];
)"
R"(    }
)"
R"(
)"
R"(    uint base = i02 * ne00_blk * ne01 * 32 + i00 * ne01 * 32 + i01;
)"
R"(
)"
R"(    uint4 qv[8];
)"
R"(    for (int p = 0; p < 8; ++p) {
)"
R"(        qv[p].x = src_qs[base + (p * 4 + 0) * ne01];
)"
R"(        qv[p].y = src_qs[base + (p * 4 + 1) * ne01];
)"
R"(        qv[p].z = src_qs[base + (p * 4 + 2) * ne01];
)"
R"(        qv[p].w = src_qs[base + (p * 4 + 3) * ne01];
)"
R"(    }
)"
R"(
)"
R"(    uchar * qv_bytes = (uchar *)qv;
)"
R"(    for (int i = 0; i < QK_K / 64; ++i) {
)"
R"(        for (int j = 0; j < 16; ++j) {
)"
R"(            uchar lo = qv_bytes[i*32 + j];
)"
R"(            uchar hi = qv_bytes[i*32 + j + 16];
)"
R"(            b->qs[i*32 + 2*j]     = convert_uchar((lo & mask_0F) | ((hi & mask_0F) << 4));
)"
R"(            b->qs[i*32 + 2*j + 1] = convert_uchar(((lo & mask_F0) >> 4) | (hi & mask_F0));
)"
R"(        }
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_convert_block_q6_k_trans4_ns(
)"
R"(    __global struct block_q6_K * src0,
)"
R"(    __global uint  * dst_ql,
)"
R"(    __global uint  * dst_qh,
)"
R"(    __global half  * dst_d,
)"
R"(    __global char  * dst_s,
)"
R"(    uint ne00,
)"
R"(    uint ne01,
)"
R"(    uchar mask_0F,
)"
R"(    uchar mask_F0
)"
R"() {
)"
R"(    uint i00 = get_global_id(1);
)"
R"(    uint i01 = get_global_id(0);
)"
R"(    uint i02 = get_global_id(2);
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
R"(    uint ne00_blk = ne00 / QK_K;
)"
R"(
)"
R"(    uint src_blk_offset = i00 + i01 * ne00_blk + i02 * ne00_blk * ne01;
)"
R"(    uint dst_blk_offset = i01 + i00 * ne01     + i02 * ne00_blk * ne01;
)"
R"(
)"
R"(    __global struct block_q6_K * b = src0 + src_blk_offset;
)"
R"(
)"
R"(    dst_d[dst_blk_offset] = b->d;
)"
R"(
)"
R"(    uint4 qlv[8];
)"
R"(    uchar * qlv_bytes = (uchar *)qlv;
)"
R"(    for (int i = 0; i < 2; ++i) {
)"
R"(        for (int j = 0; j < 16; ++j) {
)"
R"(            uchar x0 = b->ql[i*64 + 2*j];
)"
R"(            uchar x1 = b->ql[i*64 + 2*j + 1];
)"
R"(            uchar x2 = b->ql[i*64 + 32 + 2*j];
)"
R"(            uchar x3 = b->ql[i*64 + 32 + 2*j + 1];
)"
R"(            qlv_bytes[i*64 + j     ] = convert_uchar(x0 & mask_0F) | convert_uchar((x1 & mask_0F) << 4);
)"
R"(            qlv_bytes[i*64 + j + 16] = convert_uchar(x2 & mask_0F) | convert_uchar((x3 & mask_0F) << 4);
)"
R"(            qlv_bytes[i*64 + j + 32] = convert_uchar((x0 & mask_F0) >> 4) | convert_uchar(x1 & mask_F0);
)"
R"(            qlv_bytes[i*64 + j + 48] = convert_uchar((x2 & mask_F0) >> 4) | convert_uchar(x3 & mask_F0);
)"
R"(        }
)"
R"(    }
)"
R"(
)"
R"(    uint ql_base = i02 * ne00_blk * ne01 * 32 + i00 * ne01 * 32 + i01;
)"
R"(
)"
R"(    #pragma unroll
)"
R"(    for (int p = 0; p < 8; ++p) {
)"
R"(        uint4 v = qlv[p];
)"
R"(        dst_ql[ql_base + (p * 4 + 0) * ne01] = v.x;
)"
R"(        dst_ql[ql_base + (p * 4 + 1) * ne01] = v.y;
)"
R"(        dst_ql[ql_base + (p * 4 + 2) * ne01] = v.z;
)"
R"(        dst_ql[ql_base + (p * 4 + 3) * ne01] = v.w;
)"
R"(    }
)"
R"(
)"
R"(    uint qhv[16] = {0};
)"
R"(
)"
R"(    for (int n = 0; n < 2; ++n) {
)"
R"(        for (int l = 0; l < 32; ++l) {
)"
R"(            uchar h = b->qh[n*32 + l];
)"
R"(            int u = l / 16;
)"
R"(            int bit_pos = (l % 16) * 2;
)"
R"(            qhv[(n*4 + 0)*2 + u] |= ((uint)((h >> 0) & 0x03)) << bit_pos;
)"
R"(            qhv[(n*4 + 1)*2 + u] |= ((uint)((h >> 2) & 0x03)) << bit_pos;
)"
R"(            qhv[(n*4 + 2)*2 + u] |= ((uint)((h >> 4) & 0x03)) << bit_pos;
)"
R"(            qhv[(n*4 + 3)*2 + u] |= ((uint)((h >> 6) & 0x03)) << bit_pos;
)"
R"(        }
)"
R"(    }
)"
R"(
)"
R"(    uint qh_base = i02 * ne00_blk * ne01 * 16 + i00 * ne01 * 16 + i01;
)"
R"(
)"
R"(    for (int p = 0; p < 16; ++p) {
)"
R"(        dst_qh[qh_base + p * ne01] = qhv[p];
)"
R"(    }
)"
R"(
)"
R"(    __global char * s_dst = dst_s + (i02 * ne01 + i01) * ne00_blk * 16 + i00 * 16;
)"
R"(    #pragma unroll
)"
R"(    for (int i = 0; i < 16; ++i) {
)"
R"(        s_dst[i] = b->scales[i];
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_restore_block_q6_k_trans4_ns(
)"
R"(    __global uint  * src_ql,
)"
R"(    __global uint  * src_qh,
)"
R"(    __global half  * src_d,
)"
R"(    __global char  * src_s,
)"
R"(    __global struct block_q6_K * dst0,
)"
R"(    uint ne00,
)"
R"(    uint ne01,
)"
R"(    uchar mask_0F,
)"
R"(    uchar mask_F0
)"
R"() {
)"
R"(    uint i00 = get_global_id(1);  // block index along K
)"
R"(    uint i01 = get_global_id(0);  // row index
)"
R"(    uint i02 = get_global_id(2);  // batch index
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
R"(    uint ne00_blk = ne00 / QK_K;
)"
R"(
)"
R"(    uint src_blk_offset = i01 + i00 * ne01 + i02 * ne00_blk * ne01;
)"
R"(    uint dst_blk_offset = i00 + i01 * ne00_blk + i02 * ne00_blk * ne01;
)"
R"(
)"
R"(    __global struct block_q6_K * b = dst0 + dst_blk_offset;
)"
R"(
)"
R"(    b->d = src_d[src_blk_offset];
)"
R"(
)"
R"(    uint ql_base = i02 * ne00_blk * ne01 * 32 + i00 * ne01 * 32 + i01;
)"
R"(    uint4 qlv[8];
)"
R"(    for (int p = 0; p < 8; ++p) {
)"
R"(        qlv[p].x = src_ql[ql_base + (p * 4 + 0) * ne01];
)"
R"(        qlv[p].y = src_ql[ql_base + (p * 4 + 1) * ne01];
)"
R"(        qlv[p].z = src_ql[ql_base + (p * 4 + 2) * ne01];
)"
R"(        qlv[p].w = src_ql[ql_base + (p * 4 + 3) * ne01];
)"
R"(    }
)"
R"(
)"
R"(    uchar * qlv_bytes = (uchar *)qlv;
)"
R"(    for (int i = 0; i < 2; ++i) {
)"
R"(        for (int j = 0; j < 16; ++j) {
)"
R"(            uchar lo_02 = qlv_bytes[i*64 + j];
)"
R"(            uchar lo_13 = qlv_bytes[i*64 + j + 16];
)"
R"(            uchar hi_02 = qlv_bytes[i*64 + j + 32];
)"
R"(            uchar hi_13 = qlv_bytes[i*64 + j + 48];
)"
R"(            b->ql[i*64 + 2*j]          = convert_uchar((lo_02 & mask_0F) | ((hi_02 & mask_0F) << 4));
)"
R"(            b->ql[i*64 + 2*j + 1]      = convert_uchar(((lo_02 & mask_F0) >> 4) | (hi_02 & mask_F0));
)"
R"(            b->ql[i*64 + 32 + 2*j]     = convert_uchar((lo_13 & mask_0F) | ((hi_13 & mask_0F) << 4));
)"
R"(            b->ql[i*64 + 32 + 2*j + 1] = convert_uchar(((lo_13 & mask_F0) >> 4) | (hi_13 & mask_F0));
)"
R"(        }
)"
R"(    }
)"
R"(
)"
R"(    uint qh_base = i02 * ne00_blk * ne01 * 16 + i00 * ne01 * 16 + i01;
)"
R"(    uint qhv[16];
)"
R"(    for (int p = 0; p < 16; ++p) {
)"
R"(        qhv[p] = src_qh[qh_base + p * ne01];
)"
R"(    }
)"
R"(
)"
R"(    for (int n = 0; n < 2; ++n) {
)"
R"(        for (int l = 0; l < 32; ++l) {
)"
R"(            int u = l / 16;
)"
R"(            int bit_pos = (l % 16) * 2;
)"
R"(            uchar v0 = (uchar)((qhv[(n*4 + 0)*2 + u] >> bit_pos) & 0x03);
)"
R"(            uchar v1 = (uchar)((qhv[(n*4 + 1)*2 + u] >> bit_pos) & 0x03);
)"
R"(            uchar v2 = (uchar)((qhv[(n*4 + 2)*2 + u] >> bit_pos) & 0x03);
)"
R"(            uchar v3 = (uchar)((qhv[(n*4 + 3)*2 + u] >> bit_pos) & 0x03);
)"
R"(            b->qh[n*32 + l] = v0 | (v1 << 2) | (v2 << 4) | (v3 << 6);
)"
R"(        }
)"
R"(    }
)"
R"(
)"
R"(    __global char * s_src = src_s + (i02 * ne01 + i01) * ne00_blk * 16 + i00 * 16;
)"
R"(    for (int i = 0; i < 16; ++i) {
)"
R"(        b->scales[i] = s_src[i];
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(//------------------------------------------------------------------------------
)"
R"(// block_mxfp4
)"
R"(//------------------------------------------------------------------------------
)"
R"(#define QK_MXFP4 32
)"
R"(struct block_mxfp4 {
)"
R"(    uchar e; // E8M0
)"
R"(    uchar qs[QK_MXFP4 / 2];
)"
R"(};
)"
R"(
)"
R"(//------------------------------------------------------------------------------
)"
R"(// kernel_convert_block_mxfp4
)"
R"(// Convert the block_mxfp4 format to 2 separate arrays (AOS -> SOA).
)"
R"(// This kernel does not deshuffle the bits.
)"
R"(//------------------------------------------------------------------------------
)"
R"(kernel void kernel_convert_block_mxfp4(
)"
R"(    global struct block_mxfp4 * src0,
)"
R"(    global uchar * dst_q,
)"
R"(    global uchar * dst_e
)"
R"() {
)"
R"(    global struct block_mxfp4 * b = (global struct block_mxfp4 *) src0 + get_global_id(0);
)"
R"(    global uchar * q = (global uchar *) dst_q + QK_MXFP4 / 2 * get_global_id(0);
)"
R"(    global uchar * e = (global uchar *) dst_e + get_global_id(0);
)"
R"(
)"
R"(    *e = b->e;
)"
R"(
)"
R"(    for (int i = 0; i < QK_MXFP4 / 2; ++i) {
)"
R"(        q[i] = b->qs[i];
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_convert_block_mxfp4_trans(
)"
R"(    global struct block_mxfp4 * src0,
)"
R"(    __global uint4 * dst_q,
)"
R"(    __global uchar * dst_e,
)"
R"(    uint ne00,
)"
R"(    uint ne01
)"
R"() {
)"
R"(    int i00 = get_global_id(1);
)"
R"(    uint i01 = get_global_id(0);
)"
R"(    uint i02 = get_global_id(2);
)"
R"(
)"
R"(    uint ne00_blk = ne00 / QK_MXFP4;
)"
R"(    uint src_blk_offset = i00 + i01 * ne00_blk + i02 * ne00_blk * ne01;
)"
R"(    uint dst_blk_offset = i01 + i00 * ne01 + i02 * ne00_blk * ne01;
)"
R"(
)"
R"(    global struct block_mxfp4 * b = src0 + src_blk_offset;
)"
R"(
)"
R"(    dst_q[dst_blk_offset] = ((global uint4 *)(&(b->qs[0])))[0];
)"
R"(    dst_e[dst_blk_offset] = b->e;
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_restore_block_mxfp4(
)"
R"(    global uchar * src_q,
)"
R"(    global half  * src_e,
)"
R"(    global struct block_mxfp4 * dst
)"
R"() {
)"
R"(    global struct block_mxfp4 * b = (global struct block_mxfp4 *) dst + get_global_id(0);
)"
R"(    global uchar * q = (global uchar *) src_q + QK_MXFP4 / 2 * get_global_id(0);
)"
R"(    global uchar * e = (global uchar *) src_e + get_global_id(0);
)"
R"(
)"
R"(    b->e = *e;
)"
R"(    for (int i = 0; i < QK_MXFP4 / 2; ++i) {
)"
R"(        b->qs[i] = q[i];
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_restore_block_mxfp4_trans(
)"
R"(    __global uint4 * src_q,
)"
R"(    __global uchar * src_e,
)"
R"(    global struct block_mxfp4 * dst,
)"
R"(    uint ne00,
)"
R"(    uint ne01
)"
R"() {
)"
R"(    int i00 = get_global_id(1);
)"
R"(    uint i01 = get_global_id(0);
)"
R"(    uint i02 = get_global_id(2);
)"
R"(
)"
R"(    uint ne00_blk = ne00 / QK_MXFP4;
)"
R"(    uint src_blk_offset = i01 + i00 * ne01 + i02 * ne00_blk * ne01;
)"
R"(    uint dst_blk_offset = i00 + i01 * ne00_blk + i02 * ne00_blk * ne01;
)"
R"(
)"
R"(    global struct block_mxfp4 * b = dst + dst_blk_offset;
)"
R"(
)"
R"(    ((global uint4 *)(&(b->qs[0])))[0] = src_q[src_blk_offset];
)"
R"(    b->e = src_e[src_blk_offset];
)"
R"(}
)"
R"(
)"
R"(//------------------------------------------------------------------------------
)"
R"(// kernel_convert_block_q6_k_tiled_ns
)"
R"(//
)"
R"(// Tiled-wide layout for the long-vocab q6_K lm_head/embed GEMV (decode path).
)"
R"(// Unlike *_trans4_ns (which mirrors the bit-interleave the legacy 2-output GEMV
)"
R"(// consumes), this kernel is correct-by-construction against the CANONICAL ggml
)"
R"(// q6_K dequant: it recovers each weight's 6-bit code in element order e in
)"
R"(// [0,256), then re-packs low-4-bits into 32 uints (8 codes/uint) and high-2-bits
)"
R"(// into 16 uints (16 codes/uint). The matching GEMV (gemv_noshuffle_q6_k_f32_tiled)
)"
R"(// unpacks the same order, so both ends are owned here.
)"
R"(//
)"
R"(// Storage is TILED by 64 output rows so the GEMV's 64-thread tile coalesces:
)"
R"(//   ql uint4 granule g of (row r, K-block sb): idx = ((rt*ne00_blk + sb)*8 + g)*64 + rit
)"
R"(//   qh uint4 granule g:                         idx = ((rt*ne00_blk + sb)*4 + g)*64 + rit
)"
R"(//   scales (char16) of (r, sb):                 idx = (rt*ne00_blk + sb)*64 + rit
)"
R"(//   d (half) of (r, sb):                        idx = (rt*ne00_blk + sb)*64 + rit
)"
R"(// where rt = r/64, rit = r%64. Requires ne01 % 64 == 0 (gated host-side).
)"
R"(// Buffer sizes are byte-identical to the trans4_ns layout.
)"
R"(//------------------------------------------------------------------------------
)"
R"(kernel void kernel_convert_block_q6_k_tiled_ns(
)"
R"(    __global struct block_q6_K * src0,
)"
R"(    __global uint  * dst_ql,   // 32 uints / superblock (low 4 bits, 8 codes/uint)
)"
R"(    __global uint  * dst_qh,   // 16 uints / superblock (high 2 bits, 16 codes/uint)
)"
R"(    __global half  * dst_d,    // 1 half  / superblock
)"
R"(    __global char  * dst_s,    // 16 chars/ superblock
)"
R"(    uint ne00,
)"
R"(    uint ne01
)"
R"() {
)"
R"(    uint i00 = get_global_id(1);   // K-block index (superblock along ne00)
)"
R"(    uint i01 = get_global_id(0);   // output row index (along ne01)
)"
R"(    uint i02 = get_global_id(2);   // batch
)"
R"(
)"
R"(    uint ne00_blk = ne00 / QK_K;
)"
R"(
)"
R"(    // Source block: row-major over (i02, i01, i00).
)"
R"(    uint src_blk_offset = i00 + i01 * ne00_blk + i02 * ne00_blk * ne01;
)"
R"(    __global struct block_q6_K * b = src0 + src_blk_offset;
)"
R"(
)"
R"(    uint rt  = i01 / 64;
)"
R"(    uint rit = i01 % 64;
)"
R"(    uint tile_blk = (i02 * (ne01 / 64) + rt) * ne00_blk + i00;  // tile-major (row-tile, K-block)
)"
R"(
)"
R"(    // --- recover canonical 6-bit codes, pack into ql (4b) + qh (2b) in e-order ---
)"
R"(    // 32 ql-uints (8 low-nibbles each) + 16 qh-uints (16 2-bit slots each).
)"
R"(    uint qlw[32] = {0};
)"
R"(    uint qhw[16] = {0};
)"
R"(
)"
R"(    for (uint e = 0; e < 256; ++e) {
)"
R"(        uint n   = (e >= 128) ? 1u : 0u;       // which 128-half
)"
R"(        uint within = e - n * 128u;
)"
R"(        uint q   = within / 32u;               // quadrant 0..3
)"
R"(        uint l   = within % 32u;               // 0..31
)"
R"(
)"
R"(        uint off_ql = n * 64u;                 // raw ql byte base for this half
)"
R"(        uint off_qh = n * 32u;                 // raw qh byte base for this half
)"
R"(
)"
R"(        uchar low4;
)"
R"(        uchar qlb0 = b->ql[off_ql + l];
)"
R"(        uchar qlb1 = b->ql[off_ql + l + 32];
)"
R"(        if (q == 0)      low4 = qlb0 & 0x0F;
)"
R"(        else if (q == 1) low4 = qlb1 & 0x0F;
)"
R"(        else if (q == 2) low4 = (qlb0 >> 4) & 0x0F;
)"
R"(        else             low4 = (qlb1 >> 4) & 0x0F;
)"
R"(
)"
R"(        uchar hi2 = (b->qh[off_qh + l] >> (q * 2u)) & 0x03;
)"
R"(
)"
R"(        // pack low4 (e-order): uint e/8, nibble (e%8)
)"
R"(        qlw[e >> 3] |= ((uint)low4) << ((e & 7u) * 4u);
)"
R"(        // pack hi2 (e-order): uint e/16, 2-bit slot (e%16)
)"
R"(        qhw[e >> 4] |= ((uint)hi2)  << ((e & 15u) * 2u);
)"
R"(    }
)"
R"(
)"
R"(    // --- write tiled ---
)"
R"(    for (uint g = 0; g < 8; ++g) {
)"
R"(        uint base = (tile_blk * 8u + g) * 64u + rit;   // uint4 index
)"
R"(        dst_ql[base * 4u + 0u] = qlw[g * 4u + 0u];
)"
R"(        dst_ql[base * 4u + 1u] = qlw[g * 4u + 1u];
)"
R"(        dst_ql[base * 4u + 2u] = qlw[g * 4u + 2u];
)"
R"(        dst_ql[base * 4u + 3u] = qlw[g * 4u + 3u];
)"
R"(    }
)"
R"(    for (uint g = 0; g < 4; ++g) {
)"
R"(        uint base = (tile_blk * 4u + g) * 64u + rit;   // uint4 index
)"
R"(        dst_qh[base * 4u + 0u] = qhw[g * 4u + 0u];
)"
R"(        dst_qh[base * 4u + 1u] = qhw[g * 4u + 1u];
)"
R"(        dst_qh[base * 4u + 2u] = qhw[g * 4u + 2u];
)"
R"(        dst_qh[base * 4u + 3u] = qhw[g * 4u + 3u];
)"
R"(    }
)"
R"(
)"
R"(    // scales: 16 chars contiguous per (row, block), tiled
)"
R"(    __global char * s_dst = dst_s + (tile_blk * 64u + rit) * 16u;
)"
R"(    #pragma unroll
)"
R"(    for (int i = 0; i < 16; ++i) {
)"
R"(        s_dst[i] = b->scales[i];
)"
R"(    }
)"
R"(
)"
R"(    // super-block scale
)"
R"(    dst_d[tile_blk * 64u + rit] = b->d;
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_convert_block_mxfp4_trans4_ns(
)"
R"(    global struct block_mxfp4 * src0,
)"
R"(    __global uint * dst_q,
)"
R"(    __global uchar * dst_e,
)"
R"(    uint ne00,
)"
R"(    uint ne01
)"
R"() {
)"
R"(    uint i00 = get_global_id(1);
)"
R"(    uint i01 = get_global_id(0);
)"
R"(    uint i02 = get_global_id(2);
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
R"(    uint ne00_blk = ne00 / QK_MXFP4;
)"
R"(    uint src_blk_offset = i00 + i01 * ne00_blk + i02 * ne00_blk * ne01;
)"
R"(    uint dst_blk_offset = i01 + i00 * ne01 + i02 * ne00_blk * ne01;
)"
R"(
)"
R"(    global struct block_mxfp4 * b = src0 + src_blk_offset;
)"
R"(    dst_e[dst_blk_offset] = b->e;
)"
R"(
)"
R"(    // extract quantization and unshuffle
)"
R"(    ushort8 pre_block = ((global ushort8 *)(&(b->qs[0])))[0];
)"
R"(
)"
R"(    ushort8 post_block = (ushort8)(0);
)"
R"(
)"
R"(    uchar * pre_block_ptr = (uchar *)(&pre_block);
)"
R"(    uchar * post_block_ptr = (uchar *)(&post_block);
)"
R"(
)"
R"(    for (int i = 0; i < QK_MXFP4 / 4; ++i) {
)"
R"(        uchar x0 = pre_block_ptr[2*i + 0];
)"
R"(        uchar x1 = pre_block_ptr[2*i + 1];
)"
R"(
)"
R"(        post_block_ptr[i + 0        ] = convert_uchar(x0 & 0x0F) | convert_uchar((x1 & 0x0F) << 4);
)"
R"(        post_block_ptr[i + QK_MXFP4 / 4] = convert_uchar((x0 & 0xF0) >> 4) | convert_uchar(x1 & 0xF0);
)"
R"(    }
)"
R"(
)"
R"(    uint4 q_block = as_uint4(post_block);
)"
R"(
)"
R"(    uint offset = i02 * ne00_blk * ne01 * 4 + i00 * ne01 * 4 + i01;
)"
R"(    dst_q[offset] = q_block.x;
)"
R"(    dst_q[offset + ne01] = q_block.y;
)"
R"(    dst_q[offset + ne01 * 2] = q_block.z;
)"
R"(    dst_q[offset + ne01 * 3] = q_block.w;
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_restore_block_mxfp4_trans4_ns(
)"
R"(    __global uint * src_q,
)"
R"(    __global uchar * src_e,
)"
R"(    __global struct block_mxfp4 * dst0,
)"
R"(    uint ne00,
)"
R"(    uint ne01
)"
R"() {
)"
R"(    uint i00 = get_global_id(1);
)"
R"(    uint i01 = get_global_id(0);
)"
R"(    uint i02 = get_global_id(2);
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
R"(    uint ne00_blk = ne00 / QK_MXFP4;
)"
R"(    uint dst_blk_offset = i00 + i01 * ne00_blk + i02 * ne00_blk * ne01;
)"
R"(    uint src_d_offset = i01 + i00 * ne01 + i02 * ne00_blk * ne01;
)"
R"(
)"
R"(    __global struct block_mxfp4 * b = dst0 + dst_blk_offset;
)"
R"(    b->e = src_e[src_d_offset];
)"
R"(
)"
R"(    // collect transposed quantization parts for a block
)"
R"(    uint src_q_offset = i02 * ne00_blk * ne01 * 4 + i00 * ne01 * 4 + i01;
)"
R"(    uint4 q_block;
)"
R"(    q_block.x = src_q[src_q_offset];
)"
R"(    q_block.y = src_q[src_q_offset + ne01];
)"
R"(    q_block.z = src_q[src_q_offset + ne01 * 2];
)"
R"(    q_block.w = src_q[src_q_offset + ne01 * 3];
)"
R"(
)"
R"(    ushort8 post_block = as_ushort8(q_block);
)"
R"(    ushort8 pre_block = (ushort8)(0);
)"
R"(
)"
R"(    uchar * pre_block_ptr = (uchar *)(&pre_block);
)"
R"(    uchar * post_block_ptr = (uchar *)(&post_block);
)"
R"(
)"
R"(    for (int i = 0; i < QK_MXFP4 / 4; ++i) {
)"
R"(        uchar x0 = post_block_ptr[i + 0];
)"
R"(        uchar x1 = post_block_ptr[i + QK_MXFP4 / 4];
)"
R"(
)"
R"(        pre_block_ptr[2 * i + 0] = convert_uchar(x0 & 0x0F) | convert_uchar((x1 & 0x0F) << 4);
)"
R"(        pre_block_ptr[2 * i + 1] = convert_uchar((x0 & 0xF0) >> 4) | convert_uchar(x1 & 0xF0);
)"
R"(    }
)"
R"(
)"
R"(    ((__global ushort8 *)(&(b->qs[0])))[0] = pre_block;
)"
R"(}
)"
R"(
)"
R"(
)"
R"(//------------------------------------------------------------------------------
)"
R"(// block_q8_0
)"
R"(//------------------------------------------------------------------------------
)"
R"(typedef struct {
)"
R"(    half d;       // delta
)"
R"(    char qs[QK8_0]; // quants
)"
R"(} block_q8_0;
)"
R"(
)"
R"(kernel void kernel_convert_block_q8_0(
)"
R"(    global block_q8_0 * src0,
)"
R"(    global uchar * dst_q,
)"
R"(    global half  * dst_d
)"
R"() {
)"
R"(    global block_q8_0 * b = (global block_q8_0 *) src0 + get_global_id(0);
)"
R"(    global uchar      * q = (global uchar *) dst_q + QK8_0*get_global_id(0);
)"
R"(    global half       * d = (global half *) dst_d + get_global_id(0);
)"
R"(
)"
R"(    *d = b->d;
)"
R"(
)"
R"(    for (int i = 0; i < QK8_0; ++i) {
)"
R"(        q[i] = b->qs[i];
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_restore_block_q8_0(
)"
R"(    global uchar * src_q,
)"
R"(    global half  * src_d,
)"
R"(    global block_q8_0 * dst
)"
R"() {
)"
R"(    global block_q8_0 * b = (global block_q8_0 *) dst + get_global_id(0);
)"
R"(    global uchar      * q = (global uchar *) src_q + QK8_0*get_global_id(0);
)"
R"(    global half       * d = (global half *) src_d + get_global_id(0);
)"
R"(
)"
R"(    b->d = *d;
)"
R"(    for (int i = 0; i < QK8_0; ++i) {
)"
R"(        b->qs[i] = q[i];
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(// View-aware AoS q8_0 -> f32 dequant (f32/f32 FA path).
)"
R"(kernel void kernel_dequant_q8_0_f32_view_aos(
)"
R"(    global char * src,
)"
R"(    ulong         src_offset,
)"
R"(    ulong         src_nb1,
)"
R"(    ulong         src_nb2,
)"
R"(    ulong         src_nb3,
)"
R"(    int           nblk0,
)"
R"(    int           ne1,
)"
R"(    int           ne2,
)"
R"(    int           ne3,
)"
R"(    global float * dst
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
R"(    if (blk_i0 >= nblk0) return;
)"
R"(    if (i1     >= ne1)   return;
)"
R"(
)"
R"(    int i2 = batch % ne2;
)"
R"(    int i3 = batch / ne2;
)"
R"(    if (i3 >= ne3) return;
)"
R"(
)"
R"(    global char * block = src + src_offset + (ulong)i3*src_nb3 + (ulong)i2*src_nb2 + (ulong)i1*src_nb1 + (ulong)blk_i0 * (2 + QK8_0);
)"
R"(    float d = vload_half(0, (global half *)block);
)"
R"(    global char * qs = block + 2;
)"
R"(
)"
R"(    ulong dst_row_base = ((ulong)i3 * ne2 * ne1 + (ulong)i2 * ne1 + (ulong)i1) * nblk0;
)"
R"(    global float * out = dst + (dst_row_base + blk_i0) * QK8_0;
)"
R"(
)"
R"(    for (int i = 0; i < QK8_0; ++i) {
)"
R"(        out[i] = d * (float)qs[i];
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(// View-aware AoS q8_0 -> f16 dequant. Rows tight, batch strides may be gapped.
)"
R"(kernel void kernel_dequant_q8_0_f16_view_aos(
)"
R"(    global char * src,
)"
R"(    ulong         src_offset,
)"
R"(    ulong         src_nb1,
)"
R"(    ulong         src_nb2,
)"
R"(    ulong         src_nb3,
)"
R"(    int           nblk0,
)"
R"(    int           ne1,
)"
R"(    int           ne2,
)"
R"(    int           ne3,
)"
R"(    global half * dst
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
R"(    if (blk_i0 >= nblk0) return;
)"
R"(    if (i1     >= ne1)   return;
)"
R"(
)"
R"(    int i2 = batch % ne2;
)"
R"(    int i3 = batch / ne2;
)"
R"(    if (i3 >= ne3) return;
)"
R"(
)"
R"(    global char * block = src + src_offset + (ulong)i3*src_nb3 + (ulong)i2*src_nb2 + (ulong)i1*src_nb1 + (ulong)blk_i0 * (2 + QK8_0);
)"
R"(    float d = vload_half(0, (global half *)block);
)"
R"(    global char * qs = block + 2;
)"
R"(
)"
R"(    ulong dst_row_base = ((ulong)i3 * ne2 * ne1 + (ulong)i2 * ne1 + (ulong)i1) * nblk0;
)"
R"(    global half * out = dst + (dst_row_base + blk_i0) * QK8_0;
)"
R"(
)"
R"(    for (int i = 0; i < QK8_0; ++i) {
)"
R"(        out[i] = (half)(d * (float)qs[i]);
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(// View-aware AoS q4_0 -> f32 dequant (mirrors the q8_0 view variant).
)"
R"(kernel void kernel_dequant_q4_0_f32_view_aos(
)"
R"(    global char * src,
)"
R"(    ulong         src_offset,
)"
R"(    ulong         src_nb1,
)"
R"(    ulong         src_nb2,
)"
R"(    ulong         src_nb3,
)"
R"(    int           nblk0,
)"
R"(    int           ne1,
)"
R"(    int           ne2,
)"
R"(    int           ne3,
)"
R"(    global float * dst
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
R"(    if (blk_i0 >= nblk0) return;
)"
R"(    if (i1     >= ne1)   return;
)"
R"(
)"
R"(    int i2 = batch % ne2;
)"
R"(    int i3 = batch / ne2;
)"
R"(    if (i3 >= ne3) return;
)"
R"(
)"
R"(    global char * block = src + src_offset + (ulong)i3*src_nb3 + (ulong)i2*src_nb2 + (ulong)i1*src_nb1 + (ulong)blk_i0 * (2 + QK4_0/2);
)"
R"(    float d = vload_half(0, (global half *)block);
)"
R"(    global uchar * qs = (global uchar *)(block + 2);
)"
R"(
)"
R"(    ulong dst_row_base = ((ulong)i3 * ne2 * ne1 + (ulong)i2 * ne1 + (ulong)i1) * nblk0;
)"
R"(    global float * out = dst + (dst_row_base + blk_i0) * QK4_0;
)"
R"(
)"
R"(    for (int i = 0; i < QK4_0/2; ++i) {
)"
R"(        uchar byte = qs[i];
)"
R"(        int q0 = (int)(byte & 0x0F) - 8;
)"
R"(        int q1 = (int)(byte >> 4)   - 8;
)"
R"(        out[i]            = d * (float)q0;
)"
R"(        out[i + QK4_0/2]  = d * (float)q1;
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(// View-aware AoS q4_0 -> f16 dequant (mirrors the q8_0 view variant).
)"
R"(kernel void kernel_dequant_q4_0_f16_view_aos(
)"
R"(    global char * src,
)"
R"(    ulong         src_offset,
)"
R"(    ulong         src_nb1,
)"
R"(    ulong         src_nb2,
)"
R"(    ulong         src_nb3,
)"
R"(    int           nblk0,
)"
R"(    int           ne1,
)"
R"(    int           ne2,
)"
R"(    int           ne3,
)"
R"(    global half * dst
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
R"(    if (blk_i0 >= nblk0) return;
)"
R"(    if (i1     >= ne1)   return;
)"
R"(
)"
R"(    int i2 = batch % ne2;
)"
R"(    int i3 = batch / ne2;
)"
R"(    if (i3 >= ne3) return;
)"
R"(
)"
R"(    global char * block = src + src_offset + (ulong)i3*src_nb3 + (ulong)i2*src_nb2 + (ulong)i1*src_nb1 + (ulong)blk_i0 * (2 + QK4_0/2);
)"
R"(    float d = vload_half(0, (global half *)block);
)"
R"(    global uchar * qs = (global uchar *)(block + 2);
)"
R"(
)"
R"(    ulong dst_row_base = ((ulong)i3 * ne2 * ne1 + (ulong)i2 * ne1 + (ulong)i1) * nblk0;
)"
R"(    global half * out = dst + (dst_row_base + blk_i0) * QK4_0;
)"
R"(
)"
R"(    for (int i = 0; i < QK4_0/2; ++i) {
)"
R"(        uchar byte = qs[i];
)"
R"(        int q0 = (int)(byte & 0x0F) - 8;
)"
R"(        int q1 = (int)(byte >> 4)   - 8;
)"
R"(        out[i]          = (half)(d * (float)q0);
)"
R"(        out[i + QK4_0/2] = (half)(d * (float)q1);
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_restore_block_q8_0_trans(
)"
R"(    global uchar * src_q,
)"
R"(    global half  * src_d,
)"
R"(    global block_q8_0 * dst,
)"
R"(    uint ne00,
)"
R"(    uint ne01
)"
R"(){
)"
R"(    uint num_blk_per_row = ne00 / QK8_0;
)"
R"(
)"
R"(    global block_q8_0 * b = (global block_q8_0 *) dst + get_global_id(0) * num_blk_per_row;
)"
R"(    global uchar      * q = (global uchar *) src_q + get_global_id(0) * 4; // 4 8-bit packed
)"
R"(    global half       * d = (global half *) src_d + get_global_id(0);
)"
R"(
)"
R"(    for (uint blk = 0; blk < num_blk_per_row; blk++) {
)"
R"(        b->d = *d;
)"
R"(
)"
R"(        for (uint i = 0; i < QK8_0; i+=4) {
)"
R"(            b->qs[i]   = q[0];
)"
R"(            b->qs[i+1] = q[1];
)"
R"(            b->qs[i+2] = q[2];
)"
R"(            b->qs[i+3] = q[3];
)"
R"(
)"
R"(            q += 4 * ne01; // M stride
)"
R"(        }
)"
R"(
)"
R"(        d += ne01;
)"
R"(
)"
R"(        b++;
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(//------------------------------------------------------------------------------
)"
R"(// kernel_convert_block_q4_K
)"
R"(// Convert the block_q4_K format to 4 separate arrays (AOS -> SOA).
)"
R"(// This kernel does not deshuffle the bits.
)"
R"(// Each thread processes a super block.
)"
R"(// Mask args are just to keep the signature consistent with the no-shuffle
)"
R"(// version and they are not used in this kernel.
)"
R"(//------------------------------------------------------------------------------
)"
R"(kernel void kernel_convert_block_q4_K(
)"
R"(    global struct block_q4_K * src0,
)"
R"(    global uchar * dst_q,
)"
R"(    global uchar * dst_s,
)"
R"(    global half  * dst_d,
)"
R"(    global half  * dst_dm,
)"
R"(    uchar mask_0F,
)"
R"(    uchar mask_F0
)"
R"() {
)"
R"(    global struct block_q4_K * b = (global struct block_q4_K *) src0 + get_global_id(0);
)"
R"(    global uchar * q  = (global uchar *) dst_q  + QK_K/2*get_global_id(0);
)"
R"(    global uchar * s  = (global uchar *) dst_s  + K_SCALE_SIZE*get_global_id(0);
)"
R"(    global half  * d  = (global half  *) dst_d  + get_global_id(0);
)"
R"(    global half  * dm = (global half  *) dst_dm + get_global_id(0);
)"
R"(
)"
R"(    *d  = b->d;
)"
R"(    *dm = b->dm;
)"
R"(
)"
R"(    for (int i = 0; i < QK_K/2; ++i) {
)"
R"(        q[i] = b->q[i];
)"
R"(    }
)"
R"(    for (int i = 0; i < K_SCALE_SIZE; ++i) {
)"
R"(        s[i] = b->s[i];
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(// Restore block_q4_K from flattened arrays.
)"
R"(// Each thread processes a super block.
)"
R"(// Mask args are just to keep the signature consistent with the no-shuffle ones.
)"
R"(kernel void kernel_restore_block_q4_K(
)"
R"(    global uchar * src_q,
)"
R"(    global uchar * src_s,
)"
R"(    global half  * src_d,
)"
R"(    global half  * src_dm,
)"
R"(    global struct block_q4_K * dst,
)"
R"(    uchar mask_0F,
)"
R"(    uchar mask_F0
)"
R"() {
)"
R"(    global struct block_q4_K * b = (global struct block_q4_K *) dst + get_global_id(0);
)"
R"(    global uchar * q  = (global uchar *) src_q  + QK_K/2*get_global_id(0);
)"
R"(    global uchar * s  = (global uchar *) src_s + K_SCALE_SIZE*get_global_id(0);
)"
R"(    global half  * d  = (global half  *) src_d  + get_global_id(0);
)"
R"(    global half  * dm = (global half  *) src_dm  + get_global_id(0);
)"
R"(
)"
R"(    b->d  = *d;
)"
R"(    b->dm = *dm;
)"
R"(
)"
R"(    for (int i = 0; i < QK_K/2; ++i) {
)"
R"(        b->q[i] = q[i];
)"
R"(    }
)"
R"(    for (int i = 0; i < K_SCALE_SIZE; ++i) {
)"
R"(        b->s[i] = s[i];
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_convert_block_q4_K_noshuffle(
)"
R"(    global struct block_q4_K * src0,
)"
R"(    global uchar * dst_q,
)"
R"(    global uchar * dst_s,
)"
R"(    global half  * dst_d,
)"
R"(    global half  * dst_dm,
)"
R"(    uchar mask_0F,
)"
R"(    uchar mask_F0
)"
R"() {
)"
R"(    global struct block_q4_K * b = (global struct block_q4_K *) src0 + get_global_id(0);
)"
R"(    global uchar * q  = (global uchar *) dst_q  + QK_K/2 * get_global_id(0);
)"
R"(    global uchar * s  = (global uchar *) dst_s  + K_SCALE_SIZE * get_global_id(0);
)"
R"(    global half  * d  = (global half  *) dst_d  + get_global_id(0);
)"
R"(    global half  * dm = (global half  *) dst_dm + get_global_id(0);
)"
R"(
)"
R"(    *d  = b->d;
)"
R"(    *dm = b->dm;
)"
R"(
)"
R"(    for (int i = 0; i < QK_K / 64; ++i) {
)"
R"(        for (int j = 0; j < 16; ++j) {
)"
R"(            uchar x0 = b->q[i*32 + 2*j];
)"
R"(            uchar x1 = b->q[i*32 + 2*j + 1];
)"
R"(            q[i*32 + j]      = convert_uchar(x0 & mask_0F) | convert_uchar((x1 & mask_0F) << 4);
)"
R"(            q[i*32 + j + 16] = convert_uchar((x0 & mask_F0) >> 4)   | convert_uchar(x1 & mask_F0);
)"
R"(        }
)"
R"(    }
)"
R"(
)"
R"(    for (int i = 0; i < K_SCALE_SIZE; ++i) {
)"
R"(        s[i] = b->s[i];
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_restore_block_q4_K_noshuffle(
)"
R"(    global uchar * src_q,
)"
R"(    global uchar * src_s,
)"
R"(    global half  * src_d,
)"
R"(    global half  * src_dm,
)"
R"(    global struct block_q4_K * dst,
)"
R"(    uchar mask_0F,
)"
R"(    uchar mask_F0
)"
R"() {
)"
R"(    global struct block_q4_K * b = (global struct block_q4_K *) dst + get_global_id(0);
)"
R"(    global uchar * q  = (global uchar *) src_q  + QK_K/2 * get_global_id(0);
)"
R"(    global uchar * s  = (global uchar *) src_s  + K_SCALE_SIZE * get_global_id(0);
)"
R"(    global half  * d  = (global half  *) src_d  + get_global_id(0);
)"
R"(    global half  * dm = (global half  *) src_dm + get_global_id(0);
)"
R"(
)"
R"(    b->d  = *d;
)"
R"(    b->dm = *dm;
)"
R"(
)"
R"(    for (int i = 0; i < QK_K / 64; ++i) {
)"
R"(        for (int j = 0; j < 16; ++j) {
)"
R"(            uchar lo = q[i*32 + j];
)"
R"(            uchar hi = q[i*32 + j + 16];
)"
R"(            b->q[i*32 + 2*j]     = convert_uchar((lo & mask_0F) | ((hi & mask_0F) << 4));
)"
R"(            b->q[i*32 + 2*j + 1] = convert_uchar(((lo & mask_F0) >> 4) | (hi & mask_F0));
)"
R"(        }
)"
R"(    }
)"
R"(
)"
R"(    for (int i = 0; i < K_SCALE_SIZE; ++i) {
)"
R"(        b->s[i] = s[i];
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(//------------------------------------------------------------------------------
)"
R"(// kernel_convert_block_q5_K
)"
R"(// Convert the block_q5_K format to 5 separate arrays (AOS -> SOA).
)"
R"(// Each thread processes a super block.
)"
R"(//------------------------------------------------------------------------------
)"
R"(kernel void kernel_convert_block_q5_K(
)"
R"(    global struct block_q5_K * src0,
)"
R"(    global uchar * dst_q,
)"
R"(    global uchar * dst_qh,
)"
R"(    global uchar * dst_s,
)"
R"(    global half  * dst_d,
)"
R"(    global half  * dst_dm,
)"
R"(    uchar mask_0F,
)"
R"(    uchar mask_F0
)"
R"() {
)"
R"(    global struct block_q5_K * b  = (global struct block_q5_K *) src0 + get_global_id(0);
)"
R"(    global uchar * q  = (global uchar *) dst_q  + QK_K/2*get_global_id(0);
)"
R"(    global uchar * qh = (global uchar *) dst_qh + QK_K/8*get_global_id(0);
)"
R"(    global uchar * s  = (global uchar *) dst_s  + K_SCALE_SIZE*get_global_id(0);
)"
R"(    global half  * d  = (global half  *) dst_d  + get_global_id(0);
)"
R"(    global half  * dm = (global half  *) dst_dm + get_global_id(0);
)"
R"(
)"
R"(    *d  = b->d;
)"
R"(    *dm = b->dm;
)"
R"(
)"
R"(    for (int i = 0; i < QK_K/2; ++i) {
)"
R"(        q[i] = b->qs[i];
)"
R"(    }
)"
R"(    for (int i = 0; i < QK_K/8; ++i) {
)"
R"(        qh[i] = b->qh[i];
)"
R"(    }
)"
R"(    for (int i = 0; i < K_SCALE_SIZE; ++i) {
)"
R"(        s[i] = b->s[i];
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(// Restore block_q5_K from flattened arrays.
)"
R"(// Each thread processes a super block.
)"
R"(kernel void kernel_restore_block_q5_K(
)"
R"(    global uchar * src_q,
)"
R"(    global uchar * src_qh,
)"
R"(    global uchar * src_s,
)"
R"(    global half  * src_d,
)"
R"(    global half  * src_dm,
)"
R"(    global struct block_q5_K * dst,
)"
R"(    uchar mask_0F,
)"
R"(    uchar mask_F0
)"
R"() {
)"
R"(    global struct block_q5_K * b  = (global struct block_q5_K *) dst + get_global_id(0);
)"
R"(    global uchar * q  = (global uchar *) src_q  + QK_K/2*get_global_id(0);
)"
R"(    global uchar * qh = (global uchar *) src_qh + QK_K/8*get_global_id(0);
)"
R"(    global uchar * s  = (global uchar *) src_s  + K_SCALE_SIZE*get_global_id(0);
)"
R"(    global half  * d  = (global half  *) src_d  + get_global_id(0);
)"
R"(    global half  * dm = (global half  *) src_dm + get_global_id(0);
)"
R"(
)"
R"(    b->d    = *d;
)"
R"(    b->dm = *dm;
)"
R"(
)"
R"(    for (int i = 0; i < QK_K/2; ++i) {
)"
R"(        b->qs[i] = q[i];
)"
R"(    }
)"
R"(    for (int i = 0; i < QK_K/8; ++i) {
)"
R"(        b->qh[i] = qh[i];
)"
R"(    }
)"
R"(    for (int i = 0; i < K_SCALE_SIZE; ++i) {
)"
R"(        b->s[i] = s[i];
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_convert_block_q5_K_noshuffle(
)"
R"(    global struct block_q5_K * src0,
)"
R"(    global uchar * dst_q,
)"
R"(    global uchar * dst_qh,
)"
R"(    global uchar * dst_s,
)"
R"(    global half  * dst_d,
)"
R"(    global half  * dst_dm,
)"
R"(    uchar mask_0F,
)"
R"(    uchar mask_F0
)"
R"() {
)"
R"(    global struct block_q5_K * b  = (global struct block_q5_K *) src0 + get_global_id(0);
)"
R"(    global uchar * q  = (global uchar *) dst_q  + QK_K/2       * get_global_id(0);
)"
R"(    global uchar * qh = (global uchar *) dst_qh + QK_K/8       * get_global_id(0);
)"
R"(    global uchar * s  = (global uchar *) dst_s  + K_SCALE_SIZE * get_global_id(0);
)"
R"(    global half  * d  = (global half  *) dst_d  + get_global_id(0);
)"
R"(    global half  * dm = (global half  *) dst_dm + get_global_id(0);
)"
R"(
)"
R"(    *d  = b->d;
)"
R"(    *dm = b->dm;
)"
R"(
)"
R"(    for (int i = 0; i < QK_K / 64; ++i) {
)"
R"(        for (int j = 0; j < 16; ++j) {
)"
R"(            uchar x0 = b->qs[i*32 + 2*j];
)"
R"(            uchar x1 = b->qs[i*32 + 2*j + 1];
)"
R"(            q[i*32 + j]      = convert_uchar(x0 & mask_0F) | convert_uchar((x1 & mask_0F) << 4);
)"
R"(            q[i*32 + j + 16] = convert_uchar((x0 & mask_F0) >> 4) | convert_uchar(x1 & mask_F0);
)"
R"(        }
)"
R"(    }
)"
R"(
)"
R"(    for (int l = 0; l < QK_K/8; ++l) {
)"
R"(        uchar x0 = 0;
)"
R"(        for (int i = 0; i < 8; ++i) {
)"
R"(            x0 |= ((b->qh[(l%4)*8+i] >> (l/4)) & 0x01) << i;
)"
R"(        }
)"
R"(        qh[l] = x0;
)"
R"(    }
)"
R"(
)"
R"(    for (int i = 0; i < K_SCALE_SIZE; ++i) {
)"
R"(        s[i] = b->s[i];
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_restore_block_q5_K_noshuffle(
)"
R"(    global uchar * src_q,
)"
R"(    global uchar * src_qh,
)"
R"(    global uchar * src_s,
)"
R"(    global half  * src_d,
)"
R"(    global half  * src_dm,
)"
R"(    global struct block_q5_K * dst,
)"
R"(    uchar mask_0F,
)"
R"(    uchar mask_F0
)"
R"() {
)"
R"(    global struct block_q5_K * b  = (global struct block_q5_K *) dst + get_global_id(0);
)"
R"(    global uchar * q  = (global uchar *) src_q  + QK_K/2       * get_global_id(0);
)"
R"(    global uchar * qh = (global uchar *) src_qh + QK_K/8       * get_global_id(0);
)"
R"(    global uchar * s  = (global uchar *) src_s  + K_SCALE_SIZE * get_global_id(0);
)"
R"(    global half  * d  = (global half  *) src_d  + get_global_id(0);
)"
R"(    global half  * dm = (global half  *) src_dm + get_global_id(0);
)"
R"(
)"
R"(    b->d  = *d;
)"
R"(    b->dm = *dm;
)"
R"(
)"
R"(    for (int i = 0; i < QK_K / 64; ++i) {
)"
R"(        for (int j = 0; j < 16; ++j) {
)"
R"(            uchar lo = q[i*32 + j];
)"
R"(            uchar hi = q[i*32 + j + 16];
)"
R"(            b->qs[i*32 + 2*j]     = convert_uchar((lo & mask_0F) | ((hi & mask_0F) << 4));
)"
R"(            b->qs[i*32 + 2*j + 1] = convert_uchar(((lo & mask_F0) >> 4) | (hi & mask_F0));
)"
R"(        }
)"
R"(    }
)"
R"(
)"
R"(    for (int g = 0; g < 4; ++g) {
)"
R"(        for (int i = 0; i < 8; ++i) {
)"
R"(            uchar x0 = 0;
)"
R"(            for (int k = 0; k < 8; ++k) {
)"
R"(                x0 |= ((qh[4*k+g] >> i) & 0x01) << k;
)"
R"(            }
)"
R"(            b->qh[g*8+i] = x0;
)"
R"(        }
)"
R"(    }
)"
R"(
)"
R"(    for (int i = 0; i < K_SCALE_SIZE; ++i) {
)"
R"(        b->s[i] = s[i];
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(//------------------------------------------------------------------------------
)"
R"(// kernel_convert_block_q6_K
)"
R"(// Convert the block_q6_K format to 3 separate arrays (AOS -> SOA).
)"
R"(// This kernel does not deshuffle the bits.
)"
R"(// Each thread processes a super block.
)"
R"(//------------------------------------------------------------------------------
)"
R"(kernel void kernel_convert_block_q6_K(
)"
R"(    global struct block_q6_K * src0,
)"
R"(    global uchar * dst_ql,
)"
R"(    global uchar * dst_qh,
)"
R"(    global char  * dst_s,
)"
R"(    global half  * dst_d,
)"
R"(    uchar          mask_lsb_8,
)"
R"(    ulong          n_blk
)"
R"() {
)"
R"(    if (get_global_id(0) >= n_blk) {
)"
R"(        return;
)"
R"(    }
)"
R"(    global struct block_q6_K * b = (global struct block_q6_K *) src0 + get_global_id(0);
)"
R"(    global uchar * ql = (global uchar *) dst_ql + QK_K/2*get_global_id(0);
)"
R"(    global uchar * qh = (global uchar *) dst_qh + QK_K/4*get_global_id(0);
)"
R"(    global char  * s  = (global char  *) dst_s  + QK_K/16*get_global_id(0);
)"
R"(    global half  * d  = (global half  *) dst_d  + get_global_id(0);
)"
R"(
)"
R"(    *d = b->d;
)"
R"(
)"
R"(    for (int i = 0; i < QK_K/2; ++i) {
)"
R"(        ql[i] = b->ql[i];
)"
R"(    }
)"
R"(    for (int i = 0; i < QK_K/4; ++i) {
)"
R"(        qh[i] = b->qh[i];
)"
R"(    }
)"
R"(    for (int i = 0; i < QK_K/16; ++i) {
)"
R"(        s[i] = b->scales[i];
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(// Restore block_q6_K from flattened arrays.
)"
R"(// Each thread processes a super block.
)"
R"(kernel void kernel_restore_block_q6_K(
)"
R"(    global uchar * dst_ql,
)"
R"(    global uchar * dst_qh,
)"
R"(    global char  * dst_s,
)"
R"(    global half  * dst_d,
)"
R"(    global struct block_q6_K * dst,
)"
R"(    uchar mask_lsb_8,
)"
R"(    ulong n_blk
)"
R"() {
)"
R"(    if (get_global_id(0) >= n_blk) {
)"
R"(        return;
)"
R"(    }
)"
R"(    global struct block_q6_K * b = (global struct block_q6_K *) dst + get_global_id(0);
)"
R"(    global uchar * ql = (global uchar *) dst_ql + QK_K/2*get_global_id(0);
)"
R"(    global uchar * qh = (global uchar *) dst_qh + QK_K/4*get_global_id(0);
)"
R"(    global char  * s  = (global char  *) dst_s  + QK_K/16*get_global_id(0);
)"
R"(    global half  * d  = (global half  *) dst_d  + get_global_id(0);
)"
R"(
)"
R"(    b->d = *d;
)"
R"(
)"
R"(    for (int i = 0; i < QK_K/2; ++i) {
)"
R"(        b->ql[i] = ql[i];
)"
R"(    }
)"
R"(    for (int i = 0; i < QK_K/4; ++i) {
)"
R"(        b->qh[i] = qh[i];
)"
R"(    }
)"
R"(    for (int i = 0; i < QK_K/16; ++i) {
)"
R"(        b->scales[i] = s[i];
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_convert_block_q6_K_noshuffle(
)"
R"(    global struct block_q6_K * src0,
)"
R"(    global uchar * dst_ql,
)"
R"(    global uchar * dst_qh,
)"
R"(    global char  * dst_s,
)"
R"(    global half  * dst_d,
)"
R"(    uchar          mask_lsb_8,
)"
R"(    ulong          n_blk
)"
R"() {
)"
R"(    if (get_global_id(0) >= n_blk) {
)"
R"(        return;
)"
R"(    }
)"
R"(    global struct block_q6_K * b = (global struct block_q6_K *) src0 + get_global_id(0);
)"
R"(    global uchar * ql = (global uchar *) dst_ql + QK_K/2*get_global_id(0);
)"
R"(    global uchar * qh = (global uchar *) dst_qh + QK_K/4*get_global_id(0);
)"
R"(    global char  * s  = (global char  *) dst_s  + QK_K/16*get_global_id(0);
)"
R"(    global half  * d  = (global half  *) dst_d  + get_global_id(0);
)"
R"(
)"
R"(    *d = b->d;
)"
R"(
)"
R"(    for (int i = 0; i < QK_K/2/4; ++i) {
)"
R"(        uchar x0 = b->ql[i*2 + 0] & mask_lsb_8;
)"
R"(        uchar x1 = b->ql[i*2 + 1] & mask_lsb_8;
)"
R"(        ql[i +  0] = (x0 & 0x0F)        | ((x1 & 0x0F) << 4);
)"
R"(        ql[i + 32] = ((x0 & 0xF0) >> 4) | (x1 & 0xF0);
)"
R"(
)"
R"(        uchar x2 = b->ql[i*2 + 0 + 64] & mask_lsb_8;
)"
R"(        uchar x3 = b->ql[i*2 + 1 + 64] & mask_lsb_8;
)"
R"(        ql[i + 64] = (x2 & 0x0F)        | ((x3 & 0x0F) << 4);
)"
R"(        ql[i + 96] = ((x2 & 0xF0) >> 4) | (x3 & 0xF0);
)"
R"(    }
)"
R"(
)"
R"(    for (int i = 0; i < QK_K/4/8; ++i) {
)"
R"(        uchar x0 = b->qh[i*4 + 0] & mask_lsb_8;
)"
R"(        uchar x1 = b->qh[i*4 + 1] & mask_lsb_8;
)"
R"(        uchar x2 = b->qh[i*4 + 2] & mask_lsb_8;
)"
R"(        uchar x3 = b->qh[i*4 + 3] & mask_lsb_8;
)"
R"(        qh[i +  0] = (x0 & 0x03)        | ((x1 & 0x03) << 2) | ((x2 & 0x03) << 4) | ((x3 & 0x03) << 6);
)"
R"(        qh[i +  8] = ((x0 & 0x0C) >> 2) | (x1 & 0x0C)        | ((x2 & 0x0C) << 2) | ((x3 & 0x0C) << 4);
)"
R"(        qh[i + 16] = ((x0 & 0x30) >> 4) | ((x1 & 0x30) >> 2) | (x2 & 0x30)        | ((x3 & 0x30) << 2);
)"
R"(        qh[i + 24] = ((x0 & 0xC0) >> 6) | ((x1 & 0xC0) >> 4) | ((x2 & 0xC0) >> 2) | (x3 & 0xC0);
)"
R"(
)"
R"(        uchar x4 = b->qh[i*4 + 0 + 32] & mask_lsb_8;
)"
R"(        uchar x5 = b->qh[i*4 + 1 + 32] & mask_lsb_8;
)"
R"(        uchar x6 = b->qh[i*4 + 2 + 32] & mask_lsb_8;
)"
R"(        uchar x7 = b->qh[i*4 + 3 + 32] & mask_lsb_8;
)"
R"(        qh[i + 32] = (x4 & 0x03)        | ((x5 & 0x03) << 2) | ((x6 & 0x03) << 4) | ((x7 & 0x03) << 6);
)"
R"(        qh[i + 40] = ((x4 & 0x0C) >> 2) | (x5 & 0x0C)        | ((x6 & 0x0C) << 2) | ((x7 & 0x0C) << 4);
)"
R"(        qh[i + 48] = ((x4 & 0x30) >> 4) | ((x5 & 0x30) >> 2) | (x6 & 0x30)        | ((x7 & 0x30) << 2);
)"
R"(        qh[i + 56] = ((x4 & 0xC0) >> 6) | ((x5 & 0xC0) >> 4) | ((x6 & 0xC0) >> 2) | (x7 & 0xC0);
)"
R"(    }
)"
R"(
)"
R"(    for (int i = 0; i < QK_K/16; ++i) {
)"
R"(        s[i] = b->scales[i];
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_restore_block_q6_K_noshuffle(
)"
R"(    global uchar * src_ql,
)"
R"(    global uchar * src_qh,
)"
R"(    global char  * src_s,
)"
R"(    global half  * src_d,
)"
R"(    global struct block_q6_K * dst,
)"
R"(    uchar          mask_lsb_8,
)"
R"(    ulong          n_blk
)"
R"() {
)"
R"(    if (get_global_id(0) >= n_blk) {
)"
R"(        return;
)"
R"(    }
)"
R"(    global struct block_q6_K * b = (global struct block_q6_K *) dst + get_global_id(0);
)"
R"(    global uchar * ql = (global uchar *) src_ql + QK_K/2*get_global_id(0);
)"
R"(    global uchar * qh = (global uchar *) src_qh + QK_K/4*get_global_id(0);
)"
R"(    global char  * s  = (global char  *) src_s  + QK_K/16*get_global_id(0);
)"
R"(    global half  * d  = (global half  *) src_d  + get_global_id(0);
)"
R"(
)"
R"(    b->d = *d;
)"
R"(
)"
R"(    for (int i = 0; i < QK_K/2/4; ++i) {
)"
R"(        uchar x0   = ql[i +  0] & mask_lsb_8;
)"
R"(        uchar x1   = ql[i + 32] & mask_lsb_8;
)"
R"(        b->ql[i*2 + 0] = (x0 & 0x0F)        | ((x1 & 0x0F) << 4);
)"
R"(        b->ql[i*2 + 1] = ((x0 & 0xF0) >> 4) | (x1 & 0xF0);
)"
R"(
)"
R"(        uchar x2   = ql[i + 64] & mask_lsb_8;
)"
R"(        uchar x3   = ql[i + 96] & mask_lsb_8;
)"
R"(        b->ql[i*2 + 0 + 64] = (x2 & 0x0F)        | ((x3 & 0x0F) << 4);
)"
R"(        b->ql[i*2 + 1 + 64] = ((x2 & 0xF0) >> 4) | (x3 & 0xF0);
)"
R"(    }
)"
R"(
)"
R"(    for (int i = 0; i < QK_K/4/8; ++i) {
)"
R"(        uchar x0 = qh[i +  0] & mask_lsb_8;
)"
R"(        uchar x1 = qh[i +  8] & mask_lsb_8;
)"
R"(        uchar x2 = qh[i + 16] & mask_lsb_8;
)"
R"(        uchar x3 = qh[i + 24] & mask_lsb_8;
)"
R"(        b->qh[i*4 + 0] = (x0 & 0x03)        | ((x1 & 0x03) << 2) | ((x2 & 0x03) << 4) | ((x3 & 0x03) << 6);
)"
R"(        b->qh[i*4 + 1] = ((x0 & 0x0C) >> 2) | (x1 & 0x0C)        | ((x2 & 0x0C) << 2) | ((x3 & 0x0C) << 4);
)"
R"(        b->qh[i*4 + 2] = ((x0 & 0x30) >> 4) | ((x1 & 0x30) >> 2) | (x2 & 0x30)        | ((x3 & 0x30) << 2);
)"
R"(        b->qh[i*4 + 3] = ((x0 & 0xC0) >> 6) | ((x1 & 0xC0) >> 4) | ((x2 & 0xC0) >> 2) | (x3 & 0xC0);
)"
R"(
)"
R"(        uchar x4 = qh[i +  0 + 32] & mask_lsb_8;
)"
R"(        uchar x5 = qh[i +  8 + 32] & mask_lsb_8;
)"
R"(        uchar x6 = qh[i + 16 + 32] & mask_lsb_8;
)"
R"(        uchar x7 = qh[i + 24 + 32] & mask_lsb_8;
)"
R"(        b->qh[i*4 + 0 + 32] = (x4 & 0x03)        | ((x5 & 0x03) << 2) | ((x6 & 0x03) << 4) | ((x7 & 0x03) << 6);
)"
R"(        b->qh[i*4 + 1 + 32] = ((x4 & 0x0C) >> 2) | (x5 & 0x0C)        | ((x6 & 0x0C) << 2) | ((x7 & 0x0C) << 4);
)"
R"(        b->qh[i*4 + 2 + 32] = ((x4 & 0x30) >> 4) | ((x5 & 0x30) >> 2) | (x6 & 0x30)        | ((x7 & 0x30) << 2);
)"
R"(        b->qh[i*4 + 3 + 32] = ((x4 & 0xC0) >> 6) | ((x5 & 0xC0) >> 4) | ((x6 & 0xC0) >> 2) | (x7 & 0xC0);
)"
R"(    }
)"
R"(
)"
R"(    for (int i = 0; i < QK_K/16; ++i) {
)"
R"(        b->scales[i] = s[i];
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(//------------------------------------------------------------------------------
)"
R"(// kernel_convert_block_iq4_nl
)"
R"(// Convert the block_iq4_nl format to 2 separate arrays (AOS -> SOA).
)"
R"(//------------------------------------------------------------------------------
)"
R"(kernel void kernel_convert_block_iq4_nl(
)"
R"(    global struct block_iq4_nl * src0,
)"
R"(    global uchar * dst_q,
)"
R"(    global half  * dst_d,
)"
R"(    uchar          mask_0F,
)"
R"(    uchar          mask_F0,
)"
R"(    ulong          n_blk
)"
R"() {
)"
R"(    if (get_global_id(0) >= n_blk) {
)"
R"(        return;
)"
R"(    }
)"
R"(    global struct block_iq4_nl * b = (global struct block_iq4_nl *) src0 + get_global_id(0);
)"
R"(    global uchar * q = (global uchar *) dst_q + QK4_NL/2*get_global_id(0);
)"
R"(    global half  * d = (global half *) dst_d + get_global_id(0);
)"
R"(
)"
R"(    *d = b->d;
)"
R"(
)"
R"(    for (int i = 0; i < QK4_NL/2; ++i) {
)"
R"(        q[i] = b->qs[i];
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_restore_block_iq4_nl(
)"
R"(    global uchar * src_q,
)"
R"(    global half  * src_d,
)"
R"(    global struct block_iq4_nl * dst,
)"
R"(    ulong          n_blk
)"
R"() {
)"
R"(    if (get_global_id(0) >= n_blk) {
)"
R"(        return;
)"
R"(    }
)"
R"(    global struct block_iq4_nl * b = (global struct block_iq4_nl *) dst + get_global_id(0);
)"
R"(    global uchar * q = (global uchar *) src_q + QK4_NL/2*get_global_id(0);
)"
R"(    global half  * d = (global half *) src_d + get_global_id(0);
)"
R"(
)"
R"(    b->d = *d;
)"
R"(
)"
R"(    for (int i = 0; i < QK4_NL/2; ++i) {
)"
R"(        b->qs[i] = q[i];
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_convert_block_iq4_nl_noshuffle(
)"
R"(    global struct block_iq4_nl * src0,
)"
R"(    global uchar * dst_q,
)"
R"(    global half  * dst_d,
)"
R"(    uchar          mask_0F,
)"
R"(    uchar          mask_F0,
)"
R"(    ulong          n_blk
)"
R"() {
)"
R"(    if (get_global_id(0) >= n_blk) {
)"
R"(        return;
)"
R"(    }
)"
R"(    global struct block_iq4_nl * b = (global struct block_iq4_nl *) src0 + get_global_id(0);
)"
R"(    global uchar * q = (global uchar *) dst_q + QK4_NL/2*get_global_id(0);
)"
R"(    global half  * d = (global half *) dst_d + get_global_id(0);
)"
R"(
)"
R"(    *d = b->d;
)"
R"(    for (int i = 0; i < QK4_NL/4; ++i) {
)"
R"(        uchar x0 = b->qs[2*i + 0];
)"
R"(        uchar x1 = b->qs[2*i + 1];
)"
R"(
)"
R"(        q[i + 0       ] = convert_uchar(x0 & mask_0F) | convert_uchar((x1 & mask_0F) << 4);
)"
R"(        q[i + QK4_NL/4] = convert_uchar((x0 & mask_F0) >> 4) | convert_uchar(x1 & mask_F0);
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(kernel void kernel_restore_block_iq4_nl_noshuffle(
)"
R"(    global uchar * src_q,
)"
R"(    global half  * src_d,
)"
R"(    global struct block_iq4_nl * dst,
)"
R"(    uchar mask_0F,
)"
R"(    uchar mask_F0,
)"
R"(    ulong n_blk
)"
R"() {
)"
R"(    if (get_global_id(0) >= n_blk) {
)"
R"(        return;
)"
R"(    }
)"
R"(    global struct block_iq4_nl * b = (global struct block_iq4_nl *) dst + get_global_id(0);
)"
R"(    global uchar * q = (global uchar *) src_q + QK4_NL/2*get_global_id(0);
)"
R"(    global half  * d = (global half *) src_d + get_global_id(0);
)"
R"(
)"
R"(    b->d = *d;
)"
R"(    for (int i = 0; i < QK4_NL/4; ++i) {
)"
R"(        uchar x0 = q[i + 0       ];
)"
R"(        uchar x1 = q[i + QK4_NL/4];
)"
R"(
)"
R"(        b->qs[2*i + 0] = convert_uchar((x0 & mask_0F) | ((x1 & mask_0F) << 4));
)"
R"(        b->qs[2*i + 1] = convert_uchar(((x0 & mask_F0) >> 4) | (x1 & mask_F0));
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(// ---------------------------------------------------------------------------
)"
R"(// kernel_moe_expand_scale_q8_0
)"
R"(//
)"
R"(// Expand the q8_0 per-32-block scale d (one half/block, [expert][row][block]) into
)"
R"(// the UNIFORM scale[16] format the generic dp4a MoE GEMM (kernel_gemm_moe_q8_1_dp4a,
)"
R"(// MOE_QT=80) consumes: 16 f16 per 256-superblock (per-16-element segment), where the
)"
R"(// two segments of each 32-block share the block's d. q8_0 is symmetric -> no min
)"
R"(// buffer (the GEMM runs with has_min=0). The int8 weight codes are reused verbatim
)"
R"(// from the existing flat q8_0 weight buffer (extra0_q8_0->q), so only the scale is
)"
R"(// rebuilt here. One work-item per (row, superblock, expert).
)"
R"(// ---------------------------------------------------------------------------
)"
R"(kernel void kernel_moe_expand_scale_q8_0(
)"
R"(    global const half * src_d,      // [expert][row][block], one scale per 32-block
)"
R"(    global       half * dst_scale,  // [expert][row][block][2] (FLAT per-32-block)
)"
R"(    int ne00,
)"
R"(    int ne01
)"
R"() {
)"
R"(    int row = get_global_id(0);
)"
R"(    int blk = get_global_id(1);   // 32-block index along K
)"
R"(    int e   = get_global_id(2);
)"
R"(    if (row >= ne01) { return; }
)"
R"(
)"
R"(    long nb = ne00 / 32;          // 32-blocks per row (K only needs % 32 == 0)
)"
R"(    half d  = src_d[((long)e*ne01 + row)*nb + blk];
)"
R"(    long b  = (((long)e*ne01 + row)*nb + blk) * 2;
)"
R"(    dst_scale[b + 0] = d;
)"
R"(    dst_scale[b + 1] = d;
)"
R"(}
)"
R"(
)"
R"(// ---------------------------------------------------------------------------
)"
R"(// kernel_moe_expand_scale_q5_0
)"
R"(//
)"
R"(// q5_0 = symmetric, value = d*(code-16), code = nibble | (hi<<4) in 0..31. The
)"
R"(// generic dp4a MoE GEMM keeps the unsigned code and centers via the min term:
)"
R"(//   scale*dp4a(code,a) - min*sum(a),  scale = d,  min = d*16.
)"
R"(// Reads the existing q5_0 d ([expert][block][row], one half/32-block, from the
)"
R"(// trans4 convert) and writes the FLAT per-32-block uniform scale[2]/min[1] in
)"
R"(// [expert][row][block] order (a transpose). One work-item per (row, block, expert).
)"
R"(// ---------------------------------------------------------------------------
)"
R"(kernel void kernel_moe_expand_scale_q5_0(
)"
R"(    global const half * src_d,      // [expert][block][row]
)"
R"(    global       half * dst_scale,  // [expert][row][block][2]
)"
R"(    global       half * dst_min,    // [expert][row][block]
)"
R"(    int ne00,
)"
R"(    int ne01
)"
R"() {
)"
R"(    int row = get_global_id(0);
)"
R"(    int blk = get_global_id(1);
)"
R"(    int e   = get_global_id(2);
)"
R"(    if (row >= ne01) { return; }
)"
R"(
)"
R"(    long nb = ne00 / 32;
)"
R"(    half d  = src_d[(long)e*nb*ne01 + (long)blk*ne01 + row];   // [expert][block][row]
)"
R"(    long sb = (((long)e*ne01 + row)*nb + blk) * 2;
)"
R"(    long mb = ((long)e*ne01 + row)*nb + blk;
)"
R"(    dst_scale[sb + 0] = d;
)"
R"(    dst_scale[sb + 1] = d;
)"
R"(    dst_min[mb] = (half)((float)d * 16.0f);
)"
R"(}
)"
R"(
)"
R"(// ---------------------------------------------------------------------------
)"
R"(// kernel_moe_expand_scale_q5_K
)"
R"(//
)"
R"(// q5_K value = d*sv*code + (-dm*mn), with the 6-bit packed per-sub-block scale sv
)"
R"(// and min mn (8 sub-blocks of 32 per 256-superblock, decoded by get_scale_min_k4
)"
R"(// from the 12-byte s[]). The generic dp4a MoE GEMM (kernel_gemm_moe_q8_1_dp4a,
)"
R"(// MOE_QT=5) keeps the unsigned 5-bit code and applies scale/min via the uniform
)"
R"(// per-32-block buffers:
)"
R"(//   acc += sc0*a_d*raw1 + sc1*a_d*raw2 - mn_u*a_s,
)"
R"(//   sc0 = sc1 = d*sv (both per-16 segments of a 32-block share the sub-block scale),
)"
R"(//   mn_u = dm*mn (positive; the GEMM subtracts it -> the -dm*mn min term).
)"
R"(// q5_K's q_img (low nibbles) + qh (hi-bit plane) are already in the layout the GEMM
)"
R"(// reads (same trans4_ns convert that feeds gemm_moe_q5_k_f32_ns), so only the scale
)"
R"(// is rebuilt here.
)"
R"(//
)"
R"(// One work-item per (row, superblock, expert); each emits 8 sub-blocks.
)"
R"(// ---------------------------------------------------------------------------
)"
R"(kernel void kernel_moe_expand_scale_q5_K(
)"
R"(    global const uchar * src_s,     // [expert][row][superblock][12]
)"
R"(    global const half  * src_d,     // [expert][superblock][row]
)"
R"(    global const half  * src_dm,    // [expert][superblock][row]
)"
R"(    global       half  * dst_scale, // [expert][row][32block][2]
)"
R"(    global       half  * dst_min,   // [expert][row][32block]
)"
R"(    int ne00,
)"
R"(    int ne01
)"
R"() {
)"
R"(    int row = get_global_id(0);
)"
R"(    int sb  = get_global_id(1);   // superblock index along K
)"
R"(    int e   = get_global_id(2);
)"
R"(    if (row >= ne01) { return; }
)"
R"(
)"
R"(    long nsb    = ne00 / 256;     // superblocks per row
)"
R"(    long nblk32 = ne00 / 32;      // 32-blocks per row
)"
R"(
)"
R"(    float d  = (float)src_d [((long)e*nsb + sb)*ne01 + row];
)"
R"(    float dm = (float)src_dm[((long)e*nsb + sb)*ne01 + row];
)"
R"(
)"
R"(    __global const uchar * sc = src_s + ((long)e*ne01 + row)*nsb*12 + (long)sb*12;
)"
R"(
)"
R"(    for (int j = 0; j < 8; ++j) {
)"
R"(        uchar sv, mn;
)"
R"(        // get_scale_min_k4 (6-bit packed scale/min for sub-block j of 8)
)"
R"(        if (j < 4) {
)"
R"(            sv = sc[j]   & 63;
)"
R"(            mn = sc[j+4] & 63;
)"
R"(        } else {
)"
R"(            sv = (sc[j+4] & 0x0F) | ((sc[j-4] & 0xC0) >> 2);
)"
R"(            mn = ((sc[j+4] >> 4) & 0x0F) | ((sc[j]   & 0xC0) >> 2);
)"
R"(        }
)"
R"(        long sub   = (long)sb*8 + j;
)"
R"(        long sbase = (((long)e*ne01 + row)*nblk32 + sub) * 2;
)"
R"(        half s_val = (half)(d  * (float)sv);
)"
R"(        dst_scale[sbase + 0] = s_val;
)"
R"(        dst_scale[sbase + 1] = s_val;
)"
R"(        dst_min[((long)e*ne01 + row)*nblk32 + sub] = (half)(dm * (float)mn);
)"
R"(    }
)"
R"(}
)"
