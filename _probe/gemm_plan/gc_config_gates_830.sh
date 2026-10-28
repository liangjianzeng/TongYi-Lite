#!/system/bin/sh
# [gemm_plan GC ledger-220] 配置腿参数门(830 app 线, logcat 取证, 不点屏不装包)。
#
# 目的:三条配置债的**现状取证**(零改动):
#  1) n_ubatch 参数门:logcat "n_ubatch = %d (%s backend)" 应=512(GPU);
#  2) split-MoE clamp 门:LFM 装载找 "split-MoE: n_ubatch 512 -> N (bank=...,k=...)" LOGW
#     —— 命中即实证"智能体大 prompt 被切成 N-token 碎块"(N=bank/k, B 线 bank=32⇒8);
#  3) TYL-DRAIN 默认态:logcat 找排空档串(smart/idle/legacy),钉死出厂默认。
# 后续(候金口+oom-guard 预算):同模型 bank=32 vs 64 双载比 TTFT —— 本脚本先只做取证臂。
# 铁律:绝不点屏(无 KEYCODE_WAKEUP);装包只 adb install -r -t 且本腿不装;
#      设备若息屏 adbd 掉线 = 正常,等用户处理,严禁拿常亮换在线。
PKG=com.tongyilite.app     # 若不符: adb shell pm list packages | grep -i tongyi 修正后重跑
TAG=llama
OUT=/data/local/tmp/gemm
[ -d $OUT ] || mkdir -p $OUT
logcat -c 2>/dev/null
echo "#### GC_COLLECT start pkg=$PKG (触发方=用户在 app 内加载 ling 与 LFM24b 各一次;或在 host 侧 am start 后静候)"
timeout 180 logcat -v time $TAG:V *:S >$OUT/gc_logcat.txt 2>&1
grep -E "n_ubatch = |split-MoE: n_ubatch|DRAIN|drain|NDRANGE" $OUT/gc_logcat.txt | head -40 \
    | sed 's/^/#### GC_HIT /'
grep -c "split-MoE: n_ubatch 512 -> " $OUT/gc_logcat.txt | sed 's/^/#### GC_METRIC clamp_hits=/'
# 判定:clamp_hits>0 ⇒ 智能体 prefill 碎块化实证(下一步= bank≥n_exp 配置腿申请);
#       n_ubatch 行缺 "(GPU backend)" ⇒ 参数门失守,查 JNI 1074 区漂移。
echo "#### GC_DONE out=$OUT/gc_logcat.txt"
