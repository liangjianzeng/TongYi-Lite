# pre2（chunked-prefill KV 输出）追加冻结 — 2026-11-10

承接 dec2 decode 线（13 文件）。本批 = 「prefill 输出 KV cache」缺件的完整定罪与验收链，
验收结论见 `NPU线_MiniCPM5整模型验收_2026-11-09.md` §十，坑 44–50 见交接档。

## 新增文件

| 文件 | 作用 |
|---|---|
| `chain_run5.cpp` | 最终版 runner：ROLL N-row（prefill 每 chunk 发射 S 行）+ `{t}` 展开 + `CR5_T0` + `CR5_ROLL_SAVE` + `CR5_GATE`（**counter 是 `<dir>/counter` 目录内文件**——残留 counter 会让闸门裸奔，坑 47 前身事故） |
| `mcp5_63_export_dec2.py` | dec2/pre2 导出器（DEC_S=128 即 pre2）：**BRANCH_{k}_COS 敏感判据**（attn 分支单判，防 residual 掩蔽）+ amask 输入 + ao flatten-then-transpose（坑 49）+ proj view 修正（坑 44） |
| `mcp5_73_pre2_io.py` | pre2 l0 设备 IO + HF 滚窗参照（`pad = NC - c*S` 坑 50 修正式） |
| `mcp5_75_pre2_judge.py` | 设备 cache 新行/终态 vs HF 判分 |
| `mcp5_76_run_pre2_l0.sh` + `manifest_pre2_l0` | l0 4-chunk 设备验证驱动（含熄屏红线检查） |
| `mcp5_76c_judge.py` | 设备 IO 字节序定罪探针（hs/cos 候选读法 ORT 对号，坑 45） |
| `mcp5_77_pre2_prep.py` | 真 512-token prompt e2e 参照/IO（embed 转置表、per-block (hd,s) rope 表、amask、HF 全前向 logits ref） |
| `mcp5_78b_batch_pre2.sh` | 42 ctx 批量 build（PARA=2，经 mcp5_65） |
| `mcp5_79_run_pre2_full.sh` | 全链 3 进程闸门驱动（gate 目录重建、CR5_ROLL_SAVE、等待条件=CR5_DONE+进程存活，防坑 42 复发） |
| `mcp5_79_gen_pre2_manifests.py` | 3 份闸门 manifest 生成器（每层从 ctx dump 取 id/dims，勿硬编码） |
| `mcp5_79j_judge.py` | e2e 判分（l41 末行 (hid,s) 取列 S-1 → host norm+head → logits vs HF） |
| `mcp5_79m_bisect.py` / `79n_perm_scan.py` / `79q_pad_probe.py` | 坑 49/50 定罪三探针：节点级 spy（scores/probs 1.0 而 attn_out 0.258 → 布局）、排列族扫描（permute 行序错复现 maxdiff 5.15）、pad-mask 三方（HFlayer\|HFfull 0.8586 → mask 语义自错） |

## 复跑入口

```bash
# 1) 导出（DEC_S=128 即 pre2；BRANCH 判据全绿是闸门）
DEC_NC=512 DEC_S=128 DEC_NTAB=512 python3 mcp5_63_export_dec2.py all
# 2) build：bash mcp5_78b_batch_pre2.sh 0 41（PARA=2）
# 3) manifest：python3 mcp5_79_gen_pre2_manifests.py
# 4) 设备：bash mcp5_79_run_pre2_full.sh（DEV=<redacted-serial> 默认）
# 5) 判分：python3 mcp5_79j_judge.py   # 期望 cos 1.0000 / top8 8/8
```

性能：exec 关键路径 ~116 tok/s（mask 版 ~26ms/层/chunk vs 无 mask 10ms，broadcast-add
~2.5× 代价，优化候选=mask 折叠/降维）；wall ~9.5s 含 42 ctx 启动税。
