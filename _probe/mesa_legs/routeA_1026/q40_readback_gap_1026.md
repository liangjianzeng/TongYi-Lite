# q4_0 batched×3 readback 缺口 · 静态读码报告（真 Mesa 验证腿设计前置）

日期：2026-10-26 · 分析员：ZCode Explore（只读）· 台账锚点：leg-032（docs/全GPU卸载_执行记录_2026-10-25.md:904-915）
简称：OCL = third_party/llama.cpp/ggml/src/ggml-opencl/ggml-opencl.cpp；RT = 同目录 tongyi_route_table.cpp；P4 = _probe/moe_probe/moe_probe4.cpp；LOG = docs/全GPU卸载_执行记录_2026-10-25.md

---

## 1. q4_0 dense-loop 路径与 "plane" 机制（正向写入 / 反向 restore / 转置来源）

### 1.1 plane = set_tensor 期把 block_q4_0 拆成的两条 SoA 平面缓冲（d 前 q 后）
set_tensor 的 q4_0 分支把权重拆成 scales(d, fp16/块) 与 quants(q, 16bit 打包 nibble) 两个子区间（OCL:11926-11929）：

    region.origin = align_to(extra_orig->offset + tensor->view_offs + offset, backend_ctx->alignment);
    region.size = size_d;
    extra->d = clCreateSubBuffer(

（OCL:11935-11937）：

    region.origin = align_to(previous_origin + size_d, backend_ctx->alignment);
    region.size = size_q;
    extra->q = clCreateSubBuffer(

即"plane" = extra->d / extra->q 两条扁平设备平面（同一 data_device 上先后两段）。batched MoE 计算核直接消费它们（OCL:26005-26006 运行时门）：

    if (is_q4_0 && (!pextra40 || !pextra40->q || !pextra40->d)) {
        ggml_cl_mmid_gate_fail(2, "planes_q4_0", src0, src1, src2, "extra q/d missing");

（OCL:26136-26137 取指针：q4_0 用一条 d plane。）

### 1.2 dense-loop 转置写入 = set_tensor MoE 分支（已出守卫，OFF 构建照跑）
OCL:11943-11945 —— 命中条件 = 名字含 ffn+exps（RT:116）且 dense_loop_type(q4_0)=true（RT:124-130，默认 true）：

    if (use_adreno_moe_kernels(backend_ctx, tensor) && moe_use_dense_loop(tensor->type)) {
        // [TYL sweep] dense-loop storage layout hoisted OUT of the Adreno
        // guard: matches the unguarded dense_loop dispatch at MUL_MAT_ID.

先 noshuffle convert（OCL:11951 kernel_convert_block_q4_0_noshuffle），再按专家层原地转置 q/d（OCL:11987-11988，kernel_transpose_16_buf，前向 stride=K/4、rows=M）：

    transpose_2d_as_16b(backend_ctx, q_e, q_e, q_layer, Kc/4,  Mc);
    transpose_2d_as_16b(backend_ctx, d_e, d_e, d_layer, Kc/32, Mc);

转置有对齐前置门（OCL:11979-11981）：Mc%4==0 且 q_layer/d_layer 均 % alignment==0；不满足则不转置、留 row-major noshuffle。该分支在 GGML_OPENCL_USE_ADRENO_KERNELS 守卫之外（[TYL sweep]），且 use_adreno_moe_kernels 是运行期判定（OCL:10171-10181 → RT moe_admission_gate RT:110-121）——所以 Mesa OFF 构建（_probe/moe_probe/build-android-cli-noadreno/CMakeCache.txt:549 "GGML_OPENCL_USE_ADRENO_KERNELS:BOOL=OFF"）里 set_tensor 仍写"层内转置 plane"。

### 1.3 restore（读回时从 plane 还原原字节）在哪触发、哪个臂被守卫吃了
get_tensor q4_0 入口 OCL:14080；KV q4_0 AoS 直读不触 plane（OCL:14081-14082）。三个还原臂：

臂①（dense-loop MoE 反旋转 restore，守卫内）OCL:14094：

    #ifdef GGML_OPENCL_USE_ADRENO_KERNELS  // R-029b RE-GUARDED: OFF probe showed the dense-loop MoE restore arm corrupts batched q4_0 weights under Mesa (post-readback compute NMSE 0.53 vs 0.0 pre); its readback FAILs in ON too (pre-existing defect). trans4+plane arms as before.

OCL:14101 条件、OCL:14123-14125 反旋转：

    // inverse of the forward (stride=K/4, rows=M) transpose
    transpose_2d_as_16b(backend_ctx, q_e, q_t, q_layer, M, K/4);
    transpose_2d_as_16b(backend_ctx, d_e, d_t, d_layer, M, K/32);

OCL:14138 kernel_restore_block_q4_0_noshuffle 还原块 + OCL:14146 读出。
臂②（vendor trans4_ns）OCL:14150-14177，守卫内（OCL:14178 "#endif // R-029: ADRENO guard closed (trans4/tiled arms above stay guarded)"）。
臂③（通用 plane restore，无守卫）OCL:14224-14243，OCL:14227：

    cl_kernel kernel = backend_ctx->kernel_restore_block_q4_0;
    CL_CHECK(clSetKernelArg(kernel, 0, sizeof(cl_mem), &extra->q));
    CL_CHECK(clSetKernelArg(kernel, 1, sizeof(cl_mem), &extra->d));

OCL:14222（单行注释，节录）：

    // (was: #endif)  [R-029 guard-sweep P2 2026-10-26] unguarded: set_tensor producer for this layout is runtime-gated ... keeping the get_tensor restore guarded fed the plane-restore kernel transposed bytes (reverse-direction asymmetry, audit G1/G2/G3).

"转置字节"来源即此：OFF 构建里臂①未编译（守卫 OCL:14094/14178），set_tensor（OCL:11943，无守卫）已把 plane 层内转置，get_tensor 落到臂③ —— kernel_restore_block_q4_0 按"未转置标准平面"解读 dense-loop 转置存放的 extra->q/d，字节对不上。

### 1.4 与 GGML_OPENCL_USE_ADRENO_KERNELS 的关系（守卫态表）
- set_tensor dense-loop 转置写（OCL:11943）：无守卫（运行期门）→ OFF 下执行（写转置 plane）
- get_tensor 臂① 反旋转 restore（OCL:14094-14148）：守卫内（R-029b）→ OFF 下不编译 ← 缺口
- get_tensor 臂② trans4_ns（OCL:14150）：守卫内（应在）
- get_tensor 臂③ 通用 plane restore（OCL:14224）：无守卫（R-029 P2）→ OFF 下执行（读错布局 = FAIL）
- 内核创建：kernel_convert/restore_block_q4_0_noshuffle（OCL:2119-2120）、kernel_transpose_8/16_buf（OCL:4432-4433）均无守卫 → OFF 构建内核齐备，放开臂①无缺件

---

## 2. leg-032 探针 FAIL 机理

### 2.1 触发链
P4:60-64 MoE readback（set 之后、compute 之前的纯 set→get 对拍）：

    if (getenv("MOE_PROBE_READBACK") && strstr(ggml_backend_dev_name(dev), "OpenCL")) {
        std::vector<uint8_t> rb(ggml_nbytes(wq));
        ggml_backend_tensor_get(wq, rb.data(), 0, rb.size());

形状表 P4:420-422（q4_0×3）：

    run_shape(ocl, cpu, GGML_TYPE_Q4_0, 1536, 512, 128, 8, "REAL-gateup", true);
    run_shape(ocl, cpu, GGML_TYPE_Q4_0, 512, 1536, 128, 8, "REAL-down", true);
    run_shape(ocl, cpu, GGML_TYPE_Q4_0, 1536, 512, 128, 8, "PREFILL-gateup-tok4", true, 4);

张量名 "blk.0.ffn_gate_exps.weight"（P4:210）→ 过 moe_admission_gate 名门（RT:116，strstr(n,"ffn") 且 strstr(n,"exps")）→ set 走 OCL:11943 转置布局。实测 FAIL（_probe/moe_probe/legs_1026/leg032_true_mesa_rb.out:5,10,15）：

    [READBACK-MOE] blk.0.ffn_gate_exps.weight K=1536 N=512 E=128 nbytes=56623104 mismatch=54889426 (FAIL)
    [READBACK-MOE] blk.0.ffn_gate_exps.weight K=512 N=1536 E=128 nbytes=56623104 mismatch=54889000 (FAIL)
    [READBACK-MOE] blk.0.ffn_gate_exps.weight K=1536 N=512 E=128 nbytes=56623104 mismatch=54889138 (FAIL)

mismatch≈97%；同输出 GPU NMSE=0.000000（out:6,11,16 计算全绿）；iq4_xs×3、q4_K×8 全 ok（q4_K 因 G3 臂已摘守卫且自带对齐 else：OCL:14807 臂、14825-14829 对齐门、14860-14865 else copy）；q4_0 dense 2D ok（out:76；名不过 MoE 门 → set/get 双侧通用平面对称）。

### 2.2 机理判定
已静态证实：
1. OFF 构建 set/get 不对称：set（OCL:11943 无守卫）写转置 plane；匹配的还原臂（OCL:14101）被守卫编译掉（未编译守卫段 = OCL:14094-14178），落臂③（OCL:14227）按未转置平面解读 = 即"restore 拿到的 buffer 与 dense-loop 写入的不是同一布局"。
2. 读回不动权重、计算不受影响：臂①③对 extra->q/d 只读（转置源=extra、目的=临时 buf，OCL:14119-14125）；计算派发独立（OCL:30692-30697）：

    if (moe_use_dense_loop(src0->type)) {
        if (batched_moe_enabled && ggml_cl_mul_mat_id_batched(backend, src0, src1, src2, dst)) {
            return;

存疑：ON 构建"readback 亦 FAIL（pre-existing defect）"（OCL:14094 注释）静态推不出坏因 —— 臂①编译态下正反旋转互逆（OCL:11987 ↔ 14124 stride/rows 互换），理应 ok；该记录与 ICD 误标案（LOG:910-915，leg-029/030 作废）重叠，需真机重裁（§3.2 L5）。

---

## 3. Mesa 验证腿设计（830 · /data/local/tmp/mesa_clrt_1026）

### 3.1 运行协议（复用 _probe/mesa_legs/routeA_1026/routeA_legs.sh:7-13,27）

    R=/data/local/tmp/mesa_clrt_1026
    LP=$R/bin:$R/lib/aarch64-linux-gnu:$R/opt/mesa-cl/lib/aarch64-linux-gnu/clrt:$R/opt/mesa-cl/lib/aarch64-linux-gnu
    LOADER=$R/lib/ld-linux-aarch64.so.1 ; ICD=$R/opt/mesa-cl/etc/OpenCL/vendors
    HOME=$R/tmp XDG_CACHE_HOME=$R/tmp   （shader cache 隔离，routeA_legs.sh:27）

driver 判据行必见 "OpenCL driver: 26.2.4"（legs_1026/leg032_driver_proof.txt:1；ICD 误标案排雷器，LOG:910-915）。

### 3.2 最小实验矩阵
- L1 基线复现｜构建=OFF（noadreno，HEAD=R-029b 复守卫）｜开关=MOE_PROBE_READBACK=1 + MOE_PROBE_ONLY=Q40｜形状=REAL-gateup/REAL-down/PREFILL-tok4（P4:420-422）｜判据=三条 READBACK-MOE FAIL 复现（mismatch≈5.49e7，leg032 out:5,10,15）+ GPU NMSE=0.000000 + driver=26.2.4
- L2 布局独立性｜构建=OFF｜追加 GGML_OPENCL_BATCHED_MOE=0（OCL:30688-30696 强制 dense-loop 计算）｜同 L1｜判据=mismatch 与 L1 逐项相同 → 证 FAIL 属 restore 臂、与 batched/dense 派发无关
- L3 修复验证｜构建=OFF+修法A/B（§3.3）｜MOE_PROBE_READBACK=1｜probe4 全量（14 MoE + 9 dense，P4:419-459）｜判据=q4_0×3 mismatch=0 (ok)；iq4_xs×3/q4_K×8 对 leg032 out 零回归；dense 段 READBACK q4_0 ok（P4:329-330）
- L4 对齐 else 分支｜构建=OFF+修法A｜同上｜新增边界形状 K=32,M=32,E≥8（过 admission M%32 门、拒 batched M%128 门、q_layer=512 < alignment → set 不转置）｜判据=mismatch=0（alignment 实际值先打印确认）
- L5 ON 疑点重裁｜构建=ON（build-android-cli/CMakeCache.txt:530 ON）｜MOE_PROBE_READBACK=1｜同 L1｜判据=裁 OCL:14094 "ON 亦 FAIL" 真伪（复现与否都要落账）
- L6 e2e 回归门｜L3 同二进制｜routeA_legs.sh q0a0 原协议（routeA_legs.sh:31-43）｜35B e2e｜判据=health 关键词命中数、tok md5 对齐基线（q0a0f.tok）、KGSLSUBMIT/drop/nosub 计数不劣化

### 3.3 候选修法（≤2）
修法 A（推荐，镜像已验证的 q4_K G3 臂）：把 OCL:14094 的 ifdef 收窄 —— endif 从 OCL:14178 移回 OCL:14148/14149 之间（trans4 臂 OCL:14150-14177 留守卫内），并给臂①补 q4_K G3 同款对齐门+else 拷贝。参照 OCL:14825-14827：

    const bool transposed = M % 4 == 0 &&
        q_layer  % backend_ctx->alignment == 0 &&
        d_layer  % backend_ctx->alignment == 0 &&

与 OCL:14860-14861（else：copy 后仍走 noshuffle restore）。所需内核均无守卫创建（OCL:2120、OCL:4432），OFF 构建可直接跑。
修法 B（结构性对称，守卫不动）：set_tensor 实际转置处（OCL:11979-11992）在 ggml_tensor_extra_cl_q4_0 上记 dense_transposed 位；get_tensor 于 OCL:14092 后加无守卫臂按该位分派（true→反旋转+restore_noshuffle；false→copy+restore_noshuffle）。仅动 OCL:11979 区与 OCL:14092 区，根除未来 guard-sweep 再造成方向不对称（LOG:901-902 G1/G2/G3 教训）。

---

## 4. 生产影响核句：q4_0 batched×3 FAIL 不影响 35B 生产 e2e
判定依据（file:line）：
1. 权重 get_tensor 只服务 test-backend-ops/探针，e2e 读回仅 logits（OCL:14074-14076）：

    // In end-to-end runs, get_tensor is usually used to get back the logits,
    // where we can simply do clEnqueueReadBuffer since they are f32.
    // However, in test-backend-ops, the GPU graph is copied to the CPU backend,

2. 35B MoE 专家=q3_K、batched-only、不进 q4_0 臂：e2e 走 experts 文件+slot bank（minicpm_e2e.cpp:627-629，mparams.moe_experts_path = experts），docs/minicpmv47_35b_a3b_phone_plan_2026-10-15.md:15 记 "slot runtime（llama-moe-slot.cpp）q3_K 批处理内核链"；q3_K 无 dense-loop 兜底（OCL:8410 "No dense-loop fallback exists (no dense q3_K GEMV) — batched-only."；派发 OCL:30704-30708），其 get 本无字节精确契约（P4:57-59 注释）。
3. 35B 其余 q4_0 面不触缺口：非专家权重 q3_K_L/q4_K dense 腿 leg-032 全绿（P4:450-459；LOG:904-905 G1/G2 mismatch=0）；KV q4_0 保持 AoS 直读（OCL:14081-14082）。
4. 计算不受影响：同形状 GPU NMSE=0.000000（leg032 out:6,11,16）；batched 真派发判据=台账同日 "mmid_q4_0_batched"（LOG:869）。

## 5. 未验证 / 存疑清单
1. "ON 构建 readback 亦 FAIL（pre-existing defect）"（OCL:14094）静态推不出坏因，且与 ICD 误标案时段重叠 —— 待 L5 重裁。
2. R-029b 当初"OFF 臂①污染 batched 计算 NMSE 0.53"已随 ICD 案作废（LOG:906-907,914），但"放开臂①后计算仍 0.000000"未在真 Mesa 重跑 —— L3 需同时盯 NMSE 行。
3. backend_ctx->alignment 在 rusticl 下的实际值未查（L4 可行性依赖）。
4. leg-032 所用 moe_probe4 二进制的守卫态归属（noadreno vs adreno 目录）系由台账语境+CMakeCache 推断，legs_1026 无 md5 备案 —— L1 复跑时补录。
5. 台账"15 形状"与 P4 实际 MoE 形状 14 个（q4_0×3+iq4_xs×3+q4_K×8；leg032 out 亦 14 条 READBACK-MOE）差 1，口径待核。
6. 35B .experts 文件内专家权重类型仅由文档（phone_plan:15）与 q3_K batched-only 契约反推，未对 GGUF 机检类型清单。
7. batched 计算核与 dense-loop 转置平面的相容性系按注释（OCL:30684-30686 "per-expert transposed layout"）+计算全绿反推，未逐行读 kernels/*.cl 寻址式。
