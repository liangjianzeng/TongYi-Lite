#!/system/bin/sh
# [Mesa 线 P0] 部署 bundle 机检 + env 指纹。
#
# 为什么需要：这条线今天两次差点把"其实没在 GPU 上跑"的数当成 Mesa 的数（`drop unsupported device` -> CPU 回落，
# token 与 CPU"全等"是同义反复）。凡是出 t/s 或正确性结论的日志，**开头必须带这段指纹**，
# 否则那份数据不许进任何表格。本脚本既做 bundle 体检，也做指纹生成器。
#
# 用法：B=<bundle 根> [RUN=<跑测目录>] [EXPECT_MD5=<期望 md5>] sh verify_mesa_bundle.sh
#   退出码 0 = bundle 可用；非 0 = 缺东西（**此时跑出来的数一律作废**）。
set -u
B=${B:?必须给 B=<bundle 根>}
RUN=${RUN:-}
EXPECT_MD5=${EXPECT_MD5:-}
FAIL=0
say () { printf '%s\n' "$*"; }
bad () { printf '!! %s\n' "$*"; FAIL=$((FAIL+1)); }

say "#### MESA_BUNDLE_FINGERPRINT $(date -Iseconds)"
say "host=$(getprop ro.product.model 2>/dev/null) board=$(getprop ro.board.platform 2>/dev/null) rel=$(getprop ro.build.version.release 2>/dev/null)"
say "gpu=$(cat /sys/class/kgsl/kgsl-3d0/gpu_model 2>/dev/null) gen=$(cat /sys/class/kgsl/kgsl-3d0/gen 2>/dev/null) freq=$(cat /sys/class/kgsl/kgsl-3d0/gpuclk 2>/dev/null)"
say "loadavg=$(cat /proc/loadavg)  <- 出裁决数要求 1min < 2"
say "bundle=$B run=${RUN:-（未给）}"

# 1) 必需文件
for f in lib/libRusticlOpenCL.so; do
  if [ -f "$B/$f" ]; then say "ok   $f $(ls -l $B/$f | awk '{print $5}')B"; else bad "缺 $B/$f（ICD 本体不在 = 根本没 Mesa）"; fi
done
if [ -d "$B/lib/clang/21/include" ]; then
  say "ok   CLC_RESOURCE_DIR=$B/lib/clang/21/include（缺它 -> 内核全算子 not supported）"
else
  bad "缺 $B/lib/clang/21/include -> 内核编译会全灭，别跑"
fi
[ -d "$B/tmp" ] && say "ok   cache 目录 $B/tmp" || bad "缺 $B/tmp（HOME/XDG_CACHE_HOME 无处可写）"
[ -e /dev/kgsl-3d0 ] && say "ok   /dev/kgsl-3d0 在" || bad "/dev/kgsl-3d0 不存在 -> kgsl 屏建不起来"

# 2) md5 必须与在役那颗一致（两台机器同一颗是这条线所有 A/B 的前提）
if [ -f "$B/lib/libRusticlOpenCL.so" ]; then
  M=$(md5sum "$B/lib/libRusticlOpenCL.so" 2>/dev/null | awk '{print $1}')
  say "md5  libRusticlOpenCL.so=$M"
  if [ -n "$EXPECT_MD5" ] && [ "$M" != "$EXPECT_MD5" ]; then
    bad "md5 不等于 EXPECT_MD5=$EXPECT_MD5 -> 这份 bundle 不是被裁决过的那颗，A/B 无意义"
  fi
fi

# 3) 跑测目录里的东西（构建指纹 + 探针 lib）
if [ -n "$RUN" ]; then
  [ -f "$RUN/BUILD_INFO" ] && { say "-- BUILD_INFO --"; sed 's/^/#  /' "$RUN/BUILD_INFO" | head -6; } || bad "$RUN 没有 BUILD_INFO（不知道是哪次构建出的数不许用）"
  [ -f /data/local/tmp/libnotrace.so ] && say "ok   libnotrace.so 在（吞 printf，否则 tbo 会被自己的打印拖死）" || say "-- libnotrace.so 不在（可选）"
fi

# 4) 有效 env 快照（这些变量任何一个不同，两份数据就不可比）
say "-- env 指纹 --"
for v in LD_LIBRARY_PATH OCL_ICD_VENDORS RUSTICL_ENABLE HOME XDG_CACHE_HOME CLC_RESOURCE_DIR \
         GGML_OPENCL_ALLOW_NO_SUBGROUP GGML_OPENCL_FAKE_QCOM_REQD GGML_OPENCL_MESA_SPIRV \
         GGML_OPENCL_ADRENO_XMEM_GEMM GGML_OPENCL_OPFLUSH GGML_OPENCL_OPSYNC GGML_OPENCL_OPBATCH \
         GGML_OPENCL_DISABLE_FUSION FD_NODEFER FD_NO_BOCACHE FD_FORCE_REEMIT FD_IBTRACE FD_MESA_DEBUG; do
  eval "val=\${$v:-}"
  say "  $v=${val:-（未设）}"
done

# 5) 事后 GPU 证据硬闸的读法（出数后必须回填这两项，缺一不可）
say "-- 出数后必须回填 --"
say "  opencl_lines=\$(grep -ac ggml_opencl <leg>.err)   # =0 说明后端根本没起"
say "  drop=\$(grep -ac 'drop unsupported device' <leg>.err)   # >0 说明设备被丢、退回 CPU，此数作废"
if [ "$FAIL" = "0" ]; then say "==== bundle 体检通过 ===="; else say "==== 体检失败 $FAIL 项：这份数据不许进任何表格 ===="; fi
exit $FAIL
