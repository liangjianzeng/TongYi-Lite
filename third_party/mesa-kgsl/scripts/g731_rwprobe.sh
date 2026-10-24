#!/system/bin/sh
# G-731: 专家粒度(450KiB)随机冷读实测。冷跑/暖跑同一偏移序列，用差值抵消 dd 进程启动开销。
F=${F:-/data/local/tmp/k40moe/models/experts/layer_020.bin}
BS=${BS:-450560}
N=${N:-180}
NB=$(stat -c %s "$F")
BLOCKS=$(( NB / BS ))
echo "file=$F size=$NB bs=$BS blocks=$BLOCKS loadavg=$(cat /proc/loadavg)"
OFFS=$(awk -v n=$N -v b=$((BLOCKS-1)) 'BEGIN{srand(20261021); for(i=0;i<n;i++) printf "%d\n", int(rand()*(b+1))}')
BYTES=$(( N * BS ))

T0=$(date +%s%N); for o in $OFFS; do dd if="$F" of=/dev/null bs=$BS count=1 skip=$o 2>/dev/null; done; T1=$(date +%s%N)
COLD=$(( (T1-T0)/1000000 ))
T0=$(date +%s%N); for o in $OFFS; do dd if="$F" of=/dev/null bs=$BS count=1 skip=$o 2>/dev/null; done; T1=$(date +%s%N)
WARM=$(( (T1-T0)/1000000 ))
T0=$(date +%s%N); dd if="$F" of=/dev/null bs=1M count=96 2>/dev/null; T1=$(date +%s%N)
SEQ=$(( (T1-T0)/1000000 ))
T0=$(date +%s%N); dd if="$F" of=/dev/null bs=450560 count=180 skip=400 2>/dev/null; T1=$(date +%s%N)
SEQBS=$(( (T1-T0)/1000000 ))
MB=$(( BYTES / 1048576 ))

echo "== 随机 $N x ${BS}B = ${MB} MiB =="
echo "  cold  ${COLD} ms  -> 含spawn ${MB}x1000/${COLD} = $(( MB * 1000 / (COLD + 1) )) MB/s"
echo "  warm  ${WARM} ms  -> 含spawn $(( MB * 1000 / (WARM + 1) )) MB/s (≈纯 spawn 开销)"
NET=$(( COLD - WARM ))
echo "  净设备读 cold-warm = ${NET} ms -> ** $(( MB * 1000 / (NET + 1) )) MB/s **"
echo "== 对照：顺序 96MiB ${SEQ} ms -> $(( 96 * 1000 / (SEQ + 1) )) MB/s ; 同 bs=450560 顺序 ${SEQBS} ms -> $(( MB * 1000 / (SEQBS + 1) )) MB/s"
