# B0-L1 drain 归因双腿报告 (1026)

- 束: /data/local/tmp/mesa_clrt_1026 (clrt/glibc 第二运行时, 束内 loader + --library-path + --preload libclcount.so)
- 设备: <redacted-tailscale>:5555 | 日期: 2026-10-26 | 模型: minicpm-v4.7-35b-a3b-les (99 16 512)
- 两腿唯一差异: LLAMA_MOE_DRAIN_ASYNC=1 (腿A, 文件后缀 L1d1) vs =0 (腿B, 文件后缀 L1d0), 其余逐字相同。
- 两腿 EXIT=0, timeout 480s 保护, 均在限内完成。

## 腿A (LLAMA_MOE_DRAIN_ASYNC=1) 原始采集

### 1. CLCOUNT 三行垫片计数
```
[CLCOUNT] nd=44799 flush=63272 finish=4 wait=9364
[CLCOUNT] read blk=3982 nblk=0 | write blk=4066 nblk=0 | map blk=0 nblk=0
[CLCOUNT] flush_with_pending: n=34909 avg=1.28 max=1311 (sum_pending_at_flush=44799)
```

### 2. KGSLSUBMIT cmd[ 计数
```
38103
```

### 3. OpenCL driver (必须 26.2.4)
```
ggml_opencl: OpenCL driver: 26.2.4
```
有效 (无 QUALCOMM 串)。

### 4. health 与 out 头 200B
```
2
```
```
[e2e] prompt tokens: 6
[e2e] prefill 3718 ms


中国的四大发明是指**造纸术**、**指南针**、**[e2e][METRIC] leg=decode gen=16 wall_ms=8511 tok_s=1.88 load_ms=6937

[e2e] done n_gen=16
```

### 5. tok md5 (设备侧)
```
80d8e485d45da5232748857bacc3ba96  /data/local/tmp/mesa_clrt_1026/out/L1d1.tok
```

### 6. drain/stage_wait 行 (head -5, 引擎有 moe-ssd 日志)
```
[moe-ssd] decode #1 tok=1 used=8 layers=40 unique/l=8 miss=320 hit=0 pack=40/40 nth=4 pread_wall=228ms pread_sum=707ms bytes=412MiB par=3.11 io=1813MiB/s readall=412MiB calls=320 realio=1813MiB/s span=1 pmgmt=219.5ms readids=0.0ms writeids=0.0ms deferspawn=0.0ms deferwait=0.0ms drain=0.0ms/0 pfskip=0 pfwait=0/0.0ms pfread=0 pfpub=0 pfhit=0 pfpredict=0 pevsave=0 pevforced=0 pfcached=0 usedpf=0 runs=317 avg_run=1.0 max_run=2 zerocopy=100% dynsplit=0
[moe-ssd] decode #1 tok=1 ... drain=0.0ms/0 (同上行重复打印)
[moe-ssd] decode #2 tok=1 ... drain=0.0ms/0
[moe-ssd] decode #2 tok=1 ... drain=0.0ms/0
[moe-ssd] decode #3 tok=1 ... drain=0.0ms/0
```
补充: 非 moe-ssd 行的 drain/stage_wait 计数 = 0; `drain=0.0ms/0` 行数 = 16 (16 token 全部 drain=0.0ms/0)。

### 7. METRIC 行
```
L1d1.out:中国的四大发明是指**造纸术**、**指南针**、**[e2e][METRIC] leg=decode gen=16 wall_ms=8511 tok_s=1.88 load_ms=6937
```

## 腿B (LLAMA_MOE_DRAIN_ASYNC=0) 原始采集

### 1. CLCOUNT 三行垫片计数
```
[CLCOUNT] nd=44799 flush=63272 finish=4 wait=9364
[CLCOUNT] read blk=3982 nblk=0 | write blk=4066 nblk=0 | map blk=0 nblk=0
[CLCOUNT] flush_with_pending: n=34909 avg=1.28 max=1311 (sum_pending_at_flush=44799)
```

### 2. KGSLSUBMIT cmd[ 计数
```
38103
```

### 3. OpenCL driver (必须 26.2.4)
```
ggml_opencl: OpenCL driver: 26.2.4
```
有效 (无 QUALCOMM 串)。

### 4. health 与 out 头 200B
```
2
```
```
[e2e] prompt tokens: 6
[e2e] prefill 3668 ms


中国的四大发明是指**造纸术**、**指南针**、**[e2e][METRIC] leg=decode gen=16 wall_ms=8312 tok_s=1.92 load_ms=6934

[e2e] done n_gen=16
```

### 5. tok md5 (设备侧)
```
80d8e485d45da5232748857bacc3ba96  /data/local/tmp/mesa_clrt_1026/out/L1d0.tok
```

