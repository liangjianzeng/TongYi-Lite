#!/system/bin/sh
# X4 黄金语料采集器（设备端，R-072 立项；A2 正式默认开的钥匙）
# 唯一语料真源=本脚本 TABLE；host 侧清单由 `sh x4_capture.sh dump` 生成。
# 用法（设备端）：sh x4_capture.sh <case|all>
#   结果行: #### X4RESULT id=<id> rc=<rc> md5=<8> bin=<8> bytes=<n> [tok_s=..]
# 铁律随行：热闸>440、bin= 自证、ICD driver 串留 .err 可机检、单案单文件、无 && 长链。
R=/data/local/tmp/mesa_clrt_1026
LOADER=$R/lib/ld-linux-aarch64.so.1
LP="${X4_LDPRE:+$X4_LDPRE:}$R/bin:$R/lib/aarch64-linux-gnu:$R/opt/mesa-cl/lib/aarch64-linux-gnu/clrt:$R/opt/mesa-cl/lib/aarch64-linux-gnu"
MODEL=/storage/emulated/0/TongYiLite/models/qwen2.5-0.5b-q4_k_m.gguf
EYE=${X4_EYE:-$R/bin/ling_e2e}
# id|npred|ngl|seed|n_ctx|prompt   （greedy；seed 仅记账用）
TABLE='p1_cn_classic|32|99|42|1024|请详细介绍一下中国的四大发明，分别说明历史背景与技术要点，分四段展开。
p2_en_whyblue|48|99|42|1024|Explain in detail why the sky is blue, in three short paragraphs.
p3_math_17x23|32|99|42|1024|计算 17 乘以 23 等于多少？请给出推理过程。
p4_code_fib|48|99|42|1024|写一个 Python 函数 fib(n)，返回第 n 个斐波那契数，并给出示例调用。
p5_poetry|32|99|42|1024|用「春天」「火车」「信」三个词写一首四行诗。
p6_greatwall|64|99|42|1024|介绍一下长城的历史和建筑特点，分三段。'
if [ "$1" = "dump" ]; then echo "$TABLE"; exit 0; fi
ICD=$R/opt/mesa-cl/etc/OpenCL/vendors
export LD_LIBRARY_PATH=$LP OCL_ICD_VENDORS=$ICD RUSTICL_ENABLE=kgsl HOME=$R/tmp XDG_CACHE_HOME=$R/tmp
BIN=$(md5sum $R/bin/libggml-opencl.so.0.27.0 | cut -c1-8)
run_one() {
  ID=$(echo "$1" | cut -d'|' -f1); NP=$(echo "$1" | cut -d'|' -f2)
  NG=$(echo "$1" | cut -d'|' -f3); SD=$(echo "$1" | cut -d'|' -f4)
  NC=$(echo "$1" | cut -d'|' -f5); PR=$(echo "$1" | cut -d'|' -f6-)
  TEMP=$(dumpsys battery 2>/dev/null | grep -m1 temperature | tr -dc '0-9')
  if [ "${TEMP:-0}" -gt 440 ]; then echo "#### X4ABORT_THERMAL $TEMP id=$ID"; return 1; fi
  LGENV=""
  if [ "${X4_LG:-0}" = "1" ]; then LGENV="E2E_LOGITDUMP=$R/out/x4_$ID.lgf"; fi
  timeout 600 env GGML_OPENCL_SKIP_MOE_KERNELS=1 GGML_OPENCL_FAKE_QCOM_REQD=1 $LGENV \
      $LOADER --library-path $LP $EYE $MODEL $NP $NG $SD "$PR" $NC \
      > $R/out/x4_$ID.tok 2> $R/out/x4_$ID.err
  RC=$?
  MD=$(md5sum $R/out/x4_$ID.tok | cut -c1-8)
  BY=$(wc -c < $R/out/x4_$ID.tok | tr -dc '0-9')
  TS=$(grep -a tok_s= $R/out/x4_$ID.err | tail -1)
  echo "#### X4RESULT id=$ID rc=$RC md5=$MD bin=$BIN bytes=$BY $TS"
}
if [ "$1" = "all" ]; then
  echo "$TABLE" | while IFS= read -r row; do [ -n "$row" ] && run_one "$row"; done
  echo "#### X4_ALL_DONE $(date +%H:%M:%S)"
elif echo "$TABLE" | grep -q "^$1|"; then
  echo "$TABLE" | while IFS= read -r row; do
    case "$row" in "$1|"*) run_one "$row";; esac
  done
else
  echo "#### X4_NO_SUCH_CASE $1"
fi
