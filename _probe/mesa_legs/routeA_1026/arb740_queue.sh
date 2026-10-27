#!/system/bin/sh
# R-076 740 仲裁自律队列：热闸(<44.0)守门 -> kq0 CPU金 -> kq2 x20 drift -> kq7 x3。
# 设备端 nohup 长跑；宿主只读 out/arb740_results.log。禁中途 kill。
R=/data/local/tmp/mesa_clrt_1026
LEG=$R/routeA_e4_legs.sh
OUT=$R/out
RES=$OUT/arb740_results.log
BINMD5=$(md5sum $R/bin/libggml-opencl.so.0.27.0 | cut -c1-8)
lingmd5() { md5sum $R/bin/ling_e2e | cut -c1-8; }
hot() {  # 1=过热需等 —— 口径=legs 官方 dumpsys battery(centi-°C)，
         # 充电周边 pmh 区 46°≠电池热(17:4x 定罪: 曾错杀饿队列 35min)
  t=$(dumpsys battery 2>/dev/null | grep -m1 temperature | tr -dc '0-9')
  [ -z "$t" ] && return 0
  [ "$t" -gt 440 ]
}
coldwait() {  # 最多等 60 分钟
  n=0
  while hot; do
    n=$((n+1)); [ $n -gt 120 ] && { echo "GIVEUP_HOT $t" >> $RES; return 1; }
    sleep 30
  done
  return 0
}
echo "==== ARB740 START $(date) bin=$BINMD5 ====" >> $RES
run_leg() {  # $1=case $2=tag
  coldwait || return 1
  rm -f $OUT/$1.tok
  sh $LEG $1
  tok=$OUT/$1.tok
  if [ -s "$tok" ]; then
    echo "RESULT case=$1 tag=$2 bin=$BINMD5 ling=$(lingmd5) tokmd5=$(md5sum $tok | cut -c1-8) bytes=$(wc -c < $tok) at=$(date +%H:%M:%S)" >> $RES
  else
    echo "RESULT case=$1 tag=$2 EMPTY at=$(date +%H:%M:%S)" >> $RES
  fi
}
run_leg kq0 gold0
i=1
while [ $i -le 20 ]; do
  coldwait || break
  rm -f $OUT/kq2.tok
  sh $LEG kq2
  tok=$OUT/kq2.tok
  if [ -s "$tok" ]; then
    echo "RESULT case=kq2 tag=d$i bin=$BINMD5 ling=$(lingmd5) tokmd5=$(md5sum $tok | cut -c1-8) bytes=$(wc -c < $tok) at=$(date +%H:%M:%S)" >> $RES
    cp $tok $OUT/kq2_d$i.tok; cp $OUT/kq2.err $OUT/kq2_d$i.err 2>/dev/null
  else
    echo "RESULT case=kq2 tag=d$i EMPTY at=$(date +%H:%M:%S)" >> $RES
  fi
  i=$((i+1))
done
i=1
while [ $i -le 3 ]; do
  coldwait || break
  rm -f $OUT/kq7.tok
  sh $LEG kq7
  tok=$OUT/kq7.tok
  if [ -s "$tok" ]; then
    echo "RESULT case=kq7 tag=s$i bin=$BINMD5 ling=$(lingmd5) tokmd5=$(md5sum $tok | cut -c1-8) bytes=$(wc -c < $tok) at=$(date +%H:%M:%S)" >> $RES
    cp $tok $OUT/kq7_s$i.tok
  else
    echo "RESULT case=kq7 tag=s$i EMPTY at=$(date +%H:%M:%S)" >> $RES
  fi
  i=$((i+1))
done
echo "==== ARB740 DONE $(date) ====" >> $RES
