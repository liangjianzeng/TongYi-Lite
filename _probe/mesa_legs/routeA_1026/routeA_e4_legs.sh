#!/system/bin/sh
# [E4 插桩轮 1026] routeA 路 A 三条腿（L-A diag async / L-B diag OPFLUSH=1 / L-C 背书 MESA_DEBUG=sync）
# 逐字复用 routeA_legs_1026.sh q0a0 段形态：LP 四目录/OCL_ICD_VENDORS/RUSTICL_ENABLE=kgsl/
# 字面 env 同行导出/E2E 协议逐字/timeout 保护。影子库=$R/bin/libRusticlOpenCL.so.1（LP bin 首位）。
R=/data/local/tmp/mesa_clrt_1026
LP=/data/local/tmp/mesa_clrt_1026/bin:/data/local/tmp/mesa_clrt_1026/lib/aarch64-linux-gnu:/data/local/tmp/mesa_clrt_1026/opt/mesa-cl/lib/aarch64-linux-gnu/clrt:/data/local/tmp/mesa_clrt_1026/opt/mesa-cl/lib/aarch64-linux-gnu
LOADER=/data/local/tmp/mesa_clrt_1026/lib/ld-linux-aarch64.so.1
ICD=/data/local/tmp/mesa_clrt_1026/opt/mesa-cl/etc/OpenCL/vendors
MODEL=/storage/emulated/0/TongYiLite/models/minicpm-v4.7-35b-a3b-les.gguf
EXPERTS=/storage/emulated/0/TongYiLite/models/minicpm-v4.7-35b-a3b-les.experts
PROMPT='请详细介绍一下中国的四大发明，分别说明每一项的历史背景、技术要点和对世界文明的影响，分四段展开，每段不少于八十字，不要简短总结'

