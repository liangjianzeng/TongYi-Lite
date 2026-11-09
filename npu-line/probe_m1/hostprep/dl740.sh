#!/system/bin/sh
# Device-side resumable pull of spark_r2_ctx.bin from PC over tailnet.
D=/data/local/tmp/npu_m1/spark_r2_ctx.bin
URL=http://<redacted-tailscale-pc>:8123/spark_r2_ctx.bin
rm -f /data/local/tmp/npu_m1/dl_done.txt
i=0
while [ $i -lt 60 ]; do
  S=$(stat -c %s $D 2>/dev/null || echo 0)
  if [ "$S" = "2966622208" ]; then break; fi
  if [ "$S" = "0" ]; then
    curl -s -o $D $URL
  else
    tail -c +$((S+1)) /dev/null >/dev/null 2>&1
    curl -s -r $S- -o $D.tmp $URL && cat $D.tmp >> $D && rm -f $D.tmp
  fi
  i=$((i+1))
  sleep 2
done
md5sum $D > /data/local/tmp/npu_m1/dl_done.txt 2>&1
echo LOOP_END_$i >> /data/local/tmp/npu_m1/dl_done.txt
