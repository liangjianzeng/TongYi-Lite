#!/usr/bin/env bash
# [npu-line] MiniCPM5-2B QNN/HTP 整模型一键自测（740 验收 2026-11-09：logits cos 0.9999、top-6 全一致）。
#
# 干的事：设备资产核对 → 44 层 + norm 串链（chain_run2）→ norm 输出显式 transpose
# → head（vocab 130560）单跑 → WSL 判分（HF 参考 logits cos + top-6）。
# 布局铁则（踩过的坑，勿改）：层间输出 T-layout [1,2048,16] 线性直传；
# norm 输出是 natural [1,16,2048]，喂 head 前必须 transpose——当年 devchain 生成器
# 把这步写丢过，"分两段跑"才是验收真配方（见 NPU线_MiniCPM5整模型验收_2026-11-09.md）。
#
# 用法（Git Bash）：
#   DEV=<adb序列号> bash tool/npu_selftest.sh    # 序列号真值见私有区映射表，不落仓
# 依赖：adb；WSL Ubuntu-22.04（numpy + /home/liang 下的 HF 参考 npy）；
#       主机资产 SERVE_DIR（默认 E:/MyLLM_exp/serve）与 RB_DIR（默认 E:/MyLLM_exp/_repro/rb）。
set -uo pipefail

DEV="${DEV:-}"   # adb 序列号属私有值（真值见私有区映射表 <redacted-serial-740>/<redacted-serial-830>），仓内不落字面量
ADB="${ADB:-$LOCALAPPDATA/Android/Sdk/platform-tools/adb.exe}"
SERVE_DIR="${SERVE_DIR:-E:/MyLLM_exp/serve}"
RB_DIR="${RB_DIR:-E:/MyLLM_exp/_repro/rb}"
WSL_DIST="${WSL_DIST:-Ubuntu-22.04}"
D=/data/local/tmp/npu_m1
STAGE="${STAGE:-E:/wsl_stage}"
export MSYS2_ARG_CONV_EXCL="*"

fail() { echo "✗ $1" >&2; exit 1; }
[ -n "$DEV" ] || fail "请传设备序列号：DEV=<adb序列号> bash tool/npu_selftest.sh（740/830 真值见私有区映射表）"
[ -x "$ADB" ] || command -v "$ADB" >/dev/null || fail "adb 未找到（ADB=<路径> 指定）"
"$ADB" -s "$DEV" get-state >/dev/null 2>&1 || fail "设备 $DEV 不在线"
mkdir -p "$STAGE"

echo "== 1/5 设备资产核对 =="
NCTX=$("$ADB" -s "$DEV" shell "ls $D/spark_l*_ctx.bin 2>/dev/null | wc -l" | tr -d '\r')
[ "${NCTX:-0}" -ge 46 ] || fail "设备缺 ctx（$NCTX/46）；从 $SERVE_DIR push：cp \$SERVE_DIR/spark_l*_ctx.bin 后 adb push"
for f in bin/chain_run2 lib/libQnnHtp.so lib/libQnnHtpV73Skel.so mcp5_emb_T.raw; do
  "$ADB" -s "$DEV" shell "test -f $D/$f" 2>/dev/null || fail "设备缺 $D/$f"
done
[ -f "$SERVE_DIR/spark_l0_ctx.bin" ] || echo "（提示：主机 $SERVE_DIR 无资产，设备资产将被独占使用）" >&2

