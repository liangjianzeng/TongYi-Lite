# 任务简报：SPARK-X2.6-4B NPU prefill 转换链攻坚（子智能体全权执行）

## 目标
把 Spark-X2.6-4B 的 prefill 静态图（seq=512）推过 QAIRT 转换链，在小米13(740/Hexagon V73) 和 K90(830/V79) 上用 qnn-net-run 采 NPU pp512 t/s，写入 `E:/MyLLM_exp/M1_npu_results.md`。

## 已就位资产（勿重做）
- ONNX：`E:/MyLLM_exp/spark_prefill_seq512.onnx`（5.7MB 图 + 8.2GB .data，dynamo 导出，seq=512 prefill 无 KV，input_ids[1,512] int64 → logits）
- 修复链产物：fix3（onnxsim+int32）→ fix5（per-slice int32，无删除）→ fix7/fix9（Expand→Mul 各种尝试）
- HF 源：`D:/MyLLM/models/spark-x26-4b/hf/`（safetensors + modeling_spark.py）
- QAIRT 2.44.0.260225：`D:/MyLLM/qairt/2.44.0.260225/`（含 Linux 工具，WSL2 用）
- 远程 PC：ssh jianz@100.100.140.75 密码 Lxt201223（paramiko 已装在本机）
- WSL2 Ubuntu-22.04（用户 liang）：python3.10 + onnx 1.16.2 + onnxsim；libc++ 三件套已解包在 `/mnt/e/MyLLM_exp/cppx/usr/lib/{llvm-14,x86_64-linux-gnu}/`；NDK r27c 在 WSL `~/m4/android-ndk-r27c`
- 设备：740=100.109.138.2:5555（也可本机 USB 98fc9410），830=192.168.1.88:5555（tailnet 100.75.247.55）。两机 `/data/local/tmp/npu_m1/{bin,lib}` 已部署（qnn-net-run、全代 stub+skel），GGUF 也在
- 本机 adb：`D:\TongYi-Lite\.tmp_platform_tools\platform-tools\adb.exe`（K40=8b1e8747、740 USB=98fc9410、830 LAN=192.168.1.88:5555）
- 基线（闸门分母）：740 GPU pp512=16.94（Qwen 参照 33.02）、830 GPU=147.56（149.35）、CPU ~8.5-9.2

## 已确认的死路（勿再踩）
1. **Windows 版 QAIRT modeltools 有未初始化内存 bug**：Slice/Reduce 参数读出每次不同的垃圾值 → 转换一律走 WSL2 Linux 工具链（libc++ 已配好）
2. **QNN Expand 校验**：`validateQnnOpConfig` 要求 Expand 两输入同 dtype，且 shape 参数被强制 int32 → fp16 数据永远过不了。Expand→Mul(ones) 也被同一校验咬（当前卡点：`node_expand_4_mul` 0x216 vs 0x232，converter 认为数据侧是 int32 但 ONNX value_info 是 fp16，原因未明）
3. transformers 必须 4.57.1（5.x 撞 remote code 的 _tied_weights_keys list 格式）；onnx 必须 1.16.2（QAIRT 依赖 `onnx.version`）
4. 导出脚本 `D:\TongYi-Lite\_probe_m1\export_prefill.py`（已传远程 `E:/MyLLM_exp/` 同名）：attn_implementation="eager"、dynamo=True、PYTHONIOENCODING=utf-8 必须（GBK 控制台会崩在 ✅ emoji）
5. cmd 转义陷阱：本工具链里反斜杠路径会被吃，一律正斜杠；长 bash 逻辑写成 .sh 文件 sftp 到 /mnt/e 再 `wsl -- bash /mnt/e/...` 执行

## 推荐攻坚路线（按序尝试）
### 路线 A（首选）：重写导出，消灭 Expand/动态形状
写自定义 forward 包装（参考 `D:\TongYi-Lite\_probe_m1\modeling_spark.py` 已读过的结构：q_k_v_proj 融合 QKV[4096+1024+1024]、g_proj headwise sigmoid 门控、partial RoPE full=0.25/sliding=1.0、GQA 16:4、3:1 层比、GELU MLP、RMSNorm）：
- rope **常量折叠**：positions 固定 0..511 → cos/sin 全图常量（fp16 initializer，尺寸 [1,16,512,256] 直接按 16 头预展开，绕开 GQA repeat 的 Expand）
- GQA 用 grouped view：q.view(1,4,4,512,256) 与 k/v [1,4,512,256]，scores=einsum('bgqd,bkd->bgqk')，避免 repeat_kv 的 expand/tile
- 门控 g_proj 输出 [1,512,16] → sigmoid → unsqueeze 成 [1,16,512,1] 与 attn_out [1,16,512,256] 相乘（broadcast Mul，无 Expand）
- 导出后 ONNX 里应无任何 Expand/Tile 节点（断言检查），int64 initializer 清零（int32 全覆盖）
- 转换：WSL `qnn-onnx-converter --input_network X.onnx --output_path Y`（出 .cpp/.bin）→ `qnn-model-lib-generator -c Y.cpp -b Y.bin -o outdir -t aarch64-android`（ANDROID_NDK_ROOT=/mnt/d? 注意 WSL NDK 在 ~/m4/android-ndk-r27c，用 /home/liang/m4/... 路径）→ 推 libY.so 上设备 → 设备侧 `qnn-context-binary-generator --model Y.so --backend libQnnHtp.so --binary_file Y_ctx --output_dir /data/local/tmp/npu_m1/`（ADSP_LIBRARY_PATH=/data/local/tmp/npu_m1/lib）→ `qnn-net-run --retrieve_context Y_ctx --input_list input.list --backend libQnnHtp.so`
- 输入 list/raw：input_ids int32 [1,512] 随机 token（若 QNN 要 int32；int64 则对应造 raw）
### 路线 B（A 卡死时的退路）
继续修 fix9 的 dtype 幻影：用 converter debug（--debug）看 tensor 55/56 的真实身份；或把 add_4→Cast(fp16) 这条链手动常量折叠（cos/sin 静态化思路同 A 的 rope 常量折叠，但只做图变换不做重导出）

## 设备侧执行模板（已验证可用的环境变量）
```
export LD_LIBRARY_PATH=/data/local/tmp/npu_m1/lib
export ADSP_LIBRARY_PATH="//data/local/tmp/npu_m1/lib;native"
/data/local/tmp/npu_m1/bin/qnn-net-run --backend /data/local/tmp/npu_m1/lib/libQnnHtp.so --retrieve_context <ctx> --input_list <list> --output_dir /data/local/tmp/npu_m1/out
```
profiling 时间戳（--profiling_options basic/detailed）务必留下——"打印过 QNN 不算跑过"。

## 纪律
- 只写 `E:/MyLLM_exp/` 和设备 /data/local/tmp/npu_m1/；不碰 git 仓、不 commit、不 push
- 每次失败把完整 traceback 记到 `E:/MyLLM_exp/conv_attempts.log`（追加式），失败清单本身就是 R3 op 审计数据
- 830 若掉线（手机休眠）就先做 740；两机数据分开记
- 预算：within reason 迭代；若路线 A+B 都 6 次尝试仍不过，写清失败清单收尾

## 交付物
`E:/MyLLM_exp/M1_npu_results.md`：两机 NPU pp512 t/s + 闸门判定（740 ≥2×16.94=33.9；830 ≥3×147.56=442.7；功耗判据另测）+ 全部中间产物路径 + 失败清单。
