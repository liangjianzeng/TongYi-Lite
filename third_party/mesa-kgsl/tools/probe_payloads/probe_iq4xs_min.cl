// probe_iq4xs_min.cl —— G-734 被测对象：**最小 IQ4_XS 形状 dequant**，只验编译器吃不吃这套结构。
//
// 这不是数值实现，是编译门探针（数值正确性属 G-733 M1 的事）。刻意保留 IQ4 家族真正的编译器表面：
//   ① __constant 码表 + **动态下标**（最容易在移动编译器上翻车的一种访问）
//   ② 4-bit nibble 抽取（vload4 + 移位掩码）
//   ③ 每 8 权重一个超块 scale（GGML IQ4 的 scales 位域玩法）
//   ④ fp32 累加 + local 归约
// 刻意**不做**的（否则一次实验混进多个变量，违反 R5/混淆控制）：不用 `half` 当变量名（那是
// probe_ctrl_half.cl 的对照用途）、不开任何 #pragma EXTENSION、不用 subgroup / dp4a、不用 atomics。
// 简化处：scale 只走 2-bit 路径（真 IQ4_XS 另有 8-bit 扩展档），码表用 IQ4_NL 的 16 值真实码表。
//
// 判读：本文件在两栈（vendor Adreno 与我们自带 Mesa/rusticl）上都应 COMPILE_OK。
// 若阳性对照 probe_ctrl_half.cl 如期 FAIL 而本文件也 FAIL ⇒ 编译门真的挡路，先解门再谈写内核（G-733）。
#define QK_K 256

__constant int grid_iq4[16] = { -8, -7, -6, -5, -4, -3, -2, -1, 0, 1, 2, 3, 4, 5, 6, 7 };

__kernel void probe_iq4xs_min(
        __global const uchar *qs,       // nibble 平面，128 B/块
        __global const uint  *scales,   // 每块一个 uint：32 个 2-bit 超块 scale
        __global const float *x,        // 激活
        __global float       *out,
        const int             nrows) {
    const int row = get_global_id(0);
    if (row >= nrows) return;

    const uint  s   = scales[row];
    __global const uchar *q = qs + (size_t) row * (QK_K / 2);
    float sum = 0.f;

    for (int j = 0; j < QK_K / 8; j++) {                       // 32 个超块
        const int sf = (int) ((s >> (2 * j)) & 3) - 1;         // 2-bit scale（简化档）
        float acc = 0.f;
        for (int i = 0; i < 8; i++) {
            const int  idx = (j * 8 + i) >> 1;
            const int  sh  = ((j * 8 + i) & 1) ? 4 : 0;
            const uint nib = (q[idx] >> sh) & 0xF;
            acc += (float) grid_iq4[nib];                      // ← __constant 动态下标
        }
        sum += (float) sf * acc;
    }
    out[row] = sum * x[row];
}
