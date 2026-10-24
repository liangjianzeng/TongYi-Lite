#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Land map 20.39 (740 launch budget + what actually blocks GPU-beats-CPU) and update G-776, add G-777."""
import io

MAP = 'docs/全GPU卸载_架构全景地图_2026-10-21.md'
GRID = 'docs/Mesa与Vulkan线_架构问题网格_2026-10-21.md'

CENSUS = [
    (u'MUL_MAT', 363.8, u'真计算'),
    (u'ADD', 170.4, u'胶水（残差）'),
    (u'GET_ROWS', 162.9, u'胶水（行抽取）'),
    (u'SIGMOID', 126.4, u'胶水（MoE 门/ sigmoid 路由）'),
    (u'SCALE', 118.8, u'胶水'),
    (u'CPY', 109.7, u'胶水（搬运）'),
    (u'ARGSORT', 105.0, u'胶水（top-k 用排序实现）'),
    (u'MUL_MAT_ID', 101.9, u'真计算（MoE 专家）'),
    (u'CONCAT', 100.5, u'胶水（拼接）'),
    (u'SSM_CONV', 82.2, u'真计算（SSM）'),
    (u'CONT', 82.2, u'胶水（凑连续）'),
    (u'SILU', 82.2, u'胶水（激活）'),
    (u'SUM_ROWS', 70.0, u'胶水'),
    (u'MUL', 64.0, u'胶水'),
    (u'RMS_NORM', 54.8, u'胶水'),
    (u'SWIGLU', 53.2, u'胶水'),
    (u'SET_ROWS', 44.1, u'胶水（KV 写回）'),
    (u'CLAMP', 35.0, u'胶水'),
    (u'DIV', 35.0, u'胶水'),
    (u'FILL', 35.0, u'胶水'),
    (u'GATED_DELTA_NET', 27.4, u'真计算（gdn）'),
    (u'ROPE', 18.2, u'真计算'),
    (u'SOFT_MAX', 9.1, u'真计算'),
]
REAL = sum(c for _, c, k in CENSUS if k.startswith(u'真计算'))
GLUE = 2052 - REAL

SECTION = u'''

### 20.39 740 的**发射预算账**：真正挡住「GPU 压过 CPU」的是 ~1450 次/token 的胶水算子 🟪

用户定调：**本项目小模型优先，超大 MoE 与 GPU 优化只是实验**；本轮目标 = 追 GPU，先回答"现在什么挡住了"。
答案用一次完整普查说清楚（`e2e_instr` + `GGML_OPENCL_NODER_STATS=1`，24 token，`MOE_FORCE_A7X=1`，
**全部 60 种算子**，同一列名取最大累计 ÷ 24）：

| 算子 | 次/token | 类别 | | 算子 | 次/token | 类别 |
|---|---|---|---|---|---|---|
'''
half = (len(CENSUS) + 1) // 2
for i in range(half):
    a = CENSUS[i]
    b = CENSUS[i + half] if i + half < len(CENSUS) else (u'', 0.0, u'')
    SECTION += u'| `%s` | %.1f | %s | | `%s` | %s | %s |\n' % (
        a[0], a[1], a[2], b[0], ('%.1f' % b[1]) if b[0] else u'-', b[2])
