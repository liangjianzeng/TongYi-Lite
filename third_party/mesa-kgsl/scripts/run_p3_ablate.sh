#!/system/bin/sh
# [Mesa 线 P3] 消融"为了让 Mesa 跑起来而开的降级开关"，看它们是不是 token-18 数值分歧的成因。
#
# 为什么是这两个开关（§2.6 实测事实决定的靶子）：8 条不同加压配置的 Mesa 腿**全部**在第 18 个
# token 与 CPU 分歧、分歧率一模一样 66% —— 零方差。竞态型 bug（P2 的 kernel 丢失）不可能在
# 8 种配置下把分歧点钉在同一处，所以这个分歧是**确定性数值差**，属 P3（内核质量），不属 P2。
# 而当前 Mesa 腿全靠两个"降级开关"才跑得起来：
#   GGML_OPENCL_FAKE_QCOM_REQD=1  -> 编译期注入 -D cl_qcom_reqd_sub_group_size=1
#                                    -D GGML_GENERIC_SUBGROUP_SHUFFLE=1（把 qcom 专用
#                                    subgroup shuffle 换成通用实现，且 sub group size 从
#                                    Adreno 的 64 改成 1 —— 直接改变内核里的按波次划分）
#   GGML_OPENCL_ALLOW_NO_SUBGROUP=1 -> 允许没有 subgroup 能力的内核也上机
# 判定：哪个开关关掉之后（a）还能编译+加载，（b）分歧点离开 18，那个开关就是数值分歧的成因，
#       同时也就是 P3"解除内核降级"的第一块真肉。关掉就起不来，本身也是 P3 的结论（记为不可关）。
#
# 口径：与 run_p2_pressure.sh **同一份 prompt / seed / temp / NBATCH**，只有那样才和已确立的
# "@18 / 66%" 可比。OPFLUSH 固定 1（先排除提交层，只留数值）。内核缓存不影响：key 含 compile_opts
# （cl-program-cache.cpp:357 compute_key(suffix, source, compile_opts)），换开关不会吃到旧 .clbin。
#
# 用法：RUN=<dir> B=<mesa_dir> M=<gguf> E=<experts> sh run_p3_ablate.sh [npred=32]
set -u
BIN=${BIN:-minicpm_e2e}
NPRED=${1:-32}
RUN=${RUN:?}; B=${B:?}; M=${M:?}; E=${E:?}
OUT=/data/local/tmp/p3a_$(date +%H%M); mkdir -p $OUT
cd "$RUN" || exit 1
export LD_LIBRARY_PATH=$RUN:$RUN/lib:$B/lib:$B:/data/local/tmp
export OCL_ICD_VENDORS=$B/lib/libRusticlOpenCL.so RUSTICL_ENABLE=kgsl
export HOME=$B/tmp XDG_CACHE_HOME=$B/tmp CLC_RESOURCE_DIR=$B/lib/clang/21/include
export GGML_OPENCL_MESA_SPIRV=1 GGML_OPENCL_ADRENO_XMEM_GEMM=0
export E2E_SEED=42 E2E_TEMP=0
export GGML_E2E_PROMPT='请详细介绍一下中国的四大发明，分别说明每一项的历史背景、技术要点和对世界文明的影响，分四段展开，每段不少于八十字，不要简短总结。然后再分别说明印刷术在欧洲古登堡时期的改良、火药经阿拉伯传入欧洲的路径、指南针在宋代航海中的应用记载、造纸术对纸张成本的影响，各不少于六十字。'
[ -f "$RUN/BUILD_INFO" ] && cat "$RUN/BUILD_INFO"
echo "#### p3_ablate npred=$NPRED $(date -Iseconds) loadavg=$(cat /proc/loadavg)"
ls -l "$RUN/$BIN" | awk '{print "#### bin="$7" "$8" "$5"B"}'

leg () { # $1=tag  $2..=该腿额外的 env（不给即该开关关闭）
  T=$1; shift
  echo "-- LEG $T [$*] $(date +%H:%M:%S)"
  env "$@" GGML_OPENCL_OPFLUSH=1 E2E_TOKDUMP=$OUT/$T.tok timeout 900 \
    ./$BIN "$M" "$E" 99 "$NPRED" 512 > $OUT/$T.out 2> $OUT/$T.err
  RC=$?
  echo "   rc=$RC tokbytes=$(ls -l $OUT/$T.tok 2>/dev/null | awk '{print $5}') sub=$(grep -ac 'KGSLSUBMIT cmd\[' $OUT/$T.err 2>/dev/null) health=$(grep -acE '造纸|印刷|指南针|火药' $OUT/$T.out)"
  echo "   cl_err=$(grep -acE 'compile error|CL_BUILD_PROGRAM_FAILURE|error:' $OUT/$T.err 2>/dev/null) vsb=$(grep -a 'vector subgroup broadcast support' $OUT/$T.err | tail -1 | sed 's/.*: //')"
  grep -aE 'compile error|CL_BUILD_PROGRAM_FAILURE|undefined|GGML_ASSERT' $OUT/$T.err 2>/dev/null | head -2 | cut -c1-160
  sleep 60
}
# 参照：同 prompt 的 CPU 腿（本脚本自带，省得跨 run 引用）
env LD_LIBRARY_PATH=$RUN:$RUN/lib:/data/local/tmp GGML_OPENCL_OFF=1 GGML_OPENCL_OPFLUSH=0 \
  E2E_TOKDUMP=$OUT/cpu.tok timeout 900 ./$BIN "$M" "$E" 99 "$NPRED" 512 > $OUT/cpu.out 2>$OUT/cpu.err
echo "-- LEG cpu rc=$? tokbytes=$(ls -l $OUT/cpu.tok 2>/dev/null | awk '{print $5}')"
sleep 60
leg q1a1 GGML_OPENCL_ALLOW_NO_SUBGROUP=1 GGML_OPENCL_FAKE_QCOM_REQD=1
leg q0a1 GGML_OPENCL_FAKE_QCOM_REQD=1
leg q1a0 GGML_OPENCL_ALLOW_NO_SUBGROUP=1
leg q0a0
echo "=== P3_ABLATE_DONE dir=$OUT ==="
echo "读法：python3 third_party/mesa-kgsl/scripts/token_diff.py $OUT/cpu.tok $OUT/q1a1.tok $OUT/q0a1.tok $OUT/q1a0.tok $OUT/q0a0.tok"
echo "判定：q1a1 必须复现 @18/66%（否则本组全部作废，说明 run 间不可比）；"
echo "      某腿分歧点离开 18 且 rc=0 => 那个开关就是数值分歧成因 = P3 第一块肉；"
echo "      某腿 tokbytes=0 => 该开关关不掉（记为降级不可解除），同样是有用的结论。"
echo "!! 假 PASS 硬闸（实测差点被它骗两次）：任何'全等 PASS'必须先证明它真在 GPU 上跑——"
echo "   查该腿 .err 里有没有 'drop unsupported device' / 'does not support subgroups'，以及 KGSLSUBMIT 行数>0。"
echo "   退回 CPU 的腿与 CPU 全等 = 同义反复，一律不算数（q0a1/q0a0 就是这样：err 268KB vs GPU 腿 52.7MB、KGSLSUBMIT=0）。"
