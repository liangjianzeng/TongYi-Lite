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
- [x] 0032 探针轮（E4VERIFY/E4REUSE/E4FAST/E4FLUSH/E4WAIT，diag2=1a9d8f15）→ e4d-r1 **rc=139 悬垂崩**（保存裸 map 指针教训）
- [x] 0033 活性查找重设计（fd_bo_e4_lookup + SKIPPED 语义 + heap 分支钩子 + **不持引用**，diag3=1db4c812）
- [x] 机床现状：树=背书+0031..0033+0036+0037+0038（diag8=908ece48）；diag4..diag7 md5 见 /tmp/e41026；设备影子=已撤（q0a0#8 背书无损）
- [x] **R10 证伪**（E4REUSE 双钩子全哑 + 每 submit 全新 gem）+ **E1 闭环**（e4g=RUSTICL_DEBUG=sync ⇒ token 级金标准全等）+ **竞态统一图景**（e4e 三跑漂移 d0044294/678a1e60/d0044294≠e9b88e56，idx2 起分叉=prefill 命中）
- [x] R-034 入册（1045 行册）/ C2 回写 / 台账 leg-043..051 / 双仓 push
- [ ] **0034 E4BOREUSE（R11 判决）**：freedreno_bo.c try_recycle 记 {handle→{release 时最后提交 ts,queue}}，BO_CACHE acquire 侧 timeout=0 WAITTIMESTAMP 探活，**reached=0=在飞复用实证**；ts 归因是保守近似→联查 ggml 垫片 clReleaseMemObject→re-alloc 配对计数
- [ ] **E4FAST 旁路鉴别腿**：给 fastpath 加 `TYL_E4_NOFAST=1` 强制 wait 全走 KMD——async 治好=快路早完成定罪（R11 上游）；仍乱=worker 批处理内部竞态
- [x] 0034 diag4（bb401268）+ e4h NOFAST：**快路早完成死刑**（禁快路仍乱）；E4VERIFY OK=0 ⇒ R-034「IB 完好」**撤销**（n=1 空数据；ring submit 即毁=全 regime 共性）
- [x] 0035 diag5（059579c1）load-gate+tid+RGROW+QFLUSH：BOREUSE_NOTRET 双 regime 归零（**R11 直接形态→0.1**）；三线程分工（22582 录制 submit/22617 等待信号/22579+22593 API 直等）；乱码模态跨代复现（be5a0264=leg-039、d0044294×3）=窗口位置固定
- [x] R-035 入册（1062 行）/ C2 回写 / 台账 052-056 / 双仓 push；背书复验 #6
- [x] SA-4 验尸完成（四线程/sq 释放/双 sync 消费点裁定 SA-1/无 50 常量/硬阈值 30·128）→ 0036 diag6（0c0f63cf）三探针跑毕 PREP 燃料非区分量、CB0 环绕复用假说复活（0034 one-shot 降权）、fl 阈值 N≤2/N≥3、fl2=可用非免费
- [ ] u_upload_mgr 语义定档（读源码）：轮转 `u_upload_alloc_buffer` **无任何 fence/在飞检查**，releasebuf 交调用方处置；map_persistent 走 MAP_PERSISTENT|COHERENT（kgsl caps 值待证）。两条子假说：(a) **字节级环绕**——slab BO 被批 RELOC 引住+有围栏（E4CACHEBAD 预测=0，保护生命周期但不保护字节），CPU 环绕写 offset X 时滞后批仍读 X=乱；(b) **无引用户**——若 CB0 不经 RELOC，轮转释放的旧 slab 零围栏进 BO_CACHE 即刻可被夺（CACHEBAD 预测>0）。E4LAG+E4CACHEBAD 双读数一次分诊：LAG 大+CACHEBAD=0⇒(a)；CACHEBAD>0⇒(b)；LAG≈0 且仍乱⇒转 worker 内部竞态
- [x] diag7/diag8 夜袭完跑（21:29 设备自恢复，第 10 轮值守命中）：lag async 119/max143、CACHEBAD=0、fix8 4MB 模态逐字不变=cb0 族死刑、lag 非区分量（fl1 avg1932/fl2 1186 均金标准）、ring 轴静态 ref 完备出清（0034 钩子盲区=try_recycle 缓存命中路）、垫片乒乓线索（310/310 dist1-2×13.1MB×47ms）
- [x] 新铁律已执行：run_leg 热闸>44°C ABORT_THERMAL；失联处置=后台重连循环；垫片双课=routeA 腿须 glibc 构建（bionic 版 rc127）+LD_PRELOAD 禁 export（毒 bionic timeout）
- [ ] **0040 乒乓审计（diag9）设计**：垫片 release/create 带身份 + rusticl memory.rs:2409 两侧打点带 gallium 资源指针 + BO acquire 退休水位三方 join；定罪=新 buffer 首用 < 旧 buffer 末批退休。SA-6 回传后新记录对账（其初稿段已撤）
- [ ] ggml 垫片 release→re-alloc 配对计数；OPFLUSH=2/4/8 阈值扫；背书漂移大样本；前线② B0 岛事件化（OCL:11162-11166 三 NULL async 钩子，岛界 OCL:8612-8613）

