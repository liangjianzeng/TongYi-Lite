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
~2.5× 代价）；wall ~9.5s 含 42 ctx 启动税。
**2026-11-11 G2 更新：broadcast-add 代价已消**——导后 ONNX 手术 `Tile(amask,[2,8,1,1])`
使 scores Add 两侧同形（dynamo 会把 torch 侧物理 expand 折回广播，必须 post-export），
exec 4.7s → 2.35s ≈ **218 tok/s（14ms/pass，-47%）**，设备输出与 baseline **逐位一致**
（h/knew/vnew maxdiff=0），79j 复绿（cos 1.0000 / argmax / top8 8/8）。永久化在
`mcp5_78_stage_pre2.sh` staging 段（tileall 幂等注入）。

## G2 mask 优化工具（mcp5_92 系列）

| 文件 | 作用 |
|---|---|
| `mcp5_92_g2_variants.py` | 导后手术生成器：`tileall`=staged dec2p onnx 就地 Tile 注入（幂等）；l0 三变体（tile/const/nomask）供 A/B |
| `mcp5_92_gen_manifests.py` | A/B 单层 manifest 生成（从 ctx dump 读 gname/id/dims——图手术后 tensor id 漂移、amask dims NHWC 化但字节不变，坑 56） |
| `mcp5_92_run_g2ab.sh` | 单 l0 4-chunk 变体 A/B 测时（CR5_STEP exec 和；拉输出做逐位对比 + Dozing 红线检查） |
| `mcp5_92_build_dec2p.sh` | 42 层 Tile 化重建（**TAG 必须=dec2p_l{k}**：converter graph 名跟 `--output_path` TAG，错名 → manifest graphRetrieve 0x1773，坑 56） |
| `mcp5_78_stage_pre2.sh` | staging（copy 出 dec2p onnx）+ **tileall 注入**——图改动唯一正门（勿手改 serve_dec 里的 ctx 名，swap 命名不齐=0x1773/0x1774 连环坑） |

A/B 判据留档（单 l0，4-chunk exec 和）：baseline 120.7ms / **tile 77.2（-36%）** /
const 57.8（常数 mask 最快但要每 chunk 一 ctx=168 个，弃）/ nomask 68.8（地板）。
const/nomask 改 mask 语义、h 偏离属预期；tile 是唯一逐位无损变体。
