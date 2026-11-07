R"(#pragma OPENCL EXTENSION cl_khr_fp16 : enable
)"
R"(#pragma OPENCL EXTENSION cl_khr_subgroups : enable
)"
R"(
)"
R"(// [dspark 2026-10-14] SGB bitcast shims. Host passes -DSGB_FLOAT_BROKEN when
)"
R"(// the driver's online compiler lacks float overloads of sub_group_broadcast
)"
R"(// (Adreno 740: only scalar uint/int/long/ulong exist). Bitcast float<->uint,
)"
R"(// broadcast as integer, cast back — bitwise identical, subgroup-uniform.
)"
R"(// [dspark 2026-10-14] Scalar-float subgroup broadcast. 740's online compiler
)"
R"(// lacks float overloads of sub_group_broadcast entirely -> host passes
)"
R"(// -DSGB_SCALAR_BROKEN and broadcasts go through the uint-bitcast shim.
)"
R"(// 830 (E031.47) has working float broadcast but miscompiles kernels whose
)"
R"(// broadcasts go through an inline wrapper, even in pass-through form
)"
R"(// (NMSE~2.2, 2026-10-14) -> uses the direct builtin. All call sites are
)"
R"(// per-component scalar: no vector broadcast anywhere.
)"
R"(#ifdef SGB_SCALAR_BROKEN
)"
R"(inline float sgb_f(float v, uint lid) {
)"
R"(    return as_float(sub_group_broadcast(as_uint(v), lid));
)"
R"(}
)"
R"(#define SGB_BC(v, lid) sgb_f(v, lid)
)"
R"(#else
)"
R"(#define SGB_BC(v, lid) sub_group_broadcast(v, lid)
)"
R"(#endif
)"
R"(
)"
R"(#ifdef cl_qcom_reqd_sub_group_size
)"
R"(#pragma OPENCL EXTENSION cl_qcom_reqd_sub_group_size : enable
)"
R"(#define ADRENO_GPU 1
)"
R"(#define REQD_SUBGROUP_SIZE_64 __attribute__((qcom_reqd_sub_group_size("half")))
)"
R"(#endif
)"
R"(
)"
R"(// the driver's online compiler lacks float overloads of sub_group_broadcast
)"
R"(// (Adreno 740: only scalar uint/int/long/ulong exist). Bitcast float<->uint,
)"
R"(// broadcast as integer, cast back — bitwise identical, subgroup-uniform.
)"
R"(#define QK4_0 32
)"
R"(#define N_SIMDGROUP 4
)"
R"(
)"
R"(#define dequantizeBlockAccum_ila_1row_hi(total_sum, bits4, scale, y) \
)"
R"(    float shared_y; \
)"
R"(    shared_y = SGB_BC(y.s0, 0); \
)"
R"(    total_sum += ((bits4.s0 & 0x000F) - 8) * scale * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s1, 0); \
)"
R"(    total_sum += (((bits4.s0 & 0x00F0) >> 4) - 8) * scale * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s2, 0); \
)"
R"(    total_sum += (((bits4.s0 & 0x0F00) >> 8) - 8) * scale * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s3, 0); \
)"
R"(    total_sum += (((bits4.s0 & 0xF000) >> 12) - 8) * scale * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s4, 0); \
)"
R"(    total_sum += ((bits4.s1 & 0x000F) - 8) * scale * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s5, 0); \
)"
R"(    total_sum += (((bits4.s1 & 0x00F0) >> 4) - 8) * scale * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s6, 0); \
)"
R"(    total_sum += (((bits4.s1 & 0x0F00) >> 8) - 8) * scale * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s7, 0); \
)"
R"(    total_sum += (((bits4.s1 & 0xF000) >> 12) - 8) * scale * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s0, 1); \
)"
R"(    total_sum += ((bits4.s2 & 0x000F) - 8) * scale * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s1, 1); \
)"
R"(    total_sum += (((bits4.s2 & 0x00F0) >> 4) - 8) * scale * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s2, 1); \
)"
R"(    total_sum += (((bits4.s2 & 0x0F00) >> 8) - 8) * scale * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s3, 1); \
)"
R"(    total_sum += (((bits4.s2 & 0xF000) >> 12) - 8) * scale * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s4, 1); \
)"
R"(    total_sum += ((bits4.s3 & 0x000F) - 8) * scale * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s5, 1); \
)"
R"(    total_sum += (((bits4.s3 & 0x00F0) >> 4) - 8) * scale * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s6, 1); \
)"
R"(    total_sum += (((bits4.s3 & 0x0F00) >> 8) - 8) * scale * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s7, 1); \
)"
R"(    total_sum += (((bits4.s3 & 0xF000) >> 12) - 8) * scale * shared_y;
)"
R"(
)"
R"(#define dequantizeBlockAccum_ila_1row_lo(total_sum, bits4, scale, y) \
)"
R"(    shared_y = SGB_BC(y.s0, 2); \
)"
R"(    total_sum += ((bits4.s4 & 0x000F) - 8) * scale * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s1, 2); \
)"
R"(    total_sum += (((bits4.s4 & 0x00F0) >> 4) - 8) * scale * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s2, 2); \
)"
R"(    total_sum += (((bits4.s4 & 0x0F00) >> 8) - 8) * scale * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s3, 2); \
)"
R"(    total_sum += (((bits4.s4 & 0xF000) >> 12) - 8) * scale * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s4, 2); \
)"
R"(    total_sum += ((bits4.s5 & 0x000F) - 8) * scale * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s5, 2); \
)"
R"(    total_sum += (((bits4.s5 & 0x00F0) >> 4) - 8) * scale * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s6, 2); \
)"
R"(    total_sum += (((bits4.s5 & 0x0F00) >> 8) - 8) * scale * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s7, 2); \
)"
R"(    total_sum += (((bits4.s5 & 0xF000) >> 12) - 8) * scale * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s0, 3); \
)"
R"(    total_sum += ((bits4.s6 & 0x000F) - 8) * scale * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s1, 3); \
)"
R"(    total_sum += (((bits4.s6 & 0x00F0) >> 4) - 8) * scale * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s2, 3); \
)"
R"(    total_sum += (((bits4.s6 & 0x0F00) >> 8) - 8) * scale * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s3, 3); \
)"
R"(    total_sum += (((bits4.s6 & 0xF000) >> 12) - 8) * scale * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s4, 3); \
)"
R"(    total_sum += ((bits4.s7 & 0x000F) - 8) * scale * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s5, 3); \
)"
R"(    total_sum += (((bits4.s7 & 0x00F0) >> 4) - 8) * scale * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s6, 3); \
)"
R"(    total_sum += (((bits4.s7 & 0x0F00) >> 8) - 8) * scale * shared_y; \
)"
R"(    shared_y = SGB_BC(y.s7, 3); \
)"
R"(    total_sum += (((bits4.s7 & 0xF000) >> 12) - 8) * scale * shared_y;
)"
R"(
)"
R"(
)"
R"(#ifdef ADRENO_GPU
)"
R"(REQD_SUBGROUP_SIZE_64
)"
R"(#endif
)"
R"(__kernel void kernel_gemv_noshuffle_q4_0_f32_32b_trans(
)"
R"(        __read_only  image1d_buffer_t src0_q,
)"
R"(        global half  * src0_d,
)"
R"(        __read_only  image1d_buffer_t src1,
)"
R"(        global float * dst,
)"
R"(        ulong offsetd,
)"
R"(        int ne00,
)"
R"(        int ne01)
)"
R"({
)"
R"(    uint groupId = get_local_id(1);
)"
R"(    uint gid     = get_global_id(0);
)"
R"(    ushort slid  = get_sub_group_local_id();
)"
R"(
)"
R"(    uint K = ne00;
)"
R"(    uint M = ne01;
)"
R"(
)"
R"(    __private uint4  regA;
)"
R"(    __private half   regS;
)"
R"(    __private float8 regB;
)"
R"(    __private float  totalSum = 0.0f;
)"
R"(
)"
R"(    for (uint k = groupId; k < (K / QK4_0); k += N_SIMDGROUP) {
)"
R"(        regS = src0_d[k * M + gid];
)"
R"(        if (slid < 4) {
)"
R"(            regB.s0123 = read_imagef(src1, (slid * 2 + k * 8));
)"
R"(            regB.s4567 = read_imagef(src1, (1 + slid * 2 + k * 8));
)"
R"(        }
)"
R"(        regA.s0 = read_imageui(src0_q, ((k * 4 + 0) * M + gid)).x;
)"
R"(        regA.s1 = read_imageui(src0_q, ((k * 4 + 1) * M + gid)).x;
)"
R"(        regA.s2 = read_imageui(src0_q, ((k * 4 + 2) * M + gid)).x;
)"
R"(        regA.s3 = read_imageui(src0_q, ((k * 4 + 3) * M + gid)).x;
)"
R"(
)"
R"(        dequantizeBlockAccum_ila_1row_hi(totalSum, as_ushort8(regA), regS, regB);
)"
R"(        dequantizeBlockAccum_ila_1row_lo(totalSum, as_ushort8(regA), regS, regB);
)"
R"(    }
)"
R"(
)"
R"(    __local float reduceLM[SIMDGROUP_WIDTH * 3];
)"
R"(    if (groupId == 1) reduceLM[SIMDGROUP_WIDTH * 0 + slid] = totalSum;
)"
R"(    if (groupId == 2) reduceLM[SIMDGROUP_WIDTH * 1 + slid] = totalSum;
)"
R"(    if (groupId == 3) reduceLM[SIMDGROUP_WIDTH * 2 + slid] = totalSum;
)"
R"(    barrier(CLK_LOCAL_MEM_FENCE);
)"
R"(    if (groupId == 0) totalSum += reduceLM[SIMDGROUP_WIDTH * 0 + slid];
)"
R"(    if (groupId == 0) totalSum += reduceLM[SIMDGROUP_WIDTH * 1 + slid];
)"
R"(    if (groupId == 0) totalSum += reduceLM[SIMDGROUP_WIDTH * 2 + slid];
)"
R"(
)"
R"(    if (groupId == 0) {
)"
R"(        dst = (global float*)((global char*)dst + offsetd);
)"
R"(        if (gid < M) {
)"
R"(            dst[gid] = totalSum;
)"
R"(        }
)"
R"(    }
)"
R"(}
)"
