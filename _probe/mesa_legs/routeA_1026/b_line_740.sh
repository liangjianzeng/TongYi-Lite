#!/system/bin/sh
# B 线·全载推进 740 腿 v3（R-084；用户钦定优先级）
# B1 = ling tiny Q4_0 全载 ngl=99 ×3（同文性+tok/s+TRACE 核族普查）——patch79 Mesa 闸首验收
# B2 = LFM2.5-24B-a2b in-place split-MoE（配方定案 bank=32/nb=16，R-083；阶梯复核驻留面）
# 铁律：电池闸>440；bin= 自证 patch79=eee6638d；$LOADER 显式形态；HOME/XDG 必带；单案单文件；无 && 长链。
# 用法（设备端）：sh b_line_740.sh b1 | b2 | all
R=/data/local/tmp/mesa_clrt_1026
LOADER=$R/lib/ld-linux-aarch64.so.1
LP="$R/bin/patch79:$R/bin:$R/lib/aarch64-linux-gnu:$R/opt/mesa-cl/lib/aarch64-linux-gnu/clrt:$R/opt/mesa-cl/lib/aarch64-linux-gnu"
ICD=$R/opt/mesa-cl/etc/OpenCL/vendors
MD=/storage/emulated/0/TongYiLite/models
LING=/data/local/tmp/g759/Ling-3.0-tiny-Q4_0.gguf
[ -f "$LING" ] || LING=$MD/Ling-3.0-tiny-Q4_0.gguf
LFM=$(ls $MD/lfm2.5-24b-a2b-q4_0*.gguf 2>/dev/null | head -1)
OUT=$R/out
BIN=$(md5sum $R/bin/patch79/libggml-opencl.so.0.27.0 2>/dev/null | cut -c1-8)
if [ "$BIN" != "eee6638d" ]; then echo "#### B_ABORT_REDCARD bin=$BIN"; exit 1; fi
EYE=$R/bin/ling_e2e_v4ld
[ -x "$EYE" ] || { echo "#### B_ABORT_NOEYE"; exit 1; }

hot() {
  T=$(dumpsys battery 2>/dev/null | grep -m1 temperature | tr -dc '0-9')
  [ "${T:-0}" -gt 440 ]
}

run_eye() {  # $1=tag $2=model $3=npred $4=ngl $5=extra_env
  if hot; then echo "#### B_THERMAL $1 at=$(date +%H:%M:%S)"; return 1; fi
  rm -f $OUT/$1.tok
  timeout 900 env GGML_OPENCL_FAKE_QCOM_REQD=1 HOME=$R/tmp XDG_CACHE_HOME=$R/tmp \
    OCL_ICD_VENDORS=$ICD RUSTICL_ENABLE=kgsl $5 \
    $LOADER --library-path $LP $EYE "$2" "$3" "$4" 42 \
    > $OUT/$1.tok 2> $OUT/$1.err
  RC=$?
  echo "#### BRESULT tag=$1 rc=$RC ngl=$4 model=$(basename $2) md5=$(md5sum $OUT/$1.tok | cut -c1-8) bytes=$(wc -c < $OUT/$1.tok | tr -dc '0-9') bin=$BIN $(grep -a tok_s= $OUT/$1.err | tail -1) at=$(date +%H:%M:%S)"
}

case "$1" in
  b1)
    # patch79 首验收：Mesa 闸让 MUL_MAT_ID 走通用路，q4_1 SoA -48 崩溃应绝迹
    i=1; while [ $i -le 3 ]; do run_eye b19_ling_r$i "$LING" 32 99 "GGML_OPENCL_TRACE_Q4K=1"; i=$((i+1)); done
    echo "#### B_DONE b1"
    ;;
  b2)
    [ -z "$LFM" ] && { echo "#### B_SKIP_B2_NO_MODEL"; exit 0; }
    # fork 原生 in-place split-MoE（用户钦定"不同方法"）：env 指主 gguf，专家原地按需 preadv，
    # 预取配方对齐 JNI L560（8/8/6/IO4）。配方定案：BANK=32 + E2E_NB=16（R-083 唯一 rc=0 窗口）。
    MOEENV="LLAMA_MOE_EXPERTS_PATH=$LFM LLAMA_MOE_SLOT_BANK=32 LLAMA_MOE_LOOKAHEAD_PREFETCH=8 LLAMA_MOE_DECODE_WINDOW=8 LLAMA_MOE_PREFETCH_READ=6 E2E_NB=16"
    run_eye b29_lfm_n99 "$LFM" 32 99 "$MOEENV"
    run_eye b29_lfm_n24 "$LFM" 32 24 "$MOEENV"
    run_eye b29_lfm_n16 "$LFM" 32 16 "$MOEENV"
    run_eye b29_lfm_n8  "$LFM" 32 8  "$MOEENV"
    echo "#### B_DONE b2"
    ;;
  all)
    sh $0 b1; sh $0 b2
    ;;
  *) echo "usage: sh b_line_740.sh b1|b2|all"; exit 1 ;;
esac
