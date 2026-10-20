#!/system/bin/sh
# [Mesa 线 P2 数值轨] 定性质疑 token-45 分歧：是"边际 argmax 翻转"（合法）还是"某内核真算错"（P3 靶子）。
#
# 手段：E2E_LOGITDUMP 让 e2e 每步把 top5 + margin12 打到 stderr；cpu 腿与 Mesa 腿各跑一遍，
# 逐步比 margin。判读口径（写在 docs/全GPU卸载_Mesa线接管复评与重规划_2026-10-20.md §2.6）：
#   分歧步的 margin12 很小（<=1e-2 量级）      => 近tie 翻转，数值可接受，P2 数值轨结案；
#   分歧步的 margin12 两边都大 / 数量级不同    => 真算错，进 P3 拿这个 step 当靶子。
# 注意：stderr 经管道过滤，只留 [lgd] 行——在机那颗 Mesa 是 trace 版，全量 stderr 每 token ~1.5 万行。
#
# 用法：RUN=<dir> B=<mesa_dir> M=<gguf> E=<experts> [PROMPT_KIND=long|short] sh run_p2_lgd.sh [n_predict=50] [legs=cpu,async]
set -u
NPRED=${1:-50}; LEGS=${2:-cpu,async}
RUN=${RUN:-/data/local/tmp/k40moe}; B=${B:-/data/local/tmp/mesa_clean}
M=${M:?需要 M=<gguf 路径>}
E=${E:?需要 E=<experts 目录>}
TOK=/data/local/tmp/lgd_$(date +%H%M); mkdir -p $TOK
cd "$RUN" || exit 1
export LD_LIBRARY_PATH=$RUN:$RUN/lib:$B/lib:$B:/data/local/tmp
export OCL_ICD_VENDORS=$B/lib/libRusticlOpenCL.so RUSTICL_ENABLE=kgsl
export HOME=$B/tmp XDG_CACHE_HOME=$B/tmp CLC_RESOURCE_DIR=$B/lib/clang/21/include
export GGML_OPENCL_ALLOW_NO_SUBGROUP=1 GGML_OPENCL_FAKE_QCOM_REQD=1
export GGML_OPENCL_MESA_SPIRV=1 GGML_OPENCL_ADRENO_XMEM_GEMM=0
export E2E_NBATCH=512 E2E_SEED=42 E2E_TEMP=0 E2E_NOMMAP=1 E2E_LOGITDUMP=1
# prompt 两档：long = 与 run_p2_pressure.sh 同一条长 prompt（K40 实测这条把首个分歧压到 token 18，
# 是最容易暴露数值差的那条）；short = 验收用的短 prompt（分歧在 45）。也可自己 export GGML_E2E_PROMPT 覆盖。
if [ -z "${GGML_E2E_PROMPT:-}" ]; then
  if [ "${PROMPT_KIND:-long}" = short ]; then
    export GGML_E2E_PROMPT='请详细介绍一下中国的四大发明，分四段展开，不要简短总结。'
  else
    export GGML_E2E_PROMPT='请详细介绍一下中国的四大发明，分别说明每一项的历史背景、技术要点和对世界文明的影响，分四段展开，每段不少于八十字，不要简短总结。然后再分别说明印刷术在欧洲古登堡时期的改良、火药经阿拉伯传入欧洲的路径、指南针在宋代航海中的应用记载、造纸术对纸张成本的影响，各不少于六十字。'
  fi
fi
echo "#### lgd npred=$NPRED legs=$LEGS $(date -Iseconds) loadavg=$(cat /proc/loadavg)"

one () { # $1=tag $2..=env
  N=$1; shift
  echo "-- LEG $N $(date +%H:%M:%S) env=$*"
  env "$@" E2E_TOKDUMP=$TOK/$N.bin timeout 900 \
    ./minicpm_e2e "$M" "$E" 99 "$NPRED" 512 2>&1 >$TOK/$N.out | grep -aE '\[lgd\]|METRIC' > $TOK/$N.lgd
  echo "   rc=$? tokbytes=$(ls -l $TOK/$N.bin 2>/dev/null | awk '{print $5}') lgd_lines=$(wc -l < $TOK/$N.lgd)"
  sleep 60
}
case ",$LEGS," in *,cpu,*)   one cpu   GGML_OPENCL_OFF=1 ;; esac
case ",$LEGS," in *,flush1,*) one flush1 GGML_OPENCL_OPFLUSH=1 ;; esac
case ",$LEGS," in *,async,*) one async GGML_OPENCL_OPFLUSH=0 ;; esac
echo "=== LGD_DONE dir=$TOK ==="
echo "取数：adb pull $TOK 后逐行比 $TOK/cpu.lgd 与 $TOK/async.lgd 的 margin12（重点看首个分歧 step）"
