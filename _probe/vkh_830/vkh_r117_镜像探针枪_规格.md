# R-117 · 镜像能力探针枪（IMAGE_MAX_BUFFER_SIZE 硬闸 + A 路可行性前置）—— 交付父腿侧先跑，**先于一切 diff**
作者 vkh｜ 纪律：不碰产品码、不碰 740（父车道）、屏幕全程不点亮、构建父代跑

## 0. 这支枪回答的两个生死问题（编译 diff 之前必须知道）
1. **硬闸**：LFM2.5-24B 的 batched `q_img` 需要 `image_width = E*q_layer/4 = 64×1 572 864/4 = **25 165 824 px**`，是已跑通的 ling（12 582 912 px）的 **2 倍**。`CL_DEVICE_IMAGE_MAX_BUFFER_SIZE` 不够 ⇒ **A 路在 LFM 直接死刑**。
2. **A 路姿势可行性**：A 路 = 在 `origin = es_base*q_layer` 的**子缓冲**之上 `clCreateImage`。rusticl 若不支持"image over sub-buffer"，A 路当场死刑（与宽度无关）。

## 1. 三件枪（md5）
| 件 | 用途 | md5 |
|---|---|---|
| `vkh_imagecap.c`（248 行） | 探针本体：dlopen + 能力读取 + **真建 image 阶梯** + **子缓冲建图** + 阴/阳性对照 | `23996ca60176a7bac28a19ba94467a7e` |
| `vkh_imagecap_build.sh` | 宿主构建（**glibc aarch64，非 NDK**，与腿同栈；`-I third_party/OpenCL-Headers` = 与产品库同源常数） | `e1f2f1dd55de047e1f6de88fe4434029` |
| `vkh_imagecap_740.sh` | 腿侧驱动（四闸 + 双端真 sha256 + 判读 + 红牌） | `a2a64b779500064e5d4256416978f7bb` |

**跑法（父）**：`bash vkh_imagecap_build.sh` → `DRY=1 bash vkh_imagecap_740.sh`（排练，我已跑通 rc=0）→ `bash vkh_imagecap_740.sh`（真跑）。
可调免重编：`VKH_IC_Q_LAYER/VKH_IC_E/VKH_IC_ES_BASE/VKH_IC_LING_W/VKH_IC_LFM_W`。

## 2. 输出契约（父侧直接 grep，机检不靠人眼）
```
#### IMAGECAP loaded=… platform="…Mesa…" vendor="…" version="…"
#### IMAGECAP dev="…" drv="…" image_support=1 max_buffer=… max_array=… max_alloc=… global_mem=… max_wi0=…
#### IMAGEPROBE tag=selftest_tiny kind=direct fmt=0x10b1/0x107d width=1024 bytes=4096 rc=0
#### IMAGEPROBE tag=ling_width kind=direct fmt=… width=12582912 bytes=… rc=…      # 三格式各一
#### IMAGEPROBE tag=lfm_width  kind=direct fmt=… width=25165824 bytes=… rc=…       # ← 硬闸
#### IMAGEPROBE tag=a_route   kind=subbuf origin=50331648 size=100663296 rc=…      # ← A 路姿势
#### IMAGEPROBE tag=a_route_qimg kind=subbuf_origin width=25165824 bytes=… rc=…
#### IMAGEPROBE tag=a_route_negctl_unaligned origin=1 rc=… as_expected             # 阴性对照
#### IMAGECAP_VERDICT ling=PASS|FAIL lfm=PASS|FAIL a_route=PASS|FAIL gate=25165824 …
#### IC_VERDICT=GO_A_ROUTE | NO_GO | INVALID | WRONG_DRIVER
```
退出码：`0` 可行 / `1` 不可行 / `2` 探针自毁（结论作废，**不许据此决策**）。

## 3. 判读决策树（我已经把三条后路先算好，父拿到数就能直接分流）
| 结果 | 含义 | 下一步（零成本预案） |
|---|---|---|
| `lfm=PASS` 且 `a_route=PASS` | A 路可行 | **我明日交 A 路 diff**（含表行 + 三族 pin 同步） |
| `lfm=FAIL`（`max_buffer < 25 165 824`） | batched 全宽镜像在 LFM 不可能 | **改打环2 那条 dense-loop 路**：逐专家 image 只需 `q_layer/4 = 393 216 px`，比 ling 的 12.58M 还小 **32 倍** ⇒ 硬闸天然满足；封卷的 `vkh_r115_环2_q4_1_MoE_提案.md` 那套（q4_0/q4_K 版）直接复活成为 LFM MoE 主路 |
| `a_route=FAIL`（子缓冲建图 rc≠0） | A 路姿势本身不成立 | batched 只剩 B 路（加参数）⇒ **需请父重议 B 路搁置令**（我会附 E031.47 前科风险评估） |
| `INVALID` / `WRONG_DRIVER` | 探针无效 | 重跑；**不得**据此改产品码 |

## 4. 内建的防哑火（本枪自己抓到的才写得进来）
- **哑火 #25（新）— 测错驱动 = 假 PASS 比没测更坏**：740 腿 = glibc CLRT sysroot + Mesa ICD，**不是** Android `/vendor/lib64/libOpenCL.so`。本枪与父 `b_line_740.sh` **逐字同栈**（同 `$R`/`$LOADER`/`$LP`，`OCL_ICD_VENDORS=$ICD`），并强制 **`RUSTICL_ENABLE=kgsl`**（少了它 rusticl 可能不绑 Adreno 而落 llvmpipe ⇒ 镜像上限另算 = 假数）；最后校验报告里 `vendor=` 含 Mesa/rusticl，否则 `IC_VERDICT=WRONG_DRIVER` + exit 2。
- **编译门自证**：`gcc -Wall -Wextra -Werror=int-conversion` 下 **0 warning**；这道门当场抓到我自己的 **3 处指针截断 bug**（`clCreateBuffer`/`clCreateSubBuffer`/`clCreateContext` 我误写成返回 `cl_int` ⇒ aarch64 上句柄被截成低 32 位 = 探针会给假结果）。
- **阳性对照**：`tag=selftest_tiny`（1024 px 极小 image）必须 rc=0，否则 `IMAGECAP_ABORT_SELFTEST` + exit 2（整支枪作废，不带病出结论）。
- **阴性对照**：故意 `origin=1` 的非对齐子缓冲**期望失败**；若驱动接受它，打印 `(!)UNALIGNED_ORIGIN_ACCEPTED` ⇒ 说明对齐门是摆设，A 路的对齐前置必须加严。
- **哑火 #23 同款**：push 后**设备端真 `sha256sum`** 与宿主比对，不等即 abort。
- **四闸**（我的老规矩）：温闸（纯 I/O = 400）、`stay_on_while_plugged_in` 机检（非 0 默认红牌，`FIX_STAYON=1` 才归零）、**有腿在跑就让路**（`ling_e2e|llama-cli|lfm2` 命中即 abort，绝不惊动父腿）、装载证明改行为**驱动归属证明**（本枪不涉 libggml-opencl，无 bin= 红卡可抄）。
- 排练自证：`DRY=1` 全链 rc=0；排练中另抓到并修掉 2 处（DRY 态假温度污染闸门、DRY 态拿假 md5 比对）。

## 5. 我要父回的一件事
父腿侧跑完把 `#### IMAGECAP ` 两行 + `#### IMAGECAP_VERDICT` 一行贴回即可（日志落 `$R/out/imagecap_740_<ts>.log`）。**`lfm=PASS && a_route=PASS` 我明日交 A 路 diff**；否则按 §3 分流，A 路不再烧。