SECTION += u'''
（表内 top-23 之外还有 ~37 种长尾算子；总数 **2052 次/token**。）

**预算账（这就是答案）：**

| 项 | 次/token | 说明 |
|---|---|---|
| 真计算（`MUL_MAT`/`MUL_MAT_ID`/`SSM_CONV`/`GATED_DELTA_NET`/`ROPE`/`SOFT_MAX`） | **%d** | 省不掉 |
| **胶水**（`ADD`/`GET_ROWS`/`SIGMOID`/`SCALE`/`CPY`/`ARGSORT`/`CONCAT`/`CONT`/`SILU`/`SUM_ROWS`/`MUL`/`RMS_NORM`/`SWIGLU`/`SET_ROWS`/`CLAMP`/`DIV`/`FILL` + 长尾） | **%d（71%%）** | 发射次数的大头 |
| 740 驱动每次提交往返（热态实测） | ~400 µs | §20.35 |
| ⇒ 胶水单独应付的代价 | **~580 ms** | 1450 × 400 µs |
| 实测每 token | **294 ms** | 说明实际约有 2× 的异步重叠 |
| 同机 CPU 后端 | **80 ms**（12.50 tok/s） | §20.36 的参照 |

**所以拦住目标的不是任何一个内核，是发射次数本身。** 要在 740 上让 GPU 追上 CPU 的 80 ms/token，
按 ~400 µs/次 就得把 **2052 次压到 ~200 次/token**（或把驱动往返压到 ~100 µs，那是驱动侧的事，我们改不动）。

**据此更正我自己上一轮定的靶子（重要）**：§20.38 我把"放开 `MM_GLU` 到 Q4_0/Q4_1"列为 ① 号，**错了**。
读码后确认 `ggml_cl_mul_mat_q4_k_glu_fused` 是**专写死的 Q4_K 图像路径内核**（还包在
`#ifdef GGML_OPENCL_USE_ADRENO_KERNELS` 里），要吃 Q4_0/Q4_1 等于**新写一个融合内核**，
而它省的只是 FFN 的 gate+up+GLU 三并一 ⇒ 25 层 ×2 = **50 次/token = 2.4%%**。**投入产出比不合格，撤下。**

**真正的杠杆按性价比重排（全部先测后写，禁止拿"算子数降了"单独当战功）：**

| 顺序 | 目标 | 涉及算子 | 预期省 | 先做的验证 |
|---|---|---|---|---|
| ① | **MoE 路由链**（sigmoid 门 + 排序 top-k + 归一化 + 填充） | `SIGMOID` 126 + `ARGSORT` 105 + `SCALE` 119 + `CLAMP` 35 + `DIV` 35 + `FILL` 35 + `SUM_ROWS` 70 ≈ **525** | **~26%%** | 先跑 `LLAMA_MOE_*` 工装开关扫描（App 镜像 vs 全关 vs 默认），看这些胶水是不是**我们 fork 的拆分/预取自己塞进图的** |
| ② | **数据搬运族** | `CPY` 110 + `CONT` 82 + `CONCAT` 101 ≈ **292** | ~14%% | 逐条查来源（多半是 KV 写回 / 位置与掩码准备 / 为凑连续而拷），能消则消 |
| ③ | **`GET_ROWS` 163** | 行抽取 6.5/层 | ~8%% | 查是不是 rope/嵌入/门控逐层重复抽取 |
| ④ | `MM_GLU` 扩类型 | FFN 三并一 | 2.4%% | **降级为"顺手"**，不单独立项 |

**三条纪律。**
⑴ **只有算子数下降 + tok_s 上升 + 交替两组不重叠（R8(e)）才算战功**，只降算子数一律作废。
⑵ **上限要说死**：即便把 ①②③ 全做成（−817 次/token ≈ −40%%），740 上 GPU 也只到 ~5.5-6 tok/s，**仍低于 CPU 的 12.50**；
所以"740 上 Ling 的 GPU 压过 CPU"这个目标，**没有整图级融合（megakernel）就没有出路** —— 而 megakernel 与"小模型优先"相悖，
属实验线。这条判断要在设备窗口里用 **G-777**（dense 小模型对照）证伪或坐实。
⑶ **设备窗口纪律**：740 的 adbd 今天掉线三次（最后一次开局即死，导致一轮扫描 0 数据）。已把整套动作固化成
`third_party/mesa-kgsl/scripts/run_740_launch_budget.sh`（自带上线重试门、R8(h) 结构必录、算子普查 top-8 随行打印、
CPU 参照腿、App 侧 logcat 指引），下一个窗口一条命令跑完。
''' % (REAL, GLUE)


