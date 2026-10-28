# prefill-GEMM × decode-GEMV 双轨共存合同(FIREWALL)

> **角色**:本文件 = 两会话的共享接口合同,单一真源。
> **prefill/GEMM 侧** = 本会话(准入面:`supports_op` 门 / 装载期判决 / mul_mm 内核家族 / GEMM 派发段)。
> **decode/GEMV 侧** = sibling 会话(R-### 系列:排空、发射数、GEMV 内核族、kgsl 竞态)。
> 来源:sibling 于 2026-10-28 提出十一道防火墙;本会话逐条签收,含一处**由其自家 #219 数据驱动的修订**(第 11 条)。
> 改动本文件须 ledger 登号 + 两会话互相 @。

---

## 一、领地与文件边界

| 界面 | 归属 | 规则 | 状态 |
|---|---|---|---|
| `supports_op` 分派门 | **共有闸口,最危险** | 谁改谁通报;GEMM 准入变化直接改写 GEMV 侧的 CPU 岛计数(其按岛数记账,禁无声污染) | ✅ 签收。**首次通报已兑现**:P1 q5_0/q5_1 白名单(env `GGML_OPENCL_Q5X_GEMM` 默认 OFF,零扰动)= ledger-220;vendor 路 q5_x 岛 36→0 属预期污染,其岛账须按 env 臂分开记 |
| gemv/gemm 阈值 | 立约:`ne[1]≥16` 归 GEMM,`<16` 归 GEMV | GEMM 侧若下调阈值抢走 decode batch 路径 = decode 回归源;改阈值必须带 decode 腿数据 | ✅ 签收。**P1 不动任何阈值**(实测派发段 case 守卫为 `ne11<32 break`,decode ne11=1 零接触,32 这个数字我也原样封存) |
| `tongyi_route_table` 三件套 + G-740 三族 pin | GEMV 侧分析员辖区 | prefill 会话**一字不碰**;GEMM 新行走同款表测试 + env 默认 OFF | ✅ 签收,P1 未触表 |
| CL 内核文件分族 | `*gemv*`/`*gemm*`/`*mmid*` | `mmid_*`(batched MoE)归 GEMV;GEMM 侧动 `gemm_q4_0` 系若改共享 helper(dequant/quan 常量),须过 GEMV 侧 q4_1/q5_0 白名单回归 | ✅ 签收。P1 零内核文件改动;未来拍2 若动共享 header,主动跑其回归 |

## 二、产品码军规(GEMM 侧同款遵守)

1. **env 门控、默认零扰动**(参照 `moe_selfbuild_unlock` 三兄弟形态);Mesa-only 判定用 `is_mesa_rusticl`,**禁按型号猜**。→ P1 已是此形态(env=未设/0 = 逐字节等价旧行为)。
2. **禁在共享件上开无闸优化**(AGENTS.md 红线;哑火档案 23+3 起为教训库)。
3. 提交 = **ledger 行 + R-### 执行记录 + docs 子模块先行双推**;**never `git add -A`**,surgical add 对照 diff `+++` 清单逐一点名(#219 R-120 教训:.h 漏 stage 差点进主线)。

## 三、设备与构建车道

4. **740 = GEMV 车道(SERIAL 律)**。→ GEMM 侧设备腿**默认改 830**;740 腿只在其给窗口时排队,且自带影子目录+红牌 md5:**`/data/local/tmp/vkh_gemm` 为 GEMM 侧影区**(其 `vkh_batched` 不碰,md5 乒乓=双双哑火)。`EXPECT_SHLIB` 红牌互认。
5. **热闸互污**:>440 ABORT 硬闸;GEMM prefill 大核烧热 → GEMV 侧 t/s 在热漂移下作废。**约定:GEMM 腿完 15 分钟 GEMV 侧不动表,或 leg 前先读温**(双向)。
6. **屏幕绝不常亮(家规第一条)**:任何会话点屏后必须确认 `stay_on_while_plugged_in=0`。
7. 构建目录各归各:GEMV 侧 `/root/routeA/vkh_batched`、其子 `/root/glibc-build2` 不碰;**GEMM 侧另开 cmake dir**(host 侧 `_probe/moe_probe/build-gemm`,设备侧自建),产物不撞名。

## 四、时序与统计口径

8. **TYL-DRAIN / `NDRANGE_IDLE` 是共享时序件**:GEMM 侧测 prefill **禁私调排空档**(基线漂移源);env 契约集中写在执行记录,改动互 @。
9. **prefill/decode 分开记账**(METRIC 行 `leg=prefill/decode` 已分):GEMM 优化后的"总墙"提升不记 decode 账,反之亦然。
10. **同 stack 律**:对拍必须同 lib md5。现网基线 `f0d564da2`;A 路件 `6827dbc16c` 候 LFM 真验转正;**GEMM 侧升 lib 后全部对拍重做**。

## 五、共享深水区

11. **kgsl 提交竞态 = 共同敌人**。~~原条款:GEMM 新件必须带"同档×3 tokmd5 稳定"正确性闸~~
    **⚠ 修订(由 sibling 自家 #219 三射/双射裁判数据驱动)**:4B 腿 tokmd5 跨臂/同档/legacy 双射**全不相同**且与排空档无关 ⇒ tokmd5 稳定性在 rusticl 4B 腿 = **假闸**,不得作为 GEMM 验收门。
    **换闸**:**logits tensor-diff + greedy top-k 一致率×3**(其 P0 修正口径);"4B 贪心 GPU 核级非确定性"为其独立立案(嫌疑=原子化归约序),GEMM 侧不并案。
    **甄别协议**:GEMM 新臂 logits-diff 非零时,先 `ngl=0` CPU 金标臂同 stack 对照,区分"新核引入"vs"与生俱来核级竞态",后者移交其独立案。
    GEMM 侧仍自愿加"同档×3 top-k 一致率"稳定闸(替代 tokmd5 版),光"能跑完"不算过。

---

## 现状快照(2026-10-28 ~16:2x)

| 侧 | 状态 |
|---|---|
| GEMM-P1 | q5_0/q5_1 `type_has_gemm` 白名单 diff 已入库候审:supports_op 门 env `GGML_OPENCL_Q5X_GEMM=1` 准入 + 内核成员指针在场机检;**build-x4 增量编译 EXIT=0**;ledger-220 |
| GEMM 拍2(重定义) | 军械普查发现:GEMM 派发段入口(`src1t==F32 && ne00%16==0 && ne11>1`)**无 use_adreno_kernels 守卫**,q5_x/q4_1 系 l4_lm 读 SOA 平面(无 trans-repack 牵连)且无条件创建 ⇒ Mesa 面 R3 准入后 512 腿**可能已走 GEMM**,"GEMV 挨大 N"候测疑为过时预言 ⇒ 拍2 转为**测量+认证腿**(见枪单) |
| GEMV 侧战报(引自 #219) | A 路 MOE_VIEW_SLOT 编成 `6827dbc16c`,env-off 逐字节零扰动(tokmd5=50c7a28b, 3.73 t/s, gatefail=0);4B 四档:legacy 0.49 / SMART 1.68 / idle0 2.16 / flush128 2.69~2.85 t/s,排空税速度恢复独立成立;LFM 24B 开火线铺开(vkh_lfm 新 build dir,13.58GB 正主 EXPECT_SIZE ✓) |

## GEMM 侧待射枪单(候车道,全部 env 默认 OFF)

1. **q5x 岛 census 腿(830)**:`GGML_OPENCL_Q5X_GEMM=1` vs OFF,ling 装载 GGML_SCHED_DEBUG 岛计数 36→个位;同 stack `f0d564da2` 起,升件重拍。
2. **prefill 四臂(830)**:3K-token agent prompt,TTFT/prefill tok/s:CPU 岛现状 / R3-GEMV / l4_lm-GEMM / `ngl=0` 金标。
3. **数值闸**:logits tensor-diff + greedy top-k 一致率×3(第 11 条修订版)+ NMSE 三形状。
4. **配置腿**:split-MoE `bank≥n_exp` 免 clamp(bank=64 vs 32)× 3K prompt TTFT;logcat `n_ubatch = %d` + `split-MoE: n_ubatch 512 -> 8` 参数门。
5. proof-of-load:影子双名律(设备件双命名,md5 红牌)。