### 6. drain/stage_wait 行 (head -5)
```
[moe-ssd] decode #1 tok=1 used=8 layers=40 unique/l=8 miss=320 hit=0 pack=40/40 nth=4 pread_wall=179ms pread_sum=536ms bytes=412MiB par=3.00 io=2307MiB/s readall=412MiB calls=320 realio=2307MiB/s span=1 pmgmt=177.7ms readids=0.0ms writeids=0.0ms deferspawn=0.0ms deferwait=0.0ms drain=0.0ms/0 pfskip=0 pfwait=0/0.0ms pfread=0 pfpub=0 pfhit=0 pfpredict=0 pevsave=0 pevforced=0 pfcached=0 usedpf=0 runs=317 avg_run=1.0 max_run=2 zerocopy=100% dynsplit=0
[moe-ssd] decode #1 tok=1 ... drain=0.0ms/0 (重复打印)
[moe-ssd] decode #2 tok=1 ... drain=0.0ms/0
[moe-ssd] decode #2 tok=1 ... drain=0.0ms/0
[moe-ssd] decode #3 tok=1 ... drain=0.0ms/0
```
补充: 非 moe-ssd 行的 drain/stage_wait 计数 = 0; `drain=0.0ms/0` 行数 = 16。

### 7. METRIC 行
```
L1d0.out:中国的四大发明是指**造纸术**、**指南针**、**[e2e][METRIC] leg=decode gen=16 wall_ms=8312 tok_s=1.92 load_ms=6934
```

## md5 对账 (设备侧 vs 本地, adb pull 至 _probe/mesa_legs/routeA_1026/)

| 文件 | 设备侧 md5 | 本地 md5 | 一致 |
|---|---|---|---|
| L1d1.tok | 80d8e485d45da5232748857bacc3ba96 | 80d8e485d45da5232748857bacc3ba96 | YES |
| L1d1.out | 6be3ddfe31c0d6b9e63d5a4f553bd6c0 | 6be3ddfe31c0d6b9e63d5a4f553bd6c0 | YES |
| L1d0.tok | 80d8e485d45da5232748857bacc3ba96 | 80d8e485d45da5232748857bacc3ba96 | YES |
| L1d0.out | 9ed8144019d1e2492e21052502f00f01 | 9ed8144019d1e2492e21052502f00f01 | YES |

(.err 未 pull, 仅贴 grep 行。)

## 判读

1. **腿A write 是否出现 nblk>0?** 否。腿A (ASYNC=1) write blk=4066 nblk=0 —— 非阻塞写路径在垫片层面完全不可见。
   **腿B write_blk 高 nblk=0?** 是, 且与腿A 完全相同 (blk=4066 nblk=0)。即 DRAIN_ASYNC=1 没有把任何 write 迁移到非阻塞路径, 两腿 write 全部走阻塞。
2. **两腿 health:** 完全打平, 均=2 (16-token 窗口内命中 造纸+指南针), 且两腿 tok md5 逐位相同 (80d8e485...) ⇒ 同层级健康、OPFLUSH=1 下两腿输出都正确。**CLCOUNT 三行逐字节相同** (nd/flush/finish/wait、read/write/map blk/nblk、flush_with_pending n/avg/max/sum 全部一致) ⇒ 本跑中 DRAIN_ASYNC 对 shim 可见行为零差异。write157 无法归因到 T3 drain: 因为两模式下 drain 均无动作 (moe-ssd 全部 drain=0.0ms/0), A/B 对照失去区分度——write4066/157 量在两条 env 下一模一样, 说明它由与 drain 模式无关的公共路径 (T1/T4 类常规阻塞写) 产生, **不是 T3 drain 产生**; 但也需注意另一解释: 该 env 在此引擎 build 中可能根本未被消费 (见 6 项采集: 无任何 DRAIN_ASYNC 生效日志, drain=0.0ms/0 ×16), 需源码核对 LLAMA_MOE_DRAIN_ASYNC 是否被读取。
3. **同步税净影响方向:** 每腿 KGSLSUBMIT 均 38103 (完全相同), tok_s: A(异步)=1.88 vs B(同步)=1.92, 差 2.1% (gen=16 的小样本噪声级), 且方向上"异步"腿反而略慢。结论: **DRAIN_ASYNC 对同步税净影响 ≈ 0, 无可见降税收益**; 配合 nd/flush/wait/KGSLSUBMIT 逐项相同, 本次 A/B 不构成有效对照, write157/同步税归因需先确认 env 生效 (或改用更长的 gen 窗口 / 直接检查引擎是否读取 LLAMA_MOE_DRAIN_ASYNC)。