## 5b. 判决语义备忘（R-034 后 —— 覆盖 R-033 版）
- **R10 已死（R-034）；R11 直接形态与快路早完成已死（R-035）**。存活嫌疑排序：worker 批处理内部竞态（0.55，头号——per-event flush 是唯一治愈，NOFAST 不治）> ggml 事件依赖/释放配对缺陷（0.15）> R11 窄窗残党（0.1）> ts 原语谎报（0.05）> R9（BANK_GPU 腿再裁）。
- E4VERIFY/SKIPPED 语义：OK=0=读者少（ring 提交即毁）；**MISMATCH 缺席≠IB 完好**（可读者才计数）；tid 联查键=E4FENCE(录)/E4FAST(等)/E4FLUSH/E4WAIT(rt+tid)。
- **字节判据纪律**：字节级金标准对比**只准用于背书库**；diag 腿=扰动放大器（18 万行 stderr/腿），只能比 health+分布量（hist/nev/E4FAST 率/KGSLSUBMIT 计数）。R-033「diag 零扰动」字样作废（e4b 一把全等只是竞态未命中）。
- **竞态概率谱**：sync=0（金标准全等，唯一 0 概率态）；背书 OPFLUSH=1≈0（e9b88e56 五连庄=leg-034/035/042/048/051）；OPFLUSH=1+diag3=3/3 漂移；async≈1。漂移模态可复现（d0044294×2）⇒ 竞态窗口有偏置，非均匀噪声。
- E4FAST 实测：async 92%（34224/37231）、OPFLUSH 95%（175396/184549）wait 由 control->fence 自写 stamp 命中不经 KMD；E4VERIFY MISMATCH 签名=全 size 584 尾环（worker 并发重录良性）——**IB 通路无罪**。
- E4REUSE 语义：hooks 在 bo_new 的 cache-hit 与 heap-hit 两分支（RING_FLAGS）；reached=0 本应=未退休即复用，**实测恒 0 行=无复用事件**（fresh-gem 环），非探针失效（同函数在 e4d/e4e 双态均 0）。
- P2 语义坑（留档）：fd_submit_del 两步丢引用；primary ring del 前 refcnt=2，==1 判据记 0 属预期。
- fence 通路唯一性（SA-1）：kfence 唯一赋值 kgsl_ringbuffer_sp.c:115；唯一消费 kgsl_pipe.c:121（WAITTIMESTAMP_CTXTID，无轮询无超时）；整批单 fence=queue.rs:519-522（实测 nev≤50，chunking 存在）；FASTPATH=freedreno_pipe.c:178。

