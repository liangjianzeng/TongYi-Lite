#!/system/bin/sh
# G-731 v2: 专家粒度(450KiB)随机冷读实测。
# v1 作废原因（留档，防再犯）：toybox `date +%s%N` 在本机给出负的毫秒差（cold=-763ms/warm=-1643ms），
#   且那次跑测 loadavg=2.33 已越过安静闸 —— 两条都是「仪器自己不可信」，数不得用。
# v2 改动：① 计时改 /proc/uptime（monotonic，两位小数，无 %N 依赖）；② 内置安静闸，不静即 exit 3。
U() { read u _ </proc/uptime; echo "$u"; }
LA=$(cut -d' ' -f1 /proc/loadavg)
OK=$(awk -v l="$LA" 'BEGIN{print (l+0<2)?1:0}')
if [ "$OK" != "1" ]; then
  echo "REFUSE: loadavg(1min)=$LA >= 2 —— 机器不安静，本次不出数（R 规则：宁可不出数）"
  exit 3
fi
F=${F:-/data/local/tmp/k40moe/models/experts/layer_020.bin}
BS=${BS:-450560}
N=${N:-180}
NB=$(stat -c %s "$F"); BLOCKS=$(( NB / BS ))
echo "file=$F size=$NB bs=$BS blocks=$BLOCKS loadavg=$LA MemAvail=$(awk '/MemAvailable/{print $2/1024" MB"}' /proc/meminfo)"
OFFS=$(awk -v n=$N -v b="$BLOCKS" 'BEGIN{srand(20261021); for(i=0;i<n;i++) printf "%d\n", int(rand()*b)}')
BYTES=$(( N * BS ))

run_rand() { for o in $OFFS; do dd if="$F" of=/dev/null bs=$BS count=1 skip=$o 2>/dev/null; done; }

T0=$(U); run_rand; T1=$(U); COLD=$(awk -v a="$T0" -v b="$T1" 'BEGIN{printf "%.0f",(b-a)*1000}')
T0=$(U); run_rand; T1=$(U); WARM=$(awk -v a="$T0" -v b="$T1" 'BEGIN{printf "%.0f",(b-a)*1000}')
T0=$(U); dd if="$F" of=/dev/null bs=1M count=96 2>/dev/null; T1=$(U)
SEQ=$(awk -v a="$T0" -v b="$T1" 'BEGIN{printf "%.0f",(b-a)*1000}')
T0=$(U); dd if="$F" of=/dev/null bs=$BS count=$N skip=400 2>/dev/null; T1=$(U)
SEQBS=$(awk -v a="$T0" -v b="$T1" 'BEGIN{printf "%.0f",(b-a)*1000}')
MB=$(( BYTES / 1048576 ))
echo "== 随机 $N x ${BS}B = ${MB} MiB（同一偏移序列跑两遍）=="
echo "  cold ${COLD} ms -> 含spawn $(( MB * 1000 / (COLD + 1) )) MB/s"
echo "  warm ${WARM} ms -> 含spawn $(( MB * 1000 / (WARM + 1) )) MB/s (≈spawn+页缓存)"
NET=$(( COLD - WARM ))
echo "  净设备读 = cold-warm = ${NET} ms -> ** $(( MB * 1000 / (NET + 1) )) MB/s @450KiB随机 **"
echo "  sanity: cold 必须 > warm，否则本次作废（NET<=0 即仪器失效）"
echo "== 对照（顺序）：96MiB/1M=${SEQ}ms -> $(( 96 * 1000 / (SEQ + 1) )) MB/s ; ${MB}MiB/450KiB=${SEQBS}ms -> $(( MB * 1000 / (SEQBS + 1) )) MB/s"