def main():
    s = io.open(MAP, encoding='utf-8').read()
    assert u'20.39 740 的**发射预算账**' not in s, u'20.39 已存在'
    io.open(MAP, 'w', encoding='utf-8').write(s.rstrip('\n') + '\n' + SECTION)
    print(u'地图：20.39 已追加（含 60 种算子普查表 + 预算账）')

    g = io.open(GRID, encoding='utf-8').read()
    lines = g.split('\n')
    hit = 0
    for i, ln in enumerate(lines):
        if ln.startswith(u'| **G-776** |') and u'发射预算' not in ln:
            f = ln.split(u'|')
            f[6] = f[6].rstrip() + (
                u'；**🟪 2026-10-23 09:2x 更正靶子（§20.39）**：全量普查 60 种算子 = **2052 次/token**，'
                u'真计算仅 %d（29%%）、胶水 %d（71%%：ADD 170 / GET_ROWS 163 / SIGMOID 126 / SCALE 119 / CPY 110 / '
                u'ARGSORT 105 / CONCAT 101 / CONT 82 / SILU 82 / SUM_ROWS 70 / MUL 64 / RMS_NORM 55 / SWIGLU 53 / '
                u'SET_ROWS 44 / CLAMP+DIV+FILL 各 35 + 长尾 ~37 种）。按 ~400 µs/次 ⇒ 光胶水 ~580 ms，实测 294 ms（约 2x 重叠）；'
                u'CPU 参照 80 ms ⇒ **必须把 2052 压到 ~200 才可能压过 CPU**。**上一轮把 MM_GLU 列为 ① 号是错的，已撤**：'
                u'它是写死的 Q4_K 图像路径内核，扩 Q4_0/Q4_1 要新写内核，只省 50 次/token（2.4%%），投入产出不合格。'
                u'重排后 ①MoE 路由链 ~525 次 ②搬运族 CPY+CONT+CONCAT ~292 次 ③GET_ROWS 163 次。'
                u'下一发用 `third_party/mesa-kgsl/scripts/run_740_launch_budget.sh`（自带 R8(h) 机检）；'
                u'**上限说死：全做成也只到 ~5.5-6 tok/s，仍低于 CPU 12.50 ⇒ 无 megakernel 无出路**'
                % (int(REAL), int(GLUE))) + u'（详见 §20.39） '
            lines[i] = u'|'.join(f)
            hit += 1
    assert hit == 1, hit
    assert u'G-777' not in g
    last = max(i for i, l in enumerate(lines) if l.startswith(u'| **G-777** |')) if any(
        l.startswith(u'| **G-777** |') for l in lines) else max(i for i, l in enumerate(lines) if l.startswith(u'| **G-7'))
    g777 = (u'| **G-777** | **发射预算假设的可证伪推论：dense 小模型在 740 上不该输给 CPU**（每 token 提交次数低一个量级 '
            u'⇒ 若 dense 小模型也输给 CPU，就说明 740 的问题不是算子数而是驱动提交路径本身，路线判"740 GPU 不可用"，'
            u'所有模型走 CPU 后端） | L6×M4/M3 | `OWN` | **未观测** | **下一发（一条命令）**：'
            u'`third_party/mesa-kgsl/scripts/run_740_launch_budget.sh` 换 `M=` 指向目录里的 **dense 小模型**'
            u'（MiniCPM5-2B Q4_K_M 优先，AGENTS 机型分级要求 740 口径）跑 BASE 与 CPUONLY 两腿，'
            u'**判据：GPU 腿 tok_s > CPU 腿 ⇒ 假设成立（Ling 的病是算子数，走 ①②③ 融合线）；'
            u'GPU 腿 <= CPU 腿 ⇒ 假设破产，740 的 GPU 线整体判不可用**。两腿都必须录 `splits`/`selected platform`/'
            u'`offloaded` 与算子/token，缺任一项作废（R8(h)） |')
    lines.insert(last + 1, g777)
    io.open(GRID, 'w', encoding='utf-8').write(u'\n'.join(lines))
    print(u'网格：G-776 已更正靶子，新增 G-777')


if __name__ == '__main__':
    main()