run_leg () {
  typeset TAG FL NPRED EXTRAENV PRELOAD PLENV TEMP
  TAG=$1; FL=$2; NPRED=$3; EXTRAENV=$4; PRELOAD=$5
  # [教训 1026] LD_PRELOAD 绝不 export：会毒死 timeout/grep 等 bionic 二进制
  # （"CANNOT LINK EXECUTABLE timeout: cannot find verneed..."），只在 exec 行 env 注入
  mkdir -p $R/tmp $R/out
  TEMP=$(dumpsys battery 2>/dev/null | grep -m1 temperature | tr -dc '0-9')
  echo "#### $TAG $(date -Iseconds) loadavg=$(cat /proc/loadavg) temp=$(dumpsys battery 2>/dev/null | grep -m1 temperature | tr -d ' ')"
  # [热纪律 1026] 温度>44°C（tenths 单位）拒跑热腿，防 21:0x adbd 猝死事件重演
  if [ "${TEMP:-0}" -gt 440 ]; then echo "#### ABORT_THERMAL temp_tenths=$TEMP (>440)"; return 1; fi
  echo "#### shadow=$(ls -la $R/bin/libRusticlOpenCL.so.1 2>/dev/null | awk '{print $5}')"
  # Android mksh: 裸 VAR=值 被当命令 → 一律 export（§6-4 铁律的可靠形态）
  export LD_LIBRARY_PATH=$LP
  export OCL_ICD_VENDORS=$ICD
  export RUSTICL_ENABLE=kgsl
  export HOME=/data/local/tmp/mesa_clrt_1026/tmp
  export XDG_CACHE_HOME=/data/local/tmp/mesa_clrt_1026/tmp
  export GGML_OPENCL_MESA_SPIRV=1
  export GGML_OPENCL_ADRENO_XMEM_GEMM=0
  export GGML_OPENCL_FAKE_QCOM_REQD=1
  if [ "$FL" != "" ]; then export GGML_OPENCL_OPFLUSH=1; else unset GGML_OPENCL_OPFLUSH; fi
  if [ "$EXTRAENV" != "" ]; then export $EXTRAENV; fi
  export E2E_NBATCH=512
  export E2E_SEED=42
  export E2E_TEMP=0
  export E2E_NOMMAP=1
  export E2E_TOKDUMP=$R/out/$TAG.tok
  export GGML_E2E_PROMPT="$PROMPT"
  if [ "$PRELOAD" != "" ]; then
    PLENV="LD_PRELOAD=$PRELOAD"
  else
    PLENV=""
  fi
  # shellcheck disable=SC2086
  timeout 600 env $PLENV $LOADER --library-path $LP $R/bin/minicpm_e2e \
    $MODEL $EXPERTS 99 $NPRED 512 \
    > $R/out/$TAG.out 2> $R/out/$TAG.err
  echo "#### rc=$? tokbytes=$(ls -l $R/out/$TAG.tok 2>/dev/null | awk '{print $5}')"
  echo "#### tok md5=$(md5sum $R/out/$TAG.tok 2>/dev/null)"
  echo "#### KGSLSUBMIT=$(grep -ac 'KGSLSUBMIT cmd\[' $R/out/$TAG.err)"
  echo "#### driver=$(grep -a 'OpenCL driver:' $R/out/$TAG.err | head -1)"
  echo "#### health=$(grep -acE '造纸|印刷|指南针|火药' $R/out/$TAG.out)"
  echo "#### E4MERGE=$(grep -ac '^E4MERGE' $R/out/$TAG.err) E4DEL=$(grep -ac '^E4DEL' $R/out/$TAG.err) E4BO=$(grep -ac '^E4BO' $R/out/$TAG.err) E4FENCE=$(grep -ac '^E4FENCE' $R/out/$TAG.err) E4HIST=$(grep -ac '^E4HIST' $R/out/$TAG.err)"
  echo "#### E4VERIFY=$(grep -ac '^E4VERIFY' $R/out/$TAG.err) VERIFY_MISMATCH=$(grep -ac 'MISMATCH' $R/out/$TAG.err) E4REUSE=$(grep -ac '^E4REUSE' $R/out/$TAG.err) REUSE_NOTRET=$(grep -acE 'E4REUSE .*reached=0' $R/out/$TAG.err) E4FAST=$(grep -ac '^E4FAST' $R/out/$TAG.err) FASTHIT=$(grep -ac 'hit=1' $R/out/$TAG.err)"
  echo "#### E4BOREL=$(grep -ac '^E4BOREL' $R/out/$TAG.err) E4BOREUSE=$(grep -ac '^E4BOREUSE' $R/out/$TAG.err) BOREUSE_NOTRET=$(grep -acE 'E4BOREUSE .*reached=0' $R/out/$TAG.err) FASTRK0=$(grep -acE '^E4FAST.* hit=1 rk=0' $R/out/$TAG.err) FASTRK1=$(grep -acE '^E4FAST.* hit=1 rk=1' $R/out/$TAG.err)"
  echo "#### E4FLUSH=$(grep -ac '^E4FLUSH' $R/out/$TAG.err) E4WAIT=$(grep -ac '^E4WAIT' $R/out/$TAG.err) WAIT_NEV_MAX=$(grep -aoE 'E4WAIT wseq=[0-9]+ nev=[0-9]+' $R/out/$TAG.err | awk '{gsub(/nev=/,"",$3); if($3>m)m=$3} END{print m+0}') UNKNOWN_DBG=$(grep -ac 'Unknown RUSTICL_DEBUG flag' $R/out/$TAG.err)"
  echo "#### E4HIST_last=$(grep -a '^E4HIST' $R/out/$TAG.err | tail -1)"
  echo "#### nosub=$(grep -ac 'does not support subgroups' $R/out/$TAG.err) drop=$(grep -ac 'drop unsupported device' $R/out/$TAG.err)"
  echo "#### E4LAG=$(grep -ac '^E4LAG' $R/out/$TAG.err) LAG_MAX=$(grep -aoE 'lag=-?[0-9]+' $R/out/$TAG.err | awk '{gsub(/lag=/,"",$1); if($1>m)m=$1; s+=$1; n++} END{print m+0" avg="(n?s/n:0)}') E4CACHEBAD=$(grep -ac '^E4CACHEBAD' $R/out/$TAG.err)"
  echo "#### E4CB0=$(grep -ac '^E4CB0' $R/out/$TAG.err) E4PREP=$(grep -ac '^E4PREP' $R/out/$TAG.err) E4DEFER_d1=$(grep -acE '^E4DEFER .*defer=1' $R/out/$TAG.err) E4DEFER_d0=$(grep -acE '^E4DEFER .*defer=0' $R/out/$TAG.err)"
  echo "#### E4GRELPAIR=$(grep -ac '^E4GRELPAIR' $R/out/$TAG.err) E4GPOL_last=$(grep -a '^E4GPOL' $R/out/$TAG.err | tail -1)"
  # [R-041b 铁律] 干预腿自证 witness
  echo "#### E4GSLEEP=$(grep -ac '^E4GSLEEP' $R/out/$TAG.err) E4L2FIX=$(grep -ac '^E4L2FIX' $R/out/$TAG.err) NOMERGE=$(grep -ac '^E4NOMERGE' $R/out/$TAG.err)"
}