echo "== 2/5 生成并执行 44 层 + norm 链（HTP）=="
# dims/张量名全部是验收固化值；norm 输出 natural 是下一步 transpose 的前提
{
  echo '#!/system/bin/sh'
  echo "cd $D"
  echo "export LD_LIBRARY_PATH=$D/lib"
  echo "export ADSP_LIBRARY_PATH=$D/lib"
  echo 'set -e'
  echo "./bin/chain_run2 l0 spark_l0_ctx.bin l0 hs 1 f2 1,2048,16 mcp5_emb_T.raw h 90 f2 1,2048,16 L0_out.raw 1"
  for k in $(seq 1 41); do
    echo "./bin/chain_run2 l$k spark_l${k}_ctx.bin l$k hs 1 f2 1,2048,16 L$((k-1))_out.raw h 90 f2 1,2048,16 L${k}_out.raw 1"
  done
  echo "./bin/chain_run2 l998norm spark_l998norm_ctx.bin l998norm hs 1 f2 1,2048,16 L41_out.raw h 7 f2 1,16,2048 L998norm_out.raw 1"
} > "$STAGE/npu_selftest_body.sh"
"$ADB" -s "$DEV" push "$STAGE/npu_selftest_body.sh" "$D/npu_selftest_body.sh" >/dev/null
"$ADB" -s "$DEV" shell "sh $D/npu_selftest_body.sh" 2>&1 | grep -E 'CHAIN_DONE|CH_FAIL' | tail -3
"$ADB" -s "$DEV" shell "test -f $D/L998norm_out.raw" 2>/dev/null || fail "norm 段未产出（看上面 CH_FAIL）"

echo "== 3/5 norm(natural)→head(T) 显式 transpose =="
"$ADB" -s "$DEV" pull "$D/L998norm_out.raw" "$STAGE/npu_selftest_nat998.raw" >/dev/null 2>&1 || fail "pull norm 失败"
wsl -d "$WSL_DIST" -- python3 -c "
import numpy as np
d = np.fromfile('/mnt/e/wsl_stage/npu_selftest_nat998.raw', dtype='<f2')
assert d.size == 16*2048, d.size
np.ascontiguousarray(d.reshape(16,2048).T).astype('<f2').tofile('/mnt/e/wsl_stage/npu_selftest_head_T.raw')
print('transpose ok')" || fail "transpose 失败（WSL/numpy 可用？路径挂 /mnt/e）"
"$ADB" -s "$DEV" push "$STAGE/npu_selftest_head_T.raw" "$D/npu_selftest_head_T.raw" >/dev/null

echo "== 4/5 head 层单跑（vocab 130560）=="
{
  echo '#!/system/bin/sh'
  echo "cd $D"
  echo "export LD_LIBRARY_PATH=$D/lib"
  echo "export ADSP_LIBRARY_PATH=$D/lib"
  echo "./bin/chain_run2 l999head spark_l999head_ctx.bin l999head hs 1 f2 1,2048,16 npu_selftest_head_T.raw logits 9 f2 1,130560,16 npu_selftest_head_out.raw 1"
} > "$STAGE/npu_selftest_head.sh"
"$ADB" -s "$DEV" push "$STAGE/npu_selftest_head.sh" "$D/npu_selftest_head.sh" >/dev/null
"$ADB" -s "$DEV" shell "sh $D/npu_selftest_head.sh" 2>&1 | grep -E 'CHAIN_DONE|CH_FAIL|wrote' | tail -2
"$ADB" -s "$DEV" pull "$D/npu_selftest_head_out.raw" "$STAGE/npu_selftest_head_out.raw" >/dev/null 2>&1 || fail "pull head_out 失败"

echo "== 5/5 判分（HF 参考）=="
wsl -d "$WSL_DIST" -- bash -c "
cp /mnt/e/wsl_stage/npu_selftest_head_out.raw /home/liang/head_out.raw \
  && python3 /mnt/e/MyLLM_exp/_repro/rb/mcp5_44_judge.py" | tail -4
RC=${PIPESTATUS[0]:-1}
[ "$RC" -eq 0 ] || fail "判分脚本异常（参考 npy 在 /home/liang？缺失则用 mcp5_41_layered.py MODE=embhead 重导）"
echo "✓ 通过标准：LOGITS cos ≥0.999 且 TOP1_MATCH True（验收基线：cos 0.9999、top6=[1 396 2570 7562 8 85]）"
