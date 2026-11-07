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
R"(//------------------------------------------------------------------------------
)"
R"(// block_q3_K
)"
R"(//------------------------------------------------------------------------------
)"
R"(#define QK_K 256
)"
R"(
)"
R"(// 16 blocks of 16 elements each
)"
R"(// weight is represented as x = a * q
)"
R"(typedef struct {
)"
R"(    uchar hmask[QK_K/8]; // quants - high bit
)"
R"(    uchar qs[QK_K/4];    // quants - low 2 bits
)"
R"(    uchar scales[12];    // scales, quantized with 6 bits
)"
R"(    half  d;             // super-block scale
)"
R"(} block_q3_K;
)"
R"(
)"
R"(#undef N_DST
)"
R"(#undef N_SIMDGROUP
)"
R"(#undef N_SIMDWIDTH
)"
R"(
)"
R"(#ifdef INTEL_GPU
)"
R"(#define N_DST 2 // number of rows each SIMD group works on
)"
R"(#define N_SIMDGROUP 1 // number of SIMD groups in a thread group
)"
R"(#define N_SIMDWIDTH 16 // SIMD group size
)"
R"(#elif defined (ADRENO_GPU)
)"
R"(#define N_DST 2
)"
R"(#define N_SIMDGROUP 1
)"
R"(#define N_SIMDWIDTH 64
)"
R"(#endif
)"
R"(
)"
R"(#undef  BLOCK_STRIDE
)"
R"(// 8 threads cover one super block, so a wave covers N_SIMDWIDTH/8 of them
)"
R"(#define BLOCK_STRIDE (N_SIMDWIDTH/8)
)"
R"(
)"
R"(#ifdef INTEL_GPU
)"
R"(REQD_SUBGROUP_SIZE_16
)"
R"(#elif defined (ADRENO_GPU)
)"
R"(REQD_SUBGROUP_SIZE_64
)"
R"(#endif
)"
R"(kernel void kernel_mul_mv_q3_K_f32(
)"
R"(        global char * src0,
)"
R"(        ulong offset0,
)"
R"(        global char * src1,
)"
R"(        ulong offset1,
)"
R"(        global char * dst,
)"
R"(        ulong offsetd,
)"
R"(        int ne00,
)"
R"(        int ne01,
)"
R"(        ulong nb01,
)"
R"(        ulong nb02,
)"
R"(        ulong nb03,
)"
R"(        int ne12,
)"
R"(        ulong nb11,
)"
R"(        ulong nb12,
)"
R"(        ulong nb13,
)"
R"(        int ne0,
)"
R"(        int ne1,
)"
R"(        int r2,
)"
R"(        int r3
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
R"(    int nb = ne00/QK_K;
)"
R"(
)"
R"(    int r0 = get_group_id(0);
)"
R"(    int r1 = get_group_id(1);
)"
R"(    int im = get_group_id(2);
)"
R"(    int first_row = (r0 * N_SIMDGROUP + get_sub_group_id()) * N_DST;
)"
R"(
)"
R"(    int i12 = im%ne12;
)"
R"(    int i13 = im/ne12;
)"
R"(
)"
R"(    ulong offset_src0 = first_row*nb01 + (i12/r2)*nb02 + (i13/r3)*nb03;
)"
R"(    ulong offset_src1 =        r1*nb11 + (i12   )*nb12 + (i13   )*nb13;
)"
R"(
)"
R"(    global block_q3_K * x  = (global block_q3_K *) (src0 + offset_src0);
)"
R"(    global float      * yy = (global float      *) (src1 + offset_src1);
)"
R"(
)"
R"(    float yl[32];
)"
R"(
)"
R"(    // Eight lanes cover one super-block.
)"
R"(    int ix  = get_sub_group_local_id() % BLOCK_STRIDE;
)"
R"(    int tid = get_sub_group_local_id() / BLOCK_STRIDE;
)"
R"(
)"
R"(    int ip = tid/4;         // 0 or 1
)"
R"(    int il = 2*((tid%4)/2); // 0 or 2
)"
R"(    int ir = tid%2;
)"
R"(    int l0 = 8*ir;
)"
R"(
)"
R"(    // Shift the masks instead of indexing private arrays to avoid spills.
)"
R"(    ushort4 hm = (ushort4)(0x0001, 0x0100, 0x0002, 0x0200) << (ushort4)(2*(2*ip + il/2));
)"
R"(    int4    qm = (int4)   (0x0003, 0x0300, 0x000c, 0x0c00) << (int4)   (4*(il/2));
)"
R"(
)"
R"(    int shift = 2*il;
)"
R"(
)"
R"(    float v1 = il == 0 ? 4.f : 64.f;
)"
R"(    float v2 = 4.f * v1;
)"
R"(
)"
R"(    int s_shift1 = 4*ip;
)"
R"(    int s_shift2 = s_shift1 + il;
)"
R"(
)"
R"(    int q_offset = 32*ip + l0;
)"
R"(    int y_offset = 128*ip + 32*il + l0;
)"
R"(
)"
R"(    global float * y1 = yy + ix*QK_K + y_offset;
)"
R"(
)"
R"(    float sumf1[N_DST] = {0.f};
)"
R"(    float sumf2[N_DST] = {0.f};
)"
R"(    float all_sum;
)"
R"(
)"
R"(    for (int i = ix; i < nb; i += BLOCK_STRIDE) {
)"
R"(        for (int l = 0; l < 8; ++l) {
)"
R"(            yl[l+ 0] = y1[l+ 0];
)"
R"(            yl[l+ 8] = y1[l+16];
)"
R"(            yl[l+16] = y1[l+32];
)"
R"(            yl[l+24] = y1[l+48];
)"
R"(        }
)"
R"(
)"
R"(        global ushort * q = (global ushort *)(x[i].qs + q_offset);
)"
R"(        global ushort * h = (global ushort *)(x[i].hmask + l0);
)"
R"(        global ushort * a = (global ushort *)(x[i].scales);
)"
R"(        global half   * dh = &x[i].d;
)"
R"(
)"
R"(        // only ne01 output rows exist; reading past them can pull in an inf scale
)"
R"(        for (int row = 0; row < N_DST && first_row + row < ne01; ++row) {
)"
R"(            float d_all = dh[0];
)"
R"(
)"
R"(            uint s32   = (uint)a[4] | ((uint)a[5] << 16);
)"
R"(            uint aux32 = ((s32 >> s_shift2) << 4) & 0x30303030u;
)"
R"(            s32 = (uint)a[il+0] | ((uint)a[il+1] << 16);
)"
R"(            s32 = ((s32 >> s_shift1) & 0x0f0f0f0fu) | aux32;
)"
R"(            char4 sc = as_char4(s32);
)"
R"(
)"
R"(            float s1 = 0, s2 = 0, s3 = 0, s4 = 0, s5 = 0, s6 = 0;
)"
R"(            for (int l = 0; l < 8; l += 2) {
)"
R"(                int qs = q[l/2];
)"
R"(                s1 += yl[l+0] * (qs & qm.s0);
)"
R"(                s2 += yl[l+1] * (qs & qm.s1);
)"
R"(                s3 += ((h[l/2] & hm.s0) ? 0.f : yl[l+0]) + ((h[l/2] & hm.s1) ? 0.f : yl[l+1]);
)"
R"(                s4 += yl[l+16] * (qs & qm.s2);
)"
R"(                s5 += yl[l+17] * (qs & qm.s3);
)"
R"(                s6 += ((h[l/2] & hm.s2) ? 0.f : yl[l+16]) + ((h[l/2] & hm.s3) ? 0.f : yl[l+17]);
)"
R"(            }
)"
R"(            float d1 = d_all * (s1 + 1.f/256.f * s2 - s3*v1);
)"
R"(            float d2 = d_all * (s4 + 1.f/256.f * s5 - s6*v2);
)"
R"(            sumf1[row] += d1 * (sc.s0 - 32);
)"
R"(            sumf2[row] += d2 * (sc.s2 - 32);
)"
R"(
)"
R"(            s1 = s2 = s3 = s4 = s5 = s6 = 0;
)"
R"(            for (int l = 0; l < 8; l += 2) {
)"
R"(                int qs = q[l/2+8];
)"
R"(                s1 += yl[l+8] * (qs & qm.s0);
)"
R"(                s2 += yl[l+9] * (qs & qm.s1);
)"
R"(                s3 += ((h[l/2+8] & hm.s0) ? 0.f : yl[l+8]) + ((h[l/2+8] & hm.s1) ? 0.f : yl[l+9]);
)"
R"(                s4 += yl[l+24] * (qs & qm.s2);
)"
R"(                s5 += yl[l+25] * (qs & qm.s3);
)"
R"(                s6 += ((h[l/2+8] & hm.s2) ? 0.f : yl[l+24]) + ((h[l/2+8] & hm.s3) ? 0.f : yl[l+25]);
)"
R"(            }
)"
R"(            d1 = d_all * (s1 + 1.f/256.f * s2 - s3*v1);
)"
R"(            d2 = d_all * (s4 + 1.f/256.f * s5 - s6*v2);
)"
R"(            sumf1[row] += d1 * (sc.s1 - 32);
)"
R"(            sumf2[row] += d2 * (sc.s3 - 32);
)"
R"(
)"
R"(            q  += nb01/2;
)"
R"(            h  += nb01/2;
)"
R"(            a  += nb01/2;
)"
R"(            dh += nb01/2;
)"
R"(        }
)"
R"(
)"
R"(        y1 += BLOCK_STRIDE * QK_K;
)"
R"(    }
)"
R"(
)"
R"(    global float * dst_f32 = (global float *) dst + im*ne0*ne1 + r1*ne0;
)"
R"(
)"
R"(    for (int row = 0; row < N_DST; ++row) {
)"
R"(        all_sum = sub_group_reduce_add((sumf1[row] + 0.25f * sumf2[row]) / (1 << shift));
)"
R"(        if (first_row + row < ne01) {
)"
R"(            if (get_sub_group_local_id() == 0) {
)"
R"(                dst_f32[first_row + row] = all_sum;
)"
R"(            }
)"
R"(        }
)"
R"(    }
)"
R"(}
)"