# [R-041] 漂移概率统计：同参数 N 连跑，报 tok md5 分布 + health 计数（治愈候选终验门 N>=20）
run_drift () {
  typeset TAG FL NPRED EXTRAENV PRELOAD N LINE
  TAG=$1; FL=$2; NPRED=$3; EXTRAENV=$4; PRELOAD=$5; N=${6:-20}
  i=0; : > $R/out/${TAG}_drift.txt
  while [ $i -lt $N ]; do
    i=$((i+1))
    # [1027 修] 落文件中转：防管道内 export 污染主 shell（timeout 误吃 LD_PRELOAD）+ 热闸可断
    run_leg ${TAG}_r$i "$FL" "$NPRED" "$EXTRAENV" "$PRELOAD" > $R/out/${TAG}_r$i.log 2>&1
    grep -E "^#### (rc=|tok md5|health=|ABORT_THERMAL|GSLEEP|L2FIX)" $R/out/${TAG}_r$i.log | tr '\n' ' ' >> $R/out/${TAG}_drift.txt; echo "r$i" >> $R/out/${TAG}_drift.txt
    if grep -q "ABORT_THERMAL" $R/out/${TAG}_r$i.log; then echo "#### DRIFT_HALTS_THERMAL at r$i" >> $R/out/${TAG}_drift.txt; break; fi
    if ! timeout 10 ping -c1 -W3 127.0.0.1 >/dev/null 2>&1; then :; fi
  done
  echo "#### DRIFT_SUMMARY $TAG N=$N"
  awk '{for(j=1;j<=NF;j++) if($j ~ /^md5=[0-9a-f]+$/) print $j}' $R/out/${TAG}_drift.txt | sort | uniq -c | sort -rn
  echo "#### DRIFT_HEALTH=$(grep -ac 'health=1' $R/out/${TAG}_drift.txt)/$N"
}

