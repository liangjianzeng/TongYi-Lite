#!/system/bin/sh
# lingfix C2/C3 补射腿（R-085 移交清单第 1 条；断网夭折重跑）
# C2 = q4_0 KV + 512 分块 + 无 checkpoint；C3 = f16 KV 同构。判 q4_0 KV 本身 OpenCL 可用性 → 定修法 B vs C′
D=/data/local/tmp/tyl_lingfix_1027
cd $D || { echo "#### C_ABORT_NODIR"; exit 1; }
P=$(cat long_prompt.txt)
hot() {
  T=$(dumpsys battery 2>/dev/null | grep -m1 temperature | tr -dc '0-9')
  [ "${T:-0}" -gt 440 ]
}
run_leg() {  # $1=C2|C3 $2=ktype
  if hot; then echo "#### C_THERMAL $1"; return 1; fi
  rm -f out_c$1.tok
  env LD_LIBRARY_PATH=$D TYL_LINGFIX_1027=1 TONGYILITE_STUB_VERBOSE=1 \
    E2E_KV_UNIFIED=1 E2E_KTYPE=$2 E2E_VTYPE=$2 E2E_CHUNK=1 \
    timeout 420 ./ling_e2e /storage/emulated/0/TongYiLite/models/Ling-3.0-tiny-Q4_0.gguf \
      16 99 42 "$P" 16384 > out_c$1.tok 2> out_c$1.err
  RC=$?
  echo "#### CRESULT leg=$1 ktype=$2 rc=$RC md5=$(md5sum out_c$1.tok | cut -c1-8) bytes=$(wc -c < out_c$1.tok | tr -dc '0-9') ckpt=$(grep -ac 'checkpoint' out_c$1.err) err38=$(grep -ac 'error -38' out_c$1.err) $(grep -a METRIC out_c$1.err | tail -1)"
}
echo "#### C23_BEGIN $(date +%H:%M:%S)"
run_leg 2 q4_0
run_leg 3 f16
echo "#### C23_DONE $(date +%H:%M:%S)"