## 6. 坑位备忘（累计）
- 本机 harness 内 sudo=no new privileges 拦死；一律走 `ssh <redacted-tailscale> 'sudo -n ...'`。
- chroot 跑命令形态：`ssh <redacted-tailscale> "sudo -n chroot /opt/trixie-cl sh -c '...'"`（chroot 内路径=/root/mesa-26.2.4，宿主机加前缀 /opt/trixie-cl）。
- 外传经 /home/jianzengliang/*_1026* 中转 + scp；ssh stdout 打 tar 会混脏（禁）；root 属主中转文件 chmod 被拒但 world-readable 可直接 scp。
- 设备 env 必须脚本内 export（Android mksh 把续行后落单 `VAR=值` 当命令 rc=127）；同行赋值前缀合法。
- 影子加载=push 到 $R/bin/libRusticlOpenCL.so.1（LP bin 首位遮蔽）；回滚=rm；**每轮换库必设备侧 md5sum 复核**。
- 【R-034 新增】探针**禁保存 bo 映射裸指针**（缓存 shrink→munmap→SIGSEGV，e4d-r1 rc=139 学费）；用 handle→fd_bo_e4_lookup 活性查找 + SKIPPED 语义。
- 【R-034】**探针禁持被测对象的引用**（持引用=阻止被测复用发生=自宫）；观测 BO 生命周期只能读状态不能续命。
- 【R-034】新导出/前向 C 函数先写原型再定义（-Werror=missing-prototypes 两轮各咬一次）。
- 【R-034】`set -e` 下裸 `diff >> patch`（rc=1=有差异）会掐断补丁生成——diff 循环与 set -e 分家。
- 【R-034】Rust eprintln 字面量在合并 rodata 串里，`strings|grep '^E4X'` 锚定失配，用非锚定计数。
- 【R-034】腿脚本 FASTHIT 用 `hit=1` 子串计数与 timeout 大数无冲突但偏松；精确判读从 err 原文 `awk '$0 ~ /^E4FAST/ && / hit=1$/'`。
- **机床现状（R-034 后）**：chroot 树 = 背书态+0031+0032+0033（diag3 源码态）；build-cl 产物=1db4c812；**设备无影子、背书已复验（e9b88e56 第六次）**；回退料 /root/kgsl_ringbuffer_sp.c.orig（bf02f850）+ 快照 /root/mesa-26.2.4_snap_1026 仍在；pre 拷贝 /root/{e4r2_pre,e4r3_pre}/ 供 diff 再生。
- [x] R-038：SA-6 真报告对账（虚构锚点自破；release 325→ioctl 370 窗口真实）；环盲区破案（flags 等式一位之差=七代全哑真凶）；环轴测净 16339/0（KMD 实证）；跨队列死刑；BOREUSE decode 证据有效性恢复（单队列）。背书 #9。
- [x] R-040：0045/0046 内核参数级审计（E4KHDR/KARG/R2BO/R2DEL，diag14/15=38fff5c9/cfb5240c）——观测面 15 项穷尽；**日程同构铁证**（async vs fl1 前 63111 发射逐位一致）；{:p} 址复用噪声三度现形（生死括号治愈）；hostptr 多写者合法定性；子分配 ggml 零触达。
- [x] **R-041 ★战役转折（H2′ 定罪）**：垫片注入五腿交叉（g18-g25）——每 op finish 治愈(e19f0cb2)/仅 NDRange 后 finish 治愈/写后 finish 不治/**NOMERGE 拆 ioctl 不治**(g22)/≥1MB 写**前** usleep 2ms~100µs 全治愈(g23/24/25) ⇒ **罪核=上批 retire 后 GPU L2 dirty 排空滞后于 host 对 pinned 后备的覆写**（纯时延竞态；命令/日程/归属全同构）。金标准在 diag15 树=**e19f0cb2**（随插桩漂移属预期）。
- [x] R-041b 更正：g26/g27=垫片门控陷阱 NO-OP 腿（grp_on 解析要求 TYL_E4=1）⇒ 非反证；铁律新增：**干预腿必须自证生效**（witness 计数 grep）。垫片 v8 已解耦门控。
- [ ] 待设备回线（00:0x 失联，adbd TCP 超时，历史自愈型）：**g28**=背书+v8 垫片 GRP=4（E4GSLEEP 自证）；**g29**=背书+现成 `GGML_OPENCL_SET_TENSOR_FINISH=1`（前人 -54 hunt 遗产 @ggml-opencl.cpp set_tensor 入口，路线①零代码候选）；q0a0 背书复核 #10。
- [ ] 产品化三路线：①ggml 写前事件等待（g29 若愈=现成 env）②驱动侧 retire 前 L2 屏障（根治，触 KMD 邻域）③SA-5 L3 岛边界 buft 消灭 412MB×40/token 覆写本身（竞态+税双杀，前线②主线）。
- [ ] 教训入册：探针税>2min/token 的对照腿需 2× 超时；提问子智能体前先自查锚点真实性（SA-6 Q1 教训）；**grep 空返回断 `&&` 链**（rm 后 grep 教训）；**python 步骤别放断链后面**（g26 从未写入教训）；垫片开关独立解析禁借道 TYL_E4。
- **机床现状（R-041 后）**：chroot 树=背书+0031..0033+0036..0047（diag16=c1c1d271 源码态：NOMERGE/内核打点/E4R2BO/DEL 全 TYL_E4 门控）；垫片 v8（门控解耦版）在 /tmp/e41026/shim/；设备失联中（影子已撤、背书库在位、热 30.8°C 失联前正常）。
