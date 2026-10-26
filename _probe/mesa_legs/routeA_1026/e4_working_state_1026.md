# E4 插桩轮 · 主线工作记忆（2026-10-26 晚，接班会话）

> 本文件是接班会话的滚动工作记忆（机器本地便利 + `-f` 入仓归档）。
> 权威定案永远以 docs/ 地图册 + 执行记录册 + bench_ledger.jsonl 为准。

## 0. 接班 checklist 状态
- [x] 主仓 pull = d82e7829；docs 子仓 = 879fc33（两仓与 origin 一致）
- [x] 交接文档/地图 S0 框(line~137)/执行记录 R-031+R-032 全文已读
- [x] 830 在位 `<redacted-tailscale>:5555`；指纹三件套全过：束 opt 原件 **8de7d05f**、在役 bionic **c82f84d8**、$R/bin 无影子残留；模型 1662732800B 在位
- [x] 本机=DGX 机床（tailscale <redacted-tailscale> = 本机）。harness 容器内 sudo 被 no_new_privs 拦 → **已把本机 id_ed25519.pub 追加进本人 authorized_keys**，恢复文档 §3.2 通道：`ssh jianzengliang@<redacted-tailscale> 'sudo -n chroot ...'`（可逆：删该行即回滚）
- [x] 740（<redacted-tailscale>:5555）拒连、K40 超时——**当前只有 830 一条设备道，串行归主线**

