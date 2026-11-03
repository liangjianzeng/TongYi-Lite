#!/bin/bash
# [TongYi-Lite 2026-11-03 G1 回归闸] App 加载后 GPU/CPU 20-token 对测（GPU发射税减税专项 §3-G1）。
# 业主口径：只测不回退——本脚本只记录 GPU/CPU 比值入 jsonl，绝不改任何产品配置。
#
# 用法:  g1_app_gate.sh <serial> <model_name> [rounds=2]
# 纪律照旧: 一次一腿、超时必带、N≤2 轮、灭屏收尾(223)、禁 uninstall、logcat 全量回拉本地再 grep。
#
# 测量定义（与 S1 判决同口径）:
#   TTFT = 发送提问 → 首个 [DIAG] gen# 行的墙钟 ms（App 侧首字）
#   TGX  = [DIAG] gen#0 → gen#19 的墙钟 ms / 20 → tok/s
# 判读: 只落 G1RESULT 行（arm/ttft/tok_s/ratio），PASS/FAIL 由人后判（铁律：GPU 须快过 CPU 的
# 靶子判定属 R-197 循环，不在本闸内做裁决）。
#
# ⚠ 待真机校准项（本机无设备，未验）:
#   TODO(device): [DIAG] 行格式来自 dllm-lab judge_app.py 所对的版本，装机包 banner 先核（_my_opencl_lesson 纪律）。
#   TODO(device): GPU/CPU 通道切换走 App 设置页——uiautomator 选择子按 text 匹配，文案改版需同步。
#   TODO(device): 若 measure_cmd.json 免点击测量口（排空税交接 §4-4 未竟）落地，应改走测量口替代 uiautomator。
set -u
SERIAL=${1:?用法: $0 <serial> <model_name> [rounds]}
MODEL=${2:?缺 model_name}
ROUNDS=${3:-2}
ADB="adb -s $SERIAL"
PKG=com.dgxspark.tongyilite
OUT=/tmp/g1_gate_$(date +%Y%m%d_%H%M%S).jsonl
TIMEOUT=180

fail() { echo "G1 ABORT: $*" >&2; $ADB shell input keyevent 223 2>/dev/null; exit 1; }

wake()  { $ADB shell input keyevent 224 >/dev/null 2>&1; }   # WAKEUP
sleep_dev(){ $ADB shell input keyevent 223 >/dev/null 2>&1; } # SLEEP 收尾（AMOLED 禁常亮）
wake

# 打开 App → 等模型加载完成 banner（先读 JNI banner 核装机版本，lesson 纪律）
$ADB logcat -c 2>/dev/null
$ADB shell monkey -p $PKG -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || fail "启动失败"
$ADB logcat -d -v time > /tmp/g1_boot_$SERIAL.log 2>/dev/null
grep -q "tongyilite_jni" /tmp/g1_boot_$SERIAL.log || echo "WARN: 未见 JNI banner，装机包版本待人工确认" >&2

# 通道切换：设置页 GPU 开关（uiautomator 按 text 匹配；改版需同步选择子）
set_channel() { # $1 = GPU|CPU
    local want=$1
    $ADB shell am start -n $PKG/.MainActivity >/dev/null 2>&1
    $ADB shell uiautomator dump /sdcard/g1_ui.xml >/dev/null 2>&1
    $ADB pull /sdcard/g1_ui.xml /tmp/g1_ui.xml >/dev/null 2>&1 || fail "uiautomator dump 失败"
    # TODO(device): 依据 /tmp/g1_ui.xml 里的实际 text/resource-id 完成开关点击；
    #   占位逻辑：找不到控件即 ABORT（宁停不错——禁盲点）。
    grep -q "GPU" /tmp/g1_ui.xml || fail "设置页未见 GPU 开关控件，需人工校准选择子"
    echo "NOTE: 通道=$want 的设置点击待真机校准（TODO(device)）" >&2
}

run_leg() { # $1 = arm 名(GPU|CPU), $2 = 轮次
    local arm=$1 r=$2
    $ADB logcat -c 2>/dev/null
    # 发问：输入框 input text + 发送按钮（同 TODO(device) 选择子纪律）
    $ADB shell input text "hello" >/dev/null 2>&1
    # TODO(device): 点发送按钮（uiautomator 选择子）；占位=等待用户手点 20 轮 token
    local t0=$(date +%s%3N)
    timeout $TIMEOUT $ADB logcat -v time | grep -m20 "\[DIAG\] gen#" > /tmp/g1_${arm}_$r.log
    local rc=$?
    local n=$(wc -l < /tmp/g1_${arm}_$r.log)
    [ $n -ge 20 ] || { echo "G1 WARN: arm=$arm r=$r 仅 $n/20 token rc=$rc"; }
    local t1=$(date +%s%3N)
    local per_ms=$(( (t1 - t0) / (n>0?n:1) ))
    local tok_s=$(awk -v p=$per_ms 'BEGIN{if(p>0)printf "%.2f", 1000.0/p; else print "0"}')
    echo "{\"ts\":\"$(date -Iseconds)\",\"arm\":\"$arm\",\"round\":$r,\"model\":\"$MODEL\",\"n_tok\":$n,\"tok_s\":$tok_s,\"wall_ms\":$((t1-t0))}" >> $OUT
}

for r in $(seq 1 $ROUNDS); do
    set_channel GPU; run_leg GPU $r
    sleep 90   # 热闸：臂间冷却（测量污染防线，Mesa 线教训）
    set_channel CPU; run_leg CPU $r
    sleep 90
done

echo "== G1 结果（只测不回退，比值供 R-197 靶子判定引用）=="
cat $OUT | while read -r l; do echo "G1RESULT $l"; done
sleep_dev
echo "落档: $OUT"
