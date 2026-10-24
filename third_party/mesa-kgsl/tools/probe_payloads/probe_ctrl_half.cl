// probe_ctrl_half.cl —— **阳性对照**（不是被测对象，是"探针自己有没有牙"的证据）
//
// AGENTS 血泪：Adreno OpenCL 编译器把 `half` 保留为类型说明符，当变量名用即
// clBuildProgram 失败 err=-11 "cannot combine with previous 'int' declaration specifier"。
// 本文件在 Adreno 上**必须** COMPILE_FAIL；若在 rusticl/freedreno 上 COMPILE_OK 而 Adreno 也 OK，
// 说明**探针没能力复现已知故障 = 探针无效**，那么本轮所有编译门结论一律作废（R8 型：永远不会失败的闸）。
__kernel void probe_ctrl_half(__global const float *a, __global float *o) {
    int gid = get_global_id(0);
    int kt  = gid & 7;
    const int half = kt & 1;          // ← 已知杀手：变量名叫 half
    float s = 0.f;
    for (int i = 0; i < 32; i++) s += a[gid * 32 + i] * (half ? 1.f : -1.f);
    o[gid] = s;
}
