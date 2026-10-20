#!/system/bin/sh
# [Mesa 线 P2] 算子族定位：async 独有的 FAIL 才是真凶（L3 裁决报告 §8.1 的下一刀，判据先写死）
#
# 背景（今天实测收窄出来的）：gen7 上 `OPFLUSH=0` 从 token 1 全崩、`OPFLUSH=1` 与 CPU 49 token 全等；
# 但内核粒度判具 `moe_probe4` 显示 **MoE 内核在 async 下也位精确（GPU NMSE=0.000000）** ⇒ 单个 MoE 内核出局。
# ⇒ 只剩两种可能：①别的算子族在深队列下出错；②高 op 数下的系统性效应（探针几个 op 测不到）。
# 本脚本专治 ①：对一串算子族各跑一次 tbo，**async 与 flush1 各一遍**，只认"async 独有 FAIL"。
#
# 判据（不许事后改）：
#   - 某算子族：async 有 FAIL 而 flush1 没有 ⇒ **真凶锁定该族**（下一步只在它上面做内核级二分）；
#   - 所有族两边 FAIL 集合完全相同 ⇒ **单算子层无罪** ⇒ 转 ②，在 e2e 里按 op 段二分；
#   - 某族两边都 panic/崩 ⇒ 只记"该族不可判"，**不得**当成无罪证据（崩了测不出东西）。
# 硬闸：必须看到逐用例行；只有 `Skipping` 的腿一律作废（本仓库已被这类假绿骗过两次）。
#
# 用法：RUN=<dir> B=<mesa_dir> TB=<tbo 路径> sh run_p2_opsweep.sh "MUL_MAT SOFT_MAX RMS_NORM ROPE ADD MUL"
set -u
RUN=${RUN:?}; B=${B:?}; TB=${TB:?}
FAMS=${1:-"MUL_MAT SOFT_MAX RMS_NORM ROPE ADD MUL"}
STAMP=$(date +%H%M); OUT=/data/local/tmp/p2s_$STAMP; mkdir -p $OUT
cd "$RUN" || exit 1
export LD_LIBRARY_PATH=$RUN:$RUN/lib:$B/lib:$B:/data/local/tmp
export OCL_ICD_VENDORS=$B/lib/libRusticlOpenCL.so RUSTICL_ENABLE=kgsl
export HOME=$B/tmp XDG_CACHE_HOME=$B/tmp CLC_RESOURCE_DIR=$B/lib/clang/21/include
export GGML_OPENCL_ALLOW_NO_SUBGROUP=1 GGML_OPENCL_FAKE_QCOM_REQD=1
export GGML_OPENCL_MESA_SPIRV=1 GGML_OPENCL_ADRENO_XMEM_GEMM=0
echo "#### opsweep fams=[$FAMS] $(date -Iseconds) loadavg=$(cat /proc/loadavg) tb=$(ls -l $TB | awk '{print $5}')B"
for F in $FAMS; do
  for OF in 0 1; do
    L=$OUT/${F}_ofl$OF.log
    LD_PRELOAD=/data/local/tmp/libnotrace.so GGML_OPENCL_OPFLUSH=$OF \
      timeout 240 "$TB" -b GPUOpenCL -o "$F" > "$L" 2>&1; RC=$?
    OK=$(grep -ac "): OK" "$L" 2>/dev/null); FL=$(grep -ac "): FAIL" "$L" 2>/dev/null)
    NS=$(grep -ac "not supported" "$L" 2>/dev/null); SK=$(grep -ac "Skipping" "$L" 2>/dev/null)
    PN=$(grep -ac "panicked at" "$L" 2>/dev/null)
    V=ok; [ "$SK" -gt 0 ] && V="!!假绿(Skipping)"; [ "$OK" = "0" ] && [ "$NS" = "0" ] && V="$V !!零用例"
    printf -- "-- FAM=%-9s OPFLUSH=%s rc=%s OK=%-4s FAIL=%-3s notsup=%-4s panic=%-2s skip=%s verdict=%s\n" \
      "$F" "$OF" "$RC" "$OK" "$FL" "$NS" "$PN" "$SK" "$V"
    sleep 20
  done
done
echo "=== P2_OPSWEEP_DONE dir=$OUT ==="
echo "读法：把每条族的两行 FAIL 数并排看；只有 async 侧 FAIL>0 且 flush1 侧 =0 的族才算真凶"