case "$1" in
  e4a) # diag 库 async NPRED=16：复现乱码 + 采 E4 统计（预期 health=0，tok≠金标准）
    run_leg e4a_async "" 16 "TYL_E4=1"
    ;;
  e4b) # diag 库 OPFLUSH=1 NPRED=48：对照腿（预期 tok=e9b88e56 逐字节全等）
    run_leg e4b_fl1 "GGML_OPENCL_OPFLUSH=1" 48 "TYL_E4=1"
    ;;
  e4c) # 背书库（影子须已撤）async + MESA_DEBUG=sync NPRED=8：E1 复判（旧，env 名错已定案）
    run_leg e4c_sync "" 8 "MESA_DEBUG=sync"
    ;;
  e4d) # 0032 diag2 async NPRED=16：R10 判决主腿（E4REUSE reached=0 事件 = 在飞 IB 覆写窗口打开）
    run_leg e4d_async2 "" 16 "TYL_E4=1"
    ;;
  e4e) # 0032 diag2 OPFLUSH=1 NPRED=48：对照腿（预期 tok=e9b88e56 逐字节全等）
    run_leg e4e_fl12 "GGML_OPENCL_OPFLUSH=1" 48 "TYL_E4=1"
    ;;
  e4f) # 阳性对照：RUSTICL_DEBUG=__tyl_probe__（err 须现 Unknown RUSTICL_DEBUG flag）
    run_leg e4f_probe "" 8 "RUSTICL_DEBUG=__tyl_probe__ TYL_E4=1"
    ;;
  e4g) # 真 E1：async NPRED=8 + RUSTICL_DEBUG=sync（判据=E4WAIT nev 分布趋 1）
    run_leg e4g_sync2 "" 8 "RUSTICL_DEBUG=sync TYL_E4=1"
    ;;
  e4h) # 0034 diag4 鉴别腿：async NPRED=16 + TYL_E4_NOFAST=1（wait 全走 KMD；health=1 ⇒ 快路早完成定罪）
    run_leg e4h_nofast "" 16 "TYL_E4=1 TYL_E4_NOFAST=1"
    ;;
  flscan) # [背书库 1026] OPFLUSH 阈值扫（回档自设备侧 sed 演化版，恢复全列表）：N≤2 对 / N≥3 乱
    for N in 1 2 4 8 16 32; do run_leg flscan$N "" 48 "GGML_OPENCL_OPFLUSH=$N TYL_E4=1"; done
    ;;
  fl2a) # fl2 专项：OPFLUSH=2 NPRED=48（三连金标准 leg-058/059 复测形态；diag7 下即 fl2b）
    run_leg fl2a_48 "" 48 "GGML_OPENCL_OPFLUSH=2 TYL_E4=1"
    ;;
  g7) # diag7 三腿之一：async 16 + grp 垫片（E4LAG/E4CACHEBAD + 垫片 E4GRELPAIR 联合判决）
    run_leg e4d_g7 "" 16 "TYL_E4=1 TYL_E4_GRP=1" "$R/bin/libtylgrp.so"
    ;;
  fix8) # diag8 修复验证：async 16 + TYL_UPSZ=4MB（cb0 环绕假说的因果判据：health=1 ⇒ 定罪+修复闭环）
    run_leg e4d_fix8 "" 16 "TYL_E4=1 TYL_UPSZ=4194304"
    ;;
  fix8g) # diag8 双探针腿：修复验证 + grp 垫片同开（环绕应消失）
    run_leg e4d_fix8g "" 16 "TYL_E4=1 TYL_UPSZ=4194304 TYL_E4_GRP=1" "$R/bin/libtylgrp.so"
    ;;
  g11) # fl1 治愈对照（全代探针在场，验证不扰动金标准）
    run_leg e4f_g11 "" 1 "TYL_E4=1"
    ;;
  g17) # 日程对照：fl1 金标准 + 全内核打点
    run_leg e4f_g17 "" 1 "TYL_E4=1"
    ;;
  g16) # 0046 生死括号版内核普查：async 16 + E4
    run_leg e4d_g16 "" 16 "TYL_E4=1"
    ;;
  g24) # 治愈剂量扫描：async 16 + 写前 usleep 500us
    run_leg e4d_g24 "" 16 "TYL_E4=1 TYL_E4_GRP=4 TYL_GRP_SLEEPUS=500" "$R/bin/libtylgrp.so"
    ;;
  l3b) # ★L3 三证探针（717a85b0）：(a)后备归属线索 (b1)CPU写→GPU读 (b2)GPU写→CPU读×64 金丝雀 (c)带宽
    export LD_LIBRARY_PATH=$LP; export OCL_ICD_VENDORS=$ICD; export RUSTICL_ENABLE=kgsl
    export HOME=/data/local/tmp/mesa_clrt_1026/tmp; export XDG_CACHE_HOME=/data/local/tmp/mesa_clrt_1026/tmp
    TEMP=$(dumpsys battery 2>/dev/null | grep -m1 temperature | tr -dc '0-9')
    if [ "${TEMP:-0}" -gt 440 ]; then echo "#### ABORT_THERMAL temp_tenths=$TEMP"; return 1 2>/dev/null || exit 1; fi
    timeout 300 $LOADER --library-path $LP $R/bin/l3_coherency_probe 32 64 > $R/out/e4d_l3b.out 2>&1
    echo "#### probe_rc=$?"
    grep -a "PROBE" $R/out/e4d_l3b.out
    ;;
  l3a) # L3 观察腿：HBUFT lib(134bfd9c)+STATS，看哪些 i32 小张量自动拿到 extra（[L3] hbuft bind 自证）
    cp $R/stage_1027/libggml-opencl.so.0.27.0 $R/bin/libggml-opencl.so.0.27.0 2>/dev/null
    run_leg e4d_l3a "" 16 "GGML_OPENCL_ISLAND_STATS=1 GGML_OPENCL_ISLAND_HBUFT=1"
    echo "#### L3_BIND=$(grep -ac '^\\[L3\\] hbuft bind' $R/out/e4d_l3a.err)"
    grep -a '^\\[L3\\] hbuft bind' $R/out/e4d_l3a.err | head -12
    ;;
  l0b) # 前线② L0 真身：census 三件(04aaa77f/75a36aa7/914cc424) + ISLAND_STATS=1（P2 进程内计数，图末/exit 打 [L0O]/[L0B]）
    mkdir -p $R/bin_bak_1027
    cp -n $R/bin/minicpm_e2e $R/bin_bak_1027/ 2>/dev/null
    cp -n $R/bin/libggml-opencl.so.0.27.0 $R/bin_bak_1027/ 2>/dev/null
    cp -n $R/bin/libggml-base.so.0.27.0 $R/bin_bak_1027/ 2>/dev/null
    cp $R/stage_1027/minicpm_e2e $R/bin/minicpm_e2e
    cp $R/stage_1027/libggml-opencl.so.0.27.0 $R/bin/libggml-opencl.so.0.27.0
    cp $R/stage_1027/libggml-base.so.0.27.0 $R/bin/libggml-base.so.0.27.0
    echo "#### deployed: $(md5sum $R/bin/minicpm_e2e $R/bin/libggml-opencl.so.0.27.0 $R/bin/libggml-base.so.0.27.0)"
    run_leg e4d_l0b "" 16 "GGML_OPENCL_ISLAND_STATS=1"
    echo "#### L0O=$(grep -a '^\\[L0O\\]' $R/out/e4d_l0b.err | head -1)"
    grep -a '^\\[L0B\\]' $R/out/e4d_l0b.err
    grep -a '^\\[L0O\\] wr_name' $R/out/e4d_l0b.err | sort -t= -k3 -rn | head -15
    ;;
  l0a) # 前线② L0 计数腿：背书+现成 GGML_CL_OFFS_DEBUG=1，岛边界/跨设备传输底数（对照 g14 垫片 census）
    run_leg e4d_l0a "" 16 "GGML_CL_OFFS_DEBUG=1"
    echo "#### L0_SET=$(grep -ac '^\\[set\\]' $R/out/e4d_l0a.err) L0_WATCH=$(grep -ac '^\\[watch\\]' $R/out/e4d_l0a.err)"
    grep -a '^\\[set\\]' $R/out/e4d_l0a.err | awk '{print $2}' | sort | uniq -c | sort -rn | head -25
    ;;
  g31) # ★路线①真身：七件套同树(e2e=04aaa77f opencl=134bfd9c base=914cc424,shoot 已部)+背书库 KERNEL_SYNC=1
    mkdir -p $R/bin_bak_1027
    cp -n $R/bin/minicpm_e2e $R/bin_bak_1027/ 2>/dev/null
    cp -n $R/bin/libggml-opencl.so.0.27.0 $R/bin_bak_1027/ 2>/dev/null
    cp -n $R/bin/libggml-base.so.0.27.0 $R/bin_bak_1027/ 2>/dev/null
    cp $R/stage_1027/minicpm_e2e $R/bin/minicpm_e2e
    cp $R/stage_1027/libggml-opencl.so.0.27.0 $R/bin/libggml-opencl.so.0.27.0
    cp $R/stage_1027/libggml-base.so.0.27.0 $R/bin/libggml-base.so.0.27.0
    echo "#### deployed: $(md5sum $R/bin/minicpm_e2e $R/bin/libggml-opencl.so.0.27.0 $R/bin/libggml-base.so.0.27.0)"
    run_leg e4d_g31 "" 16 "GGML_OPENCL_KERNEL_SYNC=1"
    ;;
  l3b2) # R-053 fallback 三证 v2（probe 118bee3f）：map/unmap 包裹双向 + WriteBuffer/ReadBuffer 阳性对照
    TEMP=$(dumpsys battery 2>/dev/null | grep -m1 temperature | tr -dc '0-9')
    if [ "${TEMP:-0}" -gt 440 ]; then echo "#### ABORT_THERMAL $TEMP"; return 1 2>/dev/null || exit 1; fi
    export LD_LIBRARY_PATH=$LP
    export OCL_ICD_VENDORS=$ICD
    export RUSTICL_ENABLE=kgsl
    export HOME=$R/tmp
    export XDG_CACHE_HOME=$R/tmp
    timeout 300 $R/bin/l3_coherency_probe_v2 32 32
    echo "#### probe2_rc=$?"
    ;;
  g33) # L3-wire 首验：七件套+WIRE=1+STATS（async）。witness=[wire] attached；对照 g32（同件 WIRE 关乱）
    run_leg e4d_g33 "" 16 "GGML_OPENCL_ISLAND_WIRE=1 GGML_OPENCL_ISLAND_STATS=1"
    echo "#### WIRE_selfproof=$(grep -ac '\[wire\]' $R/out/e4d_g33.err) L0O=$(grep -a '^\\[L0O\\] ' $R/out/e4d_g33.err | head -1)"
    grep -a '^\\[L0O\\] wr_name' $R/out/e4d_g33.err | sort -t= -k3 -rn | head -8
    ;;
  g34) # L3-wire 税测：fl1(正确态)+WIRE=1 vs 历史 fl1 基线（tok/s 对拍用）
    run_leg e4d_g34 "1" 48 "GGML_OPENCL_ISLAND_WIRE=1"
    echo "#### WIRE_selfproof=$(grep -ac '\[wire\]' $R/out/e4d_g34.err) speed=$(grep -aoE '[0-9.]+ tokens/second|[0-9.]+ t/s' $R/out/e4d_g34.out | tail -1)"
    ;;
  d31) # g31 终验：KERNEL_SYNC drift N=20（热闸断跑；md5 单一+health 20/20=过门）
    run_drift e4d_d31 "" 16 "GGML_OPENCL_KERNEL_SYNC=1" "" 20
    ;;
  g35) # ★R-052 主形态：WBW 原生补丁(opencl 0f56e3bf)+背书 async——预期治愈+税≈g28
    cp $R/stage_1027/libggml-opencl.so.0.27.0 $R/bin/libggml-opencl.so.0.27.0
    echo "#### wbw_lib=$(md5sum $R/bin/libggml-opencl.so.0.27.0)"
    run_leg e4d_g35 "" 16 "GGML_OPENCL_WAIT_BIGWRITE=1"
    echo "#### WBW_selfproof=$(grep -ac '^\[WBW\]' $R/out/e4d_g35.err) $(grep -a '^\[WBW\]' $R/out/e4d_g35.err)"
    ;;
  g36) # WBW 阈值加密 256K（若 g35 漏网则此腿兜底）
    run_leg e4d_g36 "" 16 "GGML_OPENCL_WAIT_BIGWRITE=1 GGML_OPENCL_WAIT_BIGWRITE_TH=262144"
    echo "#### WBW_selfproof=$(grep -ac '^\[WBW\]' $R/out/e4d_g36.err) $(grep -a '^\[WBW\]' $R/out/e4d_g36.err)"
    ;;
  g32) # 对照：同新二件 KERNEL_SYNC 关（预期乱=新二进制自身非混淆变量）
    run_leg e4d_g32 "" 16 ""
    ;;
  grestore1027) # 回滚 bin 到备份（七件全量）
    for f in minicpm_e2e libggml-opencl.so.0.27.0 libggml-base.so.0.27.0 libggml.so.0.27.0 libggml-cpu.so.0.27.0 libllama.so.0.7.0 libllama-common.so.0.7.0; do
      [ -f $R/bin_bak_1027/$f ] && cp $R/bin_bak_1027/$f $R/bin/$f && echo "restored $f"
    done
    echo "#### restored_all: $(md5sum $R/bin/minicpm_e2e 2>/dev/null)"
    ;;
  g30) # ★路线②根修实验：diag17 影子 + async 16 + L2FIX（双 fence，无垫片）
    # [自证铁律] 影子腿必须腿内部署+撤除，防"影子缺席=背书跑 L2FIX 变量"NO-OP 陷阱
    if [ ! -f $R/stage_1027/libRusticl_e4r16_1026.so ]; then echo "#### G30_ABORT no diag17 in stage"; return 1 2>/dev/null || exit 1; fi
    cp $R/stage_1027/libRusticl_e4r16_1026.so $R/bin/libRusticlOpenCL.so.1
    echo "#### shadow_deployed=$(md5sum $R/bin/libRusticlOpenCL.so.1)"
    run_leg e4d_g30 "" 16 "TYL_E4=1 TYL_E4_L2FIX=1"
    echo "#### L2FIX_selfproof=$(grep -ac E4L2FIX $R/out/e4d_g30.err)"
    rm $R/bin/libRusticlOpenCL.so.1
    echo "#### shadow_removed=$(ls $R/bin/libRusticlOpenCL.so.1 2>/dev/null | wc -l) (must be 0)"
    ;;
  g29) # ★路线①零代码候选：背书库 + 现成 GGML_OPENCL_SET_TENSOR_FINISH=1（set_tensor 入口 clFinish）
    run_leg e4d_g29 "" 16 "GGML_OPENCL_SET_TENSOR_FINISH=1"
    ;;
  g28) # ★产品化终验真版：背书库 + v8 垫片 GRP=4（门控已解耦；E4GSLEEP 自证）
    run_leg e4d_g28 "" 16 "TYL_E4_GRP=4" "$R/bin/libtylgrp.so"
    echo "#### GSLEEP_selfproof=$(grep -ac E4GSLEEP $R/out/e4d_g28.err)"
    ;;
  g27) # 解耦：背书库 + GRP=4 无 TYL_E4（纯 sleep，零打印）
    run_leg e4d_g27 "" 16 "TYL_E4_GRP=4"
    ;;
  g26) # ★产品化终验：背书库 + 垫片v7 写前 2ms（无 NOMERGE 代码参与）
    run_leg e4d_g26 "" 16 "TYL_E4_GRP=4" "$R/bin/libtylgrp.so"
    ;;
  g25) # 治愈剂量扫描：async 16 + 写前 usleep 100us
    run_leg e4d_g25 "" 16 "TYL_E4=1 TYL_E4_GRP=4 TYL_GRP_SLEEPUS=100" "$R/bin/libtylgrp.so"
    ;;
  g23) # H2′ 时延假说：async 16 + 垫片v6（≥1MB 写前 usleep 2ms，GRP=4）
    run_leg e4d_g23 "" 16 "TYL_E4=1 TYL_E4_GRP=4" "$R/bin/libtylgrp.so"
    ;;
  g22) # Mesa 自证：async 16 + E4 + NOMERGE（每 submit 单独 ioctl，无垫片）
    run_leg e4d_g22 "" 16 "TYL_E4=1 TYL_E4_NOMERGE=1"
    ;;
  g21) # kernel 竞态二分：async 16 + 垫片v5（仅 NDRange 后 finish，GRP=3）
    run_leg e4d_g21 "" 16 "TYL_E4=1 TYL_E4_GRP=3" "$R/bin/libtylgrp.so"
    ;;
  g20) # 同二进制金标准：fl1 原生 16 token（无垫片）
    run_leg e4d_g20 "1" 16 ""
    ;;
  g19) # fl1-by-shim：async 16 + 垫片v4（每 op 后 clFinish，GRP=2）
    run_leg e4d_g19 "" 16 "TYL_E4=1 TYL_E4_GRP=2" "$R/bin/libtylgrp.so"
    ;;
  g18) # S1′ 治愈点定位：async 16 + 垫片v3（>1MB 写后注入 clFinish）
    run_leg e4d_g18 "" 16 "TYL_E4=1 TYL_E4_GRP=1" "$R/bin/libtylgrp.so"
    ;;
  g15) # 内核参数级普查：async 16 + E4（E4KHDR/E4KARG/E4R2BO/id=）
    run_leg e4d_g15 "" 16 "TYL_E4=1"
    ;;
  g14) # host 写审计腿：async 16 + 垫片 v2（map/unmap/read/write 全参）
    run_leg e4d_g14 "" 16 "TYL_E4=1 TYL_E4_GRP=1" "$R/bin/libtylgrp.so"
    ;;
  g12) # fastpath 神罪腿：async 16 + TYL_E4_NOFAST=1（等待全走 KMD）
    run_leg e4d_g12 "" 16 "TYL_E4=1 TYL_E4_NOFAST=1"
    ;;
  g13) # 对照：async 16 无 NOFAST（同 diag 快慢分歧复现）
    run_leg e4d_g13 "" 16 "TYL_E4=1"
    ;;
  g9) # diag9 乒乓全采腿：async 16 + grp 垫片 + Rusticl E4GMEM 三点（NEW/REL/DROP 身份贯通）
    run_leg e4d_g9 "" 16 "TYL_E4=1 TYL_E4_GRP=1" "$R/bin/libtylgrp.so"
    ;;
  *) echo "usage: sh routeA_e4_legs.sh e4a|...|e4h|flscan|fl2a|g7|fix8|fix8g"; exit 2;;
esac