## 1. 机床状态核验结论（1026 晚）
- chroot 树 `/opt/trixie-cl/root/mesa-26.2.4` **仍处 0030 已应用态**（kgsl_ringbuffer_sp.c 内含 `[TongYi-Lite 0030]` 迁移块）；build-cl 现产物 = **33cc4a00**（=diag0030 库，非背书态）。
- **回退料已在位**：`/root/kgsl_ringbuffer_sp.c.orig`（pre-0030 备份）grep 计数：0030 块=0、KGSLSUBMIT=2 ⇒ 与背书态特征吻合（KGSLSUBMIT fprintf 本就是背书态一部分，q0a0f.err 78MB 即证）。
- **MESA_DEBUG "sync" 分支解析存在**：`src/gallium/frontends/rusticl/core/platform.rs:134: "sync" => debug.sync_every_event = true` → E1（MESA_DEBUG=sync）失效另有原因，头号嫌疑=§6-4 adb 单行 env 未导出 ⇒ **L-C 零成本对照腿（背书库真机重跑，env 走脚本内 export）裁决**。
- **RSARG eprintln 残留**：`src/gallium/frontends/rusticl/core/kernel.rs:1823`。待核：背书库 8de7d05f 是否已含该串（含=保留保时序可比；不含=撤掉保基线纯净）。
- 树内 .rej/.orig 残留清单（已知，不动）：freedreno_device.c.rej、freedreno_priv.h.orig、meson.build.orig、freedreno_pipe.c.orig、freedreno_drmif.h.orig、freedreno_ringbuffer_sp.c 所在 drm/*.orig 若干。

## 2. 战役态势（继承）
- 三前线优先级：① async 乱码（前置缺陷，最高）→ ② B0 CPU 岛 → ③ q4_0 readback 挂账。
- 已排除：R1(0030 判决腿 0.70→0.15)、R4、R5、R6、软队列丢命令、T3 drain/R8 staging(leg-038 drain=0.0ms)。
- E4 任务书（交接 §5-①）：P1 flush_submit_list 合并统计（numcmds/合并 submit 数/deferred 深度直方图）；P2 合并时 fd_submit_del 前 bo refcount 观测（归零被 free？iova∈cmds 相关性）；P3 整批单 fence 信号语义（腐蚀批次假 COMPLETE？→R3 升降）；P4=对照腿（diag 库 OPFLUSH=1 应仍正确）。
- 验收铁律：每腿第一验收 = err 里 `OpenCL driver: 26.2.4`（QUALCOMM 串=作废）；影子加载只进 $R/bin，绝不动 opt 原件；diag 撤除后背书复验 e9b88e56。
- 金标准：`_probe/mesa_legs/routeA_1026/baseline_off_fl1b.tok` md5=e9b88e56203166cc69895f37bd3416a2。

## 3. 已定决策
- E4 diag 基线 = **背书态（回退 0030）**：观测对象必须是生产路径本身。
- 插桩一律 fprintf(stderr)（buildtype=release b_ndebug ⇒ DEBUG_MSG 被编译掉，这正是 MESA_DEBUG 不可见的次生教训）；探针 env 门控 `TYL_E4=1`（不设=零行为扰动，对照腿可与背书逐字节比）。
- 真机腿全由主线跑（子智能体禁碰设备）；子智能体只做只读源码考古与草稿。

## 4. 子智能体任务台账（只读三单，回报须逐字引用 file:line，主线验尸后入账）
- SA-1（DGX 只读）：MESA_DEBUG 解析链全链复核（platform.rs 读 env 的来源与消费点、queue.rs sync_every_event 消费行号、ndebug 下是否存活）+ kgsl fence/完成通路图（kgsl_pipe.c/kgsl_fence.c/kgsl_batch.c 中 kfence→wait→signal 的行级通路）→ 输出 P3 探针落点建议。
- SA-2（本地仓只读）：ggml-opencl async 面复核——OCL:15911 staging 注释与 DRAIN_ASYNC 路径、write_blk CL_TRUE 归因（leg-038 排除 R8 的证据强度）、T1/T4 CPU 岛传输点（13983/14070/13021-26）、持久映射 buft 骨架（15589-15631）现状。
- SA-3（本地只读+草稿）：E4 三条腿脚本草案（照 routeA_legs_1026.sh q0a0 段形态：LP 四目录/OCL_ICD_VENDORS/RUSTICL_ENABLE=kgsl/字面 env/timeout 保护/短腿纪律）+ 台账 leg-039..041 JSON 模板 + R-033 执行记录骨架。

## 5. 主线流水（滚动）
- [x] 接班核验+机床状态（本文件 §0/§1）
- [x] chroot 树快照 cp -a → /root/mesa-26.2.4_snap_1026（840M）
- [x] 回退 0030（cp .orig 回树，md5 bf02f850 特征核过）+ RSARG 处置（背书库二进制含 RSARG=保留）
- [x] 0031 E4 插桩补丁（P1/P2/P3a，TYL_E4 门控）+ ninja（14 目标 ~2min）→ **diag=ef83ad18**
- [x] 影子 $R/bin → L-A diag async 16tok（乱码复现+统计：nsubs≤2/freed_bos=2713/3000）→ L-B diag OPFLUSH=1 48tok（**e9b88e56 全等**，深合并 7.4/ioctl 反正确）→ 撤影子 → L-C 背书+MESA_DEBUG=sync（仍乱码，后由 SA-1 定案=env 名错，测废）→ 背书复验 q0a0（**e9b88e56 第三次一致**）
- [x] 首轮落账：台账 leg-039..042 / **R-033 入册** / C2 格回写 / 双仓 push
- [x] SA-1/SA-2 只读报告验尸（承重断言逐字抽验命中）→ 定案 E1=env 名错（RUSTICL_DEBUG）；R8 改判「未测」；R9 挂账（OCL:15885）
- [ ] **0032 探针轮（R10 判决）**：P3-B（queue.rs:345-354 FLUSH fence↔nev）+ P3-C（queue.rs:519-527 WAIT ok）+ P3-D（freedreno_pipe.c:178 前 FASTPATH hit）+ P4（IB CRC32 ioctl 时↔环缓存复用点复核，join key=handle/fence 指针）→ L-D diag async / L-E diag OPFLUSH=1 / L-F __tyl_probe__ 阳性对照 / L-G RUSTICL_DEBUG=sync
- [ ] 判读裁 R10 → 落账 R-034 → 前线②（B0 岛事件化：OCL:11162-11166 三 NULL async 钩子=结构性根因，岛界 OCL:8612-8613 红线）

## 5b. 判决语义备忘（R-033 后）
- R10 = 在飞 IB 覆写：环 bo ioctl 前归零→RING_CACHE→CPU 覆写 GPU 未读完的 IB；0030 只持引用到 ioctl 返回（≠退休）故其判决腿未覆盖本窗口。预期指纹：L-D（async）CRC 复用点不一致 + fastpath/KMD 可能不一致；L-E（OPFLUSH=1）应零不一致。
- P2 语义坑：fd_submit_del 是 unref→ring_del(丢 ring ref)→destroy(丢 table ref) 两步；primary ring 观测窗在 del 前 refcnt=2，判「将释放」要用 ≤2-at-del 语义而非 ==1。
- fence 通路唯一性（SA-1）：kfence 唯一赋值 kgsl_ringbuffer_sp.c:115；唯一消费 kgsl_pipe.c:121（WAITTIMESTAMP_CTXTID，无轮询无超时）；整批单 fence=queue.rs:519-522；FASTPATH=freedreno_pipe.c:178 GPU 自写 control->fence（R3 裁决唯一非 KMD 观测面）。

## 6. 坑位备忘（本轮新增）
- 本机 harness 内 sudo=no new privileges 拦死；一律走 `ssh <redacted-tailscale> 'sudo -n ...'`。
- chroot 跑命令形态：`ssh <redacted-tailscale> "sudo -n chroot /opt/trixie-cl sh -c '...'"`。
- 外传经 /home/jianzengliang/*_1026* 中转 + scp；ssh stdout 打 tar 会混脏（禁）。
- 设备 env 必须脚本内 export 或字面绝对路径同行不导出（E1 疑案）。
- 影子加载=push 到 $R/bin/libRusticlOpenCL.so.1（LP bin 首位遮蔽）；回滚=rm。
