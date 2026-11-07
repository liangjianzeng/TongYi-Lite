R"(#pragma OPENCL EXTENSION cl_khr_fp16 : enable
)"
R"(
)"
R"(#ifdef cl_intel_subgroups
)"
R"(#pragma OPENCL EXTENSION cl_intel_subgroups : enable
)"
R"(#else
)"
R"(#pragma OPENCL EXTENSION cl_khr_subgroups : enable
)"
R"(#endif
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
R"(// [dspark 2026-10-17] WG={64,2}=128 on rusticl/ir3 forms ONE 128-lane subgroup
)"
R"(// (vendor pins two 64-lane subgroups via qcom attr; reqd_sub_group_size is
)"
R"(// IGNORED by rusticl, probe4). Kernels that assume 2x64 must therefore:
)"
R"(//  - use get_local_id(0)/get_local_id(1) instead of subgroup lane/id queries,
)"
R"(//  - reduce with a xor-32..1 butterfly: on vendor (sg=64) it is the full
)"
R"(//    subgroup reduce; on rusticl (sg=128, lanes linearized x-fastest) it
)"
R"(//    reduces exactly the 64 lanes of one y-row.
)"
R"(// NOTE: no cl_khr_subgroup_shuffle pragma here — enabling it pulls the QCOM
)"
R"(// enum section of the injected kernel header and collides with build defines.
)"
R"(#ifdef GGML_GENERIC_SUBGROUP_SHUFFLE
)"
R"(// rusticl/freedreno: the injected kernel header exposes no prototype for the
)"
R"(// core CL 3.0 sub_group_shuffle_* builtins (probe2/probe5), and a self-declared
)"
R"(// prototype compiles but fails to lower (err=-6 at the call site). Also, the
)"
R"(// WG={64,2} forms ONE 128-lane subgroup spanning both y-rows, so even a working
)"
R"(// sub_group_reduce_add would mix rows. Reduce via local memory, grouped by the
)"
R"(// get_local_id(1) y-row; x-fastest linearization makes id(0) the in-row lane.
)"
R"(#define GGML_REDUCE64(v) do { \
)"
R"(    const uint gry = get_local_id(1) * 64u + get_local_id(0); \
)"
R"(    ggml_red[gry] = (v); \
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE); \
)"
R"(    if (get_local_id(0) < 32u) ggml_red[gry] += ggml_red[gry + 32u]; \
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE); \
)"
R"(    if (get_local_id(0) < 16u) ggml_red[gry] += ggml_red[gry + 16u]; \
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE); \
)"
R"(    if (get_local_id(0) <  8u) ggml_red[gry] += ggml_red[gry +  8u]; \
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE); \
)"
R"(    if (get_local_id(0) <  4u) ggml_red[gry] += ggml_red[gry +  4u]; \
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE); \
)"
R"(    if (get_local_id(0) <  2u) ggml_red[gry] += ggml_red[gry +  2u]; \
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE); \
)"
R"(    if (get_local_id(0) <  1u) ggml_red[gry] += ggml_red[gry +  1u]; \
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE); \
)"
R"(    (v) = ggml_red[get_local_id(1) * 64u]; \
)"
R"(} while(0)
)"
R"(#else
)"
R"(#define GGML_REDUCE64(v) do { (v) = sub_group_reduce_add((v)); } while(0)
)"
R"(#endif
)"
R"(
)"
R"(
)"
R"(//------------------------------------------------------------------------------
)"
R"(// kernel_mul_mv_q6_K_f32_flat
)"
R"(//------------------------------------------------------------------------------
)"
R"(#define Q6_K_MASK1 0x03
)"
R"(#define Q6_K_MASK2 0x0C
)"
R"(#define Q6_K_MASK3 0x30
)"
R"(#define Q6_K_MASK4 0xC0
)"
R"(
)"
R"(#define QK_K       256
)"
R"(
)"
R"(// ADRENO_OLD_COMPILER is defined by the host (-D) only for the Adreno E031
)"
R"(// compilers older than E031.45, which miscompile several constructs this kernel
)"
R"(// used (confirmed on E031.38 and E031.41; E031.45 is clean). Every other
)"
R"(// compiler -- newer E031, E17, DX, Intel, and every non-Adreno device that
)"
R"(// builds this program -- takes the #else branches, which are the original
)"
R"(// source: the workarounds below cost ~13% on the q6_K flat n=1 GEMV where they
)"
R"(// are not needed.
)"
R"(inline float block_q_6_K_dot_y_flat(
)"
R"(    global uchar * blk_ql,
)"
R"(    global uchar * blk_qh,
)"
R"(    global char  * blk_scales,
)"
R"(    global half  * blk_d,
)"
R"(    int ib,
)"
R"(    int ip,
)"
R"(    int is,
)"
R"(    int l0,
)"
R"(#if defined(ADRENO_OLD_COMPILER)
)"
R"(    int dbg,
)"
R"(#endif
)"
R"(    float4 y0,
)"
R"(    float4 y1,
)"
R"(    float4 y2,
)"
R"(    float4 y3
)"
R"() {
)"
R"(    int q_offset_l =  64*ip + l0;
)"
R"(    int q_offset_h =  32*ip + l0;
)"
R"(
)"
R"(    global uchar * q1 = blk_ql     + ib*128 + q_offset_l;
)"
R"(    global uchar * q2 = q1         + QK_K/8;
)"
R"(    global uchar * qh = blk_qh     + ib*64 + q_offset_h;
)"
R"(
)"
R"(    float dall = blk_d[ib];
)"
R"(
)"
R"(#if defined(ADRENO_OLD_COMPILER)
)"
R"(    // The vectorized dequant (int4/float4 bit-ops, convert_*4, dot()) and vload4
)"
R"(    // are miscompiled here -> garbage weights. Reconstruct the 6-bit weights and
)"
R"(    // take the dot product scalar. q4_K/q5_K flat already use scalar paths, which
)"
R"(    // is why q6_K was the only flat GEMV that failed.
)"
R"(    // Scales are SIGNED int8; read as uchar and sign-extend arithmetically so the
)"
R"(    // result does not depend on whether the compiler treats `char` as signed.
)"
R"(    global uchar * sc = (global uchar *)(blk_scales + ib*16 + is);
)"
R"(
)"
R"(    int s0 = (int)sc[0] - 256*(sc[0] >> 7);
)"
R"(    int s2 = (int)sc[2] - 256*(sc[2] >> 7);
)"
R"(    int s4 = (int)sc[4] - 256*(sc[4] >> 7);
)"
R"(    int s6 = (int)sc[6] - 256*(sc[6] >> 7);
)"
R"(
)"
R"(    // one 6-bit weight: low/high nibble of a ql byte OR'd with a 2-bit qh plane
)"
R"(    // (plane p in {0,1,2,3} selects qh bits 2p..2p+1) placed at bits 4-5, minus 32.
)"
R"(    #define Q6W(qb, sh, hb, p) ((float)((((int)(qb) >> (sh)) & 15) | ((((int)(hb) >> (2*(p))) & 3) << 4)) - 32.f)
)"
R"(
)"
R"(    float d0 = y0.s0*Q6W(q1[0],0,qh[0],0) + y0.s1*Q6W(q1[1],0,qh[1],0) + y0.s2*Q6W(q1[2],0,qh[2],0) + y0.s3*Q6W(q1[3],0,qh[3],0);
)"
R"(    float d1 = y1.s0*Q6W(q2[0],0,qh[0],1) + y1.s1*Q6W(q2[1],0,qh[1],1) + y1.s2*Q6W(q2[2],0,qh[2],1) + y1.s3*Q6W(q2[3],0,qh[3],1);
)"
R"(    float d2 = y2.s0*Q6W(q1[0],4,qh[0],2) + y2.s1*Q6W(q1[1],4,qh[1],2) + y2.s2*Q6W(q1[2],4,qh[2],2) + y2.s3*Q6W(q1[3],4,qh[3],2);
)"
R"(    float d3 = y3.s0*Q6W(q2[0],4,qh[0],3) + y3.s1*Q6W(q2[1],4,qh[1],3) + y3.s2*Q6W(q2[2],4,qh[2],3) + y3.s3*Q6W(q2[3],4,qh[3],3);
)"
R"(    #undef Q6W
)"
R"(
)"
R"(    // [dspark 2026-10-19] runtime-gated printf still makes NIR allocate the
)"
R"(    // device printf buffer; on rusticl the host then reads back a garbage
)"
R"(    // header -> Rust range panic -> abort (K40 a650, kernel.rs:2047). Gate it
)"
R"(    // at compile time as well.
)"
R"(    #ifndef GGML_NO_ADRENO_PRINTF_HACK
)"
R"(    if (dbg) printf("HELPER dall=%f s=[%d %d %d %d] d=[%f %f %f %f] ql0=%d qh0=%d y00=%f\n",
)"
R"(        dall, s0, s2, s4, s6, d0, d1, d2, d3, (int)q1[0], (int)qh[0], y0.s0);
)"
R"(    #endif
)"
R"(
)"
R"(    return dall * (d0 * s0 + d1 * s2 + d2 * s4 + d3 * s6);
)"
R"(#else
)"
R"(    global char * sc = blk_scales + ib*16 + is;
)"
R"(
)"
R"(    // Vectorized loads: 3 uchar4 weight loads instead of 12 scalar byte reads.
)"
R"(    // q_offset_l/h are 4-aligned, so these are aligned vector loads.
)"
R"(    uchar4 q1v = vload4(0, q1);
)"
R"(    uchar4 q2v = vload4(0, q2);
)"
R"(    uchar4 qhv = vload4(0, qh);
)"
R"(
)"
R"(    int4 q1i = convert_int4(q1v);
)"
R"(    int4 q2i = convert_int4(q2v);
)"
R"(    int4 qhi = convert_int4(qhv);
)"
R"(
)"
R"(    // Reconstruct the four 6-bit weight groups (low/high nibble of ql OR'd with the
)"
R"(    // matching 2-bit plane of qh), same arithmetic as the scalar version, then dot()
)"
R"(    // against the cached activation lanes.
)"
R"(    float4 w0 = convert_float4((q1i & 0xF) | ((qhi & Q6_K_MASK1) << 4)) - 32.f;
)"
R"(    float4 w1 = convert_float4((q2i & 0xF) | ((qhi & Q6_K_MASK2) << 2)) - 32.f;
)"
R"(    float4 w2 = convert_float4((q1i >> 4)  | ((qhi & Q6_K_MASK3)     )) - 32.f;
)"
R"(    float4 w3 = convert_float4((q2i >> 4)  | ((qhi & Q6_K_MASK4) >> 2)) - 32.f;
)"
R"(
)"
R"(    return dall * (dot(y0, w0) * sc[0] + dot(y1, w1) * sc[2] +
)"
R"(                   dot(y2, w2) * sc[4] + dot(y3, w3) * sc[6]);
)"
R"(#endif
)"
R"(}
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
R"(#define N_DST 4
)"
R"(#define N_SIMDGROUP 2
)"
R"(#define N_SIMDWIDTH 16
)"
R"(#elif defined (ADRENO_GPU)
)"
R"(#define N_DST 16
)"
R"(#define N_SIMDGROUP 2
)"
R"(#define N_SIMDWIDTH 64
)"
R"(#endif
)"
R"(
)"
R"(#define BLOCK_STRIDE (N_SIMDWIDTH/16) // number of blocks each subgroup processes
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
R"(kernel void kernel_mul_mv_q6_K_f32_flat(
)"
R"(        global uchar * src0_ql,
)"
R"(        global uchar * src0_qh,
)"
R"(        global char  * src0_s,
)"
R"(        global half  * src0_d,
)"
R"(        global float * src1,
)"
R"(        ulong offset1,
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
R"(        int ne10,
)"
R"(        int ne12,
)"
R"(        int ne0,
)"
R"(        int ne1,
)"
R"(        int r2,
)"
R"(        int r3
)"
R"(#if defined(ADRENO_OLD_COMPILER)
)"
R"(        ,
)"
R"(        uchar q6k_mask   // runtime 0xFF; the host passes it so the compiler cannot
)"
R"(                         // constant-fold the printf guards below into nothing
)"
R"(#endif
)"
R"() {
)"
R"(    src1 = (global float*)((global char*)src1 + offset1);
)"
R"(    dst = (global float*)((global char*)dst + offsetd);
)"
R"(
)"
R"(    int nb = ne00/QK_K;
)"
R"(
)"
R"(    // scratch for the rusticl row reduction (must be at kernel function scope)
)"
R"(    __local float ggml_red[128];
)"
R"(
)"
R"(    int r0 = get_group_id(0);
)"
R"(    int r1 = get_group_id(1);
)"
R"(    int im = get_group_id(2);
)"
R"(
)"
R"(    int i12 = im%ne12;
)"
R"(    int i13 = im/ne12;
)"
R"(
)"
R"(    int first_row = (N_SIMDGROUP * r0 + get_local_id(1)) * N_DST;
)"
R"(
)"
R"(#if defined(ADRENO_OLD_COMPILER)
)"
R"(    // 64-bit `ulong` integer arithmetic is miscompiled here -> the base-pointer byte
)"
R"(    // offsets came out wrong, so EVERY weight/scale read hit the wrong address. This
)"
R"(    // was the primary cause of the q6_K flat failure (q5_K uses int offsets and is
)"
R"(    // unaffected). Compute the block index in `int` and widen to `ulong` only inside
)"
R"(    // the pointer expression: the byte offset stays 64-bit, but there is no ulong
)"
R"(    // arithmetic chain to miscompile. The int index would overflow past ~2^31 blocks,
)"
R"(    // which no realistic weight reaches -- but that is a narrowing, so keep it off the
)"
R"(    // conformant path, which retains full ulong arithmetic.
)"
R"(    int offset_src0 = first_row*nb + (i12/r2)*(nb*ne01) + (i13/r3)*(nb*ne01*ne02);
)"
R"(
)"
R"(    global uchar * blk_ql     = (global uchar *) src0_ql + (ulong)offset_src0 * 128;
)"
R"(    global uchar * blk_qh     = (global uchar *) src0_qh + (ulong)offset_src0 * 64;
)"
R"(    global char  * blk_scales = (global char  *) src0_s  + (ulong)offset_src0 * 16;
)"
R"(    global half  * blk_d      = (global half  *) src0_d  + offset_src0;
)"
R"(#else
)"
R"(    ulong offset_src0    = first_row*nb + (i12/r2)*(nb*ne01) + (i13/r3)*(nb*ne01*ne02);
)"
R"(    ulong offset_src0_ql = offset_src0 * 128;
)"
R"(    ulong offset_src0_qh = offset_src0 * 64;
)"
R"(    ulong offset_src0_s  = offset_src0 * 16;
)"
R"(    ulong offset_src0_d  = offset_src0;
)"
R"(
)"
R"(    global uchar * blk_ql     = (global uchar *) src0_ql + offset_src0_ql;
)"
R"(    global uchar * blk_qh     = (global uchar *) src0_qh + offset_src0_qh;
)"
R"(    global char  * blk_scales = (global char  *) src0_s  + offset_src0_s;
)"
R"(    global half  * blk_d      = (global half  *) src0_d  + offset_src0_d;
)"
R"(#endif
)"
R"(    global float * yy         = (global float *) src1    + r1*ne10 + im*ne00*ne1;
)"
R"(
)"
R"(    int tid = get_local_id(0)%(N_SIMDWIDTH/BLOCK_STRIDE); // within-super-block part, 0..15
)"
R"(    int ix  = get_local_id(0)/(N_SIMDWIDTH/BLOCK_STRIDE); // super-block selector, 0..BLOCK_STRIDE-1
)"
R"(    int ip  = tid/8;   // first or second half of (super) block (0 or 1)
)"
R"(    int il  = tid%8;   // each half has 8 parts, one per scale
)"
R"(    int n   = 4;       // 4 scales at a time (and 4 sums)
)"
R"(    int l0  = n*il;    // offset into half-block, 0..28
)"
R"(    int is  = 8*ip + l0/16; // 0, 1, 8, 9
)"
R"(
)"
R"(    float sumf[N_DST];
)"
R"(    for (int row = 0; row < N_DST; row++) {
)"
R"(        sumf[row] = 0.f;
)"
R"(    }
)"
R"(
)"
R"(    for (int ib = ix; ib < nb; ib += BLOCK_STRIDE) {
)"
R"(        global float * y = yy + ib * QK_K + 128*ip + l0;
)"
R"(#if defined(ADRENO_OLD_COMPILER)
)"
R"(        // vload4 of f32 is miscompiled here; index the lanes scalar instead.
)"
R"(        float4 y0 = (float4)(y[ 0], y[ 1], y[ 2], y[ 3]);
)"
R"(        float4 y1 = (float4)(y[32], y[33], y[34], y[35]);
)"
R"(        float4 y2 = (float4)(y[64], y[65], y[66], y[67]);
)"
R"(        float4 y3 = (float4)(y[96], y[97], y[98], y[99]);
)"
R"(#else
)"
R"(        float4 y0 = vload4(0, y +  0);
)"
R"(        float4 y1 = vload4(0, y + 32);
)"
R"(        float4 y2 = vload4(0, y + 64);
)"
R"(        float4 y3 = vload4(0, y + 96);
)"
R"(#endif
)"
R"(
)"
R"(        for (int row = 0; row < N_DST; row++) {
)"
R"(            if (first_row + row < ne01) {
)"
R"(#if defined(ADRENO_OLD_COMPILER)
)"
R"(                int dbg = (q6k_mask==0xFE && r0==0 && r1==0 && im==0 && row==0 && ib==0 &&
)"
R"(                           ne00==256 && ne01==16 && get_local_id(0)==0) ? 1 : 0;
)"
R"(                sumf[row] += block_q_6_K_dot_y_flat(
)"
R"(                    blk_ql + row*nb*128, blk_qh + row*nb*64, blk_scales + row*nb*16, blk_d + row*nb,
)"
R"(                    ib, ip, is, l0, dbg, y0, y1, y2, y3);
)"
R"(#else
)"
R"(                sumf[row] += block_q_6_K_dot_y_flat(
)"
R"(                    blk_ql + row*nb*128, blk_qh + row*nb*64, blk_scales + row*nb*16, blk_d + row*nb,
)"
R"(                    ib, ip, is, l0, y0, y1, y2, y3);
)"
R"(#endif
)"
R"(            }
)"
R"(        }
)"
R"(    }
)"
R"(
)"
R"(#if defined(ADRENO_OLD_COMPILER)
)"
R"(    // Optimizer barrier. This compiler drops the sumf partials unless a side effect
)"
R"(    // forces them to materialize. q6k_mask is a kernel arg the compiler cannot prove
)"
R"(    // is never 0xFE (the host always passes 0xFF), so the printf survives compilation
)"
R"(    // but never executes. FRAGILE: the exact set and placement of these guarded
)"
R"(    // printfs is load-bearing on E031.41 -- removing any one re-breaks q6_K.
)"
R"(    if (q6k_mask==0xFE && r0==0 && r1==0 && im==0 && ne00==256 && ne01==16 && get_local_id(0)<16) {
)"
R"(        printf("Q6KLANE lane=%d ip=%d il=%d is=%d l0=%d sumf0=%f\n",
)"
R"(            get_local_id(0), ip, il, is, l0, sumf[0]);
)"
R"(    }
)"
R"(#endif
)"
R"(    for (int row = 0; row < N_DST; row++) {
)"
R"(        float tot = sumf[row]; GGML_REDUCE64(tot);
)"
R"(        if (get_local_id(0) == 0 && first_row + row < ne01) {
)"
R"(            dst[r1*ne0 + im*ne0*ne1 + first_row + row] = tot;
)"
R"(#if defined(ADRENO_OLD_COMPILER)
)"
R"(            if (q6k_mask==0xFE && r0==0 && r1==0 && im==0 && row==0 && ne00==256 && ne01==16)
)"
R"(                printf("Q6KTOT tot=%f\n", tot);
)"
R"(#endif
)"
R"(        }
)"
R"(    }
)"
R"(}
)"
